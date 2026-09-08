import Foundation
import Combine
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

public final class WatchConnectivityManager: NSObject, ObservableObject {
    public static let shared = WatchConnectivityManager()
    
    @Published public var isSessionSupported: Bool = false
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
    
    // Last-known counterpart high-speed payload
    public private(set) var latestRemoteActiveUntil: TimeInterval = 0
    public private(set) var latestRemoteTelemetryJson: String = "{}"
    public private(set) var latestRemoteHeartRate: Double = 75.0
    
    /// True if the Watch's active lease is currently valid (Phone.Time <= w2p_hs.active_until)
    @Published public var isWatchLeaseActive: Bool = false
    
    // Convergence tracking
    public private(set) var isRollingSync: Bool = false
    private var rollingTimer: AnyCancellable?
    private var leaseTimer: AnyCancellable?
    
    // Serialization queue for WCSession context updates to prevent concurrent partially-merged publishes
    private let contextQueue = DispatchQueue(label: "com.radarmap.watchconnectivity.queue")
    
    // High-level callbacks to GameStateManager
    public var onLowSpeedConvergenceStateChanged: ((LowSpeedSnapshot) -> Void)?
    public var onHighSpeedTelemetryReceived: ((_ telemetryJson: String) -> Void)?
    public var onHighSpeedHeartRateReceived: ((_ hr: Double) -> Void)?
    public var onReachabilityChanged: ((Bool) -> Void)?
    public var onWatchLeaseStatusChanged: ((Bool) -> Void)?
    public private(set) var latestAdvertisedWatchHS: WatchToPhoneHighSpeed?
    public var onWatchHighSpeedAdvertised: ((WatchToPhoneHighSpeed) -> Void)?
    public private(set) var latestAdvertisedPhoneHS: PhoneToWatchHighSpeed?
    public var onPhoneHighSpeedAdvertised: ((PhoneToWatchHighSpeed) -> Void)?
    
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
           let saved = try? JSONDecoder().decode(LowSpeedSnapshot.self, from: data) {
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
            self.localLS = seeded
        }
        
        if let data = UserDefaults.standard.data(forKey: peerLSPersistenceKey),
           let savedPeer = try? JSONDecoder().decode(LowSpeedSnapshot.self, from: data) {
            self.peerLS = savedPeer
        }
        
        super.init()
        
        #if canImport(WatchConnectivity)
        if WCSession.isSupported() {
            self.isSessionSupported = true
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
        #endif
        
        startLeaseMonitoring()
    }
    
    public func activate() {
        #if canImport(WatchConnectivity)
        if WCSession.isSupported() && WCSession.default.activationState == .notActivated {
            WCSession.default.activate()
        }
        #endif
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
                guard let self = self else { return }
                let now = Date().timeIntervalSince1970
                let active = (self.latestRemoteActiveUntil > now)
                if self.isWatchLeaseActive != active {
                    self.isWatchLeaseActive = active
                    self.onWatchLeaseStatusChanged?(active)
                }
            }
    }
    
    // MARK: - State Mutation & Low-Speed Updates

    /// Updates the membership/tactical domain structures (serialized views of Firebase room state
    /// / local tactical indicators, not user-editable leaf fields) and evaluates whether
    /// convergence retransmission is needed. Must be called on the main thread, same as the
    /// mutateLocal* methods below.
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

    /// Local mutations above always originate on the main thread (UI-driven) and assign into
    /// `localLS` synchronously for instant UI feedback. `checkAndTriggerConvergence` also runs
    /// here on main (it reads `peerLS`, which — like `localLS` — is only ever touched on main);
    /// only the actual I/O (UserDefaults write, WCSession publish) is handed to `contextQueue`,
    /// operating on a captured copy so it never touches `localLS`/`peerLS` directly.
    private func persistAndPublishLocalState() {
        let snapshot = localLS
        saveLocalState(snapshot)
        checkAndTriggerConvergence(local: snapshot)
        publishApplicationContext(local: snapshot)
    }
    
    // MARK: - High-Speed Outgoing Stream (Asymmetrical Routing)
    
    /// Advertises Phone-owned high-speed payload (p2w_hs) via updateApplicationContext.
    public func advertisePhoneHighSpeed(
        remotePlayerTelemetryJson: String = "{}"
    ) {
        guard localRole == .phone else { return }
        let now = Date().timeIntervalSince1970
        let lease = now + AppConstants.WatchConnectivity.activeUntilLeaseDurationSeconds
        let hs = PhoneToWatchHighSpeed(
            activeUntil: lease,
            remotePlayerTelemetryJson: remotePlayerTelemetryJson
        )
        self.latestAdvertisedPhoneHS = hs
        self.onPhoneHighSpeedAdvertised?(hs)
        
        publishApplicationContext(local: localLS, phoneHS: hs)
    }
    
    /// Advertises Watch-owned high-speed stream (w2p_hs) via sendMessage (with updateApplicationContext fallback).
    public func advertiseWatchHighSpeed(
        heartRate: Double,
        remotePlayerTelemetryJson: String = "{}"
    ) {
        guard localRole == .watch else { return }
        let now = Date().timeIntervalSince1970
        let lease = now + AppConstants.WatchConnectivity.activeUntilLeaseDurationSeconds
        let hs = WatchToPhoneHighSpeed(
            activeUntil: lease,
            heartRate: heartRate,
            remotePlayerTelemetryJson: remotePlayerTelemetryJson
        )
        self.latestAdvertisedWatchHS = hs
        self.onWatchHighSpeedAdvertised?(hs)
        
        // `localLS` is only ever touched on the main thread; capture it here (this function is
        // called from GameStateManager on main) before handing off to the background queue.
        let localSnapshot = localLS

        #if canImport(WatchConnectivity)
        let session = WCSession.default
        if session.activationState == .activated && session.isReachable {
            var envelope = ApplicationContextEnvelope()
            envelope.w2pHS = hs
            if let data = try? JSONEncoder().encode(envelope),
               let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                session.sendMessage(dict, replyHandler: nil) { [weak self] _ in
                    // If sendMessage drops, fallback to context update
                    self?.publishApplicationContext(local: localSnapshot, watchHS: hs)
                }
                return
            }
        }
        #endif

        publishApplicationContext(local: localSnapshot, watchHS: hs)
    }

    // MARK: - Convergence & Rolling sync_ts

    /// Must be called on the main thread — reads `peerLS`, which (like `localLS`) is only ever
    /// touched on main.
    private func checkAndTriggerConvergence(local: LowSpeedSnapshot) {
        guard let peer = peerLS else {
            // No peer snapshot seen yet: start rolling sync_ts to announce local state
            startRollingSync()
            return
        }

        if local.isDomainEquivalent(to: peer) {
            // Fully converged
            stopRollingSync()
        } else {
            // Discrepancy exists: evaluate whether local device owns any winning structure
            let (_, localWins) = MergeEngine.merge(local: local, peer: peer, localDevice: localRole)
            if localWins {
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
    private func rollSyncTimestampAndPublish() {
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
    
    private var lastPublishedPhoneHS: PhoneToWatchHighSpeed?
    private var lastPublishedWatchHS: WatchToPhoneHighSpeed?
    
    /// `local` must be captured by the caller from `localLS` on the main thread beforehand — this
    /// function itself only touches `contextQueue`-owned state (the WCSession call + the
    /// last-published HS caches) and never reads `localLS`/`peerLS` directly, so it's safe to
    /// dispatch onto `contextQueue` regardless of which thread calls it.
    private func publishApplicationContext(
        local: LowSpeedSnapshot,
        phoneHS: PhoneToWatchHighSpeed? = nil,
        watchHS: WatchToPhoneHighSpeed? = nil
    ) {
        contextQueue.async { [weak self] in
            guard let self = self else { return }
            #if canImport(WatchConnectivity)
            guard WCSession.isSupported() else { return }
            let session = WCSession.default
            guard session.activationState == .activated else { return }
            #if os(iOS)
            guard session.isPaired && session.isWatchAppInstalled else { return }
            #endif

            if let phs = phoneHS { self.lastPublishedPhoneHS = phs }
            if let whs = watchHS { self.lastPublishedWatchHS = whs }

            var envelope = ApplicationContextEnvelope()
            if self.localRole == .phone {
                envelope.p2wLS = local
                envelope.p2wHS = self.lastPublishedPhoneHS
            } else {
                envelope.w2pLS = local
                envelope.w2pHS = self.lastPublishedWatchHS
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
    public func handleIncomingApplicationContext(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let envelope = try? JSONDecoder().decode(ApplicationContextEnvelope.self, from: data) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // 1. Process High-Speed Payloads (Unidirectional)
            if self.localRole == .watch, let p2wHS = envelope.p2wHS {
                self.latestRemoteActiveUntil = p2wHS.activeUntil
                self.latestRemoteTelemetryJson = p2wHS.remotePlayerTelemetryJson
                self.onHighSpeedTelemetryReceived?(p2wHS.remotePlayerTelemetryJson)
            } else if self.localRole == .phone, let w2pHS = envelope.w2pHS {
                self.latestRemoteActiveUntil = w2pHS.activeUntil
                self.latestRemoteHeartRate = w2pHS.heartRate
                let active = (w2pHS.activeUntil > Date().timeIntervalSince1970)
                if self.isWatchLeaseActive != active {
                    self.isWatchLeaseActive = active
                    self.onWatchLeaseStatusChanged?(active)
                }
                if !w2pHS.remotePlayerTelemetryJson.isEmpty && w2pHS.remotePlayerTelemetryJson != "{}" {
                    self.latestRemoteTelemetryJson = w2pHS.remotePlayerTelemetryJson
                    self.onHighSpeedTelemetryReceived?(w2pHS.remotePlayerTelemetryJson)
                }
                self.onHighSpeedHeartRateReceived?(w2pHS.heartRate)
            }

            // 2. Process Low-Speed Payloads (Bidirectional Merge)
            let peerSnapshot = (self.localRole == .phone) ? envelope.w2pLS : envelope.p2wLS
            if let peer = peerSnapshot {
                self.peerLS = peer
                self.savePeerState(peer)

                // Merge peer snapshot into local snapshot — this assignment IS the value
                // changing; there is nothing else to copy the result into.
                let (mergedLocal, localWins) = MergeEngine.merge(local: self.localLS, peer: peer, localDevice: self.localRole)
                let localChanged = !self.localLS.isDomainEquivalent(to: mergedLocal)
                self.localLS = mergedLocal
                self.saveLocalState(mergedLocal)

                if localWins {
                    self.startRollingSync()
                } else {
                    // Either fully converged or local lost all discrepancies — either way, stop
                    // retrying.
                    self.stopRollingSync()
                }

                // If local state adopted winning peer structures or changed, publish updated local snapshot
                if localChanged {
                    self.publishApplicationContext(local: mergedLocal)
                }

                self.onLowSpeedConvergenceStateChanged?(mergedLocal)
            }
        }
    }

    // MARK: - Local Persistence

    private func saveLocalState(_ snapshot: LowSpeedSnapshot) {
        contextQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: self.localLSPersistenceKey)
            }
        }
    }

    private func savePeerState(_ snapshot: LowSpeedSnapshot) {
        contextQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: self.peerLSPersistenceKey)
            }
        }
    }
}

#if canImport(WatchConnectivity)
extension WatchConnectivityManager: WCSessionDelegate {
    public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
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
                handleIncomingApplicationContext(receivedContext)
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
    public func sessionDidBecomeInactive(_ session: WCSession) { }
    
    public func sessionDidDeactivate(_ session: WCSession) {
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

