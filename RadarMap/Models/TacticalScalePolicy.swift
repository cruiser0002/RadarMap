import CoreLocation
import Foundation

/// Canonical scale policy governing discrete scale ladder and snapping math.
public struct TacticalScalePolicy: Equatable, Sendable {
    public static let defaultScale: CLLocationDistance = 50.0
    public static let minScale: CLLocationDistance = 1.0
    public static let maxScale: CLLocationDistance = 2_500.0

    /// Canonical `[1, 2.5, 5]` mantissa ladder replicated across each decade from 1m to 2.5km.
    public static let standardAllowedScales: [CLLocationDistance] = [
        1,
        2.5,
        5,
        10,
        25,
        50,
        100,
        250,
        500,
        1_000,
        2_500
    ]

    public let allowedScales: [CLLocationDistance]

    public init(allowedScales: [CLLocationDistance] = TacticalScalePolicy.standardAllowedScales) {
        self.allowedScales = allowedScales.isEmpty ? TacticalScalePolicy.standardAllowedScales : allowedScales
    }

    /// Finds the nearest allowed discrete scale using logarithmic distance selection.
    public func nearestAllowedScale(to observedScale: CLLocationDistance) -> CLLocationDistance {
        guard observedScale > 0 else { return allowedScales[0] }
        return allowedScales.min { lhs, rhs in
            abs(log(lhs / observedScale)) < abs(log(rhs / observedScale))
        } ?? allowedScales[0]
    }

    /// Returns the next scale zooming OUT (larger real-world distance), clamped at the maximum scale.
    public func nextScale(after current: CLLocationDistance) -> CLLocationDistance {
        guard let index = allowedScales.firstIndex(of: current) else {
            return nearestAllowedScale(to: current)
        }
        return allowedScales[min(index + 1, allowedScales.count - 1)]
    }

    /// Returns the previous scale zooming IN (smaller real-world distance), clamped at the minimum scale.
    public func previousScale(before current: CLLocationDistance) -> CLLocationDistance {
        guard let index = allowedScales.firstIndex(of: current) else {
            return nearestAllowedScale(to: current)
        }
        return allowedScales[max(index - 1, 0)]
    }

    /// Returns the outer radar range (4 * selected scale).
    public static func outerRadarRange(for scale: CLLocationDistance) -> CLLocationDistance {
        return scale * 4.0
    }

    /// Returns the four ring interval distances (1S, 2S, 3S, 4S).
    public static func ringIntervals(for scale: CLLocationDistance) -> [CLLocationDistance] {
        return [scale, scale * 2.0, scale * 3.0, scale * 4.0]
    }
}
