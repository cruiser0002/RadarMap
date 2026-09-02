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
            return "Room not found"
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
    
    // Tactical indicators bandwidth-conserving change tracker
    public var lastKnownTacticalUpdatedAt: TimeInterval = 0.0
    public var lastTacticalPollTimestamp: TimeInterval = 0.0
    
    /// Unacknowledged tactical indicators awaiting server ACK (maps indicatorId -> local placement timestamp)
    public private(set) var unacknowledgedIndicators: [String: TimeInterval] = [:]
    
    private var telemetryPollingTimer: AnyCancellable?
    public var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 20.0
        
        // Allow concurrent connections to avoid serial head-of-line blocking between uploads and polling
        config.httpMaximumConnectionsPerHost = 4
        config.httpShouldUsePipelining = true
        
        return URLSession(configuration: config)
    }()
    
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
    
    private func executeTelemetryWrite(roomId: String, memberId: String, packet: TelemetryPacket, payload: [Any], isReconnectFlush: Bool = false) {
        guard let url = URL(string: "\(databaseURL)/telemetry/\(roomId)/\(memberId).json") else { return }
        var request = createRequest(url: url, method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else { return }
        request.httpBody = jsonData
        
        _uploadMetrics.telemetryWritesSubmitted += 1
        
        let startTime = Date()
        urlSession.dataTask(with: request) { [weak self] _, response, error in
            guard let self = self else { return }
            var isSuccess = false
            if error == nil, let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) {
                isSuccess = true
            }
            
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
        }.resume()
    }
    
    private func flushPendingTelemetryLocked() {
        guard let pending = _pendingTelemetry else { return }
        _uploadMetrics.reconnectTriggeredTelemetryFlushes += 1
        #if DEBUG
        print("[FirebaseSyncManager] Executing reconnect telemetry write to /telemetry/\(pending.roomId)/\(pending.memberId).json")
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
        
        guard let url = URL(string: "\(databaseURL)/rooms/\(cleanId).json") else {
            let err = FirebaseSyncError.networkError("Invalid URL")
            DispatchQueue.main.async {
                self.errorMessage = err.localizedDescription
                completion?(.failure(err))
            }
            return
        }
        
        // 1. Check if room already exists on server
        urlSession.dataTask(with: createRequest(url: url)) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                let syncError = FirebaseSyncError.networkError(error.localizedDescription)
                DispatchQueue.main.async {
                    self.errorMessage = syncError.localizedDescription
                    completion?(.failure(syncError))
                }
                return
            }
            
            if let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode),
               let data = data, !data.isEmpty,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let existingId = json["id"] as? String, !existingId.isEmpty {
                // Room exists already
                let err = FirebaseSyncError.roomAlreadyExists
                DispatchQueue.main.async {
                    self.errorMessage = err.localizedDescription
                    completion?(.failure(err))
                }
                return
            }
            
            // 2. Room does not exist -> Create room node first, then initialize telemetry & tactical subrooms
            var request = self.createRequest(url: url, method: "PUT")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let encoder = JSONEncoder()
            guard let payload = try? encoder.encode(room) else {
                let err = FirebaseSyncError.networkError("Serialization failure")
                DispatchQueue.main.async {
                    self.errorMessage = err.localizedDescription
                    completion?(.failure(err))
                }
                return
            }
            request.httpBody = payload
            
            self.urlSession.dataTask(with: request) { [weak self] _, response, error in
                guard let self = self else { return }
                
                if let error = error {
                    let syncError = FirebaseSyncError.networkError(error.localizedDescription)
                    DispatchQueue.main.async {
                        self.errorMessage = syncError.localizedDescription
                        completion?(.failure(syncError))
                    }
                    return
                }
                
                guard let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    let syncError = FirebaseSyncError.networkError("Server returned code \(code)")
                    DispatchQueue.main.async {
                        self.errorMessage = syncError.localizedDescription
                        completion?(.failure(syncError))
                    }
                    return
                }
                
                // Room created successfully -> Now initialize subnodes with clean TTL metadata
                let initGroup = DispatchGroup()
                let telTtlPayload: [String: Any] = ["expireAt": room.expireAt]
                let tactTtlPayload: [String: Any] = ["updatedAt": room.createdAt, "expireAt": room.expireAt]
                
                if let telData = try? JSONSerialization.data(withJSONObject: telTtlPayload),
                   let telUrl = URL(string: "\(self.databaseURL)/telemetry/\(cleanId).json") {
                    var putTelReq = self.createRequest(url: telUrl, method: "PUT")
                    putTelReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    putTelReq.httpBody = telData
                    initGroup.enter()
                    self.urlSession.dataTask(with: putTelReq) { _, _, _ in
                        initGroup.leave()
                    }.resume()
                }
                
                if let tactData = try? JSONSerialization.data(withJSONObject: tactTtlPayload),
                   let tactMetaUrl = URL(string: "\(self.databaseURL)/tactical/\(cleanId)/meta.json") {
                    var putTactReq = self.createRequest(url: tactMetaUrl, method: "PUT")
                    putTactReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    putTactReq.httpBody = tactData
                    initGroup.enter()
                    self.urlSession.dataTask(with: putTactReq) { _, _, _ in
                        initGroup.leave()
                    }.resume()
                }
                
                if let tactData = try? JSONSerialization.data(withJSONObject: tactTtlPayload),
                   let tactLegacyUrl = URL(string: "\(self.databaseURL)/tactical/\(cleanId).json") {
                    var putTactReq = self.createRequest(url: tactLegacyUrl, method: "PUT")
                    putTactReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    putTactReq.httpBody = tactData
                    initGroup.enter()
                    self.urlSession.dataTask(with: putTactReq) { _, _, _ in
                        initGroup.leave()
                    }.resume()
                }
                
                initGroup.notify(queue: .main) {
                    self.activeRoom = room
                    self.isConnected = true
                    self.memberLatestTimestamps.removeAll()
                    self.memberLatestSequences.removeAll()
                    self.lastKnownTacticalUpdatedAt = 0.0
                    self.startTelemetryPolling(roomId: room.id)
                    completion?(.success(room))
                }
            }.resume()
        }.resume()
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
        
        guard let url = URL(string: "\(databaseURL)/rooms/\(cleanId).json") else {
            let err = FirebaseSyncError.networkError("Invalid URL")
            DispatchQueue.main.async {
                self.errorMessage = err.localizedDescription
                completion?(.failure(err))
            }
            return
        }
        
        urlSession.dataTask(with: createRequest(url: url)) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                let syncError = FirebaseSyncError.networkError(error.localizedDescription)
                DispatchQueue.main.async {
                    self.errorMessage = syncError.localizedDescription
                    completion?(.failure(syncError))
                }
                return
            }
            
            guard let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode),
                  let data = data, !data.isEmpty,
                  let jsonString = String(data: data, encoding: .utf8), jsonString != "null" else {
                DispatchQueue.main.async {
                    self.errorMessage = FirebaseSyncError.roomNotFound.localizedDescription
                    completion?(.failure(.roomNotFound))
                }
                return
            }
            
            guard var room = try? JSONDecoder().decode(SquadRoom.self, from: data) else {
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
            
            // Validate PIN if required
            if room.hasPin {
                let inputHash = FirebaseSyncManager.hashPin(pin ?? "", salt: cleanId)
                let expectedHash = room.pinHash ?? ""
                if inputHash != expectedHash {
                    DispatchQueue.main.async {
                        self.errorMessage = FirebaseSyncError.incorrectPin.localizedDescription
                        completion?(.failure(.incorrectPin))
                    }
                    return
                }
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
                self.lastKnownTacticalUpdatedAt = 0.0
                self.startTelemetryPolling(roomId: cleanId)
                completion?(.success(room))
            }
        }.resume()
    }
    
    public func connectToRoom(_ room: SquadRoom) {
        self.activeRoom = room
        self.isConnected = true
        self.memberLatestTimestamps.removeAll()
        self.memberLatestSequences.removeAll()
        self.lastKnownTacticalUpdatedAt = 0.0
        
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
        self.lastKnownTacticalUpdatedAt = 0.0
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
        self.lastKnownTacticalUpdatedAt = 0.0
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
        if let telUrl = URL(string: "\(databaseURL)/telemetry/\(roomId).json") {
            let req = createRequest(url: telUrl, method: "DELETE")
            purgeGroup.enter()
            urlSession.dataTask(with: req) { _, _, _ in
                purgeGroup.leave()
            }.resume()
        }
        
        // 2. Delete tactical indicators node
        if let tactUrl = URL(string: "\(databaseURL)/tactical/\(roomId).json") {
            let req = createRequest(url: tactUrl, method: "DELETE")
            purgeGroup.enter()
            urlSession.dataTask(with: req) { _, _, _ in
                purgeGroup.leave()
            }.resume()
        }
        
        // 3. Delete room node after telemetry & tactical nodes have been purged
        purgeGroup.notify(queue: .global()) { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion?(true) }
                return
            }
            
            if let roomUrl = URL(string: "\(self.databaseURL)/rooms/\(roomId).json") {
                let req = self.createRequest(url: roomUrl, method: "DELETE")
                self.urlSession.dataTask(with: req) { _, _, _ in
                    DispatchQueue.main.async {
                        self.resetLocalSessionAndIcons()
                        completion?(true)
                    }
                }.resume()
            } else {
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
        if let memberUrl = URL(string: "\(databaseURL)/rooms/\(roomId)/members/\(memberId).json") {
            let req = createRequest(url: memberUrl, method: "DELETE")
            group.enter()
            urlSession.dataTask(with: req) { _, _, _ in
                group.leave()
            }.resume()
        }
        
        // 2. Delete player telemetry entry
        if let telUrl = URL(string: "\(databaseURL)/telemetry/\(roomId)/\(memberId).json") {
            let req = createRequest(url: telUrl, method: "DELETE")
            group.enter()
            urlSession.dataTask(with: req) { _, _, _ in
                group.leave()
            }.resume()
        }
        
        // 3. Delete player squad order icons from tactical node
        if let tactUrl = URL(string: "\(databaseURL)/tactical/\(roomId).json") {
            group.enter()
            let getReq = createRequest(url: tactUrl, method: "GET")
            urlSession.dataTask(with: getReq) { [weak self] data, _, _ in
                defer { group.leave() }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                
                var deletedAny = false
                let sourceDict = (json["indicators"] as? [String: Any]) ?? json
                for (indicatorId, val) in sourceDict {
                    if indicatorId == "updatedAt" || indicatorId == "expireAt" || indicatorId == "createdAt" || indicatorId == "lastActivityTimestamp" || indicatorId == "ttl" || indicatorId == "meta" || indicatorId.starts(with: "_") { continue }
                    guard let indDict = val as? [String: Any] else { continue }
                    let placedBy = indDict["placedByMemberId"] as? String
                    let typeStr = indDict["type"] as? String ?? ""
                    let categoryStr = indDict["category"] as? String ?? ""
                    
                    let isSquadOrder = categoryStr == "squadOrder" ||
                                       typeStr == "watchHere" ||
                                       typeStr == "goHere" ||
                                       typeStr == "attackHere" ||
                                       typeStr == "protectHere"
                    
                    if placedBy == memberId && isSquadOrder {
                        deletedAny = true
                        // Delete from /indicators
                        if let delUrl = URL(string: "\(self?.databaseURL ?? "")/tactical/\(roomId)/indicators/\(indicatorId).json") {
                            let delReq = self?.createRequest(url: delUrl, method: "DELETE") ?? URLRequest(url: delUrl)
                            group.enter()
                            self?.urlSession.dataTask(with: delReq) { _, _, _ in
                                group.leave()
                            }.resume()
                        }
                        // Delete from legacy root
                        if let delUrl = URL(string: "\(self?.databaseURL ?? "")/tactical/\(roomId)/\(indicatorId).json") {
                            let delReq = self?.createRequest(url: delUrl, method: "DELETE") ?? URLRequest(url: delUrl)
                            group.enter()
                            self?.urlSession.dataTask(with: delReq) { _, _, _ in
                                group.leave()
                            }.resume()
                        }
                    }
                }
                
                if deletedAny {
                    self?.touchTacticalUpdatedAt(roomId: roomId)
                }
            }.resume()
        }
        
        group.notify(queue: .main) { [weak self] in
            self?.resetLocalSessionAndIcons()
            completion?(true)
        }
    }
    
    public func removePlayerEntry(roomId: String, memberId: String, completion: ((Bool) -> Void)? = nil) {
        logoutPlayer(roomId: roomId, memberId: memberId, completion: completion)
    }
    
    public func touchRoomActivity(roomId: String) {
        let now = Date().timeIntervalSince1970
        guard let url = URL(string: "\(databaseURL)/rooms/\(roomId)/lastActivityTimestamp.json") else { return }
        var request = createRequest(url: url, method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let data = try? JSONSerialization.data(withJSONObject: now) else { return }
        request.httpBody = data
        urlSession.dataTask(with: request) { _, response, error in
            if let error = error {
                print("[FirebaseSyncManager] touchRoomActivity failed: \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                print("[FirebaseSyncManager] touchRoomActivity unexpected HTTP \(http.statusCode)")
            }
        }.resume()
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
        guard let url = URL(string: "\(databaseURL)/rooms/\(roomId)/members/\(member.id).json") else { return }
        var request = createRequest(url: url, method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload: [String: Any] = [
            "id": member.id,
            "callsign": member.callsign,
            "isHost": member.isHost
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        request.httpBody = data
        urlSession.dataTask(with: request).resume()
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
        guard let url = URL(string: "\(databaseURL)/tactical/\(roomId)/indicators/\(indicator.id).json") else { return }
        var request = createRequest(url: url, method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        guard let data = try? JSONSerialization.data(withJSONObject: indicator.compactArray) else { return }
        request.httpBody = data
        
        telemetrySchedulerQueue.async {
            self._uploadMetrics.tacticalWritesSubmitted += 1
        }
        
        urlSession.dataTask(with: request) { [weak self] _, response, error in
            guard let self = self else { return }
            var success = false
            if error == nil, let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) {
                success = true
            }
            self.telemetrySchedulerQueue.async {
                if success {
                    self._uploadMetrics.tacticalWritesCompleted += 1
                } else {
                    self._uploadMetrics.tacticalWritesFailed += 1
                }
            }
        }.resume()
        touchTacticalUpdatedAt(roomId: roomId)
    }
    
    private func deleteIndicatorFromFirebase(roomId: String, indicatorId: String) {
        // Delete from /indicators/{indicatorId}
        guard let url = URL(string: "\(databaseURL)/tactical/\(roomId)/indicators/\(indicatorId).json") else { return }
        let request = createRequest(url: url, method: "DELETE")
        
        telemetrySchedulerQueue.async {
            self._uploadMetrics.tacticalWritesSubmitted += 1
        }
        
        urlSession.dataTask(with: request) { [weak self] _, response, error in
            guard let self = self else { return }
            var success = false
            if error == nil, let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) {
                success = true
            }
            self.telemetrySchedulerQueue.async {
                if success {
                    self._uploadMetrics.tacticalWritesCompleted += 1
                } else {
                    self._uploadMetrics.tacticalWritesFailed += 1
                }
            }
        }.resume()
        
        // Also cleanup legacy root indicator node if present for backward compatibility
        if let legacyUrl = URL(string: "\(databaseURL)/tactical/\(roomId)/\(indicatorId).json") {
            let legacyReq = createRequest(url: legacyUrl, method: "DELETE")
            urlSession.dataTask(with: legacyReq).resume()
        }
        
        touchTacticalUpdatedAt(roomId: roomId)
    }
    
    public func touchTacticalUpdatedAt(roomId: String) {
        let now = Date().timeIntervalSince1970
        self.lastKnownTacticalUpdatedAt = now
        
        // Write to new /meta/updatedAt
        if let metaUrl = URL(string: "\(databaseURL)/tactical/\(roomId)/meta/updatedAt.json") {
            var request = createRequest(url: metaUrl, method: "PUT")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let data = try? JSONEncoder().encode(now) {
                request.httpBody = data
                telemetrySchedulerQueue.async {
                    self._uploadMetrics.tacticalWritesSubmitted += 1
                }
                urlSession.dataTask(with: request) { [weak self] _, response, error in
                    guard let self = self else { return }
                    var success = false
                    if error == nil, let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) {
                        success = true
                    }
                    self.telemetrySchedulerQueue.async {
                        if success {
                            self._uploadMetrics.tacticalWritesCompleted += 1
                        } else {
                            self._uploadMetrics.tacticalWritesFailed += 1
                        }
                    }
                }.resume()
            }
        }
        
        // Also write to legacy /updatedAt for backward compatibility
        if let legacyUrl = URL(string: "\(databaseURL)/tactical/\(roomId)/updatedAt.json") {
            var req = createRequest(url: legacyUrl, method: "PUT")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let data = try? JSONEncoder().encode(now) {
                req.httpBody = data
                urlSession.dataTask(with: req).resume()
            }
        }
    }
    
    /// Bandwidth-conserving check: queries updatedAt first. Only downloads the full indicator payload when a change is detected.
    public func fetchTacticalIndicatorsIfChanged(roomId: String, force: Bool = false) {
        guard let updateUrl = URL(string: "\(databaseURL)/tactical/\(roomId)/meta/updatedAt.json") else { return }
        
        urlSession.dataTask(with: createRequest(url: updateUrl)) { [weak self] data, _, error in
            guard let self = self else { return }
            var remoteUpdatedAt: Double = 0.0
            if let data = data, error == nil {
                remoteUpdatedAt = (try? JSONSerialization.jsonObject(with: data) as? Double) ?? (try? JSONDecoder().decode(Double.self, from: data)) ?? 0.0
            }
            
            // Fallback to legacy updatedAt if meta/updatedAt is not found
            if remoteUpdatedAt == 0.0, let legacyUrl = URL(string: "\(self.databaseURL)/tactical/\(roomId)/updatedAt.json") {
                self.urlSession.dataTask(with: self.createRequest(url: legacyUrl)) { [weak self] legData, _, _ in
                    guard let self = self, let legData = legData else { return }
                    let legTime = (try? JSONSerialization.jsonObject(with: legData) as? Double) ?? (try? JSONDecoder().decode(Double.self, from: legData)) ?? 0.0
                    if force || (legTime > self.lastKnownTacticalUpdatedAt && legTime > 0) {
                        self.fetchFullTacticalCollection(roomId: roomId, remoteUpdatedAt: legTime)
                    }
                }.resume()
                return
            }
            
            if force || (remoteUpdatedAt > self.lastKnownTacticalUpdatedAt && remoteUpdatedAt > 0) {
                self.fetchFullTacticalCollection(roomId: roomId, remoteUpdatedAt: remoteUpdatedAt)
            }
        }.resume()
    }
    
    private func fetchFullTacticalCollection(roomId: String, remoteUpdatedAt: Double) {
        guard let url = URL(string: "\(databaseURL)/tactical/\(roomId).json") else { return }
        
        urlSession.dataTask(with: createRequest(url: url)) { [weak self] data, _, error in
            guard let self = self, let data = data, error == nil else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async {
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
                    self.lastKnownTacticalUpdatedAt = max(self.lastKnownTacticalUpdatedAt, remoteUpdatedAt)
                }
                return
            }
            
            let metadataKeys: Set<String> = ["createdAt", "expireAt", "lastActivityTimestamp", "ttl", "updatedAt", "meta", "uts", "exp", "cts", "ats"]
            var decodedIndicators: [String: TacticalIndicator] = [:]
            
            // Check for new schema: indicators subtree under /tactical/{roomId}/indicators or direct
            let indicatorsSource = (json["indicators"] as? [String: Any]) ?? json
            for (key, val) in indicatorsSource {
                if key.starts(with: "_") || metadataKeys.contains(key) { continue }
                if let ind = TacticalIndicator.parse(id: key, rawValue: val) {
                    if !ind.isExpired {
                        decodedIndicators[ind.id] = ind
                    }
                }
            }

            
            DispatchQueue.main.async {
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
                    
                    current.indicators = mergedIndicators
                    self.activeRoom = current
                }
                self.lastKnownTacticalUpdatedAt = max(self.lastKnownTacticalUpdatedAt, remoteUpdatedAt)
            }
        }.resume()
    }
    
    public func fetchRoomDetails(roomId: String) {
        // Fetch tactical indicators if changed or first load
        fetchTacticalIndicatorsIfChanged(roomId: roomId, force: true)
        
        guard let url = URL(string: "\(databaseURL)/rooms/\(roomId).json") else { return }
        
        urlSession.dataTask(with: createRequest(url: url)) { [weak self] data, _, error in
            guard let self = self, let data = data, error == nil else { return }
            
            // Try decoding as SquadRoom or parsing members JSON dictionary
            if let decodedRoom = try? JSONDecoder().decode(SquadRoom.self, from: data) {
                DispatchQueue.main.async {
                    if var current = self.activeRoom {
                        var updatedMembers: [String: SquadMember] = [:]
                        for (id, remoteMember) in decodedRoom.members {
                            if var existing = current.members[id] {
                                existing.callsign = remoteMember.callsign
                                existing.isHost = remoteMember.isHost
                                updatedMembers[id] = existing
                            } else {
                                updatedMembers[id] = remoteMember
                            }
                        }
                        if let localId = self.localMemberId, let localMember = current.members[localId], updatedMembers[localId] == nil {
                            updatedMembers[localId] = localMember
                        }
                        current.members = updatedMembers
                        if !decodedRoom.indicators.isEmpty {
                            current.indicators = decodedRoom.indicators
                        }
                        self.activeRoom = current
                    } else {
                        self.activeRoom = decodedRoom
                    }
                }
            } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                DispatchQueue.main.async {
                    var parsedMembers: [String: SquadMember] = [:]
                    if let membersJson = json["members"] as? [String: [String: Any]] {
                        for (memberId, memberData) in membersJson {
                            let callsign = memberData["callsign"] as? String ?? ""
                            let isHost = memberData["isHost"] as? Bool ?? false
                            let member = SquadMember(
                                id: memberId,
                                callsign: callsign,
                                latitude: 0.0,
                                longitude: 0.0,
                                isHost: isHost
                            )
                            parsedMembers[memberId] = member
                        }
                    }
                    if var current = self.activeRoom {
                        var updatedMembers: [String: SquadMember] = [:]
                        for (id, member) in parsedMembers {
                            if var existing = current.members[id] {
                                existing.callsign = member.callsign
                                existing.isHost = member.isHost
                                updatedMembers[id] = existing
                            } else {
                                updatedMembers[id] = member
                            }
                        }
                        if let localId = self.localMemberId, let localMember = current.members[localId], updatedMembers[localId] == nil {
                            updatedMembers[localId] = localMember
                        }
                        current.members = updatedMembers
                        self.activeRoom = current
                    } else {
                        let hostId = json["hostId"] as? String ?? ""
                        let capacity = json["maxCapacity"] as? Int ?? AppConstants.Subscription.freeTierMaxCapacity
                        let hasPin = json["hasPin"] as? Bool ?? false
                        let pinHash = json["pinHash"] as? String
                        let createdAt = json["createdAt"] as? Double ?? Date().timeIntervalSince1970
                        let lastActivity = json["lastActivityTimestamp"] as? Double ?? createdAt
                        let expireAt = json["expireAt"] as? Double ?? (createdAt + 7 * 86400)
                        self.activeRoom = SquadRoom(
                            id: roomId,
                            hostId: hostId,
                            maxCapacity: capacity,
                            hasPin: hasPin,
                            pinHash: pinHash,
                            createdAt: createdAt,
                            lastActivityTimestamp: lastActivity,
                            expireAt: expireAt,
                            members: parsedMembers
                        )
                    }
                }
            }
        }.resume()
    }
    
    public func fetchMemberDetails(roomId: String, memberId: String) {
        let cleanRoomId = roomId.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let cleanMemberId = memberId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanRoomId.isEmpty, !cleanMemberId.isEmpty else { return }
        
        let fetchKey = "\(cleanRoomId)/\(cleanMemberId)"
        guard !pendingMemberFetches.contains(fetchKey) else { return }
        guard let url = URL(string: "\(databaseURL)/rooms/\(cleanRoomId)/members/\(cleanMemberId).json") else { return }
        
        pendingMemberFetches.insert(fetchKey)
        
        urlSession.dataTask(with: createRequest(url: url)) { [weak self] data, response, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.pendingMemberFetches.remove(fetchKey)
            }
            guard let data = data, error == nil,
                  let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) else {
                return
            }
            
            if let remoteMember = try? JSONDecoder().decode(SquadMember.self, from: data) {
                DispatchQueue.main.async {
                    if var currentRoom = self.activeRoom, currentRoom.id == cleanRoomId {
                        if var existing = currentRoom.members[cleanMemberId] {
                            existing.callsign = remoteMember.callsign
                            existing.isHost = remoteMember.isHost
                            currentRoom.members[cleanMemberId] = existing
                        } else {
                            currentRoom.members[cleanMemberId] = remoteMember
                        }
                        self.activeRoom = currentRoom
                    }
                }
            } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let callsign = json["callsign"] as? String {
                let isHost = json["isHost"] as? Bool ?? false
                DispatchQueue.main.async {
                    if var currentRoom = self.activeRoom, currentRoom.id == cleanRoomId {
                        if var existing = currentRoom.members[cleanMemberId] {
                            existing.callsign = callsign
                            existing.isHost = isHost
                            currentRoom.members[cleanMemberId] = existing
                        } else {
                            currentRoom.members[cleanMemberId] = SquadMember(
                                id: cleanMemberId,
                                callsign: callsign,
                                latitude: 0.0,
                                longitude: 0.0,
                                isHost: isHost
                            )
                        }
                        self.activeRoom = currentRoom
                    }
                }
            }
        }.resume()
    }
    
    // MARK: - Telemetry Stream Polling / Subscription
    
    public func recalculateAdaptivePollingInterval() {
        guard isWristActive else {
            let newInterval = AppConstants.Timing.AdaptiveRate.wristDownPollingInterval
            if abs(self.pollingInterval - newInterval) > AppConstants.Timing.AdaptiveRate.intervalChangeEpsilon {
                self.pollingInterval = newInterval
                if let roomId = activeRoom?.id {
                    startTelemetryPolling(roomId: roomId)
                }
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
            if let roomId = activeRoom?.id {
                startTelemetryPolling(roomId: roomId)
            }
        }
    }
    
    /// Updates wrist viewing activity and triggers an Instant Wake Burst upon wrist raise.
    public func setWristActive(_ active: Bool) {
        let wasActive = isWristActive
        self.isWristActive = active
        recalculateAdaptivePollingInterval()
        
        // Instant Wake Burst: When wrist is raised, immediately fetch telemetry to eliminate visual lag
        if active && (!wasActive || telemetryPollingTimer == nil), let roomId = activeRoom?.id {
            fetchRemoteTelemetry(roomId: roomId)
        }
    }
    
    /// Explicit awake trigger for gestures (e.g. double tap, screen tap, digital crown rotation)
    public func triggerWakeBurst() {
        setWristActive(true)
        if let roomId = activeRoom?.id {
            fetchRemoteTelemetry(roomId: roomId)
        }
    }
    
    public func startTelemetryPolling(roomId: String) {
        let cleanId = roomId.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanId.isEmpty else { return }
        
        telemetryPollingTimer?.cancel()
        telemetryPollingTimer = nil
        
        // Instant initial fetch
        fetchRemoteTelemetry(roomId: cleanId)
        fetchTacticalIndicatorsIfChanged(roomId: cleanId, force: true)
        
        // Client-driven adaptive polling timer
        telemetryPollingTimer = Timer.publish(every: pollingInterval, on: .main, in: .common)
            .autoconnect()
            .receive(on: DispatchQueue.global(qos: .utility))
            .sink { [weak self] _ in
                self?.fetchRemoteTelemetry(roomId: cleanId)
            }
    }
    
    public func stopTelemetryPolling() {
        telemetryPollingTimer?.cancel()
        telemetryPollingTimer = nil
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
    
    public func fetchRemoteTelemetry(roomId: String) {
        // Change-only check for tactical indicators throttled to once every 5.0 seconds
        let now = Date().timeIntervalSince1970
        if now - lastTacticalPollTimestamp >= 5.0 {
            lastTacticalPollTimestamp = now
            fetchTacticalIndicatorsIfChanged(roomId: roomId)
        }
        
        guard let url = URL(string: "\(databaseURL)/telemetry/\(roomId).json") else { return }
        
        urlSession.dataTask(with: createRequest(url: url)) { [weak self] data, response, error in
            guard let self = self, let data = data, error == nil else { return }
            
            if let httpRes = response as? HTTPURLResponse, !(200...299).contains(httpRes.statusCode) {
                return
            }
            
            let metadataKeys: Set<String> = ["createdAt", "expireAt", "lastActivityTimestamp", "ttl", "updatedAt"]
            let jsonDict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            
            var batchPackets: [TelemetryPacket] = []
            var activeServerMemberIds = Set<String>()
            if let dict = jsonDict {
                for (memberId, rawValue) in dict {
                    if memberId.starts(with: "_") || metadataKeys.contains(memberId) {
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
        }.resume()
    }
    
    public func createRequest(url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        applyAuth(to: &request)
        return request
    }
    
    public func applyAuth(to request: inout URLRequest) {
        if let token = authToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }
}
