# Debug Menu Specification

This document defines the architecture, access mechanics, authentication, and controls provided by the hidden **Debug Menu** ([`DebugUnlockView.swift`](../RadarMap/Views/Settings/DebugUnlockView.swift)).

---

## 1. Access Mechanics & Availability

* **Build Configuration**: Exclusively compiled into `#if DEBUG` builds. Stripped completely from production/Release binaries.
* **Entry Point**: Reached from the **Policy** sheet ([`PolicyView.swift`](../RadarMap/Views/Settings/PolicyView.swift)), accessed via the Policy link in the Settings view.
* **Gesture Trigger**: Undocumented 5-second long press anywhere on the Policy view:
  ```swift
  .simultaneousGesture(
      LongPressGesture(minimumDuration: 5.0)
          .onEnded { _ in showDebugUnlock = true }
  )
  ```
* **Presentation**: Presented modally as a sheet with navigation title `"Debug"`.

---

## 2. Passcode Gate

Before exposing debug controls, the menu enforces administrative password authentication:
* **Secure Input**: `SecureField("Password", text: $passwordInput)`.
* **Validation Key**: Authenticates against `DebugSecrets.debugPanelPassword`.
  * `DebugSecrets.swift` is a local-only file (git-ignored via `.gitignore`).
* **Failure Handling**: An incorrect password displays an `"Incorrect Password"` alert and clears the input field. There is no lockout or rate limiting.
* **Session Scope**: Unlocks state for the duration of the current sheet presentation.

---

## 3. Menu Controls & Toggles

Once authenticated, the debug form exposes three system-level diagnostics and state overrides:

```
┌────────────────────────────────────────────────────────┐
│ Debug                                            Close │
├────────────────────────────────────────────────────────┤
│ Debug Display                                   [ ON ] │
│ Encryption                                      [ ON ] │
│ Pro                                             [OFF ] │
└────────────────────────────────────────────────────────┘
```

### 1. Debug Display Toggle
* **Storage Key**: `@AppStorage(AppConstants.Storage.isDebugDisplayEnabledKey)` (UserDefaults `"is_debug_display_enabled"`).
* **Behavior**: Dynamically enables or disables the live tactical diagnostic overlay rendered in the upper-right corner of [`TacticalRadarMapView.swift`](../RadarMap/Views/Map/TacticalRadarMapView.swift).
* **Display Elements**:
  * **Line 1 (Version)**: Monospaced build string (`v{marketingVersion}b{buildNumber}`).
  * **Line 2 (Netcode Status)**: 8-character live netcode diagnostic string generated synchronously by [`GameStateManager.debugStatusString`](../RadarMap/Managers/GameStateManager.swift):
    * **Digit 1**: Upstream write link to Firebase (`U` / `0`).
    * **Digit 2**: Downstream room listeners attached (`D` / `0`).
    * **Digit 3**: High-Speed (`*_hs`) stream activity (`P` / `W` / `0`).
    * **Digit 4**: Low-Speed (`*_ls`) stream activity (`P` / `W` / `0`).
    * **Digit 5**: Companion lease horizon sign (`+` / `-`).
    * **Digit 6**: Companion lease horizon magnitude in seconds capped at 9 (`0`..`9`).
    * **Digit 7**: WCSession activation state (`.activated` -> `A` / `0`).
    * **Digit 8**: WCSession reachability (`isReachable` -> `R` / `0`).
* **Reference**: Full specification and variable evaluation rules in [`DEBUG_DISPLAY.md`](DEBUG_DISPLAY.md).

### 2. Encryption Toggle
* **Backing Property**: `gameState.isEncryptionEnabled` (`ConfigSnapshot.isEncryptionEnabled`).
* **Bidirectional Synchronization**: Synced bidirectionally across Phone and Watch via the low-speed (`*_ls`) WatchConnectivity channel so companion devices never drift out of crypto alignment.
* **Behavior**:
  * When `true` (default): Telemetry and tactical indicators are encrypted using AES-256-GCM via [`CompactArrayCipher.swift`](../RadarMap/Models/CompactArrayCipher.swift) with keys derived from the room PIN + room ID.
  * When `false`: Telemetry and tactical payloads are transmitted in plaintext, and payload decryption is bypassed on read.
* **Reference**: See [`CLOUD_DATA_MANAGEMENT.md §5.E`](CLOUD_DATA_MANAGEMENT.md).

### 3. Pro Unlock Toggle
* **Backing Property**: Bound to `gameState.subscriptionManager.hasUnlimitedSquadUnlock`.
* **Behavior**:
  * **Flipping ON**: Calls `subscriptionManager.debugForceUnlockPro()`, which sets `hasUnlimitedSquadUnlock = true` and persists it to `AppConstants.Storage.hasUnlimitedSquadUnlockKey`.
  * **Flipping OFF**: A no-op. Once unlocked (whether through debug override or StoreKit receipt), the unlock cannot be revoked from this menu.
* **Companion Sync**: Syncs `isPro` across the companion pair via `ConfigSnapshot.isPro` (`*_ls`).

---

## 4. Related Specifications

* [`DEBUG_DISPLAY.md`](DEBUG_DISPLAY.md): In-depth breakdown of the 8-character netcode HUD diagnostic overlay, including digits 5 & 6 companion lease horizon calculation.
* [`SETTINGS_VIEW.md`](SETTINGS_VIEW.md): Specification for the user-facing Settings view and gesture wiring to `DebugUnlockView`.
* [`CLOUD_DATA_MANAGEMENT.md`](CLOUD_DATA_MANAGEMENT.md): Cloud telemetry architecture, encryption pipeline, and role negotiation.
