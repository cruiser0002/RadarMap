# Bring Your Own Firebase (BYO-Firebase) Guide

RadarMap allows squad leaders to host tactical rooms on their own dedicated **Google Firebase Realtime Database** project rather than the shared default project. 

This guide provides step-by-step instructions for provisioning, configuring, and connecting your own Firebase instance in under five minutes using Google's free **Spark Plan** (no credit card required).

---

## 🎯 Why Host on Your Own Firebase?

* **Zero Shared Quota Limits**: Your squad's high-cadence GPS and biometric streaming traffic runs entirely on your own project, completely isolated from shared public room traffic.
* **100% Free**: Operates within Google's generous Firebase Spark (free) tier:
  * 1 GB stored data
  * 10 GB/month network transfer
  * 100 simultaneous active connections
* **Frictionless Teammate Onboarding**: Teammates do not need a Google account or setup. When they scan your host **Join QR code**, your custom database URL, room name, and PIN are automatically transmitted and configured on their device.

---

## ⚡ Key BYO-Firebase Constants & Parameters

The following centralized constants from [`AppConstants.swift`](../RadarMap/AppConstants.swift) (`AppConstants.Network`, `AppConstants.Storage`, and `AppConstants.UI`) govern custom Firebase database configurations:

| Section & Context | Constant / Property | Value / Limit | Purpose & Architectural Scope |
| :--- | :--- | :--- | :--- |
| **Overview** | `defaultDatabaseURL` | `"https://radarmap-8adf0-default-rtdb.firebaseio.com"` | Shared fallback RTDB endpoint (`Network.defaultDatabaseURL`) |
| **Overview** | Spark Simultaneous Connections | `100` connections | Free Firebase Realtime Database concurrent client limit |
| **Overview** | Spark Storage / Transfer | `1 GB` storage / `10 GB/mo` egress | Free Firebase monthly data quotas |
| **Step 3 Rules** | Security Rules Mode | Open (`.read: true`, `.write: true`) | Allows peer synchronization without Firebase Auth accounts |
| **Step 4 URL Format** | `maxDatabaseURLLength` | `200` characters | Generous upper bound on real RTDB URLs (`Network.maxDatabaseURLLength`) |
| **Step 4 URL Format** | `isValidDatabaseURL` | `http(s)://<host>` | Scheme and non-empty host validation before SDK initialization |
| **Connecting** | `customDatabaseURLKey` | `"custom_database_url"` | UserDefaults persistence key for custom RTDB endpoint |
| **Connecting** | `isCustomDatabaseURLEnabledKey` | `"is_custom_database_url_enabled"` | UserDefaults key for the custom-vs-default RTDB switch (default `true`) |
| **Connecting** | `recentDatabaseURLsKey` / `maxRecentDatabaseURLs` | `"recent_database_urls"` / `3` max | Recent custom URL suggestions dropdown (`Storage` / `UI`) |
| **QR Code Join** | `minRoomNameEntryLength` / `maxRoomNameEntryLength` | `4` min / `12` max characters | Squad name character limits (`UI.minRoomNameEntryLength`) |
| **QR Code Join** | `minPinLength` / `maxPinLength` | `4` min / `16` max characters | Mandatory squad PIN character limits, ASCII alphanumeric (`UI.minPinLength`) |
| **QR Code Join** | Room Path Key Length | `16` characters total | 4–12 char name + dynamic Crockford Base32 padding ($16 - \text{name.length}$) (`maxRoomNameLength`) |
| **QR Code Join** | Encoded QR Payload | Minified JSON (`{"d":"...","p":"...","r":"..."}`) | Compact JSON payload with sorted keys (`QRJoinPayload.swift`) |

---

## 🛠️ Step-by-Step Setup Instructions

### Step 1: Create a Google Firebase Project
1. Navigate to the [Firebase Console](https://console.firebase.google.com/) and sign in with your Google account.
2. Click **Add project** (or **Create a project**).
3. Enter a project name (e.g., `radarmap-squad` or `milsim-ops`).
4. **Google Analytics**: Toggle **Disable Google Analytics** (RadarMap does not use or require Analytics), then click **Create project**.

### Step 2: Provision a Realtime Database
1. In the left navigation menu, expand **Build** and select **Realtime Database**.
2. Click **Create Database**.
3. **Database Location**: Select the region geographically closest to your squad for lowest latency (e.g., `us-central1`, `europe-west1`, `asia-southeast1`).
4. **Security Rules Mode**: Choose either *Locked Mode* or *Test Mode* (you will replace the rules in the next step). Click **Enable**.

### Step 3: Configure Security Rules
1. In your Realtime Database view, click the **Rules** tab.
2. Replace the contents of the rules editor with:
   ```json
   {
     "rules": {
       ".read": true,
       ".write": true
     }
   }
   ```
3. Click **Publish**.
   > **Note:** Open read/write rules allow RadarMap's multi-client peer mesh to sync rooms, telemetry packets, and tactical markers without requiring Firebase Authentication accounts. Telemetry and tactical indicators are protected via client-side End-to-End Encryption (AES-256-GCM) derived from the squad room PIN, ensuring packets remain unreadable to outside observers.

### Step 4: Copy Your Database URL
1. Switch to the **Data** tab.
2. At the top of the data hierarchy tree, locate your database reference URL:
   * Format: `https://<your-project-id>-default-rtdb.firebaseio.com/` (or `...firebasedatabase.app`)
3. Copy this URL to your clipboard.

---

## 📱 Connecting RadarMap to Your Database

### Option A: Live Camera Text Recognition (iOS)
1. Open RadarMap on your iPhone.
2. Navigate to **Config** via the gear icon in the upper-left of the map HUD (see [`SETTINGS_VIEW.md`](SETTINGS_VIEW.md)).
3. Make sure the **Custom URL** switch beside the database URL field is ON (it is by default); the camera button is disabled while the switch is OFF.
4. Tap the **Camera Viewfinder Icon** (`camera.viewfinder`) beside the database URL field.
5. Point your camera at the Firebase Console screen showing your database URL. iOS Live Text recognition will automatically scan and populate the URL into the field.

### Option B: Manual Entry, Clipboard Paste, or Recent URLs
1. Open **Config** via the gear icon in the map HUD in RadarMap.
2. Make sure the **Custom URL** switch beside the field is ON (it is by default).
3. Tap the **Database URL** field (placeholder: `Enter custom URL`).
4. Type or paste your copied Firebase URL. If you previously connected to custom databases, focusing the field also displays up to 3 recent URLs below it for quick selection.

> **Tip:** To return to the shared RadarMap cloud at any time, toggle the **Custom URL** switch OFF (the field will display `"using default server"` and gray out the camera button). The app immediately reverts to the default shared infrastructure without losing the custom URL you entered.

---

## 📲 Teammate Auto-Configuration via QR Code

Once you host a room on your custom Firebase project:
1. Your device displays a **"SCAN TO JOIN"** QR code containing an encoded `QRJoinPayload` JSON object (with sorted keys):
   ```json
   {"d":"https://your-project.firebaseio.com","p":"1234","r":"ALPHA"}
   ```
   *(Note: When hosting on the shared default database, `d` is empty `""`, causing joiners to resolve the shared default endpoint on their own devices.)*
2. Teammates open RadarMap, tap the gear icon to open **Config**, and tap the **SCAN TO JOIN** box (showing the `qrcode.viewfinder` icon).
3. Upon scanning with their camera, their app automatically decodes the JSON payload and populates:
   * **Room Name** (`r`)
   * **Room PIN** (`p`, 4–16 alphanumeric characters)
   * **Custom Database Endpoint** (`d`, automatically enabling their Custom URL switch)
4. Teammates connect directly to your private Firebase project without any manual typing or configuration!

> **Note:** Any connected squad member (host or joined client) has their device display the room's join QR code so that any member can onboard teammates. On Apple Watch, the QR code is also rendered directly on the watch display (120×120 pt), allowing teammates with iPhones to scan the squad leader's watch.

---

## 🔒 Input Sanitization

Every field that feeds into this flow is sanitized at the point of entry, not just length-checked, since some of these values become literal Firebase Realtime Database path segments where a stray character can break the connection outright:

* **Room Name & PIN** are restricted to plain ASCII letters and digits (`A-Z`, `0-9`) — typing Greek letters, emoji, CJK, or symbols like `.`/`#`/`$`/`[`/`]` simply has no effect, since those characters are silently dropped as you type rather than accepted and later rejected by Firebase. This exists because the room name becomes part of the actual database path key, and RTDB keys reject `. # $ [ ]` and control characters outright; non-ASCII characters are excluded too because they can throw off the deterministic name+PIN padding math that builds that key (see [`CLOUD_DATA_MANAGEMENT.md`](CLOUD_DATA_MANAGEMENT.md) §6.A.1).
* **Custom Database URL** can't use that same narrow filter — a real URL needs `: / . -` at minimum — so instead it accepts the full set of characters a URL is allowed to contain (RFC 3986) and strips everything else (control characters, whitespace, non-ASCII text), including from camera-scanned text. This still won't fix a URL that's structurally wrong (e.g. missing `https://`) — that's caught separately, and the field turns red until it parses as a valid `http(s)://host` URL.
* **Takeaway for anyone extending this screen:** if you add a new text field here, decide *before* wiring it up whether its value ever becomes a literal RTDB path segment. If yes, restrict it to a narrow, Firebase-key-safe character set (plain alphanumerics is simplest); if it's only ever stored or transmitted as a value (like Callsign), length/trim validation is enough — don't over-restrict user-facing text that doesn't need it.

---

## ⚖️ Architecture Comparison: Custom vs. Shared Default

| Feature / Behavior | Shared RadarMap Project | Bring Your Own Firebase |
| :--- | :--- | :--- |
| **Hosting Account** | RadarMap Default Infrastructure | Your Personal Google Account |
| **Cost** | 100% Free | 100% Free (Spark Plan) |
| **Bandwidth Allocation** | Shared across public users | Dedicated solely to your squad |
| **Teammate Setup** | None (instant join) | None (instant QR scan) |
| **Data Retention** | Auto-pruned via hourly `cleanExpiredRooms` sweep after a 12h idle TTL (`idleCutoffHours = 12.0`, refreshed hourly by active hosts) | Remains until deleted via Firebase Console |
| **Security Rules** | Key-format & membership gating (room/member ID shape, `exp` field required, root locked down) — no validation on telemetry payload values themselves | Open `.read: true, .write: true` |

---

## 🔍 Troubleshooting & FAQ

* **"Permission Denied" Errors:**
  * Double-check Step 3. Ensure both `".read"` and `".write"` are set to `true` and you clicked **Publish**.
* **URL Formatting:**
  * Ensure the URL begins with `https://` (or `http://`), contains a valid host (e.g. `*.firebaseio.com` or `*.firebasedatabase.app`), and does not exceed 200 characters (`AppConstants.Network.maxDatabaseURLLength`).
* **Custom URL Switch:**
  * The **Custom URL** switch must stay ON for your typed database URL to actually be used — flipping it OFF displays `"using default server"`, grays out the field and camera button, and forces the shared default RTDB regardless of what's saved there. An explicit database URL from a scanned join QR code always applies on top of this switch, so scanning a teammate's code still works even with your own switch OFF.
* **Data Retention & Pruning:**
  * Unlike the shared default project, where rooms expire after a 12h idle TTL (`idleCutoffHours = 12.0`, refreshed hourly by active hosts) and an hourly Cloud Functions sweep (`cleanExpiredRooms` in [`functions/index.js`](../functions/index.js)) prunes them, custom Firebase projects do not have this scheduled job. Expired squad data remains until cleared manually via your Firebase Console Data tab.
* **Quota Upgrades:**
  * If your squad outgrows the Spark plan's free quota (100 simultaneous connections or 10 GB/month egress), Firebase will prompt you to upgrade that specific project to Blaze (pay-as-you-go). This only affects your personal project and has zero effect on the shared project or other hosts.
* **In-App Guide Reference:**
  * This guide is also embedded natively inside the app under: **Config (gear icon) → HUD Guide → Your Own Firebase**.
