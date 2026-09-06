import Foundation
import CoreLocation

/// Represents the deterministic tracking and centering state of the map.
public enum MapTrackingState: Equatable, Codable {
    case locked
    case unlocked(latitude: Double, longitude: Double)
    
    public var isLocked: Bool {
        if case .locked = self { return true }
        return false
    }
    
    public var isUnlocked: Bool {
        !isLocked
    }
    
    public var pannedCoordinate: CLLocationCoordinate2D? {
        if case let .unlocked(lat, lon) = self {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return nil
    }
    
    public var iconName: String {
        isLocked ? "location.fill" : "location"
    }
}

/// Inputs/Actions that advance the MapStateMachine.
public enum MapAction {
    case centerOnLocalUser
    case pan(to: CLLocationCoordinate2D, userCoord: CLLocationCoordinate2D)
    case setScale(meters: Double)
    case togglePresentation
    case userMoved(to: CLLocationCoordinate2D)
}

/// Dedicated, deterministic State Machine governing Map scale, presentation, and tracking.
public struct MapStateMachine: Equatable {
    public private(set) var trackingState: MapTrackingState
    public private(set) var scaleMeters: Double
    public private(set) var presentation: TacticalPresentation
    public private(set) var centerTriggerCount: Int
    
    public init(
        trackingState: MapTrackingState = .locked,
        scaleMeters: Double = TacticalScalePolicy.defaultScale,
        presentation: TacticalPresentation = .radar,
        centerTriggerCount: Int = 0
    ) {
        self.trackingState = trackingState
        self.scaleMeters = scaleMeters
        self.presentation = presentation
        self.centerTriggerCount = centerTriggerCount
    }
    
    /// Pure state transition function that advances the state machine based on inputs.
    @discardableResult
    public mutating func handle(_ action: MapAction) -> MapStateMachine {
        switch action {
        case .centerOnLocalUser:
            trackingState = .locked
            centerTriggerCount += 1
            
        case let .pan(targetCoord, userCoord):
            let dLat = (targetCoord.latitude - userCoord.latitude) * AppConstants.Location.metersPerDegreeLatitude
            let dLon = (targetCoord.longitude - userCoord.longitude) * AppConstants.Location.metersPerDegreeLatitude * cos(targetCoord.latitude * AppConstants.Location.degreesToRadiansFactor)
            let dist = hypot(dLat, dLon)
            
            if dist > AppConstants.Location.centerThresholdMeters {
                trackingState = .unlocked(latitude: targetCoord.latitude, longitude: targetCoord.longitude)
            } else {
                trackingState = .locked
            }
            
        case let .setScale(meters):
            let snapped = TacticalScalePolicy().nearestAllowedScale(to: meters)
            scaleMeters = snapped
            
        case .togglePresentation:
            switch presentation {
            case .map:
                presentation = .radar
            case .radar:
                presentation = .map
            }
            
        case .userMoved:
            // When locked, the state machine implicitly tracks the player position; no state mutation required.
            break
        }
        return self
    }
    
    /// Queries the current effective map center given the live user coordinate.
    public func effectiveCenter(userCoord: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        switch trackingState {
        case .locked:
            return userCoord
        case let .unlocked(lat, lon):
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }
    
    /// Convenience property for MapCenterLockState compatibility.
    public var lockState: MapCenterLockState {
        trackingState.isLocked ? .locked : .unlocked
    }
}
