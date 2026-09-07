import Foundation

// MARK: - Tactical Guide Callout Model
public enum TacticalHUDCallout: String, CaseIterable, Identifiable {
    case config = "Configuration"
    case tacticalCommands = "POI Annotations"
    case centerMap = "Center Map"
    case mapView = "Map View"
    case heartRate = "Heart Rate & Tag Out"
    case ownFirebase = "Bring Your Own Firebase"

    public var id: String { rawValue }

    public var codeTag: String {
        switch self {
        case .config: return "SYS-CFG"
        case .tacticalCommands: return "POI-ANN"
        case .centerMap: return "NAV-POS"
        case .mapView: return "HUD-MODE"
        case .heartRate: return "BIO-STAT"
        case .ownFirebase: return "NET-BYO"
        }
    }

    public var iconName: String {
        switch self {
        case .config: return "gearshape.fill"
        case .tacticalCommands: return "star.fill"
        case .centerMap: return "location.fill"
        case .mapView: return "map"
        case .heartRate: return "waveform.path.ecg"
        case .ownFirebase: return "server.rack"
        }
    }

    public var shortTitle: String {
        switch self {
        case .config: return "Settings"
        case .tacticalCommands: return "POI Annotations"
        case .centerMap: return "Center Map"
        case .mapView: return "Map View"
        case .heartRate: return "Pulse & Tag Out"
        case .ownFirebase: return "Your Own Firebase"
        }
    }

    public var actionInstruction: String {
        switch self {
        case .config:
            return "Tap the top-left gear icon to open squad management, change radar color themes, adjust refresh rates, and configure audio/haptics."
        case .tacticalCommands:
            return "Tap the top center star button to place POI annotations, rally points, hazard alerts, and broadcast team orders."
        case .centerMap:
            return "Tap the bottom-left arrow to instantly snap the viewport back to your real-time GPS coordinate and reset zoom to default."
        case .mapView:
            return "Tap the bottom-right map icon to toggle between the high-efficiency OLED vector radar and full map tiles."
        case .heartRate:
            return "Shows live HealthKit heart rate and pulse wave. Press and HOLD the pill button for 1.2s to toggle Tag Out status with your squad."
        case .ownFirebase:
            return """
            Hosting a lot of squads? Run your room on your own free Firebase project instead of \
            RadarMap's shared one, so your traffic never hits the shared project's bandwidth limits.

            1. Sign in at console.firebase.google.com and tap Add project.
            2. Open Build > Realtime Database, then Create Database.
            3. Open the Rules tab, set both .read and .write to true, and Publish — RadarMap needs \
            open read/write access on your own project to function.
            4. In Config, make sure the Custom URL switch next to the field is ON \
            (it is by default), then tap the "Enter custom URL" field and type \
            your database URL, or tap the camera icon beside it and point your phone at the URL \
            on the Firebase console webpage — no need to turn it into a QR code yourself.
            5. Flip that switch OFF anytime to fall back to the shared default without losing what \
            you typed — the field switches to "using default server".

            Not hosting yet? Tap the "SCAN TO JOIN" QR box above to scan another player's join \
            code and automatically fill in the room name, PIN, and database URL at once.
            """
        }
    }

    public var gestureHint: String {
        switch self {
        case .config: return "TAP ICON"
        case .tacticalCommands: return "TAP ICON"
        case .centerMap: return "TAP ICON"
        case .mapView: return "TAP ICON"
        case .heartRate: return "HOLD 1.2s"
        case .ownFirebase: return "TAP FIELD"
        }
    }
}
