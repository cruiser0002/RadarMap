import SwiftUI
import MapKit

// MARK: - SquadMember Presentation Extensions

extension SquadMember {
    /// Heart rate stress level categorization color
    public var heartRateZoneColor: Color {
        switch heartRate {
        case ..<AppConstants.Health.Zones.blueMax:
            return .blue
        case AppConstants.Health.Zones.blueMax..<AppConstants.Health.Zones.greenMax:
            return .green
        case AppConstants.Health.Zones.greenMax..<AppConstants.Health.Zones.yellowMax:
            return .yellow
        case AppConstants.Health.Zones.yellowMax..<AppConstants.Health.Zones.orangeMax:
            return .orange
        default:
            return .red
        }
    }
}

// MARK: - TacticalPresentation Extensions

extension TacticalPresentation {
    @available(watchOS 10.0, iOS 17.0, *)
    public var mapKitStyle: MapStyle {
        .standard(elevation: .flat, pointsOfInterest: .excludingAll)
    }

    public var iconName: String {
        "map"
    }
}

// MARK: - TacticalIndicatorCategory Presentation Extensions

extension TacticalIndicatorCategory {
    public var iconName: String {
        switch self {
        case .squadOrder:
            return "star.fill"
        case .enemyIndicator:
            return "scope"
        case .environment:
            return "leaf.fill"
        }
    }
    
    /// Tactical base color: Team Orders remain green; Tactical and Environmental markers are red.
    public var baseColor: Color {
        switch self {
        case .squadOrder:
            return .green
        case .enemyIndicator, .environment:
            return .red
        }
    }
}

// MARK: - TacticalIndicatorType Presentation Extensions

extension TacticalIndicatorType {
    /// Tactical base color derived from indicator category
    public var baseColor: Color {
        category.baseColor
    }
    /// SF Symbol descriptor (system name or custom asset catalog symbol name)
    public var iconName: String {
        switch self {
        // Squad Orders
        case .watchHere:
            return "eye.fill"
        case .goHere:
            return "arrowshape.down"
        case .attackHere:
            return "bolt"
        case .protectHere:
            return "shield"
        case .flag:
            return "flag.fill"
        case .point1:
            return "1.circle"
        case .point2:
            return "2.circle"
        case .point3:
            return "3.circle"
            
        // Enemy Indicators
        case .infantry:
            return "tactical.helmet"
        case .vehicle:
            return "tactical.humvee"
        case .armor:
            return "tactical.tank"
        case .drone:
            return "tactical.drone"
            
        // Environment Indicators
        case .water:
            return "water.waves"
        case .hazard:
            return "exclamationmark.triangle.fill"
        case .fire:
            return "flame.fill"
        case .snow:
            return "snowflake"
        case .closure:
            return "minus.circle.fill"
        case .emergency:
            return "sos.circle.fill"
        }
    }
    
    public var isCustomSymbol: Bool {
        switch self {
        case .infantry, .vehicle, .armor, .drone:
            return true
        default:
            return false
        }
    }
    
    public var iconImage: Image {
        if isCustomSymbol {
            return Image(iconName).renderingMode(.template)
        } else {
            return Image(systemName: iconName).renderingMode(.template)
        }
    }
}

// MARK: - TacticalIndicator Presentation Extensions

extension TacticalIndicator {
    /// Tactical base color taking into account whether the indicator was placed by the local player
    /// or a member of the same clan:
    /// - Team orders dropped by me or teammates in the same clan are green.
    /// - Other people's team orders are blue.
    /// - Tactical & environmental markers are red.
    public func baseColor(isPlacedByMe: Bool, isSameClan: Bool = false) -> Color {
        switch category {
        case .squadOrder:
            return (isPlacedByMe || isSameClan) ? .green : .blue
        case .enemyIndicator, .environment:
            return .red
        }
    }
    
    /// Default base color (assumes placed by me if unqueried)
    public var baseColor: Color {
        baseColor(isPlacedByMe: true, isSameClan: false)
    }
}

// MARK: - CoreLocation Extensions

#if canImport(CoreLocation)
extension CLLocationCoordinate2D: @retroactive Equatable {
    public static func == (lhs: CLLocationCoordinate2D, rhs: CLLocationCoordinate2D) -> Bool {
        abs(lhs.latitude - rhs.latitude) < 1e-9 && abs(lhs.longitude - rhs.longitude) < 1e-9
    }
}
#endif
