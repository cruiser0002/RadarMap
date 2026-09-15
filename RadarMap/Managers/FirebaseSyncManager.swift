import Foundation
import Combine
import CryptoKit
import CoreLocation

public enum PacketRejectionReason: String, Equatable {
    case outOfOrderSequence = "Out-of-order sequence number"
    case staleTimestamp = "Stale timestamp older than latest received"
}

public struct RejectionEvent: Identifiable, Equatable {
    public let id = UUID()
    public let memberId: String
    public let packetTimestamp: TimeInterval
    public let reason: PacketRejectionReason
    public let rejectedAt: Date = Date()
}

public enum FirebaseSyncError: LocalizedError, Equatable {
    case roomNotFound
    case roomAlreadyExists
    case duplicateCallsign
    case emptyRoomName
    case emptyCallsign
    case roomFull
    case incorrectPin
    case incorrectPassword
    case unauthorized
    case networkError(String)
    case invalidDatabaseURL

    public var errorDescription: String? {
        switch self {
        case .roomNotFound:
            return "Room+PIN combination incorrect"
        case .roomAlreadyExists:
            return "Room already exists"
        case .duplicateCallsign:
            return "Callsign already taken in this room"
        case .emptyRoomName:
            return "Room name cannot be empty"
        case .emptyCallsign:
            return "Callsign cannot be empty"
        case .roomFull:
            return "Room has reached maximum capacity"
        case .incorrectPin, .incorrectPassword:
            return "Invalid PIN / Password"
        case .unauthorized:
            return "Unauthorized access"
        case .networkError(let msg):
            return "Network Error: \(msg)"
        case .invalidDatabaseURL:
            return "Custom database URL is not a valid https:// address"
        }
    }
}

public final class FirebaseSyncManager: NSObject, ObservableObject {
    /// The Room/Tactical `LS_data` instances this manager's Observer pipelines write into
    /// directly — see the implementation plan §1/§3. `Set()` (`roomSet`/`tacticalSet`) is the
    /// only door into those stores; nothing in this class keeps its own independent roster/
    /// indicator cache anymore (that was `activeRoom`, now deleted — see CLAUDE.md rule 3 and
    /// the `fetchMemberDetails` incident this whole refactor traces back to). One-directional
    /// dependency only: `WatchConnectivityManager` never depends back on this class (see
    /// docs/COMPANION_DATA_SYNC_MODEL.md's "Zero Web/Firebase Coupling" invariant) — wired once
    /// by `GameStateManager.init`. Strong, not `weak`: `WatchConnectivityManager` holds no
    /// reference back to this class, so there is no retain cycle to guard against, and a `weak`
    /// reference here would leave a standalone `FirebaseSyncManager` (no owning
    /// `GameStateManager` keeping the peer instance alive, e.g. in tests) silently unable to
    /// reach Room/Tactical the moment nothing else retained the `WatchConnectivityManager` it was
    /// given.
    public var watchConnectivityManager: WatchConnectivityManager?

    /// The room id this manager's RTDB calls are currently scoped to — plain local bookkeeping
    /// for path construction (mirrors `attachedTelemetryRoomId`'s role for listener attachment),
    /// not a second copy of Room's actual content. The content itself lives only in
    /// `watchConnectivityManager.localRoom`.
    public private(set) var currentRoomId: String?

    @Published public var isConnected: Bool = false
    @Published public var syncLatencyMs: Double = 0.0
    @Published public var totalPacketsProcessed: Int = 0
    @Published public var totalPacketsRejected: Int = 0
    @Published public var latestRejection: RejectionEvent?
    @Published public var errorMessage: String?

    /// Not read outside this class — `GameStateManager.isWristActive` is the canonical, externally
    /// read flag (see its doc comment for why). This private copy exists only so this class's own
    /// wake-burst safety-net check below can compare against its previous value.
    private var isWristActive: Bool = true

    public var onRemoteTelemetryPacketsReceived: (([TelemetryPacket]) -> Void)?

    /// Symmetric key used to encrypt THIS device's own outbound telemetry/tactical writes, or nil
    /// when encryption is disabled (`GameStateManager.isEncryptionEnabled == false`, synced
    /// phone<->watch via `ConfigSnapshot.isEncryptionEnabled`) or no room context has been
    /// established yet. The toggle only ever governs this — what a device chooses to send — never
    /// what it can read. Set via `setEncryptionContext(pin:roomId:isEncryptionEnabled:)`.
    private(set) var activeTelemetryKey: SymmetricKey?

    /// Symmetric key used to decrypt INCOMING telemetry/tactical payloads, derived from the room's
    /// pin/id alone. Deliberately not gated on the encryption toggle: a payload's own format
    /// (plaintext array/dict vs. ciphertext string) already says whether it needs decrypting, so
    /// this key must always be available whenever the room context is known — otherwise a device
    /// with the toggle off could never read a payload some other device (with the toggle on)
    /// encrypted, silently dropping it. Set via `setEncryptionContext(pin:roomId:isEncryptionEnabled:)`.
    private(set) var incomingDecryptionKey: SymmetricKey?

    /// Establishes (or clears) the active room's telemetry/tactical encryption context. Call as
    /// soon as both the room's pin and id are known — on host create, join, and reconnect.
    /// `isEncryptionEnabled` is the caller's current, phone/watch-synced setting
    /// (`GameStateManager.isEncryptionEnabled`) — this manager has no access to that synced state
    /// itself and takes it as a parameter instead. See docs/CLOUD_DATA_MANAGEMENT.md §5.E.
    public func setEncryptionContext(pin: String, roomId: String, isEncryptionEnabled: Bool) {
        guard !pin.isEmpty, !roomId.isEmpty else {
            activeTelemetryKey = nil
            incomingDecryptionKey = nil
            return
        }
        let key = FirebaseSyncManager.deriveTelemetryKey(pin: pin, roomId: roomId)
        incomingDecryptionKey = key
        activeTelemetryKey = isEncryptionEnabled ? key : nil
    }

    public let networkQualityMonitor = NetworkQualityMonitor()
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Upload Scheduling & Observability Metrics

    public struct UploadSchedulerMetrics: Equatable {
        public var tacticalWritesSubmitted: Int = 0
        public var tacticalWritesCompleted: Int = 0
        public var tacticalWritesFailed: Int = 0
        public var telemetryWritesSubmitted: Int = 0
        public var telemetryWritesCompleted: Int = 0
        public var telemetryWritesFailed: Int = 0
        public var telemetrySamplesRetainedOffline: Int = 0
        public var telemetrySamplesReplacedCoalesced: Int = 0
        public var reconnectTriggeredTelemetryFlushes: Int = 0
        public var rtdbConnectionTransitions: Int = 0
    }

    public struct PendingTelemetry: Equatable {
        public let roomId: String
        public let memberId: String
        public let packet: TelemetryPacket
        public let payload: [Any]

        public static func == (lhs: PendingTelemetry, rhs: PendingTelemetry) -> Bool {
            return lhs.roomId == rhs.roomId &&
                   lhs.memberId == rhs.memberId &&
                   lhs.packet == rhs.packet
        }
    }

    private let telemetrySchedulerQueue = DispatchQueue(label: "RadarMap.TelemetrySchedulerQueue")
    private var _pendingTelemetry: PendingTelemetry?
    private var _uploadMetrics = UploadSchedulerMetrics()
    private var _isRTDBConnected: Bool = true

    public var isRTDBConnected: Bool {
        telemetrySchedulerQueue.sync { _isRTDBConnected }
    }

    public var uploadMetrics: UploadSchedulerMetrics {
        telemetrySchedulerQueue.sync { _uploadMetrics }
    }

    public func getPendingTelemetry() -> PendingTelemetry? {
        telemetrySchedulerQueue.sync { _pendingTelemetry }
    }

    public func resetUploadMetrics() {
        telemetrySchedulerQueue.sync {
            _uploadMetrics = UploadSchedulerMetrics()
        }
    }

    public func setRTDBConnected(_ connected: Bool) {
        telemetrySchedulerQueue.async { [weak self] in
            guard let self = self else { return }
            let wasConnected = self._isRTDBConnected
            self._isRTDBConnected = connected
            if !wasConnected && connected {
                self._uploadMetrics.rtdbConnectionTransitions += 1
                #if DEBUG
                print("[FirebaseSyncManager] RTDB connection transition: disconnected -> connected. Triggering pending telemetry flush.")
                #endif
                self.flushPendingTelemetryLocked()
            } else if wasConnected && !connected {
                self._uploadMetrics.rtdbConnectionTransitions += 1
                #if DEBUG
                print("[FirebaseSyncManager] RTDB connection transition: connected -> disconnected.")
                #endif
            }
        }
    }

    // Database endpoint configuration
    public var databaseURL: String = AppConstants.Network.defaultDatabaseURL

    // Local member ID for bandwidth saving / avoiding overwriting live telemetry with server data
    public var localMemberId: String? = nil

    // Per-member telemetry state tracking for Late Packet Rejection
    private var memberLatestTimestamps: [String: TimeInterval] = [:]
    private var memberLatestSequences: [String: Int64] = [:]

    // MARK: - Realtime Database Transport
    // See RTDBTransport.swift and CLOUD_DATA_MANAGEMENT.md §5.B/§5.C: production talks to the
    // real FirebaseDatabase SDK (one shared, persistent, multiplexed connection); tests inject a
    // mock conforming to the same protocol.
    public lazy var transport: RTDBTransport = FirebaseRTDBTransport(databaseURLProvider: { [weak self] in
        self?.databaseURL ?? AppConstants.Network.defaultDatabaseURL
    })

    // Gated realtime listener handles for the three downstream channels. Attached by
    // startTelemetryPolling(roomId:) / detached by stopTelemetryPolling() — the same gated
    // entry points GameStateManager already calls based on app_active / active_until lease
    // state (see evaluateListenerGate), so no caller changes were needed.
    private var telemetryChildAddedHandle: RTDBObserverHandle?
    private var telemetryChildChangedHandle: RTDBObserverHandle?
    private var telemetryChildRemovedHandle: RTDBObserverHandle?
    private var tacticalValueHandle: RTDBObserverHandle?
    private var roomValueHandle: RTDBObserverHandle?
    /// Debug-only: counts `roomMembersPath` `.value` listener fires, to see how listener churn
    /// scales with room player count (temporary instrumentation, remove once diagnosed).
    private var membersValueFireCount: Int = 0
    public private(set) var attachedTelemetryRoomId: String?

    private static let telemetryMetadataKeys: Set<String> = ["exp"]

    override public init() {
        super.init()

        _isRTDBConnected = networkQualityMonitor.isConnected
        networkQualityMonitor.$isConnected
            .sink { [weak self] connected in
                self?.setRTDBConnected(connected)
            }
            .store(in: &cancellables)
    }

    // MARK: - Constant Bandwidth Rate Adaptation

    /// The maximum number of concurrent players supported at peak 1.0 Hz before throttling
    /// is engaged to keep theoretical aggregate bandwidth constant.
    public static let constantBandwidthPlayerThreshold: Int = AppConstants.Timing.ConstantBandwidth.playerThreshold

    /// The baseline maximum update frequency (in Hz).
    public static let baselineMaxUpdateRateHz: Double = AppConstants.Timing.ConstantBandwidth.baselineMaxUpdateRateHz

    /// Solves for the maximum update rate (in Hz) given the active player count.
    public static func solveMaxUpdateRateHz(
        playerCount: Int,
        playerThreshold: Int = constantBandwidthPlayerThreshold,
        baselineRateHz: Double = baselineMaxUpdateRateHz
    ) -> Double {
        return AppConstants.Timing.ConstantBandwidth.maxUpdateRateHz(forPlayerCount: playerCount)
    }

    /// Solves for the update interval (in seconds) corresponding to `solveMaxUpdateRateHz`.
    public static func solveUpdateInterval(
        playerCount: Int,
        playerThreshold: Int = constantBandwidthPlayerThreshold,
        baselineRateHz: Double = baselineMaxUpdateRateHz
    ) -> TimeInterval {
        return AppConstants.Timing.ConstantBandwidth.updateInterval(forPlayerCount: playerCount)
    }


    // MARK: - PIN / Password Hashing Utility

    public static func hashPin(_ pin: String, salt: String) -> String {
        let trimmed = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        let combined = "\(salt):\(trimmed)"
        let digest = SHA256.hash(data: Data(combined.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    public static func hashPassword(_ pin: String, salt: String) -> String {
        return hashPin(pin, salt: salt)
    }

    /// Derives the AES-256 key used to encrypt telemetry/tactical compact arrays for a room.
    /// Domain-separated from `hashPin` (bare "salt:pin") and `deriveRoomPadding` ("roompad:...")
    /// via the "telemetrykey:" prefix, so this key is never equal to or derivable from either of
    /// those two publicly-stored hashes. See docs/CLOUD_DATA_MANAGEMENT.md §5.E.
    public static func deriveTelemetryKey(pin: String, roomId: String) -> SymmetricKey {
        let combined = "telemetrykey:\(roomId):\(pin)"
        let digest = SHA256.hash(data: Data(combined.utf8))
        return SymmetricKey(data: Data(digest))
    }

    /// Plain Crockford Base32 (32 symbols, excludes `0`/`O`, `1`/`I`/`L` for readability) — the
    /// one alphabet shared by every SHA256-digest-to-id derivation in the app (room-id padding,
    /// member ids, indicator ids). Defined once here so a future alphabet change can't be applied
    /// to one derivation and missed on another.
    public static let crockfordAlphabet: [Character] = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")

    /// Maps the first `length` bytes of a SHA256 digest onto `crockfordAlphabet` — the shared
    /// tail end of `deriveRoomPadding` and `GameStateManager.deriveMemberId`, which differ only
    /// in their domain-separation prefix and digest input.
    public static func crockfordEncode(digest: SHA256Digest, length: Int) -> String {
        String(Array(digest).prefix(length).map { crockfordAlphabet[Int($0) % crockfordAlphabet.count] })
    }

    /// Derives a deterministic room-id padding suffix from (name, PIN), domain-separated from
    /// `hashPin`'s own combined-string format via the "roompad:" prefix so the two derivations
    /// never share identical input despite hashing the same PIN. See CLOUD_DATA_MANAGEMENT.md.
    public static func deriveRoomPadding(pin: String, name: String, length: Int? = nil) -> String {
        let padLength = length ?? max(0, AppConstants.UI.maxRoomNameLength - name.count)
        let combined = "roompad:\(name):\(pin)"
        return crockfordEncode(digest: SHA256.hash(data: Data(combined.utf8)), length: padLength)
    }

    /// The single derivation of a room's full Firebase id from its (already-sanitized) plain
    /// name and PIN. Every caller that owns a plain room name — hosting, joining, and a
    /// companion device adopting a peer-relayed name — must go through this one function rather
    /// than inlining `name + deriveRoomPadding(...)` themselves, so the id (and everything salted
    /// from it: `pinHash`, `deriveTelemetryKey`) can never drift between call sites.
    public static func deriveRoomId(name: String, pin: String) -> String {
        name + deriveRoomPadding(pin: pin, name: name)
    }

    // MARK: - Late Packet Rejection Engine

    /// Checks packet freshness and updates sequence / timestamp tracking.
    /// Returns true if valid, false if rejected.
    private func checkAndTrackPacketFreshness(_ packet: TelemetryPacket) -> Bool {
        // Check 1: Monotonic Sequence Number check (when present)
        if packet.sequenceNumber > 0, let lastSeq = memberLatestSequences[packet.memberId], lastSeq > 0, packet.sequenceNumber <= lastSeq {
            recordRejection(memberId: packet.memberId, timestamp: packet.timestamp, reason: .outOfOrderSequence)
            return false
        }

        // Check 2: Timestamp check against latest processed timestamp for this member
        if let lastTimestamp = memberLatestTimestamps[packet.memberId], packet.timestamp <= lastTimestamp {
            recordRejection(memberId: packet.memberId, timestamp: packet.timestamp, reason: .staleTimestamp)
            return false
        }

        // Packet is valid and accepted! Update tracking state.
        if packet.sequenceNumber > 0 {
            memberLatestSequences[packet.memberId] = packet.sequenceNumber
        }
        memberLatestTimestamps[packet.memberId] = packet.timestamp
        return true
    }

    /// Validates whether an incoming telemetry packet is fresh or should be rejected. On success,
    /// forwards it to `onRemoteTelemetryPacketsReceived` — this is the sole path a remote
    /// player's position reaches `GameStateManager`'s `persistentRemoteTelemetry` ("w2p
    /// Telemetry" in the architecture diagram). Deliberately does not write into any room/roster
    /// structure — Telemetry and Room are independent memory elements with independent single
    /// writers (see the implementation plan §3).
    @discardableResult
    public func validateAndProcessPacket(_ packet: TelemetryPacket) -> Bool {
        guard checkAndTrackPacketFreshness(packet) else { return false }

        let apply = { [weak self] in
            guard let self = self else { return }
            self.totalPacketsProcessed += 1
            self.onRemoteTelemetryPacketsReceived?([packet])
        }

        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
        return true
    }

    /// Validates and forwards a batch of telemetry packets. Also the entry point for
    /// WCSession-relayed telemetry (a device without its own `/p/{roomId}` listener attached,
    /// e.g. the Phone while the Watch holds network ownership).
    @discardableResult
    public func validateAndProcessPackets(_ packets: [TelemetryPacket]) -> Int {
        guard !packets.isEmpty else { return 0 }

        var acceptedPackets: [TelemetryPacket] = []
        for packet in packets {
            if checkAndTrackPacketFreshness(packet) {
                acceptedPackets.append(packet)
            }
        }

        guard !acceptedPackets.isEmpty else { return 0 }

        let apply = { [weak self] in
            guard let self = self else { return }
            self.totalPacketsProcessed += acceptedPackets.count
            self.onRemoteTelemetryPacketsReceived?(acceptedPackets)
        }

        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }

        return acceptedPackets.count
    }

    private func recordRejection(memberId: String, timestamp: TimeInterval, reason: PacketRejectionReason) {
        let event = RejectionEvent(memberId: memberId, packetTimestamp: timestamp, reason: reason)
        if Thread.isMainThread {
            totalPacketsRejected += 1
            self.latestRejection = event
        } else {
            DispatchQueue.main.async {
                self.totalPacketsRejected += 1
                self.latestRejection = event
            }
        }
    }

    /// Calculates the forward geodesic bearing / Course Over Ground (in degrees 0 - 360) from coordinate 1 to coordinate 2.
    public static func calculateBearing(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> Double {
        let lat1 = start.latitude * AppConstants.Location.degreesToRadiansFactor
        let lon1 = start.longitude * AppConstants.Location.degreesToRadiansFactor
        let lat2 = end.latitude * AppConstants.Location.degreesToRadiansFactor
        let lon2 = end.longitude * AppConstants.Location.degreesToRadiansFactor

        let dLon = lon2 - lon1
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let radiansBearing = atan2(y, x)

        let degrees = radiansBearing * AppConstants.Location.radiansToDegreesFactor
        return (degrees + AppConstants.Location.fullCircleDegrees).truncatingRemainder(dividingBy: AppConstants.Location.fullCircleDegrees)
    }

    // MARK: - Telemetry Dispatch

    public func sendTelemetryPacket(_ packet: TelemetryPacket) {
        // Local packet is always fresh — update tracking state directly (no room/roster write:
        // the local player's own display state is sourced straight from GPS by "local player
        // management" in GameStateManager, never round-tripped through Firebase).
        let apply = { [weak self] in
            guard let self = self else { return }
            self.totalPacketsProcessed += 1
            if packet.sequenceNumber > 0 {
                self.memberLatestSequences[packet.memberId] = packet.sequenceNumber
            }
            self.memberLatestTimestamps[packet.memberId] = packet.timestamp
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }

        let payload = packet.toCompactArray()

        telemetrySchedulerQueue.async { [weak self] in
            guard let self = self else { return }

            if self._isRTDBConnected {
                self.executeTelemetryWrite(
                    roomId: packet.roomId,
                    memberId: packet.memberId,
                    packet: packet,
                    payload: payload
                )
            } else {
                // Offline: retain latest only, coalesce/drop older
                if self._pendingTelemetry == nil {
                    self._uploadMetrics.telemetrySamplesRetainedOffline += 1
                    #if DEBUG
                    print("[FirebaseSyncManager] Offline: Retained initial pending telemetry for \(packet.memberId) in \(packet.roomId).")
                    #endif
                } else {
                    self._uploadMetrics.telemetrySamplesReplacedCoalesced += 1
                    #if DEBUG
                    print("[FirebaseSyncManager] Offline: Coalesced/replaced pending telemetry for \(packet.memberId).")
                    #endif
                }
                self._pendingTelemetry = PendingTelemetry(
                    roomId: packet.roomId,
                    memberId: packet.memberId,
                    packet: packet,
                    payload: payload
                )
            }
        }
    }

    // NOTE: per CLOUD_DATA_MANAGEMENT.md §5.C's critical caveat — the SDK's own offline write
    // queue replays every setValue call issued while offline, in order; it does NOT collapse
    // repeated writes to the same path down to the latest one. The app-level single-slot
    // PendingTelemetry coalescing above (and the isReconnectFlush-gated single write below) is
    // what implements Latest-Only / Drop-Old; this call is a drop-in transport swap at the single
    // flush call site, not a reason to route telemetry through the SDK's default offline queueing.
    private func executeTelemetryWrite(roomId: String, memberId: String, packet: TelemetryPacket, payload: [Any], isReconnectFlush: Bool = false) {
        _uploadMetrics.telemetryWritesSubmitted += 1

        let wireValue: Any
        if let key = activeTelemetryKey, let encrypted = try? CompactArrayCipher.encrypt(payload, key: key) {
            wireValue = encrypted
        } else {
            wireValue = payload
        }

        let startTime = Date()
        transport.setValue(wireValue, at: telemetryMemberPath(roomId: roomId, memberId: memberId)) { [weak self] isSuccess in
            guard let self = self else { return }

            self.telemetrySchedulerQueue.async {
                if isSuccess {
                    self._uploadMetrics.telemetryWritesCompleted += 1
                    if isReconnectFlush {
                        // Clear pending slot only if it hasn't been replaced by a newer packet during transmission
                        if self._pendingTelemetry?.packet == packet {
                            self._pendingTelemetry = nil
                        }
                    }
                    let latency = Date().timeIntervalSince(startTime) * AppConstants.Timing.millisecondsPerSecond
                    DispatchQueue.main.async {
                        self.syncLatencyMs = latency
                        self.networkQualityMonitor.recordLatencySample(latency)
                    }
                } else {
                    self._uploadMetrics.telemetryWritesFailed += 1
                    if isReconnectFlush {
                        #if DEBUG
                        print("[FirebaseSyncManager] Reconnect telemetry write failed. Retaining latest pending sample.")
                        #endif
                    }
                }
            }
        }
    }

    private func flushPendingTelemetryLocked() {
        guard let pending = _pendingTelemetry else { return }
        _uploadMetrics.reconnectTriggeredTelemetryFlushes += 1
        #if DEBUG
        print("[FirebaseSyncManager] Executing reconnect telemetry write to /telemetry/\(pending.roomId)/\(pending.memberId)")
        #endif
        executeTelemetryWrite(
            roomId: pending.roomId,
            memberId: pending.memberId,
            packet: pending.packet,
            payload: pending.payload,
            isReconnectFlush: true
        )
    }

    // MARK: - Room -> RoomSnapshot publishing

    /// Converts a server `SquadRoom` into the synced `RoomSnapshot` and publishes it via
    /// `Set()` — the only way any Observer pipeline or room-lifecycle call in this class writes
    /// into the shared Room store. Members are sorted by id for deterministic `Equatable`
    /// comparison (RoomSnapshot.members is an ordered array, not a dictionary — see
    /// CompanionSyncModels.swift). Position/heading/heartRate fields are deliberately not
    /// carried into Room — Room is the roster/identity domain; live position is Telemetry's
    /// (`w2p Telemetry`, `GameStateManager.persistentRemoteTelemetry`), a fully independent
    /// memory element with its own single writer.
    private func publishRoom(_ room: SquadRoom) {
        currentRoomId = room.id
        let members = room.members.values
            .map { SquadMember(id: $0.id, callsign: $0.callsign, latitude: 0, longitude: 0, role: $0.role) }
            .sorted { $0.id < $1.id }
        watchConnectivityManager?.roomSet(RoomSnapshot(
            members: members,
            hostId: room.hostId,
            roomId: room.id,
            pinHash: room.pinHash,
            maxCapacity: room.maxCapacity,
            maxTacticalIndicators: room.maxTacticalIndicators
        ))
    }

    // MARK: - Room Management

    public func createRoom(_ room: SquadRoom, completion: ((Result<SquadRoom, FirebaseSyncError>) -> Void)? = nil) {
        let cleanId = room.id.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cleanId.isEmpty {
            let err = FirebaseSyncError.emptyRoomName
            DispatchQueue.main.async {
                self.errorMessage = err.localizedDescription
                completion?(.failure(err))
            }
            return
        }

        // Validate all member callsigns in room
        for (_, member) in room.members {
            let cleanCallsign = member.callsign.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanCallsign.isEmpty {
                let err = FirebaseSyncError.emptyCallsign
                DispatchQueue.main.async {
                    self.errorMessage = err.localizedDescription
                    completion?(.failure(err))
                }
                return
            }
        }

        // Validate callsign uniqueness within the room (only within this room)
        var seenCallsigns = Set<String>()
        for member in room.members.values {
            let callsignUpper = member.callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if seenCallsigns.contains(callsignUpper) {
                let err = FirebaseSyncError.duplicateCallsign
                DispatchQueue.main.async {
                    self.errorMessage = err.localizedDescription
                    completion?(.failure(err))
                }
                return
            }
            seenCallsigns.insert(callsignUpper)
        }

        // 1. Check if room already exists on server
        transport.getValue(at: roomPath(roomId: cleanId)) { [weak self] value in
            guard let self = self else { return }

            if let json = value as? [String: Any], let existingId = json["id"] as? String, !existingId.isEmpty {
                // Room exists already. If it's this same identity re-hosting its own still-alive
                // room (survived an ungraceful exit, or a companion device redundantly pressing
                // Host under the shared phone/watch identity — see deriveMemberId), adopt it as a
                // success instead of failing: server state must not depend on which companion
                // device happened to perform the hand-off.
                if let data = try? JSONSerialization.data(withJSONObject: json),
                   let existingRoom = try? JSONDecoder().decode(SquadRoom.self, from: data),
                   existingRoom.hostId == room.hostId {
                    DispatchQueue.main.async {
                        self.publishRoom(existingRoom)
                        self.isConnected = true
                        self.memberLatestTimestamps.removeAll()
                        self.memberLatestSequences.removeAll()
                        self.startTelemetryPolling(roomId: existingRoom.id)
                        completion?(.success(existingRoom))
                    }
                    return
                }

                // A genuinely different identity already owns this room id — unrelated identities
                // must still not collide.
                let err = FirebaseSyncError.roomAlreadyExists
                DispatchQueue.main.async {
                    self.errorMessage = err.localizedDescription
                    completion?(.failure(err))
                }
                return
            }

            // 2. Room does not exist -> Create room node first, then initialize telemetry & tactical subrooms
            let encoder = JSONEncoder()
            guard let payloadData = try? encoder.encode(room),
                  let payload = try? JSONSerialization.jsonObject(with: payloadData) else {
                let err = FirebaseSyncError.networkError("Serialization failure")
                DispatchQueue.main.async {
                    self.errorMessage = err.localizedDescription
                    completion?(.failure(err))
                }
                return
            }

            self.transport.setValue(payload, at: self.roomPath(roomId: cleanId)) { [weak self] success in
                guard let self = self else { return }

                guard success else {
                    let syncError = FirebaseSyncError.networkError("Failed to write room")
                    DispatchQueue.main.async {
                        self.errorMessage = syncError.localizedDescription
                        completion?(.failure(syncError))
                    }
                    return
                }

                // Room created successfully -> Now initialize subnodes with clean TTL metadata
                let initGroup = DispatchGroup()
                let ttlPayload: [String: Any] = ["exp": room.expireAt]

                initGroup.enter()
                self.transport.setValue(ttlPayload, at: self.telemetryPath(roomId: cleanId)) { _ in
                    initGroup.leave()
                }

                initGroup.enter()
                self.transport.setValue(ttlPayload, at: self.tacticalPath(roomId: cleanId)) { _ in
                    initGroup.leave()
                }

                initGroup.notify(queue: .main) {
                    self.publishRoom(room)
                    self.isConnected = true
                    self.memberLatestTimestamps.removeAll()
                    self.memberLatestSequences.removeAll()
                    self.startTelemetryPolling(roomId: room.id)
                    completion?(.success(room))
                }
            }
        }
    }

    public func joinRoom(id: String, member: SquadMember, pin: String? = nil, completion: ((Result<SquadRoom, FirebaseSyncError>) -> Void)? = nil) {
        let cleanId = id.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cleanId.isEmpty {
            let err = FirebaseSyncError.emptyRoomName
            DispatchQueue.main.async {
                self.errorMessage = err.localizedDescription
                completion?(.failure(err))
            }
            return
        }

        let cleanCallsign = member.callsign.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanCallsign.isEmpty {
            let err = FirebaseSyncError.emptyCallsign
            DispatchQueue.main.async {
                self.errorMessage = err.localizedDescription
                completion?(.failure(err))
            }
            return
        }

        transport.getValue(at: roomPath(roomId: cleanId)) { [weak self] value in
            guard let self = self else { return }

            // SquadRoom's own decoder (SquadRoom.swift) is lenient per-field and per-member, so
            // this only fails when the node itself is absent/not an object — a genuine "no such
            // room", not "a populated room had one odd entry" (see SquadMemberRoster).
            guard let value = value,
                  JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value),
                  var room = try? JSONDecoder().decode(SquadRoom.self, from: data) else {
                DispatchQueue.main.async {
                    self.errorMessage = FirebaseSyncError.roomNotFound.localizedDescription
                    completion?(.failure(.roomNotFound))
                }
                return
            }

            // Validate Callsign duplication (case-insensitive check against other members in this room only)
            let trimmedCallsign = member.callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let callsignConflict = room.members.values.contains { existing in
                existing.id != member.id && existing.callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == trimmedCallsign
            }
            if callsignConflict {
                DispatchQueue.main.async {
                    self.errorMessage = FirebaseSyncError.duplicateCallsign.localizedDescription
                    completion?(.failure(.duplicateCallsign))
                }
                return
            }

            // Validate PIN (mandatory — see CLOUD_DATA_MANAGEMENT.md)
            let inputHash = FirebaseSyncManager.hashPin(pin ?? "", salt: cleanId)
            if inputHash != room.pinHash {
                DispatchQueue.main.async {
                    self.errorMessage = FirebaseSyncError.incorrectPin.localizedDescription
                    completion?(.failure(.incorrectPin))
                }
                return
            }

            // Validate room capacity
            if room.members.count >= room.maxCapacity && room.members[member.id] == nil {
                DispatchQueue.main.async {
                    self.errorMessage = FirebaseSyncError.roomFull.localizedDescription
                    completion?(.failure(.roomFull))
                }
                return
            }

            // Publish local member to room
            self.publishMemberToFirebase(roomId: cleanId, member: member)
            room.members[member.id] = member

            DispatchQueue.main.async {
                self.publishRoom(room)
                self.isConnected = true
                self.memberLatestTimestamps.removeAll()
                self.memberLatestSequences.removeAll()
                self.startTelemetryPolling(roomId: cleanId)
                completion?(.success(room))
            }
        }
    }

    public func connectToRoom(_ room: SquadRoom) {
        self.publishRoom(room)
        self.isConnected = true
        self.memberLatestTimestamps.removeAll()
        self.memberLatestSequences.removeAll()

        // Sync full room and members from Firebase
        fetchRoomDetails(roomId: room.id)

        // Register local members into the room on Firebase
        for (_, member) in room.members {
            publishMemberToFirebase(roomId: room.id, member: member)
        }

        startTelemetryPolling(roomId: room.id)
    }

    /// Connects a companion device to an already hosted/joined room without re-publishing or asserting duplicate member.
    public func connectToExistingRoom(roomId: String, completion: ((Bool) -> Void)? = nil) {
        let cleanId = roomId.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanId.isEmpty else {
            completion?(false)
            return
        }
        self.isConnected = true
        self.memberLatestTimestamps.removeAll()
        self.memberLatestSequences.removeAll()
        self.currentRoomId = cleanId
        fetchRoomDetails(roomId: cleanId)
        startTelemetryPolling(roomId: cleanId)
        completion?(true)
    }

    /// Purges all local room tracking state and timestamps. Deliberately does NOT touch
    /// Room/Tactical — those are owned exclusively by `Set()`/`Get()` on
    /// `watchConnectivityManager`; the "loginCycle went inactive, purge Room/Tactical/Telemetry"
    /// box in the architecture diagram is `GameStateManager.purgeLocalSessionAndIcons`'s
    /// responsibility, not this class's.
    public func resetLocalSessionAndIcons() {
        stopTelemetryPolling()
        self.currentRoomId = nil
        self.isConnected = false
        self.memberLatestTimestamps.removeAll()
        self.memberLatestSequences.removeAll()
        self.activeTelemetryKey = nil
        self.incomingDecryptionKey = nil
    }

    public func disbandRoom(roomId: String, completion: ((Bool) -> Void)? = nil) {
        deleteRoom(roomId: roomId, completion: completion)
    }

    public func deleteRoom(roomId: String, completion: ((Bool) -> Void)? = nil) {
        stopTelemetryPolling()

        // 1. Delete room node FIRST. This immediately revokes peer write permissions for any in-flight
        // telemetry or tactical packets (rules require `root.child('r').child($roomId).exists()`).
        // Any packet arriving after this write is rejected with PERMISSION_DENIED, preventing
        // in-flight packets from resurrecting /p or /t JSON trees.
        self.transport.removeValue(at: self.roomPath(roomId: roomId)) { [weak self] _ in
            guard let self = self else {
                DispatchQueue.main.async { completion?(true) }
                return
            }

            let purgeGroup = DispatchGroup()

            // 2. Delete telemetry node (allowed by !newData.exists() rule)
            purgeGroup.enter()
            self.transport.removeValue(at: self.telemetryPath(roomId: roomId)) { _ in
                purgeGroup.leave()
            }

            // 3. Delete tactical indicators node (allowed by !newData.exists() rule)
            purgeGroup.enter()
            self.transport.removeValue(at: self.tacticalPath(roomId: roomId)) { _ in
                purgeGroup.leave()
            }

            // 4. Reset local session once subtrees are wiped
            purgeGroup.notify(queue: .global()) { [weak self] in
                DispatchQueue.main.async {
                    self?.resetLocalSessionAndIcons()
                    completion?(true)
                }
            }
        }
    }

    public func logoutPlayer(roomId: String, memberId: String, completion: ((Bool) -> Void)? = nil) {
        stopTelemetryPolling()

        let group = DispatchGroup()

        // 1. Delete player member entry
        group.enter()
        transport.removeValue(at: roomMemberPath(roomId: roomId, memberId: memberId)) { _ in
            group.leave()
        }

        // 2. Delete player telemetry entry
        group.enter()
        transport.removeValue(at: telemetryMemberPath(roomId: roomId, memberId: memberId)) { _ in
            group.leave()
        }

        // 3. Delete player squad order icons from tactical node
        group.enter()
        transport.getValue(at: tacticalOrderPath(roomId: roomId)) { [weak self] value in
            defer { group.leave() }
            guard let self = self, let json = value as? [String: Any] else { return }

            for (indicatorId, val) in json {
                guard let arr = val as? [Any], arr.count >= 5 else { continue }
                let placedBy = String(describing: arr[4])
                if placedBy == memberId {
                    group.enter()
                    self.transport.removeValue(at: self.tacticalOrderPath(roomId: roomId, indicatorId: indicatorId)) { _ in
                        group.leave()
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.resetLocalSessionAndIcons()
            completion?(true)
        }
    }

    /// Refreshes this room's TTL expiry across all three top-level trees. Not server-enforced —
    /// gate calls on `isCurrentMemberHost` client-side. See CLOUD_DATA_MANAGEMENT.md.
    public func refreshRoomExpiry(roomId: String) {
        let newExpireAt = Date().timeIntervalSince1970 + AppConstants.Timing.Inactivity.ttlDurationSeconds
        transport.setValue(newExpireAt, at: roomExpireAtPath(roomId: roomId), completion: nil)
        transport.setValue(newExpireAt, at: telemetryExpireAtPath(roomId: roomId), completion: nil)
        transport.setValue(newExpireAt, at: tacticalExpireAtPath(roomId: roomId), completion: nil)
    }

    public func leaveRoom(isHost: Bool = false, memberId: String? = nil) {
        guard let roomId = currentRoomId else {
            self.isConnected = false
            stopTelemetryPolling()
            return
        }

        if isHost {
            disbandRoom(roomId: roomId)
        } else {
            let mId = memberId ?? ""
            if !mId.isEmpty {
                logoutPlayer(roomId: roomId, memberId: mId)
            } else {
                stopTelemetryPolling()
                self.currentRoomId = nil
                self.isConnected = false
            }
        }
    }

    /// Pushes a single member's roster row (`mid`/`csn`/`rol`) to Firebase. Does not touch the
    /// local Room store — a caller that wants its own edit reflected in Room immediately (for
    /// instant local display feedback, ahead of the round trip) calls
    /// `watchConnectivityManager.roomSet(...)` itself alongside this, the same "multiple
    /// legitimate callers of one Set()" pattern used for local tactical marker placement.
    public func updateMember(_ member: SquadMember) {
        guard let roomId = currentRoomId else { return }
        publishMemberToFirebase(roomId: roomId, member: member)
    }

    /// Clears local per-member bookkeeping (freshness tracking) for a member id. Does not touch
    /// the local Room store or issue a server-side delete — see call site
    /// (`GameStateManager.updateLocalMember`) for why: a `myMemberId` change (derived from a
    /// callsign edit) needs its OLD id's local tracking cleared, but Room mutation for both the
    /// removal and the new row is the caller's responsibility.
    public func removeMember(id: String) {
        memberLatestTimestamps.removeValue(forKey: id)
        memberLatestSequences.removeValue(forKey: id)
    }

    private func publishMemberToFirebase(roomId: String, member: SquadMember) {
        let payload: [String: Any] = [
            "mid": member.id,
            "csn": member.callsign,
            "rol": member.role.rawValue
        ]
        transport.setValue(payload, at: roomMemberPath(roomId: roomId, memberId: member.id), completion: nil)
    }

    /// Places/updates a tactical indicator: pushes to Firebase and — like local marker
    /// placement in `GameStateManager` — the caller is expected to also call
    /// `watchConnectivityManager.tacticalSet(...)` for instant local display feedback ahead of
    /// the round trip (multiple legitimate callers of one `Set()`, same pattern as
    /// `updateMember` above).
    public func addOrUpdateIndicator(roomId: String, indicator: TacticalIndicator) {
        publishIndicatorToFirebase(roomId: roomId, indicator: indicator)
    }

    public func removeIndicator(roomId: String, indicatorId: String) {
        deleteIndicatorFromFirebase(roomId: roomId, indicatorId: indicatorId)
    }

    private func publishIndicatorToFirebase(roomId: String, indicator: TacticalIndicator) {
        telemetrySchedulerQueue.async {
            self._uploadMetrics.tacticalWritesSubmitted += 1
        }

        let path = indicator.type.category == .squadOrder
            ? tacticalOrderPath(roomId: roomId, indicatorId: indicator.id)
            : tacticalCappedIndicatorPath(roomId: roomId, indicatorId: indicator.id)

        let wireValue: Any
        if let key = activeTelemetryKey, let encrypted = try? CompactArrayCipher.encrypt(indicator.compactArray, key: key) {
            wireValue = encrypted
        } else {
            wireValue = indicator.compactArray
        }

        transport.setValue(wireValue, at: path) { [weak self] success in
            guard let self = self else { return }
            self.telemetrySchedulerQueue.async {
                if success {
                    self._uploadMetrics.tacticalWritesCompleted += 1
                } else {
                    self._uploadMetrics.tacticalWritesFailed += 1
                }
            }
        }
    }

    private func deleteIndicatorFromFirebase(roomId: String, indicatorId: String) {
        // No category available at this call site — issue the delete against both branches
        // unconditionally; deleting a path that doesn't hold this id is a harmless no-op.
        telemetrySchedulerQueue.async {
            self._uploadMetrics.tacticalWritesSubmitted += 1
        }

        transport.removeValue(at: tacticalOrderPath(roomId: roomId, indicatorId: indicatorId)) { [weak self] success in
            guard let self = self else { return }
            self.telemetrySchedulerQueue.async {
                if success {
                    self._uploadMetrics.tacticalWritesCompleted += 1
                } else {
                    self._uploadMetrics.tacticalWritesFailed += 1
                }
            }
        }

        transport.removeValue(at: tacticalCappedIndicatorPath(roomId: roomId, indicatorId: indicatorId), completion: nil)
    }

    /// One-shot read-and-apply of the full /t/{roomId} node. The realtime tactical listener (see
    /// attachRealtimeListeners) delivers ongoing change pushes on its own; this is for explicit
    /// one-shot callers (initial load on fetchRoomDetails).
    public func fetchTacticalIndicators(roomId: String) {
        transport.getValue(at: tacticalPath(roomId: roomId)) { [weak self] value in
            self?.applyTacticalSnapshot(value as? [String: Any], roomId: roomId)
        }
    }

    /// Decodes a /t/{roomId} snapshot and merges it into the shared `Tactical` store via
    /// `Set()`. Self-echo filter (§ "audit pass — Tactical's self-echo mechanism" in the
    /// implementation plan, required — this is the one domain where uplink and downlink share a
    /// store and the content isn't safe to blindly trust): for each incoming indicator, compare
    /// its `TacticalIndicator.timestamp` against the currently-held indicator's `timestamp`
    /// (read from `Tactical.Get()` — genuinely bidirectional), keep whichever is newer. No
    /// separate ACK-buffer bookkeeping (replaces `unacknowledgedIndicators` entirely) — an id
    /// present only in the current local copy (not in this snapshot) is dropped, same
    /// snapshot-is-truth trade-off Room's pipeline accepts (a brief cosmetic flicker on the
    /// round trip, not a correctness issue).
    private func applyTacticalSnapshot(_ json: [String: Any]?, roomId: String) {
        var decodedIndicators: [String: TacticalIndicator] = [:]

        if let json = json {
            // Squad orders (t/{roomId}/o) and enemy+environment (t/{roomId}/i) are disjoint
            // branches — every entry under either is an indicator, no metadata-key filtering
            // needed (§6/§8).
            let orders = (json["o"] as? [String: Any]) ?? [:]
            let capped = (json["i"] as? [String: Any]) ?? [:]
            for (key, val) in orders.merging(capped, uniquingKeysWith: { a, _ in a }) {
                if let ind = TacticalIndicator.parse(id: key, rawValue: val, key: incomingDecryptionKey), !ind.isExpired {
                    decodedIndicators[ind.id] = ind
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let wcm = self.watchConnectivityManager else { return }
            var currentById: [String: TacticalIndicator] = [:]
            for ind in wcm.tacticalGet().indicators {
                currentById[ind.id] = ind
            }

            var merged: [String: TacticalIndicator] = [:]
            for (id, incoming) in decodedIndicators {
                if let existing = currentById[id], existing.timestamp > incoming.timestamp {
                    merged[id] = existing
                } else {
                    merged[id] = incoming
                }
            }

            let sorted = merged.values.sorted { $0.timestamp < $1.timestamp }
            wcm.tacticalSet(TacticalSnapshot(indicators: sorted))
        }
    }

    public func fetchRoomDetails(roomId: String) {
        fetchTacticalIndicators(roomId: roomId)

        transport.getValue(at: roomPath(roomId: roomId)) { [weak self] value in
            self?.applyRoomSnapshot(value, roomId: roomId)
        }
    }

    /// Decodes a members-only /r/{roomId}/m snapshot and writes it into the shared `Room` store
    /// via `Set()`. No self-echo filtering — the local member's own row, when present in the
    /// snapshot, is accepted like any other row (its appearance is the positive "join/host
    /// succeeded" signal, not something to filter — see the implementation plan's "Room's
    /// self-echo handling" resolution). Room metadata fields (`hostId`/`pinHash`/`maxCapacity`/
    /// `maxTacticalIndicators`) aren't present in this members-only payload, so they're carried
    /// forward unchanged from the current `Room.Get()` — a normal partial-update read, not a
    /// stub: the values being carried forward are real, just-fetched data from the one-shot full
    /// room read (`applyRoomSnapshot`) that always runs before this listener's first fire.
    private func applyMembersSnapshot(_ value: Any?, roomId: String) {
        guard let value = value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let decodedMembers = try? JSONDecoder().decode(SquadMemberRoster.self, from: data) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let wcm = self.watchConnectivityManager else { return }
            let current = wcm.roomGet()
            let members = decodedMembers.members.values.sorted { $0.id < $1.id }
            wcm.roomSet(RoomSnapshot(
                members: members,
                hostId: current.hostId,
                roomId: current.roomId.isEmpty ? roomId : current.roomId,
                pinHash: current.pinHash,
                maxCapacity: current.maxCapacity,
                maxTacticalIndicators: current.maxTacticalIndicators
            ))
        }
    }

    /// Decodes a full /r/{roomId} snapshot (room metadata + members) and writes it into the
    /// shared `Room` store via `Set()`. Used only by the one-shot fetch (fetchRoomDetails, on
    /// initial connect) that needs the room's metadata (host, capacity, pinHash, expireAt) — the
    /// persistent realtime listener uses applyMembersSnapshot instead. SquadRoom's decoder (see
    /// SquadRoom.swift/SquadMember.swift) is lenient per-field and per-member by construction, so
    /// this fails only when the node itself is missing or isn't an object — never because one
    /// member in a populated room had an odd shape.
    private func applyRoomSnapshot(_ value: Any?, roomId: String) {
        guard let value = value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let decodedRoom = try? JSONDecoder().decode(SquadRoom.self, from: data) else { return }

        DispatchQueue.main.async { [weak self] in
            self?.publishRoom(decodedRoom)
        }
    }

    // MARK: - Telemetry Stream Subscription (Realtime Listeners)

    /// Updates wrist viewing activity and triggers an Instant Wake Burst upon wrist raise. Called
    /// only from `GameStateManager.setWristActive` — this class's `isWristActive` is a private
    /// implementation detail used solely for the wake-burst safety-net check below, not a
    /// canonical externally-read flag (see `GameStateManager.isWristActive`'s doc comment). Note
    /// this does NOT gate outbound telemetry upload rate — self-location must keep uploading
    /// (subject to the delta-gate/refresh-interval/network-quality equation) regardless of
    /// whether this device's wrist/screen is active, since other players still need to see this
    /// device's position while its own screen is off.
    func setWristActive(_ active: Bool) {
        let wasActive = isWristActive
        self.isWristActive = active

        // Instant Wake Burst: When wrist is raised, immediately fetch telemetry to eliminate visual lag.
        // Also fires if wrist was already active but listeners aren't currently attached (safety
        // net — mirrors the original `|| telemetryPollingTimer == nil` REST-era fallback).
        if active && (!wasActive || telemetryChildAddedHandle == nil), let roomId = currentRoomId {
            fetchRemoteTelemetry(roomId: roomId)
        }
    }

    /// Explicit awake trigger for gestures (e.g. double tap, screen tap, digital crown rotation).
    /// No Firebase re-fetch here — the SDK's always-attached listeners already keep local state
    /// current (see §9); this only lifts the wrist-down throttle.
    public func triggerWakeBurst() {
        setWristActive(true)
    }

    /// Gated attach entry point (see CLOUD_DATA_MANAGEMENT.md §2/§5.B): callers — e.g.
    /// GameStateManager.evaluateListenerGate() — invoke this only when the
    /// app_active / active_until lease conditions allow this device to be the active cloud
    /// client. Attaches the three persistent realtime listeners, which fire immediately on
    /// attachment with the current state, then again on every subsequent change — no separate
    /// instant-fetch call needed (see §9).
    public func startTelemetryPolling(roomId: String) {
        let cleanId = roomId.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanId.isEmpty else { return }

        // evaluateListenerGate() re-invokes this on every heartbeat tick while the gate stays
        // open, not just on a real transition. Without this guard, an already-attached room
        // would get torn down and rebuilt from scratch every tick, replaying the childAdded
        // burst and causing member names/annotations to blink on that cadence even though
        // nothing about the attachment actually changed.
        guard attachedTelemetryRoomId != cleanId else { return }

        detachRealtimeListeners()
        attachRealtimeListeners(roomId: cleanId)
        attachedTelemetryRoomId = cleanId
        currentRoomId = cleanId
    }

    public func stopTelemetryPolling() {
        detachRealtimeListeners()
        attachedTelemetryRoomId = nil
    }

    private func attachRealtimeListeners(roomId: String) {
        telemetryChildAddedHandle = transport.observe(at: telemetryPath(roomId: roomId), eventType: .childAdded) { [weak self] snapshot in
            self?.handleTelemetryChildUpsert(snapshot, roomId: roomId)
        }
        telemetryChildChangedHandle = transport.observe(at: telemetryPath(roomId: roomId), eventType: .childChanged) { [weak self] snapshot in
            self?.handleTelemetryChildUpsert(snapshot, roomId: roomId)
        }
        telemetryChildRemovedHandle = transport.observe(at: telemetryPath(roomId: roomId), eventType: .childRemoved) { [weak self] snapshot in
            self?.handleTelemetryChildRemoved(snapshot)
        }

        tacticalValueHandle = transport.observe(at: tacticalPath(roomId: roomId), eventType: .value) { [weak self] snapshot in
            self?.applyTacticalSnapshot(snapshot.value as? [String: Any], roomId: roomId)
        }

        // Scoped to the members subtree, not the whole room node — see applyMembersSnapshot.
        roomValueHandle = transport.observe(at: roomMembersPath(roomId: roomId), eventType: .value) { [weak self] snapshot in
            guard let self = self else { return }
            self.membersValueFireCount += 1
            let dict = snapshot.value as? [String: Any]
            let memberCount = dict?.count ?? 0
            if let data = try? JSONSerialization.data(withJSONObject: dict ?? [:]),
               let json = String(data: data, encoding: .utf8) {
                print("[Firebase] roomMembersPath .value fire #\(self.membersValueFireCount) roomId=\(roomId) memberCount=\(memberCount) bytes=\(data.count) content=\(json)")
            } else {
                print("[Firebase] roomMembersPath .value fire #\(self.membersValueFireCount) roomId=\(roomId) memberCount=\(memberCount) (unencodable snapshot)")
            }
            self.applyMembersSnapshot(snapshot.value, roomId: roomId)
        }
    }

    private func detachRealtimeListeners() {
        for handle in [telemetryChildAddedHandle, telemetryChildChangedHandle, telemetryChildRemovedHandle, tacticalValueHandle, roomValueHandle].compactMap({ $0 }) {
            transport.removeObserver(handle)
        }
        telemetryChildAddedHandle = nil
        telemetryChildChangedHandle = nil
        telemetryChildRemovedHandle = nil
        tacticalValueHandle = nil
        roomValueHandle = nil
    }

    /// Applied to every incoming childAdded/childChanged event, including this device's own
    /// optimistic pre-server-confirmation echo of its own telemetry — that echo is simply this
    /// device's own memberId, not a remote player, and is dropped rather than forwarded.
    /// Everything else decrypts/parses and forwards straight to
    /// `validateAndProcessPacket`/`onRemoteTelemetryPacketsReceived` — no room/roster lookups or
    /// writes here (see the class-level doc comment on `validateAndProcessPacket`).
    private func handleTelemetryChildUpsert(_ snapshot: RTDBSnapshot, roomId: String) {
        let memberId = snapshot.key
        guard !memberId.hasPrefix("_"), !FirebaseSyncManager.telemetryMetadataKeys.contains(memberId) else { return }
        guard localMemberId != memberId else { return }

        if let packet = FirebaseSyncManager.parseTelemetryPacket(memberId: memberId, roomId: roomId, rawValue: snapshot.value as Any, key: incomingDecryptionKey) {
            validateAndProcessPacket(packet)
            DispatchQueue.main.async { [weak self] in
                self?.onRemoteTelemetryPacketsReceived?([packet])
            }
        }
    }

    private func handleTelemetryChildRemoved(_ snapshot: RTDBSnapshot) {
        _ = snapshot
        // Telemetry-node departure is purely a display-freshness concern for
        // `GameStateManager.persistentRemoteTelemetry` (pruned there against current Room
        // membership on every Room change) — it no longer drives any Room/roster mutation here.
    }

    /// Helper to parse a TelemetryPacket from compact array format, JSON dictionary, or (when
    /// `key` is supplied) an AES-256-GCM encrypted compact array string. `key` is nil for
    /// device-local channels (e.g. the Watch high-speed relay) that never carry ciphertext.
    public static func parseTelemetryPacket(memberId: String, roomId: String, rawValue: Any, key: SymmetricKey? = nil) -> TelemetryPacket? {
        if let ciphertext = rawValue as? String, let key {
            guard let array = try? CompactArrayCipher.decrypt(ciphertext, key: key) else { return nil }
            return TelemetryPacket.fromCompactArray(memberId: memberId, roomId: roomId, array: array)
        } else if let array = rawValue as? [Any] {
            return TelemetryPacket.fromCompactArray(memberId: memberId, roomId: roomId, array: array)
        } else if let telemetryData = rawValue as? [String: Any] {
            guard let lat = telemetryData["lat"] as? Double,
                  let lng = telemetryData["lng"] as? Double,
                  let hdg = telemetryData["hdg"] as? Double,
                  let hr = telemetryData["hr"] as? Double,
                  let seq = (telemetryData["seq"] as? NSNumber)?.int64Value ?? (telemetryData["seq"] as? Int64),
                  let ts = telemetryData["ts"] as? TimeInterval else { return nil }

            let alt = telemetryData["alt"] as? Double
            return TelemetryPacket(
                memberId: memberId,
                roomId: roomId,
                latitude: lat,
                longitude: lng,
                altitude: alt,
                heading: hdg,
                heartRate: hr,
                timestamp: ts,
                sequenceNumber: seq
            )
        }
        return nil
    }

    /// One-shot read-and-apply of the full /p/{roomId} node. Used for the instant initial
    /// fetch in startTelemetryPolling and for explicit wake-burst refreshes; the persistent
    /// childAdded/childChanged/childRemoved listeners (see attachRealtimeListeners) handle ongoing
    /// real-time updates without needing to be re-invoked.
    public func fetchRemoteTelemetry(roomId: String) {
        transport.getValue(at: telemetryPath(roomId: roomId)) { [weak self] value in
            guard let self = self else { return }

            let jsonDict = value as? [String: Any]

            var batchPackets: [TelemetryPacket] = []
            if let dict = jsonDict {
                for (memberId, rawValue) in dict {
                    if memberId.starts(with: "_") || FirebaseSyncManager.telemetryMetadataKeys.contains(memberId) {
                        continue
                    }
                    if let localId = self.localMemberId, memberId == localId {
                        continue
                    }
                    if let packet = FirebaseSyncManager.parseTelemetryPacket(memberId: memberId, roomId: roomId, rawValue: rawValue, key: self.incomingDecryptionKey) {
                        batchPackets.append(packet)
                    }
                }
            }

            if !batchPackets.isEmpty {
                self.validateAndProcessPackets(batchPackets)
                DispatchQueue.main.async {
                    self.onRemoteTelemetryPacketsReceived?(batchPackets)
                }
            }
        }
    }

    // MARK: - RTDB Path Helpers
    // Plain Realtime Database paths (no REST-style ".json" suffix) shared by every transport call
    // site above.

    private func telemetryPath(roomId: String) -> String { "p/\(roomId)" }
    private func telemetryMemberPath(roomId: String, memberId: String) -> String { "p/\(roomId)/\(memberId)" }
    private func telemetryExpireAtPath(roomId: String) -> String { "p/\(roomId)/exp" }
    private func tacticalPath(roomId: String) -> String { "t/\(roomId)" }
    private func tacticalOrderPath(roomId: String, indicatorId: String) -> String { "t/\(roomId)/o/\(indicatorId)" }
    private func tacticalOrderPath(roomId: String) -> String { "t/\(roomId)/o" }
    private func tacticalCappedIndicatorPath(roomId: String, indicatorId: String) -> String { "t/\(roomId)/i/\(indicatorId)" }
    private func tacticalExpireAtPath(roomId: String) -> String { "t/\(roomId)/exp" }
    private func roomPath(roomId: String) -> String { "r/\(roomId)" }
    private func roomMembersPath(roomId: String) -> String { "r/\(roomId)/m" }
    private func roomMemberPath(roomId: String, memberId: String) -> String { "r/\(roomId)/m/\(memberId)" }
    private func roomExpireAtPath(roomId: String) -> String { "r/\(roomId)/exp" }
}
