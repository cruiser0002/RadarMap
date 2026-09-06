import Foundation
import CoreLocation

public enum MemberStatus: String, Codable {
    case active
    case downed
    case inactive
}

public enum MemberRole: String, Codable {
    case player
    case leader
}

public struct SquadMember: Identifiable, Codable, Equatable {
    public let id: String
    public var callsign: String
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?
    public var heading: Double         // 0 - 360 degrees
    public var heartRate: Double       // BPM
    public var batteryLevel: Double    // 0.0 - 1.0
    public var lastUpdatedTimestamp: TimeInterval // Epoch time in seconds
    public var sequenceNumber: Int64   // Monotonic packet sequence counter
    public var status: MemberStatus
    public var role: MemberRole
    public var colorHex: String        // Tactical marker color
    public var lastAnimationDuration: TimeInterval // Delta time between packets for translation animation (0.0s for instant stepping)

    // One sample further back than (latitude, longitude, lastUpdatedTimestamp) — the minimum
    // history needed to derive a velocity vector for dead-reckoning extrapolation between real
    // telemetry updates (see DEAD_RECKONING.md and extrapolatedCoordinate(at:) below). Local-only,
    // not part of the server-encoded roster payload.
    public var previousLatitude: Double?
    public var previousLongitude: Double?
    public var previousUpdatedTimestamp: TimeInterval?

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    public init(
        id: String = GameStateManager.generateShortMemberId(),
        callsign: String,
        latitude: Double,
        longitude: Double,
        altitude: Double? = nil,
        heading: Double = 0.0,
        heartRate: Double = AppConstants.Health.defaultRestingHeartRate,
        batteryLevel: Double = 1.0,
        lastUpdatedTimestamp: TimeInterval = Date().timeIntervalSince1970,
        sequenceNumber: Int64 = 0,
        status: MemberStatus = .active,
        role: MemberRole = .player,
        colorHex: String = AppConstants.UI.defaultTacticalColorHex,
        lastAnimationDuration: TimeInterval = 0.0,
        previousLatitude: Double? = nil,
        previousLongitude: Double? = nil,
        previousUpdatedTimestamp: TimeInterval? = nil
    ) {
        self.id = id
        self.callsign = callsign
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.heading = heading
        self.heartRate = heartRate
        self.batteryLevel = batteryLevel
        self.lastUpdatedTimestamp = lastUpdatedTimestamp
        self.sequenceNumber = sequenceNumber
        self.status = status
        self.role = role
        self.colorHex = colorHex
        self.lastAnimationDuration = lastAnimationDuration
        self.previousLatitude = previousLatitude
        self.previousLongitude = previousLongitude
        self.previousUpdatedTimestamp = previousUpdatedTimestamp
    }

    private enum CodingKeys: String, CodingKey {
        case id = "mid"
        case callsign = "csn"
        case role = "rol"
        case latitude, longitude, altitude, heading, heartRate, batteryLevel, lastUpdatedTimestamp, sequenceNumber, status, colorHex
    }

    /// Serializes member metadata for the room roster endpoint (`/r/{roomId}/m`).
    /// Dynamic real-time telemetry (location, heading, heart rate) is purposefully excluded here
    /// and streamed independently over the telemetry endpoint (`/p/{roomId}`).
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(callsign, forKey: .callsign)
        try container.encode(role, forKey: .role)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? GameStateManager.generateShortMemberId()
        callsign = try container.decodeIfPresent(String.self, forKey: .callsign) ?? ""
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude) ?? 0.0
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude) ?? 0.0
        altitude = try container.decodeIfPresent(Double.self, forKey: .altitude)
        heading = try container.decodeIfPresent(Double.self, forKey: .heading) ?? 0.0
        heartRate = try container.decodeIfPresent(Double.self, forKey: .heartRate) ?? AppConstants.Health.defaultRestingHeartRate
        batteryLevel = try container.decodeIfPresent(Double.self, forKey: .batteryLevel) ?? AppConstants.UI.defaultBatteryLevel
        lastUpdatedTimestamp = try container.decodeIfPresent(TimeInterval.self, forKey: .lastUpdatedTimestamp) ?? Date().timeIntervalSince1970
        sequenceNumber = try container.decodeIfPresent(Int64.self, forKey: .sequenceNumber) ?? 0
        status = try container.decodeIfPresent(MemberStatus.self, forKey: .status) ?? .active
        role = try container.decodeIfPresent(MemberRole.self, forKey: .role) ?? .player
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex) ?? AppConstants.UI.defaultTacticalColorHex
        lastAnimationDuration = 0.0
        previousLatitude = nil
        previousLongitude = nil
        previousUpdatedTimestamp = nil
    }

    /// Returns a copy with `id` replaced when it differs from the dictionary key it was stored
    /// under (e.g. a stale/mismatched Firebase path key) — `id` is a `let`, so this reconstructs
    /// rather than mutates. No-op (returns self) when the id already matches.
    public func correctingId(to correctId: String) -> SquadMember {
        guard id != correctId else { return self }
        return SquadMember(
            id: correctId,
            callsign: callsign,
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            heading: heading,
            heartRate: heartRate,
            batteryLevel: batteryLevel,
            lastUpdatedTimestamp: lastUpdatedTimestamp,
            sequenceNumber: sequenceNumber,
            status: status,
            role: role,
            colorHex: colorHex
        )
    }

    // MARK: - Dead Reckoning (remote position extrapolation)

    /// Predicts where this member is *right now*, extrapolating from their last two known
    /// telemetry samples using the same constant-velocity model the sender uses for upload gating
    /// (see DEAD_RECKONING.md). Lets the local map keep a remote member's icon advancing smoothly
    /// between real telemetry downloads instead of freezing at the last received point.
    ///
    /// Returns the raw last-known coordinate (no projection) when there isn't enough history yet,
    /// the interval between samples is degenerate, or the member isn't plausibly still moving
    /// (`.downed` / `.inactive`, or stale).
    public func extrapolatedCoordinate(at referenceTime: TimeInterval) -> CLLocationCoordinate2D {
        guard status == .active, !isStale(asOf: Date(timeIntervalSince1970: referenceTime)) else {
            return coordinate
        }

        guard let previousLatitude, let previousLongitude, let previousUpdatedTimestamp else {
            return coordinate
        }

        let previousCoordinate = CLLocationCoordinate2D(latitude: previousLatitude, longitude: previousLongitude)
        return DeadReckoning.predictedCoordinate(
            sampleA: (previousCoordinate, previousUpdatedTimestamp),
            sampleB: (coordinate, lastUpdatedTimestamp),
            atTime: referenceTime
        ) ?? coordinate
    }
    
    // MARK: - Stale / Inactivity Timeout Configuration
    
    /// Stale timeout multiplier (M). The number of missed update intervals
    /// before a squad member's telemetry is considered stale and rendered gray.
    public static var staleTimeoutMultiplier: Double = AppConstants.Timing.Stale.defaultTimeoutMultiplier
    
    /// Default update interval in seconds when calculating timeout.
    public static var defaultUpdateInterval: TimeInterval = AppConstants.Timing.Stale.defaultUpdateInterval
    
    /// Calculates the stale timeout duration in seconds: M * updateInterval.
    /// E.g. If M = 15 and update interval = 2.0s, timeout is 30.0s.
    public static func staleTimeoutDuration(
        updateInterval: TimeInterval = defaultUpdateInterval,
        multiplier: Double = staleTimeoutMultiplier
    ) -> TimeInterval {
        multiplier * updateInterval
    }
    
    /// Determines whether the member's telemetry is older than the computed stale timeout (M * updateInterval).
    public func isStale(
        updateInterval: TimeInterval = SquadMember.defaultUpdateInterval,
        multiplier: Double = SquadMember.staleTimeoutMultiplier,
        asOf now: Date = Date()
    ) -> Bool {
        let timeout = SquadMember.staleTimeoutDuration(updateInterval: updateInterval, multiplier: multiplier)
        return now.timeIntervalSince1970 - lastUpdatedTimestamp > timeout
    }
    
    /// Determines whether the member's telemetry is older than the default stale timeout.
    public var isStale: Bool {
        isStale(updateInterval: SquadMember.defaultUpdateInterval, multiplier: SquadMember.staleTimeoutMultiplier, asOf: Date())
    }
    
    /// Determines whether the member's telemetry is stale relative to a reference date.
    public func isStale(asOf now: Date) -> Bool {
        isStale(updateInterval: SquadMember.defaultUpdateInterval, multiplier: SquadMember.staleTimeoutMultiplier, asOf: now)
    }
}
