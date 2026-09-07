import Foundation
import CoreLocation

/// Shared constant-velocity extrapolation math, used identically on both sides of the dead
/// reckoning scheme (see DEAD_RECKONING.md):
///   - Sender-side: `GameStateManager.predictedPositionError` simulates what a peer would predict,
///     to decide whether a telemetry send can be skipped.
///   - Receiver-side: `SquadMember.extrapolatedCoordinate(at:)` uses the same formula to keep
///     rendering a remote member's position advancing between real telemetry downloads.
/// Both sides must derive velocity from two position+timestamp samples using this exact formula —
/// any divergence between them would mean a device's gating decisions no longer match what its
/// peers actually render.
public enum DeadReckoning {
    private static let metersPerDegreeLatitude: Double = AppConstants.Location.metersPerDegreeLatitude

    /// Debug-only kill switch, shared by both call sites (sender-side upload gating in
    /// `GameStateManager.predictedPositionError` and receiver-side rendering in
    /// `SquadMember.extrapolatedCoordinate`). Flip to `false` and rebuild to test them in
    /// isolation: `predictedCoordinate` always returns `nil`, so both sides fall back to their
    /// raw/no-prediction behavior consistently — the sender gates purely on raw displacement,
    /// and remote members render at their raw last-telemetry position with no extrapolation.
    public static let isEnabled = false

    /// Flat-earth (equirectangular) approximation of north/east displacement, in meters, between
    /// two nearby coordinates. Adequate for gating/rendering over the sub-kilometer distances
    /// relevant here; not intended for geodesic accuracy at longer range.
    public static func offsetMeters(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> (north: Double, east: Double) {
        let metersPerDegreeLongitude = metersPerDegreeLatitude * cos(from.latitude * .pi / 180.0)
        let north = (to.latitude - from.latitude) * metersPerDegreeLatitude
        let east = (to.longitude - from.longitude) * metersPerDegreeLongitude
        return (north, east)
    }

    /// Inverse of `offsetMeters`: applies a north/east meter offset to a base coordinate.
    public static func coordinate(from base: CLLocationCoordinate2D, addingNorthMeters north: Double, eastMeters east: Double) -> CLLocationCoordinate2D {
        let metersPerDegreeLongitude = metersPerDegreeLatitude * cos(base.latitude * .pi / 180.0)
        let newLat = base.latitude + (north / metersPerDegreeLatitude)
        let newLon = base.longitude + (east / metersPerDegreeLongitude)
        return CLLocationCoordinate2D(latitude: newLat, longitude: newLon)
    }

    /// Predicts a coordinate at `atTime`, given two prior (coordinate, timestamp) samples with
    /// `sampleB.timestamp > sampleA.timestamp`. Returns `nil` if the interval between the two
    /// samples is too small to derive a stable velocity (callers should fall back to `sampleB`'s
    /// raw coordinate in that case).
    public static func predictedCoordinate(
        sampleA: (coordinate: CLLocationCoordinate2D, timestamp: TimeInterval),
        sampleB: (coordinate: CLLocationCoordinate2D, timestamp: TimeInterval),
        atTime: TimeInterval
    ) -> CLLocationCoordinate2D? {
        guard isEnabled else { return nil }

        let dtHistory = sampleB.timestamp - sampleA.timestamp
        guard dtHistory > 0.01 else { return nil }

        let velocity = offsetMeters(from: sampleA.coordinate, to: sampleB.coordinate)
        let velocityNorth = velocity.north / dtHistory
        let velocityEast = velocity.east / dtHistory

        let dtNow = atTime - sampleB.timestamp
        return coordinate(
            from: sampleB.coordinate,
            addingNorthMeters: velocityNorth * dtNow,
            eastMeters: velocityEast * dtNow
        )
    }
}
