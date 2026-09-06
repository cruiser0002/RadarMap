# In-App Purchases & RevenueCat Configuration Guide

This document provides the complete operational setup, dashboard configuration, and testing instructions for **Radar Map**'s in-app purchases and subscription infrastructure via **RevenueCat** and **Apple StoreKit 2**.

---

## 📋 Table of Contents

* [Key Monetization & IAP Constants](#-key-monetization--iap-constants)
1. [Product Overview & Tier Limits](#1-product-overview--tier-limits)
2. [App Store Connect Configuration](#2-app-store-connect-configuration)
3. [RevenueCat Dashboard Configuration](#3-revenuecat-dashboard-configuration)
4. [Local Testing with StoreKit Configuration](#4-local-testing-with-storekit-configuration)
5. [Code References & Architecture](#5-code-references--architecture)

---

## ⚡ Key Monetization & IAP Constants

The following centralized constants from [`AppConstants.swift`](RadarMap/AppConstants.swift) (`AppConstants.Subscription` and `AppConstants.Storage`) govern all in-app purchase, paywall, and tier-enforcement behaviors:

| Section & Context | Constant / Identifier | Value | Code Source / Usage |
| :--- | :--- | :--- | :--- |
| **§1 Tier Limits** | `freeTierMaxCapacity` | `4` operators | `Subscription.freeTierMaxCapacity` — Free host squad room cap |
| **§1 Tier Limits** | `proTierMaxCapacity` | `12` operators | `Subscription.proTierMaxCapacity` — Pro squad leader room cap |
| **§1 Tactical Markers**| `freeTierMaxTacticalIndicators` | `0` markers | `Subscription.freeTierMaxTacticalIndicators` — Free tier cannot drop markers |
| **§1 Tactical Markers**| `proTierMaxTacticalIndicators` | `20` markers | `Subscription.proTierMaxTacticalIndicators` — Shared cap on enemy/hazard indicators |
| **§2 StoreKit Product**| `productID` | `"com.radarmap.watch.pro"` | App Store Connect Non-Consumable Product ID (`Subscription.productID`) |
| **§2 Pricing** | `lifetimePriceString` | `"$29.99"` | Hardcoded display price fallback (`Subscription.lifetimePriceString`) |
| **§3 RevenueCat** | `entitlementID` | `"radarmap_pro"` | RevenueCat Entitlement identifier (`Subscription.entitlementID`) |
| **§3 RevenueCat** | `offeringID` | `"default"` | RevenueCat Offering identifier (`Subscription.offeringID`) |
| **§3 RevenueCat** | `packageID` | `"$rc_lifetime"` | RevenueCat Package identifier (`Subscription.packageID`) |
| **§3 API Key** | `revenueCatApiKey` | `"appl_BImCxHPjqYqcXAVSdaxcyvcHhbw"` | Public Apple SDK API Key (`Subscription.mockRevenueCatApiKey`) |
| **§4 Local StoreKit** | Configuration File | `RadarMap.storekit` | Xcode StoreKit test scheme environment file |
| **§5 Persistence** | `hasUnlimitedSquadUnlockKey` | `"hasUnlimitedSquadUnlock"` | UserDefaults entitlement cache key (`Storage.hasUnlimitedSquadUnlockKey`) |
| **§5 Marker Timers** | `enemyIndicatorFadeDurationSeconds` | `300.0s` (5 min) | Automatic fade-to-grayscale duration for enemy markers |
| **§5 Indicator Delete**| `indicatorHoldToDeleteDurationSeconds`| `1.2s` | Long-press gesture duration to delete placed tactical markers |

---

## 1. Product Overview & Tier Limits

Radar Map uses a freemium model governed by [`SubscriptionManager.swift`](RadarMap/Managers/SubscriptionManager.swift):

* **Free Tier (`freeTierMaxCapacity = 4`)**:
  * Free operators can host squad rooms of up to **4 operators**.
  * Free operators can join hosted rooms of **any size** 100% free.
  * Tactical marker placement is locked to Pro hosts.
* **Pro Tier (`proTierMaxCapacity = 12`)**:
  * **Product ID:** `com.radarmap.watch.pro`
  * **Price:** $29.99 USD (One-time lifetime non-consumable unlock; no recurring subscriptions).
  * Unlocks squad hosting capacity up to **12 operators**.
  * Unlocks tactical marker placements (orders, objectives, enemy tags, and environmental hazards).

---

## 2. App Store Connect Configuration

1. Log in to [App Store Connect](https://appstoreconnect.apple.com/) and open **Radar Map**.
2. In the sidebar, navigate to **Monetization** → **In-App Purchases**.
3. Click the **Create In-App Purchase (+)** button.
4. Configure the purchase details:
   * **Type**: Select **Non-Consumable**.
   * **Reference Name**: `Squad Leader Lifetime Unlock`
   * **Product ID**: `com.radarmap.watch.pro`
   * **Price Tier**: $29.99 USD (Tier 30) or equivalent.
   * **Family Sharing**: Check **Turn On** (recommended by Apple for lifetime unlocks).
5. **Localization**:
   * Language: English (U.S.)
   * Display Name: `Squad Leader Lifetime`
   * Description: `Create squads of up to 12 operators and place tactical map indicators.`
6. **Review Information**:
   * Upload a screenshot of the in-app paywall screen (`PaywallView`).
   * Provide review notes explaining how to test the purchase in sandbox mode.

---

## 3. RevenueCat Dashboard Configuration

1. Log in to the [RevenueCat Dashboard](https://app.revenuecat.com/) and open the **RadarMap** project.
2. **Configure Entitlement**:
   * Navigate to **Project Settings** → **Entitlements**.
   * Click **+ New Entitlement**.
   * Identifier: `radarmap_pro`
   * Description: `Squad Leader Unlimited Capacity & Tactical Markers`
3. **Attach Product**:
   * Navigate to **Products**.
   * Add Apple App Store Product ID: `com.radarmap.watch.pro`.
   * Attach it to the Entitlement created above (`radarmap_pro`).
4. **Configure Offering**:
   * Navigate to **Offerings**.
   * Open the `default` offering.
   * Add a package: Identifier `$rc_lifetime` (Lifetime).
   * Attach product `com.radarmap.watch.pro` to `$rc_lifetime`.
5. **API Key Integration**:
   * Under **Project Settings** → **API Keys**, copy your **Public Apple API Key** (`appl_...`).
   * Verify or update `revenueCatApiKey` in [`RadarMap/AppConstants.swift`](RadarMap/AppConstants.swift):
     ```swift
     public static let revenueCatApiKey: String = Bundle.main.infoDictionary?["REVENUECAT_API_KEY"] as? String ?? mockRevenueCatApiKey
     ```

---

## 4. Local Testing with StoreKit Configuration

Xcode includes a native StoreKit testing environment that bypasses App Store sandbox servers:

1. Open the project in Xcode:
   ```bash
   xed .
   ```
2. Edit the active scheme (**Product > Scheme > Edit Scheme...** or `⌘<`).
3. Select **Run** on the left sidebar, then click the **Options** tab.
4. In the **StoreKit Configuration** dropdown, select:
   * `RadarMap.storekit` (located in [`RadarMap/Resources/RadarMap.storekit`](RadarMap/Resources/RadarMap.storekit)).
5. Click **Close**.
6. Build and run on either the watchOS or iOS Simulator:
   * Open **Config** → **Unlock Pro**.
   * Tapping **Unlock Pro** will present Xcode's local StoreKit purchase confirmation sheet.
   * Tapping **Restore Purchases** will execute local entitlement restoration.
7. Manage local transactions in Xcode via **Debug > StoreKit > Manage Transactions...** to simulate refunds, expired states, or failed purchases.

---

## 5. Code References & Architecture

* **Manager:** [`RadarMap/Managers/SubscriptionManager.swift`](RadarMap/Managers/SubscriptionManager.swift)
  * Handles purchase lifecycle, RevenueCat customer info listeners, restore purchases, and offline receipt fallback.
* **Paywall View:** [`RadarMap/Views/Paywall/PaywallView.swift`](RadarMap/Views/Paywall/PaywallView.swift)
  * SwiftUI purchase modal displaying feature comparison, price formatting, Terms of Use (EULA) links, Privacy Policy links, and restore controls.
* **Constants:** [`RadarMap/AppConstants.swift`](RadarMap/AppConstants.swift) (`AppConstants.Subscription`)
  * Declares product IDs, entitlement IDs, offering keys, and fallback pricing strings.
* **Compliance:** For App Store Review Guidelines (3.1.1 and 3.1.2) governing paywalls, see [**`PRIVACY_AND_COMPLIANCE.md`**](PRIVACY_AND_COMPLIANCE.md).
