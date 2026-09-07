# Privacy, Policy & App Store Compliance Standards

This document establishes the mandatory privacy, policy, and Apple App Store compliance standards for **Radar Map** (watchOS & iOS). All contributors and AI coding agents modifying views, managers, entitlements, or configuration files must adhere to these requirements to guarantee approval under the [Apple App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).

---

## 📋 Table of Contents

* [Key Compliance & Privacy Constants](#-key-compliance--privacy-constants)
1. [Mandatory Legal Verbiage & View Placeholders](#1-mandatory-legal-verbiage--view-placeholders)
2. [HealthKit & Workout Session Compliance (`HKWorkoutSession`)](#2-healthkit--workout-session-compliance-hkworkoutsession)
3. [Background Location Service Compliance (iOS vs. watchOS)](#3-background-location-service-compliance-ios-vs-watchos)
4. [Permission Lifecycles & In-App Opt-Out Controls](#4-permission-lifecycles--in-app-opt-out-controls)
5. [In-App Purchase & Paywall Compliance (Guidelines 3.1.1 & 3.1.2)](#5-in-app-purchase--paywall-compliance-guidelines-311--312)
6. [Privacy Policy Generator Walkthrough (PrivacyPolicies.com)](#6-privacy-policy-generator-walkthrough-privacypoliciescom)
7. [Agent & Contributor Verification Checklist](#7-agent--contributor-verification-checklist)

---

## ⚡ Key Compliance & Privacy Constants

The following centralized constants from [`AppConstants.swift`](../RadarMap/AppConstants.swift) govern legal disclaimers, data retention windows, biometric sampling limits, and opt-out storage keys:

| Section & Domain | Constant / Identifier | Value | Legal Purpose & Compliance Scope |
| :--- | :--- | :--- | :--- |
| **§1 Legal Links** | `privacyPolicyURL` | `"https://www.privacypolicies.com/live/ffdebf4f-ec87-4552-aa22-f438f6fabc94"` | Publicly accessible privacy policy link (Guideline 5.1.1) |
| **§1 Support** | `contactEmail` | `"sweetdreamsdeveloper@gmail.com"` | Developer support contact email (`Policy.contactEmail`) |
| **§1 Support** | `contactFormURL` | `"https://forms.gle/pCuy2zJtSfLoyqj16"` | In-app Google Forms feedback / support link |
| **§1 Retention** | `idleCutoffHours` | `12.0` hours (43,200s) | Ephemeral room expiration TTL (`Timing.Inactivity`) |
| **§1 Retention** | Cloud Functions Purge | Hourly sweep (`cleanExpiredRooms`) | Purges rooms past 12h idle TTL across `/r`, `/p`, `/t` |
| **§2 Biometrics** | `flatlineHeartRate` | `0.0 BPM` | Tag Out / Downed status indicator (`Health.flatlineHeartRate`) |
| **§2 Biometrics** | `lowPowerPPGActiveDurationSeconds` | `4.0s` | Active optical PPG sensor sampling burst (`HealthKitManager`) |
| **§2 Biometrics** | `lowPowerPPGSleepDurationSeconds` | `16.0s` | Optical LED power-save sleep window (80% battery conservation) |
| **§2 Stress Zones** | Biometric Zones | `<60` (Blue), `60-99` (Green), `100-139` (Yellow), `140-174` (Orange), `≥175` (Red) | Heart rate color stress categorization (`Health.Zones`) |
| **§3 Location** | `distanceFilterMeters` | `1.0m` | CoreLocation displacement filter sensitivity (`Location`) |
| **§3 Location** | `headingFilterDegrees` | `2.0°` | CoreLocation compass heading update sensitivity (`Location`) |
| **§4 Opt-Out Keys** | `isUploadLocationEnabledKey` | `"is_upload_location_enabled"` | UserDefaults key for GPS uploading opt-out (`Storage`) |
| **§4 Opt-Out Keys** | `isUploadHeartRateEnabledKey` | `"is_upload_heart_rate_enabled"` | UserDefaults key for HealthKit uploading opt-out (`Storage`) |
| **§5 Paywall** | `freeTierMaxCapacity` / `proTierMaxCapacity` | `4` free / `12` pro | Disclosed squad capacity tiers (Guideline 3.1.2) |
| **§5 Paywall** | `lifetimePriceString` | `"$29.99"` | Non-consumable lifetime unlock price disclosure |
| **§5 Paywall** | Standard Apple EULA URL | `https://www.apple.com/legal/internet-services/itunes/dev/stdeula/` | Mandatory terms of service link on all purchase views (`Policy.termsOfServiceURL`) |

---

## 1. Mandatory Legal Verbiage & View Placeholders

Whenever creating or modifying settings views, paywalls, or policy documentation, the following disclosures and placeholders **must** remain intact:

### A. In-App Policy View (`PolicyView.swift` & `AppConstants.Policy`)
* **Live Privacy Policy URL (`AppConstants.Policy.privacyPolicyURL`)**:
  * Must point to a valid, publicly resolving webpage (e.g. PrivacyPolicies.com or custom domain). Never submit with a broken URL or 404 placeholder (immediate rejection under Guideline 5.1.1).
* **Cloud Infrastructure Disclosure**:
  * Must explicitly identify **Google Firebase Realtime Database** as the cloud data processor for real-time squad synchronization.
* **Biometrics & HealthKit Disclosure**:
  * Must clearly disclose that heart rate data is shared in real time *exclusively with members of the user's active squad room* for tactical vitals monitoring.
  * Must explicitly state that biometric data is never sold, used for advertising, or repurposed for marketing (Guideline 5.1.3).
* **Workout Recording Disclosure**:
  * Must state that an active squad session records an athletic training workout into the user's Apple Health database.
* **End-to-End Encryption (E2EE) Disclosure**:
  * Clearly declare that telemetry (GPS coordinates, heading, heart rate) and tactical markers are end-to-end encrypted using AES-256-GCM authenticated encryption derived from squad room credentials, ensuring privacy across shared and Bring-Your-Own Firebase instances (`AppConstants.Policy.encryptionDescription`).
* **Ephemeral Data Retention & Automatic Purge**:
  * Clearly declare that room telemetry (coordinates, heading, markers, vitals) is temporary:
    * Purged immediately upon manual room disbandment.
    * Automatically pruned after **12 hours of inactivity** in the backend (`AppConstants.Timing.Inactivity.idleCutoffHours = 12.0`), with public policy text disclosing up to **24 hours** for operational design margin, and active hosts extending expiration hourly via `refreshRoomExpiry`.
  * Explicitly state that no permanent user accounts or passwords are created.
* **Developer Contact & Support**:
  * Contact Email: `sweetdreamsdeveloper@gmail.com`
  * Support Form: `AppConstants.Policy.contactFormURL`

### B. Paywall View (`PaywallView.swift`)
* **Terms of Use (EULA) & Privacy Links**:
  * Every paywall or purchase view **must** include direct, clickable links to:
    * **Terms of Use (EULA)**: Apple Standard EULA (`https://www.apple.com/legal/internet-services/itunes/dev/stdeula/`) or custom terms.
    * **Privacy Policy**: `AppConstants.Policy.privacyPolicyURL`.
* **Restore Purchases**:
  * Must provide a functional "Restore Purchases" button with animated progress feedback and error alerts.
* **Pricing & Billing Transparency**:
  * Clearly state whether the purchase is a *"One-time lifetime purchase (no recurring subscriptions)"* or an auto-renewing subscription.

---

## 2. HealthKit & Workout Session Compliance (`HKWorkoutSession`)

Radar Map utilizes an `HKWorkoutSession` with `HKLiveWorkoutBuilder` on watchOS to stream continuous PPG heart rate data and maintain background execution during tactical squad sessions.

### A. Legitimate Workout Framing (Guideline 2.5.4)
* **The Rule:** Apple strictly forbids using `HKWorkoutSession` and `WKBackgroundModes: workout-processing` merely as a background networking keep-alive.
* **Compliance Requirement:**
  * Radar Map must be represented and documented as an **athletic outdoor tactical training companion** (airsoft, paintball, milsim, physical field search exercises) that tracks athletic exertion.
  * The session must record active elapsed time, dynamic heart rate zones, and finalize via `workoutBuilder.finishWorkout` and `workoutSession.end()` upon room exit.

### B. HealthKit Permission Scoping (Guideline 5.1.1(i))
In `HealthKitManager.swift`:
* Request **read-only** permission for `HKQuantityTypeIdentifier.heartRate`.
* Request **write/share** permission for `HKObjectType.workoutType()`.
* **DO NOT** request write/share permission for `heartRate` unless the app writes custom `HKQuantitySample` data. Requesting write access to unused data types triggers review rejections under Guideline 5.1.1(i).

### C. App Review Notes Justification
In App Store Connect Review Notes, include:
> *"Radar Map utilizes HKWorkoutSession on watchOS to track high-intensity outdoor tactical milsim athletic sessions. The workout session records cardiovascular exertion (heart rate) and enables continuous tactical coordination during active field training. Reviewers can test this in single-player mode by launching the Watch app and hosting a room."*

---

## 3. Background Location Service Compliance (iOS vs. watchOS)

Background location is architected differently across the two platforms:

### A. Apple Watch (watchOS)
* **No Background Location Mode:** watchOS does not offer a `location` background mode in `WKBackgroundModes`.
* **Workout Session Hosting:** Background GPS on watchOS is hosted by the active `HKWorkoutSession`. While an active workout is running with `workout-processing`, `CLLocationManager` continues receiving hardware GPS updates in the background under standard `requestWhenInUseAuthorization()`.

### B. iPhone Companion App (iOS)
* **Background Mode:** Declared in `RadarMapCompanion/Resources/Info.plist`:
  ```xml
  <key>UIBackgroundModes</key>
  <array>
      <string>location</string>
  </array>
  ```
* **Hardware Configuration:** Configured in `LocationHeadingManager.swift`:
  ```swift
  #if os(iOS)
  locationManager.allowsBackgroundLocationUpdates = true
  locationManager.pausesLocationUpdatesAutomatically = false
  #endif
  ```
* **Purpose:** Allows the operator to stow their iPhone into a tactical vest pocket or pouch while continuously transmitting GPS coordinates to squadmates and the paired Watch.

### C. Mandatory App Store Review Requirements for Background Location
1. **Mandatory Battery Disclaimer (Guideline 5.1.5):**
   * The marketing text in App Store Connect **must** include this exact sentence:
     > *"Continued use of GPS running in the background can dramatically decrease battery life."*
2. **Background Indicator Transparency:**
   * On iOS, when `allowsBackgroundLocationUpdates = true` is set, `locationManager.showsBackgroundLocationIndicator = true` should be enabled so the blue status bar pill / Dynamic Island indicator clearly indicates active tracking.
3. **Session Teardown Scope:**
   * When leaving or disbanding a room, `stopTacticalSession()` invokes `healthKitManager.stopLiveHeartRateSession()` and tears down the network/telemetry timers, but deliberately leaves `locationHeadingManager` running. Location + heading are gated on the in-app "Location" toggle and OS permission (§4), not on room membership — see §4.D.
   * `allowsBackgroundLocationUpdates`/background execution is still only meaningful while the app has a genuine reason to run in the background (an active tactical session, or a workout session on watchOS); outside of that, iOS/watchOS itself suspends the app regardless of whether `CLLocationManager` is still "updating," so this does not reintroduce unbounded background tracking.

---

## 4. Permission Lifecycles & In-App Opt-Out Controls

### A. Location Permission & Sensors Are App-Lifetime, Not Session-Scoped
* `GameStateManager.init()` calls `locationHeadingManager.requestPermissions()` / `startUpdates()` once, at app launch — this is the system prompt the user sees as the "Location" slider being on/off in Settings, and it is intentionally **not** gated on creating/joining a room.
* Once permission is granted, location + heading updates run continuously for the life of the app process (see §3.C) — joining or leaving a tactical session neither starts nor stops the underlying `CLLocationManager` feed. This ensures the "me" icon's position/heading are always live, independent of room membership. The in-app "Location" toggle (§4.C, `isUploadLocationEnabled`) is a separate, upload-only gate — it decides whether `broadcastLocalTelemetry` sends your position to the server, not whether `LocationHeadingManager` keeps sensing locally. HealthKit heart-rate is the exception: `requestAuthorization()` is still requested contextually (first tactical session start / toggle interaction) since it isn't the app's headline capability and shouldn't cold-launch-prompt.

### B. Handling `.denied` and `.restricted` Permission States
* Once a user selects "Don't Allow" on a system dialog, iOS/watchOS **permanently suppresses** future system prompts.
* Calling `requestWhenInUseAuthorization()` or `requestAuthorization()` when `.denied` is a silent no-op.

### C. In-App Opt-Out Toggles ("Location", "Health data")
Located in `SettingsView.swift`, as the last two rows of the top squad section — right after the Database URL field, with no section header (backed by the same `isUploadLocationEnabledKey` / `isUploadHeartRateEnabledKey` UserDefaults keys — only the on-screen labels/position changed, not the storage keys). Both toggles are **permission-aware**, not plain preference switches:

* **Displayed position** = `storedPreference && systemPermissionIsGranted`. If the OS permission is `.denied`/`.restricted`/`.sharingDenied`, the toggle shows OFF regardless of the stored preference — the user cannot be shown an "enabled" switch for a capability the OS is actually blocking.
* **Sliding OFF** just clears the stored preference (`isUploadLocationEnabled` / `isUploadHeartRateEnabled` = `false`); never touches the OS permission (apps cannot revoke it programmatically).
* **Sliding ON** branches on the current authorization state (`SettingsView.handlePermissionBackedToggle`):
  * **Not yet determined** — this is a genuine, still-unanswered system permission: calls `locationHeadingManager.requestPermissions()` / `healthKitManager.requestAuthorization()` directly, which shows the real one-time OS dialog, then sets the preference to `true`.
  * **Denied or restricted** — iOS/watchOS will never re-show the system dialog once denied (see §4.B), so instead of a no-op the app surfaces an alert (reusing the existing error-alert plumbing: `currentErrorText` / `showErrorAlert`) with the actual manual remediation path:
    * *Location:* `"Location access was denied. On your Watch, open Settings → Privacy & Security → Location Services → RadarMap, or manage it from the Watch app on your iPhone."`
    * *HealthKit:* `"Health access was denied. On your iPhone, open the Health app → your profile icon → Apps → RadarMap, then enable Heart Rate and Workouts."`
  * **Already authorized** — just sets the preference to `true`.

**HealthKit caveat:** Apple deliberately never exposes read-authorization status (heart rate is read-only) — only share-authorization status is introspectable. `HealthKitManager.authorizationStatus` therefore tracks `HKHealthStore.authorizationStatus(for: HKObjectType.workoutType())` (the paired share type, requested in the same call as heart-rate read) as the best available proxy, refreshed after `init` and after every `requestAuthorization` completion. This is watchOS-only — on iOS (Companion), the app never touches HealthKit directly, so `authorizationStatus` is hardcoded to `.sharingAuthorized` and the "Health data" toggle there behaves as a plain preference switch.

**Platform caveat:** there is no public watchOS API to deep-link into a specific Settings page (unlike iOS's `openSettingsURLString`), so the denied-state alert can only give instructions, not an actual jump-to-Settings button, on either platform (HealthKit access is managed via the Health app rather than Settings anyway).

**Locked mid-session:** both toggles dim to 60% opacity and `.disabled(isConnected)` — `isConnected` meaning hosting or already joined as a client with an active room, not merely mid-connect (`isJoining`/`isInitiatingHost` alone don't lock them). This is deliberate: flipping data-sharing while already in a live squad session would cause a client's telemetry stream to silently start/stop broadcasting real position or heart rate mid-game, which is exactly the kind of confusing behavior (to the flipping user and to squadmates watching their marker/HR suddenly change) this lock exists to prevent. The toggles become editable again the moment the user leaves or disbands the room.

---

## 5. In-App Purchase & Paywall Compliance (Guidelines 3.1.1 & 3.1.2)

Radar Map offers a $29.99 lifetime unlock for squads up to 12 players and custom field marker placement (`com.radarmap.watch.pro`).

### Compliance Rules for Paywalls:
1. **Functional Restore Purchases:** Must offer a working "Restore Purchases" flow with animated loading and clear user feedback.
2. **Visible Legal Links:** Must display clickable links to the **Privacy Policy** and **Terms of Use (EULA)** directly on the paywall view.
3. **No Hidden Costs or Subscription Misrepresentation:** Must state explicitly that the unlock is a one-time lifetime non-consumable purchase with no recurring fees.

---

## 6. Privacy Policy Generator Walkthrough (PrivacyPolicies.com)

To generate a fully compliant privacy policy hosted on [PrivacyPolicies.com](https://app.privacypolicies.com/wizard/privacy-policy), configure the wizard categories with the following settings:

| Step / Category | Field | Required Selection |
| :--- | :--- | :--- |
| **1. App Info** | App Name | `Radar Map` |
| | Platform | Check **Mobile App** (iOS / watchOS) |
| | Entity Type | **Individual** (or registered business) |
| | Country / State | Your operating country and jurisdiction |
| **2. Data Collected** | User Accounts | **No** (ephemeral squad rooms, no accounts) |
| | Geolocation Data | **Yes** (GPS, coordinates, heading, altitude) |
| | Health & Biometrics | **Yes** (Heart rate via Apple HealthKit) |
| | Other Data | `User-defined callsigns and temporary squad room IDs` |
| | Email / Name / Phone | **No** (uncheck unless used for direct support) |
| **3. Purpose of Use** | Service Delivery | **Yes** (live squad coordination) |
| | Communications | **Yes** (in-squad coordination) |
| | Marketing / Ads | **No** (HealthKit strictly prohibits marketing/ads) |
| **4. Third Parties** | Tracking / Cookies | **No** |
| | Advertisements | **No** |
| | Third-Party Services | **Yes**:<br>• **Google Firebase Realtime Database** (real-time sync)<br>• **Apple HealthKit** (biometrics & workout tracking)<br>• **RevenueCat / StoreKit** (IAP entitlements) |
| | Data Selling | **No** |
| **5. Retention & Purge** | Retention Duration | **Temporary / Ephemeral** (purged upon disbandment or 24-hour inactivity cutoff) |
| | Contact / Deletion | Support Email (`sweetdreamsdeveloper@gmail.com`) and Contact Form |
| **6. Children's Privacy** | Under 13 Target | **No** (service is not directed to children under 13) |

---

## 7. Agent & Contributor Verification Checklist

Before submitting code changes, verify:
- [ ] `PaywallView.swift` includes clickable links to both Privacy Policy and Terms of Use (EULA).
- [ ] `AppConstants.Policy.privacyPolicyURL` points to a live, resolving URL.
- [ ] HealthKit permissions request only read for heart rate and write for workout type (no unused write permissions).
- [ ] App Store marketing description includes the mandatory background GPS battery disclaimer.
- [ ] Leaving or disbanding a room calls `stopTacticalSession()` to immediately kill GPS and workout sessions.
- [ ] In-app upload toggles handle `.denied` permission states with settings guidance alerts.
