# Local Companion Data Sync Architecture

This document formalizes the **Watch-Centric Local Companion Data Sync Model** between iPhone (iOS) and Apple Watch (watchOS) apps via `WatchConnectivity` (`WCSession.updateApplicationContext`).

## 0. Two Structurally Different Channels — Do Not Cross the Streams

`*_ls` and `*_hs` are not two flavors of the same pattern; they solve different problems and must not be designed, coded, or reasoned about the same way.

* **`*_ls` (Low-Speed) — a bidirectionally-shared variable.** Both devices can independently edit the same logical fields (callsign, `is_dead`, room lifecycle, …), and each field has to converge to one agreed value. That requires a per-field timestamp (`*_ts`) and a merge/winner rule (§3). **`WatchConnectivityManager.localLS` is the single source of truth on each device** — `GameStateManager` holds no shadow copy of any `*_ls` field; every synced property (`isDead`, `myCallsign`, `savedRoomName`, `savedPin`, `customDatabaseURL`, `radarColorTheme`, `myRole`, `isUploadHeartRateEnabled`, `isUploadLocationEnabled`, `isEncryptionEnabled`, `isHosting`) is a plain computed get/set directly onto `localLS`, and a remote merge landing in `localLS` *is* those properties changing — there's no separate "adopt the remote value" step for these fields to fall out of sync in. See `WatchConnectivityManager.mutateLocalConfig`/`mutateLocalPlayerState`/`mutateLocalLoginCycle`.
* **`*_hs` (High-Speed) — two independent one-way streams, not a shared variable.** `p2w_hs` has exactly one writer (Phone) and one reader (Watch); `w2p_hs` has exactly one writer (Watch) and one reader (Phone). There is no merge, no winner-decision, and no field is ever "shared" between them — each side just overwrites its own struct wholesale on every tick, and the reader trusts whatever's currently there as-is (subject to the lease/staleness rules in §4). Any code that merges, diffs, or reconciles `*_hs` data against a local copy is solving a problem this channel doesn't have.

---

## ⚡ Key Companion Sync Constants

The following centralized constants from [`AppConstants.swift`](../RadarMap/AppConstants.swift) (`AppConstants.WatchConnectivity`) govern `WCSession` message routing, lease heartbeats, and timestamp-driven state merging:

| Section & Domain | Constant / Identifier | Value | Protocol Purpose & Architectural Scope |
| :--- | :--- | :--- | :--- |
| **§1 Envelopes** | `p2wHSKey` | `"p2w_hs"` | Phone ➔ Watch High-Speed live telemetry dictionary key |
| **§1 Envelopes** | `w2pHSKey` | `"w2p_hs"` | Watch ➔ Phone High-Speed live telemetry & lease key |
| **§1 Envelopes** | `p2wLSKey` | `"p2w_ls"` | Phone ➔ Watch Low-Speed mergeable snapshot key |
| **§1 Envelopes** | `w2pLSKey` | `"w2p_ls"` | Watch ➔ Phone Low-Speed mergeable snapshot key |
| **§2 Cadence** | `defaultHighSpeedCadenceSeconds` | `1.0s` (1 Hz) | Transmission rate for live `sendMessage` high-speed stream |
| **§3 Structures** | Mergeable Sub-Keys | `config`, `login_cycle`, `room`, `tactical`, `player_state` | Independent timestamped dictionaries (`*_ts`) |
| **§3 Conflict Rule** | Tie-Breaker Priority | **Watch Wins** | Default resolution if timestamps are equal but contents differ |
| **§3 Retransmit** | `sync_ts` Cadence | `1.0 Hz` | Rolling trigger timestamp used until counterpart acknowledges match |
| **§4 Lease** | `activeUntilLeaseDurationSeconds` | `5.0s` (`currentTime + 5s`) | Rolling foreground lease duration for cloud client delegation |
| **§4 Advertisement** | `activeAdvertisementCadenceSeconds` | `1.0s` | Frequency of lease advertisement broadcasts between devices |

---

## 1. Protocol Architecture & Invariants

* **Transport Mechanisms:**
  * **High-Speed Stream (`W2P sendMessage stream`):** `WCSession.sendMessage` provides low-latency delivery of live optical heart rate (`hr`), streamed remote squad telemetry, and the active lease advertisement (`active_until`).
  * **Low-Speed Snapshot Sync (`updateApplicationContext`):** `WCSession.updateApplicationContext` guarantees deterministic, timestamp-driven convergence (`*_ts`) of low-speed state structures (`config`, `login_cycle`, `room`, `tactical`, `player_state`).
* **Directional Envelopes:**
  * **Phone ➔ Watch:** Advertises `p2w_hs` (activity advertisement `active_until`) and `p2w_ls` (merged low-speed snapshot).
  * **Watch ➔ Phone:** Advertises `w2p_hs` (activity advertisement `active_until`, live optical heart rate, and streamed remote squad telemetry) and `w2p_ls` (merged low-speed snapshot).
* **Heading & Sensor Independence:** Heading is computed independently on each device using local sensors + weighted Course Over Ground (COG). Phone heading remains on Phone; Watch heading remains on Watch ("me" orientation on each screen reflects local physical device orientation).
* **GPS Integration:** When both Phone and Watch are present, `CLLocationManager` seamlessly integrates Phone GPS onto the Watch.

---

## 2. Payload Structure

### High-Speed Payloads (`p2w_hs`, `w2p_hs`)
Target Cadence: **1 Hz**. Each is a one-way, single-writer/single-reader struct (see §0) — the writer overwrites it wholesale every tick; the reader takes whatever's currently there as-is. No merge, no `*_ts`, no reconciliation.

* **`p2w_hs` (Phone to Watch), Phone-written / Watch-read only:**
  * `active_until`: Epoch timestamp (`currentTime + 5s`) signaling Phone foreground/active lease.
  * **No `hr` field exists on this struct.** The Phone never has a real optical sensor of its own — see `AppConstants.Health.simulatedHeartRateSlopeBpmPerMps`/`maxSimulatedHeartRate` below — and that simulated value is a display/telemetry-broadcast concern only. `PhoneToWatchHighSpeed` (`CompanionSyncModels.swift`) has no `heartRate` property, so there is no field to carry it even by mistake; the Watch always uses its own sensor for `hr` regardless (§2 consumption rules, §4).
* **`w2p_hs` (Watch to Phone), Watch-written / Phone-read only:**
  * `active_until`: Epoch timestamp (`currentTime + 5s`) signaling Watch cloud client active lease.
  * `hr`: The Watch's own live optical heart rate. Sent unconditionally, every tick — the Watch does not check its own role before writing this; it always reflects "the Watch's current sensor reading."
  * `remote_telemetry`: **A full, accumulated snapshot of every other currently-known squad member's telemetry** (`lon`, `lat`, `hr`, `ts`), not a delta of whichever member(s) changed since the last tick. This is required, not a style choice: the payload is a plain JSON map with no delta/tombstone semantics, and each publish replaces `w2p_hs` wholesale — if the Watch only serialized the member(s) that changed in a given Firebase callback, every other member would silently disappear from `w2p_hs.telemetry` (and therefore from the Phone's view) until they individually happened to trigger their own update. `GameStateManager.persistentRemoteTelemetry` is that continuously-maintained "all currently-known members" map — `updateRemoteTelemetry(packets:)` merges incoming packets into it and prunes members no longer in `firebaseManager.activeRoom?.members`, and `advertiseWatchHighSpeedState(heartRate:)` is the single funnel (telemetry updates, HR ticks, and lease-refresh advertisements all route through it) that serializes the *entire* map on every `w2p_hs` publish — the same full-map-in, full-map-out shape `updateAllTacticalIndicators()`/`syncTacticalToWatchConnectivity()` already use for the `*_ls` `tactical` structure.

#### Consumption rules — all keyed off the same `active_until` comparison

The Phone doesn't make independent decisions for "who's the cloud client," "which HR do I show," and "which telemetry source do I use" — all three are the same `Phone.Time` vs. `w2p_hs.active_until` comparison from §4, applied to different fields:

| `Phone.Time <= w2p_hs.active_until` (Watch is cloud client) | `Phone.Time > w2p_hs.active_until` (Watch's lease expired) |
| :--- | :--- |
| Phone displays `w2p_hs.hr` | Phone falls back to its own simulated `hr` (no sensor — see below) |
| Phone consumes `w2p_hs.remote_telemetry` as its source for other members | Phone becomes its own cloud client and pulls telemetry directly from Firebase |

The Watch side has no equivalent decision to make: it always uses its own sensor for `hr`, and (per its role rule in §4) is the cloud client whenever it's in an active room session, independent of `p2w_hs` — `p2w_hs.active_until` only ever feeds the separate "should I be doing active cloud/network work right now" signal in §4, never a role handoff.

**Phone's fallback `hr` is simulated from movement, not a fixed constant.** When `w2p_hs.hr` isn't present (per the table above — `Phone.Time > w2p_hs.active_until`), `GameStateManager.simulatedHeartRateFromSpeed` estimates it as `min(maxSimulatedHeartRate, defaultRestingHeartRate + smoothedSpeedMps * simulatedHeartRateSlopeBpmPerMps)` (`AppConstants.Health`), where `smoothedSpeedMps` is a 20-sample SMA (`AppConstants.Location.speedSMASampleCount`) of raw `CLLocation.speed` maintained by `LocationHeadingManager`. This value only ever feeds the Phone's own local display and its Firebase telemetry upload (`broadcastLocalTelemetry`) — it is never written into `p2w_hs` (which has no `hr` field, see §2 above), so it can never reach the Watch.

### Low-Speed Mergeable Structures (`p2w_ls`, `w2p_ls`)
Transmitted on state change or rolling convergence retry (`sync_ts`).

1. **`config`**: `callsign`, `room_name`, `pin`, `database_url`, `theme`, `role`, `is_pro`, `is_upload_heart_rate_enabled`, `is_upload_location_enabled`, `is_encryption_enabled`, `config_ts` — deliberately **excludes** `member_id`: it's a pure deterministic function of `callsign` (`GameStateManager.deriveMemberId(fromCallsign:)`, a SHA-256-derived hash), so once `callsign` is synced, each device re-derives the same `member_id` locally. Transmitting it too would be sending the same information twice in two forms, with no mechanism keeping them from drifting apart.
2. **`login_cycle`**: `login_cycle` (`inactive`, `host_active`, `join_active`), `login_cycle_ts`. `host_active`/`inactive` are written by `GameStateManager.isHosting`'s setter; `join_active` is written directly from `sendSessionAction` when `sessionStateMachine.state` reaches `.joined` (there is no `isJoined`-style computed property mirroring `isHosting`). **Host-reconnect exception:** if a room wasn't disbanded gracefully (app killed, crash, connectivity loss), the room survives server-side with its original `hostId` intact; if the device that calls `joinRoom` again is identified as that same host (`room.hostId == myMemberId`, a deterministic per-callsign id — see `config`'s `member_id` note above), the join success handler dispatches `.hostSuccess` instead of `.joinSuccess`, so `login_cycle` converges on `host_active`, not `join_active`, and the peer re-adopts this device as host rather than as a plain member. Whichever device adopts a `host_active`/`join_active` snapshot from the peer (`GameStateManager.adoptCompanionSession`) also re-drives `sessionStateMachine` via `sendSessionAction` with the freshly-fetched room, so the state machine converges identically whether a session was started locally or adopted from a merge — it does not stay stuck on `.disconnected` after a remote-driven adoption.
3. **`room` (membership)**: `members` JSON array of squad members, `member_ts`
4. **`tactical`**: `tactical_indicators` JSON array of placed map markers, `tactical_ts`
5. **`player_state`**: `is_dead`, `is_dead_ts`. Set by a press-and-hold (N seconds) on the HR button, which toggles `is_dead` (true → false on a second press-and-hold); it is not derived from heart rate and carries no direct relationship to the `hr` value in §2's high-speed payloads or the cloud telemetry array (`CLOUD_DATA_MANAGEMENT.md` §7). Instead of transmitting `is_dead` a second time alongside `hr` downstream, every consumer (UX button, WCSession `w2p_hs.hr`, Firebase telemetry upload) is fed one already-collapsed `hr` value — `is_dead ? 0.0 (flatline) : measuredOrDefaultHR` — so `is_dead` and `hr` never travel as two redundant pieces of the same fact past this point. "Measured" here means `w2p_hs.hr` when `GameStateManager.isWatchHeartRateSourcePresent` (`Phone.Time <= w2p_hs.active_until`, same comparison as §2's consumption table) — otherwise "default" is the simulated-from-speed value described above, not the flat 75 constant.
6. **`sync_ts`**: Channel synchronization trigger timestamp.

---

## 3. Merge Engine & Conflict Resolution Rules

Applies to `*_ls` only (see §0) — `*_hs` has no merge step at all.

1. **Per-Structure Timestamp Winner:** For each individual structure (`config`, `login_cycle`, `room`, `tactical`, `player_state`), the structure with the newer timestamp (`*_ts`) wins.
2. **Watch Tie-Breaker:** If timestamps are equal but values differ, **Watch wins**.
3. **Equivalence & sync_ts:**
   * `sync_ts` is control metadata only: it is not compared to choose a state winner and is excluded from state-equivalence checks.
4. **Rolling sync_ts Retransmission:**
   * A device rolls its local `sync_ts` (e.g. 1 Hz) while it advertises any structure that wins against the counterpart's last advertised structure, causing periodic re-advertisement of its latest low-speed snapshot.
   * Stop rolling `sync_ts` after the counterpart advertises an equivalent versioned state for all mergeable structures.
   * **Deliberately NOT gated on `WCSession.isReachable`.** `isReachable` reflects live two-way *messaging* availability (foreground, or high-priority background such as an active workout session) — it is not a reliable signal for "can this data ever reach the counterpart." It is documented, and reported in practice, to read `false` even while a companion is genuinely alive and running in the background (e.g. a Watch mid-workout with the screen off) — this app's primary operating posture. `updateApplicationContext` is explicitly designed to keep working through the system WatchConnectivity daemon regardless of reachability, so gating retransmission on it risks silently stalling convergence to a backgrounded-but-active companion, to save nothing more than a skipped local encode + context-store write. **An earlier revision added this gate and it was reverted for exactly this reason — do not reintroduce it.**
5. **Losing Side Adoption:** The losing device replaces its full local structure with the winner's value and `*_ts`.
6. **Startup Sync:** Upon companion startup, timestamps default to 0 and inherently adopt the active peer's state.

---

## 4. Activity Advertisement & Cloud Access Policy

Each active device refreshes its `active_until = device.time + 5 seconds` every 1 second.

* **Watch Cloud Client Role:**
  * While active in a room session (backed by `HKWorkoutSession`), the Watch is the **primary cloud client** maintaining active Firebase SDK realtime listener / upload updates — independent of the Phone's state entirely; the Phone's activity never affects the Watch's role.
  * `Watch.Time < p2w_hs.active_until`: is an activity signal only; it never transfers cloud-client responsibility to the Phone. It feeds one concrete downstream consumer — see "Two Separate Gates" below.
* **Phone Fallback Client Role:**
  * `Phone.Time > w2p_hs.active_until`: Watch activity advertisement has expired or Watch is absent. Phone becomes the cloud client (best effort, continuity depending on background location updates).
  * `Phone.Time <= w2p_hs.active_until`: Watch is active. Watch remains the cloud client; Phone consumes `w2p_hs` high-speed stream (see §2's consumption-rules table for how HR/telemetry sourcing follow this same comparison).

### Two Separate Gates: Uplink Ownership vs. Listener Attachment

The role decision above governs **uplink ownership** (`GameStateManager.hasNetworkOwnership`: Watch always `true`; Phone only `true` once `Phone.Time > w2p_hs.active_until`) — who is allowed to *write* telemetry to Firebase. **Listener attachment** (whether a device has its three realtime Firebase listeners open — read side) is a related but independent decision, `GameStateManager.evaluateListenerGate()` / `shouldAttachListeners(isWatch:appActive:peerLeaseActive:)`, and is **not** simply "same as the role above" — it's differentiated per platform and additionally depends on `app_active` (literally "is the user looking at this device right now," i.e. `isWristActive` — not "is the process capable of executing code," which would be tautologically true anywhere this is evaluated and therefore meaningless as a condition):

* **Watch:** `app_active OR (watch.Time < p2w_hs.active_until)` — attach if the wearer is actively looking at the Watch, *or* the Phone's lease says it still needs the Watch working (e.g. Watch mid-workout, wrist down, but Phone was recently active).
* **Phone:** `app_active AND (phone.Time > w2p_hs.active_until)` — attach only if the user is actively looking at the Phone **and** the Watch has stepped down (lease expired). Unlike the Watch, the Phone does *not* attach merely because the Watch's lease happens to be active — the two clauses are AND'd, not OR'd, deliberately asymmetric from the Watch's rule.

Both devices' listener gate additionally requires an active tactical session regardless of the above.

