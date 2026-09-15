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

    // MARK: - LS_data: three independent domains (Room, Tactical, Other)
    //
    // Each domain is the sole synced structure for its area (see CompanionSyncModels.swift and
    // the implementation plan §1-2). `Set()`/`Get()` are the only door in — nothing else may
    // write `localRoom`/`localTactical`/`localOther` directly (Swift's `private(set)` on the
    // `@Published` storage enforces this at compile time). `Set()` auto-stamps the field's own
    // per-structure timestamp; callers never pass a timestamp themselves. Each domain keeps its
    // own rolling-sync timer / own outbound syncTs, so a change to one domain never forces a
    // republish cycle for the others — the traffic-minimization goal from the plan. The actual
    // wire publish is still one shared `ApplicationContextEnvelope` (WCSession only exposes one
    // atomic application context) — see that struct's doc comment.

    @Published public private(set) var localRoom: RoomSnapshot = RoomSnapshot()
    public private(set) var peerRoom: RoomSnapshot?
    var isRoomRollingSync = false

    @Published public private(set) var localTactical: TacticalSnapshot = TacticalSnapshot()
    public private(set) var peerTactical: TacticalSnapshot?
    var isTacticalRollingSync = false

    @Published public private(set) var localOther: OtherSnapshot
    public private(set) var peerOther: OtherSnapshot?
    var isOtherRollingSync = false

    // One shared clock drives all three domains' rolling sync (rather than one independent
    // Timer per domain) — joining a room sets localRoom/localTactical/localOther for the first
    // time in the same instant, so with independent timers all three start simultaneously right
    // at login, tripling redraw/publish churn exactly then. A single tick checking all three
    // `is*RollingSync` flags keeps each domain's own start/stop semantics (still only publishes
    // — and stops itself — per its own convergence check) while collapsing three near-simultaneous
    // main-thread wake-ups into one.
    private var rollingTimer: AnyCancellable?

    // High-speed payloads (HS_data): single source of truth for activeUntil and live streaming.
    // Structurally simpler than LS_data — no _ts, no converge, Get() always reads the companion's
    // value (shadow), Set() always writes this device's own outbound value (data). See
    // docs/COMPANION_DATA_SYNC_MODEL.md and the implementation plan's HS_data section.
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

    private var leaseTimer: AnyCancellable?

    // Serialization queue for WCSession context updates to prevent concurrent partially-merged publishes
    private let contextQueue = DispatchQueue(label: "com.radarmap.watchconnectivity.queue")

    // High-level callbacks to GameStateManager
    public var onRoomConvergenceStateChanged: ((RoomSnapshot) -> Void)?
    public var onTacticalConvergenceStateChanged: ((TacticalSnapshot) -> Void)?
    public var onOtherConvergenceStateChanged: ((OtherSnapshot) -> Void)?
    public var onHighSpeedTelemetryReceived: ((_ telemetryJson: String) -> Void)?
    public var onHighSpeedHeartRateReceived: ((_ hr: Double) -> Void)?
    public var onReachabilityChanged: ((Bool) -> Void)?
    public var onWatchLeaseStatusChanged: ((Bool) -> Void)?

    // Persistence keys — only "other" (config/player-state, minus loginCycle) survives an app
    // restart; room membership and tactical markers are session-ephemeral by design.
    private let localOtherPersistenceKey = "wc_local_other_snapshot"
    private let peerOtherPersistenceKey = "wc_peer_other_snapshot"

    public init(role: DeviceRole? = nil) {
        #if os(watchOS)
        let defaultRole: DeviceRole = .watch
        #else
        let defaultRole: DeviceRole = .phone
        #endif
        self.localRole = role ?? defaultRole

        // Room membership and tactical markers are session-ephemeral, like `loginCycle` below —
        // never persisted to disk or restored across an app launch. `localRoom`/`peerRoom` and
        // `localTactical`/`peerTactical` simply start empty each launch; only `localOther`/
        // `peerOther` (config/player-state, minus loginCycle) survive a restart.

        // Other: only `config` is actually meant to survive a restart. `loginCycle` and
        // `playerState` (isDead) are both session-ephemeral and always reset here, the same way,
        // regardless of what was on disk. First launch since this format was introduced seeds
        // config from the legacy per-field UserDefaults keys so existing users don't lose their
        // saved callsign/room/pin/theme/upload preferences.
        if let data = UserDefaults.standard.data(forKey: localOtherPersistenceKey),
           var saved = try? JSONDecoder().decode(OtherSnapshot.self, from: data) {
            saved.loginCycle = LoginCycleSnapshot(loginCycle: .inactive, loginCycleTs: 0)
            saved.playerState = PlayerStateSnapshot()
            self.localOther = saved
        } else {
            let defaults = UserDefaults.standard
            var seeded = OtherSnapshot()
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
            self.localOther = seeded
        }

        if let data = UserDefaults.standard.data(forKey: peerOtherPersistenceKey),
           var savedPeer = try? JSONDecoder().decode(OtherSnapshot.self, from: data) {
            savedPeer.loginCycle = LoginCycleSnapshot(loginCycle: .inactive, loginCycleTs: 0)
            savedPeer.playerState = PlayerStateSnapshot()
            self.peerOther = savedPeer
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

    /// Test-only: seeds the three domains directly with arbitrary snapshots, including
    /// caller-chosen timestamps — simulating state already persisted from a previous session, as
    /// opposed to a live local edit (which `Set()` always stamps with the current time). Does not
    /// persist or publish; production code should never call this.
    public func testSeedLocal(room: RoomSnapshot? = nil, tactical: TacticalSnapshot? = nil, other: OtherSnapshot? = nil) {
        if let room = room { localRoom = room }
        if let tactical = tactical { localTactical = tactical }
        if let other = other { localOther = other }
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
    /// deadline. See prior doc comment history — unchanged behavior from before this refactor.
    public func correctStaleLeaseExpiry() {
        guard isWatchLeaseActive, companionActiveUntil > 0, companionActiveUntil <= Date().timeIntervalSince1970 else { return }
        isWatchLeaseActive = false
        onWatchLeaseStatusChanged?(false)
    }

    // MARK: - Room: Set() / Get()

    public func roomGet() -> RoomSnapshot { localRoom }

    /// The only way to write `localRoom`. Auto-stamps `roomTs`; the caller (a Firebase Observer
    /// pipeline's canonicalize step, or Room life cycle management) supplies the finished content
    /// only. No-ops (no timestamp bump, no publish) if the content is unchanged.
    public func roomSet(_ newValue: RoomSnapshot) {
        guard newValue.members != localRoom.members ||
              newValue.hostId != localRoom.hostId ||
              newValue.roomId != localRoom.roomId ||
              newValue.pinHash != localRoom.pinHash ||
              newValue.maxCapacity != localRoom.maxCapacity ||
              newValue.maxTacticalIndicators != localRoom.maxTacticalIndicators else { return }
        var stamped = newValue
        stamped.roomTs = Date().timeIntervalSince1970
        stamped.syncTs = localRoom.syncTs
        localRoom = stamped
        persistAndPublishRoom()
    }

    // MARK: - Tactical: Set() / Get()

    public func tacticalGet() -> TacticalSnapshot { localTactical }

    public func tacticalSet(_ newValue: TacticalSnapshot) {
        guard newValue.indicators != localTactical.indicators else { return }
        var stamped = newValue
        stamped.tacticalTs = Date().timeIntervalSince1970
        stamped.syncTs = localTactical.syncTs
        localTactical = stamped
        persistAndPublishTactical()
    }

    // MARK: - Other: mutate helpers (config/loginCycle/playerState each stamp their own sub-ts)

    /// Mutates `localOther.config` in place — the single source of truth for callsign/roomName/
    /// pin/databaseURL/theme/isPro/upload-toggle fields.
    public func mutateLocalConfig(_ mutate: (inout ConfigSnapshot) -> Void) {
        var updated = localOther.config
        mutate(&updated)
        guard !updated.isEquivalent(to: localOther.config) else { return }
        updated.configTs = Date().timeIntervalSince1970
        localOther.config = updated
        persistAndPublishOther()
    }

    /// Mutates `localOther.playerState` in place — the single source of truth for `isDead`.
    public func mutateLocalPlayerState(_ mutate: (inout PlayerStateSnapshot) -> Void) {
        var updated = localOther.playerState
        mutate(&updated)
        guard !updated.isEquivalent(to: localOther.playerState) else { return }
        updated.isDeadTs = Date().timeIntervalSince1970
        localOther.playerState = updated
        persistAndPublishOther()
    }

    /// Mutates `localOther.loginCycle` in place — the single source of truth for the coarse
    /// inactive/hostActive/joinActive room-lifecycle state.
    public func mutateLocalLoginCycle(_ mutate: (inout LoginCycleSnapshot) -> Void) {
        var updated = localOther.loginCycle
        mutate(&updated)
        guard !updated.isEquivalent(to: localOther.loginCycle) else { return }
        updated.loginCycleTs = Date().timeIntervalSince1970
        localOther.loginCycle = updated
        persistAndPublishOther()
    }

    // MARK: - Debug logging

    private func debugDescribe<T: Encodable>(_ snapshot: T) -> String {
        guard let data = try? JSONEncoder().encode(snapshot),
              let json = String(data: data, encoding: .utf8) else { return "<unencodable>" }
        return json
    }

    // MARK: - Per-domain persist + convergence-check + publish
    //
    // All local mutations above always originate on the main thread (UI-driven or a Firebase
    // Observer callback already hopped to main) and assign synchronously for instant UI feedback.
    // `checkAndTriggerConvergence*` also runs here on main (it reads the domain's `peer*`, which —
    // like `local*` — is only ever touched on main); only the actual I/O (UserDefaults write,
    // WCSession publish) is handed to `contextQueue`, operating on a captured copy so it never
    // touches `local*`/`peer*` directly.

    private func persistAndPublishRoom() {
        checkAndTriggerRoomConvergence()
        let snapshot = localRoom
        print("[WCSession \(localRole)] localRoom changed: \(debugDescribe(snapshot))")
        publishApplicationContext()
    }

    private func persistAndPublishTactical() {
        checkAndTriggerTacticalConvergence()
        let snapshot = localTactical
        print("[WCSession \(localRole)] localTactical changed: \(debugDescribe(snapshot))")
        publishApplicationContext()
    }

    private func persistAndPublishOther() {
        checkAndTriggerOtherConvergence()
        let snapshot = localOther
        print("[WCSession \(localRole)] localOther changed: \(debugDescribe(snapshot))")
        saveLocalOther(snapshot)
        publishApplicationContext()
    }

    // MARK: - Convergence & Rolling sync_ts (per domain)

    private func checkAndTriggerRoomConvergence() {
        guard let peer = peerRoom else {
            localRoom.syncTs = Date().timeIntervalSince1970
            startRoomRollingSync()
            return
        }
        if localRoom.isEquivalent(to: peer) {
            stopRoomRollingSync()
        } else {
            let (_, localWins) = MergeEngine.mergeRoom(local: localRoom, peer: peer, localDevice: localRole)
            if localWins {
                localRoom.syncTs = Date().timeIntervalSince1970
                startRoomRollingSync()
            } else {
                stopRoomRollingSync()
            }
        }
    }

    private func checkAndTriggerTacticalConvergence() {
        guard let peer = peerTactical else {
            localTactical.syncTs = Date().timeIntervalSince1970
            startTacticalRollingSync()
            return
        }
        if localTactical.isEquivalent(to: peer) {
            stopTacticalRollingSync()
        } else {
            let (_, localWins) = MergeEngine.mergeTactical(local: localTactical, peer: peer, localDevice: localRole)
            if localWins {
                localTactical.syncTs = Date().timeIntervalSince1970
                startTacticalRollingSync()
            } else {
                stopTacticalRollingSync()
            }
        }
    }

    private func checkAndTriggerOtherConvergence() {
        guard let peer = peerOther else {
            localOther.syncTs = Date().timeIntervalSince1970
            startOtherRollingSync()
            return
        }
        if localOther.isDomainEquivalent(to: peer) {
            stopOtherRollingSync()
        } else {
            let (_, localWins) = MergeEngine.mergeOther(local: localOther, peer: peer, localDevice: localRole)
            if localWins {
                localOther.syncTs = Date().timeIntervalSince1970
                startOtherRollingSync()
            } else {
                stopOtherRollingSync()
            }
        }
    }

    private func canStartRollingSync() -> Bool {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return false }
        #if os(iOS)
        guard WCSession.default.isPaired && WCSession.default.isWatchAppInstalled else { return false }
        #endif
        #endif
        return true
    }

    /// Starts the shared clock if it isn't already running. Safe to call redundantly — each
    /// domain calls this whenever it needs the clock, and the clock itself only stops once no
    /// domain needs it anymore (see `stopSharedRollingTimerIfIdle`).
    private func startSharedRollingTimer() {
        guard rollingTimer == nil else { return }
        rollingTimer = Timer.publish(every: AppConstants.WatchConnectivity.defaultHighSpeedCadenceSeconds, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.isRoomRollingSync { self.rollRoomSyncTimestampAndPublish() }
                if self.isTacticalRollingSync { self.rollTacticalSyncTimestampAndPublish() }
                if self.isOtherRollingSync { self.rollOtherSyncTimestampAndPublish() }
            }
    }

    private func stopSharedRollingTimerIfIdle() {
        guard !isRoomRollingSync, !isTacticalRollingSync, !isOtherRollingSync else { return }
        rollingTimer?.cancel()
        rollingTimer = nil
    }

    private func startRoomRollingSync() {
        guard !isRoomRollingSync, canStartRollingSync() else { return }
        isRoomRollingSync = true
        DispatchQueue.main.async { [weak self] in
            self?.startSharedRollingTimer()
        }
    }

    public func stopRoomRollingSync() {
        isRoomRollingSync = false
        DispatchQueue.main.async { [weak self] in
            self?.stopSharedRollingTimerIfIdle()
        }
    }

    private func startTacticalRollingSync() {
        guard !isTacticalRollingSync, canStartRollingSync() else { return }
        isTacticalRollingSync = true
        DispatchQueue.main.async { [weak self] in
            self?.startSharedRollingTimer()
        }
    }

    public func stopTacticalRollingSync() {
        isTacticalRollingSync = false
        DispatchQueue.main.async { [weak self] in
            self?.stopSharedRollingTimerIfIdle()
        }
    }

    private func startOtherRollingSync() {
        guard !isOtherRollingSync, canStartRollingSync() else { return }
        isOtherRollingSync = true
        DispatchQueue.main.async { [weak self] in
            self?.startSharedRollingTimer()
        }
    }

    public func stopOtherRollingSync() {
        isOtherRollingSync = false
        DispatchQueue.main.async { [weak self] in
            self?.stopSharedRollingTimerIfIdle()
        }
    }

    /// Re-checks convergence against peer on every tick before republishing, rather than blindly
    /// republishing forever — same reasoning as the original single-domain implementation this
    /// replaced (see git history / docs/COMPANION_DATA_SYNC_MODEL.md).
    private func rollRoomSyncTimestampAndPublish() {
        if let peer = peerRoom, localRoom.isEquivalent(to: peer) {
            stopRoomRollingSync()
            return
        }
        // Deliberately NOT gated on isReachable — see publishApplicationContext's doc comment.
        localRoom.syncTs = Date().timeIntervalSince1970
        publishApplicationContext()
    }

    private func rollTacticalSyncTimestampAndPublish() {
        if let peer = peerTactical, localTactical.isEquivalent(to: peer) {
            stopTacticalRollingSync()
            return
        }
        localTactical.syncTs = Date().timeIntervalSince1970
        publishApplicationContext()
    }

    private func rollOtherSyncTimestampAndPublish() {
        if let peer = peerOther, localOther.isDomainEquivalent(to: peer) {
            stopOtherRollingSync()
            return
        }
        localOther.syncTs = Date().timeIntervalSince1970
        saveLocalOther(localOther)
        publishApplicationContext()
    }

    // MARK: - Publishing to WCSession
    //
    // One shared envelope, independently triggered per domain (see ApplicationContextEnvelope's
    // doc comment): whichever domain's Set()/rolling-timer fires this, the payload always carries
    // the CURRENT state of all three domains — `updateApplicationContext` only exposes one atomic
    // context, so there is no way to publish "just Room" without the others.
    private func publishApplicationContext() {
        let room = localRoom
        let tactical = localTactical
        let other = localOther
        let role = localRole

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
            if role == .phone {
                envelope.p2wRoom = room
                envelope.p2wTactical = tactical
                envelope.p2wOther = other
            } else {
                envelope.w2pRoom = room
                envelope.w2pTactical = tactical
                envelope.w2pOther = other
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
        guard session.activationState == .activated, session.isReachable else { return }
        var envelope = ApplicationContextEnvelope()
        envelope.p2wHS = hs
        if let data = try? JSONEncoder().encode(envelope),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            session.sendMessage(dict, replyHandler: nil, errorHandler: nil)
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
        guard session.activationState == .activated, session.isReachable else { return }
        var envelope = ApplicationContextEnvelope()
        envelope.w2pHS = hs
        if let data = try? JSONEncoder().encode(envelope),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            session.sendMessage(dict, replyHandler: nil, errorHandler: nil)
        }
        #endif
    }

    // MARK: - Processing Incoming Envelopes

    /// Runs entirely on the main thread — `WCSessionDelegate` callbacks that feed this can land on
    /// an arbitrary background queue, but `local*`/`peer*` are only ever touched on main, so the
    /// whole merge is dispatched there rather than to `contextQueue`.
    public func handleIncomingApplicationContext(_ dict: [String: Any], isReplayedContext: Bool = false) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              var envelope = try? JSONDecoder().decode(ApplicationContextEnvelope.self, from: data) else { return }

        // `session.receivedApplicationContext` is cached by the OS and redelivered verbatim on
        // activation, even across a cold relaunch or an app that force-quit mid-session — so a
        // stale `login_cycle` from a previous session can resurface here and get adopted as if it
        // were a live handshake. Live pushes (didReceiveApplicationContext/didReceiveMessage) are
        // never replayed this way, so only the activation-time replay needs sanitizing.
        if isReplayedContext {
            envelope.p2wOther?.loginCycle = LoginCycleSnapshot(loginCycle: .inactive, loginCycleTs: 0)
            envelope.w2pOther?.loginCycle = LoginCycleSnapshot(loginCycle: .inactive, loginCycleTs: 0)
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

            // 2. Process Low-Speed Payloads (Bidirectional Merge) — one per domain
            let peerRoomSnapshot = (self.localRole == .phone) ? envelope.w2pRoom : envelope.p2wRoom
            if let peer = peerRoomSnapshot {
                self.mergeIncomingRoom(peer)
            }
            let peerTacticalSnapshot = (self.localRole == .phone) ? envelope.w2pTactical : envelope.p2wTactical
            if let peer = peerTacticalSnapshot {
                self.mergeIncomingTactical(peer)
            }
            let peerOtherSnapshot = (self.localRole == .phone) ? envelope.w2pOther : envelope.p2wOther
            if let peer = peerOtherSnapshot {
                self.mergeIncomingOther(peer)
            }
        }
    }

    /// Must be called on the main thread. Adopts an incoming peer Room snapshot: records it as
    /// `peerRoom` (the WCSession-facing `shadow`), merges it into `localRoom` (`data`) via
    /// `MergeEngine.mergeRoom`, and re-triggers this domain's own rolling-sync cycle exactly like
    /// a local `Set()` change would.
    private func mergeIncomingRoom(_ peer: RoomSnapshot) {
        print("[WCSession \(localRole)] peerRoom received: \(debugDescribe(peer))")
        self.peerRoom = peer

        let (mergedLocal, localWins) = MergeEngine.mergeRoom(local: localRoom, peer: peer, localDevice: localRole)
        let localChanged = !localRoom.isEquivalent(to: mergedLocal)
        self.localRoom = mergedLocal
        if localChanged {
            print("[WCSession \(localRole)] localRoom merged (localWins=\(localWins)): \(debugDescribe(mergedLocal))")
        }

        if localWins || localChanged {
            self.localRoom.syncTs = Date().timeIntervalSince1970
            startRoomRollingSync()
        } else {
            stopRoomRollingSync()
        }

        if localChanged {
            publishApplicationContext()
        }
        onRoomConvergenceStateChanged?(localRoom)
    }

    private func mergeIncomingTactical(_ peer: TacticalSnapshot) {
        print("[WCSession \(localRole)] peerTactical received: \(debugDescribe(peer))")
        self.peerTactical = peer

        let (mergedLocal, localWins) = MergeEngine.mergeTactical(local: localTactical, peer: peer, localDevice: localRole)
        let localChanged = !localTactical.isEquivalent(to: mergedLocal)
        self.localTactical = mergedLocal
        if localChanged {
            print("[WCSession \(localRole)] localTactical merged (localWins=\(localWins)): \(debugDescribe(mergedLocal))")
        }

        if localWins || localChanged {
            self.localTactical.syncTs = Date().timeIntervalSince1970
            startTacticalRollingSync()
        } else {
            stopTacticalRollingSync()
        }

        if localChanged {
            publishApplicationContext()
        }
        onTacticalConvergenceStateChanged?(localTactical)
    }

    private func mergeIncomingOther(_ peer: OtherSnapshot) {
        print("[WCSession \(localRole)] peerOther received: \(debugDescribe(peer))")
        self.peerOther = peer
        saveOther(peer, key: peerOtherPersistenceKey)

        let (mergedLocal, localWins) = MergeEngine.mergeOther(local: localOther, peer: peer, localDevice: localRole)
        let localChanged = !localOther.isDomainEquivalent(to: mergedLocal)
        self.localOther = mergedLocal
        if localChanged {
            print("[WCSession \(localRole)] localOther merged (localWins=\(localWins)): \(debugDescribe(mergedLocal))")
        }

        if localWins || localChanged {
            self.localOther.syncTs = Date().timeIntervalSince1970
            startOtherRollingSync()
        } else {
            stopOtherRollingSync()
        }

        saveLocalOther(localOther)
        if localChanged {
            publishApplicationContext()
        }
        onOtherConvergenceStateChanged?(localOther)
    }

    // MARK: - Local Persistence

    private func saveOther(_ snapshot: OtherSnapshot, key: String) {
        var toSave = snapshot
        toSave.loginCycle = LoginCycleSnapshot(loginCycle: .inactive, loginCycleTs: 0)
        toSave.playerState = PlayerStateSnapshot()
        contextQueue.async {
            if let data = try? JSONEncoder().encode(toSave) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }
    private func saveLocalOther(_ snapshot: OtherSnapshot) { saveOther(snapshot, key: localOtherPersistenceKey) }
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
                    self?.publishApplicationContext()
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
        if session.isReachable {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.isRoomRollingSync { self.rollRoomSyncTimestampAndPublish() }
                if self.isTacticalRollingSync { self.rollTacticalSyncTimestampAndPublish() }
                if self.isOtherRollingSync { self.rollOtherSyncTimestampAndPublish() }
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
