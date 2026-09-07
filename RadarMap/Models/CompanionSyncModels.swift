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
    public var isPro: Bool
    public var isUploadHeartRateEnabled: Bool
    public var isUploadLocationEnabled: Bool
    public var configTs: TimeInterval

    public init(
        callsign: String = "",
        roomName: String = "",
        pin: String = "",
        databaseURL: String = "",
        theme: String = "Green",
        isPro: Bool = false,
        isUploadHeartRateEnabled: Bool = true,
        isUploadLocationEnabled: Bool = true,
        configTs: TimeInterval = 0
    ) {
        self.callsign = callsign
        self.roomName = roomName
        self.pin = pin
        self.databaseURL = databaseURL
        self.theme = theme
        self.isPro = isPro
        self.isUploadHeartRateEnabled = isUploadHeartRateEnabled
        self.isUploadLocationEnabled = isUploadLocationEnabled
        self.configTs = configTs
    }

    enum CodingKeys: String, CodingKey {
        case callsign, roomName, pin, databaseURL, theme, isPro
        case isUploadHeartRateEnabled, isUploadLocationEnabled
        case configTs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.callsign = try container.decodeIfPresent(String.self, forKey: .callsign) ?? ""
        self.roomName = try container.decodeIfPresent(String.self, forKey: .roomName) ?? ""
        self.pin = try container.decodeIfPresent(String.self, forKey: .pin) ?? ""
        self.databaseURL = try container.decodeIfPresent(String.self, forKey: .databaseURL) ?? ""
        self.theme = try container.decodeIfPresent(String.self, forKey: .theme) ?? "Green"
        self.isPro = try container.decodeIfPresent(Bool.self, forKey: .isPro) ?? false
        self.isUploadHeartRateEnabled = try container.decodeIfPresent(Bool.self, forKey: .isUploadHeartRateEnabled) ?? true
        self.isUploadLocationEnabled = try container.decodeIfPresent(Bool.self, forKey: .isUploadLocationEnabled) ?? true
        self.configTs = try container.decodeIfPresent(TimeInterval.self, forKey: .configTs) ?? 0.0
    }

    public func isEquivalent(to other: ConfigSnapshot) -> Bool {
        return callsign == other.callsign &&
               roomName == other.roomName &&
               pin == other.pin &&
               databaseURL == other.databaseURL &&
               theme == other.theme &&
               isPro == other.isPro &&
               isUploadHeartRateEnabled == other.isUploadHeartRateEnabled &&
               isUploadLocationEnabled == other.isUploadLocationEnabled &&
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

public struct MembershipSnapshot: Codable, Equatable {
    public var membersJson: String
    public var memberTs: TimeInterval
    
    public init(membersJson: String = "[]", memberTs: TimeInterval = 0) {
        self.membersJson = membersJson
        self.memberTs = memberTs
    }
    
    public func isEquivalent(to other: MembershipSnapshot) -> Bool {
        return membersJson == other.membersJson && memberTs == other.memberTs
    }
}

public struct TacticalSnapshot: Codable, Equatable {
    public var tacticalJson: String
    public var tacticalTs: TimeInterval
    
    public init(tacticalJson: String = "[]", tacticalTs: TimeInterval = 0) {
        self.tacticalJson = tacticalJson
        self.tacticalTs = tacticalTs
    }
    
    public func isEquivalent(to other: TacticalSnapshot) -> Bool {
        return tacticalJson == other.tacticalJson && tacticalTs == other.tacticalTs
    }
}

public struct PlayerStateSnapshot: Codable, Equatable {
    public var isDead: Bool
    public var isDeadTs: TimeInterval
    
    public init(isDead: Bool = false, isDeadTs: TimeInterval = 0) {
        self.isDead = isDead
        self.isDeadTs = isDeadTs
    }
    
    public func isEquivalent(to other: PlayerStateSnapshot) -> Bool {
        return isDead == other.isDead && isDeadTs == other.isDeadTs
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



// MARK: - Directional Low-Speed Snapshots

public struct LowSpeedSnapshot: Codable, Equatable {
    public var syncTs: TimeInterval
    public var config: ConfigSnapshot
    public var loginCycle: LoginCycleSnapshot
    public var membership: MembershipSnapshot
    public var tactical: TacticalSnapshot
    public var playerState: PlayerStateSnapshot
    
    public init(
        syncTs: TimeInterval = 0,
        config: ConfigSnapshot = ConfigSnapshot(),
        loginCycle: LoginCycleSnapshot = LoginCycleSnapshot(),
        membership: MembershipSnapshot = MembershipSnapshot(),
        tactical: TacticalSnapshot = TacticalSnapshot(),
        playerState: PlayerStateSnapshot = PlayerStateSnapshot()
    ) {
        self.syncTs = syncTs
        self.config = config
        self.loginCycle = loginCycle
        self.membership = membership
        self.tactical = tactical
        self.playerState = playerState
    }
    
    /// Checks whether all domain-state structures and their timestamps are equivalent.
    /// Deliberately ignores syncTs.
    public func isDomainEquivalent(to other: LowSpeedSnapshot) -> Bool {
        return config.isEquivalent(to: other.config) &&
               loginCycle.isEquivalent(to: other.loginCycle) &&
               membership.isEquivalent(to: other.membership) &&
               tactical.isEquivalent(to: other.tactical) &&
               playerState.isEquivalent(to: other.playerState)
    }
}

// MARK: - WCSession Application Context Envelope

public struct ApplicationContextEnvelope: Codable, Equatable {
    public var p2wHS: PhoneToWatchHighSpeed?
    public var w2pHS: WatchToPhoneHighSpeed?
    public var p2wLS: LowSpeedSnapshot?
    public var w2pLS: LowSpeedSnapshot?
    
    public init(
        p2wHS: PhoneToWatchHighSpeed? = nil,
        w2pHS: WatchToPhoneHighSpeed? = nil,
        p2wLS: LowSpeedSnapshot? = nil,
        w2pLS: LowSpeedSnapshot? = nil
    ) {
        self.p2wHS = p2wHS
        self.w2pHS = w2pHS
        self.p2wLS = p2wLS
        self.w2pLS = w2pLS
    }
    
    enum CodingKeys: String, CodingKey {
        case p2wHS = "p2w_hs"
        case w2pHS = "w2p_hs"
        case p2wLS = "p2w_ls"
        case w2pLS = "w2p_ls"
    }
}

// MARK: - Conflict Resolution & Winner Selection Engine

public enum DeviceRole {
    case phone
    case watch
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
    
    /// Merges an incoming counterpart LowSpeedSnapshot into the local LowSpeedSnapshot.
    /// Returns the updated local snapshot and whether the local device advertises any structure that wins against peer.
    public static func merge(
        local: LowSpeedSnapshot,
        peer: LowSpeedSnapshot,
        localDevice: DeviceRole
    ) -> (mergedLocal: LowSpeedSnapshot, localHasWinningStructure: Bool) {
        var merged = local
        var localHasWinningStructure = false
        
        let isPhone = (localDevice == .phone)
        
        // 1. Config merge
        let phoneConfig = isPhone ? local.config : peer.config
        let watchConfig = isPhone ? peer.config : local.config
        let configRes = resolveWinner(
            phoneValue: phoneConfig,
            phoneTs: phoneConfig.configTs,
            watchValue: watchConfig,
            watchTs: watchConfig.configTs
        )
        if isPhone {
            if !local.config.isEquivalent(to: peer.config) && configRes.phoneWon {
                localHasWinningStructure = true
            }
            merged.config = configRes.winnerValue
        } else {
            if !local.config.isEquivalent(to: peer.config) && !configRes.phoneWon {
                localHasWinningStructure = true
            }
            merged.config = configRes.winnerValue
        }
        
        // 2. Login Cycle merge
        let phoneCycle = isPhone ? local.loginCycle : peer.loginCycle
        let watchCycle = isPhone ? peer.loginCycle : local.loginCycle
        let cycleRes = resolveWinner(
            phoneValue: phoneCycle,
            phoneTs: phoneCycle.loginCycleTs,
            watchValue: watchCycle,
            watchTs: watchCycle.loginCycleTs
        )
        if isPhone {
            if !local.loginCycle.isEquivalent(to: peer.loginCycle) && cycleRes.phoneWon {
                localHasWinningStructure = true
            }
            merged.loginCycle = cycleRes.winnerValue
        } else {
            if !local.loginCycle.isEquivalent(to: peer.loginCycle) && !cycleRes.phoneWon {
                localHasWinningStructure = true
            }
            merged.loginCycle = cycleRes.winnerValue
        }
        
        // 3. Membership merge
        let phoneMem = isPhone ? local.membership : peer.membership
        let watchMem = isPhone ? peer.membership : local.membership
        let memRes = resolveWinner(
            phoneValue: phoneMem,
            phoneTs: phoneMem.memberTs,
            watchValue: watchMem,
            watchTs: watchMem.memberTs
        )
        if isPhone {
            if !local.membership.isEquivalent(to: peer.membership) && memRes.phoneWon {
                localHasWinningStructure = true
            }
            merged.membership = memRes.winnerValue
        } else {
            if !local.membership.isEquivalent(to: peer.membership) && !memRes.phoneWon {
                localHasWinningStructure = true
            }
            merged.membership = memRes.winnerValue
        }
        
        // 4. Tactical merge
        let phoneTac = isPhone ? local.tactical : peer.tactical
        let watchTac = isPhone ? peer.tactical : local.tactical
        let tacRes = resolveWinner(
            phoneValue: phoneTac,
            phoneTs: phoneTac.tacticalTs,
            watchValue: watchTac,
            watchTs: watchTac.tacticalTs
        )
        if isPhone {
            if !local.tactical.isEquivalent(to: peer.tactical) && tacRes.phoneWon {
                localHasWinningStructure = true
            }
            merged.tactical = tacRes.winnerValue
        } else {
            if !local.tactical.isEquivalent(to: peer.tactical) && !tacRes.phoneWon {
                localHasWinningStructure = true
            }
            merged.tactical = tacRes.winnerValue
        }
        
        // 5. Player State merge
        let phonePlayer = isPhone ? local.playerState : peer.playerState
        let watchPlayer = isPhone ? peer.playerState : local.playerState
        let playerRes = resolveWinner(
            phoneValue: phonePlayer,
            phoneTs: phonePlayer.isDeadTs,
            watchValue: watchPlayer,
            watchTs: watchPlayer.isDeadTs
        )
        if isPhone {
            if !local.playerState.isEquivalent(to: peer.playerState) && playerRes.phoneWon {
                localHasWinningStructure = true
            }
            merged.playerState = playerRes.winnerValue
        } else {
            if !local.playerState.isEquivalent(to: peer.playerState) && !playerRes.phoneWon {
                localHasWinningStructure = true
            }
            merged.playerState = playerRes.winnerValue
        }
        
        return (merged, localHasWinningStructure)
    }
}
