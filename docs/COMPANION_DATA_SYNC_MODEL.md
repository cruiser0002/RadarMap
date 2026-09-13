# Local Companion Data Sync Architecture

> **No unauthorized architecture. Simple is reliable.** Any new fallback, degrade-path, or "if the primary approach fails, patch with X" branch — in code or in this doc — requires the user's explicit, affirmative approval given in the conversation before it is written, every single time, even if a similar one was approved before. Never introduce a stub/placeholder value meant to be corrected later unless that correction is guaranteed to run first — when two code paths compute the same information, delete one rather than adding reconciliation/self-heal/validation logic to let both keep existing. See `CLAUDE.md` rules 2 and 3.

This document formalizes the **Watch-Centric Local Companion Data Sync Model** between iPhone (iOS) and Apple Watch (watchOS) apps via `WatchConnectivity` (`WCSession.sendMessage` and `WCSession.updateApplicationContext`).

---

> [!CAUTION]
> # CARDINAL ARCHITECTURAL INVARIANT: WCSESSION PURPOSE
> **ALL `WCSession` variables are strictly and exclusively for PHONE-TO-WATCH transport. ALL OF THEM must continue sync transport regardless of ANY web or internet connection. They are entirely unrelated items.**
>
> 1. **Zero Web/Firebase Coupling**: `WCSession` is a local peer-to-peer radio transport between iOS and watchOS over Bluetooth / peer-to-peer Wi-Fi. It has **nothing** to do with Firebase, web connectivity, internet access, cell service, or server squad rooms.
> 2. **Continuous Offline Operation for ALL Variables**: Every single variable carried over `WCSession` continues bidirectional or directional sync whenever either companion device is active (`isWristActive`), whether online, offline, airplane mode, or entirely outside any squad room session.
> 3. **Exhaustive Roster of WCSession Variables (ALL Decoupled from Web Connections)**:
>
> | Transport Channel | WCSession Variable | Direction | Sync Mechanism | Web Connection Dependency |
> | :--- | :--- | :---: | :--- | :--- |
> | **High-Speed (`*_hs`)** | `p2w_hs.active_until` | Phone ➔ Watch | `sendMessage` (1 Hz) | **NONE (Zero)**. Advertises Phone presence continuously. |
> | **High-Speed (`*_hs`)** | `p2w_hs.remote_telemetry` | Phone ➔ Watch | `sendMessage` (1 Hz) | **NONE (Zero)**. Relays cached/local teammate telemetry. |
> | **High-Speed (`*_hs`)** | `w2p_hs.active_until` | Watch ➔ Phone | `sendMessage` (1 Hz) | **NONE (Zero)**. Advertises Watch presence continuously. |
> | **High-Speed (`*_hs`)** | `w2p_hs.hr` | Watch ➔ Phone | `sendMessage` (1 Hz) | **NONE (Zero)**. Streams live optical heart rate from sensor. |
> | **High-Speed (`*_hs`)** | `w2p_hs.remote_telemetry` | Watch ➔ Phone | `sendMessage` (1 Hz) | **NONE (Zero)**. Relays cached/local squad telemetry. |
> | **Low-Speed (`*_ls`)** | `config.callsign` | Phone ⮂ Watch | CRDT LWW (`configTs`) | **NONE (Zero)**. Edits sync immediately between devices. |
> | **Low-Speed (`*_ls`)** | `config.roomName` | Phone ⮂ Watch | CRDT LWW (`configTs`) | **NONE (Zero)**. Edits sync immediately between devices. |
> | **Low-Speed (`*_ls`)** | `config.pin` | Phone ⮂ Watch | CRDT LWW (`configTs`) | **NONE (Zero)**. Edits sync immediately between devices. |
> | **Low-Speed (`*_ls`)** | `config.databaseURL` | Phone ⮂ Watch | CRDT LWW (`configTs`) | **NONE (Zero)**. Edits sync immediately between devices. |
> | **Low-Speed (`*_ls`)** | `config.theme` | Phone ⮂ Watch | CRDT LWW (`configTs`) | **NONE (Zero)**. Edits sync immediately between devices. |
> | **Low-Speed (`*_ls`)** | `config.role` | Phone ⮂ Watch | CRDT LWW (`configTs`) | **NONE (Zero)**. Edits sync immediately between devices. |
> | **Low-Speed (`*_ls`)** | `config.isPro` | Phone ⮂ Watch | CRDT LWW (`configTs`) | **NONE (Zero)**. StoreKit / debug unlock syncs between devices. |
> | **Low-Speed (`*_ls`)** | `config.isUploadHeartRateEnabled` | Phone ⮂ Watch | CRDT LWW (`configTs`) | **NONE (Zero)**. Preference toggle syncs between devices. |
> | **Low-Speed (`*_ls`)** | `config.isUploadLocationEnabled` | Phone ⮂ Watch | CRDT LWW (`configTs`) | **NONE (Zero)**. Preference toggle syncs between devices. |
> | **Low-Speed (`*_ls`)** | `config.isEncryptionEnabled` | Phone ⮂ Watch | CRDT LWW (`configTs`) | **NONE (Zero)**. AES crypto alignment syncs between devices. |
> | **Low-Speed (`*_ls`)** | `player_state.is_dead` | Phone ⮂ Watch | CRDT LWW (`is_dead_ts`) | **NONE (Zero)**. Tag-out status syncs between devices immediately. |
> | **Low-Speed (`*_ls`)** | `tactical.tacticalJson` | Phone ⮂ Watch | CRDT LWW (`tacticalTs`) | **NONE (Zero)**. Local markers/orders sync between devices offline. |
> | **Low-Speed (`*_ls`)** | `membership.membersJson` | Phone ⮂ Watch | CRDT LWW (`memberTs`) | **NONE (Zero)**. Cached squad roster syncs between devices. |
> | **Low-Speed (`*_ls`)** | `login_cycle.loginCycle` | Phone ⮂ Watch | CRDT LWW (`loginCycleTs`) | **NONE (Zero)**. Host/Join intent converges between devices. |
> | **Transport Control** | `sync_ts` | Phone ⮂ Watch | Rolling Pump (1 Hz) | **NONE (Zero)**. Retransmission token for context convergence. |
>
> 4. **Forbidden Anti-Patterns**:
>    - ❌ **NEVER** check `isTacticalSessionActive`, `firebaseManager.isConnected`, or `firebaseManager.activeRoom` anywhere in `WatchConnectivityManager` or in WCSession sync triggers.
>    - ❌ **NEVER** cancel `activeAdvertisementTimer` or `rollingTimer` on Firebase session disconnect or logout.
> 5. **One-Way Dependency Rule**: Firebase cloud adapters read WCSession presence (`active_until`) to decide who writes/listens to Firebase. Firebase never, under any circumstances, gates or controls WCSession transport.

---

## 0. Two Structurally Different Channels — Do Not Cross the Streams

`*_ls` and `*_hs` are not two flavors of the same pattern; they solve different problems and must not be designed, coded, or reasoned about the same way.

* **`*_ls` (Low-Speed) — a bidirectionally-shared variable.** Both devices can independently edit the same logical fields (callsign, `is_dead`, room lifecycle, …), and each field has to converge to one agreed value. That requires a per-field timestamp (`*_ts`) and a merge/winner rule (§3). **`WatchConnectivityManager.localLS` is the single source of truth on each device** — `GameStateManager` holds no shadow copy of any `*_ls` field; every synced property (`isDead`, `myCallsign`, `savedRoomName`, `savedPin`, `customDatabaseURL`, `radarColorTheme`, `myRole`, `isUploadHeartRateEnabled`, `isUploadLocationEnabled`, `isEncryptionEnabled`, `isHosting`) is a plain computed get/set directly onto `localLS`, and a remote merge landing in `localLS` *is* those properties changing — there's no separate "adopt the remote value" step for these fields to fall out of sync in. See `WatchConnectivityManager.mutateLocalConfig`/`mutateLocalPlayerState`/`mutateLocalLoginCycle`.
  * `tactical`/`membership` are serialized *views* GameStateManager computes from other owned state (local tactical indicators, Firebase room membership) rather than simple leaf fields, so they're written through `GameStateManager.syncTacticalToWatchConnectivity`/`syncMembershipToWatchConnectivity` instead of a direct computed-property setter. Both still enforce the same rule as the mutators above: `*_ts` (`tacticalTs`/`memberTs`) only bumps when the serialized content actually differs from what this device already published (checked before constructing the new stamped snapshot), so a recompute that lands back on identical content — e.g. after adopting the peer's own winning structure via `MergeEngine.merge`'s direct `localLS` assignment (§3) — never re-publishes it under a fresh timestamp as if it were a new local edit. `isApplyingRemoteSync` additionally short-circuits both functions for the duration of convergence adoption itself.
* **`*_hs` (High-Speed) — two independent one-way streams, not a shared variable.** `p2w_hs` has exactly one writer (Phone) and one reader (Watch); `w2p_hs` has exactly one writer (Watch) and one reader (Phone). There is no merge, no winner-decision, and no field is ever "shared" between them — each side just overwrites its own struct wholesale on every tick, and the reader trusts whatever's currently there as-is (subject to the lease/staleness rules in §4). Any code that merges, diffs, or reconciles `*_hs` data against a local copy is solving a problem this channel doesn't have.
  * **`activeUntil` and `remotePlayerTelemetryJson` each exist as two separate fields, one per struct** (`PhoneToWatchHighSpeed.activeUntil`/`remotePlayerTelemetryJson` and `WatchToPhoneHighSpeed.activeUntil`/`remotePlayerTelemetryJson` — `CompanionSyncModels.swift:174-175,210-212`) — not one shared field. Each direction's copy is written only by that direction's sender and read only by that direction's receiver, per the point above; there is no single `activeUntil`/`remotePlayerTelemetryJson` variable, there are two, and a given device only ever writes one of them (its own outbound struct) and reads the other (its inbound struct).
  * **`heartRate` exists on `WatchToPhoneHighSpeed` only** — there is no `PhoneToWatchHighSpeed.heartRate`, since the Watch is the sole optical-HR source; the Phone never has HR of its own to advertise.
  * **`companionActiveUntil` is the one role-based selector for lease data.** `WatchConnectivityManager.companionActiveUntil` (`WatchConnectivityManager.swift:45-47`) picks `localRole == .phone ? w2pHS.activeUntil : p2wHS.activeUntil`, and every consumer of companion-lease data goes through it rather than hardcoding `p2wHS`/`w2pHS` by role at the call site. Telemetry and heart rate are *not* funneled through an equivalent accessor: `handleIncomingApplicationContext` reads `p2wHS.remotePlayerTelemetryJson`/`w2pHS.remotePlayerTelemetryJson` inline by role and fires `onHighSpeedTelemetryReceived` (`WatchConnectivityManager.swift:499,507-508`), and heart rate flows through `onHighSpeedHeartRateReceived` into `healthKitManager`/`GameStateManager.effectiveHeartRate` rather than a `WatchConnectivityManager` accessor. A prior revision had `latestRemoteTelemetryJson`/`latestRemoteHeartRate` accessors mirroring `companionActiveUntil`'s shape, but nothing ever called them — the real relay paths above predate or bypassed them — so they were dead code and have been removed. Any new consumer of `*_hs` telemetry/HR data should go through the existing inline role-branch/callback paths, not reintroduce a parallel accessor.

### Architectural Invariant: Zero Redundant Storage for `activeUntil`

There must **never** be any other local storage or shadow copies of `activeUntil` (e.g., `latestRemoteActiveUntil`, cached `lastPublishedWatchHS`, `lastPublishedPhoneHS`).
* **Direct Outbound Assignment:**
  * **Watch:** `w2p_hs.activeUntil = watch.time + leaseTime (5s)` is directly written into this variable.
  * **Phone:** `p2w_hs.activeUntil = phone.time + leaseTime (5s)` is directly written into this variable.
* **Direct Inbound Consumption:**
  * **Watch:** `p2w_hs.activeUntil` is directly used for companion presence evaluation and lease horizon calculation.
  * **Phone:** `w2p_hs.activeUntil` is directly used for companion presence evaluation and lease horizon calculation.
* **Channel Isolation in Context Publishing:**
  * Low-speed context updates (`updateApplicationContext` for `*_ls`) must **never** bundle stale cached high-speed payloads.
  * Re-transmitting an unrefreshed high-speed struct inside low-speed sync cycles transmits expired timestamps, corrupting the receiver's companion lease calculation and causing UI indicators (such as debug menu digits 5 & 6) to oscillate between valid (`+3`) and expired (`-9`). Low-speed publishing must leave high-speed fields `nil`.

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

**Phone's `hr` is simulated from movement whenever Watch isn't connected — an explicit design, not a reaction to a failure.** Phone has no HR sensor of its own; whenever `w2p_hs.hr` isn't present (per the table above — `Phone.Time > w2p_hs.active_until`), it is Phone's designed, permanent behavior to simulate `hr` rather than show a real reading, not a fixed constant. `GameStateManager.simulatedHeartRateFromSpeed` estimates it as `min(maxSimulatedHeartRate, defaultRestingHeartRate + smoothedSpeedMps * simulatedHeartRateSlopeBpmPerMps)` (`AppConstants.Health`), where `smoothedSpeedMps` is a 20-sample SMA (`AppConstants.Location.speedSMASampleCount`) maintained by `LocationHeadingManager`. `LocationHeadingManager` tracks the latest raw `CLLocation.speed` on every GPS/compass callback, but the SMA itself is only advanced once per second by `sampleSpeedForSMA()`, called from `GameStateManager.advertiseActiveLease()` — the same single 1Hz `activeAdvertisementTimer` tick that drives the `w2p_hs`/`p2w_hs` lease refresh (see §4). `sim_hr` and the lease refresh deliberately share one "Local refresh rate (1Hz)" clock rather than each running off its own timer or off CoreLocation's own (non-1Hz, bursty-or-silent) delegate cadence. This value only ever feeds the Phone's own local display and its Firebase telemetry upload (`broadcastLocalTelemetry`) — it is never written into `p2w_hs` (which has no `hr` field, see §2 above), so it can never reach the Watch.

### Low-Speed Mergeable Structures (`p2w_ls`, `w2p_ls`)
Transmitted on state change or rolling convergence retry (`sync_ts`).

1. **`config`**: `callsign`, `room_name`, `pin`, `database_url`, `theme`, `role`, `is_pro`, `is_upload_heart_rate_enabled`, `is_upload_location_enabled`, `is_encryption_enabled`, `config_ts` — deliberately **excludes** `member_id`: it's a pure deterministic function of `callsign` (`GameStateManager.deriveMemberId(fromCallsign:)`, a SHA-256-derived hash), so once `callsign` is synced, each device re-derives the same `member_id` locally. Transmitting it too would be sending the same information twice in two forms, with no mechanism keeping them from drifting apart. `room_name`/`pin` themselves are the same story one level up: the actual Firebase room id, its `pinHash`, and its telemetry encryption key are all likewise excluded and re-derived locally by every consumer from these two fields via `FirebaseSyncManager.deriveRoomId(name:pin:)` (see [CLOUD_DATA_MANAGEMENT.md](CLOUD_DATA_MANAGEMENT.md) §7.A) — `adoptCompanionSession` (below) once inlined its own copy of that derivation and let it drift out of sync with `hostRoom`/`joinRoom`'s, which is exactly the kind of bug this exclusion principle is meant to prevent; all three now call the one shared function.
2. **`login_cycle`**: `login_cycle` (`inactive`, `host_active`, `join_active`), `login_cycle_ts`. `host_active`/`inactive` are written by `GameStateManager.isHosting`'s setter; `join_active` is written directly from `sendSessionAction` when `sessionStateMachine.state` reaches `.joined` (there is no `isJoined`-style computed property mirroring `isHosting`).
   * **Host-reconnect exception:** if a room wasn't disbanded gracefully (app killed, crash, connectivity loss), the room survives server-side with its original `hostId` intact; if the device that calls `joinRoom` again is identified as that same host (`room.hostId == myMemberId`, a deterministic per-callsign id — see `config`'s `member_id` note above), the join success handler dispatches `.hostSuccess` instead of `.joinSuccess`, so `login_cycle` converges on `host_active`, not `join_active`, and the peer re-adopts this device as host rather than as a plain member. Whichever device adopts a `host_active`/`join_active` snapshot from the peer (`GameStateManager.adoptCompanionSession`) also re-drives `sessionStateMachine` via `sendSessionAction` with the freshly-fetched room, so the state machine converges identically whether a session was started locally or adopted from a merge — it does not stay stuck on `.disconnected` after a remote-driven adoption.
   * **Session-Ephemeral Invariant (No Persistence Across Sessions):** `login_cycle` is strictly session-ephemeral and is **never saved across sessions**. When `localLS` or `peerLS` are written to persistent storage (`UserDefaults`), `login_cycle` is sanitized to `inactive` with `login_cycle_ts = 0.0`. On app launch / cold boot, both `localLS.loginCycle` and `peerLS.loginCycle` always start as `.inactive` (with timestamp `0.0`) by default. This guarantees that restarting an app or companion never resurrects a stale active hosting or joined state from a prior session.
3. **`room` (membership)**: `members` JSON array of squad members, `member_ts` — this is the single authoritative membership list, populated only from the roster channel (`FirebaseSyncManager.mergeRemoteMembers`/`applyMembersSnapshot`, which decode real `callsign`/`role` from Firebase directly). Remote-player telemetry defers to it rather than inserting members from incomplete data of its own: `FirebaseSyncManager.updateMember(with:in:)` only ever updates an *existing* member (one the roster channel already established) — telemetry for an unrecognized member id is rejected rather than used to fabricate a placeholder member with an empty callsign. See `CLAUDE.md` rule 3, "simple is reliable — no stubs, no stacked patches." (Tactical markers are not gated against this list — an unresolved `placed_by_member_id` still renders, just with a blank/guessed placer name, since telemetry misattribution has real consequences (a fabricated member record) that a display-only label doesn't.)
4. **`tactical`**: `tactical_indicators` JSON array of placed map markers, `tactical_ts`.
5. **`player_state`**: `is_dead`, `is_dead_ts`. Set by a press-and-hold (N seconds) on the HR button, which toggles `is_dead` (true → false on a second press-and-hold); it is not derived from heart rate and carries no direct relationship to the `hr` value in §2's high-speed payloads or the cloud telemetry array (`CLOUD_DATA_MANAGEMENT.md` §7). Instead of transmitting `is_dead` a second time alongside `hr` downstream, every consumer (UX button, WCSession `w2p_hs.hr`, Firebase telemetry upload) is fed one already-collapsed `hr` value — `is_dead ? 0.0 (flatline) : measuredOrDefaultHR` — so `is_dead` and `hr` never travel as two redundant pieces of the same fact past this point. "Measured" here means `w2p_hs.hr` when `GameStateManager.isWatchHeartRateSourcePresent` (`Phone.Time <= w2p_hs.active_until`, same comparison as §2's consumption table) — otherwise "default" is the simulated-from-speed value described above, not the flat 75 constant.
6. **`sync_ts`**: Channel synchronization trigger timestamp.

---

## 3. Merge Engine & Conflict Resolution Rules

Applies to `*_ls` only (see §0) — `*_hs` has no merge step at all.

1. **Per-Structure Timestamp Winner:** For each individual structure (`config`, `login_cycle`, `room`, `tactical`, `player_state`), the structure with the newer timestamp (`*_ts`) wins.
2. **Watch Tie-Breaker:** If timestamps are equal but values differ, **Watch wins**.
3. **`*_ts` updates only for real, not convergence-induced, data changes.** A structure's `*_ts` advances *only* when this device makes a genuine local change to it (a real edit, or genuinely new content merged in from a source this device owns — e.g. Firebase for `tactical`/`room`). Adopting the peer's winning structure (rule 6 below) is explicitly excluded: the losing device copies the winner's `*_ts` verbatim rather than minting a new one, so a convergence copy never masquerades as a fresh edit. This is why `MergeEngine.merge`'s direct `localLS = mergedLocal` assignment in `handleIncomingApplicationContext` — not a `Date()`-stamping setter — is the correct mechanism for adoption; see `WatchConnectivityManager.mutateLocalConfig`/`mutateLocalPlayerState`/`mutateLocalLoginCycle` and `GameStateManager.syncTacticalToWatchConnectivity`/`syncMembershipToWatchConnectivity` for the parallel "only stamp on genuine content change" discipline applied to locally-originated writes.
4. **Equivalence & sync_ts:**
   * `sync_ts` is control metadata only: it is not compared to choose a state winner and is excluded from state-equivalence checks.
   * Unlike `*_ts` (rule 3), `sync_ts` rolls on **either** kind of event — a real edit or a convergence copy-in — because its only job is announcing "the counterpart needs to see my current copy," which is equally true whether that copy just changed because *this* device authored something or because it adopted the peer's.
5. **Rolling sync_ts Retransmission:**
   * `sync_ts` rolls **immediately** whenever local data changes for any reason — a genuine local edit that wins a structure outright, *or* a losing structure being replaced by the winner's value per rule 6 below (an external update copied in) — ensuring the outbound context snapshot carries the latest timestamp with zero delay either way. It is this rolling, not who won, that informs the other side; see `WatchConnectivityManager.handleIncomingApplicationContext`, which rolls on `localWins || localChanged`, not `localWins` alone.
   * It **continues to roll** periodically (1 Hz) via the rolling timer pump while and only while that condition holds — i.e. while the local device still has something (a win or a fresh copy) the counterpart hasn't yet acknowledged.
   * Stop rolling `sync_ts` immediately after the counterpart advertises an equivalent versioned state (`isDomainEquivalent == true`) for all mergeable structures, resolving the discrepancy — this is how convergence is reached. **This check must also run on the rolling timer's own tick, not only reactively when a peer message arrives** (`WatchConnectivityManager.rollSyncTimestampAndPublish`): once both sides are genuinely equal, the peer correctly stops echoing back (nothing new to adopt), so if the only place that ever called `stopRollingSync()` were the incoming-message handler, the device that's still rolling would never receive another message to react to and would be orphaned mid-broadcast — republishing identical, already-converged state at 1 Hz forever. Re-checking convergence against `peerLS` on every tick, before republishing, closes that gap.
   * **Equivalence depends on deterministic JSON encoding of `membersJson`/`tacticalJson` — this is the paired "sort" half of self-echo filtering (`CLOUD_DATA_MANAGEMENT.md` §5.B), not a separate concern.** `MembershipSnapshot`/`TacticalSnapshot` carry their arrays as pre-serialized JSON strings, and `isDomainEquivalent` compares those strings with `==`. `JSONEncoder`'s per-object key order is otherwise unspecified and can differ between two `encode()` calls for byte-identical content, so without both (a) a stable array order (`GameStateManager.syncMembershipToWatchConnectivity` sorts the roster by `id`; `syncTacticalToWatchConnectivity` sorts indicators by `timestamp`) and (b) `encoder.outputFormatting = .sortedKeys` on both encoders, identical content can round-trip through re-encoding into a string that no longer compares equal to itself — registering a fake "change," stamping a fresh `sync_ts`, and restarting the rolling pump on data that never actually changed. Both requirements are enforced at the one place each string is produced, not corrected after the fact.
   * **Deliberately NOT gated on `WCSession.isReachable`.** `isReachable` reflects live two-way *messaging* availability (foreground, or high-priority background such as an active workout session) — it is not a reliable signal for "can this data ever reach the counterpart." It is documented, and reported in practice, to read `false` even while a companion is genuinely alive and running in the background (e.g. a Watch mid-workout with the screen off) — this app's primary operating posture. `updateApplicationContext` is explicitly designed to keep working through the system WatchConnectivity daemon regardless of reachability, so gating retransmission on it risks silently stalling convergence to a backgrounded-but-active companion, to save nothing more than a skipped local encode + context-store write. **An earlier revision added this gate and it was reverted for exactly this reason — do not reintroduce it.**
   * **Is gated, however, on basic WCSession viability**, distinct from the `isReachable` exclusion above: `WatchConnectivityManager.publishApplicationContext(local:)` and `startRollingSync()` both require `WCSession.isSupported()`, `session.activationState == .activated`, and (iOS only) `session.isPaired && session.isWatchAppInstalled` before publishing or rolling at all. This is a one-time "can this device's WCSession ever reach a paired/installed Watch app" check, not a per-tick liveness check — it doesn't reintroduce the `isReachable` gating rejected above.
6. **Losing Side Adoption:** The losing device replaces its full local structure with the winner's value and `*_ts`.
7. **Startup Sync & Ephemeral Lifecycle:** Upon companion startup, `login_cycle` always defaults to `inactive` with `login_cycle_ts = 0` (unconditionally cleared from persistence), ensuring that a booting device cleanly adopts any active peer's live session (`peer.login_cycle_ts > 0` wins over `0`) without mistakenly reviving a stale session. Persistent user preferences (`config`) and player state (`player_state`) preserve their persisted values.

---

## 4. Activity Advertisement & Cloud Access Policy

Each active device refreshes its `active_until = device.time + 5 seconds` every 1 second while active (`isWristActive = true`).
* **Transport Independence:** This advertisement travels strictly over local `WCSession` transport (`sendMessage` only — no fallback channel; a missed tick self-heals on the next 1Hz tick once reachable again, or via the TTL backstop) and runs continuously whenever the app is open/active, **completely independent of whether a Firebase squad room is joined or whether the device is offline**.
* **Lease Reception:** On the counterpart device, receiving `active_until` continuously establishes companion presence (e.g. producing `00P0+300` on the Watch or `00W0+300` on the iPhone when offline).

* **Watch Cloud Client Role:**
  * While active in a room session (backed by `HKWorkoutSession`), the Watch is the **primary cloud client** maintaining active Firebase SDK realtime listener / upload updates — independent of the Phone's state entirely; the Phone's activity never affects the Watch's role.
  * `Watch.Time < p2w_hs.active_until`: is an activity signal only; it never transfers cloud-client responsibility to the Phone. It feeds one concrete downstream consumer — see "Two Separate Gates" below.
* **Phone Secondary Client Role:**
  * `Phone.Time > w2p_hs.active_until`: Watch activity advertisement has expired or Watch is absent. Phone becomes the cloud client (best effort, continuity depending on background location updates).
  * `Phone.Time <= w2p_hs.active_until`: Watch is active. Watch remains the cloud client; Phone consumes `w2p_hs` high-speed stream (see §2's consumption-rules table for how HR/telemetry sourcing follow this same comparison).

### Two Separate Gates: Uplink Ownership vs. Listener Attachment

The role decision above governs **uplink ownership** (`GameStateManager.hasNetworkOwnership`: `login_cycle != inactive` (`host_active OR join_active`) AND — Watch always `true`; Phone only `true` once `Phone.Time > w2p_hs.active_until`) — who is allowed to *write* telemetry (and any other member-state field — see below) to Firebase. **Listener attachment** (whether a device has its three realtime Firebase listeners open — read side) is a related but independently-evaluated decision built from the same `login_cycle` gate, `GameStateManager.evaluateListenerGate()` / `shouldAttachListeners(isWatch:appActive:peerLeaseActive:)`, and is **not** simply "same as the role above" — it's differentiated per platform and additionally depends on `app_active` (literally "is the user looking at this device right now," i.e. `isWristActive` — not "is the process capable of executing code," which would be tautologically true anywhere this is evaluated and therefore meaningless as a condition):

* **Watch:** `login_active AND (app_active OR (watch.Time < p2w_hs.active_until))` — attach if a session is actually active, and either the wearer is actively looking at the Watch *or* the Phone's lease says it still needs the Watch working (e.g. Watch mid-workout, wrist down, but Phone was recently active).
* **Phone:** `login_active AND app_active AND (phone.Time > w2p_hs.active_until)` — attach only if a session is actually active, the user is actively looking at the Phone, **and** the Watch has stepped down (lease expired). Unlike the Watch, the Phone does *not* attach merely because the Watch's lease happens to be active — the two device-side clauses are AND'd, not OR'd, deliberately asymmetric from the Watch's rule.

`app_active` is always evaluated as *this device's own* activity — the Watch clause reads the Watch's own `isWristActive`, the Phone clause reads the Phone's own — never the counterpart's. It's one symbol reused per-device-context, not two separately-named variables, matching `GameStateManager.isWristActive`'s single-flag implementation on each device.

Both devices' listener gate additionally requires `login_cycle != inactive` (`host_active OR join_active`) rather than a separate, locally-derived "active tactical session" flag — `login_cycle` is the single synced source of truth for "did we actually choose to host/join," so gating on it (instead of a second flag that could disagree with it) closes a specific failure mode: at the exact moment a companion device adopts a peer-driven session (`GameStateManager.adoptCompanionSession`, itself triggered by an incoming `host_active`/`join_active` LS convergence), `login_cycle` is *already* true — it's what caused the adoption — so the freshly-attached listener isn't at risk of this gate re-evaluating false and tearing it down (via `evaluateListenerGate()` re-running synchronously in the connect completion handler) before its first, complete `.value` snapshot has had time to arrive from the server. Gating on a locally-derived flag whose truth depends on `app_active`/lease timing catching up (rather than on `login_cycle`, which is already correct at that instant) previously left a freshly-joined companion device with no listener attached and no complete room snapshot until some *unrelated* event (a reachability change, a wrist-raise) happened to re-open the gate.

The same `login_cycle` requirement applies to **every** write into `FirebaseSyncManager` via `hasNetworkOwnership`, not only telemetry — `GameStateManager.setDead` and `updateLocalMember` now check it too. Previously those two call sites wrote directly (`firebaseManager.updateMember(...)`) with no ownership check at all, while `broadcastLocalTelemetry` was gated — an asymmetry that let a device without network ownership still push isDead/callsign/role changes, which (because the members path is watched with a whole-subtree `.value` listener) looked like it was "forcing a full resync" when it was really just the one write path that had been left ungated.

**Upload rate is independent of `app_active`/`isWristActive`.** Unlike listener attachment and uplink *ownership* above, the outbound telemetry *upload rate* itself (delta-gate + adaptive refresh interval, see CLOUD_DATA_MANAGEMENT.md §4) is never throttled by whether this device's wrist/screen is currently active. Self-location must keep reaching teammates as long as it meets delta-gate criteria even while this device's own screen is off — a wrist-down/backgrounded device is still visible to its squad, it just isn't the one deciding to attach listeners or claim cloud-write ownership.

