# RadarMap - Jupyter Notebooks & Player Simulation

This directory contains Jupyter notebooks and Python scripts for simulating squad players in the **RadarMap** watchOS / iOS tactical application.

---

## 📁 Directory Contents

- [`player_simulation.ipynb`](file:///Users/cruiser/Documents/antigravity/jolly-hypatia/notebooks/player_simulation.ipynb): Interactive Jupyter notebook with setup cells, Host/Join operations, live circular trajectory simulation, tactical indicators placement, KIA flatline simulation, and rate adaptation equations.
- [`player_simulator.py`](file:///Users/cruiser/Documents/antigravity/jolly-hypatia/notebooks/player_simulator.py): Self-contained Python module and CLI script implementing the circular motion engine, geodesic bearing / COG calculations, tactical indicator endpoints, and Firebase RTDB synchronization.

---

## 🔑 Firebase Credentials (required)

The simulator talks to Firebase via the **`firebase-admin`** Python SDK (not raw REST calls), using a service-account JSON key — a privileged server credential, separate from and not to be confused with the iOS app's `GoogleService-Info.plist`. This key **bypasses `database.rules.json` entirely**, which is expected for a trusted local script (see `CLOUD_DATA_MANAGEMENT.md` §6).

1. Install the dependency: `pip install -r notebooks/requirements.txt`
2. Download a service-account key from the [Firebase Console](https://console.firebase.google.com/) → radarmap-8adf0 project → Project Settings → Service Accounts → **Generate new private key**.
3. Save it locally under `credentials/` or `notebooks/credentials/` at the repo root — both are already covered by `.gitignore`. **Never commit this file.**
4. Point the simulator at it, either:
   - CLI flag: `--credentials path/to/your-key.json`
   - Environment variable: `export FIREBASE_CREDENTIALS=path/to/your-key.json`
   - Notebook: pass `credentials_path="path/to/your-key.json"` to `RadarPlayerSimulator(...)`

If no credentials are found via either mechanism, the simulator raises a clear error immediately rather than silently falling back to any other auth method.

---

## ⚡ Key Simulator & Protocol Constants

The following centralized constants from [`AppConstants.swift`](../RadarMap/AppConstants.swift) align the Python simulator with the watchOS/iOS client implementation:

| Section & Domain | Constant / Parameter | Value | Description & Code Source |
| :--- | :--- | :--- | :--- |
| **Endpoint** | `defaultDatabaseURL` | `"https://radarmap-8adf0-default-rtdb.firebaseio.com"` | Default RTDB target URL (`Network.defaultDatabaseURL`) |
| **Path Segments** | RTDB Branch Keys | `/r` (rooms), `/p` (telemetry), `/t` (tactical) | Shortened path hierarchy (`ROOM_ID_HARDENING.md`) |
| **Telemetry Array** | Compact 4 Format | `[lat, lon, hr, ts]` | Lean 4-element telemetry payload (`TelemetryPacket`) |
| **Delta Gating** | `maxPredictedPositionErrorMeters` | `3.5m` | Position divergence threshold before upload (`DeltaGating`) |
| **Delta Gating** | `minHeartRateDeltaBpm` | `12.0 BPM` | Heart rate swing threshold (`DeltaGating`) |
| **Fallbacks** | Heartbeat Fallback Multiplier | `10.0 × T` ($10.0\text{s}$ at $1\text{Hz}$) | Maximum time without send when stationary (`ConstantBandwidth`) |
| **Stale Timeout**| `staleTimeoutMultiplier` | `15.0 × T` ($15.0\text{s}$ at $1\text{Hz}$) | Timeout before remote player is flagged stale (`ConstantBandwidth`) |
| **Room Key** | Room ID Lengths | `16` total / `4–12` name / `4–16` PIN | Mandatory PIN validation and 4-char suffix padding (`UI`) |
| **Capacities** | Player Caps | `4` (Free) / `12` (Pro) | Room operator capacity limits (`Subscription`) |
| **Indicators** | Indicator Caps | `0` (Free) / `20` (Pro) | Shared cap on enemy & environmental indicators (`Subscription`) |

---

## ⚙️ Setup Parameters

In the setup section of the notebook (or CLI arguments), you can configure:

| Parameter | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `CALLSIGN` | `str` | `"VIPER-1"` | Player tactical callsign displayed on the radar map. |
| `ROOM_NAME` | `str` | `"ALPHA"` | Room name / Squad identifier (case-insensitive, 4-12 characters; final room ID is 16 chars). |
| `PIN` | `str` | `"1234"` | Mandatory PIN for room access (4-16 digits). |
| `LATITUDE` | `float` | `37.785834` | Center GPS latitude of circular orbit. |
| `LONGITUDE` | `float` | `-122.406417` | Center GPS longitude of circular orbit. |
| `HEART_RATE` | `float` | `115.0` | Heart rate in BPM (`0.0` simulates KIA / downed state). |
| `CIRCLE_RADIUS_METERS` | `float` | `50.0` | Radius of circular path in meters. |
| `SPEED_MPS` | `float` | `4.5` | Movement speed along the circle in meters/second. |
| `UPDATE_INTERVAL_SEC` | `float` | `1.0` | Telemetry packet transmission interval in seconds. |
| `TELEMETRY_FORMAT` | `str` | `"compact4"` | `"compact4"` (`[lat, lng, hr, ts]`), `"compact6"`, `"compact7"`, or `"dict"`. |
| `ENABLE_DELTA_GATING` | `bool` | `False` | Gating movement ($< 3.5\text{m}$) and HR ($< 12\text{ BPM}$) with $7.5\text{s}$ heartbeat fallback. |

---

## 📡 Firebase Schema & Protocol Support

1. **Room Node (`/r/{roomId}`)**:
   - `id`, `hst` (hostId), `cap` (maxCapacity: 4 free / 12 pro), `mti` (maxTacticalIndicators: 0 free / 20 pro), `pin` (pinHash), `exp` (expireAt, refreshed hourly by the host).
   - Roster under `m/{memberId}` with `mid` (id), `csn` (callsign), `rol` (MemberRole: `"leader"` / `"player"`).

2. **Telemetry Stream (`/p/{roomId}/{memberId}`)**:
   - Primary ultra-lean 4-element compact array: `[latitude, longitude, heartRate, timestamp]`, alongside a top-level `exp` refreshed hourly.
   - Forward Course Over Ground (COG) is automatically derived from GPS coordinates or heading tangent.

3. **Tactical Indicators (`/t/{roomId}`)**:
   - **Squad Orders** (`/t/{roomId}/o/{indicatorId}`): `watchHere`, `goHere`, `attackHere` — self-pruning per type per member, uncapped.
   - **Enemy & Environmental Indicators** (`/t/{roomId}/i/{indicatorId}`): `infantry`, `lightVehicle`, `heavyVehicle`, plus environmental types — capped at `mti`.
   - Legacy flat mirrors, `meta/`, and `_updatedAt`/`uts` timestamps have been removed; sync relies on persistent SDK listeners.

4. **Constant Bandwidth Adaptation**:
   - Formula: $R_{max}(P) = R_{base} \times \min(1.0, N_{threshold} / P)$ with $N=12$ and $R_{base}=1.0\text{ Hz}$.

---

## 🚀 How to Run

### Option 1: Using Jupyter Notebook
1. Open [`player_simulation.ipynb`](file:///Users/cruiser/Documents/antigravity/jolly-hypatia/notebooks/player_simulation.ipynb) in your Jupyter environment or IDE.
2. Run **Section 1** to load configuration parameters.
3. Run **Section 2** to initialize the simulator engine.
4. Run **Section 3A (Host)** or **Section 3B (Join)** to connect to the squad room.
5. Run **Section 4** to start the live telemetry stream.
6. Run **Section 5** to test placing tactical indicators.
7. Run **Section 6** to test biometrics / KIA downed states.
8. Run **Section 8** when finished to cleanly leave and clean up Firebase nodes.

### Option 2: Running via Terminal CLI
```bash
# Host a new room 'ALPHA' with callsign 'VIPER-1' running at 4.5 m/s:
python3 notebooks/player_simulator.py --mode host --room ALPHA --pin 1234 --callsign VIPER-1 --radius 50 --speed 4.5 --hr 120 \
    --credentials credentials/your-service-account-key.json

# Join an existing room 'ALPHA' with callsign 'BRAVO-2' using compact4 format:
python3 notebooks/player_simulator.py --mode join --room ALPHA --pin 1234 --callsign BRAVO-2 --radius 30 --speed 3.5 --format compact4 \
    --credentials credentials/your-service-account-key.json
```

(Or set `FIREBASE_CREDENTIALS` once in your shell and omit `--credentials` on every invocation.)
