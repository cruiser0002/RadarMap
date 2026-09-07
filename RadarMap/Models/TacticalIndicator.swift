import Foundation
import CoreLocation
import CryptoKit

/// Category of tactical indicator
public enum TacticalIndicatorCategory: String, Codable, CaseIterable, Identifiable {
    case squadOrder = "squadOrder"
    case enemyIndicator = "enemyIndicator"
    case environment = "environment"
    
    public var id: String { rawValue }
    
    public var title: String {
        switch self {
        case .squadOrder:
            return "Team Orders"
        case .enemyIndicator:
            return "Tactical"
        case .environment:
            return "Environment"
        }
    }
}

/// Specific type of indicator / order
public enum TacticalIndicatorType: String, Codable, CaseIterable, Identifiable {
    // Squad Orders
    case watchHere = "watchHere"
    case goHere = "goHere"
    case attackHere = "attackHere"
    case protectHere = "protectHere"
    case flag = "flag"
    case point1 = "point1"
    case point2 = "point2"
    case point3 = "point3"
    
    // Enemy Indicators
    case infantry = "infantry"
    case vehicle = "vehicle"
    case armor = "armor"
    case drone = "drone"
    
    // Environment Indicators
    case water = "water"
    case hazard = "hazard"
    case fire = "fire"
    case snow = "snow"
    case closure = "closure"
    case emergency = "emergency"
    
    // Backward compatibility aliases
    public static var lightVehicle: TacticalIndicatorType { .vehicle }
    public static var heavyVehicle: TacticalIndicatorType { .armor }
    
    public var id: String { rawValue }
    
    public var category: TacticalIndicatorCategory {
        switch self {
        case .watchHere, .goHere, .attackHere, .protectHere, .flag,
             .point1, .point2, .point3:
            return .squadOrder
        case .infantry, .vehicle, .armor, .drone:
            return .enemyIndicator
        case .water, .hazard, .fire, .snow, .closure, .emergency:
            return .environment
        }
    }
    
    public var title: String {
        switch self {
        case .watchHere:
            return "Watch"
        case .goHere:
            return "Go"
        case .attackHere:
            return "Target"
        case .protectHere:
            return "Protect"
        case .flag:
            return "Flag"
        case .point1:
            return "1"
        case .point2:
            return "2"
        case .point3:
            return "3"
        case .infantry:
            return "Personnel"
        case .vehicle:
            return "Vehicle"
        case .armor:
            return "Armor"
        case .drone:
            return "Drone"
        case .water:
            return "Water"
        case .hazard:
            return "Hazard"
        case .fire:
            return "Fire"
        case .snow:
            return "Snow"
        case .closure:
            return "Closure"
        case .emergency:
            return "Emergency"
        }
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "vehicle", "lightVehicle":
            self = .vehicle
        case "armor", "heavyVehicle":
            self = .armor
        default:
            if let type = TacticalIndicatorType(rawValue: raw) {
                self = type
            } else if let type = TacticalIndicatorType.fromCode(raw) {
                self = type
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown TacticalIndicatorType: \(raw)")
            }
        }
    }
    
    /// 3-letter shorthand code for compact network payloads
    public var code: String {
        switch self {
        case .watchHere: return AppConstants.Encoding.Tactical.watchHere
        case .goHere: return AppConstants.Encoding.Tactical.goHere
        case .attackHere: return AppConstants.Encoding.Tactical.attackHere
        case .protectHere: return AppConstants.Encoding.Tactical.protectHere
        case .flag: return AppConstants.Encoding.Tactical.flag
        case .point1: return AppConstants.Encoding.Tactical.point1
        case .point2: return AppConstants.Encoding.Tactical.point2
        case .point3: return AppConstants.Encoding.Tactical.point3
        case .infantry: return AppConstants.Encoding.Tactical.infantry
        case .vehicle: return AppConstants.Encoding.Tactical.vehicle
        case .armor: return AppConstants.Encoding.Tactical.armor
        case .drone: return AppConstants.Encoding.Tactical.drone
        case .water: return AppConstants.Encoding.Tactical.water
        case .hazard: return AppConstants.Encoding.Tactical.hazard
        case .fire: return AppConstants.Encoding.Tactical.fire
        case .snow: return AppConstants.Encoding.Tactical.snow
        case .closure: return AppConstants.Encoding.Tactical.closure
        case .emergency: return AppConstants.Encoding.Tactical.emergency
        }
    }
    
    public static func fromCode(_ code: String) -> TacticalIndicatorType? {
        switch code {
        case AppConstants.Encoding.Tactical.watchHere, "watchHere": return .watchHere
        case AppConstants.Encoding.Tactical.goHere, "goHere": return .goHere
        case AppConstants.Encoding.Tactical.attackHere, "attackHere": return .attackHere
        case AppConstants.Encoding.Tactical.protectHere, "protectHere": return .protectHere
        case AppConstants.Encoding.Tactical.flag, "flag": return .flag
        case AppConstants.Encoding.Tactical.point1, "point1": return .point1
        case AppConstants.Encoding.Tactical.point2, "point2": return .point2
        case AppConstants.Encoding.Tactical.point3, "point3": return .point3
        case AppConstants.Encoding.Tactical.infantry, "infantry": return .infantry
        case AppConstants.Encoding.Tactical.vehicle, "vehicle", "lightVehicle": return .vehicle
        case AppConstants.Encoding.Tactical.armor, "armor", "heavyVehicle": return .armor
        case AppConstants.Encoding.Tactical.drone, "drone": return .drone
        case AppConstants.Encoding.Tactical.water, "water": return .water
        case AppConstants.Encoding.Tactical.hazard, "hazard": return .hazard
        case AppConstants.Encoding.Tactical.fire, "fire": return .fire
        case AppConstants.Encoding.Tactical.snow, "snow": return .snow
        case AppConstants.Encoding.Tactical.closure, "closure": return .closure
        case AppConstants.Encoding.Tactical.emergency, "emergency": return .emergency
        default: return nil
        }
    }
}

/// Active placed tactical indicator
public struct TacticalIndicator: Identifiable, Codable, Equatable {
    public let id: String
    public let type: TacticalIndicatorType
    public var latitude: Double
    public var longitude: Double
    public let placedByMemberId: String
    public var placedByCallsign: String?
    public let timestamp: TimeInterval
    public let expiresAt: TimeInterval?
    
    public var coordinate: CLLocationCoordinate2D {
        get { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
        set {
            latitude = newValue.latitude
            longitude = newValue.longitude
        }
    }
    
    public var category: TacticalIndicatorCategory {
        type.category
    }
    
    public var isExpired: Bool {
        guard let expiresAt = expiresAt else { return false }
        return Date().timeIntervalSince1970 >= expiresAt
    }
    
    public init(
        id: String = GameStateManager.generateShortMemberId(),
        type: TacticalIndicatorType,
        coordinate: CLLocationCoordinate2D,
        placedByMemberId: String,
        placedByCallsign: String? = nil,
        timestamp: TimeInterval = Date().timeIntervalSince1970,
        expiresAt: TimeInterval? = nil
    ) {
        self.id = id
        self.type = type
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.placedByMemberId = placedByMemberId
        self.placedByCallsign = placedByCallsign
        self.timestamp = timestamp
        self.expiresAt = expiresAt
    }
    
    /// Compact 5-element array format: [type_code, lat, lon, ts, placedByMemberId]
    /// (Supports 4-element legacy format [type_code, lat, lon, ts] for backward compatibility)
    public var compactArray: [Any] {
        return [
            type.code,
            latitude,
            longitude,
            timestamp,
            placedByMemberId
        ]
    }
    
    /// Deserializes a TacticalIndicator from compact 5-element (or 4-element) array, legacy map,
    /// or (when `key` is supplied) an AES-256-GCM encrypted compact array string.
    public static func parse(id: String, rawValue: Any, defaultPlacedBy: String = "", key: SymmetricKey? = nil) -> TacticalIndicator? {
        if let ciphertext = rawValue as? String, let key {
            guard let array = try? CompactArrayCipher.decrypt(ciphertext, key: key) else { return nil }
            return parse(id: id, rawValue: array, defaultPlacedBy: defaultPlacedBy, key: key)
        }
        if let array = rawValue as? [Any], array.count >= 4 {
            let typeStr = String(describing: array[0])
            guard let type = TacticalIndicatorType.fromCode(typeStr) ?? TacticalIndicatorType(rawValue: typeStr),
                  let lat = (array[1] as? NSNumber)?.doubleValue ?? Double("\(array[1])"),
                  let lon = (array[2] as? NSNumber)?.doubleValue ?? Double("\(array[2])"),
                  let ts = (array[3] as? NSNumber)?.doubleValue ?? Double("\(array[3])") else {
                return nil
            }
            let placedBy = array.count >= 5 ? String(describing: array[4]) : defaultPlacedBy
            return TacticalIndicator(
                id: id,
                type: type,
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                placedByMemberId: placedBy,
                timestamp: ts
            )
        } else if let dict = rawValue as? [String: Any] {
            let typeStr = dict["type"] as? String ?? dict["t"] as? String ?? ""
            guard let type = TacticalIndicatorType.fromCode(typeStr) ?? TacticalIndicatorType(rawValue: typeStr),
                  let lat = dict["latitude"] as? Double ?? dict["lat"] as? Double ?? dict["la"] as? Double,
                  let lon = dict["longitude"] as? Double ?? dict["lon"] as? Double ?? dict["lo"] as? Double,
                  let ts = dict["timestamp"] as? TimeInterval ?? dict["ts"] as? TimeInterval else {
                return nil
            }
            let placedBy = dict["placedByMemberId"] as? String ?? dict["mid"] as? String ?? defaultPlacedBy
            let exp = dict["expiresAt"] as? TimeInterval ?? dict["exp"] as? TimeInterval
            return TacticalIndicator(
                id: id,
                type: type,
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                placedByMemberId: placedBy,
                timestamp: ts,
                expiresAt: exp
            )
        }
        return nil
    }
    
    /// Compact dictionary format for backward-compatibility or direct JSON writes
    public var firebaseValue: [Any] {
        return compactArray
    }
    
    /// Calculates the aging desaturation progress (0.0 = fresh radar color, 1.0 = fully faded to gray)
    /// Over 5 minutes (300 seconds)
    public func grayFadeFactor(referenceDate: Date = Date()) -> Double {
        guard category == .enemyIndicator else { return 0.0 }
        let elapsed = max(0, referenceDate.timeIntervalSince1970 - timestamp)
        let fadeDuration = AppConstants.Subscription.enemyIndicatorFadeDurationSeconds
        return min(1.0, elapsed / fadeDuration)
    }
    
    public func isFullyFaded(referenceDate: Date = Date()) -> Bool {
        return grayFadeFactor(referenceDate: referenceDate) >= 1.0
    }
}

