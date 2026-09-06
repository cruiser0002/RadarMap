"""
RadarMap Player Simulator
Simulates squad players moving in circular or tactical trajectories around GPS coordinates
and streams live telemetry and tactical indicators to Firebase Realtime Database.
Matches the Swift WatchOS/iOS client schema and communication protocol.
"""

import math
import os
import time
import random
import hashlib
import uuid
import threading
import queue
from dataclasses import dataclass, field
from typing import Optional, Dict, Any, Tuple, List, Callable

try:
    import firebase_admin
    from firebase_admin import credentials as firebase_credentials
    from firebase_admin import db as firebase_db
    from firebase_admin import exceptions as firebase_exceptions
except ImportError as _import_error:
    raise ImportError(
        "firebase-admin is required to run the RadarMap player simulator. Install it with "
        "`pip install -r requirements.txt` (see notebooks/requirements.txt) or "
        "`pip install firebase-admin`."
    ) from _import_error


# MARK: - Firebase App Registry
# firebase-admin only allows a given app *name* to be initialized once per process (it raises
# ValueError on re-init). Multiple simulated players/coordinators in the same process legitimately
# target the same (credentials, database_url) pair and should share one underlying App instance
# and its persistent authorized connection, so cache by that pair rather than using the SDK's
# implicit default app.
_firebase_apps_lock = threading.Lock()
_firebase_apps: Dict[Tuple[str, str], Any] = {}
_firebase_app_counter = 0


def _get_or_create_firebase_app(credentials_path: str, database_url: str):
    """Returns a process-wide firebase_admin.App for the given (credentials, database_url)
    pair, initializing it on first use."""
    global _firebase_app_counter
    key = (os.path.abspath(credentials_path), database_url)
    with _firebase_apps_lock:
        app = _firebase_apps.get(key)
        if app is not None:
            return app
        cred = firebase_credentials.Certificate(credentials_path)
        _firebase_app_counter += 1
        app = firebase_admin.initialize_app(
            cred,
            {"databaseURL": database_url},
            name=f"radarmap-sim-{_firebase_app_counter}",
        )
        _firebase_apps[key] = app
        return app


def resolve_firebase_credentials_path(explicit_path: Optional[str] = None) -> str:
    """Resolves the service-account JSON key path from an explicit argument or the
    FIREBASE_CREDENTIALS environment variable. Fails loudly rather than silently falling back
    to Application Default Credentials, since a missing key is almost always a setup mistake."""
    path = explicit_path or os.environ.get("FIREBASE_CREDENTIALS")
    if not path:
        raise RuntimeError(
            "No Firebase service-account credentials provided. Pass --credentials <path> (CLI) "
            "or credentials_path=... (Python), or set the FIREBASE_CREDENTIALS environment "
            "variable, to a service-account JSON key downloaded from the Firebase Console "
            "(Project Settings > Service Accounts > Generate new private key) for the "
            "radarmap-8adf0 project. Keep this file out of version control — see "
            "notebooks/README.md for the recommended location."
        )
    if not os.path.isfile(path):
        raise RuntimeError(f"Firebase credentials file not found: '{path}'.")
    return path


# MARK: - Error Classification
class FirebaseErrorCategory:
    TRANSIENT = "transient"        # Timeouts, connection resets, DNS, 502/503/504
    PERMANENT = "permanent"        # 401 Unauthorized, 403 Forbidden, 400 Malformed, 404 Room Not Found
    CONVERGED = "converged"        # Idempotent success (e.g. deleting already absent marker)
    UNKNOWN = "unknown"


@dataclass
class UploadMetrics:
    initializations: int = 0
    client_creations: int = 0
    telemetry_attempted: int = 0
    telemetry_succeeded: int = 0
    telemetry_failed_transient: int = 0
    telemetry_failed_permanent: int = 0
    telemetry_pending_replaced: int = 0
    telemetry_retry_attempted: int = 0
    telemetry_retry_succeeded: int = 0
    tactical_enqueued: int = 0
    tactical_succeeded: int = 0
    tactical_failed_transient: int = 0
    tactical_failed_permanent: int = 0
    tactical_queue_depth: int = 0
    http_or_transport_session_creations: int = 0
    read_operations: int = 0
    listener_or_stream_operations: int = 0

    def as_dict(self) -> Dict[str, int]:
        return {
            "firebase.initializations": self.initializations,
            "firebase.client_creations": self.client_creations,
            "firebase.telemetry.attempted": self.telemetry_attempted,
            "firebase.telemetry.succeeded": self.telemetry_succeeded,
            "firebase.telemetry.failed_transient": self.telemetry_failed_transient,
            "firebase.telemetry.failed_permanent": self.telemetry_failed_permanent,
            "firebase.telemetry.pending_replaced": self.telemetry_pending_replaced,
            "firebase.telemetry.retry_attempted": self.telemetry_retry_attempted,
            "firebase.telemetry.retry_succeeded": self.telemetry_retry_succeeded,
            "firebase.tactical.enqueued": self.tactical_enqueued,
            "firebase.tactical.succeeded": self.tactical_succeeded,
            "firebase.tactical.failed_transient": self.tactical_failed_transient,
            "firebase.tactical.failed_permanent": self.tactical_failed_permanent,
            "firebase.tactical.queue_depth": self.tactical_queue_depth,
            "firebase.http_or_transport_session_creations": self.http_or_transport_session_creations,
            "firebase.read_operations": self.read_operations,
            "firebase.listener_or_stream_operations": self.listener_or_stream_operations,
        }


@dataclass
class TelemetryItem:
    room_name: str
    member_id: str
    payload: Any
    created_at: float
    is_retry: bool = False
    retry_count: int = 0
    next_retry_time: float = 0.0


@dataclass
class TacticalOperation:
    op_id: str
    op_type: str  # "place", "remove", "clear"
    room_name: str
    indicator_id: Optional[str] = None
    indicator_type: Optional[str] = None
    lat: Optional[float] = None
    lon: Optional[float] = None
    placed_by: Optional[str] = None
    created_at: float = field(default_factory=time.time)
    retry_count: int = 0
    next_retry_time: float = 0.0


class FirebaseUploadCoordinator:
    """
    Manages low-overhead, asynchronous network uploads to Firebase Realtime Database.
    
    Features:
    - Exactly one initialization & reusable transport session per process/coordinator.
    - Ephemeral Latest-Only Telemetry: Holds only 1 pending telemetry point at any time,
      coalescing new points and discarding obsolete stale samples during outages.
    - Durable Tactical Queue: Bounded FIFO queue for tactical markers with exponential backoff.
    - Background Worker: Decouples network I/O latency from the 1 Hz physics simulation loop.
    - Observability: Collects 17 telemetry & transport metrics with periodic aggregate reporting.
    """

    MAX_TACTICAL_QUEUE_SIZE = 100
    REQUEST_TIMEOUT_SEC = 5.0
    INITIAL_BACKOFF_SEC = 0.5
    MAX_BACKOFF_SEC = 10.0
    BACKOFF_MULTIPLIER = 2.0
    JITTER_FACTOR = 0.25

    def __init__(self, database_url: str, credentials_path: str, periodic_log_interval_sec: float = 30.0):
        self.database_url = database_url.rstrip("/")
        self.credentials_path = credentials_path
        self.metrics = UploadMetrics()
        self.periodic_log_interval = periodic_log_interval_sec
        self._lock = threading.RLock()
        self._condition = threading.Condition(self._lock)

        # Telemetry latest-only slot
        self._pending_telemetry: Optional[TelemetryItem] = None
        self._telemetry_permanent_error: bool = False

        # Tactical durable queue
        self._tactical_queue: List[TacticalOperation] = []
        self._tactical_permanent_error: bool = False

        # Session & Network transport
        self._app: Optional[Any] = None
        self._init_transport()

        # Worker lifecycle
        self._is_running = True
        self._last_aggregate_log_time = time.time()
        self._worker_thread = threading.Thread(target=self._worker_loop, name="FirebaseUploadWorker", daemon=True)
        self._worker_thread.start()

        # Startup diagnostic log
        self._log_startup_diagnostics()

    def _init_transport(self):
        """Initializes the Firebase Admin SDK app and its persistent authorized connection once."""
        self.metrics.initializations += 1
        self.metrics.client_creations += 1
        self.metrics.http_or_transport_session_creations += 1

        self._app = _get_or_create_firebase_app(self.credentials_path, self.database_url)

    def _log_startup_diagnostics(self):
        """Logs diagnostic transport details once at startup."""
        transport_desc = (
            "firebase-admin SDK (Realtime Database module) with a persistent, service-account "
            "authorized connection, reused across requests. Note: this is a privileged server "
            "SDK — writes bypass database.rules.json entirely (expected/fine for this script; "
            "see CLOUD_DATA_MANAGEMENT.md §6)."
        )
        print("=" * 70)
        print(f"[FirebaseUploadCoordinator] Initialized successfully.")
        print(f"  • Library: firebase-admin {firebase_admin.__version__}")
        print(f"  • Transport: {transport_desc}")
        print(f"  • Credentials: {self.credentials_path}")
        print(f"  • Database URL: {self.database_url}")
        print(f"  • Telemetry Mode: Latest-Only Single Slot (Coalesced on backpressure)")
        print(f"  • Tactical Mode: Durable Bounded Queue (Max capacity: {self.MAX_TACTICAL_QUEUE_SIZE})")
        print(f"  • Telemetry Read/Listener Operations: 0 (Strictly disabled)")
        print("=" * 70)

    # MARK: - Raw Transport Operations
    def _execute_db(self, method: str, path: str, data: Optional[Any] = None) -> Tuple[int, Any, str]:
        """
        Executes a Realtime Database operation via the firebase-admin SDK's persistent,
        service-account authorized connection.
        Returns: (status_code, response_data, error_category) — mirrors the contract of the
        former REST-based transport so all downstream retry/classification logic is unchanged.
        """
        ref_path = path.lstrip("/")
        if ref_path.endswith(".json"):
            ref_path = ref_path[: -len(".json")]
        ref = firebase_db.reference("/" + ref_path, app=self._app)

        if method == "GET":
            with self._lock:
                self.metrics.read_operations += 1

        try:
            if method == "GET":
                res_data = ref.get()
            elif method == "PUT":
                ref.set(data)
                res_data = None
            elif method == "DELETE":
                ref.delete()
                res_data = None
            else:
                raise ValueError(f"Unsupported method: {method}")
            status_code = 200
        except firebase_exceptions.FirebaseError as e:
            status_code = self._status_code_from_firebase_error(e)
            category = self._classify_status(status_code, method)
            return status_code, str(e), category
        except Exception as e:
            return -1, str(e), FirebaseErrorCategory.UNKNOWN

        category = self._classify_status(status_code, method)
        return status_code, res_data, category

    @staticmethod
    def _status_code_from_firebase_error(error: "firebase_exceptions.FirebaseError") -> int:
        """Recovers an HTTP-style status code from an SDK error so the existing HTTP-status-based
        classification logic (_classify_status) keeps working unchanged."""
        if error.http_response is not None:
            return error.http_response.status_code
        if isinstance(error, firebase_exceptions.DeadlineExceededError):
            return 408
        if isinstance(error, firebase_exceptions.UnavailableError):
            return 503
        return -1

    @staticmethod
    def _classify_status(status_code: int, method: str) -> str:
        if 200 <= status_code < 300:
            return FirebaseErrorCategory.CONVERGED if method == "DELETE" else "success"
        if status_code in (401, 403, 400):
            return FirebaseErrorCategory.PERMANENT
        if status_code == 404:
            # Deleting a non-existent marker is converged success
            return FirebaseErrorCategory.CONVERGED if method == "DELETE" else FirebaseErrorCategory.PERMANENT
        if status_code in (408, 429, 500, 502, 503, 504):
            return FirebaseErrorCategory.TRANSIENT
        return FirebaseErrorCategory.UNKNOWN

    def _compute_backoff(self, retry_count: int) -> float:
        """Computes exponential backoff with random jitter."""
        delay = min(self.MAX_BACKOFF_SEC, self.INITIAL_BACKOFF_SEC * (self.BACKOFF_MULTIPLIER ** retry_count))
        jitter = delay * self.JITTER_FACTOR * (random.random() * 2 - 1)
        return max(0.1, delay + jitter)

    # MARK: - Telemetry Dispatch (Latest-Only)
    def submit_telemetry(self, room_name: str, member_id: str, payload: Any):
        """
        Pushes a new telemetry sample into the single latest-only pending slot.
        If a prior sample has not yet been uploaded, it is overwritten and discarded.
        """
        now = time.time()
        with self._condition:
            if self._pending_telemetry is not None:
                self.metrics.telemetry_pending_replaced += 1

            self._pending_telemetry = TelemetryItem(
                room_name=room_name,
                member_id=member_id,
                payload=payload,
                created_at=now,
                is_retry=False,
                retry_count=0,
                next_retry_time=now
            )
            self._condition.notify_all()

    # MARK: - Tactical Operations Dispatch (Durable Queue)
    def submit_tactical_op(self, op: TacticalOperation) -> bool:
        """
        Enqueues a durable tactical operation into the bounded FIFO queue.
        Returns False if the queue is full (backpressure rejection).
        """
        with self._condition:
            if len(self._tactical_queue) >= self.MAX_TACTICAL_QUEUE_SIZE:
                print(f"[TACTICAL ERROR] Queue capacity exceeded ({self.MAX_TACTICAL_QUEUE_SIZE}). Dropping op {op.op_id}.")
                self.metrics.tactical_failed_permanent += 1
                return False

            self._tactical_queue.append(op)
            self.metrics.tactical_enqueued += 1
            self.metrics.tactical_queue_depth = len(self._tactical_queue)
            self._condition.notify_all()
            return True

    # MARK: - Session / Room Management
    def reset_session(self):
        """Clears pending telemetry when room/session changes to avoid cross-room pollution."""
        with self._lock:
            self._pending_telemetry = None
            self._telemetry_permanent_error = False

    def close(self):
        """Cleanly shuts down the worker thread. The underlying Firebase App/connection is
        process-wide and cached by (credentials, database_url) — it may be shared with other
        coordinators, so it is intentionally left running rather than torn down here."""
        with self._condition:
            self._is_running = False
            self._condition.notify_all()

        if self._worker_thread.is_alive():
            self._worker_thread.join(timeout=2.0)

    # MARK: - Background Worker Loop
    def _worker_loop(self):
        while True:
            item_to_send: Optional[TelemetryItem] = None
            tactical_op: Optional[TacticalOperation] = None
            now = time.time()

            with self._condition:
                if not self._is_running:
                    break

                # Periodic aggregate logging check
                if now - self._last_aggregate_log_time >= self.periodic_log_interval:
                    self._log_periodic_aggregate()
                    self._last_aggregate_log_time = now

                # 1. Check tactical queue first (durable operations)
                if self._tactical_queue and not self._tactical_permanent_error:
                    first_op = self._tactical_queue[0]
                    if now >= first_op.next_retry_time:
                        tactical_op = first_op

                # 2. Check pending telemetry
                if tactical_op is None and self._pending_telemetry is not None and not self._telemetry_permanent_error:
                    if now >= self._pending_telemetry.next_retry_time:
                        item_to_send = self._pending_telemetry

                # If nothing ready, wait with timeout
                if tactical_op is None and item_to_send is None:
                    # Calculate next wake time
                    next_wake = 1.0
                    if self._tactical_queue:
                        next_wake = min(next_wake, max(0.05, self._tactical_queue[0].next_retry_time - now))
                    if self._pending_telemetry:
                        next_wake = min(next_wake, max(0.05, self._pending_telemetry.next_retry_time - now))
                    self._condition.wait(timeout=next_wake)
                    continue

            # Process outside lock to avoid blocking producers
            if tactical_op is not None:
                self._process_tactical_op(tactical_op)
            elif item_to_send is not None:
                self._process_telemetry_item(item_to_send)

    def _process_telemetry_item(self, item: TelemetryItem):
        path = f"p/{item.room_name}/{item.member_id}.json"
        with self._lock:
            self.metrics.telemetry_attempted += 1
            if item.is_retry:
                self.metrics.telemetry_retry_attempted += 1

        status_code, resp_data, category = self._execute_db("PUT", path, item.payload)

        with self._lock:
            if category == "success":
                self.metrics.telemetry_succeeded += 1
                if item.is_retry:
                    self.metrics.telemetry_retry_succeeded += 1
                # If this is still the pending telemetry, clear it
                if self._pending_telemetry is item:
                    self._pending_telemetry = None
            elif category == FirebaseErrorCategory.TRANSIENT:
                self.metrics.telemetry_failed_transient += 1
                # If this item is still in the slot (not replaced by newer sample), update backoff
                if self._pending_telemetry is item:
                    item.is_retry = True
                    item.retry_count += 1
                    backoff = self._compute_backoff(item.retry_count)
                    item.next_retry_time = time.time() + backoff
            elif category == FirebaseErrorCategory.PERMANENT:
                self.metrics.telemetry_failed_permanent += 1
                self._telemetry_permanent_error = True
                print(f"[TELEMETRY ERROR] Permanent error HTTP {status_code} ({resp_data}). Halting telemetry retries for session.")
                if self._pending_telemetry is item:
                    self._pending_telemetry = None
            else:
                self.metrics.telemetry_failed_transient += 1
                if self._pending_telemetry is item:
                    item.is_retry = True
                    item.retry_count += 1
                    item.next_retry_time = time.time() + self._compute_backoff(item.retry_count)

    def _process_tactical_op(self, op: TacticalOperation):
        success = False
        category = FirebaseErrorCategory.UNKNOWN
        now = time.time()

        if op.op_type == "place":
            type_code = op.indicator_type or "wat"
            branch = "o" if type_code in RadarPlayerSimulator.SQUAD_ORDER_CODES else "i"
            payload = [type_code, op.lat, op.lon, now, op.placed_by or ""]
            status_code, resp_data, category = self._execute_db(
                "PUT", f"t/{op.room_name}/{branch}/{op.indicator_id}.json", payload
            )
            if category == "success":
                success = True

        elif op.op_type == "remove":
            # No category available at this point — delete against both branches
            # unconditionally, matching FirebaseSyncManager.deleteIndicatorFromFirebase.
            status_code, resp_data, category = self._execute_db(
                "DELETE", f"t/{op.room_name}/o/{op.indicator_id}.json"
            )
            self._execute_db("DELETE", f"t/{op.room_name}/i/{op.indicator_id}.json")
            if category in ("success", FirebaseErrorCategory.CONVERGED):
                success = True

        elif op.op_type == "clear":
            status_code, resp_data, category = self._execute_db(
                "DELETE", f"t/{op.room_name}.json"
            )
            if category in ("success", FirebaseErrorCategory.CONVERGED):
                exp = now + RadarPlayerSimulator.ROOM_TTL_SECONDS
                self._execute_db("PUT", f"t/{op.room_name}.json", {"exp": exp})
                success = True

        with self._lock:
            if success or category == FirebaseErrorCategory.CONVERGED:
                self.metrics.tactical_succeeded += 1
                if self._tactical_queue and self._tactical_queue[0] is op:
                    self._tactical_queue.pop(0)
                    self.metrics.tactical_queue_depth = len(self._tactical_queue)
            elif category == FirebaseErrorCategory.PERMANENT:
                self.metrics.tactical_failed_permanent += 1
                print(f"[TACTICAL ERROR] Permanent failure on op {op.op_id}. Removing from queue.")
                if self._tactical_queue and self._tactical_queue[0] is op:
                    self._tactical_queue.pop(0)
                    self.metrics.tactical_queue_depth = len(self._tactical_queue)
            else:
                # Transient error -> retry with backoff
                self.metrics.tactical_failed_transient += 1
                op.retry_count += 1
                op.next_retry_time = time.time() + self._compute_backoff(op.retry_count)

    def _log_periodic_aggregate(self):
        """Prints a concise 30-second aggregate telemetry & tactical metric summary."""
        with self._lock:
            m = self.metrics
            pending_status = "present" if self._pending_telemetry is not None else "empty"
            msg = (
                f"\n📊 [FIREBASE AGGREGATE METRICS] "
                f"Telemetry: {m.telemetry_succeeded}/{m.telemetry_attempted} ok "
                f"(transient err: {m.telemetry_failed_transient}, perm err: {m.telemetry_failed_permanent}, replaced: {m.telemetry_pending_replaced}) | "
                f"Pending: {pending_status} | "
                f"Tactical Queue: {m.tactical_queue_depth} depth, {m.tactical_succeeded} ok, {m.tactical_failed_transient} retry | "
                f"Reads: {m.read_operations} | Streams/Listeners: {m.listener_or_stream_operations}"
            )
        print(msg)


# MARK: - RadarPlayerSimulator
class RadarPlayerSimulator:
    """
    Simulates a single squad member connected to RadarMap Firebase Realtime Database.
    
    Supports:
    - Lean 4-element compact array telemetry ([lat, lng, hr, ts])
    - Extended 6-element and 7-element legacy telemetry formats
    - Hosting & joining rooms with case-insensitive IDs and SHA-256 PIN security
    - Real-time geodesic bearing & Course Over Ground (COG) calculation
    - Placing and clearing Tactical Indicators (Squad Orders & Enemy Indicators)
    - Constant bandwidth rate adaptation R_max(P) = R_base * min(1.0, N / P)
    - Biometrics & KIA / Downed state simulation (HR = 0.0 BPM)
    - Dead reckoning & delta gating with heartbeat fallback
    """

    # Constants matching AppConstants.swift
    DEFAULT_DATABASE_URL = "https://radarmap-8adf0-default-rtdb.firebaseio.com"
    METERS_PER_DEG_LAT = 111139.0
    CONSTANT_BANDWIDTH_PLAYER_THRESHOLD = 12
    BASELINE_MAX_UPDATE_RATE_HZ = 1.0
    MIN_DISPLACEMENT_FOR_COG_METERS = 2.0
    FREE_TIER_MAX_CAPACITY = 4
    PRO_TIER_MAX_CAPACITY = 12
    FREE_TIER_MAX_TACTICAL_INDICATORS = 0
    PRO_TIER_MAX_TACTICAL_INDICATORS = 20
    MAX_PIN_LENGTH = 16
    MIN_PIN_LENGTH = 4
    MAX_ROOM_NAME_LENGTH = 16
    MAX_ROOM_NAME_ENTRY_LENGTH = 12
    MIN_ROOM_NAME_ENTRY_LENGTH = 4
    ROOM_TTL_SECONDS = 12.0 * 3600.0  # 12-hour idle cutoff (see CLOUD_DATA_MANAGEMENT.md)
    ROOM_PADDING_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
    # Squad-order 3-letter codes — these self-prune under /t/{roomId}/o and never share the
    # enemy+environment cap under /t/{roomId}/i (see CLOUD_DATA_MANAGEMENT.md).
    SQUAD_ORDER_CODES = frozenset({
        "wat", "goh", "atk", "def", "flg",
        "pt1", "pt2", "pt3", "pt4", "pt5", "pt6", "pt7", "pt8", "pt9", "p10",
    })

    # Tactical Indicator types
    SQUAD_ORDERS = ["watchHere", "goHere", "attackHere"]
    ENEMY_INDICATORS = ["infantry", "lightVehicle", "heavyVehicle"]

    def __init__(
        self,
        callsign: str = "VIPER-1",
        room_name: str = "ALPHA",
        pin: Optional[str] = None,
        latitude: float = 37.785834,
        longitude: float = -122.406417,
        altitude: Optional[float] = None,
        heart_rate: float = 85.0,
        circle_radius_meters: float = 50.0,
        speed_mps: float = 3.0,
        update_interval_sec: float = 1.0,
        database_url: str = DEFAULT_DATABASE_URL,
        credentials_path: Optional[str] = None,
        member_id: Optional[str] = None,
        color_hex: str = "#00FF66",
        telemetry_format: str = "compact4",  # "compact4", "compact6", "compact7", or "dict"
        enable_delta_gating: bool = False,
        min_movement_delta_meters: float = 3.5,
        min_hr_delta_bpm: float = 12.0,
        heartbeat_interval_sec: float = 10.0,
        coordinator: Optional[FirebaseUploadCoordinator] = None,
    ):
        self.callsign = callsign.strip()
        # Plain user-entered name (<=12 chars) — the Firebase path key is the derived `room_id`
        # below, not this. See CLOUD_DATA_MANAGEMENT.md.
        self.room_name = room_name.strip().upper()[:self.MAX_ROOM_NAME_ENTRY_LENGTH]
        self.pin = self.sanitize_pin(pin) if pin else ""
        if len(self.pin) < self.MIN_PIN_LENGTH:
            raise ValueError(
                f"PIN is mandatory and must be at least {self.MIN_PIN_LENGTH} digits "
                "(see CLOUD_DATA_MANAGEMENT.md) — pass pin=... with >= 4 digits."
            )
        self.max_tactical_indicators = self.PRO_TIER_MAX_TACTICAL_INDICATORS
        self.room_id = self.room_name + self.derive_room_padding(self.pin, self.room_name)
        self.center_lat = latitude
        self.center_lon = longitude
        self.altitude = altitude
        self.heart_rate = heart_rate
        self.radius = max(0.1, circle_radius_meters)
        self.speed = max(0.0, speed_mps)
        self.update_interval = max(0.1, update_interval_sec)
        self.database_url = database_url.rstrip("/")
        self.member_id = (member_id or f"sim_{uuid.uuid4().hex[:8]}").strip()
        self.color_hex = color_hex
        self.telemetry_format = telemetry_format

        # Dedicated Upload Coordinator (only resolves/validates credentials when this instance
        # creates its own coordinator — a shared coordinator passed in already has them)
        self.coordinator = coordinator or FirebaseUploadCoordinator(
            self.database_url, resolve_firebase_credentials_path(credentials_path)
        )
        self._owns_coordinator = coordinator is None

        # State tracking
        self.is_host = False
        self.is_connected = False
        self.is_running = False
        self.sequence_number = 0
        self.current_angle_rad = 0.0
        self.last_sent_lat: Optional[float] = None
        self.last_sent_lon: Optional[float] = None
        self.last_sent_hr: Optional[float] = None
        self.last_sent_time: float = 0.0
        
        # Delta gating parameters
        self.enable_delta_gating = enable_delta_gating
        self.min_movement_delta_meters = min_movement_delta_meters
        self.min_hr_delta_bpm = min_hr_delta_bpm
        self.heartbeat_interval_sec = heartbeat_interval_sec

        # 3-letter tactical type codes mapping
        self.type_codes = {
            "watchHere": "wat", "goHere": "goh", "attackHere": "atk", "protectHere": "def", "flag": "flg",
            "point1": "pt1", "point2": "pt2", "point3": "pt3", "point4": "pt4", "point5": "pt5",
            "point6": "pt6", "point7": "pt7", "point8": "pt8", "point9": "pt9", "point10": "p10",
            "infantry": "inf", "vehicle": "veh", "lightVehicle": "veh", "armor": "arm", "heavyVehicle": "arm", "drone": "drn",
            "water": "wtr", "hazard": "haz", "fire": "fir", "snow": "snw", "closure": "cls", "emergency": "emg"
        }

    @staticmethod
    def sanitize_pin(pin: str) -> str:
        """Sanitizes PIN input, filtering digits up to MAX_PIN_LENGTH characters matching GameStateManager."""
        digits = [c for c in pin if c.isdigit()]
        return "".join(digits[:RadarPlayerSimulator.MAX_PIN_LENGTH])

    @staticmethod
    def hash_pin(pin: str, salt: str) -> str:
        """Computes SHA-256 hash matching FirebaseSyncManager: salt:pin"""
        sanitized = RadarPlayerSimulator.sanitize_pin(pin)
        if not sanitized:
            return ""
        combined = f"{salt}:{sanitized}"
        return hashlib.sha256(combined.encode("utf-8")).hexdigest()

    @staticmethod
    def derive_room_padding(pin: str, name: str, length: int = None) -> str:
        """Derives the room-id padding suffix matching FirebaseSyncManager.deriveRoomPadding —
        domain-separated from hash_pin via the "roompad:" prefix. Padding fills the remainder of
        MAX_ROOM_NAME_LENGTH (16) so the total room id is always 16 chars. See
        CLOUD_DATA_MANAGEMENT.md."""
        alphabet = RadarPlayerSimulator.ROOM_PADDING_ALPHABET
        pad_length = length if length is not None else max(0, RadarPlayerSimulator.MAX_ROOM_NAME_LENGTH - len(name))
        combined = f"roompad:{name}:{pin}"
        digest = hashlib.sha256(combined.encode("utf-8")).digest()
        return "".join(alphabet[b % len(alphabet)] for b in digest[:pad_length])

    # MARK: - Rate Adaptation Equations
    @staticmethod
    def solve_max_update_rate_hz(
        player_count: int,
        player_threshold: int = CONSTANT_BANDWIDTH_PLAYER_THRESHOLD,
        baseline_rate_hz: float = BASELINE_MAX_UPDATE_RATE_HZ,
    ) -> float:
        """
        Solves for the maximum update rate (in Hz) given active player count:
        R_max(P) = R_base * (N_threshold / max(1, P))^2 for P > N_threshold
        """
        if player_count <= 0:
            return baseline_rate_hz
        if player_count <= player_threshold:
            return baseline_rate_hz
        ratio = float(player_threshold) / float(player_count)
        return baseline_rate_hz * (ratio * ratio)

    @staticmethod
    def solve_update_interval(
        player_count: int,
        player_threshold: int = CONSTANT_BANDWIDTH_PLAYER_THRESHOLD,
        baseline_rate_hz: float = BASELINE_MAX_UPDATE_RATE_HZ,
    ) -> float:
        """Solves for update interval in seconds corresponding to solve_max_update_rate_hz."""
        rate_hz = RadarPlayerSimulator.solve_max_update_rate_hz(
            player_count=player_count,
            player_threshold=player_threshold,
            baseline_rate_hz=baseline_rate_hz,
        )
        return 1.0 / rate_hz if rate_hz > 0 else (1.0 / baseline_rate_hz)

    # MARK: - Geodesic Navigation
    @staticmethod
    def calculate_bearing(start_lat: float, start_lon: float, end_lat: float, end_lon: float) -> float:
        """
        Calculates forward geodesic bearing / Course Over Ground (0 - 360 degrees)
        from start coordinate to end coordinate matching FirebaseSyncManager.calculateBearing.
        """
        deg_to_rad = math.pi / 180.0
        rad_to_deg = 180.0 / math.pi
        
        lat1 = start_lat * deg_to_rad
        lon1 = start_lon * deg_to_rad
        lat2 = end_lat * deg_to_rad
        lon2 = end_lon * deg_to_rad
        
        d_lon = lon2 - lon1
        y = math.sin(d_lon) * math.cos(lat2)
        x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(d_lon)
        radians_bearing = math.atan2(y, x)
        
        degrees = radians_bearing * rad_to_deg
        return (degrees + 360.0) % 360.0

    @staticmethod
    def distance_between_meters(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
        """Computes approximate distance in meters between two coordinates."""
        d_lat = (lat2 - lat1) * RadarPlayerSimulator.METERS_PER_DEG_LAT
        lat_rad = math.radians((lat1 + lat2) / 2.0)
        d_lon = (lon2 - lon1) * RadarPlayerSimulator.METERS_PER_DEG_LAT * math.cos(lat_rad)
        return math.hypot(d_lat, d_lon)

    # MARK: - Database Request Helper
    def _http_request(self, method: str, path: str, data: Optional[Any] = None) -> Tuple[int, Any]:
        """Performs a Realtime Database operation via the coordinator's firebase-admin SDK
        connection (kept as a thin wrapper so every call site below is unchanged)."""
        status_code, res_data, _ = self.coordinator._execute_db(method, path, data)
        return status_code, res_data

    # MARK: - Trajectory Math
    def calculate_position(self, delta_time: float) -> Tuple[float, float, float]:
        """
        Advances position along the circular orbit based on delta_time and speed.
        Returns: (latitude, longitude, heading_degrees)
        """
        omega = self.speed / self.radius
        self.current_angle_rad = (self.current_angle_rad + omega * delta_time) % (2.0 * math.pi)

        offset_east = self.radius * math.cos(self.current_angle_rad)
        offset_north = self.radius * math.sin(self.current_angle_rad)

        lat_rad = math.radians(self.center_lat)
        meters_per_deg_lon = self.METERS_PER_DEG_LAT * math.cos(lat_rad)
        if meters_per_deg_lon == 0:
            meters_per_deg_lon = 1.0

        current_lat = self.center_lat + (offset_north / self.METERS_PER_DEG_LAT)
        current_lon = self.center_lon + (offset_east / meters_per_deg_lon)

        # Velocity tangent vector
        v_east = -math.sin(self.current_angle_rad)
        v_north = math.cos(self.current_angle_rad)

        heading_rad = math.atan2(v_east, v_north)
        heading_deg = (math.degrees(heading_rad) + 360.0) % 360.0

        return current_lat, current_lon, heading_deg

    # MARK: - Room Management
    def host_room(self, max_capacity: int = PRO_TIER_MAX_CAPACITY, overwrite: bool = True) -> bool:
        """Creates a new squad room on Firebase as Host matching SquadRoom schema and TTL policy."""
        now = time.time()
        expire_at = now + self.ROOM_TTL_SECONDS
        pin_hash = self.hash_pin(self.pin, self.room_id)

        # Check if room already exists
        if not overwrite:
            status, existing = self._http_request("GET", f"r/{self.room_id}.json")
            if status == 200 and existing and isinstance(existing, dict) and existing.get("id"):
                print(f"[ERROR] Room '{self.room_id}' already exists. Use join_room() or choose another room name/PIN, or pass overwrite=True.")
                return False

        host_member = {
            "mid": self.member_id,
            "csn": self.callsign,
            "rol": "leader"
        }

        room_payload = {
            "id": self.room_id,
            "hst": self.member_id,
            "cap": max_capacity,
            "mti": self.max_tactical_indicators,
            "pin": pin_hash,
            "exp": expire_at,
            "m": {
                self.member_id: host_member
            }
        }

        # 1. Create/overwrite room node first so Firebase rules grant authorization for subnodes
        status, resp = self._http_request("PUT", f"r/{self.room_id}.json", room_payload)
        if not (200 <= status < 300):
            print(f"[ERROR] Failed to create room: HTTP {status} - {resp}")
            return False

        # 2. Reset/initialize subrooms with a clean TTL expiry
        self._http_request("PUT", f"p/{self.room_id}.json", {"exp": expire_at})
        self._http_request("PUT", f"t/{self.room_id}.json", {"exp": expire_at})

        self.coordinator.reset_session()
        self.is_host = True
        self.is_connected = True
        print(f"[SUCCESS] Hosted room '{self.room_id}' (name '{self.room_name}') as '{self.callsign}' (Host: Yes, TTL: 12h, refreshed hourly while active).")
        return True

    def join_room(self) -> bool:
        """Joins an existing squad room on Firebase."""
        status, room_data = self._http_request("GET", f"r/{self.room_id}.json")

        if status != 200 or not room_data or not isinstance(room_data, dict):
            print(f"[ERROR] Room '{self.room_id}' not found on server (wrong name or PIN both derive a miss — see CLOUD_DATA_MANAGEMENT.md).")
            return False

        # Validate PIN (mandatory — see CLOUD_DATA_MANAGEMENT.md)
        expected_pin_hash = room_data.get("pin", "")
        input_hash = self.hash_pin(self.pin, self.room_id)
        if input_hash != expected_pin_hash:
            print(f"[ERROR] Incorrect PIN for room '{self.room_id}'.")
            return False

        # Validate Callsign uniqueness
        members = room_data.get("m", {}) or {}
        trimmed_callsign = self.callsign.upper()
        for mid, mdata in members.items():
            if mid != self.member_id and isinstance(mdata, dict):
                if mdata.get("csn", "").strip().upper() == trimmed_callsign:
                    print(f"[ERROR] Callsign '{self.callsign}' is already taken in room '{self.room_id}'.")
                    return False

        # Validate capacity
        max_cap = room_data.get("cap", self.PRO_TIER_MAX_CAPACITY)
        if len(members) >= max_cap and self.member_id not in members:
            print(f"[ERROR] Room '{self.room_id}' has reached maximum capacity ({max_cap}).")
            return False

        member_payload = {
            "mid": self.member_id,
            "csn": self.callsign,
            "rol": "player"
        }

        status, resp = self._http_request("PUT", f"r/{self.room_id}/m/{self.member_id}.json", member_payload)
        if 200 <= status < 300:
            self.coordinator.reset_session()
            self.is_host = False
            self.is_connected = True
            print(f"[SUCCESS] Joined room '{self.room_id}' as '{self.callsign}'.")
            return True
        else:
            print(f"[ERROR] Failed to register member: HTTP {status} - {resp}")
            return False

    # MARK: - Telemetry Dispatch
    def should_suppress_update(self, lat: float, lon: float, hr: float, now: float) -> bool:
        """Implements Dead Reckoning & Delta Gating matching AppConstants.Timing.DeltaGating."""
        if not self.enable_delta_gating:
            return False

        # If heartbeat interval exceeded, must send update
        if self.last_sent_time > 0 and (now - self.last_sent_time) >= self.heartbeat_interval_sec:
            return False

        # First update always sent
        if self.last_sent_lat is None or self.last_sent_lon is None or self.last_sent_hr is None:
            return False

        # Check movement delta
        distance_moved = self.distance_between_meters(self.last_sent_lat, self.last_sent_lon, lat, lon)
        hr_delta = abs(self.heart_rate - self.last_sent_hr)

        if distance_moved < self.min_movement_delta_meters and hr_delta < self.min_hr_delta_bpm:
            return True  # Suppress upload (gated)

        return False

    def send_telemetry(self, lat: float, lon: float, hdg: float, altitude: Optional[float] = None) -> bool:
        """
        Submits telemetry packet to FirebaseUploadCoordinator.
        Uses 4-element compact array (default), 6-element, 7-element, or dict formats.
        """
        now = time.time()
        self.sequence_number += 1
        alt = altitude if altitude is not None else self.altitude

        # Construct payload based on telemetry_format
        if self.telemetry_format == "compact4":
            # Primary ultra-lean 4-element format: [lat, lng, hr, ts]
            payload = [lat, lon, self.heart_rate, now]
        elif self.telemetry_format == "compact6":
            # 6-element format: [lat, lng, alt, hr, seq, ts]
            payload = [lat, lon, alt if alt is not None else 0.0, self.heart_rate, self.sequence_number, now]
        elif self.telemetry_format == "compact7":
            # 7-element legacy format: [lat, lng, alt, hdg, hr, seq, ts]
            payload = [lat, lon, alt if alt is not None else 0.0, hdg, self.heart_rate, self.sequence_number, now]
        else:
            # JSON dictionary format
            payload = {
                "lat": lat,
                "lng": lon,
                "hdg": hdg,
                "hr": self.heart_rate,
                "seq": self.sequence_number,
                "ts": now
            }
            if alt is not None:
                payload["alt"] = alt

        self.coordinator.submit_telemetry(self.room_id, self.member_id, payload)
        self.last_sent_lat = lat
        self.last_sent_lon = lon
        self.last_sent_hr = self.heart_rate
        self.last_sent_time = now
        return True

    def place_tactical_indicator(self, indicator_type: str, lat: float, lon: float, indicator_id: Optional[str] = None) -> Optional[str]:
        """
        Enqueues placing a tactical indicator on the server at /t/{roomId}/o/{indicatorId} (squad
        orders) or /t/{roomId}/i/{indicatorId} (enemy+environment, shared cap) using the compact
        5-element array format: [type_code, lat, lon, ts, placed_by]. See CLOUD_DATA_MANAGEMENT.md.
        """
        ind_id = indicator_id or f"ind_{uuid.uuid4().hex[:8]}"
        type_code = self.type_codes.get(indicator_type, indicator_type)

        op = TacticalOperation(
            op_id=str(uuid.uuid4().hex[:8]),
            op_type="place",
            room_name=self.room_id,
            indicator_id=ind_id,
            indicator_type=type_code,
            lat=lat,
            lon=lon,
            placed_by=self.member_id
        )
        enqueued = self.coordinator.submit_tactical_op(op)
        if enqueued:
            print(f"[TACTICAL] Enqueued compact indicator '{type_code}' ({ind_id}) placed by '{self.member_id}' at ({lat:.6f}, {lon:.6f}).")
            return ind_id
        return None

    def remove_tactical_indicator(self, indicator_id: str) -> bool:
        """Enqueues deleting a tactical indicator (idempotent)."""
        op = TacticalOperation(
            op_id=str(uuid.uuid4().hex[:8]),
            op_type="remove",
            room_name=self.room_id,
            indicator_id=indicator_id
        )
        return self.coordinator.submit_tactical_op(op)

    def clear_all_tactical_indicators(self) -> bool:
        """Enqueues purging all tactical indicators in the room while preserving the TTL expiry."""
        op = TacticalOperation(
            op_id=str(uuid.uuid4().hex[:8]),
            op_type="clear",
            room_name=self.room_id
        )
        return self.coordinator.submit_tactical_op(op)

    def get_tactical_indicators(self) -> Dict[str, Any]:
        """Fetches active tactical indicators (both squad-order and capped branches) from the server."""
        status, data = self._http_request("GET", f"t/{self.room_id}.json")
        if status == 200 and isinstance(data, dict):
            orders = data.get("o", {}) if isinstance(data.get("o"), dict) else {}
            capped = data.get("i", {}) if isinstance(data.get("i"), dict) else {}
            return {**orders, **capped}
        return {}

    # MARK: - Biometrics & Player State
    def set_heart_rate(self, bpm: float):
        """Updates simulated heart rate (0.0 BPM simulates Downed / KIA)."""
        self.heart_rate = bpm
        state = "DOWNED / KIA" if bpm == 0.0 else f"{bpm:.0f} BPM"
        print(f"[BIOMETRICS] Heart rate updated to {state}.")

    def set_downed(self, downed: bool = True):
        """Quick toggle for KIA / Downed state."""
        self.set_heart_rate(0.0 if downed else 85.0)

    def refresh_room_expiry(self):
        """Refreshes this room's TTL expiry across all three top-level trees, matching
        FirebaseSyncManager.refreshRoomExpiry — keeps a long-running simulated room alive under
        the new 12h idle cutoff. See CLOUD_DATA_MANAGEMENT.md."""
        if not self.is_connected or not self.room_id:
            return
        new_expire_at = time.time() + self.ROOM_TTL_SECONDS
        self._http_request("PUT", f"r/{self.room_id}/exp.json", new_expire_at)
        self._http_request("PUT", f"p/{self.room_id}/exp.json", new_expire_at)
        self._http_request("PUT", f"t/{self.room_id}/exp.json", new_expire_at)

    # MARK: - Room Cleanup & Leave
    def leave_room(self):
        """Leaves the room and cleans up Firebase entries matching FirebaseSyncManager."""
        if not self.is_connected:
            return

        print(f"\n[INFO] Leaving room '{self.room_id}'...")
        if self.is_host:
            # Host disbanding room: delete telemetry and tactical nodes first, then room node
            self._http_request("DELETE", f"p/{self.room_id}.json")
            self._http_request("DELETE", f"t/{self.room_id}.json")
            self._http_request("DELETE", f"r/{self.room_id}.json")
            print(f"[SUCCESS] Disbanded room '{self.room_id}' and purged all nodes.")
        else:
            # Check remaining members
            status, room_data = self._http_request("GET", f"r/{self.room_id}.json")
            members = (room_data.get("m", {}) if isinstance(room_data, dict) else {}) or {}
            remaining = [m for m in members if m != self.member_id]

            self._http_request("DELETE", f"r/{self.room_id}/m/{self.member_id}.json")
            self._http_request("DELETE", f"p/{self.room_id}/{self.member_id}.json")

            # Remove this player's own squad-order markers (compact array format; no
            # dictionary-shaped guard — mirrors the FirebaseSyncManager fix in CLOUD_DATA_MANAGEMENT.md)
            t_status, t_data = self._http_request("GET", f"t/{self.room_id}/o.json")
            if t_status == 200 and isinstance(t_data, dict):
                for ind_id, arr in t_data.items():
                    if isinstance(arr, list) and len(arr) >= 5 and str(arr[4]) == self.member_id:
                        self._http_request("DELETE", f"t/{self.room_id}/o/{ind_id}.json")

            if not remaining:
                # Room now empty: delete telemetry and tactical nodes first, then room node
                self._http_request("DELETE", f"p/{self.room_id}.json")
                self._http_request("DELETE", f"t/{self.room_id}.json")
                self._http_request("DELETE", f"r/{self.room_id}.json")
                print(f"[SUCCESS] Room '{self.room_id}' is now empty. Purged entire room and tactical nodes.")
            else:
                print(f"[SUCCESS] Removed player '{self.callsign}' and associated team orders from room '{self.room_id}'.")

        self.coordinator.reset_session()
        self.is_connected = False
        self.is_running = False

    def shutdown(self):
        """Clean shutdown of coordinator and resources."""
        if self._owns_coordinator:
            self.coordinator.close()

    # MARK: - Main Simulation Loop
    def run_simulation(self, duration_sec: Optional[float] = None):
        """
        Starts circular telemetry simulation loop.
        Updates position in a circle at `speed` m/s with `radius` meters,
        broadcasting telemetry every `update_interval` seconds.
        """
        if not self.is_connected:
            print("[ERROR] Must host or join a room before running simulation.")
            return

        self.is_running = True
        start_time = time.time()
        last_tick = start_time
        ticks = 0

        print(f"\n🚀 Simulation started for player '{self.callsign}' in room '{self.room_name}'!")
        print(f"📍 Center: ({self.center_lat:.6f}, {self.center_lon:.6f})")
        print(f"🔄 Radius: {self.radius:.1f} m | Speed: {self.speed:.1f} m/s | Interval: {self.update_interval:.1f}s")
        print(f"❤️ Heart Rate: {self.heart_rate:.0f} BPM | Format: {self.telemetry_format}")
        print("Press Ctrl+C or Interrupt Kernel to stop...\n")

        try:
            while self.is_running:
                now = time.time()
                elapsed = now - start_time
                if duration_sec is not None and elapsed >= duration_sec:
                    print(f"\n⏱️ Reached duration limit ({duration_sec}s). Stopping simulation.")
                    break

                dt = now - last_tick
                last_tick = now

                lat, lon, hdg = self.calculate_position(dt)

                if self.should_suppress_update(lat, lon, self.heart_rate, now):
                    status_mark = "⚡"  # Gated / Delta suppressed
                else:
                    self.send_telemetry(lat, lon, hdg)
                    status_mark = "✅"

                ticks += 1
                if ticks % 10 == 0:
                    self.refresh_room_expiry()

                print(
                    f"\r{status_mark} [T+{elapsed:6.1f}s] Lat: {lat:10.6f} | Lon: {lon:11.6f} | "
                    f"Hdg: {hdg:5.1f}° | HR: {self.heart_rate:3.0f} BPM | Seq: {self.sequence_number:<5}",
                    end="",
                    flush=True
                )

                time.sleep(self.update_interval)

        except KeyboardInterrupt:
            print("\n\n⏹️ Simulation interrupted by user.")
        finally:
            self.is_running = False
            print(f"\nCompleted {self.sequence_number} telemetry updates.")


def main():
    import argparse

    parser = argparse.ArgumentParser(description="RadarMap Player Simulator")
    parser.add_argument("--mode", choices=["host", "join"], default="host", help="Host a new room or join existing")
    parser.add_argument("--callsign", default="VIPER-1", help="Player callsign")
    parser.add_argument("--room", default="ALPHA", help="Room name")
    parser.add_argument("--pin", required=True, help="Mandatory PIN, 4-16 digits (see CLOUD_DATA_MANAGEMENT.md)")
    parser.add_argument("--lat", type=float, default=37.785834, help="Center latitude")
    parser.add_argument("--lon", type=float, default=-122.406417, help="Center longitude")
    parser.add_argument("--hr", type=float, default=110.0, help="Heart rate BPM")
    parser.add_argument("--radius", type=float, default=40.0, help="Circle radius in meters")
    parser.add_argument("--speed", type=float, default=4.0, help="Speed in m/s")
    parser.add_argument("--interval", type=float, default=1.0, help="Update interval in seconds")
    parser.add_argument("--format", choices=["compact4", "compact6", "compact7", "dict"], default="compact4", help="Telemetry format")
    parser.add_argument("--duration", type=float, default=None, help="Run duration in seconds (optional)")
    parser.add_argument(
        "--credentials",
        default=None,
        help=(
            "Path to a Firebase service-account JSON key (or set the FIREBASE_CREDENTIALS "
            "environment variable instead)."
        ),
    )

    args = parser.parse_args()
    credentials_path = resolve_firebase_credentials_path(args.credentials)

    sim = RadarPlayerSimulator(
        callsign=args.callsign,
        room_name=args.room,
        pin=args.pin,
        latitude=args.lat,
        longitude=args.lon,
        heart_rate=args.hr,
        circle_radius_meters=args.radius,
        speed_mps=args.speed,
        update_interval_sec=args.interval,
        telemetry_format=args.format,
        credentials_path=credentials_path,
    )

    try:
        success = sim.host_room() if args.mode == "host" else sim.join_room()
        if success:
            sim.run_simulation(duration_sec=args.duration)
    finally:
        sim.leave_room()
        sim.shutdown()


if __name__ == "__main__":
    main()
