# Config View

The single "Config" screen, opened via the gear icon in the upper-left of the map HUD. Implemented in [`SettingsView.swift`](../RadarMap/Views/Settings/SettingsView.swift), navigation title `"Config"`. It handles callsign, hosting/joining a squad, custom Firebase database URL, radar color, data-sharing toggles, the paywall, and roster display. Shared subcomponents: [`JoinQRBox.swift`](../RadarMap/Views/Room/JoinQRBox.swift) and [`DatabaseURLField.swift`](../RadarMap/Views/Room/DatabaseURLField.swift). Related: [BRING_YOUR_OWN_FIREBASE.md](BRING_YOUR_OWN_FIREBASE.md) for the custom-Firebase setup flow this UI supports, and [TACTICAL_UI_SPECIFICATION.md](TACTICAL_UI_SPECIFICATION.md) §6 for the HUD entry point.

---

## ⚡ Key Constants & Parameters

The following centralized constants from [`AppConstants.swift`](../RadarMap/AppConstants.swift) (`AppConstants.UI` and `AppConstants.Storage`) govern input validation, field lengths, and user defaults persistence for the Config screen:

| Domain & Field | Constant / Key | Value | Purpose & Architectural Enforcement |
| :--- | :--- | :--- | :--- |
| **Room Name Entry** | `minRoomNameEntryLength` | `4` characters | Minimum allowed manual squad name input length (`UI`) |
| **Room Name Entry** | `maxRoomNameEntryLength` | `12` characters | Maximum manual squad name input length (`UI`) |
| **Full Room Path** | `maxRoomNameLength` | `16` characters | Total derived Firebase room key length ($4\text{–}12 + \text{padding}$) (`UI`) |
| **PIN Validation** | `minPinLength` / `maxPinLength` | `4` min / `16` max | ASCII alphanumeric room PIN validation boundaries (`UI`) |
| **Callsign Validation** | `minCallsignLength` / `maxCallsignLength` | `1` min / `20` max | Callsign length boundaries, gating `canHostOrJoin` (`UI`) |
| **Database URL** | `customDatabaseURLKey` | `"custom_database_url"` | UserDefaults key for custom Firebase RTDB endpoint (`Storage`) |
| **Custom URL Toggle** | `isCustomDatabaseURLEnabledKey` | `"is_custom_database_url_enabled"` | UserDefaults key for the custom-vs-default RTDB switch, default `true` (`Storage`) |
| **Recent URLs** | `recentDatabaseURLsKey` | `"recent_database_urls"` | UserDefaults key for the recently-used custom URL list (`Storage`) |
| **Recent URLs** | `maxRecentDatabaseURLs` | `3` | Max entries kept in the recent custom URL dropdown (`UI`) |
| **Data Sharing** | `isUploadLocationEnabledKey` | `"is_upload_location_enabled"` | UserDefaults key for GPS broadcast opt-out toggle (`Storage`) |
| **Data Sharing** | `isUploadHeartRateEnabledKey`| `"is_upload_heart_rate_enabled"` | UserDefaults key for HealthKit broadcast opt-out toggle (`Storage`) |
| **Debug Display** | `isDebugDisplayEnabledKey` | `"is_debug_display_enabled"` | UserDefaults key for the HUD version/netcode debug text, default `false` (`Storage`) |
| **Encryption** | `isEncryptionEnabledKey` | `"is_encryption_enabled"` | UserDefaults key for the data-encryption flag, default `true` (`Storage`) |

---

## Top section — top to bottom

1. **QR box** (`JoinQRBox`) — when not connected, a tappable `qrcode.viewfinder` icon that opens the camera to scan another squad's join QR code; a successful scan fills Squad Name, PIN, and Database URL below (name/PIN treated as a pre-derived full room id, not a plain 4–12 char name). Once connected — hosting **or** joined as a client — the box instead renders this room's own join QR code, so any member (not just the host) can hand a teammate a no-friction join code.
2. **Join** button — joins the room described by Squad Name/PIN/Database URL below. Becomes **Logout** while already joined as a client.
3. **Host** button — hosts a new room from Squad Name/PIN below. Becomes **Disband** while already hosting.
4. **Callsign** field — 1–20 characters (`AppConstants.UI.minCallsignLength` / `maxCallsignLength`), sanitized live via `GameStateManager.sanitizeCallsignInput` to ASCII alphanumerics, space, and `[`/`]` (the last two preserved so `String.clanTag` can still parse a bracket-enclosed clan tag out of the callsign — see `SquadMember.swift`), auto-uppercased; server-side/duplicate-callsign validation errors surface via `gameState.callsignError`.
5. **Role slider** (`RoleSliderView`, bound to `gameState.myRole`) — Player/Team Leader, drawn from `MemberRole.allRanksOrdered`. Leader is gated behind Pro (`MemberRole.isProRequired`): tapping or dragging to a locked rank is silently ignored (`RoleSliderView.isRankUnlocked`), and `GameStateManager.myRole`'s own getter/setter additionally clamp back to `.player` if Pro is ever lost while Leader is selected. Synced phone↔watch like every other config field — see [COMPANION_DATA_SYNC_MODEL.md §2](COMPANION_DATA_SYNC_MODEL.md#2-payload-structure). Disabled (dimmed, same as the fields below) while `isBusy`.
6. **Squad Name** field — 4–12 ASCII alphanumeric characters (`AppConstants.UI.minRoomNameEntryLength` / `maxRoomNameEntryLength`), sanitized live via `GameStateManager.sanitizeRoomNameInput` (non-alphanumeric input, including non-ASCII characters, is silently dropped as typed — see [CLOUD_DATA_MANAGEMENT.md](CLOUD_DATA_MANAGEMENT.md) §6.A.1) for manual entry; a QR-scanned value is instead treated as an already-derived full room id and only bounded by `maxRoomNameLength`.
7. **PIN** field — 4–16 ASCII alphanumeric characters (`AppConstants.UI.minPinLength` / `maxPinLength`), standard keyboard (`.asciiCapable`), sanitized via `GameStateManager.sanitizePinInput`.
8. **Database URL** field (`DatabaseURLField`) — see below.
9. **Location** toggle — see Data Sharing behavior below.
10. **Health data** toggle — see Data Sharing behavior below.

**Validation / disabled states:**
- Squad Name, PIN, and Callsign fields turn red only once their content is non-empty but out of range (not while empty), or when `gameState.squadNameError` / `pinError` / `callsignError` is set externally (e.g. a rejected join).
- **Host** is disabled until Squad Name, PIN, and Callsign are all in range (`canHostOrJoin`), and while already joining, already initiating a host, or connected as a client.
- **Join** is disabled until Squad Name, PIN, and Callsign are all in range, and while already hosting or initiating a host, or already connected as a client.
- All fields in this section disable and dim to 60% opacity while hosting, joining, initiating a host, or already connected (`isBusy`).
- **Location** and **Health data** dim/disable on the narrower `isConnected` check (hosting or joined, not merely mid-connect) rather than `isBusy` — see below.
- Squad Name/PIN typed here are mirrored to `gameState.savedRoomName` / `savedPin` live, and mirrored back if changed elsewhere.
- Focusing any field auto-scrolls it into view above the keyboard; focus is cleared automatically once `isBusy` becomes true.

---

## DatabaseURLField (shared with the legacy Room views)

A single row, styled the same as the Squad Name/PIN fields above it (no boxed background): — iOS only — a camera button (`camera.viewfinder`) on the left, then a text field / default indicator, then a **Custom URL** switch on the right (full-size, matching the Location/Health data toggles — no longer shrunk with `.scaleEffect`); plus a recent-URLs dropdown beneath it.

- **Camera button** (leftmost, iOS only): opens `ScannerSheetView` in `.url` mode, using iOS Live Text recognition to read a URL directly off a Firebase Console screen — no need to turn the URL into a QR code first. Disabled whenever the text field is (i.e. switch off).
- **Text field**: free-form entry or paste of a custom Firebase Realtime Database URL (`https://*.firebaseio.com` or `*.firebasedatabase.app`). Only editable while the Custom URL switch is on. Sanitized live via `AppConstants.Network.sanitizeInput` — a wider RFC 3986 URI character allowlist than the Squad Name/PIN/Callsign fields' ASCII-alphanumeric-only filters, since a URL legitimately needs `: / . - ? # @` etc.; this only strips whitespace/control/non-ASCII characters and does not itself validate well-formedness (paired with `AppConstants.Network.isValidDatabaseURL` at submit time via `GameStateManager.applyDatabaseURL`).
- **Custom URL switch** (rightmost, `gameState.isCustomDatabaseURLEnabled`, default on): the master on/off for this feature. **Off** (switch to the left) — displays gray text `"using default server"`, with the camera button grayed out/disabled, and hosting or joining always uses the shared default RTDB regardless of whatever text was previously entered. **On** (switch to the right) — the field/camera are editable and the entered URL is used (falling back to the shared default only if left empty). The shared default's actual URL is never displayed as text or encoded into a QR code. This switch only governs this device's own typed setting — an explicit database URL decoded from a scanned join QR code always takes precedence (see `GameStateManager.applyDatabaseURL`).
- **Recent URLs dropdown**: while the text field is focused and the switch is on, up to `AppConstants.UI.maxRecentDatabaseURLs` (3) previously-used custom URLs appear as tappable rows beneath the field (`gameState.recentDatabaseURLs`, newest first). A URL is remembered the moment it's actually used to host or join (`GameStateManager.applyDatabaseURL` → `rememberRecentDatabaseURL`), not on every keystroke, and persists across launches (`AppConstants.Storage.recentDatabaseURLsKey`).

---

## JoinQRBox (shared with the legacy Room views)

Renders as a `SCAN TO JOIN` label above a fixed 160×160 box.

- **Not connected**: the box is a tap target showing a QR icon. Tapping opens `ScannerSheetView` in `.qrCode` mode. A decoded scan (`QRJoinPayload`) fills Squad Name and PIN above (flagged as a pre-derived id) and flips the Custom Database URL toggle on or off depending on whether the QR code contained an optional URL (updating the Database URL field accordingly).
- **Connected** (`isConnected` — hosting or joined as a client, an `activeRoom` exists): the box instead renders the actual QR code encoding this room's `QRJoinPayload` — room name, PIN, and the *raw* custom database URL setting (`""` when hosting on the shared default, never the shared project's literal URL) — for teammates to scan. Any member can display it, not just the host.
- Disabled at 60% opacity while busy and not connected (`isBusy && !isConnected`), so a connected member can always see/re-display the room's QR code even while otherwise "busy."

---

## Location / Health data toggles

Last two rows of the top squad section (right after the Database URL field, item 8–9 above) — no section header (the former "Data Sharing" header was removed once these moved out of their own section). Still backed by the same `isUploadLocationEnabledKey` / `isUploadHeartRateEnabledKey` UserDefaults keys (see constants table above); only the on-screen labels and position changed, not the storage keys.

- **Permission-aware, not plain preference switches**: the displayed position is `storedPreference && systemPermissionGranted`, so a denied OS permission shows the switch off even if the preference itself is still `true`. Sliding a switch on branches on the live `CLAuthorizationStatus` / `HKAuthorizationStatus` — undetermined fires the real one-time system prompt (`requestPermissions()` / `requestAuthorization()`); denied/restricted (which iOS/watchOS will never re-prompt for) instead surfaces an alert with the manual fix path (Watch's own Settings app for Location, the iPhone Health app for Heart Rate); already-granted just flips the preference. Sliding off only clears the preference — it can't revoke the OS permission. See [PRIVACY_AND_COMPLIANCE.md §4.C](PRIVACY_AND_COMPLIANCE.md) for the full mechanism and exact alert text.
- **Locked while connected**: both toggles dim to 60% opacity and disable while `isConnected` (hosting or already joined as a client) — mid-connect states (`isJoining`/`isInitiatingHost` without an active room yet) do **not** lock them, only an actual live room does. This prevents a squadmate from flipping data-sharing mid-session, which would otherwise cause a client's telemetry stream to silently start/stop broadcasting real position or heart rate values partway through a game. Toggling is only permitted again once the user leaves/disbands the room.

---

## Rest of the Config screen (below the squad section)

- **Radar color** toggle (green/red theme; disabled/hidden for now with default green theme).
- **Paywall** section — shows "Pro Unlocked" or an "Unlock Pro" button that presents `PaywallView`.
- **HUD Guide** and **Policy** navigation links.
- **Roster** section (only while in an active room) — lists squad members with callsign, heading, and live heart rate. A **HOST** badge marks whoever holds `room.hostId`; a separate **LEADER** badge marks anyone with `member.role == .leader` who is *not* the host — the two badges are independent (a host who also selected the Leader role only shows HOST, not both) since a member's `role` (Player/Team Leader, set via the Role slider above) is orthogonal to who happens to be hosting the room.

---

## Hidden debug panel (via Policy, DEBUG builds only)

`PolicyView` (opened from the **Policy** link above) carries an undocumented long-press gesture under `#if DEBUG` with no visual affordance: holding anywhere on the screen for 5 seconds (`LongPressGesture(minimumDuration: 5.0)`) presents [`DebugUnlockView.swift`](../RadarMap/Views/Settings/DebugUnlockView.swift) as a sheet. In production/Release builds, this gesture, sheet, and all associated debug logic are excluded.

- **Password gate**: a `SecureField` checked against `DebugSecrets.debugPanelPassword`. `DebugSecrets.swift` is a local-only file (git-ignored — see `.gitignore`); a wrong entry shows an "Incorrect Password" alert and clears the field. There is no lockout or rate limiting.
- Once matched, three toggles appear:
  1. **Debug Display** (`AppConstants.Storage.isDebugDisplayEnabledKey`, default off) — shows/hides the version + `gameState.debugStatusString` text in the map HUD's upper-right corner (see [`TacticalRadarMapView.swift`](../RadarMap/Views/Map/TacticalRadarMapView.swift)). Backed by `@AppStorage` on both this sheet and the HUD, so it takes effect immediately without relaunching.
  2. **Encryption** — bound to `gameState.isEncryptionEnabled`, a phone/watch-synced field (`ConfigSnapshot.isEncryptionEnabled`, default on, legacy-seeded once from `AppConstants.Storage.isEncryptionEnabledKey` on first launch), which gates whether `FirebaseSyncManager.setEncryptionContext(pin:roomId:isEncryptionEnabled:)` derives an AES-256-GCM key for this device's telemetry and tactical-indicator writes/reads (see [CLOUD_DATA_MANAGEMENT.md](CLOUD_DATA_MANAGEMENT.md) §5.E). Flipping it off makes this device write plaintext and skip decryption on read; every client syncing on the same room must agree on this setting.
  3. **Pro** (bound to `gameState.subscriptionManager.hasUnlimitedSquadUnlock`) — initial position reflects the current pro state. Flipping it on calls `SubscriptionManager.debugForceUnlockPro()`, which grants the unlock and persists it to `AppConstants.Storage.hasUnlimitedSquadUnlockKey`. Flipping it off is a no-op — once unlocked (by this switch or a real purchase/restore) it can never be turned back off from here.
