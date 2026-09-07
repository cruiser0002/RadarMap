import Foundation

public struct SquadRoom: Identifiable, Codable, Equatable {
    public let id: String                 // Squad Name (unique identifier)
    public var hostId: String             // Member ID of the squad creator / host
    public var maxCapacity: Int           // 4 for free tier, 12 for Pro unlock
    public var maxTacticalIndicators: Int // Shared cap on enemy+environment indicators (0 free / 20 pro)
    public var expireAt: TimeInterval     // TTL expiration timestamp for Firebase TTL deletion policy
    public var pinHash: String
    public var members: [String: SquadMember] // memberId -> SquadMember
    public var indicators: [String: TacticalIndicator] // indicatorId -> TacticalIndicator (client-model convenience, not wire-encoded — see below)

    public var name: String { id }

    public init(
        id: String,
        hostId: String,
        maxCapacity: Int = AppConstants.Subscription.freeTierMaxCapacity,
        maxTacticalIndicators: Int = AppConstants.Subscription.proTierMaxTacticalIndicators,
        pinHash: String = "",
        expireAt: TimeInterval? = nil,
        members: [String: SquadMember] = [:],
        indicators: [String: TacticalIndicator] = [:]
    ) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.hostId = hostId
        self.maxCapacity = maxCapacity
        self.maxTacticalIndicators = maxTacticalIndicators
        self.pinHash = pinHash
        self.expireAt = expireAt ?? (Date().timeIntervalSince1970 + AppConstants.Timing.Inactivity.ttlDurationSeconds)
        self.members = members
        self.indicators = indicators
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case members = "m"
        case hostId = "hst"
        case maxCapacity = "cap"
        case maxTacticalIndicators = "mti"
        case pinHash = "pin"
        case expireAt = "exp"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(hostId, forKey: .hostId)
        try container.encode(maxCapacity, forKey: .maxCapacity)
        try container.encode(maxTacticalIndicators, forKey: .maxTacticalIndicators)
        try container.encode(expireAt, forKey: .expireAt)
        try container.encode(pinHash, forKey: .pinHash)
        try container.encode(members, forKey: .members)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try container.decodeIfPresent(String.self, forKey: .id) ?? "SQUAD").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        hostId = try container.decodeIfPresent(String.self, forKey: .hostId) ?? "HOST"
        maxCapacity = try container.decodeIfPresent(Int.self, forKey: .maxCapacity) ?? AppConstants.Subscription.freeTierMaxCapacity
        maxTacticalIndicators = try container.decodeIfPresent(Int.self, forKey: .maxTacticalIndicators) ?? AppConstants.Subscription.freeTierMaxTacticalIndicators
        expireAt = try container.decodeIfPresent(TimeInterval.self, forKey: .expireAt)
            ?? (Date().timeIntervalSince1970 + AppConstants.Timing.Inactivity.ttlDurationSeconds)
        pinHash = try container.decodeIfPresent(String.self, forKey: .pinHash) ?? ""
        let rawMembers = try container.decodeIfPresent([String: SquadMember].self, forKey: .members) ?? [:]
        var sanitizedMembers: [String: SquadMember] = [:]
        for (memberKey, memberVal) in rawMembers {
            if memberVal.id != memberKey {
                sanitizedMembers[memberKey] = memberVal.correctingId(to: memberKey)
            } else {
                sanitizedMembers[memberKey] = memberVal
            }
        }
        members = sanitizedMembers
        indicators = [:]
    }

    public var memberCount: Int {
        members.count
    }

    public var isFull: Bool {
        members.count >= maxCapacity
    }

    public var isEmpty: Bool {
        members.isEmpty
    }
}
