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
        }
    }
}

public final class FirebaseSyncManager: NSObject, ObservableObject {
    @Published public var activeRoom: SquadRoom? {
        didSet {
            if oldValue?.members.count != activeRoom?.members.count {
                recalculateAdaptivePollingInterval()
            }
        }
    }

    @Published public var isConnected: Bool = false
    @Published public var syncLatencyMs: Double = 0.0
    @Published public var totalPacketsProcessed: Int = 0
    @Published public var totalPacketsRejected: Int = 0
    @Published public var latestRejection: RejectionEvent?
    @Published public var errorMessage: String?
    @Published public var squadMembersArray: [SquadMember] = []

    @Published public private(set) var pollingInterval: TimeInterval = AppConstants.Timing.AdaptiveRate.baselineInterval
    @Published public var isWristActive: Bool = true

    public var onRemoteTelemetryPacketsReceived: (([TelemetryPacket]) -> Void)?

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
    public var authToken: String? = nil

    // Local member ID for bandwidth saving / avoiding overwriting live telemetry with server data
    public var localMemberId: String? = nil

    // Per-member telemetry state tracking for Late Packet Rejection
    private var memberLatestTimestamps: [String: TimeInterval] = [:]
    private var memberLatestSequences: [String: Int64] = [:]
    private var pendingMemberFetches: Set<String> = []

    /// Unacknowledged tactical indicators awaiting server ACK (maps indicatorId -> local placement timestamp)
    public private(set) var unacknowledgedIndicators: [String: TimeInterval] = [:]

    // MARK: - Realtime Database Transport
    // See RTDBTransport.swift and CLOUD_DATA_MANAGEMENT.md §5.B/§5.C: production talks to the
    // real FirebaseDatabase SDK (one shared, persistent, multiplexed connection); tests inject a
    // mock conforming to the same protocol.
    public lazy var transport: RTDBTransport = FirebaseRTDBTransport(databaseURLProvider: { [weak self] in
        self?.databaseURL ?? AppConstants.Network.defaultDatabaseURL
    })

    // Gated realtime listener handles for the three downstream channels. Attached by
    // startTelemetryPolling(roomId:) / detached by stopTelemetryPolling() — the same gated
    // entry points GameStateManager already calls based on screen_active / active_until lease
    // state (see evaluatePhoneCloudClientPolicy), so no caller changes were needed.
    private var telemetryChildAddedHandle: RTDBObserverHandle?
    private var telemetryChildChangedHandle: RTDBObserverHandle?
    private var telemetryChildRemovedHandle: RTDBObserverHandle?
    private var tacticalValueHandle: RTDBObserverHandle?
    private var roomValueHandle: RTDBObserverHandle?

    /// Member IDs currently present under /p/{roomId}, maintained incrementally from
    /// childAdded/childRemoved events so reconcileRemoteMembers keeps its original
    /// whole-snapshot-based pruning behavior without re-fetching the full node on every event.
    private var observedTelemetryMemberIds: Set<String> = []

    private static let telemetryMetadataKeys: Set<String> = ["exp"]

    override public init() {
        super.init()

        _isRTDBConnected = networkQualityMonitor.isConnected
        networkQualityMonitor.$isConnected
            .sink { [weak self] connected in
                self?.setRTDBConnected(connected)
            }
            .store(in: &cancellables)

        // Recalculate polling interval only when player count or connection grade changes —
        // not on every coordinate update — preventing spurious Timer restarts.
        Publishers.CombineLatest(
            $activeRoom.map { $0?.members.count ?? 0 }.removeDuplicates(),
            networkQualityMonitor.$connectionGrade
        )
        .sink { [weak self] _, _ in
            self?.recalculateAdaptivePollingInterval()
        }
        .store(in: &cancellables)

        // Rebuild squadMembersArray only when member count changes (same guard as above).
        $activeRoom
            .map { (room: SquadRoom?) -> [SquadMember] in
                guard let room = room else { return [] }
                return Array(room.members.values)
            }
            .removeDuplicates { (prev: [SquadMember], next: [SquadMember]) -> Bool in
                guard prev.count == next.count else { return false }
                return zip(prev, next).allSatisfy { $0.id == $1.id }
            }
            .sink { [weak self] (members: [SquadMember]) in
                self?.squadMembersArray = members
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

    /// Derives a deterministic room-id padding suffix from (name, PIN), domain-separated from
    /// `hashPin`'s own combined-string format via the "roompad:" prefix so the two derivations
    /// never share identical input despite hashing the same PIN. See ROOM_ID_HARDENING.md §1.
    public static func deriveRoomPadding(pin: String, name: String, length: Int? = nil) -> String {
        let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
        let padLength = length ?? max(0, AppConstants.UI.maxRoomNameLength - name.count)
        let combined = "roompad:\(name):\(pin)"
        let digest = Array(SHA256.hash(data: Data(combined.utf8)))
        return String(digest.prefix(padLength).map { alphabet[Int($0) % alphabet.count] })
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

    /// Validates whether an incoming telemetry packet is fresh or should be rejected.
    /// Returns true if accepted and updates tracking state, false if rejected.
    @discardableResult
    public func validateAndProcessPacket(_ packet: TelemetryPacket) -> Bool {
        guard checkAndTrackPacketFreshness(packet) else { return false }

        let apply = { [weak self] in
            guard let self = self else { return }
            self.totalPacketsProcessed += 1
            self.applyTelemetryToActiveRoom(packet)
        }

        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
        return true
    }

    /// Validates and applies a batch of telemetry packets, updating activeRoom in a single
    /// pass to avoid redundant @Published view re-evaluations.
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
            let roomId = self.activeRoom?.id ?? acceptedPackets.first?.roomId ?? ""
            var room = self.activeRoom ?? SquadRoom(id: roomId, hostId: "")
            for packet in acceptedPackets {
                self.updateMember(with: packet, in: &room.members)
            }
            self.totalPacketsProcessed += acceptedPackets.count
            self.activeRoom = room
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

    private func updateMember(with packet: TelemetryPacket, in members: inout [String: SquadMember]) {
        let isExistingMember = members[packet.memberId] != nil
        var member = members[packet.memberId] ?? SquadMember(
            id: packet.memberId,
            callsign: "",
            latitude: packet.latitude,
            longitude: packet.longitude,
            altitude: packet.altitude,
            heading: packet.heading,
            heartRate: packet.heartRate,
            lastUpdatedTimestamp: packet.timestamp,
            sequenceNumber: packet.sequenceNumber,
            status: packet.heartRate == AppConstants.Health.flatlineHeartRate ? .downed : .active
        )

        // Compute Course Over Ground (COG) if player moved > threshold
        if isExistingMember {
            let prevCoord = CLLocationCoordinate2D(latitude: member.latitude, longitude: member.longitude)
            let newCoord = CLLocationCoordinate2D(latitude: packet.latitude, longitude: packet.longitude)
            let prevLoc = CLLocation(latitude: member.latitude, longitude: member.longitude)
            let newLoc = CLLocation(latitude: packet.latitude, longitude: packet.longitude)
            let distanceMoved = prevLoc.distance(from: newLoc)
            let isInitialPlaceholder = (abs(member.latitude) < 1e-5 && abs(member.longitude) < 1e-5)

            if packet.heading > 0.0 {
                member.heading = packet.heading
            } else if !isInitialPlaceholder && distanceMoved > AppConstants.Location.minDisplacementForCourseOverGroundMeters {
                let cogHeading = FirebaseSyncManager.calculateBearing(from: prevCoord, to: newCoord)
                member.heading = cogHeading
            }
            // If distanceMoved <= threshold and packet.heading == 0, retain previous heading
        } else if packet.heading > 0.0 {
            member.heading = packet.heading
        }

        if isExistingMember && member.lastUpdatedTimestamp > 0 {
            member.lastAnimationDuration = 0.0

            // Retain the pre-update sample for dead-reckoning extrapolation (DEAD_RECKONING.md),
            // unless it's still the (0,0) initial placeholder rather than a real prior position.
            let isPlaceholder = abs(member.latitude) < 1e-5 && abs(member.longitude) < 1e-5
            if !isPlaceholder {
                member.previousLatitude = member.latitude
                member.previousLongitude = member.longitude
                member.previousUpdatedTimestamp = member.lastUpdatedTimestamp
            }
        }

        member.latitude = packet.latitude
        member.longitude = packet.longitude
        member.altitude = packet.altitude
        member.heartRate = packet.heartRate
        member.lastUpdatedTimestamp = packet.timestamp
        member.sequenceNumber = packet.sequenceNumber

        // If heart rate is flatline (0.0), mark status as downed (KIA)
        if packet.heartRate == AppConstants.Health.flatlineHeartRate {
            member.status = .downed
        } else if member.status == .downed && packet.heartRate > AppConstants.Health.flatlineHeartRate {
            member.status = .active
        }

        members[packet.memberId] = member

        let effectiveRoomId = !packet.roomId.isEmpty ? packet.roomId : (activeRoom?.id ?? "")
        let needsCallsign = member.callsign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || member.callsign == packet.memberId
        if (!isExistingMember || needsCallsign) && !effectiveRoomId.isEmpty {
            fetchMemberDetails(roomId: effectiveRoomId, memberId: packet.memberId)
        }
    }

    private func applyTelemetryToActiveRoom(_ packet: TelemetryPacket) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.applyTelemetryToActiveRoom(packet)
            }
            return
        }
        let roomId = activeRoom?.id ?? packet.roomId
        var room = activeRoom ?? SquadRoom(id: roomId, hostId: "")
        updateMember(with: packet, in: &room.members)
        self.activeRoom = room
    }

    // MARK: - Telemetry Dispatch

    public func sendTelemetryPacket(_ packet: TelemetryPacket) {
        // Local packet is always fresh — apply directly and update tracking state
        let apply = { [weak self] in
            guard let self = self else { return }
            self.applyTelemetryToActiveRoom(packet)
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

        let startTime = Date()
        transport.setValue(payload, at: telemetryMemberPath(roomId: roomId, memberId: memberId)) { [weak self] isSuccess in
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
                // Room exists already
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
                    self.activeRoom = room
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

            // Validate PIN (mandatory — see ROOM_ID_HARDENING.md §2)
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
                self.activeRoom = room
                self.isConnected = true
                self.memberLatestTimestamps.removeAll()
                self.memberLatestSequences.removeAll()
                self.startTelemetryPolling(roomId: cleanId)
                completion?(.success(room))
            }
        }
    }

    public func connectToRoom(_ room: SquadRoom) {
        self.activeRoom = room
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
        if self.activeRoom == nil || self.activeRoom?.id != cleanId {
            self.activeRoom = SquadRoom(id: cleanId, hostId: "")
        }
        fetchRoomDetails(roomId: cleanId)
        startTelemetryPolling(roomId: cleanId)
        completion?(true)
    }

    /// Purges all local room tracking state, timestamps, tactical indicator metadata, and remote players.
    public func resetLocalSessionAndIcons() {
        stopTelemetryPolling()
        self.activeRoom = nil
        self.isConnected = false
        self.memberLatestTimestamps.removeAll()
        self.memberLatestSequences.removeAll()
        self.unacknowledgedIndicators.removeAll()
        self.pendingMemberFetches.removeAll()
    }

    public func disbandRoom(roomId: String, completion: ((Bool) -> Void)? = nil) {
        deleteRoom(roomId: roomId, completion: completion)
    }

    public func deleteRoom(roomId: String, completion: ((Bool) -> Void)? = nil) {
        stopTelemetryPolling()

        let purgeGroup = DispatchGroup()

        // 1. Delete telemetry node
        purgeGroup.enter()
        transport.removeValue(at: telemetryPath(roomId: roomId)) { _ in
            purgeGroup.leave()
        }

        // 2. Delete tactical indicators node
        purgeGroup.enter()
        transport.removeValue(at: tacticalPath(roomId: roomId)) { _ in
            purgeGroup.leave()
        }

        // 3. Delete room node after telemetry & tactical nodes have been purged
        purgeGroup.notify(queue: .global()) { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion?(true) }
                return
            }

            self.transport.removeValue(at: self.roomPath(roomId: roomId)) { _ in
                DispatchQueue.main.async {
                    self.resetLocalSessionAndIcons()
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

    public func removePlayerEntry(roomId: String, memberId: String, completion: ((Bool) -> Void)? = nil) {
        logoutPlayer(roomId: roomId, memberId: memberId, completion: completion)
    }

    /// Refreshes this room's TTL expiry across all three top-level trees. Not server-enforced —
    /// gate calls on `isCurrentMemberHost` client-side. See ROOM_ID_HARDENING.md §8.
    public func refreshRoomExpiry(roomId: String) {
        let newExpireAt = Date().timeIntervalSince1970 + AppConstants.Timing.Inactivity.ttlDurationSeconds
        transport.setValue(newExpireAt, at: roomExpireAtPath(roomId: roomId), completion: nil)
        transport.setValue(newExpireAt, at: telemetryExpireAtPath(roomId: roomId), completion: nil)
        transport.setValue(newExpireAt, at: tacticalExpireAtPath(roomId: roomId), completion: nil)
    }

    public func leaveRoom(isHost: Bool = false, memberId: String? = nil) {
        guard let room = activeRoom else {
            self.activeRoom = nil
            self.isConnected = false
            stopTelemetryPolling()
            return
        }

        if isHost {
            disbandRoom(roomId: room.id)
        } else {
            let mId = memberId ?? ""
            if !mId.isEmpty {
                logoutPlayer(roomId: room.id, memberId: mId)
            } else {
                stopTelemetryPolling()
                self.activeRoom = nil
                self.isConnected = false
            }
        }
    }

    public func updateMember(_ member: SquadMember) {
        guard var room = activeRoom else { return }
        room.members[member.id] = member
        self.activeRoom = room
        publishMemberToFirebase(roomId: room.id, member: member)
    }

    public func removeMember(id: String) {
        guard var room = activeRoom else { return }
        room.members.removeValue(forKey: id)
        memberLatestTimestamps.removeValue(forKey: id)
        memberLatestSequences.removeValue(forKey: id)
        self.activeRoom = room
    }

    private func publishMemberToFirebase(roomId: String, member: SquadMember) {
        let payload: [String: Any] = [
            "mid": member.id,
            "csn": member.callsign,
            "rol": member.role.rawValue
        ]
        transport.setValue(payload, at: roomMemberPath(roomId: roomId, memberId: member.id), completion: nil)
    }

    public func addOrUpdateIndicator(roomId: String, indicator: TacticalIndicator) {
        guard var room = activeRoom, room.id == roomId else { return }
        unacknowledgedIndicators[indicator.id] = Date().timeIntervalSince1970
        room.indicators[indicator.id] = indicator
        self.activeRoom = room
        publishIndicatorToFirebase(roomId: roomId, indicator: indicator)
    }

    public func removeIndicator(roomId: String, indicatorId: String) {
        unacknowledgedIndicators.removeValue(forKey: indicatorId)
        guard var room = activeRoom, room.id == roomId else { return }
        room.indicators.removeValue(forKey: indicatorId)
        self.activeRoom = room
        deleteIndicatorFromFirebase(roomId: roomId, indicatorId: indicatorId)
    }

    private func publishIndicatorToFirebase(roomId: String, indicator: TacticalIndicator) {
        telemetrySchedulerQueue.async {
            self._uploadMetrics.tacticalWritesSubmitted += 1
        }

        let path = indicator.type.category == .squadOrder
            ? tacticalOrderPath(roomId: roomId, indicatorId: indicator.id)
            : tacticalCappedIndicatorPath(roomId: roomId, indicatorId: indicator.id)

        transport.setValue(indicator.compactArray, at: path) { [weak self] success in
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

    /// Decodes and merges a /t/{roomId} snapshot into activeRoom.indicators. Shared by the
    /// one-shot fetch path above and the persistent realtime listener, so both stay in lockstep.
    private func applyTacticalSnapshot(_ json: [String: Any]?, roomId: String) {
        guard let json = json else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if var current = self.activeRoom {
                    let now = Date().timeIntervalSince1970
                    let ackTimeout = AppConstants.Subscription.tacticalIndicatorAckTimeoutSeconds
                    var retainedIndicators: [String: TacticalIndicator] = [:]
                    self.unacknowledgedIndicators = self.unacknowledgedIndicators.filter { id, placedAt in
                        let isWithinTimeout = (now - placedAt) < ackTimeout
                        if isWithinTimeout, let localInd = current.indicators[id] {
                            retainedIndicators[id] = localInd
                            return true
                        }
                        return false
                    }
                    current.indicators = retainedIndicators
                    self.activeRoom = current
                }
            }
            return
        }

        var decodedIndicators: [String: TacticalIndicator] = [:]

        // Squad orders (t/{roomId}/o) and enemy+environment (t/{roomId}/i) are disjoint branches —
        // every entry under either is an indicator, no metadata-key filtering needed (§6/§8).
        let orders = (json["o"] as? [String: Any]) ?? [:]
        let capped = (json["i"] as? [String: Any]) ?? [:]
        for (key, val) in orders.merging(capped, uniquingKeysWith: { a, _ in a }) {
            if let ind = TacticalIndicator.parse(id: key, rawValue: val), !ind.isExpired {
                decodedIndicators[ind.id] = ind
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if var current = self.activeRoom {
                var mergedIndicators = decodedIndicators
                let now = Date().timeIntervalSince1970
                let ackTimeout = AppConstants.Subscription.tacticalIndicatorAckTimeoutSeconds

                // 1. Remove all server-confirmed indicators from the pending ACK map (Server ACK)
                for id in decodedIndicators.keys {
                    self.unacknowledgedIndicators.removeValue(forKey: id)
                }

                // 2. Retain unacknowledged local indicators as long as they are within the timeout
                self.unacknowledgedIndicators = self.unacknowledgedIndicators.filter { id, placedAt in
                    let isWithinTimeout = (now - placedAt) < ackTimeout
                    if isWithinTimeout, let localInd = current.indicators[id] {
                        mergedIndicators[id] = localInd
                        return true
                    }
                    return false
                }

                // 3. Self-echo filter (§5.B, required): for indicators this device itself placed,
                // prefer the locally-authoritative copy over the snapshot's (possibly optimistic,
                // pre-server-confirmation) echo of it. Presence above already counts toward ACK
                // regardless of authorship, so confirmation still works normally.
                if let localId = self.localMemberId {
                    for (id, decoded) in decodedIndicators where decoded.placedByMemberId == localId {
                        if let localCopy = current.indicators[id] {
                            mergedIndicators[id] = localCopy
                        }
                    }
                }

                current.indicators = mergedIndicators
                self.activeRoom = current
            }
        }
    }

    public func fetchRoomDetails(roomId: String) {
        fetchTacticalIndicators(roomId: roomId)

        transport.getValue(at: roomPath(roomId: roomId)) { [weak self] value in
            self?.applyRoomSnapshot(value, roomId: roomId)
        }
    }

    /// Decodes and merges a /r/{roomId} snapshot into activeRoom. Shared by the one-shot fetch
    /// path above and the persistent realtime listener.
    private func applyRoomSnapshot(_ value: Any?, roomId: String) {
        guard let value = value else { return }

        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let decodedRoom = try? JSONDecoder().decode(SquadRoom.self, from: data) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if var current = self.activeRoom {
                    var updatedMembers: [String: SquadMember] = [:]
                    for (id, remoteMember) in decodedRoom.members {
                        // Self-echo filter (§5.B, required): the local member's own row is already
                        // locally authoritative — never let a remote echo (including the SDK's
                        // optimistic pre-server-confirmation echo) overwrite it here.
                        if let localId = self.localMemberId, id == localId {
                            continue
                        }
                        if var existing = current.members[id] {
                            existing.callsign = remoteMember.callsign
                            existing.role = remoteMember.role
                            updatedMembers[id] = existing
                        } else {
                            updatedMembers[id] = remoteMember
                        }
                    }
                    if let localId = self.localMemberId, let localMember = current.members[localId] {
                        updatedMembers[localId] = localMember
                    }
                    current.members = updatedMembers
                    self.activeRoom = current
                } else {
                    self.activeRoom = decodedRoom
                }
            }
            return
        }

        guard let json = value as? [String: Any] else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            var parsedMembers: [String: SquadMember] = [:]
            if let membersJson = json["m"] as? [String: [String: Any]] {
                for (memberId, memberData) in membersJson {
                    let callsign = memberData["csn"] as? String ?? ""
                    let role = MemberRole(rawValue: memberData["rol"] as? String ?? "") ?? .player
                    let member = SquadMember(
                        id: memberId,
                        callsign: callsign,
                        latitude: 0.0,
                        longitude: 0.0,
                        role: role
                    )
                    parsedMembers[memberId] = member
                }
            }
            if var current = self.activeRoom {
                var updatedMembers: [String: SquadMember] = [:]
                for (id, member) in parsedMembers {
                    if let localId = self.localMemberId, id == localId {
                        continue
                    }
                    if var existing = current.members[id] {
                        existing.callsign = member.callsign
                        existing.role = member.role
                        updatedMembers[id] = existing
                    } else {
                        updatedMembers[id] = member
                    }
                }
                if let localId = self.localMemberId, let localMember = current.members[localId] {
                    updatedMembers[localId] = localMember
                }
                current.members = updatedMembers
                self.activeRoom = current
            } else {
                let hostId = json["hst"] as? String ?? ""
                let capacity = json["cap"] as? Int ?? AppConstants.Subscription.freeTierMaxCapacity
                let maxTactical = json["mti"] as? Int ?? AppConstants.Subscription.freeTierMaxTacticalIndicators
                let pinHash = json["pin"] as? String ?? ""
                let expireAt = json["exp"] as? Double ?? (Date().timeIntervalSince1970 + AppConstants.Timing.Inactivity.ttlDurationSeconds)
                self.activeRoom = SquadRoom(
                    id: roomId,
                    hostId: hostId,
                    maxCapacity: capacity,
                    maxTacticalIndicators: maxTactical,
                    pinHash: pinHash,
                    expireAt: expireAt,
                    members: parsedMembers
                )
            }
        }
    }

    public func fetchMemberDetails(roomId: String, memberId: String) {
        let cleanRoomId = roomId.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let cleanMemberId = memberId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanRoomId.isEmpty, !cleanMemberId.isEmpty else { return }

        let fetchKey = "\(cleanRoomId)/\(cleanMemberId)"
        guard !pendingMemberFetches.contains(fetchKey) else { return }

        pendingMemberFetches.insert(fetchKey)

        transport.getValue(at: roomMemberPath(roomId: cleanRoomId, memberId: cleanMemberId)) { [weak self] value in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.pendingMemberFetches.remove(fetchKey)
            }
            guard let value = value else { return }

            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value),
               let remoteMember = try? JSONDecoder().decode(SquadMember.self, from: data) {
                DispatchQueue.main.async {
                    if var currentRoom = self.activeRoom, currentRoom.id == cleanRoomId {
                        if var existing = currentRoom.members[cleanMemberId] {
                            existing.callsign = remoteMember.callsign
                            existing.role = remoteMember.role
                            currentRoom.members[cleanMemberId] = existing
                        } else {
                            currentRoom.members[cleanMemberId] = remoteMember
                        }
                        self.activeRoom = currentRoom
                    }
                }
            } else if let json = value as? [String: Any], let callsign = json["csn"] as? String {
                let role = MemberRole(rawValue: json["rol"] as? String ?? "") ?? .player
                DispatchQueue.main.async {
                    if var currentRoom = self.activeRoom, currentRoom.id == cleanRoomId {
                        if var existing = currentRoom.members[cleanMemberId] {
                            existing.callsign = callsign
                            existing.role = role
                            currentRoom.members[cleanMemberId] = existing
                        } else {
                            currentRoom.members[cleanMemberId] = SquadMember(
                                id: cleanMemberId,
                                callsign: callsign,
                                latitude: 0.0,
                                longitude: 0.0,
                                role: role
                            )
                        }
                        self.activeRoom = currentRoom
                    }
                }
            }
        }
    }

    // MARK: - Telemetry Stream Subscription (Realtime Listeners)

    public func recalculateAdaptivePollingInterval() {
        guard isWristActive else {
            let newInterval = AppConstants.Timing.AdaptiveRate.wristDownPollingInterval
            if abs(self.pollingInterval - newInterval) > AppConstants.Timing.AdaptiveRate.intervalChangeEpsilon {
                self.pollingInterval = newInterval
            }
            return
        }

        let memberCount = activeRoom?.members.count ?? 0
        let grade = networkQualityMonitor.connectionGrade

        // Active rate calculated from constant bandwidth player equation: R_max(P) = R_base * min(1.0, N_threshold / P)
        let calculatedInterval = FirebaseSyncManager.solveUpdateInterval(playerCount: memberCount)

        let newInterval: TimeInterval
        if grade == .critical || grade == .offline {
            newInterval = max(AppConstants.Timing.AdaptiveRate.criticalInterval, calculatedInterval)
        } else if grade == .poor {
            newInterval = max(AppConstants.Timing.AdaptiveRate.poorInterval, calculatedInterval)
        } else {
            newInterval = calculatedInterval
        }

        if abs(self.pollingInterval - newInterval) > AppConstants.Timing.AdaptiveRate.intervalChangeEpsilon {
            self.pollingInterval = newInterval
        }
    }

    /// Updates wrist viewing activity and triggers an Instant Wake Burst upon wrist raise.
    public func setWristActive(_ active: Bool) {
        let wasActive = isWristActive
        self.isWristActive = active
        recalculateAdaptivePollingInterval()

        // Instant Wake Burst: When wrist is raised, immediately fetch telemetry to eliminate visual lag.
        // Also fires if wrist was already active but listeners aren't currently attached (safety
        // net — mirrors the original `|| telemetryPollingTimer == nil` REST-era fallback).
        if active && (!wasActive || telemetryChildAddedHandle == nil), let roomId = activeRoom?.id {
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
    /// GameStateManager.evaluatePhoneCloudClientPolicy() — invoke this only when the
    /// screen_active / active_until lease conditions allow this device to be the active cloud
    /// client. Attaches the three persistent realtime listeners, which fire immediately on
    /// attachment with the current state, then again on every subsequent change — no separate
    /// instant-fetch call needed (see §9).
    public func startTelemetryPolling(roomId: String) {
        let cleanId = roomId.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanId.isEmpty else { return }

        detachRealtimeListeners()
        attachRealtimeListeners(roomId: cleanId)
    }

    public func stopTelemetryPolling() {
        detachRealtimeListeners()
    }

    private func attachRealtimeListeners(roomId: String) {
        observedTelemetryMemberIds.removeAll()

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

        roomValueHandle = transport.observe(at: roomPath(roomId: roomId), eventType: .value) { [weak self] snapshot in
            self?.applyRoomSnapshot(snapshot.value, roomId: roomId)
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

    /// Self-echo filter (§5.B, required): applied to every incoming childAdded/childChanged
    /// event, including this device's own optimistic pre-server-confirmation echo — mirrors the
    /// `memberId == localId` skip the REST implementation already had in fetchRemoteTelemetry.
    private func handleTelemetryChildUpsert(_ snapshot: RTDBSnapshot, roomId: String) {
        let memberId = snapshot.key
        guard !memberId.hasPrefix("_"), !FirebaseSyncManager.telemetryMetadataKeys.contains(memberId) else { return }

        observedTelemetryMemberIds.insert(memberId)

        if let localId = localMemberId, memberId == localId {
            reconcileRemoteMembers(activeServerMemberIds: observedTelemetryMemberIds)
            return
        }

        if let packet = FirebaseSyncManager.parseTelemetryPacket(memberId: memberId, roomId: roomId, rawValue: snapshot.value as Any) {
            validateAndProcessPacket(packet)
            DispatchQueue.main.async { [weak self] in
                self?.onRemoteTelemetryPacketsReceived?([packet])
            }
        }

        let needsFetch = self.activeRoom?.members[memberId] == nil ||
            (self.activeRoom?.members[memberId]?.callsign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ||
            self.activeRoom?.members[memberId]?.callsign == memberId
        if needsFetch {
            self.fetchMemberDetails(roomId: roomId, memberId: memberId)
        }

        reconcileRemoteMembers(activeServerMemberIds: observedTelemetryMemberIds)
    }

    private func handleTelemetryChildRemoved(_ snapshot: RTDBSnapshot) {
        let memberId = snapshot.key
        guard !memberId.hasPrefix("_"), !FirebaseSyncManager.telemetryMetadataKeys.contains(memberId) else { return }
        observedTelemetryMemberIds.remove(memberId)
        reconcileRemoteMembers(activeServerMemberIds: observedTelemetryMemberIds)
    }

    /// Helper to parse a TelemetryPacket from compact array format or JSON dictionary
    public static func parseTelemetryPacket(memberId: String, roomId: String, rawValue: Any) -> TelemetryPacket? {
        if let array = rawValue as? [Any] {
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

    /// Reconciles remote members present in activeRoom against the set of member IDs active on the server.
    /// Remote members missing from the server payload are pruned, while the local player (localMemberId) is protected.
    public func reconcileRemoteMembers(activeServerMemberIds: Set<String>) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.reconcileRemoteMembers(activeServerMemberIds: activeServerMemberIds)
            }
            return
        }

        guard !activeServerMemberIds.isEmpty else { return }

        guard var currentRoom = activeRoom else { return }
        var roomChanged = false
        let currentMemberIds = Array(currentRoom.members.keys)

        for memberId in currentMemberIds {
            // Protect local player from being pruned
            if let localId = localMemberId, memberId == localId {
                continue
            }

            // If a remote member is missing from the server payload, remove them
            if !activeServerMemberIds.contains(memberId) {
                currentRoom.members.removeValue(forKey: memberId)
                memberLatestTimestamps.removeValue(forKey: memberId)
                memberLatestSequences.removeValue(forKey: memberId)
                roomChanged = true
            }
        }

        if roomChanged {
            self.activeRoom = currentRoom
        }
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
            var activeServerMemberIds = Set<String>()
            if let dict = jsonDict {
                for (memberId, rawValue) in dict {
                    if memberId.starts(with: "_") || FirebaseSyncManager.telemetryMetadataKeys.contains(memberId) {
                        continue
                    }
                    activeServerMemberIds.insert(memberId)
                    if let localId = self.localMemberId, memberId == localId {
                        continue
                    }
                    if let packet = FirebaseSyncManager.parseTelemetryPacket(memberId: memberId, roomId: roomId, rawValue: rawValue) {
                        batchPackets.append(packet)
                    }
                    let needsFetch = self.activeRoom?.members[memberId] == nil ||
                        (self.activeRoom?.members[memberId]?.callsign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ||
                        self.activeRoom?.members[memberId]?.callsign == memberId
                    if needsFetch {
                        self.fetchMemberDetails(roomId: roomId, memberId: memberId)
                    }
                }
            }

            if !batchPackets.isEmpty {
                self.validateAndProcessPackets(batchPackets)
                DispatchQueue.main.async {
                    self.onRemoteTelemetryPacketsReceived?(batchPackets)
                }
            }
            self.reconcileRemoteMembers(activeServerMemberIds: activeServerMemberIds)
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
    private func roomMemberPath(roomId: String, memberId: String) -> String { "r/\(roomId)/m/\(memberId)" }
    private func roomExpireAtPath(roomId: String) -> String { "r/\(roomId)/exp" }
}
