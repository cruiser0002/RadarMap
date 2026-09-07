import unittest
import time
import sys
import os
from unittest.mock import patch, MagicMock

# Add notebooks directory to path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "notebooks")))

from player_simulator import (
    FirebaseUploadCoordinator,
    RadarPlayerSimulator,
    TacticalOperation,
    TelemetryItem,
    FirebaseErrorCategory,
    UploadMetrics,
)
from firebase_admin import exceptions as firebase_exceptions


class MockHTTPResponse:
    def __init__(self, status_code=200, json_data=None, text=""):
        self.status_code = status_code
        self._json_data = json_data
        self.text = text or (str(json_data) if json_data is not None else "null")

    def json(self):
        return self._json_data


class TestFirebaseUploadCoordinator(unittest.TestCase):

    def setUp(self):
        # Stub out real Firebase App initialization so unit tests stay hermetic (no real
        # credentials file or network access needed) — only _execute_db's interface contract
        # is under test here, not the SDK itself.
        self._app_patcher = patch(
            "player_simulator._get_or_create_firebase_app", return_value=MagicMock(name="FakeFirebaseApp")
        )
        self._app_patcher.start()
        self.addCleanup(self._app_patcher.stop)

        self.coordinator = FirebaseUploadCoordinator(
            "https://test-rtdb.firebaseio.com",
            credentials_path="/fake/credentials.json",
            periodic_log_interval_sec=3600.0,
        )

    def tearDown(self):
        self.coordinator.close()

    def test_single_initialization_and_session_creation(self):
        """Verifies Firebase transport initializes once per coordinator."""
        metrics = self.coordinator.metrics
        self.assertEqual(metrics.initializations, 1)
        self.assertEqual(metrics.client_creations, 1)
        self.assertEqual(metrics.http_or_transport_session_creations, 1)
        self.assertEqual(metrics.listener_or_stream_operations, 0)

    def test_healthy_telemetry_submission(self):
        """Verifies healthy telemetry uploads cleanly to /p/{room}/{member}.json."""
        recorded_calls = []

        def mock_execute(method, path, data=None):
            recorded_calls.append((method, path, data))
            return 200, {"ok": True}, "success"

        self.coordinator._execute_db = mock_execute

        payload = [37.7858, -122.4064, 85.0, 1788000000.0]
        self.coordinator.submit_telemetry("ALPHA", "member_1", payload)

        # Wait briefly for worker to process
        time.sleep(0.2)

        self.assertGreaterEqual(len(recorded_calls), 1)
        method, path, data = recorded_calls[0]
        self.assertEqual(method, "PUT")
        self.assertEqual(path, "p/ALPHA/member_1.json")
        self.assertEqual(data, payload)
        self.assertEqual(self.coordinator.metrics.telemetry_succeeded, 1)
        self.assertEqual(self.coordinator.metrics.telemetry_failed_transient, 0)

    def test_transient_failure_and_latest_only_coalescing(self):
        """
        Verifies that during transient network failure:
        1. Only one pending telemetry slot is retained.
        2. 10 subsequent samples overwrite that single slot without unbounded growth.
        3. Upon recovery, only the newest 11th sample is uploaded.
        """
        is_failing = True
        recorded_puts = []

        def mock_execute(method, path, data=None):
            if is_failing:
                return -1, "Connection timeout", FirebaseErrorCategory.TRANSIENT
            else:
                recorded_puts.append((method, path, data))
                return 200, {"ok": True}, "success"

        self.coordinator._execute_db = mock_execute

        # 1. Submit initial sample while offline
        self.coordinator.submit_telemetry("ALPHA", "member_1", [37.1, -122.1, 80.0, 100.0])
        time.sleep(0.15)  # Let worker attempt and fail once

        # 2. Push 10 more samples while offline
        for i in range(1, 11):
            self.coordinator.submit_telemetry("ALPHA", "member_1", [37.1 + i*0.001, -122.1, 80.0 + i, 100.0 + i])

        # Verify replacement counter incremented 10 times
        self.assertEqual(self.coordinator.metrics.telemetry_pending_replaced, 10)

        # Confirm pending slot has ONLY the 10th (newest) sample
        with self.coordinator._lock:
            pending = self.coordinator._pending_telemetry
            self.assertIsNotNone(pending)
            self.assertEqual(pending.payload[3], 110.0)  # timestamp 100 + 10 = 110.0
            # Force immediate retry without waiting for backoff timer
            pending.next_retry_time = 0.0

        # 3. Restore network
        is_failing = False
        with self.coordinator._condition:
            self.coordinator._condition.notify_all()

        time.sleep(0.25)

        # 4. Confirm only the latest sample was successfully uploaded
        self.assertGreaterEqual(len(recorded_puts), 1)
        latest_uploaded = recorded_puts[-1]
        self.assertEqual(latest_uploaded[2][3], 110.0)

        with self.coordinator._lock:
            self.assertIsNone(self.coordinator._pending_telemetry)

    def test_permanent_error_halts_infinite_retries(self):
        """Verifies HTTP 401 / 403 halts retries for the telemetry session."""
        def mock_execute(method, path, data=None):
            return 403, "Permission denied", FirebaseErrorCategory.PERMANENT

        self.coordinator._execute_db = mock_execute

        self.coordinator.submit_telemetry("ALPHA", "member_1", [37.0, -122.0, 75.0, 100.0])
        time.sleep(0.2)

        self.assertEqual(self.coordinator.metrics.telemetry_failed_permanent, 1)
        self.assertTrue(self.coordinator._telemetry_permanent_error)
        with self.coordinator._lock:
            self.assertIsNone(self.coordinator._pending_telemetry)

    def test_session_reset_drops_old_pending_telemetry(self):
        """Verifies changing rooms clears pending telemetry so old room coords are not sent."""
        # Hold worker from running by not failing or succeeding immediately
        with self.coordinator._lock:
            self.coordinator._pending_telemetry = TelemetryItem(
                room_name="ROOM_A",
                member_id="mem_1",
                payload=[37.0, -122.0, 80.0, 1.0],
                created_at=time.time(),
                next_retry_time=time.time() + 100.0
            )

        self.coordinator.reset_session()

        with self.coordinator._lock:
            self.assertIsNone(self.coordinator._pending_telemetry)
            self.assertFalse(self.coordinator._telemetry_permanent_error)

    def test_tactical_operations_durable_fifo_and_idempotent_delete(self):
        """Verifies tactical actions preserve FIFO order and deletion of missing marker is converged success."""
        recorded_ops = []

        def mock_execute(method, path, data=None):
            recorded_ops.append((method, path, data))
            if method == "DELETE":
                # Simulate 404 (absent)
                return 404, None, FirebaseErrorCategory.CONVERGED
            return 200, {"ok": True}, "success"

        self.coordinator._execute_db = mock_execute

        op1 = TacticalOperation(op_id="1", op_type="place", room_name="ALPHA", indicator_id="ind_1", indicator_type="inf", lat=37.1, lon=-122.1)
        op2 = TacticalOperation(op_id="2", op_type="remove", room_name="ALPHA", indicator_id="ind_1")

        self.assertTrue(self.coordinator.submit_tactical_op(op1))
        self.assertTrue(self.coordinator.submit_tactical_op(op2))

        time.sleep(0.3)

        self.assertEqual(self.coordinator.metrics.tactical_enqueued, 2)
        self.assertEqual(self.coordinator.metrics.tactical_succeeded, 2)
        self.assertEqual(self.coordinator.metrics.tactical_queue_depth, 0)

    def test_tactical_queue_capacity_backpressure(self):
        """Verifies tactical queue capacity rejects entries beyond MAX_TACTICAL_QUEUE_SIZE without crashing."""
        with self.coordinator._lock:
            # Fill up queue
            for i in range(FirebaseUploadCoordinator.MAX_TACTICAL_QUEUE_SIZE):
                self.coordinator._tactical_queue.append(
                    TacticalOperation(op_id=str(i), op_type="place", room_name="ALPHA", next_retry_time=time.time() + 1000)
                )

        overflow_op = TacticalOperation(op_id="overflow", op_type="place", room_name="ALPHA")
        success = self.coordinator.submit_tactical_op(overflow_op)
        self.assertFalse(success)
        self.assertEqual(self.coordinator.metrics.tactical_failed_permanent, 1)

    def test_zero_reads_and_listeners_on_upload_path(self):
        """Verifies that normal telemetry and tactical upload calls generate zero GET reads and zero listeners."""
        def mock_execute(method, path, data=None):
            return 200, {"ok": True}, "success"

        self.coordinator._execute_db = mock_execute

        # Submit telemetry
        self.coordinator.submit_telemetry("ALPHA", "member_1", [37.78, -122.40, 80.0, 12345.0])
        # Submit tactical
        self.coordinator.submit_tactical_op(
            TacticalOperation(op_id="op_1", op_type="place", room_name="ALPHA", indicator_id="i1", indicator_type="inf", lat=37.0, lon=-122.0)
        )

        time.sleep(0.2)

        self.assertEqual(self.coordinator.metrics.read_operations, 0)
        self.assertEqual(self.coordinator.metrics.listener_or_stream_operations, 0)

    def test_execute_db_strips_json_suffix_and_dispatches_by_method(self):
        """Verifies _execute_db converts REST-style '.json' paths into SDK reference paths and
        calls the matching Reference method (get/set/delete) for each HTTP-style verb."""
        fake_ref = MagicMock()
        fake_ref.get.return_value = {"hello": "world"}

        with patch("player_simulator.firebase_db.reference", return_value=fake_ref) as mock_reference:
            status, data, category = self.coordinator._execute_db("GET", "rooms/ALPHA.json")
            mock_reference.assert_called_with("/rooms/ALPHA", app=self.coordinator._app)
            self.assertEqual(status, 200)
            self.assertEqual(data, {"hello": "world"})
            self.assertEqual(category, "success")

            status, data, category = self.coordinator._execute_db("PUT", "rooms/ALPHA.json", {"id": "ALPHA"})
            fake_ref.set.assert_called_once_with({"id": "ALPHA"})
            self.assertEqual(status, 200)
            self.assertEqual(category, "success")

            status, data, category = self.coordinator._execute_db("DELETE", "rooms/ALPHA.json")
            fake_ref.delete.assert_called_once()
            self.assertEqual(status, 200)
            self.assertEqual(category, FirebaseErrorCategory.CONVERGED)

    def test_execute_db_classifies_sdk_errors_via_existing_status_logic(self):
        """Verifies SDK FirebaseError exceptions (with or without an http_response) are mapped
        back onto the existing _classify_status contract unchanged."""
        fake_ref = MagicMock()

        # Permission denied with a real http_response -> PERMANENT (matches HTTP 403 behavior).
        http_response = MagicMock()
        http_response.status_code = 403
        fake_ref.set.side_effect = firebase_exceptions.PermissionDeniedError(
            message="denied", http_response=http_response
        )
        with patch("player_simulator.firebase_db.reference", return_value=fake_ref):
            status, data, category = self.coordinator._execute_db("PUT", "rooms/ALPHA.json", {})
        self.assertEqual(status, 403)
        self.assertEqual(category, FirebaseErrorCategory.PERMANENT)

        # Connection-level failure with no http_response (e.g. DNS/connect failure) -> TRANSIENT.
        fake_ref.set.side_effect = firebase_exceptions.UnavailableError(message="unavailable")
        with patch("player_simulator.firebase_db.reference", return_value=fake_ref):
            status, data, category = self.coordinator._execute_db("PUT", "rooms/ALPHA.json", {})
        self.assertEqual(status, 503)
        self.assertEqual(category, FirebaseErrorCategory.TRANSIENT)

        # Timeout with no http_response -> TRANSIENT.
        fake_ref.set.side_effect = firebase_exceptions.DeadlineExceededError(message="timeout")
        with patch("player_simulator.firebase_db.reference", return_value=fake_ref):
            status, data, category = self.coordinator._execute_db("PUT", "rooms/ALPHA.json", {})
        self.assertEqual(status, 408)
        self.assertEqual(category, FirebaseErrorCategory.TRANSIENT)


class TestRadarPlayerSimulatorIntegration(unittest.TestCase):

    def test_simulator_payload_formats(self):
        """Verifies simulator produces exact compact4, compact6, compact7, and dict payloads."""
        with patch("player_simulator._get_or_create_firebase_app", return_value=MagicMock(name="FakeFirebaseApp")):
            coordinator = FirebaseUploadCoordinator(
                "https://test-rtdb.firebaseio.com", credentials_path="/fake/credentials.json"
            )
        recorded_telemetry = []

        def mock_submit(room_name, member_id, payload):
            recorded_telemetry.append((room_name, member_id, payload))

        coordinator.submit_telemetry = mock_submit

        # 1. Compact4
        sim4 = RadarPlayerSimulator(room_name="ROOM4", pin="1234", member_id="mem4", telemetry_format="compact4", coordinator=coordinator)
        sim4.send_telemetry(37.123, -122.456, 180.0, altitude=15.0)
        self.assertEqual(len(recorded_telemetry[-1][2]), 4)
        self.assertEqual(recorded_telemetry[-1][2][0], 37.123)
        self.assertEqual(recorded_telemetry[-1][2][1], -122.456)
        self.assertEqual(recorded_telemetry[-1][2][2], 85.0)

        # 2. Compact6
        sim6 = RadarPlayerSimulator(room_name="ROOM6", pin="1234", member_id="mem6", telemetry_format="compact6", coordinator=coordinator)
        sim6.send_telemetry(37.123, -122.456, 180.0, altitude=15.0)
        self.assertEqual(len(recorded_telemetry[-1][2]), 6)
        self.assertEqual(recorded_telemetry[-1][2][2], 15.0)

        # 3. Compact7
        sim7 = RadarPlayerSimulator(room_name="ROOM7", pin="1234", member_id="mem7", telemetry_format="compact7", coordinator=coordinator)
        sim7.send_telemetry(37.123, -122.456, 180.0, altitude=15.0)
        self.assertEqual(len(recorded_telemetry[-1][2]), 7)
        self.assertEqual(recorded_telemetry[-1][2][3], 180.0)

        # 4. Dict format
        sim_dict = RadarPlayerSimulator(room_name="ROOMD", pin="1234", member_id="memd", telemetry_format="dict", coordinator=coordinator)
        sim_dict.send_telemetry(37.123, -122.456, 180.0, altitude=15.0)
        payload = recorded_telemetry[-1][2]
        self.assertIsInstance(payload, dict)
        self.assertEqual(payload["lat"], 37.123)
        self.assertEqual(payload["lng"], -122.456)
        self.assertEqual(payload["hdg"], 180.0)

        coordinator.close()

    def test_member_id_derivation_and_rules_compliance(self):
        """Verifies member_id is exactly 8 characters from Crockford Base32 alphabet,
        matching GameStateManager.deriveMemberId and database.rules.json length check."""
        with patch("player_simulator._get_or_create_firebase_app", return_value=MagicMock(name="FakeFirebaseApp")):
            coordinator = FirebaseUploadCoordinator(
                "https://test-rtdb.firebaseio.com", credentials_path="/fake/credentials.json"
            )
        sim = RadarPlayerSimulator(callsign="VIPER-1", room_name="ALPHA", pin="1234", coordinator=coordinator)
        self.assertEqual(len(sim.member_id), 8)
        self.assertTrue(all(c in RadarPlayerSimulator.ROOM_PADDING_ALPHABET for c in sim.member_id))
        derived = RadarPlayerSimulator.derive_member_id("VIPER-1")
        self.assertEqual(sim.member_id, derived)
        coordinator.close()

    def test_constant_bandwidth_rate_adaptation_linear_falloff(self):
        """Verifies rate adaptation follows linear falloff R(P) = R_base * (N / P)
        so aggregate bandwidth P * R(P) = 12 pkt/s for P > 12."""
        # P <= 12 -> 1.0 Hz
        self.assertEqual(RadarPlayerSimulator.solve_max_update_rate_hz(12), 1.0)
        self.assertEqual(RadarPlayerSimulator.solve_update_interval(12), 1.0)

        # P = 16 -> 0.75 Hz, interval 1.333s, agg = 12
        rate_16 = RadarPlayerSimulator.solve_max_update_rate_hz(16)
        self.assertAlmostEqual(rate_16, 0.75, places=3)
        self.assertAlmostEqual(16 * rate_16, 12.0, places=3)

        # P = 24 -> 0.5 Hz, interval 2.0s, agg = 12
        rate_24 = RadarPlayerSimulator.solve_max_update_rate_hz(24)
        self.assertAlmostEqual(rate_24, 0.5, places=3)
        self.assertAlmostEqual(24 * rate_24, 12.0, places=3)

    def test_hash_parity_with_swift(self):
        """Cross-language parity verification against Swift CryptoKit reference outputs:
        - Room padding for ALPHA with PIN 1234 -> 'JUAT8TJZH2B'
        - Member ID for VIPER-1 -> 'DTYTZD3W'
        - PIN hash for 1234 salted with ALPHA -> 'd5b93eba76c149bafd2bc09099eff86e3f9b89624220f6c1c194f379ccdd438c'
        """
        padding = RadarPlayerSimulator.derive_room_padding("1234", "ALPHA")
        self.assertEqual(padding, "JUAT8TJZH2B")

        mid = RadarPlayerSimulator.derive_member_id("VIPER-1")
        self.assertEqual(mid, "DTYTZD3W")

        pin_hash = RadarPlayerSimulator.hash_pin("1234", "ALPHA")
        self.assertEqual(pin_hash, "d5b93eba76c149bafd2bc09099eff86e3f9b89624220f6c1c194f379ccdd438c")

    def test_tactical_squad_order_codes_and_point_indicators(self):
        """Verifies numbered tactical indicator parity: only point1-3 are defined,
        and point4-10 are excluded."""
        self.assertIn("pt1", RadarPlayerSimulator.SQUAD_ORDER_CODES)
        self.assertIn("pt2", RadarPlayerSimulator.SQUAD_ORDER_CODES)
        self.assertIn("pt3", RadarPlayerSimulator.SQUAD_ORDER_CODES)
        for i in range(4, 11):
            self.assertNotIn(f"pt{i}", RadarPlayerSimulator.SQUAD_ORDER_CODES)
            self.assertNotIn(f"p{i}", RadarPlayerSimulator.SQUAD_ORDER_CODES)

        with patch("player_simulator._get_or_create_firebase_app", return_value=MagicMock(name="FakeFirebaseApp")):
            coordinator = FirebaseUploadCoordinator(
                "https://test-rtdb.firebaseio.com", credentials_path="/fake/credentials.json"
            )
        sim = RadarPlayerSimulator(room_name="ALPHA", pin="1234", coordinator=coordinator)
        self.assertIn("point1", sim.type_codes)
        self.assertIn("point2", sim.type_codes)
        self.assertIn("point3", sim.type_codes)
        for i in range(4, 11):
            self.assertNotIn(f"point{i}", sim.type_codes)
        coordinator.close()

    def test_tactical_enemy_indicators_canonical_types(self):
        """Verifies enemy indicators match canonical types (infantry, vehicle, armor, drone)
        and do not expose legacy aliases (lightVehicle, heavyVehicle)."""
        self.assertIn("infantry", RadarPlayerSimulator.ENEMY_INDICATORS)
        self.assertIn("vehicle", RadarPlayerSimulator.ENEMY_INDICATORS)
        self.assertIn("armor", RadarPlayerSimulator.ENEMY_INDICATORS)
        self.assertIn("drone", RadarPlayerSimulator.ENEMY_INDICATORS)
        self.assertNotIn("lightVehicle", RadarPlayerSimulator.ENEMY_INDICATORS)
        self.assertNotIn("heavyVehicle", RadarPlayerSimulator.ENEMY_INDICATORS)


if __name__ == "__main__":
    unittest.main()
