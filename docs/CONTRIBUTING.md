# Contributing to RadarMap

Thank you for contributing to RadarMap! This document provides guidelines and conventions for developing, testing, and maintaining both the watchOS application and its iOS companion target.

---

## Architectural & Engineering Rules

### 1. No Fallback Data Sources or Placeholder Masking
RadarMap is designed as a zero-mock, real-time tactical navigation system:
- **No Mock or Fallback Data**: Do not introduce synthetic fallbacks, mock location providers, or simulated peer nodes in production targets (`RadarMap` watchOS or `RadarMapCompanion` iOS).
- **Surface Errors Directly**: When permissions are denied, sensors fail, or cloud connections disconnect, surface the state explicitly through the UI (tactical status banners, member status indicators, or dedicated alert states) rather than masking failures with dummy data.
- **Strict Separation of Simulation**: Player and mesh simulation belongs strictly in `notebooks/player_simulator.py` and offline test harnesses.

### 2. Dual-Target Layout
The repository contains two distinct platform targets:
- **`RadarMap` (watchOS Target)**:
  - Entry point: `RadarMap/RadarMapApp.swift` (`#if os(watchOS)`).
  - Standalone Apple Watch tactical map interface with compass heading sensor integration (`LocationHeadingManager`), dual MapKit / OLED CRT radar presentations (`TacticalRadarMapView`), and live companion synchronization (`WatchConnectivityManager`).
- **`RadarMapCompanion` (iOS Target)**:
  - Entry point: `RadarMapCompanion/RadarMapCompanionApp.swift` (`#if os(iOS)`).
  - iPhone companion app offering enhanced mission planning, telemetry review, and shared tactical session participation.
- **Shared Code**: Core models, network protocols, and cryptographic utilities are shared across targets without conditional branching where possible.

### 3. Project Generation Requirement
`RadarMap.xcodeproj` is generated from the file tree by [`generate_xcodeproj.py`](../generate_xcodeproj.py).
- Run `python3 generate_xcodeproj.py` to regenerate the project file whenever Swift source files are added, removed, or moved.
- Always verify that new Swift files in `RadarMap/` or `RadarMapCompanion/` are recognized by `generate_xcodeproj.py` before opening pull requests.

---

## Testing Standards

### Automated Tests
Run unit tests from the command line using Swift Package Manager or Xcode:
```bash
swift test
```
Or in Xcode:
- Press `⌘U` with either the `RadarMap` or `RadarMapCompanion` scheme selected.

### StoreKit & In-App Purchases Testing
For Pro tier and entitlement testing:
- Use the StoreKit Test configuration file located at [`RadarMap/Resources/RadarMap.storekit`](../RadarMap/Resources/RadarMap.storekit).
- In Xcode, select **Product > Scheme > Edit Scheme... > Run > Options**, and ensure **StoreKit Configuration** is set to `RadarMap.storekit`.
- Never submit hardcoded entitlement overrides to production branches.

### Network Benchmarking & Simulation
To evaluate multi-peer synchronization load and Firebase real-time database costs:
```bash
# Run simulator session against room ALPHA
python3 notebooks/player_simulator.py --mode host --room ALPHA --pin 1234 --callsign VIPER-1 --duration 60

# Run comparative network cost evaluation and bandwidth benchmarks
python3 scripts/network_benchmark.py --compare benchmarks/baseline_scheme_v1.0.json benchmarks/candidate_scheme_v2_optimized.json
```
Review metrics against specifications in [`NETWORK_BENCHMARK_FIREBASE_COST_ESTIMATION.md`](NETWORK_BENCHMARK_FIREBASE_COST_ESTIMATION.md) and [`notebooks/README.md`](../notebooks/README.md).

---

## Pull Request Checklist

Before submitting a PR, ensure:
1. `swift test` passes without errors.
2. Markdown documentation is kept in sync with code modifications (e.g. scale ladders, constants, wire schemas).
3. No user schemes (`xcuserdata`), ephemeral build artifacts, or secret keys (service account private keys) are committed.
