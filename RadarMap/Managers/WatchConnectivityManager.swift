import Foundation
import Combine
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

public final class WatchConnectivityManager: NSObject, ObservableObject {
    public static let shared = WatchConnectivityManager()
    
    @Published public var isSessionSupported: Bool = false
    @Published public var isActivated: Bool = false
    @Published public var isReachable: Bool = false
    @Published public var isPaired: Bool = false
    @Published public var isWatchAppInstalled: Bool = false
    
    public let localRole: DeviceRole

    // Outbound low-speed snapshot owned by this device. This is the single source of truth for
    // every synced config/player-state/login-cycle field — GameStateManager reads and writes
    // through it directly (via the mutateLocal* methods below) rather than keeping its own copy.
    // Always mutated on the main thread (directly for local edits, via a main-thread hop for
    // incoming merges) so it's safe to observe from SwiftUI.
    @Published public private(set) var localLS: LowSpeedSnapshot
    
    // Last-known counterpart low-speed snapshot received
    public private(set) var peerLS: LowSpeedSnapshot?
    
    // High-speed payloads: single source of truth for activeUntil and live streaming.
    // There is no other local storage of activeUntil.
    @Published public var w2pHS: WatchToPhoneHighSpeed = WatchToPhoneHighSpeed()
    @Published public var p2wHS: PhoneToWatchHighSpeed = PhoneToWatchHighSpeed()
    
    // Wire aliases
    public var w2p_hs: WatchToPhoneHighSpeed {
        get { w2pHS }
        set { w2pHS = newValue }
    }
    public var p2w_hs: PhoneToWatchHighSpeed {
        get { p2wHS }
        set { p2wHS = newValue }
    }
    
    /// Companion's advertised lease expiration timestamp (evaluated directly from inbound HS).
    /// Zero local storage.
    public var companionActiveUntil: TimeInterval {
        localRole == .phone ? w2pHS.activeUntil : p2wHS.activeUntil
    }
    
    public var latestAdvertisedWatchHS: WatchToPhoneHighSpeed? {
        localRole == .watch ? w2pHS : nil
    }
    
    /// True if the companion's active lease is currently valid
    @Published public var isWatchLeaseActive: Bool = false
    
    // Convergence tracking
    public private(set) var isRollingSync: Bool = false
    private var rollingTimer: AnyCancellable?
    private var leaseTimer: AnyCancellable?

    // Debug-only: call-rate instrumentation for diagnosing the transmission-storm hypothesis.
    // Remove once diagnosed.
    private var publishApplicationContextCallCount = 0
    private var lastPublishApplicationContextTime: TimeInterval = 0
    private var handleIncomingApplicationContextCallCount = 0
    private var lastHandleIncomingApplicationContextTime: TimeInterval = 0
    
    // Serialization queue for WCSession context updates to prevent concurrent partially-merged publishes
    private let contextQueue = DispatchQueue(label: "com.radarmap.watchconnectivity.queue")
    
    // High-level callbacks to GameStateManager
    public var onLowSpeedConvergenceStateChanged: ((LowSpeedSnapshot) -> Void)?
    public var onHighSpeedTelemetryReceived: ((_ telemetryJson: String) -> Void)?
    public var onHighSpeedHeartRateReceived: ((_ hr: Double) -> Void)?
    public var onReachabilityChanged: ((Bool) -> Void)?
    public var onWatchLeaseStatusChanged: ((Bool) -> Void)?
    
    // Persistence keys
    private let localLSPersistenceKey = "wc_local_ls_snapshot"
    private let peerLSPersistenceKey = "wc_peer_ls_snapshot"
    
    public init(role: DeviceRole? = nil) {
        #if os(watchOS)
        let defaultRole: DeviceRole = .watch
        #else
        let defaultRole: DeviceRole = .phone
        #endif
        self.localRole = role ?? defaultRole
        
        // Load persisted snapshots if available
        if let data = UserDefaults.standard.data(forKey: localLSPersistenceKey),
           var saved = try? JSONDecoder().decode(LowSpeedSnapshot.self, from: data) {
            // Login lifecycle state is session-ephemeral and must not be saved across sessions.
            // It always starts as .inactive (with timestamp 0) by default upon launch.
            saved.loginCycle = LoginCycleSnapshot(loginCycle: .inactive, loginCycleTs: 0)
            self.localLS = saved
        } else {
            // First launch on this device since localLS was introduced: seed config from the
            // legacy per-field UserDefaults keys so existing users don't lose their saved
            // callsign/room/pin/theme/upload preferences.
            let defaults = UserDefaults.standard
            var seeded = LowSpeedSnapshot()
            seeded.config = ConfigSnapshot(
                callsign: defaults.string(forKey: AppConstants.Storage.userCallsignKey) ?? "",
                roomName: defaults.string(forKey: AppConstants.Storage.savedRoomNameKey) ?? "",
                pin: defaults.string(forKey: AppConstants.Storage.savedPinKey) ?? "",
                databaseURL: defaults.string(forKey: AppConstants.Storage.customDatabaseURLKey) ?? "",
                theme: defaults.string(forKey: AppConstants.Storage.radarColorThemeKey) ?? "Green",
                role: defaults.string(forKey: AppConstants.Storage.userRoleKey) ?? "player",
                isPro: false,
                isUploadHeartRateEnabled: defaults.object(forKey: AppConstants.Storage.isUploadHeartRateEnabledKey) as? Bool ?? true,
                isUploadLocationEnabled: defaults.object(forKey: AppConstants.Storage.isUploadLocationEnabledKey) as? Bool ?? true,
                isEncryptionEnabled: defaults.object(forKey: AppConstants.Storage.isEncryptionEnabledKey) as? Bool ?? true,
                configTs: 0
            )
            seeded.loginCycle = LoginCycleSnapshot(loginCycle: .inactive, loginCycleTs: 0)
            self.localLS = seeded
        }
        
        if let data = UserDefaults.standard.data(forKey: peerLSPersistenceKey),
           var savedPeer = try? JSONDecoder().decode(LowSpeedSnapshot.self, from: data) {
            savedPeer.loginCycle = LoginCycleSnapshot(loginCycle: .inactive, loginCycleTs: 0)
            self.peerLS = savedPeer
        }
        
        super.init()
        
        #if canImport(WatchConnectivity)
        if WCSession.isSupported() {
            self.isSessionSupported = true
            let session = WCSession.default
            self.isActivated = (session.activationState == .activated)
            self.isReachable = session.isReachable
            session.delegate = self
            session.activate()
        }
        #endif
        
        startLeaseMonitoring()
    }
    
    /// Test-only: seeds `localLS` directly with an arbitrary snapshot, including caller-chosen
    /// timestamps — simulating state already persisted from a previous session, as opposed to a
    /// live local edit (which the `mutateLocal*` methods always stamp with the current time).
    /// Does not persist or publish; production code should never call this.
    public func testSeedLocalLS(_ snapshot: LowSpeedSnapshot) {
        localLS = snapshot
    }
    
    // MARK: - Lease Monitoring & Standby Gating
    
    private func startLeaseMonitoring() {
        leaseTimer?.cancel()
        leaseTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.evaluateLeaseStatus()
            }
    }
    
    public func evaluateLeaseStatus() {
        let now = Date().timeIntervalSince1970
        let active = (companionActiveUntil > now)
        if isWatchLeaseActive != active {
            isWatchLeaseActive = active
            onWatchLeaseStatusChanged?(active)
        }
    }

    /// Corrects `isWatchLeaseActive` if it's stuck `true` past the companion's actual advertised
    /// deadline. `isWatchLeaseActive` is otherwise only refreshed by the 1Hz `leaseTimer` (or a
    /// fresh HS payload arriving) — a one-off decision point like `evaluateListenerGate` or
    /// `hasNetworkOwnership` that runs between timer ticks (or while the timer is suspended, e.g.
    /// backgrounded on watchOS) can see a lease that expired moments ago but is still reported
    /// active, which can leave listener/ownership handoff stuck. Deliberately never flips the flag
    /// the other direction (false -> true): with no real advertised deadline yet
    /// (`companionActiveUntil == 0`), an externally-set `true` (e.g. direct test injection) is left
    /// alone rather than treated as expired.
    public func correctStaleLeaseExpiry() {
        guard isWatchLeaseActive, companionActiveUntil > 0, companionActiveUntil <= Date().timeIntervalSince1970 else { return }
        isWatchLeaseActive = false
        onWatchLeaseStatusChanged?(false)
    }
    
    // MARK: - State Mutation & Low-Speed Updates

    /// Updates the membership/tactical domain structures (serialized views of Firebase room state
    /// / local tactical indicators, not user-editable leaf fields) and evaluates whether
    /// convergence retransmission is needed. Must be called on the main thread, same as the
    /// mutateLocal* methods below. The caller (`GameStateManager.syncTacticalToWatchConnectivity`/
    /// `syncMembershipToWatchConnectivity`) owns the "did my view actually change" equality check
    /// and constructs the stamped snapshot itself — this setter trusts what it's given, same as
    /// `MergeEngine.merge`'s direct `localLS = mergedLocal` assignment does for convergence
    /// adoption (see `handleIncomingApplicationContext`).
    public func updateLocalStructures(
        membership: MembershipSnapshot? = nil,
        tactical: TacticalSnapshot? = nil
    ) {
        if let membership = membership {
            localLS.membership = membership
        }
        if let tactical = tactical {
            localLS.tactical = tactical
        }
        persistAndPublishLocalState()
    }

    /// Mutates `localLS.config` in place — the single source of truth for callsign/roomName/pin/
    /// databaseURL/theme/isPro/upload-toggle fields. Call sites read `localLS.config.<field>`
    /// directly rather than keeping a separate copy; this is the only way to write to it.
    public func mutateLocalConfig(_ mutate: (inout ConfigSnapshot) -> Void) {
        var updated = localLS.config
        mutate(&updated)
        guard !updated.isEquivalent(to: localLS.config) else { return }
        updated.configTs = Date().timeIntervalSince1970
        localLS.config = updated
        persistAndPublishLocalState()
    }

    /// Mutates `localLS.playerState` in place — the single source of truth for `isDead`.
    public func mutateLocalPlayerState(_ mutate: (inout PlayerStateSnapshot) -> Void) {
        var updated = localLS.playerState
        mutate(&updated)
        guard !updated.isEquivalent(to: localLS.playerState) else { return }
        updated.isDeadTs = Date().timeIntervalSince1970
        localLS.playerState = updated
        persistAndPublishLocalState()
    }

    /// Mutates `localLS.loginCycle` in place — the single source of truth for the coarse
    /// inactive/hostActive/joinActive room-lifecycle state.
    public func mutateLocalLoginCycle(_ mutate: (inout LoginCycleSnapshot) -> Void) {
        var updated = localLS.loginCycle
        mutate(&updated)
        guard !updated.isEquivalent(to: localLS.loginCycle) else { return }
        updated.loginCycleTs = Date().timeIntervalSince1970
        localLS.loginCycle = updated
        persistAndPublishLocalState()
    }

    /// Debug-only: renders a `LowSpeedSnapshot` as JSON for the content-on-change logging below.
    private func debugDescribe(_ snapshot: LowSpeedSnapshot) -> String {
        guard let data = try? JSONEncoder().encode(snapshot),
              let json = String(data: data, encoding: .utf8) else { return "<unencodable>" }
        return json
    }

    /// Local mutations above always originate on the main thread (UI-driven) and assign into
    /// `localLS` synchronously for instant UI feedback. `checkAndTriggerConvergence` also runs
    /// here on main (it reads `peerLS`, which — like `localLS` — is only ever touched on main);
    /// only the actual I/O (UserDefaults write, WCSession publish) is handed to `contextQueue`,
    /// operating on a captured copy so it never touches `localLS`/`peerLS` directly.
    private func persistAndPublishLocalState() {
        checkAndTriggerConvergence(local: localLS)
        let snapshot = localLS
        print("[WCSession \(localRole)] localLS changed: \(debugDescribe(snapshot))")
        saveLocalState(snapshot)
        publishApplicationContext(local: snapshot)
    }
    
    // MARK: - High-Speed Outgoing Stream (Asymmetrical Routing)

    /// Advertises Phone-owned high-speed payload (p2w_hs) strictly via sendMessage. No fallback
    /// channel on failure/unreachability by design — see docs/CLOUD_DATA_MANAGEMENT.md and
    /// CLAUDE.md's "no fallback-as-design" rule. A missed tick self-heals via the next tick once
    /// reachable again, or via `correctStaleLeaseExpiry`'s TTL backstop.
    public func advertisePhoneHighSpeed(
        remotePlayerTelemetryJson: String = "{}"
    ) {
        guard localRole == .phone else { return }
        let now = Date().timeIntervalSince1970
        let lease = now + AppConstants.WatchConnectivity.activeUntilLeaseDurationSeconds
        self.p2wHS.activeUntil = lease
        self.p2wHS.remotePlayerTelemetryJson = remotePlayerTelemetryJson
        let hs = self.p2wHS

        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            print("[WCSession phone] advertisePhoneHighSpeed: NOT REACHABLE, skipping tick. remotePlayerTelemetryJson bytes=\(remotePlayerTelemetryJson.utf8.count) content=\(remotePlayerTelemetryJson)")
            return
        }
        var envelope = ApplicationContextEnvelope()
        envelope.p2wHS = hs
        if let data = try? JSONEncoder().encode(envelope),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            print("[WCSession phone] advertisePhoneHighSpeed sendMessage: bytes=\(data.count) remotePlayerTelemetryJson bytes=\(remotePlayerTelemetryJson.utf8.count) content=\(remotePlayerTelemetryJson)")
            session.sendMessage(dict, replyHandler: nil, errorHandler: { error in
                print("[WCSession phone] advertisePhoneHighSpeed sendMessage FAILED (payload bytes=\(data.count)): \(error)")
            })
        } else {
            print("[WCSession phone] advertisePhoneHighSpeed: FAILED TO ENCODE envelope, remotePlayerTelemetryJson bytes=\(remotePlayerTelemetryJson.utf8.count)")
        }
        #endif
    }

    /// Advertises Watch-owned high-speed stream (w2p_hs) strictly via sendMessage. No fallback
    /// channel on failure/unreachability by design — see docs/CLOUD_DATA_MANAGEMENT.md and
    /// CLAUDE.md's "no fallback-as-design" rule. A missed tick self-heals via the next tick once
    /// reachable again, or via `correctStaleLeaseExpiry`'s TTL backstop.
    public func advertiseWatchHighSpeed(
        heartRate: Double,
        remotePlayerTelemetryJson: String = "{}"
    ) {
        guard localRole == .watch else { return }
        let now = Date().timeIntervalSince1970
        let lease = now + AppConstants.WatchConnectivity.activeUntilLeaseDurationSeconds
        self.w2pHS.activeUntil = lease
        self.w2pHS.heartRate = heartRate
        self.w2pHS.remotePlayerTelemetryJson = remotePlayerTelemetryJson
        let hs = self.w2pHS

        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            print("[WCSession watch] advertiseWatchHighSpeed: NOT REACHABLE, skipping tick. remotePlayerTelemetryJson bytes=\(remotePlayerTelemetryJson.utf8.count) content=\(remotePlayerTelemetryJson)")
            return
        }
        var envelope = ApplicationContextEnvelope()
        envelope.w2pHS = hs
        if let data = try? JSONEncoder().encode(envelope),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            print("[WCSession watch] advertiseWatchHighSpeed sendMessage: bytes=\(data.count) remotePlayerTelemetryJson bytes=\(remotePlayerTelemetryJson.utf8.count) content=\(remotePlayerTelemetryJson)")
            session.sendMessage(dict, replyHandler: nil, errorHandler: { error in
                print("[WCSession watch] advertiseWatchHighSpeed sendMessage FAILED (payload bytes=\(data.count)): \(error)")
            })
        } else {
            print("[WCSession watch] advertiseWatchHighSpeed: FAILED TO ENCODE envelope, remotePlayerTelemetryJson bytes=\(remotePlayerTelemetryJson.utf8.count)")
        }
        #endif
    }

    // MARK: - Convergence & Rolling sync_ts

    /// Must be called on the main thread — reads `peerLS`, which (like `localLS`) is only ever
    /// touched on main.
    private func checkAndTriggerConvergence(local: LowSpeedSnapshot) {
        guard let peer = peerLS else {
            // No peer snapshot seen yet: roll sync_ts immediately and start rolling pump to announce local state
            localLS.syncTs = Date().timeIntervalSince1970
            startRollingSync()
            return
        }

        if local.isDomainEquivalent(to: peer) {
            // Fully converged: discrepancy resolved
            stopRollingSync()
        } else {
            // Discrepancy exists: evaluate whether local device owns any winning structure
            let (_, localWins) = MergeEngine.merge(local: local, peer: peer, localDevice: localRole)
            if localWins {
                // Roll sync_ts immediately whenever a change causes a discrepancy where local wins
                localLS.syncTs = Date().timeIntervalSince1970
                // Continue rolling until discrepancy is resolved
                startRollingSync()
            } else {
                stopRollingSync()
            }
        }
    }
    
    private func startRollingSync() {
        guard !isRollingSync else { return }
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        #if os(iOS)
        guard WCSession.default.isPaired && WCSession.default.isWatchAppInstalled else { return }
        #endif
        #endif
        isRollingSync = true
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.rollingTimer?.cancel()
            self.rollingTimer = Timer.publish(every: AppConstants.WatchConnectivity.defaultHighSpeedCadenceSeconds, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    self?.rollSyncTimestampAndPublish()
                }
        }
    }
    
    public func stopRollingSync() {
        isRollingSync = false
        DispatchQueue.main.async { [weak self] in
            self?.rollingTimer?.cancel()
            self?.rollingTimer = nil
        }
    }
    
    /// Must be called on the main thread (`localLS` is only ever touched there). Its callers —
    /// the rolling `Timer` (scheduled `on: .main`) and `sessionReachabilityDidChange` below — are
    /// responsible for that.
    ///
    /// Re-checks convergence against `peerLS` on every tick before republishing, rather than
    /// blindly republishing forever. `stopRollingSync()` was previously only ever called reactively
    /// from `handleIncomingApplicationContext` (i.e. only when a peer's push happened to arrive) —
    /// once both sides genuinely converged, the peer correctly stops echoing back (nothing new to
    /// adopt), which meant this device never received another incoming message to react to and so
    /// never got the chance to notice convergence and stop. The pump then ran at 1Hz forever,
    /// republishing identical already-converged state with no path back to `stopRollingSync()`.
    private func rollSyncTimestampAndPublish() {
        if let peer = peerLS, localLS.isDomainEquivalent(to: peer) {
            stopRollingSync()
            return
        }

        // Deliberately NOT gated on isReachable: that reflects live two-way messaging
        // availability (foreground/high-priority-background), which is known to unreliably read
        // false even while a companion is genuinely alive and running in the background (e.g. a
        // watch mid-workout with the screen off). updateApplicationContext is explicitly designed
        // to keep working via the system WatchConnectivity daemon regardless of reachability, so
        // gating this retry on it would risk suppressing real convergence to a
        // backgrounded-but-active companion.
        localLS.syncTs = Date().timeIntervalSince1970
        let snapshot = localLS
        saveLocalState(snapshot)
        publishApplicationContext(local: snapshot)
    }
    
    // MARK: - Publishing to WCSession
    
    /// `local` must be captured by the caller from `localLS` on the main thread beforehand — this
    /// function itself only touches `contextQueue`-owned state (the WCSession call) and never reads
    /// `localLS`/`peerLS` directly, so it's safe to dispatch onto `contextQueue` regardless of which thread calls it.
    private func publishApplicationContext(local: LowSpeedSnapshot) {
        publishApplicationContextCallCount += 1
        let now = Date().timeIntervalSince1970
        let deltaMs = lastPublishApplicationContextTime == 0 ? 0 : (now - lastPublishApplicationContextTime) * 1000
        lastPublishApplicationContextTime = now
        print("[WCSession \(localRole)] publishApplicationContext call #\(publishApplicationContextCallCount), \(String(format: "%.1f", deltaMs))ms since last call")
        contextQueue.async { [weak self] in
            guard let self = self else { return }
            #if canImport(WatchConnectivity)
            guard WCSession.isSupported() else { return }
            let session = WCSession.default
            guard session.activationState == .activated else { return }
            #if os(iOS)
            guard session.isPaired && session.isWatchAppInstalled else { return }
            #endif

            var envelope = ApplicationContextEnvelope()
            if self.localRole == .phone {
                envelope.p2wLS = local
            } else {
                envelope.w2pLS = local
            }

            guard let data = try? JSONEncoder().encode(envelope),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

            do {
                try session.updateApplicationContext(dict)
            } catch {
                // Silently handle context update error to avoid crashing
            }
            #endif
        }
    }

    // MARK: - Processing Incoming Envelopes

    /// Runs entirely on the main thread — `WCSessionDelegate` callbacks that feed this can land on
    /// an arbitrary background queue, but `localLS`/`peerLS` are only ever touched on main, so the
    /// whole merge is dispatched there rather than to `contextQueue` (which is reserved for
    /// snapshot-parameterized I/O that doesn't need to read either property directly).
    public func handleIncomingApplicationContext(_ dict: [String: Any], isReplayedContext: Bool = false) {
        handleIncomingApplicationContextCallCount += 1
        let callNow = Date().timeIntervalSince1970
        let callDeltaMs = lastHandleIncomingApplicationContextTime == 0 ? 0 : (callNow - lastHandleIncomingApplicationContextTime) * 1000
        lastHandleIncomingApplicationContextTime = callNow
        print("[WCSession \(localRole)] handleIncomingApplicationContext call #\(handleIncomingApplicationContextCallCount), \(String(format: "%.1f", callDeltaMs))ms since last call, replayed=\(isReplayedContext)")

        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              var envelope = try? JSONDecoder().decode(ApplicationContextEnvelope.self, from: data) else { return }

        // `session.receivedApplicationContext` is cached by the OS and redelivered verbatim on
        // activation, even across a cold relaunch or an app that force-quit mid-session — so a
        // stale `login_cycle` from a previous session can resurface here and get adopted as if it
        // were a live handshake. Live pushes (didReceiveApplicationContext/didReceiveMessage) are
        // never replayed this way, so only the activation-time replay needs sanitizing.
        if isReplayedContext {
            envelope.p2wLS?.loginCycle = LoginCycleSnapshot(loginCycle: .inactive, loginCycleTs: 0)
            envelope.w2pLS?.loginCycle = LoginCycleSnapshot(loginCycle: .inactive, loginCycleTs: 0)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            #if DEBUG
            print("[WCSession \(self.localRole)] handleIncomingApplicationContext: p2wHS=\(envelope.p2wHS != nil), w2pHS=\(envelope.w2pHS != nil)")
            #endif

            // 1. Process High-Speed Payloads (Unidirectional)
            if self.localRole == .watch, let p2wHS = envelope.p2wHS {
                print("[WCSession watch] p2wHS received: activeUntil=\(p2wHS.activeUntil) remotePlayerTelemetryJson=\(p2wHS.remotePlayerTelemetryJson)")
                self.p2wHS = p2wHS
                let active = (p2wHS.activeUntil > Date().timeIntervalSince1970)
                if self.isWatchLeaseActive != active {
                    self.isWatchLeaseActive = active
                    self.onWatchLeaseStatusChanged?(active)
                }
                self.onHighSpeedTelemetryReceived?(p2wHS.remotePlayerTelemetryJson)
            } else if self.localRole == .phone, let w2pHS = envelope.w2pHS {
                print("[WCSession phone] w2pHS received: activeUntil=\(w2pHS.activeUntil) heartRate=\(w2pHS.heartRate) remotePlayerTelemetryJson=\(w2pHS.remotePlayerTelemetryJson)")
                self.w2pHS = w2pHS
                let active = (w2pHS.activeUntil > Date().timeIntervalSince1970)
                if self.isWatchLeaseActive != active {
                    self.isWatchLeaseActive = active
                    self.onWatchLeaseStatusChanged?(active)
                }
                if !w2pHS.remotePlayerTelemetryJson.isEmpty && w2pHS.remotePlayerTelemetryJson != "{}" {
                    self.onHighSpeedTelemetryReceived?(w2pHS.remotePlayerTelemetryJson)
                }
                self.onHighSpeedHeartRateReceived?(w2pHS.heartRate)
            }

            // 2. Process Low-Speed Payloads (Bidirectional Merge)
            let peerSnapshot = (self.localRole == .phone) ? envelope.w2pLS : envelope.p2wLS
            if let peer = peerSnapshot {
                print("[WCSession \(self.localRole)] peerLS received (replayed=\(isReplayedContext)): \(self.debugDescribe(peer))")
                self.peerLS = peer
                self.savePeerState(peer)

                // Merge peer snapshot into local snapshot — this assignment IS the value
                // changing; there is nothing else to copy the result into.
                let (mergedLocal, localWins) = MergeEngine.merge(local: self.localLS, peer: peer, localDevice: self.localRole)
                let localChanged = !self.localLS.isDomainEquivalent(to: mergedLocal)
                self.localLS = mergedLocal
                if localChanged {
                    print("[WCSession \(self.localRole)] localLS merged (localWins=\(localWins)): \(self.debugDescribe(mergedLocal))")
                }

                // Roll sync_ts whenever there's a reason for the peer to still be watching this
                // device: either this device holds data the peer hasn't caught up to (localWins),
                // or this device's own advertised copy just changed via the copy-in above
                // (localChanged) — the peer's cached view of *this device's* structure is still
                // the pre-copy value until a fresh push lands, even though the copied-in content
                // originated from the peer itself. Only stop once neither holds (true
                // convergence: nothing of ours to give, nothing just adopted to announce).
                if localWins || localChanged {
                    self.localLS.syncTs = Date().timeIntervalSince1970
                    self.startRollingSync()
                } else {
                    self.stopRollingSync()
                }

                self.saveLocalState(self.localLS)

                // If local state adopted winning peer structures or changed, publish updated local
                // snapshot immediately (zero-delay initial push — see rollSyncTimestampAndPublish's
                // rolling retries for the ongoing retry path).
                if localChanged {
                    self.publishApplicationContext(local: self.localLS)
                }

                self.onLowSpeedConvergenceStateChanged?(self.localLS)
            }
        }
    }

    // MARK: - Local Persistence

    private func saveLocalState(_ snapshot: LowSpeedSnapshot) {
        var toSave = snapshot
        toSave.loginCycle = LoginCycleSnapshot(loginCycle: .inactive, loginCycleTs: 0)
        contextQueue.async {
            if let data = try? JSONEncoder().encode(toSave) {
                UserDefaults.standard.set(data, forKey: self.localLSPersistenceKey)
            }
        }
    }

    private func savePeerState(_ snapshot: LowSpeedSnapshot) {
        var toSave = snapshot
        toSave.loginCycle = LoginCycleSnapshot(loginCycle: .inactive, loginCycleTs: 0)
        contextQueue.async {
            if let data = try? JSONEncoder().encode(toSave) {
                UserDefaults.standard.set(data, forKey: self.peerLSPersistenceKey)
            }
        }
    }
}

#if canImport(WatchConnectivity)
extension WatchConnectivityManager: WCSessionDelegate {
    public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isActivated = (activationState == .activated)
            self.isReachable = session.isReachable
            self.onReachabilityChanged?(session.isReachable)
            #if os(iOS)
            self.isPaired = session.isPaired
            self.isWatchAppInstalled = session.isWatchAppInstalled
            #endif
        }
        
        if activationState == .activated {
            let receivedContext = session.receivedApplicationContext
            if !receivedContext.isEmpty {
                handleIncomingApplicationContext(receivedContext, isReplayedContext: true)
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.publishApplicationContext(local: self.localLS)
                }
            }
        }
    }

    public func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isActivated = (session.activationState == .activated)
            self.isReachable = session.isReachable
            self.onReachabilityChanged?(session.isReachable)
        }
        if session.isReachable, isRollingSync {
            DispatchQueue.main.async { [weak self] in
                self?.rollSyncTimestampAndPublish()
            }
        }
    }
    
    #if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isActivated = (session.activationState == .activated)
        }
    }
    
    public func sessionDidDeactivate(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isActivated = false
        }
        WCSession.default.activate()
    }
    
    public func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isPaired = session.isPaired
            self.isWatchAppInstalled = session.isWatchAppInstalled
        }
    }
    #endif
    
    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        handleIncomingApplicationContext(applicationContext)
    }
    
    public func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        handleIncomingApplicationContext(message)
    }
}
#endif

#if DEBUG
extension WatchConnectivityManager {
    /// Live re-read of WCSession state for the debug HUD only. `isActivated`/`isReachable` are
    /// cached and only updated inside WCSessionDelegate callbacks, which don't fire for
    /// display-only transitions (e.g. Always-On dimming) — so the debug HUD can show a stale
    /// value. These bypass the cache and read `WCSession.default` directly each time the debug
    /// string is recomputed (every second, via the HUD's own TimelineView). Falls back to the
    /// cached `isActivated`/`isReachable` when `WCSession.isSupported()` is false (e.g. the
    /// `swift test` macOS host, where tests inject those directly and there is no real session to
    /// read), preserving existing test coverage. Not used by any production logic. Deleting this
    /// whole extension fully reverts this change.
    public var debugLiveIsActivated: Bool {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return isActivated }
        return WCSession.default.activationState == .activated
        #else
        return isActivated
        #endif
    }

    public var debugLiveIsReachable: Bool {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return isReachable }
        return WCSession.default.isReachable
        #else
        return isReachable
        #endif
    }
}
#endif

