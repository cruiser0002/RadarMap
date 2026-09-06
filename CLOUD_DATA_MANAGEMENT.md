# Cloud Data Management Architecture

This document formalizes the **Watch-Centric Cloud Data Management Matrix** and **Client-Side Upload Scheduling Architecture** governing data flow between local companion systems (`WCSession` / local state) and Cloud infrastructure (Firebase Real-Time Database / Cloud Functions).

---

## ⚡ Key Cloud Architecture Constants

The following centralized constants from [`AppConstants.swift`](RadarMap/AppConstants.swift) govern cloud data synchronization, delta gating, bandwidth adaptation, and background cleanup:

| Section & Domain | Constant / Identifier | Value | Architectural Scope & Impact |
| :--- | :--- | :--- | :--- |
| **§1 Matrix / Endpoints** | RTDB Endpoints | `/r` (rooms), `/p` (telemetry), `/t` (tactical), `/m` (members) | Shortened path keys (`Network.Endpoints`) |
| **§2 Flow & Gating** | `maxPredictedPositionErrorMeters` | `3.5m` (`Timing.DeltaGating`) | Max dead-reckoning extrapolation divergence before triggering send |
| **§2 Flow & Gating** | `minHeartRateDeltaBpm` | `12.0 BPM` (`Timing.DeltaGating`) | Heart rate change threshold for biometric delta gating |
| **§2 Flow & Gating** | `heartRateDeltaGatingEnabled` | `false` (`Timing.DeltaGating`) | When false, HR is passive and does not trigger unneeded GPS uploads |
| **§2 Lease Control** | `activeUntilLeaseDurationSeconds`| `5.0s` (`WatchConnectivity`) | Foreground companion heartbeat lease duration |
| **§2 Lease Control** | `activeAdvertisementCadenceSeconds`| `1.0s` (`WatchConnectivity`) | Cadence for refreshing companion activity lease |
| **§3 Scheduling** | Tactical Indicator Cap | `0` (Free) / `20` (Pro) (`Subscription`) | Maximum concurrent enemy/environment tactical indicators (`mti`) |
| **§3 Scheduling** | Enemy Indicator Decay | `300.0s` (5 minutes) (`Subscription`) | Automated fade-out duration for placed enemy markers |
| **§4 Bandwidth Adaptation**| `playerThreshold` | `12` operators (`ConstantBandwidth`) | Player count ceiling before dynamic update rate reduction begins |
| **§4 Bandwidth Adaptation**| `baselineMaxUpdateRateHz` | `1.0 Hz` ($T = 1.0\text{s}$) | Base telemetry update frequency when $P \le 12$ |
| **§4 Bandwidth Adaptation**| Scaled Rate Formula ($P > 12$) | $1.0 \times (12 / P)\text{ Hz}$ | Keeps total aggregate upload bandwidth flat at $12\text{ packets/s}$ |
| **§4 Fallback Heartbeat** | `refreshIntervalMultiplier` | `10.0` ($10 \times T$) (`ConstantBandwidth`) | Fallback heartbeat cadence when player is stationary / delta-gated |
| **§4 Stale Telemetry** | `staleTimeoutMultiplier` | `15.0` ($15 \times T$) (`ConstantBandwidth`) | Stale peer threshold before fading icon to gray on radar |
| **§5 Cleanup & TTL** | `idleCutoffHours` | `12.0` hours (43,200s) (`Inactivity`) | Idle-room cutoff; host refreshes `exp` hourly to keep an active room alive past this |
| **§6 Network Latency** | Quality Boundaries | `150ms` (Exc), `300ms` (Good), `700ms` (Poor) | `Network.Quality` latency threshold grading |

---

## 1. Cloud Data Management Matrix

| | **From: Local Data** | **From: Cloud (Firebase RTDB)** |
|---|---|---|
| **To: Local Data** | **Resilient WCSession:**<br>• `WCSession.sendMessage` for high-speed live stream & `active_until` lease<br>• `WCSession.updateApplicationContext` for low-speed state snapshots<br>• Timestamp-driven merge resolution (`*_ts` per structure, Watch wins tie-breaks)<br>• Directional payloads (`p2w_hs`, `w2p_hs`, `p2w_ls`, `w2p_ls`) | **Persistent Realtime Streaming Listeners (Downstream) — Firebase SDK (Plan of Record; see §5.B):**<br>• All three downstream feeds (telemetry, tactical, room) use native `FirebaseDatabase` SDK listeners, not REST polling or REST/SSE<br>• Dedicated streaming listeners on active cloud client, multiplexed over one SDK-managed WebSocket connection<br>• Monotonic sequence and timestamp watermarks reject out-of-order packets<br>• **Watch is primary cloud client** (attaches listeners); Phone consumes `w2p_hs` stream and only attaches cloud listeners if Watch expires (`phone.time > w2p_hs.active_until`)<br>• SDK automatically resynchronizes state after reconnect via `.info/connected` — no manual repair logic |
| **To: Cloud (Firebase RTDB)** | **Split Upload Scheduling Policies (Upstream) — Firebase SDK (Plan of Record; see §5.C):**<br>• Writes dispatch via native `FirebaseDatabase` SDK methods (`setValue`/`updateChildValues`) over the same shared connection as the downstream listeners, not REST<br>• **Tactical Writes (Queue-All / Must-Arrive):** Placements, deletions bypass delta-gating and are submitted immediately; offline writes are queued by the SDK and replayed in order upon reconnect.<br>• **Telemetry Uploads (Latest-Only / Drop-Old):** Delta-gated ($> 3.5\text{ m}$, $> 12\text{ BPM}$) or fallback refresh interval ($10 \times T$). Connected: immediate write. Disconnected: coalesces into a single in-memory pending slot (app-level, independent of the SDK's own offline queue — see §5.C caveat); flushes only the latest sample upon reconnect.<br>• Cloud writes tolerate occasional duplicate or overlapping attempts — latest data wins | **Hourly cleanup based on `exp`, plus a per-room tactical cap:**<br>• Scheduled Cloud Function (`cleanExpiredRooms`) purges expired rooms and associated data across `/r`, `/t`, and `/p`<br>• Event-triggered Cloud Function (`pruneExcessTacticalIndicators`) evicts the oldest entries once `/t/{roomId}/i` exceeds the room's `mti` cap (see §7.B) |

---

## 2. Integrated Control & Data Flow Architecture

The same unified architecture applies to both Apple Watch and iPhone with differentiated control logic:

```mermaid
flowchart TD
    subgraph Downlink ["Downlink Listeners (Cloud ➔ Local)"]
        subgraph DownlinkGating ["Downlink Control Logic"]
            D_Watch["Watch: screen_active OR (watch.time < p2w_hs.active_until)"]
            D_Phone["Phone: screen_active AND (phone.time > w2p_hs.active_until)"]
        end
        D_Allow["Allow / Attach"]
        L_Tel["Remote Player Telemetry Listener"]
        L_Tac["Room & Tactical Listener"]
        Server_Down["Active Server Connection"]

        DownlinkGating --> D_Allow
        D_Allow --> L_Tel
        D_Allow --> L_Tac
        Server_Down --> L_Tel
        Server_Down --> L_Tac
    end

    subgraph Companion ["Inter-Device Companion Sync"]
        W2P_HS["W2P sendMessage Stream<br>(High-Speed Telemetry + Lease)"]
        LS_Sync["LS updateApplicationContext Sync<br>(Low-Speed Snapshot using _ts)"]
    end

    subgraph Uplink ["Uplink Dispatch (Local ➔ Cloud)"]
        subgraph UplinkGating ["Uplink Control Logic"]
            U_Watch["Watch: True"]
            U_Phone["Phone: (phone.time > w2p_hs.active_until)"]
        end
        U_Allow["Allow / Attach"]

        Local_Tel["Local Telemetry<br>Watch: watch.lon, watch.lat, watch.hr & !isDead, ts<br>Phone: phone.lon, phone.lat, 75 & !isDead, ts"]
        Delta_Gate["> delta-gate (3.5m / 12 BPM)<br>or refresh interval (10×T, room-size scaled)"]
        Uplink_Tel["Telemetry Uplink — Firebase SDK<br>(Latest-Only / Drop-Old)"]

        Local_Tac["Room, Tactical Mutations<br>(Placements, Deletions, Metadata)"]
        Uplink_Tac["Tactical Uplink — Firebase SDK<br>(Queue-All / Must-Arrive)"]

        Server_Up["Active Server RTDB"]

        Local_Tel --> Delta_Gate
        Delta_Gate --> Uplink_Tel
        UplinkGating --> U_Allow
        U_Allow --> Uplink_Tel

        Local_Tac --> Uplink_Tac

        Uplink_Tel --> Server_Up
        Uplink_Tac --> Server_Up
    end

    L_Tel <--> W2P_HS
    L_Tac <--> LS_Sync
    Local_Tac <--> LS_Sync
```

---

## 3. Client-Side Upload Scheduling Policies

### Policy 1: Tactical Writes (Queue-All / Must-Arrive)
* **Scope:** Tactical indicator placements and deletions, split into two sibling branches by category (see §7.B): squad orders at `/t/{roomId}/o/{indicatorId}` (self-pruning, no shared cap) and enemy+environment indicators at `/t/{roomId}/i/{indicatorId}` (shared cap `mti`, server-enforced by the `pruneExcessTacticalIndicators` Cloud Function). Deletes are issued against both branches unconditionally, since the delete call site has no category to route by.
* **Execution:** All tactical mutations are submitted directly to the Firebase SDK without dropping or collapsing actions.
* **Offline Resilience:** When offline, writes remain queued by the SDK's own offline write queue and are replayed in order upon reconnect — this policy is a natural fit for that default SDK behavior (see §5.C).
* **Preservation:** Guarantees indicator IDs, ordering, deletion tombstones, and completion handlers are preserved intact.

### Policy 2: Telemetry Writes (Latest-Only / Drop-Old)
* **Scope:** High-frequency GPS coordinates and biometrics (`/p/{roomId}/{memberId}.json`).
* **Pre-Uplink Gating:** Evaluated by Dead Reckoning & Delta Gating (movement $\ge 3.5\text{ m}$ or $\Delta\text{HR} \ge 12\text{ BPM}$, with fallback refresh heartbeat interval $10 \times T$).
* **Connection Gating & Coalescing:**
  * **Connected:** Dispatches the compact 4-element array `[lat, lon, hr, ts]` immediately at the active update cadence.
  * **Disconnected / Offline:** Network write calls are bypassed. The system maintains exactly **one** in-memory `PendingTelemetry` slot. Subsequent offline samples replace/coalesce older samples, eliminating unbounded retry queues and packet stampedes.
  * **Reconnect Flush:** On connection restoration (disconnected $\rightarrow$ connected transition), exactly **one** telemetry write containing the latest pending state is transmitted. The pending slot is cleared only upon successful write completion.

---

## 4. Heartbeat Rate & Telemetry Adaptation Schedule

### Constant Aggregate Bandwidth Scaling Equation
To hold aggregate fan-out bandwidth **constant** ($P \times R(P) = R_{\text{base}} \cdot N_{\text{threshold}}$, independent of $P$) once player count exceeds the threshold:

$$R(P) = \begin{cases} R_{\text{base}} & P \le N_{\text{threshold}} \\ R_{\text{base}} \cdot \dfrac{N_{\text{threshold}}}{P} & P > N_{\text{threshold}} \end{cases} \qquad T(P) = \frac{1}{R(P)}$$

* **Constants:** $R_{\text{base}} = 1.0\text{ Hz}$, $N_{\text{threshold}} = 12$, $X = 10$, $Y = 15$.
* **Peak Rate / Min Interval ($T$):** Minimum update interval under congestion; provides a floor to prevent over-congestion.
* **Refresh Interval ($X \times T$):** Default refresh heartbeat to assure cloud data freshness when stationary.
* **Stale Timeout ($Y \times T$):** Timeout after which associated player graphics turn gray, indicating staleness.
* **Why linear, not squared:** $R(P)$ must fall off as $1/P$ — not $1/P^2$ — for aggregate bandwidth $P \times R(P)$ to stay constant rather than continue shrinking as the room grows past the threshold. A squared falloff is a *stricter, decreasing* aggregate-bandwidth policy, not an *identical* one; it was evaluated and rejected in favor of the equation above, which is the plan of record.
* **Tier Boundary:** Pro tier is capped to **12 players** for production sessions today. The equation itself is general and well-defined for any $P > N_{\text{threshold}}$ — the 12-player cap is a current product decision, not a limitation of the equation, and is expected to lift for a future Extended tier.

| Player Count ($P$) | Tier | Peak Allowed Rate ($R(P)$) | Min Update Interval ($T$) | Refresh Interval ($10 \times T$) | Stale Timeout ($15 \times T$) |
| :---: | :---: | :---: | :---: | :---: | :---: |
| **1 – 4** | **Free Tier** (Max 4) | **$1.0\text{ Hz}$** | $1.0\text{ s}$ | $10.0\text{ s}$ | $15.0\text{ s}$ |
| **5 – 12** | **Pro Tier** (Max 12) | **$1.0\text{ Hz}$** | $1.0\text{ s}$ | $10.0\text{ s}$ | $15.0\text{ s}$ |
| **16** | Extended | **$0.75\text{ Hz}$** | $1.33\text{ s}$ | $13.3\text{ s}$ | $20.0\text{ s}$ |
| **20** | Extended | **$0.60\text{ Hz}$** | $1.67\text{ s}$ | $16.7\text{ s}$ | $25.0\text{ s}$ |
| **24** | Extended | **$0.50\text{ Hz}$** | $2.0\text{ s}$ | $20.0\text{ s}$ | $30.0\text{ s}$ |
| **50** | Extended (Max) | **$0.24\text{ Hz}$** | $4.17\text{ s}$ | $41.7\text{ s}$ | $62.5\text{ s}$ |

Every row satisfies $P \times R(P) = 12$ for $P > 12$ (e.g. $16 \times 0.75 = 20 \times 0.60 = 24 \times 0.50 = 50 \times 0.24 = 12$), confirming aggregate bandwidth is held at the Pro-tier ceiling rather than continuing to shrink.

---

## 5. Channel Breakdown & Implementation Details

### A. Local Data ➔ Local Data (WCSession)
* **Components:** [`WatchConnectivityManager.swift`](RadarMap/Managers/WatchConnectivityManager.swift), [`CompanionSyncModels.swift`](RadarMap/Models/CompanionSyncModels.swift), [`COMPANION_DATA_SYNC_MODEL.md`](COMPANION_DATA_SYNC_MODEL.md).
* **Guarantees:** Resilient local synchronization between iPhone and Apple Watch using directional snapshots and per-structure timestamp resolution (`*_ts`).
* **Mechanism:** High-speed stream via `WCSession.sendMessage` and low-speed snapshots via `WCSession.updateApplicationContext`. Watch wins equal-timestamp ties.

---

### B. Cloud ➔ Local Data (Realtime Streaming Listeners)
* **Components:** [`FirebaseSyncManager.swift`](RadarMap/Managers/FirebaseSyncManager.swift).
* **Guarantees:** Low-latency push stream, ephemeral telemetry, strict per-member sequence ordering, automatic resync on reconnect.
* **Gated Listener Attachment:**
  * **Watch attaches listeners when:** `screen_active OR (watch.time < p2w_hs.active_until)`
  * **Phone attaches listeners when:** `screen_active AND (phone.time > w2p_hs.active_until)`
* **Late / Out-of-Order Packet Rejection:** Maintains per-member monotonically increasing sequence counters (`memberLatestSequences`) and timestamp watermarks (`memberLatestTimestamps`) to drop out-of-order packets.

#### Plan of Record: Transport Decision (Firebase SDK, not REST/SSE)
* **Decision:** All three downstream channels — Remote Player Telemetry, Tactical Indicators, and Room/Membership — **must** be implemented using the native Firebase Realtime Database SDK's realtime listeners (`DatabaseReference.observe(.value)` / `.childAdded` / `.childChanged` / `.childRemoved`), not the RTDB REST API in either plain-polling or `Accept: text/event-stream` (SSE) form.
* **Rationale:**
  * **Wire-level delta payload is equivalent either way** — the SDK's listener protocol and REST SSE both stream the same underlying `put`/`patch` change events from the RTDB backend, so per-event payload size does not differ meaningfully between the two transports.
  * **Connection multiplexing favors the SDK for this app specifically.** This app requires three concurrent downstream feeds. The SDK multiplexes all listeners over a single persistent WebSocket connection (one TCP+TLS handshake, one keepalive stream). REST SSE has no equivalent multiplexing — each streamed path is its own independent HTTP connection, so three SSE streams cost three separate handshakes and three concurrent keepalive overheads. Under otherwise-identical link conditions, the SDK is the lower-aggregate-bandwidth option for our 3-stream case.
  * **Automatic reconnect + repair is a first-class SDK guarantee, not something REST/SSE provides for free.** The SDK watches connection state via `.info/connected`, retries with backoff on drop, and automatically resynchronizes every attached listener to the server's current state on reconnect — no app-level "give me everything since sequence N" logic required. A REST/SSE stream drop must be detected, repaired via a manual REST GET, and re-attached by hand, which re-implements the exact behavior the SDK gives natively.
  * Matches the "Future Proof" requirement to depend on the Firebase SDK rather than reinvent its reconnect/resync behavior in application code.
* **Current implementation status: COMPLIANT.** `firebase-ios-sdk` is an SPM dependency (both `RadarMap.xcodeproj` via `generate_xcodeproj.py` and `Package.swift`), and all three downstream channels are implemented on top of it via the `RTDBTransport` protocol ([RTDBTransport.swift](RadarMap/Managers/RTDBTransport.swift)), whose production implementation `FirebaseRTDBTransport` wraps `DatabaseReference`. `FirebaseSyncManager.startTelemetryPolling(roomId:)` / `stopTelemetryPolling()` are the gated attach/detach entry points (unchanged names/call sites for `GameStateManager.evaluatePhoneCloudClientPolicy()`), calling `attachRealtimeListeners(roomId:)` / `detachRealtimeListeners()`: telemetry uses `.childAdded` / `.childChanged` / `.childRemoved` on `p/{roomId}` (per-child deltas, not whole-subtree re-transmission), tactical and room/membership each use `.value` on `t/{roomId}` / `r/{roomId}` (matching their existing whole-node merge semantics). Since these listeners fire immediately on attach with current state and again on every subsequent change, `startTelemetryPolling` does not also perform a separate instant one-shot fetch (see §7.C — that redundant REST-era fetch was removed). `fetchRemoteTelemetry(roomId:)` and `fetchTacticalIndicators(roomId:)` remain as one-shot read-and-apply methods (via `transport.getValue`, the SDK's one-shot read) for `fetchRoomDetails(roomId:)`'s initial load and explicit wake-burst refreshes, sharing their merge logic with the persistent listeners via `applyTacticalSnapshot`/`applyRoomSnapshot`.

#### Required: Self-Echo Filtering on SDK Listener Callbacks
* **Cause:** Once uploads also move to the SDK (§5.C) and ride the same shared connection as these listeners, the SDK's local synchronized cache means a listener covering a path you also write to (e.g. a room-level `/p/{roomId}` listener, while you write to `/p/{roomId}/{memberId}`) fires again **immediately and optimistically** with your own just-written value — before any server round-trip. The SDK does not distinguish "changed because I wrote it" from "changed because a peer wrote it" at the callback level; this applies identically to telemetry, tactical indicators, and room membership.
* **Not a bandwidth cost:** this is a purely local callback re-firing off the already-synchronized in-process cache — no extra bytes cross the wire. It is a data-correctness concern, not an efficiency one: an unfiltered self-echo would flow into the same ingestion path built for remote peers (`applyTelemetryToActiveRoom`, tactical merge, room reconciliation) and could contend with the locally-authoritative state the device's own sensors already maintain.
* **Mitigation — implemented for all three channels:** the original REST implementation's `if memberId == localId { continue }` skip in `fetchRemoteTelemetry` is preserved verbatim, and the equivalent guard has been relocated into each listener callback. Telemetry: `handleTelemetryChildUpsert` skips packet application (but still tracks presence for reconciliation) when `snapshot.key == localMemberId`. Room: `applyRoomSnapshot`'s per-member merge loop skips overwriting the local member's row from the remote/echoed snapshot, relying on the already-locally-authoritative copy instead. Tactical: `applyTacticalSnapshot` still lets any indicator's mere presence in the snapshot clear its pending-ACK flag (regardless of authorship, so confirmation isn't broken), but for indicators where `placedByMemberId == localMemberId` it prefers the local copy over the snapshot's (possibly pre-confirmation) echoed value when merging into `activeRoom.indicators`. All three checks apply to every incoming event, including the SDK's optimistic pre-server-confirmation echo, not only server-confirmed ones.
* **No reliable existing backstop:** telemetry happens to get incidental partial protection from the sequence-freshness check, since `sendTelemetryPacket`'s local-apply closure already sets `memberLatestSequences[myMemberId]`/`memberLatestTimestamps[myMemberId]` synchronously at send time ([`FirebaseSyncManager.swift:456-459`](RadarMap/Managers/FirebaseSyncManager.swift#L456-L459)) — an unfiltered self-echo would carry the same sequence number just recorded and get rejected by `checkAndTrackPacketFreshness`'s `packet.sequenceNumber <= lastSeq` check. This is an accidental side effect of the sequence-tracking design, not a designed defense, and it does **not** exist for tactical indicators or room membership, which have no monotonic sequence check at all. The explicit self-echo filter above is required for all three channels regardless.

---

### C. Local Data ➔ Cloud (Upstream Upload Scheduling)
* **Components:** [`FirebaseSyncManager.swift`](RadarMap/Managers/FirebaseSyncManager.swift), [`GameStateManager.swift`](RadarMap/Managers/GameStateManager.swift).
* **Guarantees:**
  * **Uplink Control:** Watch is always permitted (`True`); Phone uplinks only when Watch lease expired (`phone.time > w2p_hs.active_until`).
  * **Tactical Queue-All:** All tactical operations queue during offline periods and deliver upon reconnect.
  * **Telemetry Latest-Only:** Offline telemetry updates replace a single in-memory slot, avoiding packet queues.
  * **Telemetry Payload:**
    * Watch: `watch.lon`, `watch.lat`, `watch.hr`, `!isDead`, `ts`
    * Phone: `phone.lon`, `phone.lat`, `75`, `!isDead`, `ts`
  * **Refresh Cadence:** Telemetry re-sent at the fallback refresh interval every $10 \times T$ heartbeats even absent a qualifying delta, to assure cloud data freshness.

#### Plan of Record: Transport Decision (Firebase SDK writes, not REST)
* **Decision:** Both upload channels — Telemetry and Tactical/Room — dispatch via the native Firebase Realtime Database SDK (`DatabaseReference.setValue(_:)` / `updateChildValues(_:)`) over the **same shared SDK connection** used for the downstream listeners (§5.B), not `URLSession` REST calls.
* **Rationale:**
  * **Lower per-write overhead.** A REST PUT pays a full HTTP request/response cycle (headers, `Authorization: Bearer` token, `Content-Type`, etc.) on every call even when the underlying TCP+TLS connection is reused. An SDK write on the already-open connection is a small framed protocol message — no repeated headers, no separate connection pool. This matters most for exactly the payloads we send: a handful of doubles per telemetry sample.
  * **Same fire-and-forget semantics.** An SDK write with its completion handler ignored is exactly as best-effort as an unmonitored REST PUT — cloud writes still tolerate occasional duplicate or overlapping attempts, and latest data still wins. No behavioral guarantee is lost.
  * **Tactical Queue-All is a natural fit for the SDK's default offline behavior** — the SDK already queues writes issued while offline and replays them in order on reconnect, which is precisely Policy 1's requirement.
* **Critical caveat — do not rely on the SDK's offline queue for telemetry:** the SDK's default offline behavior queues and replays **every** `setValue` call issued at a path while offline, in order — it does not collapse repeated writes to the same path down to the latest one. Relying on that default for telemetry would silently violate Policy 2 (Latest-Only / Drop-Old). The app must keep its own single-slot `PendingTelemetry` coalescing exactly as implemented today, and only invoke the SDK write once, at the moment that slot is flushed — the SDK call is a drop-in replacement for the REST PUT at that single call site, not a reason to remove the app-level coalescing.
* **Current implementation status: COMPLIANT.** Both upload paths in `FirebaseSyncManager.swift` dispatch via `RTDBTransport.setValue`/`removeValue` (`FirebaseRTDBTransport`'s production implementation calls `DatabaseReference.setValue(_:)`/`removeValue(completion:)`), e.g. `publishIndicatorToFirebase`, `executeTelemetryWrite` (the single flush call site used by both the connected and reconnect-flush paths). All existing app-level gating is preserved unchanged: delta-gating and adaptive rate happen upstream of `sendTelemetryPacket` (untouched), the single-slot `PendingTelemetry` coalescing still gates every telemetry write (the SDK call is only a drop-in replacement for the REST PUT at the one flush call site — telemetry is never routed through the SDK's own offline write queue), and tactical writes still submit immediately/unconditionally (queue-all), now backed by the SDK's default offline queue-and-replay behavior instead of a REST caveat.
* **TTL refresh:** the host writes a fresh `exp` to all three top-level trees (`/r/{roomId}/exp`, `/p/{roomId}/exp`, `/t/{roomId}/exp`) via `FirebaseSyncManager.refreshRoomExpiry(roomId:)`, at most once per hour while actively hosting — not server-enforced, gated client-side on `isCurrentMemberHost`. The idle cutoff is 12 hours (down from 7 days); an actively-hosted room stays alive indefinitely via this refresh. See §7.C.
* **Self-echo consequence:** moving these writes onto the shared SDK connection is what triggers the self-echo behavior documented in §5.B ("Required: Self-Echo Filtering on SDK Listener Callbacks") — every write made here optimistically re-fires this device's own downstream listeners. That filtering is implemented as a required, paired part of this same migration (see §5.B above), not an independent concern.

---

### D. Cloud ➔ Cloud (Lifecycle & Pruning)
* **Components:** [`functions/index.js`](functions/index.js).
* **Guarantees:** Automatic garbage collection of orphaned sessions, and a server-enforced ceiling on tactical indicator growth.
* **Mechanism — expiry:** Scheduled Cloud Function (`cleanExpiredRooms`) executes hourly (`every 1 hours` UTC) to identify rooms with `exp <= now` and atomically purge their sub-trees across `/r/{roomId}`, `/t/{roomId}`, and `/p/{roomId}`. `cleanupEmptyRoom` (triggered on `/r/{roomId}/m` writes) additionally purges a room immediately if it becomes empty or its host leaves.
* **Mechanism — tactical cap:** Event-triggered Cloud Function (`pruneExcessTacticalIndicators`, triggered on writes to `/t/{roomId}/i/{indicatorId}`) evicts the oldest entries by timestamp once the branch exceeds the room's `mti` cap. This closes a gap in the pre-Cloud-Function design, where cap enforcement ran client-side only on the host's own placements and never fired if a non-host member's placement was what pushed the room over the cap. Squad orders (`/t/{roomId}/o`) are untouched by this function — they self-prune client-side (one per type per member) and don't share this cap. See §7.B.

---

## 6. Access Control & Security Model

The room id is no longer the plain user-typed name — it is that name plus dynamic Crockford Base32 padding deterministically derived from the (mandatory) PIN, filling the remainder to a fixed 16 characters total, and that derived id is the actual RTDB path key. This section describes the resulting model; see §7.A for the derivation and rationale.

### A. Identifier Limits
* **Room / Squad Name (entry):** Uppercased, trimmed, **4–12 characters** (`AppConstants.UI.minRoomNameEntryLength`/`maxRoomNameEntryLength`, `RadarPlayerSimulator.MIN_ROOM_NAME_ENTRY_LENGTH`/`MAX_ROOM_NAME_ENTRY_LENGTH`). This is what the user types and what a join screen accepts — not the RTDB path key.
* **Room id (derived, the actual path key):** `name + deriveRoomPadding(pin, name, length: 16 - name.count)`, **always 16 characters total** (`AppConstants.UI.maxRoomNameLength`, `RadarPlayerSimulator.MAX_ROOM_NAME_LENGTH`, enforced server-side by `database.rules.json`'s `$roomId.length <= 16` validation). The dynamic padding (4 to 12 characters, filling the remainder to 16) is drawn from the same 32-symbol Crockford Base32 alphabet used for member/indicator ids, via a domain-separated SHA-256 hash of `(name, pin)` (`FirebaseSyncManager.deriveRoomPadding`, mirrored in `RadarPlayerSimulator.derive_room_padding`) — see §7.A for the full alphabet and domain-separation rationale.
* **Room PIN:** Digits-only, now **mandatory**, **4–16 characters** (`AppConstants.UI.minPinLength`/`maxPinLength`, `RadarPlayerSimulator.MIN_PIN_LENGTH`/`MAX_PIN_LENGTH`). Previously optional with no minimum.
* Host/Join buttons in [`CreateRoomView.swift`](RadarMap/Views/Room/CreateRoomView.swift), [`RoomDiscoveryView.swift`](RadarMap/Views/Room/RoomDiscoveryView.swift), and [`SettingsView.swift`](RadarMap/Views/Settings/SettingsView.swift) are disabled (not error-flagged) until both fields are in range, with the out-of-range field highlighted red in real time. [`player_simulator.py`](notebooks/player_simulator.py) enforces the matching caps independently for parity and raises immediately if constructed with a PIN under 4 digits.

### B. What the PIN Actually Protects (and What It Doesn't)
* **`pinHash = SHA256("{roomId}:{pin}")`** is computed identically in [`FirebaseSyncManager.hashPin`](RadarMap/Managers/FirebaseSyncManager.swift#L258) and [`RadarPlayerSimulator.hash_pin`](notebooks/player_simulator.py#L643) — note the salt is now the full *derived* room id, not the plain name. This is domain-separated from the room-id derivation itself (`deriveRoomPadding` prefixes its input with `"roompad:"`) so the two hashes never collide despite both consuming the same `(name, pin)` inputs.
* **The PIN now gates locating the room at all, not just joining it.** Because the room id itself is derived from `(name, pin)`, a wrong PIN doesn't fail a stored-hash comparison — it computes a *different, almost certainly nonexistent* id, and the lookup fails as `roomNotFound` before any membership or PIN check runs. This is a deliberate, subtle UX behavior change from before (wrong PIN used to surface as `incorrectPin`); see §7.A. The old stored-`pinHash` comparison in `joinRoom` still exists as a second check once a room *is* found (relevant for the vanishingly unlikely case of two different `(name, pin)` pairs deriving the same id), but in practice the id-derivation step is now the PIN's primary line of defense.
* **Reads are still unauthenticated at the derived path.** `.read` rules for `r`, `p`, and `t` only require that the node exist (`root.child('r').child($roomId).exists()`) — they do not check membership or any PIN-derived value once you're at the right id. What changed is *reachability*: before, the id was the plain room name, so knowing (or guessing) the name alone was sufficient to read a room's full state, including its `pinHash`, with no PIN needed. Now, reaching that same node requires the correct `(name, pin)` pair — guessing the name alone lands on the wrong path essentially always. Firebase Realtime Database `.read` rules still have no mechanism to inspect a value the reader supplies (unlike `.write`, which can compare against `newData`), so this reachability-via-derivation is the only read-side gate; a rule-level PIN check remains infeasible without restructuring further or adding Firebase Auth with custom claims minted by a Cloud Function after server-side PIN verification. Neither the latter is implemented.
* **Accepted entropy tradeoff:** PINs are numeric-only, so a 4-digit minimum yields only 10,000 possible derived paddings per name (~13.3 bits) for an attacker who already knows the room name — weaker than a dedicated random salt would have been, but the padding's actual purpose is letting a joiner's client recompute the id locally from `(name, pin)` without relaying extra characters, not maximizing salt entropy in isolation. See §7.A's "Accepted entropy tradeoff" and "Versioning caveat" notes (the latter: differing app versions running different derivation logic for the same `(name, pin)` fail to find each other on manual join; QR join is unaffected since it carries the final id directly).
* **Ongoing writes after joining** (telemetry, tactical) are not re-checked against the PIN at all — they're gated only by "does this `memberId` already exist in this room's `m`". Because `memberId` is a client-chosen, non-authenticated string, a client that already knows (or guesses) another member's `memberId` can write telemetry impersonating them; nothing currently prevents this — unchanged by this pass. Closing that gap would require binding `memberId` to an authenticated identity (e.g. `auth.uid == $memberId` after adding Firebase Auth), a larger change than this pass's scope.
* **No enumeration, but no rate limiting either:** there is no `.read` rule on the `r`/`p`/`t` collection nodes themselves, so a room id cannot be discovered by listing — it must be derived from a known `(name, pin)` pair. Realtime Database imposes no request throttling, so guessing is limited only by an attacker's own request rate, not by the server.

### C. Current Trust Boundary (Given the Above)
The practical security of a room now rests on an attacker needing both the room name *and* the PIN together to even locate it — a meaningful improvement over the prior model, where the name alone was sufficient to read a room's full state regardless of PIN. It is still not server-enforced access control: there is no rule-level check tying a read to proof of the PIN, and once a valid `(name, pin)` pair is known, everything downstream (reads, membership spoofing) works exactly as before. This is considered an acceptable tradeoff for the app's actual threat model — casual, session-scoped squad coordination (e.g. an airsoft match) where the realistic adversary is an opposing team member who might guess or overhear a name/PIN, not a sustained attacker — rather than a system holding persistent accounts, payment data, or PII. If that threat model changes (e.g. public matchmaking, persistent player identities), the read-gating and membership-spoofing gaps above should be revisited together, since both are naturally closed by the same underlying fix (Firebase Auth).

---

## 7. RTDB Schema Reference

The finalized schema, after the room-id hardening and short-key cleanup pass (dropping the earlier plain-room-name id, several dead fields, and REST-era polling):

```
r/                                          (was "rooms")
  {roomId}/                                 16 chars total: 4-12 char name + PIN-derived padding filling the remainder
    id: "ALPHA1XQ7K3M4N"                    full-length, kept human-readable
    hst: "A3F9K2QZ"                         was hostId
    cap: 12                                 was maxCapacity (free tier stays 4)
    mti: 20                                 was maxEnemyIndicatorsCount; now covers enemy+environment (0 free / 20 pro)
    pin: "c59c62cd..."                      was pinHash — non-optional (PIN is mandatory), hasPin removed
    exp: 1789141367.378                     was expireAt — refreshed hourly by host
    m/                                      was "members"
      {memberId}/                           8 chars, Crockford alphabet (23456789ABCDEFGHJKLMNPQRSTUVWXYZ)
        mid: "A3F9K2QZ"                     was id
        csn: "VIPER-1"                      was callsign
        rol: "leader"                       was isHost: true — MemberRole (player/leader, expandable)
    # createdAt, lastActivityTimestamp, hasPin: removed (dead/redundant)
    # indicators: excluded from the room's own Codable representation (was always an empty,
    # meaningless mirror — real indicator data lives under t/{roomId})

p/                                          (was "telemetry")
  {roomId}/
    exp: 1789141367.378                     refreshed hourly alongside r/ and t/
    {memberId}: [lat, lng, hr, ts]           4-element compact array

t/                                          (was "tactical")
  {roomId}/
    exp: 1789141367.378                     was expireAt — refreshed hourly
    o/                                      "orders" branch — squadOrder category only
      {indicatorId}: [type_code, lat, lng, ts, memberId]   self-pruning (1 per type per member), no numeric cap
    i/                                      was "indicators" — enemy + environment only
      {indicatorId}: [type_code, lat, lng, ts, memberId]   shares the room's `mti` cap
    # meta/ wrapper, flat legacy mirror, uts (updatedAt): removed entirely — see §2.C below
```

`database.rules.json` mirrors this: top-level `rooms`→`r`, `telemetry`→`p`, `tactical`→`t`; nested `members`→`m`, `indicators`→`i`, `o` as a new sibling with the same shape as `i`; the `meta` rule and the `.indexOn` list are both removed (confirmed unused — no query anywhere in the app orders/filters by any indexed field).

**No backwards-compatibility shims** — a build on the old schema and one on this schema cannot interoperate (different Firebase locations entirely). All clients (phone app, watch companion, Python simulator) ship together.

### A. Room ID Derivation

`roomId = name + deriveRoomPadding(pin, name, length: 16 - name.count)`:

```swift
// FirebaseSyncManager.swift, next to hashPin
public static func deriveRoomPadding(pin: String, name: String, length: Int? = nil) -> String {
    let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
    let padLength = length ?? max(0, AppConstants.UI.maxRoomNameLength - name.count)
    let combined = "roompad:\(name):\(pin)"
    let digest = Array(SHA256.hash(data: Data(combined.utf8)))
    return String(digest.prefix(padLength).map { alphabet[Int($0) % alphabet.count] })
}
```

* **Domain-separated** from `hashPin`'s own combined-string format (`"\(salt):\(trimmed)"`) via the `"roompad:"` prefix, so this derivation and the PIN-verification hash never share identical input even though both hash the same PIN.
* **Alphabet:** plain Crockford Base32 (32 symbols — `23456789ABCDEFGHJKLMNPQRSTUVWXYZ`, excludes `0`/`O`, `1`/`I`/`L` for readability), the same alphabet used everywhere else in the app for member and indicator ids. An earlier draft used an extended 41-symbol alphabet to maximize entropy per character; standardized back down to Crockford Base32 because the real entropy ceiling is set by the PIN's own low entropy (see below), so a larger mapping alphabet doesn't meaningfully improve security against that ceiling.
* Every character is uppercase-only, since the room id is `.uppercased()` at every call site.
* **Collision handling:** `FirebaseSyncManager.createRoom` reads before writing and fails with `.roomAlreadyExists` if the computed id is taken.
* **Accepted entropy tradeoff:** the PIN field is numeric-only, so a 4-digit minimum PIN yields only 10,000 possible derivations (~13.3 bits) per name — weaker than a dedicated random salt, but deliberate: the goal is letting a joiner's client recompute the id locally from `(name, pin)` without relaying extra characters, not maximizing salt entropy in isolation.
* **Versioning caveat:** manual join (no QR) requires the joiner's app to run the *same* derivation algorithm as the host's — differing app versions would compute different ids for the same `(name, pin)` and fail to find each other. QR-based join is unaffected, since it carries the final id directly rather than the ingredients.

### B. Tactical Indicators: Two-Tier Cap via Structural Split

`TacticalIndicatorCategory` has three cases: `squadOrder`, `enemyIndicator`, `environment`.

1. **Squad orders — self-pruning, no shared count.** `placeTacticalIndicator` removes any existing indicator of the same type placed by the same member before placing a new one — each member has at most one `goHere`, one `flag`, etc.
2. **Everything else (enemy + environment) — one shared numeric cap** (`mti`: 0 free / 20 pro, computed at room creation the same way `cap` already is).

Storage is split into two sibling branches so which tier something belongs to is which branch it's written under, not something a reader has to compute by inspecting type codes: `t/{roomId}/o` (squad orders, never touched by cap enforcement) and `t/{roomId}/i` (enemy + environment, shares the `mti` cap). Enforcement is a Cloud Function, not client-side, since client-side enforcement only ran on the host's own placements and never fired if a non-host member's placement pushed the room over the cap:

```javascript
exports.pruneExcessTacticalIndicators = functions.database
  .ref("/t/{roomId}/i/{indicatorId}")
  .onWrite(async (change, context) => {
    if (!change.after.exists()) return null;  // ignore deletes
    const roomId = context.params.roomId;

    const roomSnap = await db.ref(`/r/${roomId}`).once("value");
    const roomVal = roomSnap.val() || {};
    const MAX_TACTICAL = roomVal.mti !== undefined ? Number(roomVal.mti) : 20;

    const snap = await db.ref(`/t/${roomId}/i`).once("value");
    if (!snap.exists() || snap.numChildren() <= MAX_TACTICAL) return null;

    const entries = [];
    snap.forEach((child) => {
      const arr = child.val(); // [type_code, lat, lon, ts, placedByMemberId]
      const ts = Array.isArray(arr) ? arr[3] : arr["3"];
      entries.push({ id: child.key, ts: Number(ts) });
    });

    entries.sort((a, b) => a.ts - b.ts);
    const overflow = entries.slice(0, entries.length - MAX_TACTICAL);
    const updates = {};
    overflow.forEach((e) => { updates[`/t/${roomId}/i/${e.id}`] = null; });
    await db.ref().update(updates);
    return null;
  });
```

### C. Removed Fields & Retired Mechanisms

* **`hasPin`** — removed entirely; `hasPin == (pinHash != nil)` always held by construction, and became a compile-time constant `true` once the PIN became mandatory.
* **`lastActivityTimestamp`** — removed along with `isIdle()`/`touchRoomActivity()`; superseded by the hourly `exp` refresh (§5 above).
* **`createdAt`** — removed from the wire entirely; its only consumer was seeding `expireAt`'s initial default, now computed inline at construction.
* **`meta`/`updatedAt` (`uts`)** — removed entirely, not just relocated. `meta/` existed only because indicators used to live flat, sharing a namespace with metadata fields; once indicators moved into their own `o`/`i` branches that collision became structurally impossible, so metadata lives flat with no wrapper needed.
* **REST-style polling** — removed in favor of the Firebase SDK's persistent `.observe()` listeners (§5.B above), which already fire immediately on attach and again on every subsequent change; the manual re-fetches alongside them were leftovers from before the SDK migration.
* **`scheduledDailyCleanup`** (a separate daily 7-day-idle sweep in `functions/index.js`) — deleted; `cleanExpiredRooms` (hourly, `exp`-based) fully supersedes it.


