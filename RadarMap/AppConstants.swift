import Foundation
import CoreLocation
import SwiftUI

/// Centralized configuration constants for the RadarMap application.
/// Modify these values to adjust application behaviors, thresholds, intervals, and UI scales.
public enum AppConstants {
    
    // MARK: - Version & Build Tracking
    public enum Version {
        public static var appVersion: String {
            AppBuildVersion.marketingVersion
        }
        public static var buildNumber: String {
            "\(AppBuildVersion.buildNumber)"
        }
        public static var formattedVersionString: String {
            AppBuildVersion.formatted
        }
    }
    
    #if DEBUG
    // MARK: - Debug Configuration
    public enum Debug {
        /// Whether the version/netcode debug field is shown in the HUD. Off by default; toggled at
        /// runtime from the hidden debug panel (hold the Policy screen for 5 seconds).
        public static var isDebugFieldEnabled: Bool {
            get { UserDefaults.standard.bool(forKey: AppConstants.Storage.isDebugDisplayEnabledKey) }
            set { UserDefaults.standard.set(newValue, forKey: AppConstants.Storage.isDebugDisplayEnabledKey) }
        }
    }
    #endif
    
    // MARK: - Local Storage & UserDefaults Keys
    public enum Storage {
        public static let userCallsignKey = "user_callsign"
        public static let savedRoomNameKey = "saved_room_name"
        public static let radarColorThemeKey = "radar_color_theme"
        public static let hasUnlimitedSquadUnlockKey = "hasUnlimitedSquadUnlock"
        public static let savedPinKey = "saved_pin"
        public static let isUploadHeartRateEnabledKey = "is_upload_heart_rate_enabled"
        public static let isUploadLocationEnabledKey = "is_upload_location_enabled"
        public static let customDatabaseURLKey = "custom_database_url"
        public static let isCustomDatabaseURLEnabledKey = "is_custom_database_url_enabled"
        public static let recentDatabaseURLsKey = "recent_database_urls"
        #if DEBUG
        public static let isDebugDisplayEnabledKey = "is_debug_display_enabled"
        #endif
        public static let userRoleKey = "user_role"
        /// Legacy per-device flag, only read once to seed `ConfigSnapshot.isEncryptionEnabled` on
        /// first launch after that field was introduced — see `WatchConnectivityManager.init`.
        /// The live, phone/watch-synced value is `GameStateManager.isEncryptionEnabled`.
        public static let isEncryptionEnabledKey = "is_encryption_enabled"
    }
    
    // MARK: - Networking & Realtime Database
    public enum Network {
        /// Firebase Realtime Database default endpoint URL
        public static let defaultDatabaseURL = "https://radarmap-8adf0-default-rtdb.firebaseio.com"

        /// Generous upper bound on a real Firebase RTDB URL (a real one is ~50-90 characters).
        /// Exists to keep the join QR code's payload small and reliably scannable — it's encoded
        /// alongside the room name and PIN (see QRJoinPayload/JoinQRBox), and an unbounded field
        /// here would be the one way to blow that up, whether by accident (a stray paste) or
        /// otherwise, denser than the small screens it's displayed on can actually scan.
        public static let maxDatabaseURLLength: Int = 200

        /// Whether `string` is well-formed enough to hand to `Database.database(url:)` without it
        /// trapping. Firebase's SDK terminates the app with an uncaught `NSException` when given a
        /// URL it can't parse as an http(s) host root (e.g. missing scheme, or a bare word like
        /// "dfgdsgf") — this check must run before any custom database URL reaches that call.
        /// RFC 3986 URI characters (unreserved + reserved + percent-encoding) — the widest set a
        /// legitimate Firebase RTDB URL can ever need. Unlike the room-name/PIN fields, a URL
        /// can't be restricted to plain alphanumerics (it requires `: / . -` at minimum), so this
        /// instead strips everything a URL *never* contains: whitespace, control characters, and
        /// any non-ASCII text (e.g. from a stray paste or the camera-scan OCR field) that would
        /// otherwise make `Database.database(url:)` trap instead of failing gracefully.
        private static let uriCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")

        /// Sanitizes free-typed or scanned text destined for the custom-database-URL field to
        /// RFC 3986 URI characters only. Does not itself validate URL well-formedness — pair with
        /// `isValidDatabaseURL` before use.
        public static func sanitizeInput(_ string: String) -> String {
            let filtered = string.unicodeScalars.filter { uriCharacters.contains($0) }
            return String(String.UnicodeScalarView(filtered)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        public static func isValidDatabaseURL(_ string: String) -> Bool {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count <= maxDatabaseURLLength,
                  let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  let host = url.host, !host.isEmpty else {
                return false
            }
            return true
        }
        
        /// Firebase Realtime Database path endpoints
        public enum Endpoints {
            public static let rooms = "r"
            public static let telemetry = "p"
            public static let tactical = "t"
            public static let members = "m"
            /// Squad-order indicators, under tactical/{roomId} — self-pruning, no numeric cap.
            public static let orders = "o"
            /// Enemy + environment indicators, under tactical/{roomId} — shares the room's `mti` cap.
            public static let indicators = "i"
        }
        
        /// Quality monitoring and latency grading thresholds
        public enum Quality {
            public static let initialLatencyMs: Double = 50.0
            public static let initialJitterMs: Double = 0.0
            public static let emaAlpha: Double = 0.2 // Weight for Exponential Moving Average
            
            // Latency boundaries in milliseconds
            public static let excellentLatencyMs: Double = 150.0
            public static let excellentJitterMs: Double = 50.0
            public static let goodLatencyMs: Double = 300.0
            public static let goodJitterMs: Double = 100.0
            public static let poorLatencyMs: Double = 700.0
        }
    }
    
    // MARK: - In-App Purchase & Subscriptions
    public enum Subscription {
        public static let entitlementID = "radarmap_pro"
        public static let productID = "com.radarmap.watch.pro"
        public static let lifetimePriceString = "$29.99"
        public static let promotionalPriceMessage: String? = nil
        
        /// Squad player capacity limits
        public static let freeTierMaxCapacity: Int = 4
        public static let proTierMaxCapacity: Int = 12

        /// Tactical Indicators Constants — shared cap on enemy+environment indicators (squad
        /// orders self-prune separately and don't count against this cap; see CLOUD_DATA_MANAGEMENT.md)
        public static let freeTierMaxTacticalIndicators: Int = 0
        public static let proTierMaxTacticalIndicators: Int = 20
        public static let enemyIndicatorFadeDurationSeconds: TimeInterval = 300.0 // 5 minutes
        public static let indicatorHoldToDeleteDurationSeconds: TimeInterval = 1.2
        public static var tacticalIndicatorAckTimeoutSeconds: TimeInterval = 10.0
        
        /// Mock purchase simulated sleep delays
        public static let mockPurchaseSleepNanoseconds: UInt64 = 1_000_000_000
        public static let mockRestoreSleepNanoseconds: UInt64 = 800_000_000
    }
    
    // MARK: - Privacy & Policy
    public enum Policy {
        public static let privacyPolicyURL = "https://www.privacypolicies.com/live/ffdebf4f-ec87-4552-aa22-f438f6fabc94"
        public static let termsOfServiceURL = "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
        public static let contactEmail = "sweetdreamsdeveloper@gmail.com"
        public static let contactFormURL = "https://forms.gle/pCuy2zJtSfLoyqj16"
        
        public static let summary = "Radar Map is committed to protecting your privacy. We collect real-time location and heart rate data solely for live squad coordination during active sessions."
        public static let locationDataDescription = "Location data (GPS coordinates, heading, course over ground) is streamed in real time to your squad room and is automatically purged when the room is disbanded or after 24 hours of inactivity. Continued use of GPS running in the background can dramatically decrease battery life. You can opt out of location uploading at any time in Settings."
        public static let healthDataDescription = "Heart rate biometrics are read via Apple HealthKit during outdoor workouts to display team exertion levels and vital status. This data is never sold, used for advertising, or shared with third parties. You can opt out of HR uploading at any time in Settings."
        public static let dataRetentionDescription = "We do not sell your data or use tracking cookies. All session data is ephemeral and tied to temporary squad rooms."
        public static let encryptionDescription = "Telemetry (GPS coordinates, heading, heart rate) and tactical markers are end-to-end encrypted (E2EE) using AES-256-GCM derived from your squad room PIN, ensuring data remains secure and unreadable in transit and at rest on any cloud database."
        public static let batteryDisclaimer = "Continued use of GPS running in the background can dramatically decrease battery life."
    }
    
    // MARK: - Location & Geodesic Navigation
    public enum Location {
        /// Default fallback coordinate (San Francisco, CA)
        public static let fallbackLatitude: Double = 37.785834
        public static let fallbackLongitude: Double = -122.406417
        public static let fallbackCoordinate = CLLocationCoordinate2D(
            latitude: fallbackLatitude,
            longitude: fallbackLongitude
        )
        
        /// Sensor sensitivity filters
        public static let distanceFilterMeters: Double = 1.0 // 1 meter update sensitivity
        public static let headingFilterDegrees: Double = 2.0  // 2 degree heading sensitivity
        
        /// Meters per degree latitude approximation (WGS-84 geodesic)
        public static let metersPerDegreeLatitude: Double = 111_139.0
        
        /// Metric conversion factors
        public static let metersPerKilometer: Double = 1000.0
        
        /// Angular trigonometry and calculation factors
        public static let degreesToRadiansFactor: Double = .pi / 180.0
        public static let radiansToDegreesFactor: Double = 180.0 / .pi
        public static let fullCircleDegrees: Double = 360.0
        public static let vectorEpsilon: Double = 1e-6
        
        /// Speed-weighted heading blending thresholds (m/s)
        public static let stationarySpeedThresholdMps: Double = 0.5 // ~1.1 mph: 100% Compass
        public static let runningSpeedThresholdMps: Double = 2.5    // ~5.6 mph: 100% GPS COG
        
        /// Minimum displacement required to compute Course Over Ground (COG)
        /// Set to 2.0m to filter out GPS drift / noise jitter that causes player headings to bob up and down
        public static let minDisplacementForCourseOverGroundMeters: Double = 2.0
        
        /// Unified threshold in meters to determine whether map center tracks local player or custom panned location
        public static let centerThresholdMeters: Double = 10.0

        /// Window size for the simple moving average of movement speed used to simulate HR from motion.
        public static let speedSMASampleCount: Int = 20
    }
    
    // MARK: - HealthKit & Biometrics
    public enum Health {
        /// Default initial player vital status (alive / active, not dead)
        public static let defaultIsDead: Bool = false
        public static let defaultRestingHeartRate: Double = 75.0 // BPM
        public static let flatlineHeartRate: Double = 0.0        // BPM for KIA / Downed

        /// BPM added per m/s of smoothed movement speed when simulating HR from motion
        /// (Phone has no optical sensor of its own — see `LocationHeadingManager.smoothedSpeedMps`).
        public static let simulatedHeartRateSlopeBpmPerMps: Double = 18.0
        /// Upper clamp for the speed-simulated HR, matching a sprint-level exertion reading.
        public static let maxSimulatedHeartRate: Double = 190.0
        public static let referenceBpm: Double = 100.0           // Reference BPM for scanning sweep (BPM / 100 equation)
        public static let secondsPerMinute: Double = 60.0
        
        /// Mock fallback values for simulator/host execution
        public static let mockWorkoutHeartRate: Double = 82.0
        
        /// Heart rate pulse clamping bounds for visual pulse animation
        public static let minPulseBpm: Double = 30.0
        public static let maxPulseBpm: Double = 220.0
        
        /// Heart rate stress level thresholds (BPM)
        public enum Zones {
            public static let blueMax: Double = 60.0    // < 60: Rest (Blue)
            public static let greenMax: Double = 100.0  // 60 - 99: Normal (Green)
            public static let yellowMax: Double = 140.0 // 100 - 139: Elevated (Yellow)
            public static let orangeMax: Double = 175.0 // 140 - 174: High Stress (Orange)
            // >= 175: Max Stress (Red)
        }
    }
    
    // MARK: - Timing, Intervals & Rates
    public enum Timing {
        /// Standard time unit conversion factors
        public static let secondsPerMinute: Double = 60.0
        public static let secondsPerHour: Double = 3600.0
        public static let secondsPerDay: Double = 86400.0
        public static let millisecondsPerSecond: Double = 1000.0
        
        /// Telemetry upload and polling adaptive intervals (in seconds)
        public enum AdaptiveRate {
            public static let criticalInterval: TimeInterval = 5.0
            public static let poorInterval: TimeInterval = 4.0
            public static let baselineInterval: TimeInterval = 1.0
            public static let wristDownPollingInterval: TimeInterval = 10.0 // Low power throttle when wrist is down
            
            // Threshold for triggering interval update
            public static let intervalChangeEpsilon: Double = 0.01
        }
        
        /// Refresh rates for display animations and unified dead-reckoning smoothing (local & remote)
        public enum DisplayRefresh {
            public static let radarUIIntervalSeconds: TimeInterval = 1.0 / 20.0

            /// Rate at which extrapolated (dead-reckoned) positions for remote squad members are
            /// recomputed for local rendering, independent of how often real telemetry updates
            /// actually arrive over the network (see DEAD_RECKONING.md). Tunable — start conservative.
            public static let remotePlayerDeadReckoningHz: Double = 1.0
            public static let remotePlayerDeadReckoningIntervalSeconds: TimeInterval = 1.0 / remotePlayerDeadReckoningHz
        }
        
        /// Movement and telemetry delta gating thresholds (Dead Reckoning optimization)
        public enum DeltaGating {
            /// Max allowed divergence between actual position and where a peer's dead-reckoning
            /// extrapolation (from our last two sent samples) would predict us to be right now.
            /// Below this, peers' predictions are already accurate enough — skip the send.
            public static let maxPredictedPositionErrorMeters: Double = 3.5
            public static let minHeartRateDeltaBpm: Double = 12.0  // Ignore respiration & PPG sensor jitter (< 12 BPM)

            /// Master switch for the heart rate delta gate. Real HR is always uploaded regardless
            /// of this flag — this only controls whether a >= minHeartRateDeltaBpm swing is allowed
            /// to force an early telemetry emit. Flip to false to send HR passively (still gated by
            /// the position delta and 10*T heartbeat fallback) without HR jitter causing extra uploads.
            public static let heartRateDeltaGatingEnabled: Bool = false
        }
        
        /// Theoretical aggregate bandwidth rate adaptation equation constants & schedule
        public enum ConstantBandwidth {
            public static let playerThreshold: Int = 12
            public static let baselineMaxUpdateRateHz: Double = 1.0
            public static let refreshIntervalMultiplier: Double = 10.0
            public static let staleTimeoutMultiplier: Double = 15.0
            
            /// Computes the maximum update rate in Hz for a given player count.
            /// For P <= 12: 1.0 Hz
            /// For P > 12: 1.0 * (12 / P) — linear falloff, chosen so that
            /// aggregate bandwidth (P * rate) stays constant at the P=12 ceiling
            /// rather than continuing to shrink as the room grows further.
            public static func maxUpdateRateHz(forPlayerCount playerCount: Int) -> Double {
                guard playerCount > 0 else { return baselineMaxUpdateRateHz }
                if playerCount <= playerThreshold {
                    return baselineMaxUpdateRateHz
                }
                let ratio = Double(playerThreshold) / Double(playerCount)
                return baselineMaxUpdateRateHz * ratio
            }
            
            /// Computes the minimum update interval in seconds.
            public static func updateInterval(forPlayerCount playerCount: Int) -> TimeInterval {
                let rate = maxUpdateRateHz(forPlayerCount: playerCount)
                guard rate > 0 else { return 1.0 }
                return 1.0 / rate
            }
            
            /// Computes the fallback refresh heartbeat interval (7 * T).
            public static func refreshInterval(forPlayerCount playerCount: Int) -> TimeInterval {
                return refreshIntervalMultiplier * updateInterval(forPlayerCount: playerCount)
            }
            
            /// Computes the stale timeout watermark (15 * T).
            public static func staleTimeout(forPlayerCount playerCount: Int) -> TimeInterval {
                return staleTimeoutMultiplier * updateInterval(forPlayerCount: playerCount)
            }
        }
        
        /// Stale telemetry timeout constants
        public enum Stale {
            /// Stale timeout multiplier (M): timeout = M * updateInterval
            public static let defaultTimeoutMultiplier: Double = 15.0
            public static let defaultUpdateInterval: TimeInterval = 1.0
        }
        
        /// Inactivity room cleanup threshold & TTL duration
        public enum Inactivity {
            public static let idleCutoffHours: Double = 12.0
            public static let secondsPerHour: Double = 3600.0
            public static let ttlDurationSeconds: TimeInterval = idleCutoffHours * secondsPerHour
            /// Cadence at which the host re-pushes `exp` (see FirebaseSyncManager.refreshRoomExpiry)
            /// to keep an actively-hosted room alive past idleCutoffHours.
            public static let ttlRefreshIntervalSeconds: TimeInterval = secondsPerHour
        }
    }
    
    // MARK: - Centralized 3-Letter Encodings & Field Mappings
    public enum Encoding {
        public enum Tactical {
            public static let watchHere = "wat"
            public static let goHere = "goh"
            public static let attackHere = "atk"
            public static let protectHere = "def"
            public static let flag = "flg"
            public static let point1 = "pt1"
            public static let point2 = "pt2"
            public static let point3 = "pt3"
            
            public static let infantry = "inf"
            public static let vehicle = "veh"
            public static let armor = "arm"
            public static let drone = "drn"
            
            public static let water = "wtr"
            public static let hazard = "haz"
            public static let fire = "fir"
            public static let snow = "snw"
            public static let closure = "cls"
            public static let emergency = "emg"
        }
        
        public enum TelemetryKeys {
            public static let latitude = "lat"
            public static let longitude = "lon"
            public static let altitude = "alt"
            public static let heading = "hdg"
            public static let heartRate = "hr"
            public static let sequenceNumber = "seq"
            public static let timestamp = "ts"
        }
        
        public enum MetadataKeys {
            public static let memberId = "mid"
            public static let callsign = "csn"
            public static let hostId = "hst"
            public static let maxCapacity = "cap"
            public static let pinHash = "pin"
            public static let expireAt = "exp"
        }
    }

    // MARK: - UI, Display & Styling
    public enum UI {
        public static let defaultCallsign = ""
        public static let defaultRoomName = ""
        public static let defaultTacticalColorHex = "#00FF66"
        public static let defaultBatteryLevel: Double = 0.95
        
        /// Gesture timing & interaction parameters
        public enum Gestures {
            public static let actionHoldDurationSeconds: TimeInterval = 1.2
            public static let holdTimerTickIntervalSeconds: TimeInterval = 0.02
            public static let actionAnimationDurationSeconds: Double = 0.25
        }
        
        /// PIN Input formatting & length
        public static let maxPinLength: Int = 16

        /// Room / Squad id total length (user-entered name + PIN-derived padding suffix). This is
        /// the actual Firebase path key length and must stay in sync with database.rules.json's
        /// `$roomId.length <= 16` validation.
        public static let maxRoomNameLength: Int = 16

        /// Max characters a user may type into the Squad Name field. The remainder of
        /// `maxRoomNameLength` (4 chars) is padding deterministically derived from the room's
        /// (mandatory) PIN at creation/join time, so a joiner's client can recompute the full id
        /// locally from the same name + PIN without any extra characters being relayed. See
        /// CLOUD_DATA_MANAGEMENT.md.
        public static let maxRoomNameEntryLength: Int = 12

        /// Minimum characters required in the Squad Name field (see CLOUD_DATA_MANAGEMENT.md).
        public static let minRoomNameEntryLength: Int = 4

        /// Minimum characters required in the (mandatory) PIN field (see CLOUD_DATA_MANAGEMENT.md).
        public static let minPinLength: Int = 4

        /// Max characters a user may type into the Callsign field. Generous relative to
        /// room name/PIN since it's free-form display text, not a derived id, but still bounded
        /// so an unrestricted paste can't blow up member-list rendering or Firebase payload size.
        public static let maxCallsignLength: Int = 20

        /// Minimum characters required in the Callsign field — just enough to rule out a
        /// whitespace-only or single stray-character entry.
        public static let minCallsignLength: Int = 1

        /// Number of most-recently-used custom database URLs remembered for quick reselection.
        public static let maxRecentDatabaseURLs: Int = 3
        
        /// Voice dictation word mapping for PIN entry
        public static let pinWordMapping: [String: String] = [
            "zero": "0", "oh": "0",
            "one": "1", "won": "1",
            "two": "2", "to": "2", "too": "2",
            "three": "3",
            "four": "4", "for": "4", "fore": "4",
            "five": "5",
            "six": "6",
            "seven": "7",
            "eight": "8", "ate": "8",
            "nine": "9"
        ]
        
        /// Radar scale distance bounds (meters) and canonical scale ladder policy
        public enum RadarScale {
            public static let defaultScaleMeters: Double = TacticalScalePolicy.defaultScale
            public static let minScaleMeters: Double = TacticalScalePolicy.minScale
            public static let maxScaleMeters: Double = TacticalScalePolicy.maxScale
            public static let maxiOSScaleMeters: Double = TacticalScalePolicy.maxScale
            
            /// Canonical discrete `[1, 2.5, 5]` decade scale ladder from 1m to 2.5km
            public static let discreteScales: [Double] = TacticalScalePolicy.standardAllowedScales
            
            public static let policy = TacticalScalePolicy()
            
            /// Finds the closest discrete scale index for a given scale in meters
            public static func nearestScaleIndex(for scaleMeters: Double) -> Int {
                let target = policy.nearestAllowedScale(to: scaleMeters)
                return discreteScales.firstIndex(of: target) ?? 0
            }
            
            /// Snaps an arbitrary scale to the nearest discrete ladder scale using logarithmic comparison
            public static func snapToDiscreteScale(_ scaleMeters: Double) -> Double {
                return policy.nearestAllowedScale(to: scaleMeters)
            }
            
            /// Returns the next discrete scale zooming IN (smaller meter distance).
            @available(*, deprecated, message: "+/- zoom buttons are deprecated; use crown or pinch gestures.")
            public static func stepZoomIn(from scaleMeters: Double) -> Double {
                return policy.previousScale(before: scaleMeters)
            }
            
            /// Returns the next discrete scale zooming OUT (larger meter distance).
            @available(*, deprecated, message: "+/- zoom buttons are deprecated; use crown or pinch gestures.")
            public static func stepZoomOut(from scaleMeters: Double) -> Double {
                return policy.nextScale(after: scaleMeters)
            }
            
            /// Finds the crown index (reversed direction: 0 = max zoomed out 50km, max index = max zoomed in 50m)
            public static func crownIndex(for scaleMeters: Double) -> Double {
                let nearestIdx = nearestScaleIndex(for: scaleMeters)
                return Double((discreteScales.count - 1) - nearestIdx)
            }
            
            /// Resolves the scale in meters for a given crown index (reversed direction: scrolling up zooms in)
            public static func scale(forCrownIndex crownIndex: Double) -> Double {
                let maxIdx = discreteScales.count - 1
                let intIndex = min(max(Int(round(crownIndex)), 0), maxIdx)
                let scaleIndex = maxIdx - intIndex
                return discreteScales[scaleIndex]
            }
            
            /// Display geometry ratios
            public static let radarRadiusRatio: Double = 0.44
            public static let crosshairExtensionRatio: Double = 1.05
            public static let centerReticleSize: Double = 9.0
            
            #if os(watchOS)
            public static let referenceScreenAspectRatio: Double = 1.22 // Height / Width for Apple Watch
            #else
            public static let referenceScreenAspectRatio: Double = 2.16 // Height / Width for iPhone
            #endif
            
            /// Range ring fractional ratios from center (4 clicks of minor scale: 1x, 2x, 3x, 4x)
            public static let rangeRingRatios: [Double] = [0.25, 0.50, 0.75, 1.0]
            
            /// Converts a minor radar scale in meters to an equivalent MapKit coordinate span latitude delta (outer radius = 4 minor clicks).
            public static func mapSpanDelta(forRadarScaleMeters radarScaleMeters: Double) -> Double {
                let outerRadarMeters = radarScaleMeters * 4.0
                let visibleMetersLat = (outerRadarMeters / radarRadiusRatio) * referenceScreenAspectRatio
                return visibleMetersLat / AppConstants.Location.metersPerDegreeLatitude
            }
            
            /// Converts a MapKit coordinate span latitude delta to an equivalent clamped minor radar scale in meters.
            public static func radarScaleMeters(forMapSpanDelta mapSpanDelta: Double) -> Double {
                let visibleMetersLat = (mapSpanDelta * AppConstants.Location.metersPerDegreeLatitude) / referenceScreenAspectRatio
                let outerRadarMeters = visibleMetersLat * radarRadiusRatio
                let minorScaleMeters = outerRadarMeters / 4.0
                return policy.nearestAllowedScale(to: minorScaleMeters)
            }
            
            /// Converts a MapKit MapCamera distance (altitude) to continuous minor radar scale in meters.
            public static func continuousScaleMeters(forCameraDistance distance: Double) -> Double {
                let visibleMetersLat = distance * (2.0 * tan(15.0 * .pi / 180.0))
                let outerRadarMeters = (visibleMetersLat / referenceScreenAspectRatio) * radarRadiusRatio
                let minorScaleMeters = outerRadarMeters / 4.0
                return max(minScaleMeters, min(maxiOSScaleMeters, minorScaleMeters))
            }
            
            /// Converts a MapKit MapCamera distance (altitude) to an equivalent clamped minor radar scale in meters.
            public static func scaleMeters(forCameraDistance distance: Double) -> Double {
                return policy.nearestAllowedScale(to: continuousScaleMeters(forCameraDistance: distance))
            }
            
            /// Converts a minor radar scale in meters to an equivalent MapKit MapCamera distance (altitude).
            public static func cameraDistance(forScale scaleMeters: Double) -> Double {
                let outerRadarMeters = scaleMeters * 4.0
                let visibleMetersLat = (outerRadarMeters / radarRadiusRatio) * referenceScreenAspectRatio
                let cameraAltitude = visibleMetersLat / (2.0 * tan(15.0 * .pi / 180.0))
                return max(10.0, cameraAltitude)
            }
        }
        
        /// Tactical scale ruler display thresholds
        public enum ScaleRuler {
            #if os(watchOS)
            public static let referenceScreenHeight: Double = 200.0
            #else
            public static let referenceScreenHeight: Double = 800.0
            #endif
            
            /// Formats a distance in meters to a discrete ruler label.
            public static func formatRulerDistance(minorScaleMeters: Double) -> String {
                let snappedMinor = RadarScale.snapToDiscreteScale(minorScaleMeters)
                return formatDistance(meters: snappedMinor)
            }
            
            /// Formats a live/continuous distance in meters directly to ruler label without pre-snapping.
            public static func formatLiveRulerDistance(minorScaleMeters: Double) -> String {
                return formatDistance(meters: minorScaleMeters)
            }
            
            /// Formats a distance in meters for display (e.g. range ring distance label or ruler label).
            public static func formatDistance(meters: Double) -> String {
                let roundedToTenth = (meters * 10.0).rounded() / 10.0
                if roundedToTenth < AppConstants.Location.metersPerKilometer {
                    if abs(roundedToTenth.rounded() - roundedToTenth) < 1e-5 {
                        return "\(Int(roundedToTenth.rounded()))m"
                    } else {
                        return String(format: "%.1fm", roundedToTenth)
                    }
                } else {
                    let km = roundedToTenth / AppConstants.Location.metersPerKilometer
                    let kmTenth = (km * 10.0).rounded() / 10.0
                    if abs(kmTenth.rounded() - kmTenth) < 1e-5 {
                        return "\(Int(kmTenth.rounded()))km"
                    } else {
                        return String(format: "%.1fkm", kmTenth)
                    }
                }
            }
        }
        
        /// Tactical HUD overlay sizing, hitboxes, and symmetrical corner padding
        public enum HUD {
            #if os(watchOS)
            public static let horizontalPadding: CGFloat = 12.0
            public static let topPadding: CGFloat = 14.0
            public static let bottomPadding: CGFloat = 12.0
            
            public static let circleButtonDiameter: CGFloat = 26.0
            public static let circleIconFontSize: CGFloat = 12.0
            public static let rectButtonWidth: CGFloat = 48.0
            public static let rectButtonHeight: CGFloat = 24.0
            public static let rectCornerRadius: CGFloat = 5.0
            public static let ekgWaveSize: CGSize = CGSize(width: 32.0, height: 14.0)
            public static let ekgLineWidth: CGFloat = 1.3
            public static let ekgHaloSize: CGFloat = 5.5
            public static let ekgDotSize: CGFloat = 2.2
            public static let rulerNotchMajorWidth: CGFloat = 1.5
            public static let rulerNotchMajorHeight: CGFloat = 5.0
            public static let rulerNotchMinorWidth: CGFloat = 1.0
            public static let rulerNotchMinorHeight: CGFloat = 3.5
            public static let rulerBarWidth: CGFloat = 19.0
            public static let rulerBarHeight: CGFloat = 1.0
            public static let rulerFontSize: CGFloat = 8.0
            public static let heartRateFontSize: CGFloat = 20.0

            public static let circleHitboxSize: CGSize = CGSize(width: 48.0, height: 48.0)
            public static let rectHitboxSize: CGSize = CGSize(width: 52.0, height: 48.0)
            #else
            // iPhone UI: 2x element sizing with generous hitboxes & symmetrical safe-area centering
            public static let horizontalPadding: CGFloat = 24.0
            public static let topPadding: CGFloat = 56.0
            public static let bottomPadding: CGFloat = 34.0
            
            public static let circleButtonDiameter: CGFloat = 52.0
            public static let circleIconFontSize: CGFloat = 22.0
            public static let rectButtonWidth: CGFloat = 96.0
            public static let rectButtonHeight: CGFloat = 48.0
            public static let rectCornerRadius: CGFloat = 10.0
            public static let ekgWaveSize: CGSize = CGSize(width: 64.0, height: 28.0)
            public static let ekgLineWidth: CGFloat = 2.2
            public static let ekgHaloSize: CGFloat = 9.0
            public static let ekgDotSize: CGFloat = 4.0
            public static let rulerNotchMajorWidth: CGFloat = 2.5
            public static let rulerNotchMajorHeight: CGFloat = 8.0
            public static let rulerNotchMinorWidth: CGFloat = 2.0
            public static let rulerNotchMinorHeight: CGFloat = 6.0
            public static let rulerBarWidth: CGFloat = 40.0
            public static let rulerBarHeight: CGFloat = 2.0
            public static let rulerFontSize: CGFloat = 13.0
            public static let heartRateFontSize: CGFloat = 40.0

            public static let circleHitboxSize: CGSize = CGSize(width: 68.0, height: 68.0)
            public static let rectHitboxSize: CGSize = CGSize(width: 112.0, height: 64.0)
            #endif

            /// Duration in seconds for the numerical heart rate display to fade from full brightness to 0.
            public static let heartRateFadeDurationSeconds: Double = 3.0
        }
        
        /// Tactical Map Markers sizing and label styling
        public enum MapMarkers {
            /// Scale factor applied to other players' annotations (30% smaller)
            public static let otherPlayerScaleFactor: CGFloat = 0.70

            /// Touch priority z-indices for UI layer stacking and hit testing
            public static let greenTouchPriorityZIndex: Double = 100.0
            public static let defaultTouchPriorityZIndex: Double = 10.0

            #if os(watchOS)
            public static let playerIconSize: CGFloat = 18.0
            public static let leaderIconSize: CGFloat = 22.0
            public static let deadXIconSize: CGFloat = 18.0
            public static let markerFrameSize: CGFloat = 26.0
            public static let pulseCoreSize: CGFloat = 6.0
            
            public static let tacticalIndicatorIconSize: CGFloat = 11.2
            public static let environmentalIndicatorIconSize: CGFloat = 11.2
            public static let tacticalIndicatorRingSize: CGFloat = 16.8
            
            public static let callsignFontSize: CGFloat = 7.0
            public static let callsignYOffset: CGFloat = 20.0
            public static let orderCallsignYOffset: CGFloat = 14.0
            public static let greenTouchTargetPadding: CGFloat = 6.0
            #else
            // iPhone UI: Scaled tactical icons, frames, and legible callsign tags (38pt player icon)
            public static let playerIconSize: CGFloat = 30.0
            public static let leaderIconSize: CGFloat = 30.0
            public static let deadXIconSize: CGFloat = 22.0
            public static let markerFrameSize: CGFloat = 32.0
            public static let pulseCoreSize: CGFloat = 10.0
            
            public static let tacticalIndicatorIconSize: CGFloat = 21.0
            public static let environmentalIndicatorIconSize: CGFloat = 14.0
            public static let tacticalIndicatorRingSize: CGFloat = 22.4
            
            public static let callsignFontSize: CGFloat = 10.0
            public static let callsignYOffset: CGFloat = 30.0
            public static let orderCallsignYOffset: CGFloat = 21.0
            public static let greenTouchTargetPadding: CGFloat = 10.0
            #endif

            /// Resolves dynamic icon display size for indicators based on category (e.g. smaller environmental markers on phone to match tactical marker silhouettes).
            public static func iconSize(for category: TacticalIndicatorCategory) -> CGFloat {
                switch category {
                case .environment:
                    return environmentalIndicatorIconSize
                case .enemyIndicator, .squadOrder:
                    return tacticalIndicatorIconSize
                }
            }
        }
        
        /// Tactical Vector Shapes Geometry Calculation Constants
        public enum TacticalShapes {
            // Player Shape
            public static let playerRadiusFactor: Double = 0.38
            public static let playerLeftShoulderAngleDegrees: Double = 220.0
            public static let playerRightShoulderAngleDegrees: Double = 320.0
            
            // Squad Leader Shape
            public static let leaderRadiusFactor: Double = 0.36
            public static let leaderShoulderOffsetRatio: Double = 0.85
            public static let leaderShoulderHeightRatio: Double = 0.35
            public static let leaderWingOuterRatio: Double = 0.98
            public static let leaderWingHeightRatio: Double = 0.2
            public static let leaderInnerNotchAngle1Degrees: Double = 35.0
            public static let leaderInnerNotchAngle2Degrees: Double = 145.0
            
            // KIA Dead X Shape
            public static let deadXArmLengthRatio: Double = 0.46
            public static let deadXHalfThicknessRatio: Double = 0.13
            public static let sqrtTwo: CGFloat = 1.4142135623730951
            
            // ECG Waveform Progress Keyframes & Amplitude Ratios
            public enum ECG {
                public static let pWaveStart: CGFloat = 0.20
                public static let pWavePeak: CGFloat = 0.28
                public static let pWaveEnd: CGFloat = 0.35
                public static let qDip: CGFloat = 0.42
                public static let rPeak: CGFloat = 0.50
                public static let sDip: CGFloat = 0.58
                public static let tWaveStart: CGFloat = 0.65
                public static let tWavePeak: CGFloat = 0.73
                public static let tWaveEnd: CGFloat = 0.81
                
                public static let pWaveHeightRatio: CGFloat = 0.16
                public static let qDipDepthRatio: CGFloat = 0.15
                public static let rPeakHeightRatio: CGFloat = 0.44
                public static let sDipDepthRatio: CGFloat = 0.38
                public static let tWaveHeightRatio: CGFloat = 0.20
            }
        }
    }
    
    // MARK: - Watch Connectivity Sync
    public enum WatchConnectivity {
        public static let defaultHighSpeedCadenceSeconds: TimeInterval = 1.0
        public static let activeUntilLeaseDurationSeconds: TimeInterval = 5.0
        public static let activeAdvertisementCadenceSeconds: TimeInterval = 1.0
    }
}



