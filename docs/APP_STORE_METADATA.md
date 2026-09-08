# App Store Connect Submission Metadata & Review Package

This document contains the complete, production-ready App Store Connect listing metadata, compliance disclosures, and App Review instructions for **Radar Map** (iOS & watchOS companion).

---

## 📱 App Store Listing Information

### App Information
* **App Name (max 30 chars):** `Radar Map: Squad Tactical HUD`
* **Subtitle (max 30 chars):** `Live Field GPS & Team Radar`
* **Primary Category:** `Navigation`
* **Secondary Category:** `Sports`
* **Content Rights:** Contains only proprietary assets and Apple system symbols.
* **Age Rating:** `4+` (No objectionable material, no gambling, no adult content).

### URLs & Legal Agreements
* **Privacy Policy URL:** `https://www.privacypolicies.com/live/ffdebf4f-ec87-4552-aa22-f438f6fabc94`
* **Terms of Use (EULA) URL:** `https://www.apple.com/legal/internet-services/itunes/dev/stdeula/`
* **Support URL:** `https://forms.gle/pCuy2zJtSfLoyqj16`
* **Support Email:** `sweetdreamsdeveloper@gmail.com`

---

## 📝 Promotional Text & Description

### Promotional Text (max 170 chars)
> Coordinate your squad in real time with a tactical radar HUD, live GPS navigation, biometric exertion tracking, and end-to-end encrypted room synchronization.

### Full Description (max 4,000 chars)
```markdown
Radar Map is a real-time tactical navigation and athletic squad coordination companion designed for outdoor tactical sports, airsoft, paintball, milsim, search exercises, and team outdoor training.

Turn your iPhone and Apple Watch into a unified tactical heads-up display. Track teammate positions, share course over ground, monitor team biometric exertion, and place field markers with zero friction.

TACTICAL RADAR & MAP HUD
• Circular tactical radar sweep display with dynamic range scaling from 50m to 2.5km.
• Smooth compass and GPS course-over-ground (COG) speed blending for accurate directional headings.
• Dynamic dead reckoning smoothing for real-time teammate positioning even in contested network conditions.
• MapKit satellite and standard hybrid presentation with one-tap center lock and range ruler.

TEAM SQUAD COORDINATION
• Create or join ephemeral squad rooms using custom room names and secure PIN codes.
• QR code instant join: scan a host's on-screen QR code with your iPhone camera to instantly join the squad.
• Visual squad roster displaying teammate callsigns, relative headings, and live exertion vitals.
• Tactical map indicators: drop team orders (Watch, Go, Attack, Defend, Flag, Waypoints), enemy sightings (Infantry, Vehicles, Armor, Drones), and environmental hazard markers (Hazard, Fire, Water, Closure, Emergency).

APPLE WATCH STANDALONE & COMPANION INTEGRATION
• Run independently on Apple Watch or pair seamlessly with iPhone.
• Integrated Apple HealthKit workout session records athletic exertion and cardiovascular stress zones during outdoor training exercises.
• Low-power optical PPG sampling preserves battery life while maintaining continuous background situational awareness.
• Physical Digital Crown zoom control snaps through calibrated tactical scale decades.

SECURITY & EPHEMERAL PRIVACY
• End-to-End Encryption (E2EE): Telemetry coordinates, headings, heart rate, and tactical markers are encrypted with AES-256-GCM derived from your squad room PIN.
• No account creation, passwords, or personal identity required.
• All room telemetry is strictly ephemeral: purged immediately upon room disbandment or automatically pruned after inactivity.
• Bring Your Own Firebase: advanced operators can connect directly to their private Firebase Realtime Database.

SQUAD LEADER PRO UPGRADE
• Squad Leader Lifetime is a one-time non-consumable unlock. No recurring subscriptions.
• Expand squad capacity from 4 players up to 12 players.
• Unlock tactical map marker placement and team order broadcast capabilities.
• Teammates can always join any squad for free.

--------------------------------------------------
BATTERY & BACKGROUND LOCATION DISCLAIMER (Guideline 2.5.4 / 5.1.5):
Continued use of GPS running in the background can dramatically decrease battery life.
--------------------------------------------------
```

### Keywords (max 100 chars comma-separated)
`tactical,radar,milsim,airsoft,paintball,squad,gps,map,navigation,heart rate,workout,compass,hud`

---

## 🛡️ App Review Information (Notes for the Reviewer)

Copy and paste the following into the **App Review Information -> Notes** field in App Store Connect:

```text
Dear App Review Team,

Thank you for reviewing Radar Map. Below are the details to help test the app's functionality, background modes, and HealthKit integration:

1. NO LOGIN OR ACCOUNT REQUIRED:
Radar Map uses temporary, ephemeral squad rooms. No user account, phone number, or login credentials are required.

2. HOW TO TEST IN SINGLE-PLAYER MODE:
- Launch the app on iPhone or Apple Watch.
- Tap "Config" (gear icon) in the top-right corner.
- Enter a Callsign (e.g. "ALPHA-1"), Room Name (4-12 characters, e.g. "TESTROOM"), and a 4-digit PIN (e.g. "1234").
- Tap "Host" to create an active squad session.
- You will see your local tactical blip on the radar HUD, compass heading, and GPS location.
- Tap the center display to toggle between the Radar HUD and MapKit view.
- To test tactical indicators (if testing Squad Leader Pro): tap the indicator menu at the bottom to place field markers on the map.
- Tap "Config" -> "Disband" to end the session.

3. BACKGROUND MODES JUSTIFICATION (Guideline 2.5.4):
- iOS 'location' (UIBackgroundModes): Radar Map provides real-time tactical field navigation for outdoor sports (airsoft, milsim, search exercises). Operators stow their iPhone in a tactical vest or pocket during active matches while the app broadcasts coordinates to their squad and paired Apple Watch. A blue background location indicator (showsBackgroundLocationIndicator) is displayed in iOS when running in the background.
- watchOS 'workout-processing' (WKBackgroundModes): The watchOS app utilizes HKWorkoutSession to track high-intensity cardiovascular exertion and record an athletic outdoor workout into Apple HealthKit while streaming real-time heart rate vitals to squadmates.

4. BATTERY DISCLAIMER (Guideline 5.1.5):
The mandatory background GPS disclaimer ("Continued use of GPS running in the background can dramatically decrease battery life.") is included in our App Store Description and inside the app's Policy view (Config -> Policy).

5. IN-APP PURCHASE:
The app offers an optional non-consumable lifetime unlock ("Squad Leader Lifetime", product ID: com.radarmap.watch.pro) to host squads larger than 4 players and drop custom field markers. The StoreKit 2 paywall contains a functional Restore Purchases button, EULA link, and Privacy Policy link.

If you have any questions or require additional details, please contact us at sweetdreamsdeveloper@gmail.com.
```
