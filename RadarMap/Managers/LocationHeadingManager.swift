import Foundation
import CoreLocation
import Combine

public final class LocationHeadingManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published public var userLocation: CLLocation? {
        didSet {
            recalculateBlendedHeading()
        }
    }
    @Published public var userHeading: CLHeading? {
        didSet {
            recalculateBlendedHeading()
        }
    }
    @Published public var blendedHeading: Double = 0.0
    @Published public var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published public var isUpdating: Bool = false
    
    /// When true (e.g. on Apple Watch when Phone is active and paired), local GPS hardware updates are ignored
    /// so the shared location is exclusively sourced from the iPhone.
    @Published public var isRemoteLocationSource: Bool = false
    
    // MARK: - Speed-Weighted Heading Blending (COG + Compass)
    
    /// Speed threshold below which heading is 100% compass (stationary / looking around).
    public static let stationarySpeedThresholdMps: Double = AppConstants.Location.stationarySpeedThresholdMps
    
    /// Speed threshold above which heading is 100% GPS Course Over Ground (running / sprinting).
    public static let runningSpeedThresholdMps: Double = AppConstants.Location.runningSpeedThresholdMps
    
    /// Smooth circular interpolation between two angles (in degrees) using 2D unit vector decomposition.
    /// Prevents discontinuities when crossing the 0° / 360° north boundary.
    public static func circularInterpolate(from angle1: Double, to angle2: Double, weight: Double) -> Double {
        let clampedWeight = min(max(weight, 0.0), 1.0)
        let rad1 = angle1 * AppConstants.Location.degreesToRadiansFactor
        let rad2 = angle2 * AppConstants.Location.degreesToRadiansFactor
        
        let x = (1.0 - clampedWeight) * cos(rad1) + clampedWeight * cos(rad2)
        let y = (1.0 - clampedWeight) * sin(rad1) + clampedWeight * sin(rad2)
        
        guard abs(x) > AppConstants.Location.vectorEpsilon || abs(y) > AppConstants.Location.vectorEpsilon else { return angle1 }
        let blendedRad = atan2(y, x)
        let degrees = blendedRad * AppConstants.Location.radiansToDegreesFactor
        return (degrees + AppConstants.Location.fullCircleDegrees).truncatingRemainder(dividingBy: AppConstants.Location.fullCircleDegrees)
    }
    
    /// Computes the blended heading by dynamically weighting compass heading and GPS course over ground.
    public static func computeBlendedHeading(
        compassHeading: Double,
        gpsCourse: Double,
        speedMps: Double,
        hasValidCompass: Bool = true,
        hasValidCourse: Bool = true
    ) -> Double {
        if !hasValidCourse && hasValidCompass {
            return compassHeading
        }
        if !hasValidCompass && hasValidCourse {
            return gpsCourse
        }
        if !hasValidCompass && !hasValidCourse {
            return compassHeading
        }
        
        if speedMps <= stationarySpeedThresholdMps {
            return compassHeading
        }
        if speedMps >= runningSpeedThresholdMps {
            return gpsCourse
        }
        
        // Speed is between 0.5 m/s and 2.5 m/s: smoothly ramp weight
        let weight = (speedMps - stationarySpeedThresholdMps) / (runningSpeedThresholdMps - stationarySpeedThresholdMps)
        return circularInterpolate(from: compassHeading, to: gpsCourse, weight: weight)
    }
    
    private func recalculateBlendedHeading() {
        let compass = userHeading != nil && userHeading!.headingAccuracy >= 0 ? (userHeading!.trueHeading >= 0 ? userHeading!.trueHeading : userHeading!.magneticHeading) : nil
        let loc = userLocation
        let course = loc != nil && loc!.course >= 0 ? loc!.course : nil
        let speed = max(0.0, loc?.speed ?? 0.0)
        
        let hasValidCompass = compass != nil
        let hasValidCourse = course != nil
        
        let rawCompass = compass ?? blendedHeading
        let rawCourse = course ?? blendedHeading
        
        let newHeading = LocationHeadingManager.computeBlendedHeading(
            compassHeading: rawCompass,
            gpsCourse: rawCourse,
            speedMps: speed,
            hasValidCompass: hasValidCompass,
            hasValidCourse: hasValidCourse
        )
        
        // Secondary dead-band: suppress publish on floating-point noise when heading is near a threshold boundary.
        // Primary filtering is done at the hardware level via CLLocationManager.headingFilter (AppConstants.Location.headingFilterDegrees).
        let epsilon = 0.1  // degrees
        if abs(newHeading - blendedHeading) > epsilon {
            self.blendedHeading = newHeading
        }
    }
    
    private let locationManager = CLLocationManager()
    
    public override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .automotiveNavigation
        #if os(watchOS) || os(iOS)
        locationManager.headingFilter = AppConstants.Location.headingFilterDegrees
        locationManager.headingOrientation = .portrait
        #endif
        #if os(iOS)
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        #endif
    }

    public func requestPermissions() {
        #if os(iOS)
        locationManager.requestAlwaysAuthorization()
        #elseif os(watchOS)
        locationManager.requestWhenInUseAuthorization()
        #else
        locationManager.requestAlwaysAuthorization()
        #endif
    }
    
    public func startUpdates() {
        guard !isUpdating else { return }
        locationManager.startUpdatingLocation()
        #if os(watchOS) || os(iOS)
        if CLLocationManager.headingAvailable() {
            locationManager.startUpdatingHeading()
        }
        #endif
        isUpdating = true
    }
    public func stopUpdates() {
        locationManager.stopUpdatingLocation()
        #if os(watchOS) || os(iOS)
        if CLLocationManager.headingAvailable() {
            locationManager.stopUpdatingHeading()
        }
        #endif
        isUpdating = false
    }
    
    public func setHighAccuracy(_ high: Bool) {
        locationManager.desiredAccuracy = high ? kCLLocationAccuracyBestForNavigation : kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = high ? AppConstants.Location.distanceFilterMeters : 50.0
        #if os(watchOS) || os(iOS)
        if CLLocationManager.headingAvailable() {
            if high && isUpdating {
                locationManager.startUpdatingHeading()
            } else {
                locationManager.stopUpdatingHeading()
            }
        }
        #endif
    }
    
    public func enterLowPowerMode() {
        setHighAccuracy(false)
    }
    
    public func exitLowPowerMode() {
        setHighAccuracy(true)
    }
    
    // MARK: - CLLocationManagerDelegate
    
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        self.authorizationStatus = manager.authorizationStatus
        #if os(watchOS) || os(iOS)
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            startUpdates()
        }
        #else
        if manager.authorizationStatus == .authorizedAlways {
            startUpdates()
        }
        #endif
    }
    
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        self.userLocation = latest
    }
    
    public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        self.userHeading = newHeading
    }
    
    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[LocationManager] Failed with error: \(error.localizedDescription)")
    }
}
