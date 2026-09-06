# Radar Map: Your Milsim Companion (watchOS & iOS)

**Radar Map** is a tactical companion application built with SwiftUI for watchOS and iOS, engineered for milsim (military simulation), airsoft, paintball, and outdoor tactical squad coordination.

---

## 🎯 Core Features

* 🛰️ **Dual-Presentation Tactical Display**:
  * **Map View**: Native MapKit integration with 60Hz/120Hz GPU-composited smooth user tracking, muted tactical cartography, and a live calibrated metric scale ruler.
  * **Radar View**: High-contrast, battery-optimized OLED vector radial display with 4 concentric range rings ($S, 2S, 3S, 4S$) and cardinal headings.
  * *Details:* [**`TACTICAL_UI_SPECIFICATION.md`**](TACTICAL_UI_SPECIFICATION.md) & [**`MAPKIT_EQUIVALENTS.md`**](MAPKIT_EQUIVALENTS.md)
* 🧭 **Live Telemetry, Biometrics & KIA Reporting**:
  * Continuous GPS coordinates with dynamic speed-weighted heading blending (Compass $\leftrightarrow$ GPS Course Over Ground).
  * Real-time HealthKit (`HKWorkoutSession`) heart rate streaming with biometric stress zones and optical PPG battery duty-cycling.
  * One-touch KIA / Downed status reporting with visual cross-out indicators across the squad map.
  * *Details:* [**`PRIVACY_AND_COMPLIANCE.md`**](PRIVACY_AND_COMPLIANCE.md)
* ⚡ **WatchConnectivity Companion Synchronization**:
  * Immediate local rendering with persistent context staging in `WCSession`.
  * Dual-stream pipeline: high-speed stream for live sensor data (Phone GPS priority & Watch biometrics) and low-speed snapshot sync for markers, room lifecycle, and configuration.
  * Automatic network handover between paired iPhone and standalone Apple Watch.
  * *Details:* [**`COMPANION_DATA_SYNC_MODEL.md`**](COMPANION_DATA_SYNC_MODEL.md)
* 📍 **Tactical Markers & Orders**:
  * Squad Leaders can deploy tactical objective points, orders (`watchHere`, `goHere`, `attackHere`, `defendHere`, `flag`), hostile unit classifications, and environmental hazards.
  * Hostile markers feature automated 5-minute linear decay to grayscale.
  * *Details:* [**`TACTICAL_UI_SPECIFICATION.md`**](TACTICAL_UI_SPECIFICATION.md)
* 🔍 **Discrete Decade Zoom Ladder**:
  * Digital Crown (watchOS) and pinch-to-zoom (iOS) navigation stepping through discrete $[1, 2.5, 5, 10, 25, 50, 100, 250, 500, 1000, 2500]\text{m}$ decade scales.
  * Non-destructive centering preserving active zoom distance.
  * *Details:* [**`TACTICAL_UI_SPECIFICATION.md`**](TACTICAL_UI_SPECIFICATION.md)
* 🔄 **Predictive Netcode & Cloud Telemetry**:
  * Split upload scheduling: must-arrive queueing for tactical mutations; latest-only coalescing for high-frequency telemetry.
  * Dead-reckoning predictive delta gating ($3.5\text{m}$ error threshold) and remote player extrapolation smoothing.
  * Monotonic sequence numbers and timestamp watermarking to prevent out-of-order jitter.
  * *Details:* [**`CLOUD_DATA_MANAGEMENT.md`**](CLOUD_DATA_MANAGEMENT.md), [**`DEAD_RECKONING.md`**](DEAD_RECKONING.md), & [**`ROOM_ID_HARDENING.md`**](ROOM_ID_HARDENING.md)
* 🌐 **Bring Your Own Firebase (BYO-Firebase)**:
  * Squad leaders can host private rooms on their own dedicated Google Firebase Realtime Database (100% free Spark plan) to isolate traffic from shared public room quotas.
  * Features camera Live Text OCR recognition, Lock protection, and instant teammate auto-configuration via Join QR codes.
  * *Details:* [**`BRING_YOUR_OWN_FIREBASE.md`**](BRING_YOUR_OWN_FIREBASE.md)
* 💳 **RevenueCat Squad Leader Paywall**:
  * Free tier supports squads of up to 4 operators with free participation in rooms of any size.
  * $29.99 lifetime unlock enables squad hosting up to 12 operators and custom tactical marker placement.
  * *Details:* [**`REVENUECAT_AND_STOREKIT_SETUP.md`**](REVENUECAT_AND_STOREKIT_SETUP.md)
* 📖 **Interactive HUD Field Manual**:
  * Integrated in-app onboarding guide with interactive diagrams for hardware controls, tactical glyphs, and BYO-Firebase setup.

---

## ⚡ Key System Constants & Default Configuration

The application is parameterized by centralized constants in [`RadarMap/AppConstants.swift`](RadarMap/AppConstants.swift). The most critical constants across all functional areas are summarized below:

| Functional Area | Constant / Parameter | Default Value | Behavioral Impact & Scope |
| :--- | :--- | :--- | :--- |
| **Tactical Scale** | `defaultScale` | `50.0m` | Default minor zoom scale on initial room launch (`TacticalScalePolicy`) |
| **Tactical Scale** | Scale Ladder | `[1, 2.5, 5, 10, ..., 2500]m` | Discrete logarithmic decade scale ladder (1m to 2.5km) |
| **Radar Display** | `rangeRingRatios` | `[0.25, 0.5, 0.75, 1.0]` | Multipliers for concentric radar rings ($S, 2S, 3S, 4S$) |
| **Radar Display** | `radarUIHz` | `20.0 Hz` (50ms) | OLED vector CRT sweep and entity rendering refresh rate |
| **Map Tracking** | Follow-Me Compositor | `60Hz` / `120Hz` | Native MapKit `showsUserLocation` tracking rate (no timer loops) |
| **Map Centering** | `centerThresholdMeters` | `10.0m` | Pan displacement deadband before unlocking follow mode |
| **Dead Reckoning** | `maxPredictedPositionErrorMeters`| `3.5m` | Extrapolation error gate before transmitting GPS telemetry |
| **Dead Reckoning** | `minHeartRateDeltaBpm` | `12.0 BPM` | Biometric gate threshold (passive when `heartRateDeltaGatingEnabled` = false) |
| **Dead Reckoning** | Extrapolation Cadence | `1.0 Hz` | Cadence for locally recomputing remote squad positions |
| **Bandwidth Scaling**| `playerThreshold` | `12` operators | Room player count ceiling before dynamic update rate reduction |
| **Bandwidth Scaling**| Heartbeat & Stale Rates | `10 × T` / `15 × T` | Fallback refresh heartbeat ($10.0\text{s}$) and stale peer cutoff ($15.0\text{s}$) |
| **Squad Capacities**| `freeTierMaxCapacity` / `proTierMaxCapacity` | `4` / `12` operators | Squad room host limits for Free vs Pro tiers |
| **Monetization** | Lifetime Price / Product ID | `$29.99` / `com.radarmap.watch.pro` | One-time non-consumable Squad Leader lifetime unlock |
| **Tactical Markers**| `freeTierMaxTacticalIndicators` / `pro` | `0` / `20` markers | Concurrent active enemy & environmental markers cap |
| **Tactical Markers**| `enemyIndicatorFadeDurationSeconds` | `300.0s` (5 min) | Automatic fade-to-grayscale duration for enemy sightings |
| **Room Identifiers**| Room ID / Entry Length | `16` total / `4–12` name | 12-char squad name + 4-char PIN-derived SHA-256 padding |
| **PIN Validation** | `minPinLength` / `maxPinLength`| `4` min / `16` max | Mandatory join PIN validation limits |
| **Biometrics** | Optical PPG Duty Cycle | `4.0s` active / `16.0s` sleep | 80% battery conservation duty cycling (`HealthKitManager`) |
| **Biometrics** | `flatlineHeartRate` | `0.0 BPM` | KIA / Downed status indicator triggered via 1.2s hold gesture |
| **Networking** | `defaultDatabaseURL` | `https://radarmap-8adf0-default-rtdb.firebaseio.com` | Default fallback Google Firebase Realtime Database endpoint |
| **Companion Sync** | `activeUntilLeaseDurationSeconds`| `5.0s` (`currentTime + 5s`)| WatchConnectivity foreground lease duration between Watch & Phone |

---

## ⚠️ Core Engineering Rule: No Fallback Datasources or Placeholder Masking

* **Datasource Resilience Over Fallbacks**: NEVER introduce fallback data sources, secondary compensatory lookup pipelines, or synthetic placeholder stitching unless explicitly specified.
* **Direct Authoritative Consumption**: Consume data directly from authoritative sources as-is. If a field or property (e.g., player callsign) is not yet available, it remains empty or unrendered until delivered by the authoritative stream.
* **No ID / Mock Leakage**: NEVER fall back to internal identifiers (such as UUIDs, member IDs, or synthetic keys) as user-facing values. Doing so masks data gaps, causes unpredictable race conditions, and produces UI flickering.

---

## 📚 Technical Architecture & Instructional Documents

All operational procedures, netcode specifications, and compliance rules are maintained in dedicated reference documents:

### 📖 Instructional & Setup Guides
* [**Bring Your Own Firebase Guide**](BRING_YOUR_OWN_FIREBASE.md): Step-by-step instructions for hosting rooms on your own free Google Firebase Realtime Database with camera Live Text OCR scanning and instant QR auto-onboarding for squadmates.
* [**In-App Purchases & RevenueCat Setup**](REVENUECAT_AND_STOREKIT_SETUP.md): App Store Connect IAP setup, RevenueCat dashboard configuration, offerings, entitlements, and local Xcode StoreKit testing.
* [**Privacy, Policy & App Store Compliance Standards**](PRIVACY_AND_COMPLIANCE.md): Complete guidelines for App Store review approval, HealthKit, background location, mandatory paywall EULA/Privacy links, permission lifecycles, and privacy policy generation.

### ⚙️ Netcode, Synchronization & Architecture Specifications
* [**Tactical UI & Radar Specification**](TACTICAL_UI_SPECIFICATION.md): Authoritative UI/UX specification covering Map and Radar presentations, discrete decade scale ladders, 60Hz native follow-me motion rules, and platform adapters.
* [**Dead Reckoning & Predictive Delta Gating**](DEAD_RECKONING.md): Predictive delta compression, dual-sample velocity derivation, and local extrapolation for smooth remote player rendering.
* [**Room ID Hardening & Schema Architecture**](ROOM_ID_HARDENING.md): 16-character PIN-derived room ID padding, role migration, short leaf keys, and tactical indicator pruning.
* [**Cloud Data Management Architecture**](CLOUD_DATA_MANAGEMENT.md): Cloud Data Matrix, delta gating, dead reckoning, late packet rejection, and scheduled Cloud Functions garbage collection.
* [**Local Companion Data Sync Architecture**](COMPANION_DATA_SYNC_MODEL.md): `WatchConnectivity` (`WCSession`) dual-stream sync protocol, immediate local rendering, and phone preference network handover.
* [**MapKit Equivalents & Native Behavioral Standards**](MAPKIT_EQUIVALENTS.md): MapKit native behaviors, camera altitude trigonometry, `UserAnnotation` standards, and discrete decade zoom scales.

---

## 🏗️ Project Architecture

```
RadarMap/
├── RadarMapApp.swift                       # Multiplatform app entry point (watchOS & iOS)
├── AppConstants.swift                      # Global constants, decade scales & API keys
├── Models/
│   ├── AppBuildVersion.swift               # Version tracking & schema migration
│   ├── CompanionSyncModels.swift           # Low-speed & high-speed WatchConnectivity structures
│   ├── DeadReckoning.swift                 # Planar dead reckoning math & velocity derivation
│   ├── MapCenterLockState.swift            # Map locking modes (Free Roam, Locked Follow)
│   ├── MapStateMachine.swift               # MapKit camera altitude & tracking state coordinator
│   ├── PlayerVitalStateMachine.swift       # Biometric stress zones & KIA/Downed state machine
│   ├── QRJoinPayload.swift                 # Join QR code payload model & parser
│   ├── RadarColorTheme.swift               # Tactical CRT & NVG color palettes (Red / Green)
│   ├── SessionStateMachine.swift           # Squad session lifecycle (disconnected, hosting, joined, error)
│   ├── SquadMember.swift                   # Member profile, coordinates, heading, vitals, role & stale status
│   ├── SquadRoom.swift                     # Squad room configuration, PIN, capacity & expiry
│   ├── TacticalHUDCallout.swift            # HUD Field Manual guide categories and glyph codes
│   ├── TacticalIndicator.swift             # Field markers (Orders, Enemy, Environmental hazards)
│   ├── TacticalPresentation.swift          # Map view vs Radar view presentation state
│   ├── TacticalScalePolicy.swift           # Discrete logarithmic scale ladder & snapping policy
│   └── TelemetryPacket.swift               # Wire format with sequence numbers, timestamps & delta gating
├── Managers/
│   ├── FirebaseSyncManager.swift           # Firebase RTDB sync engine (Realtime Database SDK) with late-packet rejection
│   ├── GameStateManager.swift              # Central environment coordinator binding sensors, room & UI
│   ├── HealthKitManager.swift              # HKWorkoutSession for live watchOS heart rate collection & duty cycling
│   ├── LocationHeadingManager.swift        # CoreLocation GPS & compass heading stream with speed blending
│   ├── NetworkQualityMonitor.swift         # NWPathMonitor network reachability, RTT latency & jitter grading
│   ├── RTDBTransport.swift                 # RTDBTransport protocol + FirebaseDatabase SDK-backed implementation
│   ├── SubscriptionManager.swift           # RevenueCat lifetime squad unlock & StoreKit logic
│   └── WatchConnectivityManager.swift      # WCSession companion data bridge & network handover
├── Views/
│   ├── ContentView.swift                   # App root: hosts TacticalRadarMapView and drives scene-phase lifecycle
│   ├── ModelPresentationExtensions.swift   # Presentation helpers and UI formatters
│   ├── Map/
│   │   ├── TacticalRadarMapView.swift      # Primary tactical interface with Crown zoom & HUD overlays
│   │   ├── StandardMapView.swift           # Native MapKit map with custom vector annotations (watchOS)
│   │   ├── RadarMapView.swift              # High-contrast OLED CRT radar sweep view
│   │   ├── CrownInputView.swift            # Digital Crown rotational input binder for watchOS
│   │   ├── MemberAnnotationView.swift      # Teammate directional blip, heading cone & BPM pulse badge
│   │   ├── TacticalIndicatorMenuView.swift # Quick action menu for dropping tactical markers
│   │   ├── TacticalIndicatorOverlayView.swift # Tactical marker layer with 5-minute decay & GPU caching
│   │   ├── SquadTacticalIcons.swift        # Custom vector shapes for leaders, players, and markers
│   │   └── iOS/
│   │       └── TacticalMKMapView.swift     # High-performance UIKit MKMapView wrapper with CADisplayLink (iOS)
│   ├── Guide/
│   │   └── HUDGuideView.swift              # Interactive HUD field manual & visual onboarding guide
│   ├── Room/
│   │   ├── RoomDiscoveryView.swift         # Squad creation & direct PIN join interface
│   │   ├── CreateRoomView.swift            # Room creator with capacity selector & paywall trigger
│   │   ├── SquadLobbyView.swift            # Squad roster, member ready states & mission countdown
│   │   ├── DatabaseURLField.swift          # Custom RTDB URL input with Live Text camera OCR scanning
│   │   ├── JoinQRBox.swift                 # Join QR code display box and scanner trigger
│   │   ├── QRCodeView.swift                # CIQRCodeGenerator vector QR barcode renderer
│   │   └── QRScannerView.swift             # AVCaptureSession camera scanner for join QR codes
│   ├── Paywall/
│   │   └── PaywallView.swift               # RevenueCat lifetime unlock paywall with EULA and Privacy links
│   └── Settings/
│       ├── SettingsView.swift              # Callsign config, theme selector, dead reckoning & stats
│       └── PolicyView.swift                # Privacy policy & terms of service modal
├── Resources/
│   ├── Assets.xcassets                     # App icons, colors, and HUD diagram assets
│   ├── GoogleService-Info.plist            # Firebase configuration
│   ├── Info.plist                          # CoreLocation & HealthKit permissions
│   └── RadarMap.storekit                   # Local StoreKit testing configuration
```

Additional top-level project contents (outside `RadarMap/`):

```
RadarMapTests/
└── RadarMapTests.swift                     # Unit & integration test suite (187+ tests)
RadarMapCompanion/                          # watchOS companion target
└── RadarMapCompanionApp.swift
functions/                                  # Firebase Cloud Functions (room TTL sweeps, indicator pruning)
notebooks/                                  # Jupyter notebook & CLI player simulator (see notebooks/README.md)
scripts/                                    # Standalone tooling (e.g. network_benchmark.py)
Package.swift                               # Swift Package Manager manifest
generate_xcodeproj.py                       # Regenerates RadarMap.xcodeproj from the file tree — must be re-run
                                             # after adding/removing/moving any Swift file, before opening in Xcode
```

---

## 🚀 Running & Testing

### Prerequisites
* Xcode 15.0+
* Swift 5.9+
* Target Platforms: **watchOS 10.0+**, **iOS 17.0+**, **macOS 14.0+**

### Run Unit Tests
```bash
swift test
```

### Opening in Xcode
`RadarMap.xcodeproj` is generated from the file tree by [`generate_xcodeproj.py`](generate_xcodeproj.py). Re-run it any time you add, remove, or move a Swift file — otherwise Xcode/`xcodebuild` won't see the change:
```bash
python3 generate_xcodeproj.py
xed .
```
Select an Apple Watch target (e.g. Apple Watch Series 9 or Ultra 2, watchOS 10+) or iPhone target (iOS 17+) to build and run.
