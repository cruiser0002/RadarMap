import unittest
import time
import os
import sys
from typing import Any, Dict
from unittest.mock import patch

# Ensure scripts directory is on Python path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "scripts")))

from stress_test_simulator import (
    PlayerSpec,
    SimulatedPlayer,
    RandomWalkController,
    MovementState,
    NetworkQualitySimulator,
    StressTestCoordinator,
    parse_players_table,
    sanitize_room_name,
    sanitize_pin,
    derive_member_id,
    derive_room_padding,
    hash_pin,
    distance_between_meters,
    DEFAULT_SIMULATION_DURATION_SEC,
    SQUAD_ORDER_CODES,
    ENEMY_AND_ENV_CODES,
)


class TestStressTestSimulator(unittest.TestCase):

    def test_room_name_and_pin_sanitization(self):
        """Tests that room name and PIN match RadarMap constraints."""
        self.assertEqual(sanitize_room_name("alpha-room!"), "ALPHAROOM")
        self.assertEqual(sanitize_room_name("VeryLongRoomNameExceeding12Chars"), "VERYLONGROOM")
        self.assertEqual(sanitize_pin("pin 1234 #"), "pin1234")
        self.assertEqual(sanitize_pin("1234 #"), "1234")
        self.assertEqual(sanitize_pin(""), "1234")

    def test_member_id_deterministic_derivation(self):
        """Tests deterministic Crockford Base32 8-char member ID derivation."""
        mid1 = derive_member_id("VIPER-1")
        mid2 = derive_member_id("VIPER-1")
        mid3 = derive_member_id("GHOST-2")

        self.assertEqual(len(mid1), 8)
        self.assertEqual(mid1, mid2)
        self.assertNotEqual(mid1, mid3)
        # All characters must be in Crockford Base32 alphabet
        valid_chars = set("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
        self.assertTrue(all(c in valid_chars for c in mid1))

    def test_room_padding_and_pin_hashing(self):
        """Tests room padding derivation and PIN hashing."""
        pad = derive_room_padding("1234", "ALPHA")
        self.assertEqual(len("ALPHA" + pad), 16)

        pin_h = hash_pin("1234", "ALPHA" + pad)
        self.assertEqual(len(pin_h), 64)  # SHA-256 hex string

    def test_parse_players_table_json(self):
        """Tests custom player table parsing."""
        raw_json = '[["ALPHA-1", 3.5, 5], ["BRAVO-2", 4.0, 2]]'
        specs = parse_players_table(raw_json)
        self.assertEqual(len(specs), 2)
        self.assertEqual(specs[0].callsign, "ALPHA-1")
        self.assertEqual(specs[0].target_avg_speed_mps, 3.5)
        self.assertEqual(specs[0].network_quality, 5)
        self.assertEqual(specs[1].callsign, "BRAVO-2")
        self.assertEqual(specs[1].target_avg_speed_mps, 4.0)
        self.assertEqual(specs[1].network_quality, 2)

    def test_default_players_table_has_12_players(self):
        """Tests default seeded player table contains 12 squad members."""
        specs = parse_players_table(None)
        self.assertEqual(len(specs), 12)
        qualities = [s.network_quality for s in specs]
        self.assertIn(5, qualities)
        self.assertIn(1, qualities)

    def test_random_walk_speed_regulation_and_stops(self):
        """
        Tests that RandomWalkController:
        1. Naturally transitions into STOPPED state (speed = 0).
        2. Regulates average speed towards target over time.
        """
        controller = RandomWalkController(
            center_lat=37.7858,
            center_lon=-122.4064,
            target_avg_speed_mps=4.0,
        )
        now = 1000.0
        dt = 0.5
        encountered_stop = False

        # Run 200 ticks = 100 simulated seconds
        for _ in range(200):
            lat, lon, hdg, speed, state, entered_stop = controller.tick(dt, now)
            if state == MovementState.STOPPED or entered_stop:
                encountered_stop = True
                self.assertEqual(speed, 0.0, "Stopped state must enforce speed = 0 m/s")
            now += dt

        self.assertTrue(encountered_stop, "Speed regulator must trigger STOPPED states")
        # Average observed speed should be within reasonable bound of target (4.0 m/s)
        self.assertGreater(controller.cumulative_avg_speed_mps, 1.0)
        self.assertLess(controller.cumulative_avg_speed_mps, 7.0)

    def test_network_quality_uptime_scaling(self):
        """
        Tests that NetworkQualitySimulator reflects quality scale:
        - Quality 5 should have high uptime (> 85%)
        - Quality 1 should have frequent/long outages (< 65% uptime)
        """
        now = 1000.0
        net_q5 = NetworkQualitySimulator(quality=5, start_time=now)
        net_q1 = NetworkQualitySimulator(quality=1, start_time=now)

        dt = 0.5
        # Simulate 10 minutes (600s)
        for _ in range(1200):
            now += dt
            net_q5.tick(now)
            net_q1.tick(now)

        self.assertGreater(net_q5.current_uptime_ratio, 0.85, "Quality 5 uptime must be high")
        self.assertLess(net_q1.current_uptime_ratio, 0.65, "Quality 1 uptime must be significantly degraded")

    def test_marker_generation_on_stop(self):
        """
        Tests that when player enters STOPPED state, a tactical marker is generated
        with valid 5-element payload [code, lat, lon, ts, memberId].
        """
        spec = PlayerSpec(callsign="SCOUT-1", target_avg_speed_mps=3.0, network_quality=5)
        player = SimulatedPlayer(
            spec=spec,
            center_lat=37.7858,
            center_lon=-122.4064,
            room_id="TESTROOM12345678",
            marker_drop_probability=1.0,  # 100% guarantee for test
        )

        # 1. Test direct marker generation schema
        marker = player._generate_marker(37.7858, -122.4064, 1000.0)
        self.assertIsNotNone(marker)
        self.assertIn("payload", marker)
        payload = marker["payload"]
        self.assertEqual(len(payload), 5)  # [code, lat, lon, ts, memberId]
        self.assertEqual(payload[4], player.member_id)
        self.assertIn(marker["branch"], ["o", "i"])

        # 2. Test stop event triggers marker placement in simulation loop
        now = 1000.0
        dt = 1.0
        marker_placed = False

        for _ in range(150):
            packet, tick_marker, tactical_ops, is_gated = player.tick(dt, now)
            if tick_marker is not None:
                marker_placed = True
                break
            now += dt

        self.assertTrue(marker_placed, "Player with 100% marker probability must drop marker upon stopping")

    def test_squad_order_same_issuer_replace_survives_offline_drop(self):
        """
        Simulates the key network-drop scenario for issuer-based squad order replacement:
        place order A while online, drop the issuer offline, replace it with order B while
        offline (which queues remove(A) then place(B) in the outbox), then reconnect and
        flush. Verifies the outbox preserves FIFO order and the mock RTDB ends up with exactly
        order B — no orphaned order A and no duplicate active orders — matching the offline
        write-queue contract described in FirebaseSyncManager.swift.
        """
        spec = PlayerSpec(callsign="ISSUER-1", target_avg_speed_mps=3.0, network_quality=5)
        player = SimulatedPlayer(
            spec=spec, center_lat=37.7858, center_lon=-122.4064, room_id="TESTROOM12345678",
            marker_drop_probability=1.0,
        )
        mock_rtdb: Dict[str, Any] = {}  # simulates t/{roomId}/o/{id}

        def apply_ops(ops):
            for op in ops:
                if op["op"] == "remove":
                    mock_rtdb.pop(op["id"], None)
                else:
                    mock_rtdb[op["id"]] = op["payload"]

        # 1. Place order A while online; flush immediately (mirrors tick()'s online-gated flush).
        player.net.is_connected = True
        with patch("stress_test_simulator.random.choice", return_value="watchHere"):
            marker_a = player._generate_marker(37.7858, -122.4064, 1000.0)
        self.assertEqual(len(marker_a["ops"]), 1)  # no prior order to remove yet
        apply_ops(marker_a["ops"])
        self.assertIn(marker_a["id"], mock_rtdb)

        # 2. Drop the issuer offline, then replace the order with a different type.
        player.net.is_connected = False
        with patch("stress_test_simulator.random.choice", return_value="attackHere"):
            marker_b = player._generate_marker(37.7858, -122.4064, 1005.0)
        player.pending_tactical_ops.extend(marker_b["ops"])

        # Same-issuer replace queues remove(A) before place(B) — order matters.
        self.assertEqual(len(marker_b["ops"]), 2)
        self.assertEqual(marker_b["ops"][0], {"op": "remove", "branch": "o", "id": marker_a["id"]})
        self.assertEqual(marker_b["ops"][1]["op"], "place")

        # While offline, nothing has actually reached the "server" yet — a teammate who reads
        # now still sees the stale order A.
        self.assertIn(marker_a["id"], mock_rtdb)
        self.assertNotIn(marker_b["id"], mock_rtdb)

        # 3. Reconnect — the outbox flushes in FIFO order.
        player.net.is_connected = True
        apply_ops(player.pending_tactical_ops)
        player.pending_tactical_ops.clear()

        # Recovery: exactly one active order remains (B); A is gone — no orphan, no duplicate.
        self.assertNotIn(marker_a["id"], mock_rtdb)
        self.assertIn(marker_b["id"], mock_rtdb)
        self.assertEqual(len(mock_rtdb), 1)

    def test_coordinator_dry_run_multiplayer(self):
        """
        Tests multi-player coordinator execution in dry-run mode.
        """
        specs = [
            PlayerSpec("LEAD-1", 4.0, 5),
            PlayerSpec("SCOUT-2", 3.0, 3),
            PlayerSpec("RECON-3", 2.0, 1),
        ]
        coordinator = StressTestCoordinator(
            center_lat=37.7858,
            center_lon=-122.4064,
            players=specs,
            room_name="TESTROOM",
            pin="1234",
            dry_run=True,
            tick_interval_sec=0.05,
            marker_probability=0.8,
        )

        self.assertEqual(len(coordinator.players), 3)
        coordinator.run(duration_sec=0.5)

        self.assertGreater(coordinator.total_telemetry_sent, 0)
        self.assertEqual(coordinator.players[0].callsign, "LEAD-1")
        self.assertTrue(coordinator.players[0].is_leader)
        self.assertFalse(coordinator.players[1].is_leader)


    def test_tactical_airsoft_movement_legs_hold_direction_over_distance(self):
        """
        Tests that player does NOT jitter heading every tick/microsecond,
        but instead maintains a locked heading over a realistic tactical distance
        (e.g. 20m), only pivoting after reaching the end of the movement bound.
        """
        controller = RandomWalkController(
            center_lat=37.7858,
            center_lon=-122.4064,
            target_avg_speed_mps=4.0,
            min_leg_distance_meters=20.0,
            max_leg_distance_meters=20.0,
        )
        controller.current_leg_target_distance = 20.0
        controller.current_leg_traveled_distance = 0.0
        controller.state = MovementState.RUNNING
        controller.current_speed_mps = 4.0  # 4 m/s
        controller.state_until_time = 1000.0 + 100.0  # long state duration

        initial_heading = controller.current_heading_deg
        now = 1000.0
        dt = 0.5  # 2 meters per tick

        headings = []
        # Run 9 ticks = 4.5 seconds = 18 meters (< 20m target)
        for _ in range(9):
            lat, lon, hdg, speed, state, entered_stop = controller.tick(dt, now)
            headings.append(hdg)
            now += dt

        # Over all 9 ticks, heading must be strictly identical (no microsecond/per-tick jitter)
        for h in headings:
            self.assertAlmostEqual(h, initial_heading, places=4, msg="Heading must remain locked while traversing bound")

        # Now step 2 more ticks = 4 meters (total 22m > 20m target bound) -> must pivot
        for _ in range(2):
            lat, lon, hdg, speed, state, entered_stop = controller.tick(dt, now)
            now += dt

        # Direction should have pivoted once leg completed
        self.assertNotEqual(controller.current_heading_deg, initial_heading)

    def test_duration_time_limit_default_and_override(self):
        """Tests that coordinator enforces the 10-minute default time limit and respects overrides."""
        players = [PlayerSpec("P1", 3.0, 5)]
        
        # Test 1: Default time limit is 600 seconds (10 minutes)
        coord_default = StressTestCoordinator(
            center_lat=37.7858,
            center_lon=-122.4064,
            players=players,
            dry_run=True,
        )
        self.assertEqual(coord_default.duration_sec, 600.0)
        self.assertEqual(DEFAULT_SIMULATION_DURATION_SEC, 600.0)

        # Test 2: Custom duration override in __init__
        coord_custom = StressTestCoordinator(
            center_lat=37.7858,
            center_lon=-122.4064,
            players=players,
            dry_run=True,
            duration_sec=120.0,
        )
        self.assertEqual(coord_custom.duration_sec, 120.0)

        # Test 3: Execution loop terminates when duration is reached
        start = time.time()
        coord_custom.run(duration_sec=0.2)
        elapsed = time.time() - start
        self.assertGreaterEqual(elapsed, 0.2)
        self.assertLess(elapsed, 2.0)

    def test_squad_order_codes_numbered_indicators(self):
        """Verifies squad order codes contain only point1-3 (pt1-pt3)."""
        self.assertEqual(SQUAD_ORDER_CODES.get("point1"), "pt1")
        self.assertEqual(SQUAD_ORDER_CODES.get("point2"), "pt2")
        self.assertEqual(SQUAD_ORDER_CODES.get("point3"), "pt3")
        for i in range(4, 11):
            self.assertNotIn(f"point{i}", SQUAD_ORDER_CODES)
            self.assertNotIn(f"pt{i}", SQUAD_ORDER_CODES.values())
            self.assertNotIn(f"p{i}", SQUAD_ORDER_CODES.values())

    def test_benchmark_presets(self):
        """Tests that Free and Pro benchmark profiles match requirements."""
        from stress_test_simulator import get_benchmark_players

        free_players = get_benchmark_players("free")
        self.assertEqual(len(free_players), 4)
        self.assertEqual(free_players[0].glance_time_sec, 5.0)
        self.assertEqual(free_players[0].inactivity_time_sec, 30.0)
        self.assertEqual(free_players[0].telemetry_payload_bytes, 200)

        pro_players = get_benchmark_players("pro")
        self.assertEqual(len(pro_players), 12)
        self.assertEqual(pro_players[0].glance_time_sec, 10.0)
        self.assertEqual(pro_players[0].inactivity_time_sec, 20.0)
        self.assertEqual(pro_players[0].telemetry_payload_bytes, 200)

    def test_60_player_rate_adaptation(self):
        """Tests that 60 players follow the heartbeat rate reduction schedule from CLOUD_DATA_MANAGEMENT.md §4."""
        from stress_test_simulator import generate_squad_roster, StressTestCoordinator

        players_60 = generate_squad_roster(60)
        self.assertEqual(len(players_60), 60)

        coordinator = StressTestCoordinator(
            center_lat=37.7858,
            center_lon=-122.4064,
            players=players_60,
            dry_run=True,
        )
        # R(60) = 1.0 * (12 / 60) = 0.20 Hz (interval T = 5.0s, heartbeat = 10 * T = 50.0s)
        self.assertAlmostEqual(coordinator.target_rate_hz, 0.20, places=3)
        self.assertAlmostEqual(coordinator.tick_interval, 5.0, places=3)
        self.assertAlmostEqual(coordinator.refresh_heartbeat_sec, 50.0, places=3)


if __name__ == "__main__":
    unittest.main()

