# RadarMap 12-Player Stress Test Python Simulator

## 1. Overview

The **RadarMap Stress Test Simulator** (`scripts/stress_test_simulator.py`) is a high-performance, single-process multi-player simulation engine designed to stress test the **RadarMap** watchOS/iOS clients and Firebase Realtime Database backend under realistic, high-concurrency tactical operations.

Instead of requiring 12 independent Jupyter notebooks or separate terminal processes, **a single execution coordinates all 12 players concurrently**. It manages individual random walks, closed-loop speed regulation, intermittent cellular network disconnects, and tactical marker drops.

```
+---------------------------------------------------------------------------------------+
|                       RadarMap Stress Test Coordinator (Single Process)               |
|                                                                                       |
|  [Starting Anchor: Lat, Lon]  <--->  [Virtual Squad Room: r/{roomId} (PIN Protected)] |
|                                                                                       |
|   Player 1  (VIPER-1): 4.5 m/s, Net ★★★★★ -> Random Walk -> Drops Marker on Stop      |
|   Player 2  (VIPER-2): 3.0 m/s, Net ★★★★★ -> Random Walk -> Drops Marker on Stop      |
|   Player 3  (GHOST-1): 1.5 m/s, Net ★★★★☆ -> Random Walk -> Drops Marker on Stop      |
|   Player 4  (GHOST-2): 2.0 m/s, Net ★★★★☆ -> Random Walk -> Drops Marker on Stop      |
|   Player 5  (COBRA-1): 5.0 m/s, Net ★★★☆☆ -> Disconnects -> Buffer Coalescing (p/)    |
|   Player 6  (COBRA-2): 3.5 m/s, Net ★★★☆☆ -> Disconnects -> Buffer Coalescing (p/)    |
|   Player 7  (COBRA-3): 2.5 m/s, Net ★★★☆☆ -> Random Walk -> Drops Marker on Stop      |
|   Player 8  (EAGLE-1): 4.0 m/s, Net ★★☆☆☆ -> Edge Outage -> Resumes on Reconnect      |
|   Player 9  (EAGLE-2): 3.0 m/s, Net ★★☆☆☆ -> Edge Outage -> Drops Marker (t/o, t/i)  |
|   Player 10 (WOLF-1) : 6.0 m/s, Net ★★☆☆☆ -> High Speed  -> Buffer Coalescing (p/)    |
|   Player 11 (WOLF-2) : 2.0 m/s, Net ★☆☆☆☆ -> Severe Drop -> Reconnect Flush           |
|   Player 12 (WOLF-3) : 3.5 m/s, Net ★☆☆☆☆ -> Severe Drop -> Reconnect Flush           |
|                                                                                       |
|  Live Multi-Player HUD Dashboard  |  RTDB Endpoints: r/ (Roster), p/ (Telemetry), t/  |
+---------------------------------------------------------------------------------------+
```

---

## 2. Player Definition Table & Configuration

Each simulated player is defined as a tuple:
```python
[callsign: str, average_speed_mps: float, network_quality: int]
```

- **`callsign`**: Alphanumeric callsign (e.g. `"VIPER-1"`, `"GHOST-2"`). Deterministically derives an 8-character Crockford Base32 Member ID (`memberid:CALLSIGN` hashed via SHA-256) matching `database.rules.json` validation: `$memberId.length == 8`.
- **`average_speed_mps`**: Target cumulative average speed in meters per second (e.g., $1.5\text{ m/s}$ walking scout, $4.5\text{ m/s}$ sprinting assault).
- **`network_quality`**: Integer from **1 to 5**, where **5 is best** (cellular reception / link stability).

### Default 12-Player Squad Roster

When invoked without an explicit player table, the simulator launches a complete 12-member squad representing diverse roles, speeds, and wireless conditions:

| Index | Callsign | Role | Target Speed ($v_{\text{avg}}$) | Network Quality (1-5) | Link Behavior |
| :--- | :--- | :--- | :--- | :--- | :--- |
| 1 | **VIPER-1** | Lead Scout | 4.5 m/s (16.2 km/h) | **5 / 5** (★★★★★) | ~98% uptime, rock-solid |
| 2 | **VIPER-2** | Squad Leader | 3.0 m/s (10.8 km/h) | **5 / 5** (★★★★★) | ~98% uptime, rock-solid |
| 3 | **GHOST-1** | Sniper / Recon | 1.5 m/s (5.4 km/h) | **4 / 5** (★★★★☆) | ~92% uptime, occasional drop |
| 4 | **GHOST-2** | Spotter | 2.0 m/s (7.2 km/h) | **4 / 5** (★★★★☆) | ~92% uptime, occasional drop |
| 5 | **COBRA-1** | Point Assault | 5.0 m/s (18.0 km/h) | **3 / 5** (★★★☆☆) | ~80% uptime, moderate dropouts |
| 6 | **COBRA-2** | Support Gunner | 3.5 m/s (12.6 km/h) | **3 / 5** (★★★☆☆) | ~80% uptime, moderate dropouts |
| 7 | **COBRA-3** | Breacher | 2.5 m/s (9.0 km/h) | **3 / 5** (★★★☆☆) | ~80% uptime, moderate dropouts |
| 8 | **EAGLE-1** | Flanker 1 | 4.0 m/s (14.4 km/h) | **2 / 5** (★★☆☆☆) | ~60% uptime, poor cell edge |
| 9 | **EAGLE-2** | Flanker 2 | 3.0 m/s (10.8 km/h) | **2 / 5** (★★☆☆☆) | ~60% uptime, high packet loss |
| 10 | **WOLF-1** | Fast Runner | 6.0 m/s (21.6 km/h) | **2 / 5** (★★☆☆☆) | ~60% uptime, frequent outages |
| 11 | **WOLF-2** | Heavy Weapons | 2.0 m/s (7.2 km/h) | **1 / 5** (★☆☆☆☆) | ~38% uptime, severe blackouts |
| 12 | **WOLF-3** | Rear Guard | 3.5 m/s (12.6 km/h) | **1 / 5** (★☆☆☆☆) | ~38% uptime, harsh terrain drops |

---

## 3. Random Walk Physics & Speed Regulation

Real players never move at a static, unvarying velocity; they sprint between cover, walk carefully, and **frequently stop completely** to scan surroundings, reload, or issue tactical orders.

### Closed-Loop Speed Regulator

To guarantee that the cumulative average speed over time strictly matches the configured target $v_{\text{avg}}$:

$$\bar{v}(T) = \frac{1}{T} \int_0^T v(t)\,dt \longrightarrow v_{\text{avg}}$$

The simulator implements a Markov state machine with closed-loop feedback:

```
                  +---------------------------+
                  |          STOPPED          |
                  |     (v = 0.0 m/s)         |
                  |   [Drops Marker 50%]      |
                  +-------------+-------------+
                                |
               +----------------+----------------+
               |                                 |
               v                                 v
+-----------------------------+   +-----------------------------+
|           WALKING           |   |           RUNNING           |
| (v = 0.5 - 0.9 * v_target)  |   | (v = 1.1 - 1.4 * v_target)  |
+--------------+--------------+   +--------------+--------------+
               |                                 |
               +----------------+----------------+
                                |
                                v
                  +---------------------------+
                  |         SPRINTING         |
                  | (v = 1.5 - 2.0 * v_target)|
                  +---------------------------+
```

1. At each state transition, the simulator evaluates the ratio $\rho = \frac{\bar{v}_{\text{observed}}}{v_{\text{target}}}$:
   - **Running ahead ($\rho > 1.15$)**: Heavily weights transitions into `STOPPED` ($v = 0.0\text{ m/s}$) or `WALKING`.
   - **Lagging behind ($\rho < 0.85$)**: Heavily weights transitions into `RUNNING` or `SPRINTING`.
   - **Balanced ($0.85 \le \rho \le 1.15$)**: Natural human distribution (stops, walks, runs).

2. **Tactical Bounds / Leg Distance (Airsoft Movement)**:
   - Real players in an airsoft match **do not change direction every tick or microsecond**. Instead, they commit to a movement vector (bounding across an open lane, advancing toward a bunker, or flanking along a tree line).
   - Each player selects a **leg target distance** (e.g. $15\text{ m}$ to $40\text{ m}$, configurable via `--min-leg-dist` and `--max-leg-dist`).
   - While traversing this bound, the player's heading is **strictly locked** (zero random per-tick micro-jitter), producing clean tactical vectors on the radar.
   - Upon completing the leg distance, the player arrives at their new position/cover. This triggers a **tactical pivot** (deliberate turn by $\pm 30^\circ, 45^\circ, 60^\circ, 90^\circ, 135^\circ$) and frequently triggers a **stop/pause** (55% probability) behind cover to scan or reload, which can also trigger placing a tactical marker.
   - If a player reaches the operational boundary ($350\text{ m}$ tether), they smoothly steer back towards the central anchor and start a new return bound.
   - Latitude and longitude displacements are calculated using WGS84 geodesic spherical trigonometry:
     $$\Delta \text{lat} = \frac{v \cdot \Delta t \cdot \cos(\theta)}{111139}, \quad \Delta \text{lon} = \frac{v \cdot \Delta t \cdot \sin(\theta)}{111139 \cdot \cos(\text{lat})}$$

---

## 4. Network Quality Degradation Model (Scale 1 to 5)

Each player's wireless connection is governed by a two-state semi-Markov model (`ONLINE` $\leftrightarrow$ `DISCONNECTED`) with parameters calibrated to real-world cellular/GPS conditions:

| Quality Rating | Target Uptime | Mean Online Duration ($\mu_{\text{up}}$) | Mean Outage Duration ($\mu_{\text{down}}$) | Typical Scenario |
| :---: | :---: | :---: | :---: | :--- |
| **5 (Best)** | **98%** | 90.0 s | 2.0 s | Urban 5G / strong Wi-Fi. Brief latency jitter. |
| **4** | **92%** | 45.0 s | 4.0 s | Good LTE. Occasional handoff drops. |
| **3** | **80%** | 25.0 s | 6.0 s | Edge cellular / light forest cover. Periodic disconnects. |
| **2** | **60%** | 15.0 s | 10.0 s | Deep forest / valley / building penetration. Frequent drops. |
| **1 (Worst)**| **38%** | 8.0 s | 13.0 s | Harsh canyon / severe interference. Extended blackouts. |

### Latest-Only Telemetry Coalescing (No Queue Blowup)

RadarMap uses an **Ephemeral Latest-Only** buffering policy matching `FirebaseSyncManager.swift`:
- When a player is **`DISCONNECTED`**, telemetry is **NOT** sent over the wire.
- Rather than buffering hundreds of outdated GPS points (which would flood the network and consume unnecessary Firebase egress upon reconnect), the simulator retains only the **single most recent sample** in memory (`PendingTelemetry`).
- Older samples are coalesced and discarded.
- When the player re-enters **`ONLINE`**, the latest GPS fix is uploaded immediately.

---

## 5. Tactical Marker Placement on Stop

Whenever a player enters the **`STOPPED`** state ($v = 0.0\text{ m/s}$), they evaluate a probability roll (default: 50% chance) to place a tactical marker at their current GPS coordinate.

### Marker Types & RTDB Branches

1. **Squad Orders** (Uploaded to `t/{roomId}/o/{indicatorId}`):
   - `wat` (Watch Here)
   - `goh` (Go Here)
   - `atk` (Attack Here)
   - `def` (Protect Here)
   - `flg` (Flag)
   - `pt1` - `pt3` (Tactical Points 1 through 3)
2. **Enemy & Environment Indicators** (Uploaded to `t/{roomId}/i/{indicatorId}`, subject to room cap):
   - `inf` (Enemy Infantry)
   - `veh` (Enemy Vehicle)
   - `arm` (Enemy Armor)
   - `drn` (Enemy Drone)
   - `haz` (Environmental Hazard)
   - `cls` (Route Closure)

### Wire Payload Schema

Matches RadarMap's compact 5-element array:
```json
[
  "inf",            // 0: 3-letter indicator code
  37.785834,        // 1: Latitude (rounded to 6 decimals)
  -122.406417,      // 2: Longitude (rounded to 6 decimals)
  1788000000.123,   // 3: Epoch timestamp in seconds
  "Y8KM29XA"        // 4: 8-character Member ID of placer
]
```

---

## 6. Live Console HUD & Observability

During execution, the simulator clears and renders a live, full-width ASCII dashboard reporting real-time metrics for all 12 players:

```
⏱️ [T+  45.0s] Room: STRESSS5VHU48YRK | Total Telemetry: 462 pkts | Total Markers: 14
---------------------------------------------------------------------------------------------------------
CALLSIGN   | STATUS  | NET   | STATE     | V_INST  | V_AVG/TGT   | DIST    | PKTS_OK | COALESCE | MARKERS
---------------------------------------------------------------------------------------------------------
VIPER-1    | 🟢 ON   | 5/5   | RUNNING   |  5.2m/s |  4.5/4.5    |   203m  | 44      | 0        |  1 placed
VIPER-2    | 🟢 ON   | 5/5   | STOPPED   |  0.0m/s |  3.0/3.0    |   135m  | 44      | 0        |  2 placed
GHOST-1    | 🟢 ON   | 4/5   | WALKING   |  1.2m/s |  1.5/1.5    |    68m  | 41      | 3        |  2 placed
GHOST-2    | 🟢 ON   | 4/5   | RUNNING   |  2.4m/s |  2.0/2.0    |    90m  | 42      | 2        |  1 placed
COBRA-1    | 🔴 OFF  | 3/5   | SPRINTIN  |  7.5m/s |  5.1/5.0    |   229m  | 36      | 8        |  1 placed
COBRA-2    | 🟢 ON   | 3/5   | STOPPED   |  0.0m/s |  3.4/3.5    |   153m  | 37      | 7        |  2 placed
COBRA-3    | 🟢 ON   | 3/5   | WALKING   |  2.1m/s |  2.5/2.5    |   112m  | 37      | 7        |  1 placed
EAGLE-1    | 🟢 ON   | 2/5   | RUNNING   |  4.8m/s |  3.9/4.0    |   175m  | 27      | 17       |  1 placed
EAGLE-2    | 🔴 OFF  | 2/5   | STOPPED   |  0.0m/s |  3.0/3.0    |   135m  | 28      | 16       |  2 placed
WOLF-1     | 🟢 ON   | 2/5   | SPRINTIN  |  9.2m/s |  5.8/6.0    |   261m  | 26      | 18       |  0 placed
WOLF-2     | 🔴 OFF  | 1/5   | WALKING   |  1.6m/s |  1.9/2.0    |    85m  | 17      | 27       |  1 placed
WOLF-3     | 🟢 ON   | 1/5   | STOPPED   |  0.0m/s |  3.3/3.5    |   148m  | 18      | 26       |  0 placed
---------------------------------------------------------------------------------------------------------
📍 Recent Marker Drop: EAGLE-2:infantry, COBRA-2:watchHere
```

### Final Summary Report

Upon termination (or when `--duration` expires), a comprehensive benchmark report is printed:
- **Total Duration**: Elapsed simulation seconds.
- **Total Telemetry Packets Sent**: Successfully delivered wire frames.
- **Total Offline Coalesce**: Number of obsolete frames discarded during outages (demonstrates bandwidth savings).
- **Per-Player Accuracy**: Observed average speed vs target average speed percentage.
- **Per-Player Uptime**: Measured percentage of time connected.
- **Markers Placed**: Total markers created during stop events.

---

## 7. Interactive Front-End & Execution Modes

### Mode A: Dedicated Jupyter Front-End (`notebooks/stress_test_simulation.ipynb`)

A dedicated interactive notebook cockpit is available at [`notebooks/stress_test_simulation.ipynb`](notebooks/stress_test_simulation.ipynb) (keeping [`notebooks/player_simulation.ipynb`](notebooks/player_simulation.ipynb) untouched for single-player circular trajectory testing):
- **Interactive UI**: Start (`▶`) and Stop (`⏹`) buttons with status indicators and a 10-minute progress bar.
- **Live Vector Radar**: Real-time SVG tactical PPI display showing player blips, heading vectors, cover stops, and connection status.
- **Live Telemetry Table**: Real-time table displaying speeds, network quality, state, packet counts, and dropped markers.

```bash
jupyter notebook notebooks/stress_test_simulation.ipynb
```

### Mode B: Offline Dry-Run CLI (No Credentials Required)

Runs full multi-player physics, speed regulation, network drops, and marker logic locally without connecting to Firebase:

```bash
python3 notebooks/stress_test_simulator.py --dry-run
```

Run with a 30-second duration limit:
```bash
python3 notebooks/stress_test_simulator.py --dry-run --duration 30
```

### Mode C: Live Firebase RTDB Mode

Connects to the live Firebase Realtime Database project (`https://radarmap-8adf0-default-rtdb.firebaseio.com`), creates room node `r/{roomId}`, streams live telemetry to `p/{roomId}/{memberId}`, and places markers under `t/{roomId}`:

```bash
export FIREBASE_CREDENTIALS="/path/to/service-account-key.json"
python3 scripts/stress_test_simulator.py --room STRESS12 --pin 7788
```

Or pass credentials explicitly via CLI:
```bash
python3 scripts/stress_test_simulator.py \
  --credentials /path/to/service-account-key.json \
  --room SQUAD12 \
  --pin 7788 \
  --duration 120
```

### Mode C: Custom Starting Coordinates

Set the simulation anchor to any GPS coordinate on Earth (e.g. outdoor training ground or stadium):

```bash
python3 scripts/stress_test_simulator.py --dry-run \
  --lat 37.774929 \
  --lon -122.419416 \
  --duration 60
```

### Mode D: Custom Player Table (JSON)

Inject custom player definitions directly via the `--players` argument:

```bash
python3 scripts/stress_test_simulator.py --dry-run \
  --players '[
    ["ALPHA-1", 4.0, 5],
    ["ALPHA-2", 3.0, 4],
    ["BRAVO-1", 2.0, 2],
    ["CHARLIE-1", 5.5, 1]
  ]' \
  --duration 45
```

---

## 8. Command-Line Reference

| Flag | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `--lat` | `float` | `37.785834` | Starting anchor latitude. |
| `--lon` | `float` | `-122.406417` | Starting anchor longitude. |
| `--room` | `str` | `STRESS` | Squad room name (sanitized to 12 alphanumeric uppercase characters). |
| `--pin` | `str` | `7788` | Mandatory PIN (4-16 alphanumeric characters). |
| `--players` | `str` | `None` | JSON array of players: `[[callsign, avg_speed_mps, quality_1_to_5], ...]`. Defaults to standard seeded squad roster. |
| `--duration` | `float` | `600.0` (10 min) | Simulation time limit in seconds (default 600s = 10 mins; pass 0 or negative for unlimited). |
| `--interval` | `float` | `1.0` | Telemetry broadcast tick interval in seconds (default 1 Hz). |
| `--marker-prob` | `float` | `0.50` | Probability (0.0 to 1.0) of generating a marker whenever a player stops moving. |
| `--min-leg-dist` | `float` | `15.0` | Minimum distance (meters) traversed along a locked heading before changing direction. |
| `--max-leg-dist` | `float` | `40.0` | Maximum distance (meters) traversed along a locked heading before changing direction. |
| `--database-url` | `str` | `radarmap-8adf0` | Target Firebase Realtime Database URL. |
| `--credentials` | `str` | `None` | Path to Firebase service-account JSON key (or set `FIREBASE_CREDENTIALS`). |
| `--dry-run` | `flag` | `False` | Run in local offline mode without Firebase SDK credentials. |
| `--preserve-room` | `flag` | `False` | Preserve Firebase room nodes upon simulation stop (disables auto-cleanup). |

---

## 9. Automated Test Suite

A complete unit test suite validates all simulation mathematical models, network distributions, and schema encodings:

```bash
python3 -m unittest discover -s tests -p "test_stress_test_simulator.py" -v
```

Verified test coverage:
1. `test_room_name_and_pin_sanitization`: Verifies uppercase alphanumeric enforcement and length limits.
2. `test_member_id_deterministic_derivation`: Verifies 8-character Crockford Base32 ID generation matching Swift clients.
3. `test_room_padding_and_pin_hashing`: Verifies SHA-256 room padding and PIN hash formulas.
4. `test_parse_players_table_json`: Verifies parsing of custom player table JSON formats.
5. `test_default_players_table_has_12_players`: Verifies 12-player squad roster defaults.
6. `test_random_walk_speed_regulation_and_stops`: Verifies speed convergence and forced `STOPPED` state transitions ($v = 0$).
7. `test_network_quality_uptime_scaling`: Verifies quality 5 achieves high uptime while quality 1 generates prolonged drops.
8. `test_marker_generation_on_stop`: Verifies tactical marker generation with valid 5-element schema upon stopping.
9. `test_coordinator_dry_run_multiplayer`: Verifies concurrent multi-player execution in offline dry-run mode.
