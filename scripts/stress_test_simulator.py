#!/usr/bin/env python3
"""
RadarMap Stress Test Python Simulator
Simulates multi-player tactical squads (up to 12 players) simultaneously in a single process.
Obays all iOS / watchOS cloud data management behavior:
- Endpoints: /r (roster), /p (telemetry), /t/o (squad orders), /t/i (tactical indicators)
- Telemetry format: compact 4-element array [lat, lon, hr, ts]
- Tactical format: compact 5-element array [type_code, lat, lon, ts, member_id]
- Security: Salted SHA-256 PIN hash, Crockford Base32 8-character Member IDs, 16-char padded room IDs
- Cloud Scheduling Policy 1: Tactical writes are Durable Queue-All / Must-Arrive
- Cloud Scheduling Policy 2: Telemetry writes are Latest-Only / Drop-Old with single-slot coalescing
- Dead Reckoning & Delta Gating: Suppresses stationary uploads (< 3.5m, < 12 BPM) with fallback heartbeat (10xT)
- Bandwidth Rate Adaptation: Scales update interval R_max(P) = 1.0 * min(1.0, 12 / P)
- Inactivity TTL: 12-hour idle cutoff (idleCutoffHours) refreshed hourly while active
- Airsoft Tactical Movement: Distance-based movement bounds (15-40m) without microsecond jitter
- Random tactical marker placement on stop
"""

import argparse
import glob
import hashlib
import json
import math
import os
import random
import re
import sys
import threading
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple

# Attempt to import firebase_admin
try:
    import firebase_admin
    from firebase_admin import credentials as firebase_credentials
    from firebase_admin import db as firebase_db
    from firebase_admin import exceptions as firebase_exceptions
    HAS_FIREBASE = True
except ImportError:
    HAS_FIREBASE = False

# Attempt to import cryptography (only required when --encrypted / PlayerSpec.encrypted is used)
try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    import base64
    HAS_CRYPTO = True
except ImportError:
    HAS_CRYPTO = False

# AppConstants.swift & database.rules.json Cloud Constants
METERS_PER_DEG_LAT = 111139.0
DEFAULT_DATABASE_URL = "https://radarmap-8adf0-default-rtdb.firebaseio.com"
MAX_ROOM_NAME_ENTRY_LENGTH = 12
MAX_ROOM_NAME_LENGTH = 16
MAX_PIN_LENGTH = 16
ROOM_PADDING_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
MEMBER_ID_LENGTH = 8
# Matches AppConstants.UI.pinWordMapping exactly — see sanitize_pin.
PIN_WORD_MAPPING = {
    "zero": "0", "oh": "0",
    "one": "1", "won": "1",
    "two": "2", "to": "2", "too": "2",
    "three": "3",
    "four": "4", "for": "4", "fore": "4",
    "five": "5",
    "six": "6",
    "seven": "7",
    "eight": "8", "ate": "8",
    "nine": "9",
}
IDLE_CUTOFF_HOURS = 12.0
ROOM_TTL_SECONDS = IDLE_CUTOFF_HOURS * 3600.0  # 12-hour idle cutoff
MAX_TACTICAL_INDICATORS_CAP = 20  # Pro tier cap on /t/{roomId}/i

# Delta Gating & Constant Bandwidth Constants (CLOUD_DATA_MANAGEMENT.md §2 & §4)
MAX_PREDICTED_POSITION_ERROR_METERS = 3.5  # Position delta gate threshold
MIN_HEART_RATE_DELTA_BPM = 12.0           # Biometric delta gate threshold
PLAYER_BANDWIDTH_THRESHOLD = 12           # P threshold for rate scaling
BASELINE_UPDATE_RATE_HZ = 1.0             # 1.0 Hz base rate
REFRESH_HEARTBEAT_MULTIPLIER = 10.0       # Fallback heartbeat (10 x T)
DEFAULT_SIMULATION_DURATION_SEC = 600.0   # Default 10-minute simulation time limit

# Centralized tactical 3-letter codes
SQUAD_ORDER_CODES = {
    "watchHere": "wat",
    "goHere": "goh",
    "attackHere": "atk",
    "protectHere": "def",
    "flag": "flg",
    "point1": "pt1",
    "point2": "pt2",
    "point3": "pt3",
}

ENEMY_AND_ENV_CODES = {
    "infantry": "inf",
    "vehicle": "veh",
    "armor": "arm",
    "drone": "drn",
    "hazard": "haz",
    "closure": "cls",
}

ALL_MARKER_TYPES = list(SQUAD_ORDER_CODES.keys()) + list(ENEMY_AND_ENV_CODES.keys())


# MARK: - Credentials Auto-Discovery
def resolve_firebase_credentials_path(explicit_path: Optional[str] = None) -> Optional[str]:
    """
    Resolves Firebase service account credentials with auto-discovery:
    1. Explicit path parameter
    2. FIREBASE_CREDENTIALS environment variable
    3. Known candidate locations (credentials/*.json, notebooks/credentials/*.json)
    """
    if explicit_path and os.path.isfile(explicit_path):
        return os.path.abspath(explicit_path)

    env_path = os.environ.get("FIREBASE_CREDENTIALS")
    if env_path and os.path.isfile(env_path):
        return os.path.abspath(env_path)

    # Search standard repository locations relative to this file or cwd
    base_dirs = [
        os.path.abspath("."),
        os.path.abspath(os.path.dirname(__file__)),
        os.path.abspath(os.path.join(os.path.dirname(__file__), "..")),
    ]

    for b in base_dirs:
        patterns = [
            os.path.join(b, "credentials", "*.json"),
            os.path.join(b, "notebooks", "credentials", "*.json"),
        ]
        for pat in patterns:
            matches = glob.glob(pat)
            for m in matches:
                if os.path.isfile(m):
                    return os.path.abspath(m)

    return None


# MARK: - Cryptographic & Formatting Helpers
def sanitize_room_name(name: str) -> str:
    """Matches GameStateManager.sanitizeRoomNameInput: ASCII alphanumerics only, uppercased,
    truncated. No fallback default — an empty result after sanitizing means the caller passed
    an empty/all-invalid name, and should surface that rather than silently substituting a
    placeholder room name that would mismatch every other client's expectations."""
    cleaned = "".join([c for c in name if c.isascii() and c.isalnum()]).upper()
    return cleaned[:MAX_ROOM_NAME_ENTRY_LENGTH]


def sanitize_pin(pin: str) -> str:
    """Sanitizes PIN input matching GameStateManager.sanitizePinInput bug-for-bug: lowercases,
    splits on non-alphanumeric boundaries, maps a whole token to a digit via PIN_WORD_MAPPING
    (spoken-word dictation, e.g. "four" -> "4"), and otherwise keeps only the decimal digits
    within that token — a token with letters that isn't a recognized word has those letters
    dropped, not kept, matching the Swift implementation exactly so a dictated or typed PIN
    hashes identically in both. No fallback default — see sanitize_room_name."""
    lowered = pin.lower()
    tokens = re.split(r"[^a-z0-9]+", lowered)
    result_parts = []
    for token in tokens:
        mapped = PIN_WORD_MAPPING.get(token)
        if mapped is not None:
            result_parts.append(mapped)
        else:
            result_parts.append("".join(c for c in token if c.isdigit()))
    return "".join(result_parts)[:MAX_PIN_LENGTH]


def derive_room_padding(pin: str, name: str, length: Optional[int] = None) -> str:
    pad_length = length if length is not None else max(0, MAX_ROOM_NAME_LENGTH - len(name))
    combined = f"roompad:{name}:{pin}"
    digest = hashlib.sha256(combined.encode("utf-8")).digest()
    return "".join(ROOM_PADDING_ALPHABET[b % len(ROOM_PADDING_ALPHABET)] for b in digest[:pad_length])


def derive_room_id(name: str, pin: str) -> str:
    """The single combining function for the room id — matching
    FirebaseSyncManager.deriveRoomId(name:pin:). Every call site that owns a plain room name
    must go through this rather than inlining `name + derive_room_padding(...)`, so the id (and
    everything salted from it: pin_hash, derive_telemetry_key) can't drift between call sites.
    See CLOUD_DATA_MANAGEMENT.md §7.A."""
    return name + derive_room_padding(pin, name)


def hash_pin(pin: str, salt: str) -> str:
    """Matches FirebaseSyncManager.hashPin: hashes the PIN as given (already-sanitized by the
    caller), not re-sanitized here — see CLOUD_DATA_MANAGEMENT.md §6.B."""
    trimmed = pin.strip()
    if not trimmed:
        return ""
    combined = f"{salt}:{trimmed}"
    return hashlib.sha256(combined.encode("utf-8")).hexdigest()


def derive_telemetry_key(pin: str, room_id: str) -> bytes:
    """Derives the AES-256 key matching FirebaseSyncManager.deriveTelemetryKey —
    domain-separated from hash_pin ("salt:pin") and derive_room_padding ("roompad:...") via
    the "telemetrykey:" prefix. See docs/CLOUD_DATA_MANAGEMENT.md §5.E."""
    combined = f"telemetrykey:{room_id}:{pin}"
    return hashlib.sha256(combined.encode("utf-8")).digest()


def encrypt_compact_array(array: List[Any], key: bytes) -> str:
    """Encrypts a compact telemetry/tactical array matching CompactArrayCipher.encrypt:
    AES-256-GCM with a fresh random 12-byte nonce, output as base64(nonce + ciphertext + tag)."""
    if not HAS_CRYPTO:
        raise ImportError(
            "cryptography is required for --encrypted. Install it with `pip install cryptography`."
        )
    plaintext = json.dumps(array, separators=(",", ":")).encode("utf-8")
    nonce = os.urandom(12)
    ciphertext = AESGCM(key).encrypt(nonce, plaintext, None)
    return base64.b64encode(nonce + ciphertext).decode("ascii")


def derive_member_id(callsign: str) -> str:
    normalized = callsign.strip().upper()
    combined = f"memberid:{normalized}"
    digest = hashlib.sha256(combined.encode("utf-8")).digest()
    return "".join(ROOM_PADDING_ALPHABET[b % len(ROOM_PADDING_ALPHABET)] for b in digest[:MEMBER_ID_LENGTH])


def distance_between_meters(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    d_lat = (lat2 - lat1) * METERS_PER_DEG_LAT
    lat_rad = math.radians((lat1 + lat2) / 2.0)
    d_lon = (lon2 - lon1) * METERS_PER_DEG_LAT * math.cos(lat_rad)
    return math.hypot(d_lat, d_lon)


# MARK: - Player Specification & Default 10/12 Roster
@dataclass
class PlayerSpec:
    callsign: str
    target_avg_speed_mps: float
    network_quality: int  # 1 (poor) to 5 (best)
    start_lat: Optional[float] = None
    start_lon: Optional[float] = None
    encrypted: bool = False  # Per-player AES-256-GCM encryption of telemetry/tactical arrays
    glance_time_sec: float = 0.0  # Active display glance duration (0 = always active)
    inactivity_time_sec: float = 0.0  # Wrist-down / inactive duration (0 = never inactive)
    telemetry_payload_bytes: int = 200  # Default compact telemetry payload size in bytes
    tactical_payload_bytes: int = 200  # Default tactical marker payload size in bytes


DEFAULT_12_PLAYERS: List[Tuple[str, float, int, bool]] = [
    ("VIPER-1",  4.5, 5, False),   # Lead Scout: 4.5 m/s, ~98% uptime, rock-solid (★★★★★)
    ("VIPER-2",  3.0, 5, False),   # Squad Leader: 3.0 m/s, ~98% uptime, rock-solid (★★★★★)
    ("GHOST-1",  1.5, 4, False),   # Sniper / Recon: 1.5 m/s, ~92% uptime, occasional drop (★★★★☆)
    ("GHOST-2",  2.0, 4, False),   # Spotter: 2.0 m/s, ~92% uptime, occasional drop (★★★★☆)
    ("COBRA-1",  5.0, 3, False),   # Point Assault: 5.0 m/s, ~80% uptime, moderate dropouts (★★★☆☆)
    ("COBRA-2",  3.5, 3, False),   # Support Gunner: 3.5 m/s, ~80% uptime, moderate dropouts (★★★☆☆)
    ("COBRA-3",  2.5, 3, False),   # Breacher: 2.5 m/s, ~80% uptime, moderate dropouts (★★★☆☆)
    ("EAGLE-1",  4.0, 2, False),   # Flanker 1: 4.0 m/s, ~60% uptime, poor cell edge (★★☆☆☆)
    ("EAGLE-2",  3.0, 2, False),   # Flanker 2: 3.0 m/s, ~60% uptime, high packet loss (★★☆☆☆)
    ("WOLF-1",   6.0, 2, False),   # Fast Runner: 6.0 m/s, ~60% uptime, frequent outages (★★☆☆☆)
    ("WOLF-2",   2.0, 1, False),   # Heavy Weapons: 2.0 m/s, ~38% uptime, severe blackouts (★☆☆☆☆)
    ("WOLF-3",   3.5, 1, False),   # Rear Guard: 3.5 m/s, ~38% uptime, harsh terrain drops (★☆☆☆☆)
]

# Backward compatibility alias
DEFAULT_10_PLAYERS = DEFAULT_12_PLAYERS


# MARK: - Network Quality Simulator
@dataclass
class NetworkQualityProfile:
    quality: int
    target_uptime_ratio: float
    mean_connected_duration_sec: float
    mean_disconnected_duration_sec: float


NETWORK_PROFILES: Dict[int, NetworkQualityProfile] = {
    5: NetworkQualityProfile(quality=5, target_uptime_ratio=0.98, mean_connected_duration_sec=90.0, mean_disconnected_duration_sec=2.0),
    4: NetworkQualityProfile(quality=4, target_uptime_ratio=0.92, mean_connected_duration_sec=45.0, mean_disconnected_duration_sec=4.0),
    3: NetworkQualityProfile(quality=3, target_uptime_ratio=0.80, mean_connected_duration_sec=25.0, mean_disconnected_duration_sec=6.0),
    2: NetworkQualityProfile(quality=2, target_uptime_ratio=0.60, mean_connected_duration_sec=15.0, mean_disconnected_duration_sec=10.0),
    1: NetworkQualityProfile(quality=1, target_uptime_ratio=0.38, mean_connected_duration_sec=8.0,  mean_disconnected_duration_sec=13.0),
}


class NetworkQualitySimulator:
    """Simulates intermittent connection breaks based on 1-5 quality rating."""
    def __init__(self, quality: int, start_time: Optional[float] = None):
        self.quality = max(1, min(5, quality))
        self.profile = NETWORK_PROFILES[self.quality]
        self.is_connected = True
        base_time = start_time if start_time is not None else time.time()
        self.next_transition_time = base_time + self._sample_duration(self.profile.mean_connected_duration_sec)
        self.total_connected_time = 0.0
        self.total_disconnected_time = 0.0
        self.disconnect_count = 0
        self._last_tick_time: Optional[float] = start_time

    def _sample_duration(self, mean_duration: float) -> float:
        val = random.expovariate(1.0 / mean_duration)
        return max(0.5, val)

    def tick(self, now: float) -> bool:
        if self._last_tick_time is None:
            self._last_tick_time = now
        dt = max(0.0, now - self._last_tick_time)
        self._last_tick_time = now

        if self.is_connected:
            self.total_connected_time += dt
        else:
            self.total_disconnected_time += dt

        if now >= self.next_transition_time:
            self.is_connected = not self.is_connected
            if not self.is_connected:
                self.disconnect_count += 1
                dur = self._sample_duration(self.profile.mean_disconnected_duration_sec)
            else:
                dur = self._sample_duration(self.profile.mean_connected_duration_sec)
            self.next_transition_time = now + dur

        return self.is_connected

    @property
    def current_uptime_ratio(self) -> float:
        total = self.total_connected_time + self.total_disconnected_time
        return (self.total_connected_time / total) if total > 0 else 1.0


# MARK: - Random Walk & Airsoft Bound Movement Engine
class MovementState:
    STOPPED = "STOPPED"
    WALKING = "WALKING"
    RUNNING = "RUNNING"
    SPRINTING = "SPRINTING"


class RandomWalkController:
    """
    Simulates tactical airsoft movement:
    - Commits to a straight movement bound (15m-40m) without microsecond/per-tick jitter
    - Deliberate tactical pivots upon arriving at cover/bound completion
    - Closed-loop speed regulator forces stops (v = 0.0 m/s) while preserving target average speed
    - Soft leashing to operational perimeter (350m)
    """
    def __init__(
        self,
        center_lat: float,
        center_lon: float,
        target_avg_speed_mps: float,
        operational_radius_meters: float = 350.0,
        min_leg_distance_meters: float = 15.0,
        max_leg_distance_meters: float = 40.0,
    ):
        self.center_lat = center_lat
        self.center_lon = center_lon
        self.current_lat = center_lat + (random.uniform(-25.0, 25.0) / METERS_PER_DEG_LAT)
        self.current_lon = center_lon + (random.uniform(-25.0, 25.0) / (METERS_PER_DEG_LAT * math.cos(math.radians(center_lat))))
        self.target_avg_speed = max(0.2, target_avg_speed_mps)
        self.operational_radius = operational_radius_meters

        self.min_leg_distance = max(2.0, min_leg_distance_meters)
        self.max_leg_distance = max(self.min_leg_distance, max_leg_distance_meters)
        self.current_leg_target_distance = random.uniform(self.min_leg_distance, self.max_leg_distance)
        self.current_leg_traveled_distance = 0.0

        self.current_heading_deg = random.uniform(0.0, 360.0)
        self.state = MovementState.STOPPED
        self.current_speed_mps = 0.0
        self.state_until_time = 0.0

        # Metrics
        self.total_distance_meters = 0.0
        self.total_time_seconds = 0.0
        self.stop_events_count = 0
        self.entered_stop_this_tick = False

    def tick(self, dt: float, now: float) -> Tuple[float, float, float, float, str, bool]:
        self.entered_stop_this_tick = False

        if now >= self.state_until_time:
            self._select_next_state(now)

        if self.current_speed_mps > 0.0 and dt > 0.0:
            step_distance = self.current_speed_mps * dt
            self.total_distance_meters += step_distance
            self.current_leg_traveled_distance += step_distance

            # Boundary tether check
            dist_from_center = distance_between_meters(
                self.center_lat, self.center_lon, self.current_lat, self.current_lon
            )
            if dist_from_center > self.operational_radius:
                return_bearing = self._bearing_to(self.current_lat, self.current_lon, self.center_lat, self.center_lon)
                self.current_heading_deg = (return_bearing + random.uniform(-15.0, 15.0)) % 360.0
                self._start_new_tactical_leg()

            # End of movement bound reached
            elif self.current_leg_traveled_distance >= self.current_leg_target_distance:
                self._pivot_to_next_tactical_leg(now)

            # Move lat/lon along locked heading
            hdg_rad = math.radians(self.current_heading_deg)
            d_north = step_distance * math.cos(hdg_rad)
            d_east = step_distance * math.sin(hdg_rad)

            lat_rad = math.radians(self.current_lat)
            meters_per_lon = METERS_PER_DEG_LAT * math.cos(lat_rad)
            if meters_per_lon == 0:
                meters_per_lon = 1.0

            self.current_lat += d_north / METERS_PER_DEG_LAT
            self.current_lon += d_east / meters_per_lon

        self.total_time_seconds += dt

        return (
            self.current_lat,
            self.current_lon,
            self.current_heading_deg,
            self.current_speed_mps,
            self.state,
            self.entered_stop_this_tick,
        )

    def _start_new_tactical_leg(self):
        self.current_leg_target_distance = random.uniform(self.min_leg_distance, self.max_leg_distance)
        self.current_leg_traveled_distance = 0.0

    def _pivot_to_next_tactical_leg(self, now: float):
        pivot_angle = random.choice([-90.0, -60.0, -45.0, -30.0, 30.0, 45.0, 60.0, 90.0, 135.0])
        self.current_heading_deg = (self.current_heading_deg + pivot_angle + 360.0) % 360.0
        self._start_new_tactical_leg()

        # Airsoft players arriving at cover frequently stop to scan / reload / cover
        if self.state != MovementState.STOPPED and random.random() < 0.55:
            self.state = MovementState.STOPPED
            self.current_speed_mps = 0.0
            self.stop_events_count += 1
            self.entered_stop_this_tick = True
            self.state_until_time = now + random.uniform(4.0, 10.0)

    def _select_next_state(self, now: float):
        obs_avg = (self.total_distance_meters / self.total_time_seconds) if self.total_time_seconds > 0 else 0.0
        prev_state = self.state
        speed_ratio = (obs_avg / self.target_avg_speed) if self.target_avg_speed > 0 else 1.0

        if speed_ratio > 1.15:
            weights = [0.55, 0.35, 0.10, 0.00]  # Force stop or slow walk
        elif speed_ratio < 0.85:
            weights = [0.10, 0.20, 0.45, 0.25]  # Sprint or run to catch up
        else:
            weights = [0.25, 0.40, 0.25, 0.10]

        next_state = random.choices(
            [MovementState.STOPPED, MovementState.WALKING, MovementState.RUNNING, MovementState.SPRINTING],
            weights=weights,
            k=1,
        )[0]

        self.state = next_state

        if next_state == MovementState.STOPPED:
            self.current_speed_mps = 0.0
            duration = random.uniform(3.0, 10.0)
            if prev_state != MovementState.STOPPED:
                self.stop_events_count += 1
                self.entered_stop_this_tick = True
        elif next_state == MovementState.WALKING:
            self.current_speed_mps = max(0.5, self.target_avg_speed * random.uniform(0.5, 0.9))
            duration = random.uniform(6.0, 15.0)
        elif next_state == MovementState.RUNNING:
            self.current_speed_mps = self.target_avg_speed * random.uniform(1.1, 1.4)
            duration = random.uniform(5.0, 12.0)
        else:  # SPRINTING
            self.current_speed_mps = self.target_avg_speed * random.uniform(1.5, 2.0)
            duration = random.uniform(3.0, 7.0)

        self.state_until_time = now + duration

    @property
    def cumulative_avg_speed_mps(self) -> float:
        return (self.total_distance_meters / self.total_time_seconds) if self.total_time_seconds > 0 else 0.0

    @staticmethod
    def _bearing_to(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
        d_lon = math.radians(lon2 - lon1)
        y = math.sin(d_lon) * math.cos(math.radians(lat2))
        x = math.cos(math.radians(lat1)) * math.sin(math.radians(lat2)) - math.sin(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.cos(d_lon)
        return (math.degrees(math.atan2(y, x)) + 360.0) % 360.0


# MARK: - Simulated Player Engine (Obeying iOS Cloud Architecture)
class SimulatedPlayer:
    """
    Simulates one player adhering strictly to iOS / watchOS cloud behavior:
    - Dead Reckoning & Delta Gating (3.5m / 12 BPM threshold)
    - Fallback refresh heartbeat (10 x T)
    - Ephemeral Latest-Only telemetry buffer during outages
    - Tactical marker generation on stop
    """
    def __init__(
        self,
        spec: PlayerSpec,
        center_lat: float,
        center_lon: float,
        room_id: str,
        is_leader: bool = False,
        marker_drop_probability: float = 0.50,
        min_leg_distance_meters: float = 15.0,
        max_leg_distance_meters: float = 40.0,
        enable_delta_gating: bool = True,
        refresh_heartbeat_sec: float = 10.0,
        encryption_key: Optional[bytes] = None,
    ):
        self.spec = spec
        self.callsign = spec.callsign
        self.member_id = derive_member_id(self.callsign)
        self.room_id = room_id
        self.is_leader = is_leader
        self.marker_drop_probability = marker_drop_probability
        self.enable_delta_gating = enable_delta_gating
        self.refresh_heartbeat_sec = refresh_heartbeat_sec
        # AES-256-GCM key for this player's telemetry/tactical writes, or None to write plaintext
        # compact arrays — set per-player from PlayerSpec.encrypted (see DEFAULT_12_PLAYERS).
        self.encryption_key = encryption_key

        start_lat = spec.start_lat if spec.start_lat is not None else center_lat
        start_lon = spec.start_lon if spec.start_lon is not None else center_lon

        self.walker = RandomWalkController(
            center_lat=start_lat,
            center_lon=start_lon,
            target_avg_speed_mps=spec.target_avg_speed_mps,
            min_leg_distance_meters=min_leg_distance_meters,
            max_leg_distance_meters=max_leg_distance_meters,
        )
        self.net = NetworkQualitySimulator(quality=spec.network_quality)

        # Telemetry state
        self.sequence_number = 0
        self.heart_rate = random.uniform(85.0, 135.0)
        self.pending_telemetry: Optional[List[Any]] = None  # Single-slot latest-only
        self.last_sent_lat: Optional[float] = None
        self.last_sent_lon: Optional[float] = None
        self.last_sent_hr: Optional[float] = None
        self.last_sent_time: float = 0.0

        # Metrics
        self.packets_attempted = 0
        self.packets_succeeded = 0
        self.packets_coalesced_offline = 0
        self.packets_gated_stationary = 0
        self.markers_placed: List[str] = []
        self.last_placed_marker: Optional[Dict[str, Any]] = None

        # Squad-order same-issuer replace tracking (matches GameStateManager.placeTacticalIndicator:
        # a new squad order from this member replaces this member's previously active squad order,
        # regardless of type). `pending_tactical_ops` is this player's Durable Queue-All outbox —
        # tactical ops queue here while offline and flush in FIFO order on reconnect, mirroring the
        # Firebase SDK's own offline write queue (see FirebaseSyncManager.swift comment on ordering).
        self.active_squad_order: Optional[Dict[str, str]] = None
        self.pending_tactical_ops: List[Dict[str, Any]] = []
        self.tactical_ops_queued = 0
        self.tactical_ops_flushed = 0

        # Glance / Inactivity duty cycle state (Apple Watch wrist raise/lower behavior)
        self.glance_time_sec = spec.glance_time_sec
        self.inactivity_time_sec = spec.inactivity_time_sec
        self.has_glance_cycle = (self.glance_time_sec > 0 and self.inactivity_time_sec > 0)
        self.is_glancing = True
        self._next_glance_transition = 0.0
        if self.has_glance_cycle:
            # Stagger initial phase across players so they don't all glance simultaneously
            initial_phase = random.uniform(0.0, self.glance_time_sec + self.inactivity_time_sec)
            if initial_phase < self.glance_time_sec:
                self.is_glancing = True
                self._next_glance_transition = time.time() + (self.glance_time_sec - initial_phase)
            else:
                self.is_glancing = False
                self._next_glance_transition = time.time() + (self.glance_time_sec + self.inactivity_time_sec - initial_phase)

        # Byte / Egress accounting
        self.telemetry_payload_bytes = spec.telemetry_payload_bytes
        self.tactical_payload_bytes = spec.tactical_payload_bytes
        self.total_ingress_bytes = 0
        self.total_continuous_egress_bytes = 0
        self.total_glance_gated_egress_bytes = 0

    def should_suppress_update(self, lat: float, lon: float, hr: float, now: float) -> bool:
        """Evaluates iOS Dead Reckoning & Delta Gating (CLOUD_DATA_MANAGEMENT.md §2)."""
        if not self.enable_delta_gating:
            return False

        # First update must always send
        if self.last_sent_lat is None or self.last_sent_lon is None or self.last_sent_hr is None:
            return False

        # Fallback heartbeat interval exceeded (10 x T) -> force upload to maintain freshness
        if (now - self.last_sent_time) >= self.refresh_heartbeat_sec:
            return False

        # Check movement displacement delta
        distance_moved = distance_between_meters(self.last_sent_lat, self.last_sent_lon, lat, lon)
        hr_delta = abs(hr - self.last_sent_hr)

        # If displacement < 3.5m and HR delta < 12 BPM, suppress stationary telemetry
        if distance_moved < MAX_PREDICTED_POSITION_ERROR_METERS and hr_delta < MIN_HEART_RATE_DELTA_BPM:
            return True

        return False

    def tick(
        self,
        dt: float,
        now: float,
    ) -> Tuple[Optional[Any], Optional[Dict[str, Any]], List[Dict[str, Any]], bool]:
        """
        Executes one simulation step.
        Returns: (telemetry_packet_or_none, tactical_marker_or_none, tactical_ops_to_upload, is_gated_boolean)
        telemetry_packet_or_none is a compact List[Any], or a base64 ciphertext str when this
        player is encrypted (see PlayerSpec.encrypted / self.encryption_key).
        tactical_ops_to_upload is a FIFO-ordered list of {"op": "place"|"remove", "branch", "id",
        ["payload"]} dicts flushed from this player's outbox this tick (empty while offline).
        """
        # 1. Update glance state (active display vs inactivity)
        if self.has_glance_cycle and now >= self._next_glance_transition:
            self.is_glancing = not self.is_glancing
            dur = self.glance_time_sec if self.is_glancing else self.inactivity_time_sec
            self._next_glance_transition = now + dur

        # 2. Update movement
        lat, lon, hdg, speed, state, entered_stop = self.walker.tick(dt, now)

        # Dynamic heart rate correlated with speed
        base_hr = 75.0 + (speed * 12.0)
        self.heart_rate = max(60.0, min(180.0, base_hr + random.uniform(-2.0, 2.0)))

        # 3. Check network connectivity
        is_online = self.net.tick(now)

        # 4. Telemetry packet construction: compact 4-element [lat, lon, hr, ts]
        self.sequence_number += 1
        rounded_lat = round(lat, 6)
        rounded_lon = round(lon, 6)
        rounded_hr = round(self.heart_rate, 0)
        rounded_ts = round(now, 3)
        telemetry_payload = [rounded_lat, rounded_lon, rounded_hr, rounded_ts]

        packet_to_upload: Optional[List[Any]] = None
        is_gated = False

        if is_online:
            # Check delta gating if not flushing an offline reconnect sample
            if self.pending_telemetry is None and self.should_suppress_update(lat, lon, self.heart_rate, now):
                self.packets_gated_stationary += 1
                is_gated = True
            else:
                # Online and qualified: flush latest
                packet_to_upload = telemetry_payload
                self.pending_telemetry = None
                self.packets_attempted += 1
                self.last_sent_lat = lat
                self.last_sent_lon = lon
                self.last_sent_hr = self.heart_rate
                self.last_sent_time = now
                self.total_ingress_bytes += self.telemetry_payload_bytes
        else:
            # Offline: Latest-Only coalescing into single slot (Policy 2)
            if self.pending_telemetry is not None:
                self.packets_coalesced_offline += 1
            self.pending_telemetry = telemetry_payload

        # 5. Marker Generation on Stop — enqueued into the Durable Queue-All outbox regardless of
        # connectivity; only flushed to the wire while online (step 6 below).
        marker_to_place: Optional[Dict[str, Any]] = None
        if entered_stop and random.random() < self.marker_drop_probability:
            marker_to_place = self._generate_marker(lat, lon, now)
            self.pending_tactical_ops.extend(marker_to_place["ops"])
            self.tactical_ops_queued += len(marker_to_place["ops"])

        # 6. Flush the tactical outbox only while online, in FIFO order — mirrors the Firebase
        # SDK's own offline write queue, which replays every queued write in the order it was
        # issued once connectivity returns (see FirebaseSyncManager.swift). This is what lets a
        # same-issuer squad-order replace (remove old + add new) survive a network drop correctly:
        # the remove always reaches the server before the add, so the old order can't outlive it.
        tactical_ops_to_upload: List[Dict[str, Any]] = []
        if is_online and self.pending_tactical_ops:
            tactical_ops_to_upload = self.pending_tactical_ops
            self.pending_tactical_ops = []
            self.tactical_ops_flushed += len(tactical_ops_to_upload)
            self.total_ingress_bytes += len(tactical_ops_to_upload) * self.tactical_payload_bytes

        # 7. Encrypt the outgoing telemetry array (if this player has an encryption key) —
        # internal state above (last_sent_lat/lon/hr, pending_telemetry) always stays plaintext
        # since delta-gating math needs real numbers; only the wire payload is ciphertext.
        wire_packet: Optional[Any] = packet_to_upload
        if wire_packet is not None and self.encryption_key is not None:
            wire_packet = encrypt_compact_array(wire_packet, self.encryption_key)

        return wire_packet, marker_to_place, tactical_ops_to_upload, is_gated

    def _generate_marker(self, lat: float, lon: float, now: float) -> Dict[str, Any]:
        """Creates a tactical marker matching RadarMap 5-element schema, plus the ordered list of
        outbox ops needed to place it. For a squad order, if this member already has an active
        squad order (any type), its removal is queued ahead of the new placement — matching
        GameStateManager.placeTacticalIndicator's same-issuer replace rule."""
        marker_name = random.choice(ALL_MARKER_TYPES)
        is_squad_order = marker_name in SQUAD_ORDER_CODES
        type_code = SQUAD_ORDER_CODES.get(marker_name) or ENEMY_AND_ENV_CODES.get(marker_name, "wat")
        indicator_id = f"{type_code}_{uuid.uuid4().hex[:6]}"
        branch = "o" if is_squad_order else "i"

        # Compact 5-element array format: [type_code, lat, lon, ts, placedByMemberId]
        payload: Any = [type_code, round(lat, 6), round(lon, 6), round(now, 3), self.member_id]
        if self.encryption_key is not None:
            payload = encrypt_compact_array(payload, self.encryption_key)

        ops: List[Dict[str, Any]] = []
        if is_squad_order and self.active_squad_order is not None:
            ops.append({"op": "remove", "branch": "o", "id": self.active_squad_order["id"]})
        ops.append({"op": "place", "branch": branch, "id": indicator_id, "payload": payload})

        if is_squad_order:
            self.active_squad_order = {"id": indicator_id, "type_code": type_code}

        marker_info = {
            "id": indicator_id,
            "type_name": marker_name,
            "type_code": type_code,
            "is_squad_order": is_squad_order,
            "branch": branch,
            "lat": lat,
            "lon": lon,
            "placed_by": self.callsign,
            "member_id": self.member_id,
            "payload": payload,
            "ops": ops,
        }
        self.markers_placed.append(indicator_id)
        self.last_placed_marker = marker_info
        return marker_info


# MARK: - Multi-Player Stress Test Coordinator
class StressTestCoordinator:
    """
    Coordinates simultaneous execution of all simulated squad players.
    Enforces all iOS / watchOS cloud behaviors:
    - Creates room r/{roomId} with host, cap, mti, and pin
    - Initializes TTL exp across r/, p/, and t/ (12h idle cutoff)
    - Performs periodic TTL refreshes while active
    - Respects constant bandwidth scaling R_max(P) = 1.0 * min(1.0, 12 / P)
    - Supports live Firebase Realtime Database SDK or --dry-run testing
    """
    def __init__(
        self,
        center_lat: float,
        center_lon: float,
        players: List[PlayerSpec],
        room_name: str = "STRESS",
        pin: str = "7788",
        database_url: str = DEFAULT_DATABASE_URL,
        credentials_path: Optional[str] = None,
        dry_run: bool = False,
        tick_interval_sec: float = 1.0,
        marker_probability: float = 0.50,
        min_leg_dist: float = 15.0,
        max_leg_dist: float = 40.0,
        enable_delta_gating: bool = True,
        duration_sec: Optional[float] = DEFAULT_SIMULATION_DURATION_SEC,
        on_tick: Optional[Any] = None,
        cleanup_on_stop: bool = True,
    ):
        self.center_lat = center_lat
        self.center_lon = center_lon
        self.raw_room_name = sanitize_room_name(room_name)
        self.pin = sanitize_pin(pin)
        self.room_id = derive_room_id(self.raw_room_name, self.pin)
        self.database_url = database_url.rstrip("/")
        self.credentials_path = resolve_firebase_credentials_path(credentials_path)
        self.dry_run = dry_run
        self.marker_probability = marker_probability
        self.min_leg_dist = min_leg_dist
        self.max_leg_dist = max_leg_dist
        self.enable_delta_gating = enable_delta_gating
        self.duration_sec = duration_sec if (duration_sec is not None and duration_sec > 0) else None
        self.on_tick = on_tick
        self.cleanup_on_stop = cleanup_on_stop

        # Constant Bandwidth Rate Adaptation (CLOUD_DATA_MANAGEMENT.md §4)
        base_rate = (1.0 / tick_interval_sec) if tick_interval_sec > 0 else BASELINE_UPDATE_RATE_HZ
        num_players = max(1, len(players))
        if num_players <= PLAYER_BANDWIDTH_THRESHOLD:
            self.target_rate_hz = base_rate
        else:
            self.target_rate_hz = base_rate * (float(PLAYER_BANDWIDTH_THRESHOLD) / float(num_players))

        self.tick_interval = 1.0 / self.target_rate_hz
        self.refresh_heartbeat_sec = self.tick_interval * REFRESH_HEARTBEAT_MULTIPLIER

        # All encrypted players in a room share one key, since it's derived from the room's own
        # (pin, room_id) — matching FirebaseSyncManager.deriveTelemetryKey — not a per-player secret.
        self._telemetry_key: Optional[bytes] = None
        if any(spec.encrypted for spec in players):
            if not HAS_CRYPTO:
                raise ImportError(
                    "cryptography is required when any PlayerSpec.encrypted=True. Install it with "
                    "`pip install cryptography`."
                )
            self._telemetry_key = derive_telemetry_key(self.pin, self.room_id)

        # Instantiate all simulated squad players
        self.players: List[SimulatedPlayer] = []
        for i, spec in enumerate(players):
            is_leader = (i == 0)
            player = SimulatedPlayer(
                spec=spec,
                center_lat=center_lat,
                center_lon=center_lon,
                room_id=self.room_id,
                is_leader=is_leader,
                marker_drop_probability=marker_probability,
                min_leg_distance_meters=min_leg_dist,
                max_leg_distance_meters=max_leg_dist,
                enable_delta_gating=enable_delta_gating,
                refresh_heartbeat_sec=self.refresh_heartbeat_sec,
                encryption_key=self._telemetry_key if spec.encrypted else None,
            )
            self.players.append(player)

        # Firebase connection resources
        self._firebase_app: Optional[Any] = None
        self.is_running = False

        # Metrics
        self.total_ticks = 0
        self.total_telemetry_sent = 0
        self.total_telemetry_coalesced = 0
        self.total_telemetry_gated = 0
        self.total_markers_placed = 0
        self.total_tactical_ops_uploaded = 0
        self.total_ingress_bytes = 0
        self.total_continuous_egress_bytes = 0
        self.total_glance_gated_egress_bytes = 0
        self.start_time = 0.0
        self._last_ttl_refresh = 0.0

    def init_firebase_if_needed(self) -> bool:
        if self.dry_run:
            print("[SIMULATOR] Running in --dry-run mode (local physics & network simulation, no Firebase upload).")
            return True

        if not HAS_FIREBASE:
            print("[ERROR] firebase-admin package is not installed. Pass --dry-run or install firebase-admin.")
            return False

        if not self.credentials_path or not os.path.isfile(self.credentials_path):
            print("[ERROR] No valid Firebase service-account JSON key found.")
            print("Place a key in credentials/*.json or set FIREBASE_CREDENTIALS, or pass --dry-run.")
            return False

        try:
            cred = firebase_credentials.Certificate(self.credentials_path)
            app_name = f"stress-sim-{uuid.uuid4().hex[:6]}"
            self._firebase_app = firebase_admin.initialize_app(
                cred,
                {"databaseURL": self.database_url},
                name=app_name,
            )
            print(f"[FIREBASE] Initialized authorized connection to {self.database_url}")
            print(f"[FIREBASE] Service Account: {self.credentials_path}")
            return True
        except Exception as e:
            print(f"[ERROR] Failed to initialize Firebase app: {e}")
            return False

    def setup_room(self) -> bool:
        """Sets up room r/{roomId} and subtrees matching SquadRoom and TTL policy."""
        if self.dry_run:
            print(f"[SIMULATOR] Initialized virtual room '{self.room_id}' with {len(self.players)} players.")
            return True

        now = time.time()
        expire_at = now + ROOM_TTL_SECONDS
        pin_h = hash_pin(self.pin, self.room_id)
        host_id = self.players[0].member_id

        members_payload = {}
        for p in self.players:
            members_payload[p.member_id] = {
                "mid": p.member_id,
                "csn": p.callsign,
                "rol": "leader" if p.is_leader else "player",
            }

        room_payload = {
            "id": self.room_id,
            "hst": host_id,
            "cap": 12,
            "mti": MAX_TACTICAL_INDICATORS_CAP,
            "pin": pin_h,
            "exp": expire_at,
            "m": members_payload,
        }

        try:
            # 1. Write room node (/r/{roomId})
            r_ref = firebase_db.reference(f"r/{self.room_id}", app=self._firebase_app)
            r_ref.set(room_payload)

            # 2. Write telemetry & tactical TTL subnodes (/p/{roomId} and /t/{roomId})
            p_ref = firebase_db.reference(f"p/{self.room_id}", app=self._firebase_app)
            p_ref.set({"exp": expire_at})

            t_ref = firebase_db.reference(f"t/{self.room_id}", app=self._firebase_app)
            t_ref.set({"exp": expire_at})

            self._last_ttl_refresh = now
            print(f"[FIREBASE] Squad room '{self.room_id}' created with {len(self.players)} registered members.")
            return True
        except Exception as e:
            print(f"[FIREBASE ERROR] Failed to setup room: {e}")
            return False

    def refresh_room_expiry_if_needed(self, now: float):
        """Refreshes TTL exp across r/, p/, and t/ hourly (CLOUD_DATA_MANAGEMENT.md §5.C)."""
        if self.dry_run or not self._firebase_app:
            return
        if (now - self._last_ttl_refresh) >= 3600.0:  # Hourly refresh
            new_exp = now + ROOM_TTL_SECONDS
            try:
                firebase_db.reference(f"r/{self.room_id}/exp", app=self._firebase_app).set(new_exp)
                firebase_db.reference(f"p/{self.room_id}/exp", app=self._firebase_app).set(new_exp)
                firebase_db.reference(f"t/{self.room_id}/exp", app=self._firebase_app).set(new_exp)
                self._last_ttl_refresh = now
            except Exception:
                pass

    def teardown_room(self):
        """Clean teardown on simulation finish, purging cloud nodes."""
        if self.dry_run:
            print(f"\n[INFO] Dry-run mode: skipping Firebase purge for room '{self.room_id}'.")
            return

        if not self._firebase_app:
            if not self.init_firebase_if_needed():
                return

        print(f"\n[CLEANUP] Disbanding room '{self.room_id}' on Firebase...")
        try:
            firebase_db.reference(f"p/{self.room_id}", app=self._firebase_app).delete()
            firebase_db.reference(f"t/{self.room_id}", app=self._firebase_app).delete()
            firebase_db.reference(f"r/{self.room_id}", app=self._firebase_app).delete()
            print(f"[SUCCESS] Disbanded room '{self.room_id}' and purged all nodes (r/, p/, t/).")
        except Exception as e:
            print(f"[CLEANUP ERROR] Failed to delete room nodes: {e}")

    def disband_room(self):
        """Clean disband of room on Firebase, purging telemetry, tactical markers, and room info."""
        self.teardown_room()

    def leave_room(self):
        """Alias for disband_room / teardown_room to cleanly exit and purge room."""
        self.disband_room()

    @classmethod
    def purge_all_rooms(cls, credentials_path: Optional[str] = None, database_url: str = DEFAULT_DATABASE_URL):
        """Administrative helper: purges all rooms across r/, p/, and t/ from Firebase RTDB."""
        creds = resolve_firebase_credentials_path(credentials_path)
        if not creds:
            print("[ERROR] No credentials found to purge rooms.")
            return
        if not firebase_admin._apps:
            cred = firebase_credentials.Certificate(creds)
            app = firebase_admin.initialize_app(cred, {"databaseURL": database_url})
        else:
            app = firebase_admin.get_app()
        for branch in ["r", "p", "t"]:
            firebase_db.reference(f"/{branch}", app=app).delete()
        print(f"[CLEANUP] Purged all nodes under /r, /p, and /t on {database_url}.")

    def run(self, duration_sec: Optional[float] = None):
        """Main synchronous multi-player simulation loop."""
        if duration_sec is not None:
            effective_duration = duration_sec if duration_sec > 0 else None
        else:
            effective_duration = self.duration_sec

        if not self.init_firebase_if_needed():
            return
        if not self.setup_room():
            return

        self.is_running = True
        self.start_time = time.time()
        last_tick_time = self.start_time

        mode_str = "DRY RUN (offline test)" if self.dry_run else "LIVE FIREBASE RTDB"
        limit_str = f"{effective_duration:.0f}s ({effective_duration / 60.0:.1f} min)" if effective_duration is not None else "Unlimited (Ctrl+C to stop)"
        print("\n" + "=" * 95)
        print(f"🚀 RADARMAP TACTICAL STRESS SIMULATOR: {len(self.players)} CONCURRENT SQUAD PLAYERS")
        print(f"📍 Center: ({self.center_lat:.6f}, {self.center_lon:.6f}) | Room: {self.room_id} | Mode: {mode_str}")
        print(f"⏱️ Time Limit: {limit_str}")
        print(f"📡 Bandwidth Scaling: Rate = {self.target_rate_hz:.2f} Hz | Interval = {self.tick_interval:.2f}s | Heartbeat = {self.refresh_heartbeat_sec:.1f}s")
        print("Press Ctrl+C to safely terminate and clean up.")
        print("=" * 95 + "\n")

        try:
            while self.is_running:
                now = time.time()
                elapsed = now - self.start_time
                if effective_duration is not None and elapsed >= effective_duration:
                    print(f"\n⏱️ Reached time limit ({effective_duration:.0f}s / {effective_duration / 60.0:.1f} min). Stopping simulation.")
                    break

                dt = now - last_tick_time
                last_tick_time = now
                self.total_ticks += 1

                # Step all players concurrently in this tick
                recent_markers: List[Dict[str, Any]] = []

                for player in self.players:
                    packet_to_send, marker_to_place, tactical_ops, is_gated = player.tick(dt, now)

                    if is_gated:
                        self.total_telemetry_gated += 1

                    if packet_to_send is not None:
                        self.total_telemetry_sent += 1
                        player.packets_succeeded += 1
                        # Ingress: player -> server
                        self.total_ingress_bytes += player.telemetry_payload_bytes
                        # Egress: fan-out to other N-1 connected players
                        for other in self.players:
                            if other.member_id != player.member_id and other.net.is_connected:
                                self.total_continuous_egress_bytes += player.telemetry_payload_bytes
                                if other.is_glancing:
                                    self.total_glance_gated_egress_bytes += player.telemetry_payload_bytes

                        if not self.dry_run and self._firebase_app:
                            self._async_upload_telemetry(player.member_id, packet_to_send)

                    if marker_to_place is not None:
                        self.total_markers_placed += 1
                        recent_markers.append(marker_to_place)

                    if tactical_ops:
                        self.total_tactical_ops_uploaded += len(tactical_ops)
                        for op in tactical_ops:
                            self.total_ingress_bytes += player.tactical_payload_bytes
                            # Tactical fan-out to other N-1 connected players
                            for other in self.players:
                                if other.member_id != player.member_id and other.net.is_connected:
                                    self.total_continuous_egress_bytes += player.tactical_payload_bytes
                                    if other.is_glancing:
                                        self.total_glance_gated_egress_bytes += player.tactical_payload_bytes

                        if not self.dry_run and self._firebase_app:
                            for op in tactical_ops:
                                self._async_apply_tactical_op(op)

                # Periodic TTL refresh check
                self.refresh_room_expiry_if_needed(now)

                # Render dashboard
                self._render_dashboard(elapsed, recent_markers)

                # Invoke custom tick callback if configured (e.g. for ipynb UI / visualizers)
                if self.on_tick is not None:
                    try:
                        self.on_tick({
                            "elapsed": elapsed,
                            "room_id": self.room_id,
                            "players": self.players,
                            "recent_markers": recent_markers,
                            "telemetry_sent": self.total_telemetry_sent,
                            "telemetry_gated": self.total_telemetry_gated,
                            "markers_placed": self.total_markers_placed,
                            "is_running": self.is_running,
                        })
                    except Exception:
                        pass

                # Sleep to maintain adaptive tick rate
                sleep_dur = max(0.01, self.tick_interval - (time.time() - now))
                time.sleep(sleep_dur)

        except KeyboardInterrupt:
            print("\n\n⏹️ Simulation interrupted by user.")
        finally:
            self.is_running = False
            if self.cleanup_on_stop:
                self.teardown_room()
            else:
                print(f"\n[INFO] Room nodes preserved under 'r/{self.room_id}', 'p/{self.room_id}', 't/{self.room_id}' for Firebase Console inspection.")
            self._print_final_summary()

    def _async_upload_telemetry(self, member_id: str, payload: Any):
        """Uploads telemetry packet asynchronously via Firebase RTDB SDK."""
        def _task():
            try:
                ref = firebase_db.reference(f"p/{self.room_id}/{member_id}", app=self._firebase_app)
                ref.set(payload)
            except Exception:
                pass
        threading.Thread(target=_task, daemon=True).start()

    def _async_apply_tactical_op(self, op: Dict[str, Any]):
        """Applies one flushed tactical outbox op (place or remove) asynchronously via Firebase
        RTDB SDK. Ops arrive here already in FIFO order per-player (see SimulatedPlayer.tick)."""
        def _task():
            try:
                ref = firebase_db.reference(f"t/{self.room_id}/{op['branch']}/{op['id']}", app=self._firebase_app)
                if op["op"] == "remove":
                    ref.delete()
                else:
                    ref.set(op["payload"])
            except Exception:
                pass
        threading.Thread(target=_task, daemon=True).start()

    def _render_dashboard(self, elapsed: float, recent_markers: List[Dict[str, Any]]):
        lines = []
        lines.append("\033[H\033[J")
        lines.append(f"⏱️ [T+{elapsed:6.1f}s] Room: {self.room_id} | Live Telemetry: {self.total_telemetry_sent} pkts | Delta Gated: {self.total_telemetry_gated} | Markers: {self.total_markers_placed}")
        lines.append("-" * 110)
        lines.append(f"{'CALLSIGN':<10} | {'STATUS':<7} | {'NET':<5} | {'STATE':<9} | {'V_INST':<7} | {'V_AVG/TGT':<11} | {'DIST':<7} | {'PKTS_OK':<7} | {'COALESCE':<8} | {'TACTQ':<5} | {'MARKERS'}")
        lines.append("-" * 110)

        for p in self.players:
            net_status = "ON" if p.net.is_connected else "OFF"
            v_inst = f"{p.walker.current_speed_mps:4.1f}m/s"
            v_avg = f"{p.walker.cumulative_avg_speed_mps:4.1f}/{p.spec.target_avg_speed_mps:3.1f}"
            dist = f"{p.walker.total_distance_meters:5.0f}m"
            marker_count = f"{len(p.markers_placed):2d} placed"
            tactq = f"{len(p.pending_tactical_ops):3d}"

            status_indicator = "🟢" if p.net.is_connected else "🔴"
            state_str = p.walker.state[:8]

            lines.append(
                f"{p.callsign:<10} | {status_indicator} {net_status:<3} | {p.spec.network_quality}/5   | {state_str:<9} | {v_inst:<7} | {v_avg:<11} | {dist:<7} | {p.packets_succeeded:<7} | {p.packets_coalesced_offline:<8} | {tactq:<5} | {marker_count}"
            )

        lines.append("-" * 110)
        if recent_markers:
            m_descs = [f"{m['placed_by']}:{m['type_name']}" for m in recent_markers[:4]]
            lines.append(f"📍 Recent Tactical Markers: {', '.join(m_descs)}")
        else:
            lines.append("📍 Airsoft bounds: players commit to 15-40m legs. Markers drop upon entering STOPPED state.")

        print("\n".join(lines), flush=True)

    def _print_final_summary(self):
        elapsed = time.time() - self.start_time
        print("\n" + "=" * 85)
        print("📊 STRESS TEST SIMULATION SUMMARY (iOS CLOUD-COMPLIANT)")
        print("=" * 85)
        print(f"Total Duration:         {elapsed:.1f} seconds")
        print(f"Total Squad Players:    {len(self.players)}")
        print(f"Total Telemetry Sent:   {self.total_telemetry_sent} packets")
        coalesced_sum = sum(p.packets_coalesced_offline for p in self.players)
        print(f"Total Offline Coalesce: {coalesced_sum} packets (backpressure saved)")
        print(f"Total Stationary Gated: {self.total_telemetry_gated} packets (delta gating saved)")
        print(f"Total Markers Placed:   {self.total_markers_placed}")
        print(f"Total Tactical Ops Sent: {self.total_tactical_ops_uploaded} (place + remove, FIFO-flushed on reconnect)")
        stranded = sum(len(p.pending_tactical_ops) for p in self.players)
        if stranded:
            print(f"⚠️  Tactical Ops Stranded Offline At Stop: {stranded} (players still offline when simulation ended)")
        print("-" * 85)
        print(f"{'Callsign':<10} | {'Target v':<8} | {'Observed v':<10} | {'Accuracy':<8} | {'Uptime %':<8} | {'Markers Placed'}")
        print("-" * 85)

        for p in self.players:
            tgt = p.spec.target_avg_speed_mps
            obs = p.walker.cumulative_avg_speed_mps
            acc = ((1.0 - abs(obs - tgt) / tgt) * 100.0) if tgt > 0 else 100.0
            uptime = p.net.current_uptime_ratio * 100.0
            print(f"{p.callsign:<10} | {tgt:6.2f}m/s | {obs:8.2f}m/s | {acc:7.1f}% | {uptime:7.1f}% | {len(p.markers_placed):2d} markers")

        print("-" * 85)
        print("💰 NETWORK TRAFFIC & CLOUD COST PROJECTION (Firebase RTDB Blaze Plan)")
        print("-" * 85)
        mb_ingress = self.total_ingress_bytes / (1024.0 * 1024.0)
        mb_egress_cont = self.total_continuous_egress_bytes / (1024.0 * 1024.0)
        mb_egress_gated = self.total_glance_gated_egress_bytes / (1024.0 * 1024.0)
        print(f"Total Client Ingress:             {mb_ingress:8.3f} MB ({self.total_ingress_bytes:,} bytes)")
        print(f"Total Fan-out Egress (Continuous):{mb_egress_cont:8.3f} MB ({self.total_continuous_egress_bytes:,} bytes)")
        print(f"Total Fan-out Egress (Glance-Gated):{mb_egress_gated:8.3f} MB ({self.total_glance_gated_egress_bytes:,} bytes)")
        if elapsed > 0:
            hr_scale = 3600.0 / elapsed
            game_scale = (8.0 * 3600.0) / elapsed
            mo_scale = (64.0 * 3600.0) / elapsed  # 8 days/mo * 8 hrs/day = 64 hrs
            print(f"\n--- Extrapolations based on {elapsed:.1f}s test run ---")
            print(f"Hourly Egress (Continuous):      {(mb_egress_cont * hr_scale):8.2f} MB/hr")
            print(f"Hourly Egress (Glance-Gated):    {(mb_egress_gated * hr_scale):8.2f} MB/hr")
            print(f"8-Hour Game Egress (Glance-Gated):{(mb_egress_gated * game_scale):8.2f} MB  [Cost: ${(mb_egress_gated * game_scale / 1024.0) * 1.00:0.4f} @ $1.00/GB]")
            print(f"Monthly Weekend Play (64 hrs):   {(mb_egress_gated * mo_scale / 1024.0):8.3f} GB/mo [Cost: ${max(0.0, (mb_egress_gated * mo_scale / 1024.0) - 10.0) * 1.00:0.2f} after 10GB free]")
        print("=" * 85 + "\n")


# MARK: - Benchmark Profiles & Cost Analyzer
def get_benchmark_players(benchmark: str) -> List[PlayerSpec]:
    """Generates player roster according to standard benchmark tiers."""
    b = benchmark.lower()
    if b == "free":
        # Free Tier: 4 players, 5s glance / 30s inactive (14.29% duty cycle), 200B telemetry, 0 markers
        return [
            PlayerSpec(callsign=f"FREE-{i+1}", target_avg_speed_mps=3.0, network_quality=4,
                       glance_time_sec=5.0, inactivity_time_sec=30.0,
                       telemetry_payload_bytes=200, tactical_payload_bytes=200)
            for i in range(4)
        ]
    elif b == "pro":
        # Pro Tier: 12 players, 10s glance / 20s inactive (33.33% duty cycle), 200B telemetry, 100 max markers
        return [
            PlayerSpec(callsign=f"PRO-{i+1}", target_avg_speed_mps=3.5, network_quality=4 if i < 8 else 3,
                       glance_time_sec=10.0, inactivity_time_sec=20.0,
                       telemetry_payload_bytes=200, tactical_payload_bytes=200)
            for i in range(12)
        ]
    else:
        raise ValueError(f"Unknown benchmark '{benchmark}'. Must be 'free' or 'pro'.")


def generate_squad_roster(num_players: int) -> List[PlayerSpec]:
    """Generates an N-player squad roster (e.g. 60 players) with realistic callsigns, speeds, and network qualities."""
    roster: List[PlayerSpec] = []
    squad_names = ["VIPER", "GHOST", "COBRA", "EAGLE", "WOLF", "HAWK", "RAVEN", "TITAN", "STORM", "HUNTER"]
    for i in range(num_players):
        sq_idx = i // 6
        sq_name = squad_names[sq_idx % len(squad_names)]
        num = (i % 6) + 1
        if sq_idx >= len(squad_names):
            sq_name = f"{sq_name}{sq_idx // len(squad_names) + 1}"
        callsign = f"{sq_name}-{num}"
        # Distributed tactical speeds: 2.0 m/s (scout/sniper) to 5.0 m/s (point scout/assault)
        speed = 2.0 + ((i * 1.7) % 3.2)
        # Distributed network qualities: 1 to 5
        quality = 5 if (i % 5 == 0) else (4 if (i % 5 in (1, 2)) else (3 if (i % 5 == 3) else 2))
        roster.append(PlayerSpec(
            callsign=callsign,
            target_avg_speed_mps=speed,
            network_quality=quality,
            glance_time_sec=10.0,
            inactivity_time_sec=20.0,
            telemetry_payload_bytes=200,
            tactical_payload_bytes=200,
        ))
    return roster


def print_analytical_cost_report():
    """Prints mathematical cost and capacity analysis matching Network Benchmark table."""
    print("\n" + "=" * 95)
    print("📈 RADARMAP NETWORK BENCHMARK & FIREBASE CLOUD FINANCIAL ANALYSIS")
    print("=" * 95)
    print("Firebase RTDB Blaze Allocation: 10 GB/month FREE, $1.00 / GB egress thereafter.")
    print("Usage Model: Weekend play only = 8 days/month, 8 hours/day = 64 hours/month.")
    print("-" * 95)

    # Free Tier Math
    # 4 players, 0.5 Hz upload, 200B telemetry, 0 markers, 5s glance / 30s inactive (duty = 5/35 = 14.286%)
    n_free = 4
    rate_free = 0.5
    size_tel = 200
    duty_free = 5.0 / 35.0
    # Telemetry ingress
    tel_in_free_hr = n_free * rate_free * size_tel * 3600 / (1024 * 1024)  # MB/hr
    # Fanout egress per player = (N-1) * rate * size * 3600
    tel_eg_free_cont_hr = n_free * (n_free - 1) * rate_free * size_tel * 3600 / (1024 * 1024)  # MB/hr
    tel_eg_free_gated_hr = tel_eg_free_cont_hr * duty_free  # MB/hr

    free_game_egress_mb = tel_eg_free_gated_hr * 8.0
    free_month_egress_gb = (tel_eg_free_gated_hr * 64.0) / 1024.0
    free_games_in_10gb = 10.0 / (free_month_egress_gb if free_month_egress_gb > 0 else 1.0)
    free_cost_per_game = (free_game_egress_mb / 1024.0) * 1.00

    print(f"1️⃣  FREE TIER BENCHMARK ({n_free} Players | 0.5 Hz Upload | 5s Glance / 30s Inactive | 0 Markers):")
    print(f"    • Ingress (Client -> Cloud):    {tel_in_free_hr:6.2f} MB/hr")
    print(f"    • Continuous Fanout Egress:     {tel_eg_free_cont_hr:6.2f} MB/hr ({tel_eg_free_cont_hr * 8:5.1f} MB / 8-hr game)")
    print(f"    • Glance-Gated Egress ({duty_free*100:4.1f}%):   {tel_eg_free_gated_hr:6.2f} MB/hr ({free_game_egress_mb:5.1f} MB / 8-hr game)")
    print(f"    • Monthly Egress (64 hrs/mo):   {free_month_egress_gb:6.3f} GB/squad")
    print(f"    • Q1: Concurrent Free Games in 10 GB Free Tier: {free_games_in_10gb:5.1f} concurrent squads ({free_games_in_10gb * n_free:4.0f} CCU)")
    print(f"    • Q1a: Total Install Base (at 2% CCU peak):     ~{int(free_games_in_10gb * n_free / 0.02):,} registered users before any Firebase bill")
    print(f"    • Q2: Incremental Cost of 8-Hour Game:         ${free_cost_per_game:0.4f} (~half a cent per 8-hour game)")

    print("-" * 95)

    # Pro Tier Math
    # 12 players, 0.5 Hz upload, 200B telemetry, 1.0 Hz marker placement rate, 200B markers, 10s glance / 20s inactive (duty = 10/30 = 33.333%)
    n_pro = 12
    rate_pro_tel = 0.5
    rate_pro_mkr = 1.0
    duty_pro = 10.0 / 30.0
    # Telemetry egress
    tel_eg_pro_cont_hr = n_pro * (n_pro - 1) * rate_pro_tel * size_tel * 3600 / (1024 * 1024)
    tel_eg_pro_gated_hr = tel_eg_pro_cont_hr * duty_pro
    # Marker egress (1 marker/s room-wide fanned out to 11 players)
    mkr_eg_pro_cont_hr = (n_pro - 1) * rate_pro_mkr * size_tel * 3600 / (1024 * 1024)
    mkr_eg_pro_gated_hr = mkr_eg_pro_cont_hr * duty_pro

    total_pro_cont_hr = tel_eg_pro_cont_hr + mkr_eg_pro_cont_hr
    total_pro_gated_hr = tel_eg_pro_gated_hr + mkr_eg_pro_gated_hr
    pro_game_egress_mb = total_pro_gated_hr * 8.0
    pro_month_egress_gb = (total_pro_gated_hr * 64.0) / 1024.0
    pro_games_in_10gb = 10.0 / pro_month_egress_gb
    pro_cost_per_game = (pro_game_egress_mb / 1024.0) * 1.00

    # Depletion of $19.99 purchase
    # Apple 15% cut (Small Business Program): Net revenue = $19.99 * 0.85 = $16.99. 50% = $8.50.
    # At standard 30% cut: Net revenue = $13.99. 50% = $7.00.
    # Cost per player-month at 64 hrs/mo = (total squad cost) / 12 = ($pro_month_egress_gb * $1.00) / 12
    cost_per_player_month_64h = pro_month_egress_gb / float(n_pro)
    months_to_deplete_50_pct_hardcore = (16.99 * 0.50) / cost_per_player_month_64h
    months_to_deplete_50_pct_casual = (16.99 * 0.50) / (cost_per_player_month_64h * (16.0 / 64.0))

    print(f"2️⃣  PRO TIER BENCHMARK ({n_pro} Players | 0.5 Hz Upload | 10s Glance / 20s Inactive | 1.0 Hz Markers | 100 Cap):")
    print(f"    • Telemetry Egress (Continuous):{tel_eg_pro_cont_hr:6.2f} MB/hr | Glance-Gated: {tel_eg_pro_gated_hr:6.2f} MB/hr")
    print(f"    • Tactical Marker Egress:       {mkr_eg_pro_cont_hr:6.2f} MB/hr | Glance-Gated: {mkr_eg_pro_gated_hr:6.2f} MB/hr")
    print(f"    • Total Hourly Egress:          {total_pro_cont_hr:6.2f} MB/hr (Continuous) | {total_pro_gated_hr:6.2f} MB/hr (Glance-Gated)")
    print(f"    • Per 8-Hour Game Egress:       {pro_game_egress_mb:6.1f} MB/game (Glance-Gated)")
    print(f"    • Monthly Egress (64 hrs/mo):   {pro_month_egress_gb:6.3f} GB/squad")
    print(f"    • Q1: Concurrent Pro Games in 10 GB Free Tier:  {pro_games_in_10gb:5.1f} concurrent squads ({pro_games_in_10gb * n_pro:4.0f} CCU)")
    print(f"    • Q1a: Total Install Base (at 2% CCU peak):     ~{int(pro_games_in_10gb * n_pro / 0.02):,} registered users before any Firebase bill")
    print(f"    • Q2: Incremental Cost of 8-Hour Game:         ${pro_cost_per_game:0.4f} (~15 cents per 8-hour game)")
    print(f"    • Q3: Time to Deplete 50% of $19.99 App Revenue ($8.50 budget @ Apple 15% rate):")
    print(f"          - Hardcore Play (64 hrs/mo, every weekend): {months_to_deplete_50_pct_hardcore:4.1f} months (~{months_to_deplete_50_pct_hardcore/12.0:0.1f} years)")
    print(f"          - Casual Play (16 hrs/mo, 2 weekends):      {months_to_deplete_50_pct_casual:4.1f} months (~{months_to_deplete_50_pct_casual/12.0:0.1f} years)")
    print("=" * 95 + "\n")


# MARK: - Entrypoint & Parsing
def parse_players_table(table_json_str: Optional[str]) -> List[PlayerSpec]:
    if not table_json_str:
        return [
            PlayerSpec(callsign=c, target_avg_speed_mps=s, network_quality=q, encrypted=e)
            for (c, s, q, e) in DEFAULT_12_PLAYERS
        ]

    raw = json.loads(table_json_str)
    specs = []
    for item in raw:
        if isinstance(item, list) and len(item) >= 3:
            specs.append(PlayerSpec(
                callsign=str(item[0]),
                target_avg_speed_mps=float(item[1]),
                network_quality=int(item[2]),
                encrypted=bool(item[3]) if len(item) >= 4 else False,
            ))
        elif isinstance(item, dict):
            specs.append(PlayerSpec(
                callsign=item["callsign"],
                target_avg_speed_mps=float(item.get("speed", item.get("avg_speed", 3.0))),
                network_quality=int(item.get("quality", item.get("network_quality", 5))),
                start_lat=item.get("lat"),
                start_lon=item.get("lon"),
                encrypted=bool(item.get("encrypted", False)),
                glance_time_sec=float(item.get("glance_time_sec", 0.0)),
                inactivity_time_sec=float(item.get("inactivity_time_sec", 0.0)),
                telemetry_payload_bytes=int(item.get("telemetry_payload_bytes", 200)),
                tactical_payload_bytes=int(item.get("tactical_payload_bytes", 200)),
            ))
    return specs


def main():
    parser = argparse.ArgumentParser(
        description="RadarMap Tactical Squad Stress Test Simulator",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--num-players", "-n", type=int, default=None, help="Simulate N players (e.g. 60) automatically generating rosters")
    parser.add_argument("--benchmark", choices=["free", "pro"], default=None, help="Preset benchmark tier ('free' = 4 players, 'pro' = 12 players)")
    parser.add_argument("--cost-analysis", action="store_true", help="Print analytical cloud bandwidth and financial report for Blaze plan")
    parser.add_argument("--lat", type=float, default=37.785834, help="Starting anchor latitude")
    parser.add_argument("--lon", type=float, default=-122.406417, help="Starting anchor longitude")
    parser.add_argument("--room", default="STRESS", help="Squad room name (max 12 alphanumeric chars)")
    parser.add_argument("--pin", default="7788", help="Room PIN (4-16 alphanumeric chars)")
    parser.add_argument("--players", type=str, default=None, help="JSON list of players [[callsign, speed_mps, quality_1_to_5, encrypted], ...] (encrypted is optional, defaults to false)")
    parser.add_argument(
        "--duration",
        type=float,
        default=DEFAULT_SIMULATION_DURATION_SEC,
        help="Simulation duration limit in seconds (default 600s = 10 mins; pass 0 or negative for unlimited)",
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=1.0,
        help="Telemetry broadcast tick interval in seconds (default 1 Hz)",
    )
    parser.add_argument("--marker-prob", type=float, default=0.50, help="Probability (0.0 - 1.0) of placing a marker on stop")
    parser.add_argument("--min-leg-dist", type=float, default=15.0, help="Minimum distance (meters) before direction change (airsoft bound)")
    parser.add_argument("--max-leg-dist", type=float, default=40.0, help="Maximum distance (meters) before direction change (airsoft bound)")
    parser.add_argument("--no-delta-gating", action="store_true", help="Disable dead reckoning delta gating")
    parser.add_argument("--database-url", default=DEFAULT_DATABASE_URL, help="Firebase RTDB URL")
    parser.add_argument("--credentials", default=None, help="Path to Firebase service-account JSON key")
    parser.add_argument("--dry-run", action="store_true", help="Run in local offline test mode (no Firebase connection)")
    parser.add_argument("--preserve-room", action="store_true", help="Preserve Firebase room nodes upon stop instead of purging them")

    args = parser.parse_args()

    if args.cost_analysis:
        print_analytical_cost_report()
        if args.duration == DEFAULT_SIMULATION_DURATION_SEC and args.benchmark is None and args.players is None and args.num_players is None:
            return

    if args.num_players is not None and args.num_players > 0:
        players = generate_squad_roster(args.num_players)
    elif args.benchmark:
        players = get_benchmark_players(args.benchmark)
    else:
        players = parse_players_table(args.players)

    duration = args.duration if (args.duration is not None and args.duration > 0) else None

    coordinator = StressTestCoordinator(
        center_lat=args.lat,
        center_lon=args.lon,
        players=players,
        room_name=args.room,
        pin=args.pin,
        database_url=args.database_url,
        credentials_path=args.credentials,
        dry_run=args.dry_run,
        tick_interval_sec=args.interval,
        marker_probability=args.marker_prob,
        min_leg_dist=args.min_leg_dist,
        max_leg_dist=args.max_leg_dist,
        enable_delta_gating=not args.no_delta_gating,
        duration_sec=duration,
        cleanup_on_stop=not args.preserve_room,
    )

    coordinator.run()


if __name__ == "__main__":
    main()

