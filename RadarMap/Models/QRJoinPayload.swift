import Foundation

/// Compact payload encoded into a host's join QR code so a scanning device can auto-fill the
/// room name, PIN, and target Firebase Realtime Database URL without manual entry. See
/// BRING_YOUR_OWN_FIREBASE.md for the end-to-end host setup flow this supports.
public struct QRJoinPayload: Codable, Equatable {
    /// Room name.
    public let r: String
    /// PIN, if the room has one.
    public let p: String?
    /// Firebase Realtime Database URL the room lives on, or "" when the host is on the shared
    /// default project — deliberately never the shared project's literal URL, so a joiner scanning
    /// it gets no override and resolves the same shared default on their own end instead.
    public let d: String

    public init(roomName: String, pin: String?, databaseURL: String) {
        self.r = roomName
        self.p = (pin?.isEmpty == true) ? nil : pin
        self.d = databaseURL
    }

    public func encodedString() -> String? {
        // Without .sortedKeys, JSONEncoder doesn't guarantee stable key order across calls even
        // for identical values — that turned the same room/pin/URL into a different literal
        // string (and therefore a different QR bitmap) on every render.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ string: String) -> QRJoinPayload? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(QRJoinPayload.self, from: data)
    }
}
