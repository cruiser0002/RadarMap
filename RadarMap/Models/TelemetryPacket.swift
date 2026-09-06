import Foundation

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

public struct TelemetryPacket: Codable, Equatable {
    public let memberId: String
    public let roomId: String
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double?
    public let heading: Double
    public let heartRate: Double
    public let timestamp: TimeInterval   // Generation timestamp (seconds since epoch)
    public let sequenceNumber: Int64     // Monotonically increasing sequence number
    
    public init(
        memberId: String,
        roomId: String,
        latitude: Double,
        longitude: Double,
        altitude: Double? = nil,
        heading: Double = 0.0,
        heartRate: Double,
        timestamp: TimeInterval = Date().timeIntervalSince1970,
        sequenceNumber: Int64
    ) {
        self.memberId = memberId
        self.roomId = roomId
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.heading = heading
        self.heartRate = heartRate
        self.timestamp = timestamp
        self.sequenceNumber = sequenceNumber
    }
}

extension TelemetryPacket {
    /// Serializes packet to an ultra-lean 4-element compact array format:
    /// `[0: lat, 1: lng, 2: hr, 3: ts]` (4 elements).
    ///
    /// Each field is rounded to the coarsest precision that's still far finer than what the
    /// delta/heartbeat gating upstream of this call can ever act on, shaving digits off the
    /// wire JSON (and RTDB's per-byte fan-out cost) for free: 6 decimal places on lat/lng is
    /// ~0.11m, well under the 3.5m position delta gate; whole-BPM heart rate is well under the
    /// 12 BPM delta gate; millisecond timestamps are far finer than the dead-reckoning velocity
    /// math (which operates over multi-second intervals) needs.
    public func toCompactArray() -> [Any] {
        return [
            (latitude * 1_000_000).rounded() / 1_000_000,
            (longitude * 1_000_000).rounded() / 1_000_000,
            heartRate.rounded(),
            (timestamp * 1_000).rounded() / 1_000
        ]
    }
    
    /// Deserializes a telemetry packet from a compact positional array.
    /// Supports the primary 4-element schema `[lat, lng, hr, ts]`, as well as 6-element and 7-element legacy formats.
    public static func fromCompactArray(memberId: String, roomId: String, array: [Any]) -> TelemetryPacket? {
        guard array.count >= 4 else { return nil }
        
        let lat = (array[safe: 0] as? NSNumber)?.doubleValue ?? (array[safe: 0] as? Double) ?? 0.0
        let lng = (array[safe: 1] as? NSNumber)?.doubleValue ?? (array[safe: 1] as? Double) ?? 0.0
        
        if array.count == 4 {
            // Ultra-lean 4-element format: [lat, lng, hr, ts]
            let hr = (array[safe: 2] as? NSNumber)?.doubleValue ?? (array[safe: 2] as? Double) ?? 0.0
            let ts = (array[safe: 3] as? NSNumber)?.doubleValue ?? (array[safe: 3] as? Double) ?? Date().timeIntervalSince1970
            
            return TelemetryPacket(
                memberId: memberId,
                roomId: roomId,
                latitude: lat,
                longitude: lng,
                altitude: nil,
                heading: 0.0,
                heartRate: hr,
                timestamp: ts,
                sequenceNumber: 0
            )
        } else if array.count == 6 {
            // 6-element format: [lat, lng, alt, hr, seq, ts]
            let rawAlt = (array[safe: 2] as? NSNumber)?.doubleValue ?? (array[safe: 2] as? Double) ?? 0.0
            let alt = rawAlt != 0.0 ? rawAlt : nil
            let hr = (array[safe: 3] as? NSNumber)?.doubleValue ?? (array[safe: 3] as? Double) ?? 0.0
            let seq = (array[safe: 4] as? NSNumber)?.int64Value ?? (array[safe: 4] as? Int64) ?? Int64((array[safe: 4] as? Double) ?? 0)
            let ts = (array[safe: 5] as? NSNumber)?.doubleValue ?? (array[safe: 5] as? Double) ?? Date().timeIntervalSince1970
            
            return TelemetryPacket(
                memberId: memberId,
                roomId: roomId,
                latitude: lat,
                longitude: lng,
                altitude: alt,
                heading: 0.0,
                heartRate: hr,
                timestamp: ts,
                sequenceNumber: seq
            )
        } else {
            // Legacy 7-element format: [lat, lng, alt, hdg, hr, seq, ts]
            let rawAlt = (array[safe: 2] as? NSNumber)?.doubleValue ?? (array[safe: 2] as? Double) ?? 0.0
            let alt = rawAlt != 0.0 ? rawAlt : nil
            let hdg = (array[safe: 3] as? NSNumber)?.doubleValue ?? (array[safe: 3] as? Double) ?? 0.0
            let hr = (array[safe: 4] as? NSNumber)?.doubleValue ?? (array[safe: 4] as? Double) ?? 0.0
            let seq = (array[safe: 5] as? NSNumber)?.int64Value ?? (array[safe: 5] as? Int64) ?? Int64((array[safe: 5] as? Double) ?? 0)
            let ts = (array[safe: 6] as? NSNumber)?.doubleValue ?? (array[safe: 6] as? Double) ?? Date().timeIntervalSince1970
            
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
    }
}
