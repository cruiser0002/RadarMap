# Dead Reckoning & Predictive Delta Gating

## ⚡ Key Dead Reckoning Constants

The following centralized constants from [`AppConstants.swift`](../RadarMap/AppConstants.swift) govern sender-side predictive upload gating, geodesic projection, and receiver-side extrapolation:

| Section & Context | Constant / Property | Value | Algorithmic Scope & Purpose |
| :--- | :--- | :--- | :--- |
| **Overview & Gating** | `maxPredictedPositionErrorMeters` | `3.5m` | Max extrapolation error before sender must transmit new sample (`DeltaGating`) |
| **Overview & Gating** | `minHeartRateDeltaBpm` | `12.0 BPM` | Biometric swing threshold (`DeltaGating`) |
| **Overview & Gating** | `heartRateDeltaGatingEnabled` | `false` | Master switch; keeps HR passive to prevent unnecessary GPS uploads |
| **Extrapolation Math**| `metersPerDegreeLatitude` | `111,139.0m` | Geodesic equirectangular planar projection factor (`Location`) |
| **Extrapolation Math**| `degreesToRadiansFactor` | `.pi / 180.0` | Angular conversion factor for longitudinal latitude cosine scaling |
| **Course Over Ground**| `minDisplacementForCourseOverGroundMeters` | `2.0m` | Displacement threshold to filter stationary GPS heading jitter (`Location`) |
| **Upload Scheduling** | `baselineMaxUpdateRateHz` | `1.0 Hz` ($T = 1.0\text{s}$) | Maximum per-client telemetry upload rate ($P \le 12$) (`ConstantBandwidth`) |
| **Upload Scheduling** | Fallback Heartbeat | `10.0 × T` ($10.0\text{s}$ at $1\text{Hz}$) | Maximum time without send before forced refresh heartbeat (`refreshIntervalMultiplier`) |
| **Receiver Rendering**| `remotePlayerDeadReckoningHz` | `1.0 Hz` (1.0s interval) | Cadence for locally recomputing remote squad positions (`DisplayRefresh`) |
| **Receiver Rendering**| `radarUIHz` | `20.0 Hz` (50ms interval) | Vector CRT sweep and target rendering refresh frequency (`DisplayRefresh`) |
| **Peer Stale Cutoff** | `staleTimeoutMultiplier` | `15.0 × T` ($15.0\text{s}$ at $1\text{Hz}$) | Network timeout before marking remote member as stale (gray) |

---

## Why

RTDB bills and bottlenecks on message count and per-message protocol overhead, not on raw
telemetry payload size (the `[lat, lng, hr, ts]` compact array is only ~40 bytes; each message's
JSON envelope costs 100-150+ bytes on top of that). The fix that actually moves the needle is
sending fewer telemetry updates in the first place — not just shrinking each one.

The old gate (`AppConstants.Timing.DeltaGating.minMovementDeltaMeters`, since renamed) suppressed
a send only if raw distance from the last *sent* position stayed under 3.5m. That's naive: someone
walking in a straight line at constant speed still tripped it every ~2.5 seconds, even though a
receiver doing simple constant-velocity extrapolation would already be tracking them accurately the
whole time. Updates are only actually necessary when a peer's prediction of you would be *wrong* —
i.e. on direction changes, stops, or speed changes.

This is the standard "dead-reckoning-gated update" pattern from game netcode (Source engine /
Quake-style delta compression: don't send a state update if the receiver's extrapolation is still
within tolerance).

## Two applications of the same model

Dead reckoning shows up twice in this design, and it's important to keep them distinct:

1. **Sender-side predictive gating** (implemented) — a device runs the extrapolation model on
   *itself*, purely to decide whether it's safe to skip sending a telemetry update. It never
   affects how a device renders its own position.
2. **Receiver-side position synthesis** (implemented, data layer and view wiring both) — a
   device runs the *same* extrapolation model to keep computing *other* players' positions locally
   between real telemetry downloads, instead of freezing at the last received point.

Both must use an **identical** extrapolation formula. If sender and receiver ever diverge (e.g. one
uses linear extrapolation and the other adds easing/damping), the sender's gating decisions will be
based on a receiver behavior that doesn't match reality, and remote positions will silently drift.

## The shared extrapolation model

**Key simplification: no velocity field is transmitted.** Velocity is derived independently on
each side from the last two *position* samples it already has — the sender from its own last two
*sent* samples, the receiver from the last two *received* samples for that member. Since both sides
are deriving velocity from the same two points, they arrive at the same vector with zero additional
wire format cost. The compact telemetry array stays `[lat, lng, hr, ts]` — unchanged.

Given two prior samples `(posA, tA)` and `(posB, tB)` with `tB > tA`:

1. Convert the lat/lon displacement between `posA` and `posB` into local planar meters (flat-earth /
   equirectangular approximation — adequate at the sub-kilometer distances relevant here):
   - `north = (posB.lat - posA.lat) * metersPerDegreeLatitude`
   - `east  = (posB.lon - posA.lon) * metersPerDegreeLatitude * cos(posA.lat in radians)`
2. Derive velocity: `vNorth = north / (tB - tA)`, `vEast = east / (tB - tA)`.
3. To predict position at some later time `t`: project `posB` forward by
   `vNorth * (t - tB)` / `vEast * (t - tB)`, converting back from planar meters to lat/lon offsets.

This is implemented once, canonically, in `DeadReckoning`
([RadarMap/Models/DeadReckoning.swift](../RadarMap/Models/DeadReckoning.swift)) — a stateless
`offsetMeters` / `coordinate` / `predictedCoordinate` utility. Both `GameStateManager` (gating) and
`SquadMember` (rendering) call into this one implementation rather than each maintaining their own
copy, which is what actually guarantees they agree — see Application 1 and 2 below.

## Application 1: Upload gating (implemented)

**Where:** `GameStateManager.shouldEmitTelemetry` / `predictedPositionError`
([GameStateManager.swift:1503](../RadarMap/Managers/GameStateManager.swift)).

**State tracked:** in addition to the existing `lastSentLocation` / `lastSentTimestamp`, a second
retained sample — `secondLastSentLocation` / `secondLastSentTimestamp` — the minimum history needed
to derive a velocity vector. Both are cleared on session stop and shifted forward on every emitted
send (`broadcastLocalTelemetry`).

**Gate logic, in order:**
1. `force` → always send.
2. No prior sent sample at all → always send (first-ever packet).
3. `isDead` transition → always send (state change, not a position matter).
4. Heartbeat fallback interval elapsed (`currentHeartbeatFallbackInterval()`) → always send. This
   is the **sole staleness backstop** — it bounds worst-case correction time independent of whether
   the prediction model is behaving, so no separate absolute-distance backstop is needed alongside
   it.
5. Heart rate moved ≥ `minHeartRateDeltaBpm` → send (biometric changes aren't position-predictable).
6. Otherwise, compute `predictedPositionError`:
   - If there's no second-to-last sample yet, or the interval between the last two sent samples is
     degenerate (`< 0.01s`), fall back to raw distance from the last sent position (bootstrap case).
   - Otherwise, extrapolate from the last two sent samples to `currentTime`, and measure the
     distance between that prediction and the actual current location.
   - Send only if that error ≥ `AppConstants.Timing.DeltaGating.maxPredictedPositionErrorMeters`
     (3.5m — same magnitude as the old flat gate, but now measuring prediction error, not raw
     movement).

**Net effect:** a player moving in a straight line at constant speed sends near-zero updates once
two samples establish their velocity — sends resume only when their actual trajectory diverges from
what a peer's dead reckoning would have predicted (turns, stops, acceleration).

## Application 2: Local rendering of remote players

**Goal:** other players' positions should keep advancing smoothly along their last known
trajectory between real telemetry downloads, instead of freezing until the next update arrives —
the same visual result as if updates were still arriving every second, without actually downloading
anything in between.

**Why this is necessary, not optional:** application 1 makes real updates arrive far less often
during predictable motion. Without application 2, gating success would show up to the player as
other squad members' icons visibly freezing for longer stretches — a regression in perceived
quality even though the underlying data is accurate.

**Implemented:**
1. `SquadMember` ([RadarMap/Models/SquadMember.swift](../RadarMap/Models/SquadMember.swift)) retains
   one prior sample per remote member — `previousLatitude`/`previousLongitude`/
   `previousUpdatedTimestamp` — captured in `FirebaseSyncManager.updateMember(with:in:)`
   ([FirebaseSyncManager.swift](../RadarMap/Managers/FirebaseSyncManager.swift)) right before an
   incoming packet overwrites `latitude`/`longitude`. These fields are local-only, excluded from
   the server-encoded roster payload (same treatment as the other telemetry fields).
2. `SquadMember.extrapolatedCoordinate(at referenceTime:)` calls `DeadReckoning.predictedCoordinate`
   with those two samples. It returns the raw last-known coordinate (no projection) when there
   isn't enough history yet, the interval between samples is degenerate, or the member is
   `.downed`/`.inactive`/stale — dead reckoning only makes sense for a plausibly-still-moving
   player.
3. `GameStateManager.remoteDisplayPositions: [String: CLLocationCoordinate2D]`
   ([GameStateManager.swift](../RadarMap/Managers/GameStateManager.swift)) is a `@Published`
   dictionary, recomputed on a dedicated timer (`startDeadReckoningTimer` /
   `refreshRemoteDisplayPositions`) at a **tunable rate**, independent of the network's actual
   telemetry cadence: `AppConstants.Timing.DisplayRefresh.remotePlayerDeadReckoningHz` (currently
   **1.0 Hz** — deliberately conservative to start; raise it if smoother motion is worth the extra
   CPU/`@Published` churn). The timer starts in `startTacticalSession()` and stops in
   `stopTacticalSession()`, mirroring the existing heartbeat-timer lifecycle.

**View wiring (implemented):** every rendering path that draws a remote member now looks up
`gameState.remoteDisplayPositions[member.id] ?? member.coordinate` instead of reading
`member.coordinate` (raw last-received data) directly:
- [StandardMapView.swift:105-119](../RadarMap/Views/Map/StandardMapView.swift) — `Annotation` coordinate
  and its `.animation(value:)` tracking key.
- [RadarMapView.swift:96-109](../RadarMap/Views/Map/RadarMapView.swift) — the radar-relative distance
  check, screen-space offset calculation, and `.animation(value:)` tracking key.
- [Views/Map/iOS/TacticalMKMapView.swift:304-313](../RadarMap/Views/Map/iOS/TacticalMKMapView.swift) —
  both the existing-`SquadMemberAnnotation` coordinate update and newly-created annotations.
- `TacticalRadarMapView.swift` needed no direct change — it only composes `StandardMapView`/
  `RadarMapView`, both already updated.

In every case, the **local player's own rendering is untouched** — it's always drawn from
`gameState.localPlayerMember` / `meMember` (or MapKit's own `userLocation` dot), a code path
structurally separate from the `otherSquadMembers` loop these edits touched.

**Side effect hit while wiring this in — unrelated `@EnvironmentObject` fan-out:** because
`remoteDisplayPositions` is `@Published` on the same `GameStateManager` instance that
`SettingsView`/`CreateRoomView` hold as `@EnvironmentObject`, this 1Hz tick fires
`objectWillChange` for *every* observer of that instance, not just the map views that actually
read it. Concretely, it made [JoinQRBox.swift](../RadarMap/Views/Room/JoinQRBox.swift)'s QR display
re-diff and repaint once a second while connected, even though the encoded payload
(room/pin/database URL) never changed — `ObservableObject` publishes at whole-object granularity,
so a view has no way to subscribe to only the slice of `GameStateManager` it actually cares about.
Mitigated locally by making `QRCodeView` `Equatable` on its `content` string and applying
`.equatable()` at its call site ([JoinQRBox.swift:68-70](../RadarMap/Views/Room/JoinQRBox.swift)),
so SwiftUI skips re-rendering it whenever the payload is unchanged — this stops the visible
symptom, but the root cause (dead-reckoning state living on the same object as unrelated
session/config state) remains; splitting `remoteDisplayPositions` off `GameStateManager` into its
own map-only observable would eliminate the fan-out at the source instead of patching one symptom
of it.

**Build system gotcha hit while wiring this in:** SwiftPM (`swift build`) auto-discovers source
files under the target path, so it built clean the moment `DeadReckoning.swift` was added. The
actual shipped app (`RadarMap.xcodeproj`) does **not** auto-discover — its file list is generated by
[generate_xcodeproj.py](../generate_xcodeproj.py), which hadn't run since the new file was added, so
`xcodebuild` failed with `cannot find 'DeadReckoning' in scope` even though `swift build` reported
success. Fixed by re-running `python3 generate_xcodeproj.py` before rebuilding. **Takeaway: after
adding a new `.swift` file to this repo, `swift build` alone does not prove the shipped app builds —
re-run `generate_xcodeproj.py` and verify with `xcodebuild` (or Xcode) too.**

## Constants

- `AppConstants.Timing.DeltaGating.maxPredictedPositionErrorMeters` (3.5m) — prediction-error gate
  threshold for uploads.
- `AppConstants.Timing.DeltaGating.minHeartRateDeltaBpm` (12 BPM) — unchanged.
- `AppConstants.Timing.DisplayRefresh.remotePlayerDeadReckoningHz` (**1.0 Hz**, tunable) — how often
  `remoteDisplayPositions` is recomputed for local rendering, independent of real telemetry cadence.
- `AppConstants.Timing.ConstantBandwidth.*` — the 1Hz-ceiling / per-player-count falloff scheduling
  this gate sits underneath; unaffected by this change.
