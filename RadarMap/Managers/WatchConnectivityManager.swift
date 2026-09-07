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
    
    // Outbound low-speed snapshot owned by this device
    public private(set) var localLS: LowSpeedSnapshot
    
    // Last-known counterpart low-speed snapshot received
    public private(set) var peerLS: LowSpeedSnapshot?
    
    // Last-known counterpart high-speed payload
    public private(set) var latestRemoteHSFreshUntil: TimeInterval = 0
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
    public var onHighSpeedTelemetryReceived: ((_ telemetryJson: String, _ freshUntil: TimeInterval) -> Void)?
    public var onHighSpeedHeartRateReceived: ((_ hr: Double, _ freshUntil: TimeInterval) -> Void)?
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
           let saved = try? JSONDecoder().decode(LowSpeedSnapshot.self, from: data) {
            self.localLS = saved
        } else {
            self.localLS = LowSpeedSnapshot()
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
    
    /// Updates one or more domain structures owned by this device and evaluates whether convergence retransmission is needed.
    public func updateLocalStructures(
        config: ConfigSnapshot? = nil,
        loginCycle: LoginCycleSnapshot? = nil,
        membership: MembershipSnapshot? = nil,
        tactical: TacticalSnapshot? = nil,
        playerState: PlayerStateSnapshot? = nil
    ) {
        contextQueue.async { [weak self] in
            guard let self = self else { return }
            
            if let config = config {
                self.localLS.config = config
            }
            if let loginCycle = loginCycle {
                self.localLS.loginCycle = loginCycle
            }
            if let membership = membership {
                self.localLS.membership = membership
            }
            if let tactical = tactical {
                self.localLS.tactical = tactical
            }
            if let playerState = playerState {
                self.localLS.playerState = playerState
            }
            
            self.saveLocalState()
            self.checkAndTriggerConvergence()
            self.publishApplicationContext()
        }
    }
    
    // MARK: - High-Speed Outgoing Stream (Asymmetrical Routing)
    
    /// Advertises Phone-owned high-speed payload (p2w_hs) via updateApplicationContext.
    public func advertisePhoneHighSpeed(
        remotePlayerTelemetryJson: String = "{}",
        ttl: TimeInterval = AppConstants.WatchConnectivity.defaultFreshnessTTLSeconds
    ) {
        guard localRole == .phone else { return }
        let now = Date().timeIntervalSince1970
        let lease = now + AppConstants.WatchConnectivity.activeUntilLeaseDurationSeconds
        let hs = PhoneToWatchHighSpeed(
            activeUntil: lease,
            freshUntil: now + ttl,
            remotePlayerTelemetryJson: remotePlayerTelemetryJson
        )
        
        contextQueue.async { [weak self] in
            guard let self = self else { return }
            self.publishApplicationContext(phoneHS: hs)
        }
    }
    
    /// Advertises Watch-owned high-speed stream (w2p_hs) via sendMessage (with updateApplicationContext fallback).
    public func advertiseWatchHighSpeed(
        heartRate: Double,
        remotePlayerTelemetryJson: String = "{}",
        ttl: TimeInterval = AppConstants.WatchConnectivity.defaultFreshnessTTLSeconds
    ) {
        guard localRole == .watch else { return }
        let now = Date().timeIntervalSince1970
        let lease = now + AppConstants.WatchConnectivity.activeUntilLeaseDurationSeconds
        let hs = WatchToPhoneHighSpeed(
            activeUntil: lease,
            freshUntil: now + ttl,
            heartRate: heartRate,
            remotePlayerTelemetryJson: remotePlayerTelemetryJson
        )
        
        #if canImport(WatchConnectivity)
        let session = WCSession.default
        if session.activationState == .activated && session.isReachable {
            var envelope = ApplicationContextEnvelope()
            envelope.w2pHS = hs
            if let data = try? JSONEncoder().encode(envelope),
               let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                session.sendMessage(dict, replyHandler: nil) { [weak self] _ in
                    // If sendMessage drops, fallback to context update
                    self?.contextQueue.async {
                        self?.publishApplicationContext(watchHS: hs)
                    }
                }
                return
            }
        }
        #endif
        
        contextQueue.async { [weak self] in
            guard let self = self else { return }
            self.publishApplicationContext(watchHS: hs)
        }
    }
    
    // MARK: - Convergence & Rolling sync_ts
    
    private func checkAndTriggerConvergence() {
        guard let peer = peerLS else {
            // No peer snapshot seen yet: start rolling sync_ts to announce local state
            startRollingSync()
            return
        }
        
        if localLS.isDomainEquivalent(to: peer) {
            // Fully converged
            stopRollingSync()
        } else {
            // Discrepancy exists: evaluate whether local device owns any winning structure
            let (_, localWins) = MergeEngine.merge(local: localLS, peer: peer, localDevice: localRole)
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
    
    private func rollSyncTimestampAndPublish() {
        #if canImport(WatchConnectivity)
        guard WCSession.default.isReachable else { return }
        #endif
        contextQueue.async { [weak self] in
            guard let self = self else { return }
            self.localLS.syncTs = Date().timeIntervalSince1970
            self.saveLocalState()
            self.publishApplicationContext()
        }
    }
    
    // MARK: - Publishing to WCSession
    
    private var lastPublishedPhoneHS: PhoneToWatchHighSpeed?
    private var lastPublishedWatchHS: WatchToPhoneHighSpeed?
    
    private func publishApplicationContext(
        phoneHS: PhoneToWatchHighSpeed? = nil,
        watchHS: WatchToPhoneHighSpeed? = nil
    ) {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        #if os(iOS)
        guard session.isPaired && session.isWatchAppInstalled else { return }
        #endif
        
        if let phs = phoneHS { lastPublishedPhoneHS = phs }
        if let whs = watchHS { lastPublishedWatchHS = whs }
        
        var envelope = ApplicationContextEnvelope()
        if localRole == .phone {
            envelope.p2wLS = localLS
            envelope.p2wHS = lastPublishedPhoneHS
        } else {
            envelope.w2pLS = localLS
            envelope.w2pHS = lastPublishedWatchHS
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
    
    // MARK: - Processing Incoming Envelopes
    
    public func handleIncomingApplicationContext(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let envelope = try? JSONDecoder().decode(ApplicationContextEnvelope.self, from: data) else { return }
        
        contextQueue.async { [weak self] in
            guard let self = self else { return }
            
            // 1. Process High-Speed Payloads (Unidirectional)
            if self.localRole == .watch, let p2wHS = envelope.p2wHS {
                self.latestRemoteHSFreshUntil = p2wHS.freshUntil
                self.latestRemoteActiveUntil = p2wHS.activeUntil
                self.latestRemoteTelemetryJson = p2wHS.remotePlayerTelemetryJson
                DispatchQueue.main.async {
                    self.onHighSpeedTelemetryReceived?(p2wHS.remotePlayerTelemetryJson, p2wHS.freshUntil)
                }
            } else if self.localRole == .phone, let w2pHS = envelope.w2pHS {
                self.latestRemoteHSFreshUntil = w2pHS.freshUntil
                self.latestRemoteActiveUntil = w2pHS.activeUntil
                self.latestRemoteHeartRate = w2pHS.heartRate
                if !w2pHS.remotePlayerTelemetryJson.isEmpty && w2pHS.remotePlayerTelemetryJson != "{}" {
                    self.latestRemoteTelemetryJson = w2pHS.remotePlayerTelemetryJson
                    DispatchQueue.main.async {
                        self.onHighSpeedTelemetryReceived?(w2pHS.remotePlayerTelemetryJson, w2pHS.freshUntil)
                    }
                }
                DispatchQueue.main.async {
                    self.onHighSpeedHeartRateReceived?(w2pHS.heartRate, w2pHS.freshUntil)
                }
            }
            
            // 2. Process Low-Speed Payloads (Bidirectional Merge)
            let peerSnapshot = (self.localRole == .phone) ? envelope.w2pLS : envelope.p2wLS
            if let peer = peerSnapshot {
                self.peerLS = peer
                self.savePeerState()
                
                // Merge peer snapshot into local snapshot
                let (mergedLocal, localWins) = MergeEngine.merge(local: self.localLS, peer: peer, localDevice: self.localRole)
                let localChanged = !self.localLS.isDomainEquivalent(to: mergedLocal)
                self.localLS = mergedLocal
                self.saveLocalState()
                
                if localWins {
                    self.startRollingSync()
                } else if self.localLS.isDomainEquivalent(to: peer) {
                    self.stopRollingSync()
                } else {
                    // Local lost all discrepancies, stop rolling sync_ts
                    self.stopRollingSync()
                }
                
                // If local state adopted winning peer structures or changed, publish updated local snapshot
                if localChanged {
                    self.publishApplicationContext()
                }
                
                let snapshotToDeliver = self.localLS
                DispatchQueue.main.async {
                    self.onLowSpeedConvergenceStateChanged?(snapshotToDeliver)
                }
            }
        }
    }
    
    // MARK: - Local Persistence
    
    private func saveLocalState() {
        if let data = try? JSONEncoder().encode(localLS) {
            UserDefaults.standard.set(data, forKey: localLSPersistenceKey)
        }
    }
    
    private func savePeerState() {
        if let peer = peerLS, let data = try? JSONEncoder().encode(peer) {
            UserDefaults.standard.set(data, forKey: peerLSPersistenceKey)
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
                publishApplicationContext()
            }
        }
    }
    
    public func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
            self.onReachabilityChanged?(session.isReachable)
        }
        if session.isReachable, isRollingSync {
            rollSyncTimestampAndPublish()
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

