# Radar Map: Tactical Radar & Field Companion (watchOS & iOS)

[![watchOS 10.0+](https://img.shields.io/badge/watchOS-10.0%2B-black?style=flat&logo=apple)](https://developer.apple.com/watchos/)
[![iOS 17.0+](https://img.shields.io/badge/iOS-17.0%2B-black?style=flat&logo=apple)](https://developer.apple.com/ios/)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange?style=flat&logo=swift)](https://swift.org)
[![Xcode 15.0+](https://img.shields.io/badge/Xcode-15.0%2B-blue?style=flat&logo=xcode)](https://developer.apple.com/xcode/)

**Radar Map** is a tactical companion application built with SwiftUI for watchOS and iOS, engineered for airsoft, paintball, and outdoor field squad coordination.

---

## 🎯 Core Features

* 🛰️ **Dual-Presentation Tactical Display**:
  * **Map View**: Native MapKit integration with 60Hz/120Hz GPU-composited smooth user tracking, muted tactical cartography, and a live calibrated metric scale ruler.
  * **Radar View**: High-contrast, battery-optimized OLED vector radial display with 4 concentric range rings ($S, 2S, 3S, 4S$) and cardinal headings.
  * *Details:* [**`TACTICAL_UI_SPECIFICATION.md`**](docs/TACTICAL_UI_SPECIFICATION.md)
* 🧭 **Live Telemetry, Biometrics & Tag Out Reporting**:
  * Continuous GPS coordinates with dynamic speed-weighted heading blending (Compass $\leftrightarrow$ GPS Course Over Ground).
  * Real-time HealthKit (`HKWorkoutSession`) heart rate streaming with biometric stress zones and optical PPG battery duty-cycling.
  * One-touch Tag Out / Downed status reporting with visual cross-out indicators across the squad map.
  * *Details:* [**`PRIVACY_AND_COMPLIANCE.md`**](docs/PRIVACY_AND_COMPLIANCE.md)
* ⚡ **WatchConnectivity Companion Synchronization**:
  * **Completely Decoupled from Web Connections**: ALL WCSession variables and synchronization channels operate continuously offline between Phone and Watch, entirely independent of internet, cellular connection, or Firebase squad room state.
  * Immediate local rendering with persistent context staging in `WCSession`.
  * Dual-stream pipeline: high-speed stream for live sensor data (Phone GPS priority & Watch biometrics) and low-speed snapshot sync for markers, room lifecycle, and configuration.
  * Ephemeral room lifecycle state: login lifecycle state starts as inactive by default and is never saved across sessions, preventing stale session resumption on app launch.
  * Automatic network handover between paired iPhone and standalone Apple Watch.
  * *Details:* [**`COMPANION_DATA_SYNC_MODEL.md`**](docs/COMPANION_DATA_SYNC_MODEL.md)
* 📍 **Tactical Markers & Orders**:
  * Squad Leaders can deploy tactical objective points, orders (`watchHere`, `goHere`, `attackHere`, `defendHere`, `flag`), hostile unit classifications, and environmental hazards.
  * **Color Coding & Multi-Clan Affiliation**: Call signs support multi-clan tags with comma separation (`[clanA,clanB]Callsign`). Teammates sharing $\ge 1$ clan with the local user render in tactical **Green**; other teammates render in **Blue** (fading to gray if stale).
  * **Clan-Private Team Orders**: Team orders are strictly clan-private (visible only to the placer and teammates sharing at least one clan; orders from other clans are hidden). All visible team orders render in **Green**. Hostile and environmental markers remain shared squad-wide in **Red** (hostile markers feature automated 5-minute linear decay to grayscale).
  * **UX Touch Priority**: Green icons (local user, same-clan teammates, and visible same-clan orders) receive highest priority for touch sensing via elevated z-indices (`100.0`) and expanded hitboxes.
  * *Details:* [**`TACTICAL_UI_SPECIFICATION.md`**](docs/TACTICAL_UI_SPECIFICATION.md)
* 📏 **Tap-to-Measure Distance Line**:
  * Single tap on any squad member or tactical POI marker draws an interactive real-time range line from the local player to the target.
  * Displays 2D horizontal ground ($XY$) distance at its midpoint using an equirectangular planar projection (strictly altitude / $Z$-independent).
  * Automatically activates the targeted player's callsign nametag badge while attached, deactivating upon detachment.
  * Purely local UI state with touch pass-through (`allowsHitTesting(false)`), with zero network or cloud synchronization overhead.
  * *Details:* [**`TACTICAL_UI_SPECIFICATION.md`**](docs/TACTICAL_UI_SPECIFICATION.md)
* 🔍 **Discrete Decade Zoom Ladder**:
  * Digital Crown (watchOS) and pinch-to-zoom (iOS) navigation stepping through discrete $[1, 2.5, 5, 10, 25, 50, 100, 250, 500, 1000, 2500]\text{m}$ decade scales.
  * Non-destructive centering preserving active zoom distance.
  * *Details:* [**`TACTICAL_UI_SPECIFICATION.md`**](docs/TACTICAL_UI_SPECIFICATION.md)
* 🔄 **Predictive Netcode & Cloud Telemetry**:
  * Split upload scheduling: must-arrive queueing for tactical mutations; latest-only coalescing for high-frequency telemetry.
  * Dead-reckoning predictive delta gating ($3.5\text{m}$ error threshold) and remote player extrapolation smoothing.
  * Monotonic sequence numbers and timestamp watermarking to prevent out-of-order jitter.
  * *Details:* [**`CLOUD_DATA_MANAGEMENT.md`**](docs/CLOUD_DATA_MANAGEMENT.md) & [**`DEAD_RECKONING.md`**](docs/DEAD_RECKONING.md)
* 🌐 **Bring Your Own Firebase (BYO-Firebase)**:
  * Squad leaders can host private rooms on their own dedicated Google Firebase Realtime Database (100% free Spark plan) to isolate traffic from shared public room quotas.
  * Features camera Live Text OCR recognition, Lock protection, and instant teammate auto-configuration via Join QR codes.
  * *Details:* [**`BRING_YOUR_OWN_FIREBASE.md`**](docs/BRING_YOUR_OWN_FIREBASE.md)
* 💳 **RevenueCat Squad Leader Paywall**:
  * Free tier supports squads of up to 4 players with free participation in rooms of any size.
  * $29.99 lifetime unlock enables squad hosting up to 12 players and custom tactical marker placement.
  * *Details:* [**`REVENUECAT_AND_STOREKIT_SETUP.md`**](docs/REVENUECAT_AND_STOREKIT_SETUP.md)
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
| **Bandwidth Scaling**| `playerThreshold` | `12` players | Room player count ceiling before dynamic update rate reduction |
| **Bandwidth Scaling**| Heartbeat & Stale Rates | `10 × T` / `15 × T` | Fallback refresh heartbeat ($10.0\text{s}$) and stale peer cutoff ($15.0\text{s}$) |
| **Squad Capacities**| `freeTierMaxCapacity` / `proTierMaxCapacity` | `4` / `12` players | Squad room host limits for Free vs Pro tiers |
| **Monetization** | Lifetime Price / Product ID | `$29.99` / `com.radarmap.watch.pro` | One-time non-consumable Squad Leader lifetime unlock |
| **Tactical Markers**| `freeTierMaxTacticalIndicators` / `pro` | `0` / `20` markers | Concurrent active enemy & environmental markers cap |
| **Tactical Markers**| `enemyIndicatorFadeDurationSeconds` | `300.0s` (5 min) | Automatic fade-to-grayscale duration for enemy sightings |
| **UX Touch Priority**| `greenTouchPriorityZIndex` / `default` | `100.0` / `10.0` | Z-index priority ensuring green (same-clan) icons intercept touches first |
| **UX Touch Priority**| `greenTouchTargetPadding` | `10.0pt` (iOS) / `6.0pt` (watchOS) | Expanded invisible touch target padding for green tactical icons |
| **Room Identifiers**| Room ID / Entry Length | `16` total / `4–12` name | 4–12 char squad name + dynamic Crockford Base32 padding ($16 - \text{name.length}$) = fixed 16-char path key |
| **PIN Validation** | `minPinLength` / `maxPinLength`| `4` min / `16` max | Mandatory join PIN validation limits |
| **Biometrics** | Optical PPG Duty Cycle | `4.0s` active / `16.0s` sleep | 80% battery conservation duty cycling (`HealthKitManager`) |
| **Biometrics** | `flatlineHeartRate` | `0.0 BPM` | Tag Out / Downed status indicator triggered via 1.2s hold gesture |
| **Networking** | `defaultDatabaseURL` | `https://radarmap-8adf0-default-rtdb.firebaseio.com` | Default fallback Google Firebase Realtime Database endpoint |
| **Companion Sync** | `activeUntilLeaseDurationSeconds`| `5.0s` (`currentTime + 5s`)| WatchConnectivity foreground lease duration between Watch & Phone |

---

## ⚠️ Architectural & Engineering Standards

RadarMap adheres to strict zero-mock, real-time tactical synchronization standards:
* **No Fallback Data Sources**: Production targets consume data directly from authoritative sensors and streams; missing telemetry is surfaced via explicit UI states rather than masked with synthetic fallbacks.
* **No Internal Identifier Leakage**: The UI never presents internal UUIDs or member hashes while callsigns or locations are resolving.

For project generation, dual-target layout, and pull request testing standards, see [**`CONTRIBUTING.md`**](docs/CONTRIBUTING.md).

---

## 📚 Documentation

All technical architecture specifications, netcode models, and setup guides are maintained under [`docs/`](docs/):

* **Display & Interaction**:
  * [**`TACTICAL_UI_SPECIFICATION.md`**](docs/TACTICAL_UI_SPECIFICATION.md): Authoritative specification for Map & Radar views, 60Hz follow-me rules, discrete decade scale ladder, and platform MapKit adapters.
  * [**`SETTINGS_VIEW.md`**](docs/SETTINGS_VIEW.md): Layout and behavior of the gear-icon Config screen — callsign, host/join squad flow, QR scan/display, and custom database URL entry.
* **Synchronization & Netcode**:
  * [**`CLOUD_DATA_MANAGEMENT.md`**](docs/CLOUD_DATA_MANAGEMENT.md): Firebase RTDB synchronization matrix, client upload scheduling, bandwidth adaptation, and RTDB schema reference.
  * [**`COMPANION_DATA_SYNC_MODEL.md`**](docs/COMPANION_DATA_SYNC_MODEL.md): Local Apple Watch $\leftrightarrow$ iPhone `WatchConnectivity` (`WCSession`) dual-stream protocol.
  * [**`DEAD_RECKONING.md`**](docs/DEAD_RECKONING.md): Predictive delta gating formulas, velocity derivation, and receiver-side extrapolation.
* **Monetization & Compliance**:
  * [**`REVENUECAT_AND_STOREKIT_SETUP.md`**](docs/REVENUECAT_AND_STOREKIT_SETUP.md): RevenueCat, App Store Connect IAP configuration, and local Xcode StoreKit testing.
  * [**`PRIVACY_AND_COMPLIANCE.md`**](docs/PRIVACY_AND_COMPLIANCE.md): HealthKit `HKWorkoutSession` framing, background location guidelines, and legal privacy policies.
* **Developer Guides & Tooling**:
  * [**`CONTRIBUTING.md`**](docs/CONTRIBUTING.md): Architectural invariants, dual-target layout, project generation, and testing standards.
  * [**`BRING_YOUR_OWN_FIREBASE.md`**](docs/BRING_YOUR_OWN_FIREBASE.md): Step-by-step setup guide for hosting squad rooms on private Firebase instances.
  * [**`NETWORK_BENCHMARK_FIREBASE_COST_ESTIMATION.md`**](docs/NETWORK_BENCHMARK_FIREBASE_COST_ESTIMATION.md): Network benchmarking framework and Firebase RTDB cost estimation model.
  * [**`notebooks/README.md`**](notebooks/README.md): Headless multi-player Python simulator and Jupyter testing suite.
  * [**`output/README.md`**](output/README.md): Designated output destination specification for benchmark artifacts and simulation traces.
  * [**`.agents/skills/`**](.agents/skills/): Workspace Agent Skills providing modular runbooks and best practices for Firebase and Xcode workflows.

---

## 🏗️ Project Architecture

```
RadarMap/
├── RadarMapApp.swift                       # Apple Watch app entry point (#if os(watchOS))
├── AppConstants.swift                      # Global constants, decade scales & API keys
├── Models/
│   ├── AppBuildVersion.swift               # Version tracking & schema migration
│   ├── CompanionSyncModels.swift           # Low-speed & high-speed WatchConnectivity structures
│   ├── DeadReckoning.swift                 # Planar dead reckoning math & velocity derivation
│   ├── MapCenterLockState.swift            # Map locking modes (Free Roam, Locked Follow)
│   ├── MapStateMachine.swift               # MapKit camera altitude & tracking state coordinator
│   ├── PlayerVitalStateMachine.swift       # Biometric stress zones & Tag Out/Downed state machine
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
.agents/                                    # Workspace Agent Skills (Firebase, Xcode setup, etc.)
docs/                                       # Technical reference documentation & architecture specifications
├── BRING_YOUR_OWN_FIREBASE.md              # Self-hosted Google Spark RTDB setup & Live Text OCR
├── CLOUD_DATA_MANAGEMENT.md                # RTDB sync matrix, upload policies & schema reference
├── COMPANION_DATA_SYNC_MODEL.md            # Local Apple Watch <-> iPhone WCSession dual-stream protocol
├── CONTRIBUTING.md                         # Architectural invariants, project generation & PR testing standards
├── DEAD_RECKONING.md                       # Predictive delta gating math & remote player extrapolation
├── NETWORK_BENCHMARK_FIREBASE_COST_ESTIMATION.md # Network benchmark protocol & cost estimation model
├── PRIVACY_AND_COMPLIANCE.md               # HealthKit compliance, background location & privacy standards
├── REVENUECAT_AND_STOREKIT_SETUP.md        # RevenueCat IAP, StoreKit local testing & paywall rules
├── SETTINGS_VIEW.md                        # Config view specification, QR scanning & database URL input
└── TACTICAL_UI_SPECIFICATION.md            # Map & Radar view presentation, 60Hz motion & decade ladder
RadarMapTests/
└── RadarMapTests.swift                     # Unit & integration test suite (187+ tests)
RadarMapCompanion/                          # iOS (iPhone) companion target
└── RadarMapCompanionApp.swift
benchmarks/                                 # Baseline & candidate network benchmark configurations
credentials/                                # Local service-account JSON keys (gitignored)
functions/                                  # Firebase Cloud Functions (room TTL sweeps, host departure cleanup)
notebooks/                                  # Jupyter notebook & CLI player simulator (see notebooks/README.md)
output/                                     # Benchmark and simulation output destination (see output/README.md)
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
Execute unit tests from the command line:
```bash
swift test
```
Or within Xcode:
* Press `⌘U` with either `RadarMap` (watchOS) or `RadarMapCompanion` (iOS) active.

### In-App Purchases & StoreKit Testing
To validate Pro Squad Leader tier entitlements locally:
1. In Xcode, navigate to **Product > Scheme > Edit Scheme... > Run > Options**.
2. Set **StoreKit Configuration** to [`RadarMap/Resources/RadarMap.storekit`](RadarMap/Resources/RadarMap.storekit).
3. Test lifetime unlock transactions and restoration flows offline without live App Store Connect accounts.

### Opening in Xcode
`RadarMap.xcodeproj` is generated from the file tree by [`generate_xcodeproj.py`](generate_xcodeproj.py). Re-run it any time you add, remove, or move a Swift file — otherwise Xcode/`xcodebuild` won't see the change:
```bash
python3 generate_xcodeproj.py
xed .
```
Select an Apple Watch target (e.g. Apple Watch Series 9 or Ultra 2, watchOS 10+) or iPhone target (iOS 17+) to build and run.

---

## 🤝 Contributing

Contributions and issue reports are welcome! Please review [**`CONTRIBUTING.md`**](docs/CONTRIBUTING.md) for architectural invariants, dual-target layout standards, and pull request testing requirements.

---

## 📄 License

This repository is maintained for tactical simulation and development. All rights reserved. See repository settings and headers for specific distribution terms.

---

## 💬 Support & Inquiries

For tactical deployment inquiries, feature requests, or issue tracking, please open an issue in the GitHub repository or consult the in-app [**HUD Field Manual**](RadarMap/Views/Guide/HUDGuideView.swift).
