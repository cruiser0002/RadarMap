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
    /// Simple moving average of the last `speedSMASampleCount` raw speed samples (m/s), used to
    /// simulate HR from motion when no optical sensor reading is present — see `AppConstants.Health`.
    @Published public private(set) var smoothedSpeedMps: Double = 0.0
    private var speedSamples: [Double] = []
    /// Latest raw speed (m/s) reported by CoreLocation. Sampled into the SMA once per second by
    /// `sampleSpeedForSMA()`, called from `GameStateManager`'s 1Hz `activeAdvertisementTimer` tick
    /// (the same "Local refresh rate (1Hz)" clock that drives the w2p_hs/p2w_hs lease refresh) —
    /// not on every GPS/compass delegate callback, whose cadence is bursty while turning and silent
    /// while stationary rather than a steady per-second clock.
    private var latestRawSpeedMps: Double = 0.0
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
    
    private func updateSmoothedSpeed(withRawSample sample: Double) {
        speedSamples.append(sample)
        if speedSamples.count > AppConstants.Location.speedSMASampleCount {
            speedSamples.removeFirst(speedSamples.count - AppConstants.Location.speedSMASampleCount)
        }
        smoothedSpeedMps = speedSamples.reduce(0, +) / Double(speedSamples.count)
    }

    /// Pushes the latest raw speed sample into the SMA. Called once per second from
    /// `GameStateManager`'s `activeAdvertisementTimer` tick — see `latestRawSpeedMps`.
    public func sampleSpeedForSMA() {
        updateSmoothedSpeed(withRawSample: latestRawSpeedMps)
    }

    private func recalculateBlendedHeading() {
        let compass = userHeading != nil && userHeading!.headingAccuracy >= 0 ? (userHeading!.trueHeading >= 0 ? userHeading!.trueHeading : userHeading!.magneticHeading) : nil
        let loc = userLocation
        let course = loc != nil && loc!.course >= 0 ? loc!.course : nil
        let speed = max(0.0, loc?.speed ?? 0.0)
        latestRawSpeedMps = speed
        // Note: this does not itself advance smoothedSpeedMps — see sampleSpeedForSMA().

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
        locationManager.activityType = .fitness
        #if os(watchOS) || os(iOS)
        locationManager.headingFilter = AppConstants.Location.headingFilterDegrees
        locationManager.headingOrientation = .portrait
        #endif
        #if os(iOS)
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.showsBackgroundLocationIndicator = true
        #endif
    }

    public func requestPermissions() {
        #if os(iOS) || os(watchOS)
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
    
    /// Adjusts GPS accuracy/distance-filter for power mode. Heading updates are intentionally left
    /// untouched here: the compass always runs alongside location (see startUpdates/stopUpdates),
    /// regardless of power mode, so the blended heading never freezes.
    public func setHighAccuracy(_ high: Bool) {
        locationManager.desiredAccuracy = high ? kCLLocationAccuracyBestForNavigation : kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = high ? AppConstants.Location.distanceFilterMeters : 50.0
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

    /// Suppresses the system heading-calibration screen (a ring of dots that must be closed by
    /// rotating the device, drawn full-screen over whatever the app is showing). The app has its
    /// own compass/heading UI on the radar face, so the system prompt is just an unwanted
    /// interruption — and on watchOS/iOS Simulator, with no real magnetometer to satisfy it, it
    /// can never actually be dismissed by the user, leaving the app looking permanently stuck on
    /// a "loading" screen. Returning false here stops CLLocationManager from presenting it at all.
    public func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        false
    }
}
