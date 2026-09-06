# Local Companion Data Sync Architecture

This document formalizes the **Watch-Centric Local Companion Data Sync Model** between iPhone (iOS) and Apple Watch (watchOS) apps via `WatchConnectivity` (`WCSession.updateApplicationContext`).

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
| **§2 Freshness** | `defaultFreshnessTTLSeconds` | `3.0s` | Expiration window for cached sensor samples before marking stale |
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
Target Cadence: **1 Hz**

* **`p2w_hs` (Phone to Watch):**
  * `active_until`: Epoch timestamp (`currentTime + 5s`) signaling Phone foreground/active lease.
* **`w2p_hs` (Watch to Phone):**
  * `active_until`: Epoch timestamp (`currentTime + 5s`) signaling Watch cloud client active lease.
  * `local_telemetry`: Live optical heart rate (`hr`).
  * `remote_telemetry`: Streamed remote squad members' telemetry (`lon`, `lat`, `hr`, `ts`) downloaded by the Watch from the cloud.

### Low-Speed Mergeable Structures (`p2w_ls`, `w2p_ls`)
Transmitted on state change or rolling convergence retry (`sync_ts`).

1. **`config`**: `callsign`, `room_name`, `pin`, `theme`, `is_pro`, `member_id`, `config_ts`
2. **`login_cycle`**: `login_cycle` (`inactive`, `host_active`, `join_active`), `login_cycle_ts`
3. **`room` (membership)**: `members` JSON array of squad members, `member_ts`
4. **`tactical`**: `tactical_indicators` JSON array of placed map markers, `tactical_ts`
5. **`player_state`**: `is_dead`, `is_dead_ts`
6. **`sync_ts`**: Channel synchronization trigger timestamp.

---

## 3. Merge Engine & Conflict Resolution Rules

1. **Per-Structure Timestamp Winner:** For each individual structure (`config`, `login_cycle`, `room`, `tactical`, `player_state`), the structure with the newer timestamp (`*_ts`) wins.
2. **Watch Tie-Breaker:** If timestamps are equal but values differ, **Watch wins**.
3. **Equivalence & sync_ts:**
   * `sync_ts` is control metadata only: it is not compared to choose a state winner and is excluded from state-equivalence checks.
4. **Rolling sync_ts Retransmission:**
   * A device rolls its local `sync_ts` (e.g. 1 Hz) while it advertises any structure that wins against the counterpart's last advertised structure, causing periodic re-advertisement of its latest low-speed snapshot.
   * Stop rolling `sync_ts` after the counterpart advertises an equivalent versioned state for all mergeable structures.
5. **Losing Side Adoption:** The losing device replaces its full local structure with the winner's value and `*_ts`.
6. **Startup Sync:** Upon companion startup, timestamps default to 0 and inherently adopt the active peer's state.

---

## 4. Activity Advertisement & Cloud Access Policy

Each active device refreshes its `active_until = device.time + 5 seconds` every 1 second.

* **Watch Cloud Client Role:**
  * While active in a room session (backed by `HKWorkoutSession`), the Watch is the **primary cloud client** maintaining active Firebase SDK realtime listener / upload updates.
  * `Watch.Time < p2w_hs.active_until`: Phone is active and expects Watch to perform cloud/network work. `p2w_hs.active_until` is an activity signal only; it does not transfer cloud responsibility to Phone.
* **Phone Fallback Client Role:**
  * `Phone.Time > w2p_hs.active_until`: Watch activity advertisement has expired or Watch is absent. Phone becomes the cloud client (best effort, continuity depending on background location updates).
  * `Phone.Time <= w2p_hs.active_until`: Watch is active. Watch remains the cloud client; Phone consumes `w2p_hs` high-speed stream.

