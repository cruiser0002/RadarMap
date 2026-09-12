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

    /// Every field is read with `try?`, and members go through `SquadMemberRoster` rather than a
    /// direct `[String: SquadMember]` decode — see SquadMember.swift's doc comment on
    /// `SquadMemberRoster` for why a synthesized dictionary decode is the wrong default here.
    /// A room read from RTDB should never fail outright just because one field or one member
    /// doesn't match this client's exact expectations at the instant of the read.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = ((try? container.decode(String.self, forKey: .id)) ?? "SQUAD").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        hostId = (try? container.decode(String.self, forKey: .hostId)) ?? "HOST"
        maxCapacity = (try? container.decode(Int.self, forKey: .maxCapacity)) ?? AppConstants.Subscription.freeTierMaxCapacity
        maxTacticalIndicators = (try? container.decode(Int.self, forKey: .maxTacticalIndicators)) ?? AppConstants.Subscription.freeTierMaxTacticalIndicators
        expireAt = (try? container.decode(TimeInterval.self, forKey: .expireAt))
            ?? (Date().timeIntervalSince1970 + AppConstants.Timing.Inactivity.ttlDurationSeconds)
        pinHash = (try? container.decode(String.self, forKey: .pinHash)) ?? ""
        let rawMembers = (try? container.decode(SquadMemberRoster.self, forKey: .members))?.members ?? [:]
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

    public var isEmpty: Bool {
        members.isEmpty
    }
}
