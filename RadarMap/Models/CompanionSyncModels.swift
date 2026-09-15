import Foundation

// MARK: - Room Lifecycle Enum

public enum LoginCycleState: String, Codable, Equatable {
    case inactive = "inactive"
    case hostActive = "host_active"
    case joinActive = "join_active"
}

// MARK: - Low Speed Mergeable Structures

public struct ConfigSnapshot: Codable, Equatable {
    public var callsign: String
    public var roomName: String
    public var pin: String
    /// Raw custom Firebase RTDB URL textbox value. Empty is meaningful here (means "use the
    /// shared default project"), unlike callsign/roomName/pin below where empty means "not set
    /// yet" — so this field is adopted unconditionally on the receiving side, empty included.
    public var databaseURL: String
    public var theme: String
    public var role: String
    public var isPro: Bool
    public var isUploadHeartRateEnabled: Bool
    public var isUploadLocationEnabled: Bool
    /// Whether this device encrypts its own outbound telemetry/tactical writes (AES-256-GCM).
    /// Synced phone<->watch like every other config field so both devices agree on it — see
    /// `GameStateManager.isEncryptionEnabled` and docs/CLOUD_DATA_MANAGEMENT.md §5.E.
    public var isEncryptionEnabled: Bool
    public var configTs: TimeInterval

    public init(
        callsign: String = "",
        roomName: String = "",
        pin: String = "",
        databaseURL: String = "",
        theme: String = "Green",
        role: String = "player",
        isPro: Bool = false,
        isUploadHeartRateEnabled: Bool = true,
        isUploadLocationEnabled: Bool = true,
        isEncryptionEnabled: Bool = true,
        configTs: TimeInterval = 0
    ) {
        self.callsign = callsign
        self.roomName = roomName
        self.pin = pin
        self.databaseURL = databaseURL
        self.theme = theme
        self.role = role
        self.isPro = isPro
        self.isUploadHeartRateEnabled = isUploadHeartRateEnabled
        self.isUploadLocationEnabled = isUploadLocationEnabled
        self.isEncryptionEnabled = isEncryptionEnabled
        self.configTs = configTs
    }

    enum CodingKeys: String, CodingKey {
        case callsign, roomName, pin, databaseURL, theme, role, isPro
        case isUploadHeartRateEnabled, isUploadLocationEnabled, isEncryptionEnabled
        case configTs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.callsign = try container.decodeIfPresent(String.self, forKey: .callsign) ?? ""
        self.roomName = try container.decodeIfPresent(String.self, forKey: .roomName) ?? ""
        self.pin = try container.decodeIfPresent(String.self, forKey: .pin) ?? ""
        self.databaseURL = try container.decodeIfPresent(String.self, forKey: .databaseURL) ?? ""
        self.theme = try container.decodeIfPresent(String.self, forKey: .theme) ?? "Green"
        self.role = try container.decodeIfPresent(String.self, forKey: .role) ?? "player"
        self.isPro = try container.decodeIfPresent(Bool.self, forKey: .isPro) ?? false
        self.isUploadHeartRateEnabled = try container.decodeIfPresent(Bool.self, forKey: .isUploadHeartRateEnabled) ?? true
        self.isUploadLocationEnabled = try container.decodeIfPresent(Bool.self, forKey: .isUploadLocationEnabled) ?? true
        self.isEncryptionEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEncryptionEnabled) ?? true
        self.configTs = try container.decodeIfPresent(TimeInterval.self, forKey: .configTs) ?? 0.0
    }

    public func isEquivalent(to other: ConfigSnapshot) -> Bool {
        return callsign == other.callsign &&
               roomName == other.roomName &&
               pin == other.pin &&
               databaseURL == other.databaseURL &&
               theme == other.theme &&
               role == other.role &&
               isPro == other.isPro &&
               isUploadHeartRateEnabled == other.isUploadHeartRateEnabled &&
               isUploadLocationEnabled == other.isUploadLocationEnabled &&
               isEncryptionEnabled == other.isEncryptionEnabled &&
               configTs == other.configTs
    }
}

public struct LoginCycleSnapshot: Codable, Equatable {
    public var loginCycle: LoginCycleState
    public var loginCycleTs: TimeInterval

    public init(loginCycle: LoginCycleState = .inactive, loginCycleTs: TimeInterval = 0) {
        self.loginCycle = loginCycle
        self.loginCycleTs = loginCycleTs
    }

    public func isEquivalent(to other: LoginCycleSnapshot) -> Bool {
        return loginCycle == other.loginCycle && loginCycleTs == other.loginCycleTs
    }
}

/// Room domain — one of the three independent `LS_data` instances (see CompanionSyncModels.swift
/// top-of-file architecture note and docs/COMPANION_DATA_SYNC_MODEL.md §3). Carries today's
/// roster (`members`/`roomTs`, formerly `MembershipSnapshot`) plus the room-metadata fields that
/// used to live only in `FirebaseSyncManager.activeRoom` (`SquadRoom`) and would otherwise have
/// been lost once that independent store is eliminated — `hostId`/`roomId`/`pinHash`/
/// `maxCapacity`/`maxTacticalIndicators`. `syncTs` is this domain's own outbound
/// convergence-publish trigger (mirrors what `LowSpeedSnapshot.syncTs` was for the whole bundle;
/// see `WatchConnectivityManager`'s per-domain rolling-sync state) — deliberately excluded from
/// `isEquivalent(to:)`, same as before.
public struct RoomSnapshot: Codable, Equatable {
    /// Native roster, not a pre-serialized JSON string — comparison and merge use `Equatable`
    /// array equality directly, so it isn't exposed to JSON-encoder key/float-formatting
    /// nondeterminism the way a string comparison would be.
    public var members: [SquadMember]
    public var hostId: String
    public var roomId: String
    public var pinHash: String
    public var maxCapacity: Int
    public var maxTacticalIndicators: Int
    public var roomTs: TimeInterval
    public var syncTs: TimeInterval

    public init(
        members: [SquadMember] = [],
        hostId: String = "",
        roomId: String = "",
        pinHash: String = "",
        maxCapacity: Int = AppConstants.Subscription.freeTierMaxCapacity,
        maxTacticalIndicators: Int = AppConstants.Subscription.freeTierMaxTacticalIndicators,
        roomTs: TimeInterval = 0,
        syncTs: TimeInterval = 0
    ) {
        self.members = members
        self.hostId = hostId
        self.roomId = roomId
        self.pinHash = pinHash
        self.maxCapacity = maxCapacity
        self.maxTacticalIndicators = maxTacticalIndicators
        self.roomTs = roomTs
        self.syncTs = syncTs
    }

    public func isEquivalent(to other: RoomSnapshot) -> Bool {
        return members == other.members &&
               hostId == other.hostId &&
               roomId == other.roomId &&
               pinHash == other.pinHash &&
               maxCapacity == other.maxCapacity &&
               maxTacticalIndicators == other.maxTacticalIndicators &&
               roomTs == other.roomTs
    }
}

/// Tactical domain — same shape as before (`indicators`/`tacticalTs`), now its own independent
/// `LS_data` instance with its own `syncTs` outbound trigger rather than sharing one with
/// Room/Other.
public struct TacticalSnapshot: Codable, Equatable {
    /// Native indicators — see `RoomSnapshot.members` comment above for why this isn't a JSON
    /// string.
    public var indicators: [TacticalIndicator]
    public var tacticalTs: TimeInterval
    public var syncTs: TimeInterval

    public init(indicators: [TacticalIndicator] = [], tacticalTs: TimeInterval = 0, syncTs: TimeInterval = 0) {
        self.indicators = indicators
        self.tacticalTs = tacticalTs
        self.syncTs = syncTs
    }

    public func isEquivalent(to other: TacticalSnapshot) -> Bool {
        return indicators == other.indicators && tacticalTs == other.tacticalTs
    }
}

public struct PlayerStateSnapshot: Codable, Equatable {
    public var isDead: Bool
    public var isDeadTs: TimeInterval

    public init(isDead: Bool = false, isDeadTs: TimeInterval = 0) {
        self.isDead = isDead
        self.isDeadTs = isDeadTs
    }

    enum CodingKeys: String, CodingKey {
        case isDead = "is_dead"
        case legacyIsDead = "isDead"
        case isDeadTs = "is_dead_ts"
        case legacyIsDeadTs = "isDeadTs"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isDead = (try? container.decode(Bool.self, forKey: .isDead)) ??
                      (try? container.decode(Bool.self, forKey: .legacyIsDead)) ?? false
        self.isDeadTs = (try? container.decode(TimeInterval.self, forKey: .isDeadTs)) ??
                        (try? container.decode(TimeInterval.self, forKey: .legacyIsDeadTs)) ?? 0.0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isDead, forKey: .isDead)
        try container.encode(isDeadTs, forKey: .isDeadTs)
    }

    public func isEquivalent(to other: PlayerStateSnapshot) -> Bool {
        return isDead == other.isDead && isDeadTs == other.isDeadTs
    }
}

/// Other domain — the third independent `LS_data` instance, bundling `config`/`loginCycle`/
/// `playerState` together (small, related, naturally exchanged together — see the wire codable
/// table in the implementation plan, where these three ride under one "Login life cycle config
/// and actions" row). A single `LS_data` instance with multiple concurrently independent sync
/// parameters: each sub-field keeps its own per-field timestamp (`configTs`/`loginCycleTs`/
/// `isDeadTs`) and converges independently via `MergeEngine.mergeOther`, same per-field LWW
/// principle `mergeStructure` already provides for Room/Tactical, just applied to three fields
/// instead of one. `syncTs` is this domain's own outbound convergence-publish trigger.
public struct OtherSnapshot: Codable, Equatable {
    public var config: ConfigSnapshot
    public var loginCycle: LoginCycleSnapshot
    public var playerState: PlayerStateSnapshot
    public var syncTs: TimeInterval

    public init(
        config: ConfigSnapshot = ConfigSnapshot(),
        loginCycle: LoginCycleSnapshot = LoginCycleSnapshot(),
        playerState: PlayerStateSnapshot = PlayerStateSnapshot(),
        syncTs: TimeInterval = 0
    ) {
        self.config = config
        self.loginCycle = loginCycle
        self.playerState = playerState
        self.syncTs = syncTs
    }

    enum CodingKeys: String, CodingKey {
        case config
        case loginCycle = "login_cycle"
        case legacyLoginCycle = "loginCycle"
        case playerState = "player_state"
        case legacyPlayerState = "playerState"
        case syncTs = "sync_ts"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.config = (try? container.decode(ConfigSnapshot.self, forKey: .config)) ?? ConfigSnapshot()
        self.loginCycle = (try? container.decode(LoginCycleSnapshot.self, forKey: .loginCycle)) ??
                          (try? container.decode(LoginCycleSnapshot.self, forKey: .legacyLoginCycle)) ?? LoginCycleSnapshot()
        self.playerState = (try? container.decode(PlayerStateSnapshot.self, forKey: .playerState)) ??
                           (try? container.decode(PlayerStateSnapshot.self, forKey: .legacyPlayerState)) ?? PlayerStateSnapshot()
        self.syncTs = (try? container.decode(TimeInterval.self, forKey: .syncTs)) ?? 0.0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(config, forKey: .config)
        try container.encode(loginCycle, forKey: .loginCycle)
        try container.encode(playerState, forKey: .playerState)
        try container.encode(syncTs, forKey: .syncTs)
    }

    /// Checks whether all three sub-structures (and their own timestamps) are equivalent.
    /// Deliberately ignores this instance's own syncTs, same as RoomSnapshot/TacticalSnapshot.
    public func isDomainEquivalent(to other: OtherSnapshot) -> Bool {
        return config.isEquivalent(to: other.config) &&
               loginCycle.isEquivalent(to: other.loginCycle) &&
               playerState.isEquivalent(to: other.playerState)
    }
}

// MARK: - Directional High-Speed Structures

public struct PhoneToWatchHighSpeed: Codable, Equatable {
    public var activeUntil: TimeInterval
    public var remotePlayerTelemetryJson: String

    public init(
        activeUntil: TimeInterval = 0,
        remotePlayerTelemetryJson: String = "{}"
    ) {
        self.activeUntil = activeUntil
        self.remotePlayerTelemetryJson = remotePlayerTelemetryJson
    }

    enum CodingKeys: String, CodingKey {
        case activeUntil = "active_until"
        case remotePlayerTelemetryJson = "remote_telemetry"
        case slideRemoteTelemetrySnapshot = "remote_player_telemetry_snapshot"
        case legacyRemoteTelemetryJson = "remotePlayerTelemetryJson"
        case legacyActiveUntil = "activeUntil"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.activeUntil = (try? container.decode(TimeInterval.self, forKey: .activeUntil)) ??
                           (try? container.decode(TimeInterval.self, forKey: .legacyActiveUntil)) ?? 0.0
        self.remotePlayerTelemetryJson = (try? container.decode(String.self, forKey: .remotePlayerTelemetryJson)) ??
                                        (try? container.decode(String.self, forKey: .slideRemoteTelemetrySnapshot)) ??
                                        (try? container.decode(String.self, forKey: .legacyRemoteTelemetryJson)) ?? "{}"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(activeUntil, forKey: .activeUntil)
        try container.encode(remotePlayerTelemetryJson, forKey: .remotePlayerTelemetryJson)
    }
}

public struct WatchToPhoneHighSpeed: Codable, Equatable {
    public var activeUntil: TimeInterval
    public var heartRate: Double
    public var remotePlayerTelemetryJson: String

    public init(
        activeUntil: TimeInterval = 0,
        heartRate: Double = 75.0,
        remotePlayerTelemetryJson: String = "{}"
    ) {
        self.activeUntil = activeUntil
        self.heartRate = heartRate
        self.remotePlayerTelemetryJson = remotePlayerTelemetryJson
    }

    enum CodingKeys: String, CodingKey {
        case activeUntil = "active_until"
        case heartRate = "hr"
        case remotePlayerTelemetryJson = "remote_telemetry"
        case slideRemoteTelemetrySnapshot = "remote_player_telemetry_snapshot"
        case legacyHeartRate = "heartRate"
        case legacyRemoteTelemetryJson = "remotePlayerTelemetryJson"
        case legacyActiveUntil = "activeUntil"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.activeUntil = (try? container.decode(TimeInterval.self, forKey: .activeUntil)) ??
                           (try? container.decode(TimeInterval.self, forKey: .legacyActiveUntil)) ?? 0.0
        self.heartRate = (try? container.decode(Double.self, forKey: .heartRate)) ??
                         (try? container.decode(Double.self, forKey: .legacyHeartRate)) ?? 75.0
        self.remotePlayerTelemetryJson = (try? container.decode(String.self, forKey: .remotePlayerTelemetryJson)) ??
                                        (try? container.decode(String.self, forKey: .slideRemoteTelemetrySnapshot)) ??
                                        (try? container.decode(String.self, forKey: .legacyRemoteTelemetryJson)) ?? "{}"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(activeUntil, forKey: .activeUntil)
        try container.encode(heartRate, forKey: .heartRate)
        try container.encode(remotePlayerTelemetryJson, forKey: .remotePlayerTelemetryJson)
    }
}



// MARK: - WCSession Application Context Envelope
//
// One shared envelope, independently triggered per domain: `updateApplicationContext` replaces
// the whole context dictionary atomically, so there is still exactly one wire payload — but each
// of Room/Tactical/Other decides on its own (via its own syncTs/rolling-sync state in
// WatchConnectivityManager) whether ITS change warrants triggering a fresh publish of that shared
// payload. This is the traffic-minimization change: a converged Room/Other no longer gets dragged
// along by Tactical still rolling, the way one shared LowSpeedSnapshot.syncTs forced before.

public struct ApplicationContextEnvelope: Codable, Equatable {
    public var p2wHS: PhoneToWatchHighSpeed?
    public var w2pHS: WatchToPhoneHighSpeed?
    public var p2wRoom: RoomSnapshot?
    public var w2pRoom: RoomSnapshot?
    public var p2wTactical: TacticalSnapshot?
    public var w2pTactical: TacticalSnapshot?
    public var p2wOther: OtherSnapshot?
    public var w2pOther: OtherSnapshot?

    public init(
        p2wHS: PhoneToWatchHighSpeed? = nil,
        w2pHS: WatchToPhoneHighSpeed? = nil,
        p2wRoom: RoomSnapshot? = nil,
        w2pRoom: RoomSnapshot? = nil,
        p2wTactical: TacticalSnapshot? = nil,
        w2pTactical: TacticalSnapshot? = nil,
        p2wOther: OtherSnapshot? = nil,
        w2pOther: OtherSnapshot? = nil
    ) {
        self.p2wHS = p2wHS
        self.w2pHS = w2pHS
        self.p2wRoom = p2wRoom
        self.w2pRoom = w2pRoom
        self.p2wTactical = p2wTactical
        self.w2pTactical = w2pTactical
        self.p2wOther = p2wOther
        self.w2pOther = w2pOther
    }

    enum CodingKeys: String, CodingKey {
        case p2wHS = "p2w_hs"
        case w2pHS = "w2p_hs"
        case p2wRoom = "p2w_room"
        case w2pRoom = "w2p_room"
        case p2wTactical = "p2w_tactical"
        case w2pTactical = "w2p_tactical"
        case p2wOther = "p2w_other"
        case w2pOther = "w2p_other"
    }
}

// MARK: - Conflict Resolution & Winner Selection Engine

public enum DeviceRole {
    case phone
    case watch
}

/// A `*_ls` mergeable structure: carries its own last-change timestamp and can be compared for
/// equality (all conforming snapshot types below are already `Equatable`, and their
/// `isEquivalent(to:)` methods compare the same fields `==` does — so plain `Equatable` is enough
/// for merge purposes; `isEquivalent(to:)` stays in place for its other call sites in
/// `WatchConnectivityManager`'s `mutateLocal*` guards and the `isDomainEquivalent` methods above).
public protocol MergeableLSStructure: Equatable {
    var ts: TimeInterval { get }
}

extension ConfigSnapshot: MergeableLSStructure {
    public var ts: TimeInterval { configTs }
}
extension LoginCycleSnapshot: MergeableLSStructure {
    public var ts: TimeInterval { loginCycleTs }
}
extension RoomSnapshot: MergeableLSStructure {
    public var ts: TimeInterval { roomTs }
}
extension TacticalSnapshot: MergeableLSStructure {
    public var ts: TimeInterval { tacticalTs }
}
extension PlayerStateSnapshot: MergeableLSStructure {
    public var ts: TimeInterval { isDeadTs }
}

public struct MergeEngine {

    /// Determines the winner between a Phone version and a Watch version of a structure.
    /// Rules:
    /// 1. Newer *_ts wins.
    /// 2. If *_ts are equal and values are equal -> converged.
    /// 3. If *_ts are equal and values differ -> Watch wins.
    public static func resolveWinner<T: Equatable>(
        phoneValue: T,
        phoneTs: TimeInterval,
        watchValue: T,
        watchTs: TimeInterval
    ) -> (winnerValue: T, winnerTs: TimeInterval, phoneWon: Bool) {
        if phoneTs > watchTs {
            return (phoneValue, phoneTs, true)
        } else if watchTs > phoneTs {
            return (watchValue, watchTs, false)
        } else {
            // Equal timestamps: Watch wins tie-break (phoneWon = false)
            return (watchValue, watchTs, false)
        }
    }

    /// Merges one `*_ls` structure: resolves the winner via `resolveWinner` (mapping local/peer
    /// onto phone/watch by role) and reports whether *this* device's own value is the one that
    /// won a genuine discrepancy — the single per-structure step every mergeable field shares, so
    /// the per-domain `merge*` entry points below don't need one hand-written copy of this logic
    /// per field (see docs/COMPANION_DATA_SYNC_MODEL.md §3).
    private static func mergeStructure<T: MergeableLSStructure>(
        local: T,
        peer: T,
        isPhone: Bool
    ) -> (winner: T, localWon: Bool) {
        let phoneValue = isPhone ? local : peer
        let watchValue = isPhone ? peer : local
        let result = resolveWinner(
            phoneValue: phoneValue,
            phoneTs: phoneValue.ts,
            watchValue: watchValue,
            watchTs: watchValue.ts
        )
        let localWon = isPhone ? result.phoneWon : !result.phoneWon
        return (result.winnerValue, local != peer && localWon)
    }

    /// Merges an incoming counterpart Room snapshot into the local one. Returns the updated local
    /// snapshot and whether the local device advertises a winning (more-recent, differing)
    /// structure against peer.
    public static func mergeRoom(
        local: RoomSnapshot,
        peer: RoomSnapshot,
        localDevice: DeviceRole
    ) -> (merged: RoomSnapshot, localHasWinningStructure: Bool) {
        let result = mergeStructure(local: local, peer: peer, isPhone: localDevice == .phone)
        return (result.winner, result.localWon)
    }

    /// Merges an incoming counterpart Tactical snapshot into the local one. Same shape as
    /// `mergeRoom` — this is the WCSession phone<->watch convergence layer, a separate mechanism
    /// from the Firebase-echo per-indicator `timestamp` comparison in
    /// `FirebaseSyncManager.applyTacticalSnapshot`.
    public static func mergeTactical(
        local: TacticalSnapshot,
        peer: TacticalSnapshot,
        localDevice: DeviceRole
    ) -> (merged: TacticalSnapshot, localHasWinningStructure: Bool) {
        let result = mergeStructure(local: local, peer: peer, isPhone: localDevice == .phone)
        return (result.winner, result.localWon)
    }

    /// Merges an incoming counterpart Other snapshot into the local one — three independent
    /// per-field merges (config/loginCycle/playerState), each converging on its own timestamp,
    /// combined into one instance-level "did local win anything" flag.
    public static func mergeOther(
        local: OtherSnapshot,
        peer: OtherSnapshot,
        localDevice: DeviceRole
    ) -> (merged: OtherSnapshot, localHasWinningStructure: Bool) {
        var merged = local
        var localHasWinningStructure = false
        let isPhone = (localDevice == .phone)

        let config = mergeStructure(local: local.config, peer: peer.config, isPhone: isPhone)
        merged.config = config.winner
        localHasWinningStructure = localHasWinningStructure || config.localWon

        let loginCycle = mergeStructure(local: local.loginCycle, peer: peer.loginCycle, isPhone: isPhone)
        merged.loginCycle = loginCycle.winner
        localHasWinningStructure = localHasWinningStructure || loginCycle.localWon

        let playerState = mergeStructure(local: local.playerState, peer: peer.playerState, isPhone: isPhone)
        merged.playerState = playerState.winner
        localHasWinningStructure = localHasWinningStructure || playerState.localWon

        return (merged, localHasWinningStructure)
    }
}
