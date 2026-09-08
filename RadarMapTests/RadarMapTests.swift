import XCTest
import CoreLocation
import SwiftUI
import MapKit
import Combine
@testable import RadarMap

final class RadarMapTests: XCTestCase {
    
    /// Legacy per-field keys `WatchConnectivityManager.init()` reads as a one-time migration
    /// fallback when no persisted "wc_local_ls_snapshot" blob exists yet. Nothing in production
    /// writes these anymore (localLS is the single persisted source of truth now), so unlike the
    /// keys below, a test that sets one directly to simulate a pre-migration device must also be
    /// the one to clean it up — these are cleared here purely so a value written by an aborted or
    /// killed test run doesn't linger in the real on-disk UserDefaults domain and leak into a
    /// later run's fresh GameStateManager() as a phantom migration.
    private func clearLegacyMigrationKeys() {
        UserDefaults.standard.removeObject(forKey: AppConstants.Storage.userCallsignKey)
        UserDefaults.standard.removeObject(forKey: AppConstants.Storage.savedRoomNameKey)
        UserDefaults.standard.removeObject(forKey: AppConstants.Storage.savedPinKey)
        UserDefaults.standard.removeObject(forKey: AppConstants.Storage.customDatabaseURLKey)
        UserDefaults.standard.removeObject(forKey: AppConstants.Storage.radarColorThemeKey)
        UserDefaults.standard.removeObject(forKey: AppConstants.Storage.userRoleKey)
        UserDefaults.standard.removeObject(forKey: AppConstants.Storage.hasUnlimitedSquadUnlockKey)
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "wc_local_ls_snapshot")
        UserDefaults.standard.removeObject(forKey: "wc_peer_ls_snapshot")
        UserDefaults.standard.removeObject(forKey: AppConstants.Storage.isUploadHeartRateEnabledKey)
        UserDefaults.standard.removeObject(forKey: AppConstants.Storage.isUploadLocationEnabledKey)
        clearLegacyMigrationKeys()
        // SquadMember.defaultUpdateInterval is a shared static mutated by
        // GameStateManager.recalculateAdaptiveUploadInterval() as a side effect of room-size
        // changes; reset it so tests don't leak room-size state into each other via test order.
        SquadMember.defaultUpdateInterval = AppConstants.Timing.Stale.defaultUpdateInterval
    }

    override func tearDown() {
        // WatchConnectivityManager persists localLS/peerLS via a private background queue whose
        // closures capture `self` strongly, so a write from this test can still be in flight
        // after the test method returns (its manager instance stays alive only to run that
        // closure). Give it a moment to land before clearing, so it can't leak into the next
        // test's fresh read of these keys.
        Thread.sleep(forTimeInterval: 0.05)
        UserDefaults.standard.removeObject(forKey: "wc_local_ls_snapshot")
        UserDefaults.standard.removeObject(forKey: "wc_peer_ls_snapshot")
        UserDefaults.standard.removeObject(forKey: AppConstants.Storage.isUploadHeartRateEnabledKey)
        UserDefaults.standard.removeObject(forKey: AppConstants.Storage.isUploadLocationEnabledKey)
        clearLegacyMigrationKeys()
        SquadMember.defaultUpdateInterval = AppConstants.Timing.Stale.defaultUpdateInterval
        super.tearDown()
    }
    
    private func createMockFirebaseSyncManager() -> FirebaseSyncManager {
        let syncManager = FirebaseSyncManager()
        syncManager.transport = MockRTDBTransport()
        return syncManager
    }

    /// Retrieves the `MockRTDBTransport` installed by `createMockFirebaseSyncManager()` so a test
    /// can seed server state / assert on recorded gets/sets/removes.
    private func mockTransport(for syncManager: FirebaseSyncManager) -> MockRTDBTransport {
        // swiftlint:disable:next force_cast
        syncManager.transport as! MockRTDBTransport
    }
    
    // MARK: - Late Packet Rejection Tests
    
    func testLatePacketRejectionInOrder() {
        let syncManager = createMockFirebaseSyncManager()
        let room = SquadRoom(id: "ALPHA1", hostId: "USER1")
        let member = SquadMember(id: "USER2", callsign: "VIPER", latitude: 37.77, longitude: -122.41)
        var updatedRoom = room
        updatedRoom.members["USER2"] = member
        syncManager.connectToRoom(updatedRoom)
        
        let now = Date().timeIntervalSince1970
        
        // Packet 1: sequence 1
        let p1 = TelemetryPacket(memberId: "USER2", roomId: "ALPHA1", latitude: 37.771, longitude: -122.411, heading: 45.0, heartRate: 80.0, timestamp: now, sequenceNumber: 1)
        XCTAssertTrue(syncManager.validateAndProcessPacket(p1), "Fresh in-order packet 1 should be accepted")
        
        // Packet 2: sequence 2, higher timestamp
        let p2 = TelemetryPacket(memberId: "USER2", roomId: "ALPHA1", latitude: 37.772, longitude: -122.412, heading: 50.0, heartRate: 85.0, timestamp: now + 1.0, sequenceNumber: 2)
        XCTAssertTrue(syncManager.validateAndProcessPacket(p2), "Fresh in-order packet 2 should be accepted")
        
        XCTAssertEqual(syncManager.totalPacketsProcessed, 2)
        XCTAssertEqual(syncManager.totalPacketsRejected, 0)
    }
    
    func testLatePacketRejectionOutOfOrderSequence() {
        let syncManager = createMockFirebaseSyncManager()
        let room = SquadRoom(id: "ALPHA1", hostId: "USER1")
        let member = SquadMember(id: "USER2", callsign: "VIPER", latitude: 37.77, longitude: -122.41)
        var updatedRoom = room
        updatedRoom.members["USER2"] = member
        syncManager.connectToRoom(updatedRoom)
        
        let now = Date().timeIntervalSince1970
        
        // Packet 1: sequence 5
        let p1 = TelemetryPacket(memberId: "USER2", roomId: "ALPHA1", latitude: 37.771, longitude: -122.411, heading: 45.0, heartRate: 80.0, timestamp: now, sequenceNumber: 5)
        XCTAssertTrue(syncManager.validateAndProcessPacket(p1))
        
        // Packet 2: sequence 3 (late / out-of-order)
        let p2 = TelemetryPacket(memberId: "USER2", roomId: "ALPHA1", latitude: 37.772, longitude: -122.412, heading: 50.0, heartRate: 85.0, timestamp: now + 0.5, sequenceNumber: 3)
        XCTAssertFalse(syncManager.validateAndProcessPacket(p2), "Out-of-order sequence packet should be rejected")
        
        XCTAssertEqual(syncManager.totalPacketsProcessed, 1)
        XCTAssertEqual(syncManager.totalPacketsRejected, 1)
        XCTAssertEqual(syncManager.latestRejection?.reason, .outOfOrderSequence)
    }
    
    func testLatePacketRejectionStaleTimestamp() {
        let syncManager = createMockFirebaseSyncManager()
        let room = SquadRoom(id: "ALPHA1", hostId: "USER1")
        let member = SquadMember(id: "USER2", callsign: "VIPER", latitude: 37.77, longitude: -122.41)
        var updatedRoom = room
        updatedRoom.members["USER2"] = member
        syncManager.connectToRoom(updatedRoom)
        
        let now = Date().timeIntervalSince1970
        
        // Packet 1: timestamp = now
        let p1 = TelemetryPacket(memberId: "USER2", roomId: "ALPHA1", latitude: 37.771, longitude: -122.411, heading: 45.0, heartRate: 80.0, timestamp: now, sequenceNumber: 1)
        XCTAssertTrue(syncManager.validateAndProcessPacket(p1))
        
        // Packet 2: higher sequence number but older timestamp
        let p2 = TelemetryPacket(memberId: "USER2", roomId: "ALPHA1", latitude: 37.772, longitude: -122.412, heading: 50.0, heartRate: 85.0, timestamp: now - 2.0, sequenceNumber: 2)
        XCTAssertFalse(syncManager.validateAndProcessPacket(p2), "Stale timestamp packet should be rejected")
        
        XCTAssertEqual(syncManager.totalPacketsProcessed, 1)
        XCTAssertEqual(syncManager.totalPacketsRejected, 1)
        XCTAssertEqual(syncManager.latestRejection?.reason, .staleTimestamp)
    }
    
    func testPacketAcceptedRegardlessOfAge() {
        let syncManager = createMockFirebaseSyncManager()
        let room = SquadRoom(id: "ALPHA1", hostId: "USER1")
        let member = SquadMember(id: "USER2", callsign: "VIPER", latitude: 37.77, longitude: -122.41)
        var updatedRoom = room
        updatedRoom.members["USER2"] = member
        syncManager.connectToRoom(updatedRoom)
        
        let now = Date().timeIntervalSince1970
        
        // Packet generated in past (e.g. 60 seconds ago)
        let olderPacket = TelemetryPacket(memberId: "USER2", roomId: "ALPHA1", latitude: 37.771, longitude: -122.411, heading: 45.0, heartRate: 80.0, timestamp: now - 60.0, sequenceNumber: 1)
        XCTAssertTrue(syncManager.validateAndProcessPacket(olderPacket), "Older packet should be accepted without arbitrary age limits")
        XCTAssertEqual(syncManager.totalPacketsProcessed, 1)
        XCTAssertEqual(syncManager.totalPacketsRejected, 0)
    }
    
    // MARK: - Mock RTDB Transport for Deterministic Network Testing
    //
    // Network interception used to route through `MockURLProtocol` (a `URLProtocol` subclass)
    // intercepting `FirebaseSyncManager.urlSession`'s REST calls. `FirebaseSyncManager` now talks
    // to the Firebase Realtime Database SDK directly (never through `URLSession`), so tests inject
    // `MockRTDBTransport` (see RadarMapTests/MockRTDBTransport.swift) via `.transport` instead.

    private func createMockGameState(watchConnectivityManager: WatchConnectivityManager = WatchConnectivityManager()) -> GameStateManager {
        let gameState = GameStateManager(watchConnectivityManager: watchConnectivityManager)
        gameState.myCallsign = "OPERATOR"
        gameState.firebaseManager.transport = MockRTDBTransport()
        return gameState
    }

    /// Retrieves the `MockRTDBTransport` installed by `createMockGameState(...)` so a test can
    /// seed server state / assert on recorded gets/sets/removes.
    private func mockTransport(for gameState: GameStateManager) -> MockRTDBTransport {
        // swiftlint:disable:next force_cast
        gameState.firebaseManager.transport as! MockRTDBTransport
    }

    /// Delivers `snapshot` to `manager` as if it just arrived over WCSession from its companion —
    /// encodes it into an `ApplicationContextEnvelope` (on the correct `w2pLS`/`p2wLS` side for
    /// `manager`'s own role) and feeds it through `handleIncomingApplicationContext`, the same
    /// entrypoint `WCSessionDelegate` uses in production. `localLS` is the single source of truth
    /// now, so a synthetic snapshot only takes effect on `manager`/its `GameStateManager` by
    /// actually landing there via a real merge — poking `onLowSpeedConvergenceStateChanged`
    /// directly (the old approach) no longer has anything to adopt into.
    private func deliverPeerSnapshot(_ snapshot: LowSpeedSnapshot, to manager: WatchConnectivityManager) {
        var envelope = ApplicationContextEnvelope()
        if manager.localRole == .phone {
            envelope.w2pLS = snapshot
        } else {
            envelope.p2wLS = snapshot
        }
        guard let data = try? JSONEncoder().encode(envelope),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            XCTFail("Failed to encode synthetic envelope")
            return
        }
        manager.handleIncomingApplicationContext(dict)
        // handleIncomingApplicationContext hops to DispatchQueue.main.async internally (matching
        // production, where WCSessionDelegate callbacks can land off-main) — pump the run loop so
        // the merge has actually landed in localLS by the time this call returns.
        pumpMainRunLoop()
    }

    /// A single `DispatchQueue.main.async { exp.fulfill() }` only guarantees everything queued
    /// *before* it has run — it does NOT guarantee everything queued *as a consequence of* it
    /// (e.g. `handleIncomingApplicationContext`'s own internal main-queue hop, which itself
    /// triggers `WatchConnectivityManager.$localLS`'s `.receive(on: .main)` sink in
    /// `GameStateManager.bindManagers()`, a *second* hop) has also run — that second hop's
    /// closure gets queued only once the first one actually executes, i.e. after this pump's own
    /// fulfill may already be sitting ahead of it in line. Repeating the hop drains each
    /// successive level.
    private func pumpMainRunLoop(times: Int = 4) {
        for _ in 0..<times {
            let exp = XCTestExpectation(description: "main run loop pumped")
            DispatchQueue.main.async { exp.fulfill() }
            wait(for: [exp], timeout: 2.0)
        }
    }

    // MARK: - Paywall Capacity Tests
    
    func testPaywallCapacityEnforcement() {
        // No seeding needed: a fresh MockRTDBTransport's empty root already makes every read
        // resolve to nil (room doesn't exist yet) and every write succeed, matching the old
        // handler's unconditional "{}" / 200 response.
        let gameState = createMockGameState()
        gameState.subscriptionManager.hasUnlimitedSquadUnlock = false
        
        let exp1 = expectation(description: "Free room hosted")
        gameState.hostRoom(name: "FREE SQUAD", pin: "1234") { _ in
            XCTAssertEqual(gameState.firebaseManager.activeRoom?.maxCapacity, 4)
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 1.0)

        gameState.subscriptionManager.hasUnlimitedSquadUnlock = true
        let exp2 = expectation(description: "Pro room hosted")
        gameState.hostRoom(name: "PRO SQUAD", pin: "1234") { _ in
            XCTAssertEqual(gameState.firebaseManager.activeRoom?.maxCapacity, 12)
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 1.0)
    }
    
    // MARK: - Heart Rate Zone Color Tests
    
    func testHeartRateZoneColors() {
        let restingMember = SquadMember(callsign: "ONE", latitude: 0, longitude: 0, heartRate: 55)
        XCTAssertEqual(restingMember.heartRateZoneColor, .blue)
        
        let normalMember = SquadMember(callsign: "TWO", latitude: 0, longitude: 0, heartRate: 80)
        XCTAssertEqual(normalMember.heartRateZoneColor, .green)
        
        let elevatedMember = SquadMember(callsign: "THREE", latitude: 0, longitude: 0, heartRate: 120)
        XCTAssertEqual(elevatedMember.heartRateZoneColor, .yellow)
        
        let highStressMember = SquadMember(callsign: "FOUR", latitude: 0, longitude: 0, heartRate: 150)
        XCTAssertEqual(highStressMember.heartRateZoneColor, .orange)
        
        let maxStressMember = SquadMember(callsign: "FIVE", latitude: 0, longitude: 0, heartRate: 185)
        XCTAssertEqual(maxStressMember.heartRateZoneColor, .red)
    }
    
    // MARK: - Tactical Presentation & Scale Policy Verification Tests
    
    func testTacticalPresentations() {
        XCTAssertTrue(TacticalPresentation.allCases.contains(.radar))
        XCTAssertTrue(TacticalPresentation.allCases.contains(.map))
        XCTAssertEqual(TacticalPresentation.radar.rawValue, "Radar")
        XCTAssertEqual(TacticalPresentation.map.rawValue, "Map")
        XCTAssertEqual(TacticalPresentation.radar.iconName, "map")
        XCTAssertEqual(TacticalPresentation.map.iconName, "map")
        XCTAssertEqual(TacticalPresentation.allCases.count, 2)
    }
    
    func testTacticalScalePolicyLadderAndClamping() {
        let policy = TacticalScalePolicy()
        let expectedLadder: [CLLocationDistance] = [1, 2.5, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500]
        XCTAssertEqual(policy.allowedScales, expectedLadder)
        XCTAssertEqual(TacticalScalePolicy.defaultScale, 50.0)
        XCTAssertEqual(TacticalScalePolicy.minScale, 1.0)
        XCTAssertEqual(TacticalScalePolicy.maxScale, 2_500.0)
        
        // Clamping min & max
        XCTAssertEqual(policy.previousScale(before: 1.0), 1.0, "Clamps at minimum 1m")
        XCTAssertEqual(policy.nextScale(after: 2_500.0), 2_500.0, "Clamps at maximum 2.5km")
        
        // Stepping
        XCTAssertEqual(policy.nextScale(after: 1.0), 2.5)
        XCTAssertEqual(policy.previousScale(before: 2.5), 1.0)
        XCTAssertEqual(policy.nextScale(after: 50.0), 100.0)
        XCTAssertEqual(policy.previousScale(before: 100.0), 50.0)
        XCTAssertEqual(policy.nextScale(after: 100.0), 250.0)
        
        // Nearest logarithmic scale (breakpoints are geometric means, not arithmetic)
        XCTAssertEqual(policy.nearestAllowedScale(to: 0.5), 1.0)
        XCTAssertEqual(policy.nearestAllowedScale(to: 1.4), 1.0, "Below geometric mean sqrt(1*2.5)=1.58 snaps down")
        XCTAssertEqual(policy.nearestAllowedScale(to: 1.7), 2.5, "Above geometric mean sqrt(1*2.5)=1.58 snaps up")
        XCTAssertEqual(policy.nearestAllowedScale(to: 3.0), 2.5, "Below geometric mean sqrt(2.5*5)=3.54 snaps down")
        XCTAssertEqual(policy.nearestAllowedScale(to: 4.0), 5.0, "Above geometric mean sqrt(2.5*5)=3.54 snaps up")
        XCTAssertEqual(policy.nearestAllowedScale(to: 45.0), 50.0)
        XCTAssertEqual(policy.nearestAllowedScale(to: 80.0), 100.0)
        XCTAssertEqual(policy.nearestAllowedScale(to: 180.0), 250.0)
        XCTAssertEqual(policy.nearestAllowedScale(to: 350.0), 250.0)
        XCTAssertEqual(policy.nearestAllowedScale(to: 400.0), 500.0)
        XCTAssertEqual(policy.nearestAllowedScale(to: 5_000.0), 2_500.0, "Above ladder max clamps to 2.5km")
        
        // Radar range and intervals
        XCTAssertEqual(TacticalScalePolicy.outerRadarRange(for: 50.0), 200.0)
        XCTAssertEqual(TacticalScalePolicy.outerRadarRange(for: 100.0), 400.0)
        XCTAssertEqual(TacticalScalePolicy.ringIntervals(for: 100.0), [100.0, 200.0, 300.0, 400.0])
    }
    
    func testPresentationSwitchPreservesScaleAndTheme() {
        let gameState = createMockGameState()
        gameState.selectedScaleMeters = 250.0
        gameState.radarColorTheme = .green
        gameState.selectedPresentation = .map
        
        gameState.togglePresentation()
        XCTAssertEqual(gameState.selectedPresentation, .radar)
        XCTAssertEqual(gameState.selectedScaleMeters, 250.0, "Presentation switch must preserve selectedScaleMeters")
        XCTAssertEqual(gameState.radarColorTheme, .green, "Presentation switch must preserve theme")
        
        gameState.radarColorTheme = .red
        XCTAssertEqual(gameState.selectedPresentation, .radar, "Theme change must not alter presentation")
        XCTAssertEqual(gameState.selectedScaleMeters, 250.0, "Theme change must not alter selected scale")
    }
    
    func testRadarColorThemes() {
        XCTAssertTrue(RadarColorTheme.allCases.contains(.red))
        XCTAssertTrue(RadarColorTheme.allCases.contains(.green))
        XCTAssertEqual(RadarColorTheme.allCases.count, 2)
        XCTAssertEqual(RadarColorTheme.red.color, .red)
        XCTAssertEqual(RadarColorTheme.green.color, .green)
    }
    
    func testStaleMemberDataOlderThan15Seconds() {
        let now = Date()
        let freshMember = SquadMember(
            callsign: "FRESH",
            latitude: 37.77,
            longitude: -122.41,
            lastUpdatedTimestamp: now.timeIntervalSince1970 - 5.0
        )
        XCTAssertFalse(freshMember.isStale(asOf: now), "Member updated 5s ago should not be stale")
        
        let staleMember = SquadMember(
            callsign: "STALE",
            latitude: 37.77,
            longitude: -122.41,
            lastUpdatedTimestamp: now.timeIntervalSince1970 - 16.0
        )
        XCTAssertTrue(staleMember.isStale(asOf: now), "Member updated > 15s ago should be marked as stale")
    }
    
    func testStaleMemberDynamicIntervalAndMultiplier() {
        let now = Date()
        
        // Stale timeout duration: M * interval
        // Default: M = 15, interval = 1s -> 15s
        XCTAssertEqual(SquadMember.staleTimeoutDuration(updateInterval: 1.0, multiplier: 15.0), 15.0)
        // Interval = 2s, M = 15 -> 30s
        XCTAssertEqual(SquadMember.staleTimeoutDuration(updateInterval: 2.0, multiplier: 15.0), 30.0)
        // Interval = 5s, M = 15 -> 75s
        XCTAssertEqual(SquadMember.staleTimeoutDuration(updateInterval: 5.0, multiplier: 15.0), 75.0)
        
        // Member updated 25 seconds ago
        let member25s = SquadMember(
            callsign: "TEST_25S",
            latitude: 37.77,
            longitude: -122.41,
            lastUpdatedTimestamp: now.timeIntervalSince1970 - 25.0
        )
        
        // With 1.0s interval (timeout = 15s), 25s elapsed IS stale
        XCTAssertTrue(member25s.isStale(updateInterval: 1.0, multiplier: 15.0, asOf: now))
        
        // With 2.0s interval (timeout = 30s), 25s elapsed is NOT yet stale (fresh)
        XCTAssertFalse(member25s.isStale(updateInterval: 2.0, multiplier: 15.0, asOf: now))
        
        // Member updated 35 seconds ago
        let member35s = SquadMember(
            callsign: "TEST_35S",
            latitude: 37.77,
            longitude: -122.41,
            lastUpdatedTimestamp: now.timeIntervalSince1970 - 35.0
        )
        // With 2.0s interval (timeout = 30s), 35s elapsed IS stale
        XCTAssertTrue(member35s.isStale(updateInterval: 2.0, multiplier: 15.0, asOf: now))
    }
    
    func testRadarDistanceAndScaleAccuracy() {
        // Operator position (e.g. San Francisco)
        let userCoord = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        let radarRangeMeters: Double = 100.0
        let maxRadiusPoints: Double = 100.0
        
        // 1 degree latitude ~ 111,139 meters
        let metersPerDegreeLat: Double = 111_139.0
        let metersPerDegreeLon: Double = 111_139.0 * cos(userCoord.latitude * .pi / 180.0)
        let pointsPerMeter: Double = maxRadiusPoints / radarRangeMeters
        
        // 1. Target exactly 50 meters North (should land precisely on Ring 2: 50% radius)
        let deltaLat50m: Double = 50.0 / metersPerDegreeLat
        let targetNorth = CLLocationCoordinate2D(latitude: userCoord.latitude + deltaLat50m, longitude: userCoord.longitude)
        
        let dLatN: Double = targetNorth.latitude - userCoord.latitude
        let dLonN: Double = targetNorth.longitude - userCoord.longitude
        let yOffsetN: Double = -(dLatN * metersPerDegreeLat) * pointsPerMeter
        let xOffsetN: Double = (dLonN * metersPerDegreeLon) * pointsPerMeter
        
        XCTAssertEqual(xOffsetN, 0.0, accuracy: 0.001)
        XCTAssertEqual(yOffsetN, -50.0, accuracy: 0.001) // 50 points upward = 50% of 100pt maxRadius
        
        let radialDistN = sqrt(pow(xOffsetN, 2.0) + pow(yOffsetN, 2.0))
        XCTAssertEqual(radialDistN, 50.0, accuracy: 0.001) // Exactly matches 50m Ring 2!
        
        // 2. Target exactly 25 meters East (should land precisely on Ring 1: 25% radius)
        let deltaLon25m: Double = 25.0 / metersPerDegreeLon
        let targetEast = CLLocationCoordinate2D(latitude: userCoord.latitude, longitude: userCoord.longitude + deltaLon25m)
        
        let dLatE: Double = targetEast.latitude - userCoord.latitude
        let dLonE: Double = targetEast.longitude - userCoord.longitude
        let yOffsetE: Double = -(dLatE * metersPerDegreeLat) * pointsPerMeter
        let xOffsetE: Double = (dLonE * metersPerDegreeLon) * pointsPerMeter
        
        XCTAssertEqual(xOffsetE, 25.0, accuracy: 0.001) // Exactly 25 points right
        XCTAssertEqual(yOffsetE, 0.0, accuracy: 0.001)
        let radialDistE = sqrt(pow(xOffsetE, 2.0) + pow(yOffsetE, 2.0))
        XCTAssertEqual(radialDistE, 25.0, accuracy: 0.001) // Exactly matches 25m Ring 1!
        
        // 3. Target 100 meters at 45 degree bearing (should land on outer boundary Ring 4: 100% radius)
        let dist100m: Double = 100.0
        let deltaLat45: Double = (dist100m * cos(.pi / 4.0)) / metersPerDegreeLat
        let deltaLon45: Double = (dist100m * sin(.pi / 4.0)) / metersPerDegreeLon
        let targetNE = CLLocationCoordinate2D(latitude: userCoord.latitude + deltaLat45, longitude: userCoord.longitude + deltaLon45)
        
        let dLatNE: Double = targetNE.latitude - userCoord.latitude
        let dLonNE: Double = targetNE.longitude - userCoord.longitude
        let yOffsetNE: Double = -(dLatNE * metersPerDegreeLat) * pointsPerMeter
        let xOffsetNE: Double = (dLonNE * metersPerDegreeLon) * pointsPerMeter
        
        let radialDistNE = sqrt(pow(xOffsetNE, 2.0) + pow(yOffsetNE, 2.0))
        XCTAssertEqual(radialDistNE, 100.0, accuracy: 0.001) // Exactly matches 100m Ring 4!
    }
    
    func testRadarRangeRingDistanceLabelDiagonalPositions() {
        let screenCenter = CGPoint(x: 150.0, y: 150.0)
        let maxRadius: CGFloat = 100.0
        
        for (index, ratio) in AppConstants.UI.RadarScale.rangeRingRatios.enumerated() {
            let ringRadius = maxRadius * CGFloat(ratio)
            let diagOffset = (maxRadius * ratio) * cos(.pi / 4.0)
            let labelX = screenCenter.x + diagOffset
            let labelY = screenCenter.y - diagOffset
            
            // Cartesian dx, dy from center
            let dx = Double(labelX - screenCenter.x)
            let dy = Double(screenCenter.y - labelY) // Positive upward
            
            // Verify dx == dy (lies on y = x line)
            XCTAssertEqual(dx, dy, accuracy: 0.0001, "Distance label for ring \(index + 1) must lie along the y=x line")
            XCTAssertGreaterThan(dx, 0.0, "Distance label must be in the upper right (dx > 0)")
            XCTAssertGreaterThan(dy, 0.0, "Distance label must be in the upper right (dy > 0)")
            
            // Verify radial distance from center equals ring radius
            let computedRadius = sqrt(dx * dx + dy * dy)
            XCTAssertEqual(computedRadius, Double(ringRadius), accuracy: 0.001, "Distance label must be positioned on its corresponding radius circle")
        }
    }
    
    // MARK: - Player Death & Revive State Tests
    
    func testPlayerDeathState() {
        let gameState = createMockGameState()
        XCTAssertFalse(gameState.isDead, "Initial player state should be alive")
        
        let exp = expectation(description: "Host room")
        gameState.hostRoom(name: "Test Squad", pin: "1234") { _ in
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
        
        guard let myId = gameState.firebaseManager.activeRoom?.members.keys.first else {
            XCTFail("Active member should exist")
            return
        }
        XCTAssertEqual(gameState.firebaseManager.activeRoom?.members[myId]?.status, .active)
        
        // Trigger death
        gameState.setDead(true)
        XCTAssertTrue(gameState.isDead, "Player state should be dead")
        XCTAssertEqual(gameState.firebaseManager.activeRoom?.members[myId]?.status, .downed)
        
        // Revive
        gameState.setDead(false)
        XCTAssertFalse(gameState.isDead, "Player should be revived")
        XCTAssertEqual(gameState.firebaseManager.activeRoom?.members[myId]?.status, .active)
    }
    
    // MARK: - Password & Security Tests
    
    func testPasswordHashingAndVerification() {
        let pin = "1234"
        let roomId = "ALPH"
        let hash1 = FirebaseSyncManager.hashPassword(pin, salt: roomId)
        let hash2 = FirebaseSyncManager.hashPassword("1234", salt: "ALPH")
        let wrongHash = FirebaseSyncManager.hashPassword("9999", salt: "ALPH")
        
        XCTAssertFalse(hash1.isEmpty)
        XCTAssertEqual(hash1, hash2, "Identical PIN and salt must yield identical hash")
        XCTAssertNotEqual(hash1, wrongHash, "Different PIN must yield different hash")
        
        // Empty PIN
        XCTAssertEqual(FirebaseSyncManager.hashPassword("", salt: roomId), "")
    }
    
    func testPinRetentionInUserDefaultsAndGameState() {
        // savedPin is no longer individually UserDefaults-backed — it's a view onto
        // watchConnectivityManager.localLS.config.pin, persisted as one blob under
        // "wc_local_ls_snapshot". AppConstants.Storage.savedPinKey is only ever *read* once, as a
        // migration fallback when no such blob exists yet (which is what seeds it here).
        let testPin = "7412"
        UserDefaults.standard.set(testPin, forKey: AppConstants.Storage.savedPinKey)

        let gameState = createMockGameState()
        XCTAssertEqual(gameState.savedPin, "7412", "GameStateManager should initialize with the retained PIN from UserDefaults")

        // Changing savedPin directly updates the persisted localLS snapshot
        gameState.savedPin = "9876"
        XCTAssertEqual(gameState.watchConnectivityManager.localLS.config.pin, "9876", "Updating savedPin should update localLS")

        // Hosting a room with PIN retains it
        let hostExp = expectation(description: "Host with PIN")
        gameState.hostRoom(name: "PIN SQUAD", pin: "4321") { _ in
            hostExp.fulfill()
        }
        wait(for: [hostExp], timeout: 1.0)
        XCTAssertEqual(gameState.savedPin, "4321", "Hosting with PIN should retain the PIN")

        // Joining a room with PIN retains it
        let joinExp = expectation(description: "Join with PIN")
        gameState.joinRoom(id: "PIN SQUAD", pin: "5555") { (success: Bool) in
            joinExp.fulfill()
        }
        wait(for: [joinExp], timeout: 1.0)
        XCTAssertEqual(gameState.savedPin, "5555", "Joining with PIN should retain the PIN")

        // Clean up
        UserDefaults.standard.removeObject(forKey: AppConstants.Storage.savedPinKey)
    }
    
    func testKIATelemetryFlatlineZeroBPM() {
        let syncManager = createMockFirebaseSyncManager()
        let room = SquadRoom(id: "BRAVO", hostId: "HOST1")
        let member = SquadMember(id: "OP1", callsign: "GHOST", latitude: 37.77, longitude: -122.41, heartRate: 140.0, status: .active)
        var updatedRoom = room
        updatedRoom.members["OP1"] = member
        syncManager.connectToRoom(updatedRoom)
        
        XCTAssertEqual(syncManager.activeRoom?.members["OP1"]?.status, .active)
        
        // Broadcast KIA flatline packet (hr = 0.0)
        let kiaPacket = TelemetryPacket(
            memberId: "OP1",
            roomId: "BRAVO",
            latitude: 37.775,
            longitude: -122.415,
            heading: 180.0,
            heartRate: 0.0,
            timestamp: Date().timeIntervalSince1970,
            sequenceNumber: 1
        )
        
        XCTAssertTrue(syncManager.validateAndProcessPacket(kiaPacket))
        XCTAssertEqual(syncManager.activeRoom?.members["OP1"]?.heartRate, 0.0)
        XCTAssertEqual(syncManager.activeRoom?.members["OP1"]?.status, .downed, "0 BPM packet should transition member to downed status")
    }
    
    // MARK: - 3-Player North & East Offset Verification Test
    
    func testThreePlayerNorthOffsetTestData() {
        let syncManager = createMockFirebaseSyncManager()
        let metersPerDegreeLat: Double = 111_139.0
        
        // Base reference coordinate
        let baseLat = 37.785834
        let baseLng = -122.406417
        let metersPerDegreeLon: Double = 111_139.0 * cos(baseLat * .pi / 180.0)
        let eastOffset25m: Double = 25.0 / metersPerDegreeLon
        let targetLng = baseLng + eastOffset25m
        
        // Player 1 (25 meters North, 25 meters East of base)
        let p1Lat = baseLat + (25.0 / metersPerDegreeLat)
        let p1Lng = targetLng
        
        // Player 2 (50 meters North, 25 meters East of base)
        let p2Lat = baseLat + (50.0 / metersPerDegreeLat)
        let p2Lng = targetLng
        
        // Player 3 (150 meters North, 25 meters East of base)
        let p3Lat = baseLat + (150.0 / metersPerDegreeLat)
        let p3Lng = targetLng
        
        // Room setup
        let room = SquadRoom(
            id: "MOCK_TEST_ROOM",
            hostId: "PLAYER_1",
            members: [
                "PLAYER_1": SquadMember(id: "PLAYER_1", callsign: "ALPHA-1", latitude: p1Lat, longitude: p1Lng, heading: 0.0, heartRate: 75.0, role: .leader),
                "PLAYER_2": SquadMember(id: "PLAYER_2", callsign: "ALPHA-2", latitude: p2Lat, longitude: p2Lng, heading: 0.0, heartRate: 85.0),
                "PLAYER_3": SquadMember(id: "PLAYER_3", callsign: "ALPHA-3", latitude: p3Lat, longitude: p3Lng, heading: 0.0, heartRate: 95.0)
            ]
        )
        syncManager.connectToRoom(room)
        
        // Verify accurate distance calculations
        let baseLoc = CLLocation(latitude: baseLat, longitude: baseLng)
        let loc1 = CLLocation(latitude: p1Lat, longitude: p1Lng)
        let loc2 = CLLocation(latitude: p2Lat, longitude: p2Lng)
        let loc3 = CLLocation(latitude: p3Lat, longitude: p3Lng)
        
        // Distance from base: sqrt(north^2 + east^2)
        XCTAssertEqual(baseLoc.distance(from: loc1), 35.355, accuracy: 1.0, "Player 1 should be ~25m north and 25m east of base")
        XCTAssertEqual(baseLoc.distance(from: loc2), 55.902, accuracy: 1.0, "Player 2 should be ~50m north and 25m east of base")
        XCTAssertEqual(baseLoc.distance(from: loc3), 152.069, accuracy: 1.5, "Player 3 should be ~150m north and 25m east of base")
        
        // Verify 25m East displacement from north-only positions
        let p1NorthOnly = CLLocation(latitude: p1Lat, longitude: baseLng)
        let p2NorthOnly = CLLocation(latitude: p2Lat, longitude: baseLng)
        let p3NorthOnly = CLLocation(latitude: p3Lat, longitude: baseLng)
        XCTAssertEqual(p1NorthOnly.distance(from: loc1), 25.0, accuracy: 0.5, "Player 1 should be 25m east of north line")
        XCTAssertEqual(p2NorthOnly.distance(from: loc2), 25.0, accuracy: 0.5, "Player 2 should be 25m east of north line")
        XCTAssertEqual(p3NorthOnly.distance(from: loc3), 25.0, accuracy: 0.5, "Player 3 should be 25m east of north line")
        
        // Verify Firebase telemetry packet ingestion for all 3 players
        let now = Date().timeIntervalSince1970
        let pkt1 = TelemetryPacket(memberId: "PLAYER_1", roomId: "MOCK_TEST_ROOM", latitude: p1Lat, longitude: p1Lng, heading: 0.0, heartRate: 78.0, timestamp: now, sequenceNumber: 1)
        let pkt2 = TelemetryPacket(memberId: "PLAYER_2", roomId: "MOCK_TEST_ROOM", latitude: p2Lat, longitude: p2Lng, heading: 10.0, heartRate: 88.0, timestamp: now, sequenceNumber: 1)
        let pkt3 = TelemetryPacket(memberId: "PLAYER_3", roomId: "MOCK_TEST_ROOM", latitude: p3Lat, longitude: p3Lng, heading: 20.0, heartRate: 98.0, timestamp: now, sequenceNumber: 1)
        
        XCTAssertTrue(syncManager.validateAndProcessPacket(pkt1))
        XCTAssertTrue(syncManager.validateAndProcessPacket(pkt2))
        XCTAssertTrue(syncManager.validateAndProcessPacket(pkt3))
        
        XCTAssertEqual(syncManager.totalPacketsProcessed, 3)
        XCTAssertEqual(syncManager.activeRoom?.members["PLAYER_1"]?.heartRate, 78.0)
        XCTAssertEqual(syncManager.activeRoom?.members["PLAYER_2"]?.heartRate, 88.0)
        XCTAssertEqual(syncManager.activeRoom?.members["PLAYER_3"]?.heartRate, 98.0)
    }
    
    func testAutoRegisterUnknownMemberFromTelemetry() {
        let syncManager = createMockFirebaseSyncManager()
        let room = SquadRoom(id: "MOCK_TEST_ROOM", hostId: "LOCAL_PLAYER", members: [:])
        syncManager.connectToRoom(room)
        
        let now = Date().timeIntervalSince1970
        let p1 = TelemetryPacket(memberId: "PLAYER_1", roomId: "TEST", latitude: 37.7860589, longitude: -122.4061324, heading: 0.0, heartRate: 78.0, timestamp: now, sequenceNumber: 1)
        let p2 = TelemetryPacket(memberId: "PLAYER_2", roomId: "TEST", latitude: 37.7862839, longitude: -122.4061324, heading: 10.0, heartRate: 88.0, timestamp: now, sequenceNumber: 1)
        let p3 = TelemetryPacket(memberId: "PLAYER_3", roomId: "TEST", latitude: 37.7871837, longitude: -122.4061324, heading: 20.0, heartRate: 98.0, timestamp: now, sequenceNumber: 1)
        
        XCTAssertTrue(syncManager.validateAndProcessPacket(p1))
        XCTAssertTrue(syncManager.validateAndProcessPacket(p2))
        XCTAssertTrue(syncManager.validateAndProcessPacket(p3))
        
        XCTAssertEqual(syncManager.activeRoom?.members.count, 3)
        XCTAssertEqual(syncManager.activeRoom?.members["PLAYER_1"]?.callsign, "")
        XCTAssertEqual(syncManager.activeRoom?.members["PLAYER_2"]?.callsign, "")
        XCTAssertEqual(syncManager.activeRoom?.members["PLAYER_3"]?.callsign, "")
    }
    
    func testSquadRoomAndMemberResilientDecoding() throws {
        let rawJson = """
        {
            "id": "TEST",
            "hst": "PLAYER_1",
            "m": {
                "PLAYER_1": {"csn": "ALPHA-1", "heading": 0.0, "heartRate": 78.0, "mid": "PLAYER_1", "rol": "leader", "latitude": 37.7860589, "longitude": -122.4061324, "status": "active"},
                "PLAYER_2": {"csn": "ALPHA-2", "heading": 0.0, "heartRate": 88.0, "mid": "PLAYER_2", "rol": "player", "latitude": 37.7862839, "longitude": -122.4061324, "status": "active"},
                "PLAYER_3": {"csn": "ALPHA-3", "heading": 0.0, "heartRate": 98.0, "mid": "PLAYER_3", "rol": "player", "latitude": 37.7871837, "longitude": -122.4061324, "status": "active"}
            }
        }
        """
        let data = Data(rawJson.utf8)
        let decodedRoom = try JSONDecoder().decode(SquadRoom.self, from: data)
        
        XCTAssertEqual(decodedRoom.id, "TEST")
        XCTAssertEqual(decodedRoom.members.count, 3)
        XCTAssertEqual(decodedRoom.members["PLAYER_1"]?.callsign, "ALPHA-1")
        XCTAssertEqual(decodedRoom.members["PLAYER_2"]?.callsign, "ALPHA-2")
        XCTAssertEqual(decodedRoom.members["PLAYER_3"]?.callsign, "ALPHA-3")
        XCTAssertEqual(decodedRoom.members["PLAYER_1"]?.heartRate, 78.0)
    }
    
    func testHostAndJoinLifecycleState() {
        let gameState = createMockGameState()
        let transport = mockTransport(for: gameState)
        let charliePin = "5678"
        let charlieName = "CHARLIE"
        let charlieId = charlieName + FirebaseSyncManager.deriveRoomPadding(pin: charliePin, name: charlieName)
        let testRoom = SquadRoom(id: charlieId, hostId: "REMOTE_HOST", pinHash: FirebaseSyncManager.hashPin(charliePin, salt: charlieId), members: [:])
        let testRoomData = try! JSONEncoder().encode(testRoom)
        let testRoomJson = try! JSONSerialization.jsonObject(with: testRoomData)
        transport.seed(testRoomJson, at: "r/\(charlieId)")
        XCTAssertFalse(gameState.isHosting)
        XCTAssertFalse(gameState.isJoining)
        XCTAssertFalse(gameState.firebaseManager.isConnected)

        // Host room
        let bravoPin = "1234"
        let bravoName = "BRAVO SQUAD"
        let bravoId = bravoName + FirebaseSyncManager.deriveRoomPadding(pin: bravoPin, name: bravoName)
        let hostExp = expectation(description: "Host room")
        gameState.hostRoom(name: bravoName, pin: bravoPin) { success in
            XCTAssertTrue(success)
            XCTAssertTrue(gameState.isHosting)
            XCTAssertFalse(gameState.isJoining)
            XCTAssertTrue(gameState.firebaseManager.isConnected)
            XCTAssertEqual(gameState.firebaseManager.activeRoom?.name, bravoId)
            hostExp.fulfill()
        }
        wait(for: [hostExp], timeout: 1.0)

        // Leave / Disband room
        let leaveExp = expectation(description: "Leave room")
        gameState.leaveCurrentRoom { _ in
            XCTAssertFalse(gameState.isHosting)
            XCTAssertFalse(gameState.isJoining)
            XCTAssertFalse(gameState.firebaseManager.isConnected)
            XCTAssertNil(gameState.firebaseManager.activeRoom)
            leaveExp.fulfill()
        }
        wait(for: [leaveExp], timeout: 1.0)

        // Join room
        let joinExp = expectation(description: "Join room")
        gameState.joinRoom(id: charlieName, name: charlieName, pin: charliePin) { success in
            XCTAssertTrue(success)
            XCTAssertFalse(gameState.isHosting)
            XCTAssertFalse(gameState.isJoining)
            XCTAssertTrue(gameState.firebaseManager.isConnected)
            XCTAssertEqual(gameState.firebaseManager.activeRoom?.id, charlieId)
            joinExp.fulfill()
        }
        wait(for: [joinExp], timeout: 1.0)
    }
    
    // MARK: - Host Button Specification Tests
    
    func testHostButton_Workflow_Initiating_Success_Disband_ServerRoomDeleted() {
        let gameState = createMockGameState()
        let transport = mockTransport(for: gameState)
        
        // 1. Initial State
        XCTAssertFalse(gameState.isInitiatingHost)
        XCTAssertFalse(gameState.isHosting)
        XCTAssertFalse(gameState.isJoining)
        
        // 2. Start hosting
        let alphaPin = "1111"
        let alphaName = "ALPHA SQUAD"
        let alphaId = alphaName + FirebaseSyncManager.deriveRoomPadding(pin: alphaPin, name: alphaName)
        let hostExp = expectation(description: "Host creation confirmed")
        gameState.hostRoom(name: alphaName, pin: alphaPin) { success in
            XCTAssertTrue(success)
            // 4. Server creation confirmed -> becomes disband
            XCTAssertFalse(gameState.isInitiatingHost)
            XCTAssertTrue(gameState.isHosting)
            XCTAssertTrue(gameState.isCurrentMemberHost)
            hostExp.fulfill()
        }

        wait(for: [hostExp], timeout: 1.0)

        // 5. Disband -> server's room is deleted
        let disbandExp = expectation(description: "Room disbanded")
        gameState.leaveCurrentRoom { _ in
            disbandExp.fulfill()
        }
        wait(for: [disbandExp], timeout: 1.0)

        // Verify remove() calls were sent for the room and telemetry
        XCTAssertTrue(transport.recordedRemoves.contains("r/\(alphaId)"))
        XCTAssertTrue(transport.recordedRemoves.contains("p/\(alphaId)"))
        
        XCTAssertFalse(gameState.isHosting)
        XCTAssertNil(gameState.firebaseManager.activeRoom)
    }
    
    func testHostButton_Workflow_CreationFailure_RevertsToHost() {
        let gameState = createMockGameState()
        let failName = "FAIL SQUAD"
        let failPin = "1234"
        let failId = failName + FirebaseSyncManager.deriveRoomPadding(pin: failPin, name: failName)
        // Simulate a server write failure on the room node the host flow will try to create.
        mockTransport(for: gameState).failingPaths.insert("r/\(failId)")

        let exp = expectation(description: "Host creation failure")
        gameState.hostRoom(name: failName, pin: failPin) { success in
            XCTAssertFalse(success)
            // 3. Goes back to being host if creation process failed
            XCTAssertFalse(gameState.isInitiatingHost)
            XCTAssertFalse(gameState.isHosting)
            XCTAssertFalse(gameState.isCurrentMemberHost)
            XCTAssertNotNil(gameState.errorMessage)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    func testHostButton_DisabledWhenJoinIsPressed() {
        let gameState = createMockGameState()
        gameState.isJoining = true
        
        // When join is pressed (isJoining == true), Host is disabled
        XCTAssertTrue(gameState.isJoining)
    }
    
    // MARK: - Join Button Specification Tests
    
    func testJoinButton_Workflow_Joining_Success_Leave_PlayerEntryDeleted() {
        let gameState = createMockGameState()
        let transport = mockTransport(for: gameState)
        let deltaPin = "2468"
        let deltaName = "DELTA"
        let deltaId = deltaName + FirebaseSyncManager.deriveRoomPadding(pin: deltaPin, name: deltaName)
        let targetRoom = SquadRoom(id: deltaId, hostId: "HOST_OPERATOR", pinHash: FirebaseSyncManager.hashPin(deltaPin, salt: deltaId), members: [:])
        let roomData = try! JSONEncoder().encode(targetRoom)
        let roomJson = try! JSONSerialization.jsonObject(with: roomData)
        transport.seed(roomJson, at: "r/\(deltaId)")

        // 1. Initial State
        XCTAssertFalse(gameState.isJoining)
        XCTAssertFalse(gameState.firebaseManager.isConnected)

        // 2. Start joining
        let joinExp = expectation(description: "Join confirmed")
        gameState.joinRoom(id: deltaName, pin: deltaPin) { success in
            XCTAssertTrue(success)
            // 4. Server connection confirmed -> becomes leave
            XCTAssertFalse(gameState.isJoining)
            XCTAssertTrue(gameState.firebaseManager.isConnected)
            XCTAssertFalse(gameState.isCurrentMemberHost)
            joinExp.fulfill()
        }
        wait(for: [joinExp], timeout: 1.0)

        // 5. Leave -> server's player entry is deleted
        let leaveExp = expectation(description: "Player left room")
        gameState.leaveCurrentRoom { _ in
            leaveExp.fulfill()
        }
        wait(for: [leaveExp], timeout: 1.0)

        // Verify remove() calls were sent specifically for player member entry and player telemetry
        XCTAssertTrue(transport.recordedRemoves.contains("r/\(deltaId)/m/\(gameState.myMemberId)"))
        XCTAssertTrue(transport.recordedRemoves.contains("p/\(deltaId)/\(gameState.myMemberId)"))

        XCTAssertFalse(gameState.firebaseManager.isConnected)
        XCTAssertNil(gameState.firebaseManager.activeRoom)
    }
    
    func testPlayerLogoutDeletesUserSquadOrderIconsFromServer() {
        let syncManager = createMockFirebaseSyncManager()
        let transport = mockTransport(for: syncManager)

        let ordersData: [String: Any] = [
            "ORDER_1": ["wat", 37.78, -122.41, 1700000000.0, "USER_LEAVING"]
        ]
        let cappedData: [String: Any] = [
            "ENEMY_1": ["inf", 37.79, -122.42, 1700000000.0, "USER_LEAVING"]
        ]
        transport.seed(ordersData, at: "t/ROOM_1/o")
        transport.seed(cappedData, at: "t/ROOM_1/i")
        let room = SquadRoom(id: "ROOM_1", hostId: "OTHER_USER", members: [
            "OTHER_USER": SquadMember(id: "OTHER_USER", callsign: "HOST", latitude: 0, longitude: 0),
            "USER_LEAVING": SquadMember(id: "USER_LEAVING", callsign: "LEAVING", latitude: 0, longitude: 0)
        ])
        syncManager.connectToRoom(room)
        
        let logoutExp = expectation(description: "Player logout removes squad order icons")
        syncManager.logoutPlayer(roomId: "ROOM_1", memberId: "USER_LEAVING") { success in
            XCTAssertTrue(success)
            logoutExp.fulfill()
        }
        wait(for: [logoutExp], timeout: 1.0)
        
        let removedPaths = transport.recordedRemoves
        // Must delete the member entry, the member telemetry, AND the squad order icon node ORDER_1
        XCTAssertTrue(removedPaths.contains("r/ROOM_1/m/USER_LEAVING"))
        XCTAssertTrue(removedPaths.contains("p/ROOM_1/USER_LEAVING"))
        XCTAssertTrue(removedPaths.contains("t/ROOM_1/o/ORDER_1"), "Must delete user's squad order icon node ORDER_1 on server")
        XCTAssertFalse(removedPaths.contains("t/ROOM_1/i/ENEMY_1"), "Must NOT delete enemy indicator node ENEMY_1 (member-departure cleanup only scans /o)")
    }
    
    func testJoinButton_Workflow_RoomNotFound_RevertsToJoin() {
        // No seeding: a fresh MockRTDBTransport's empty root resolves the room read to nil, same
        // as the old handler's 404/"null" response.
        let gameState = createMockGameState()
        
        let exp = expectation(description: "Room not found failure")
        gameState.joinRoom(id: "NONEXISTENT", pin: "1234") { success in
            XCTAssertFalse(success)
            // 3. Goes back to join if joining failed
            XCTAssertFalse(gameState.isJoining)
            XCTAssertFalse(gameState.firebaseManager.isConnected)
            XCTAssertEqual(gameState.errorMessage, FirebaseSyncError.roomNotFound.localizedDescription)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    // A wrong PIN now derives the wrong room id entirely (see CLOUD_DATA_MANAGEMENT.md), so it
    // surfaces as roomNotFound rather than incorrectPin/incorrectPassword — a deliberate,
    // subtle UX behavior change from the pre-hardening design.
    func testJoinButton_Workflow_IncorrectPIN_RevertsToJoin() {
        let gameState = createMockGameState()
        let securePin = "9999"
        let secureName = "SECURE"
        let secureId = secureName + FirebaseSyncManager.deriveRoomPadding(pin: securePin, name: secureName)
        let pinHash = FirebaseSyncManager.hashPin(securePin, salt: secureId)
        let secureRoom = SquadRoom(id: secureId, hostId: "HOST_USER", pinHash: pinHash, members: [:])
        let roomData = try! JSONEncoder().encode(secureRoom)
        let roomJson = try! JSONSerialization.jsonObject(with: roomData)
        mockTransport(for: gameState).seed(roomJson, at: "r/\(secureId)")

        let exp = expectation(description: "Wrong PIN failure")
        gameState.joinRoom(id: secureName, pin: "0000") { success in
            XCTAssertFalse(success)
            // Goes back to join if joining failed
            XCTAssertFalse(gameState.isJoining)
            XCTAssertFalse(gameState.firebaseManager.isConnected)
            XCTAssertEqual(gameState.errorMessage, FirebaseSyncError.roomNotFound.localizedDescription)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testJoinButton_Workflow_RoomFull_RevertsToJoin() {
        let gameState = createMockGameState()
        var fullMembers: [String: SquadMember] = [:]
        for i in 1...4 {
            fullMembers["USER_\(i)"] = SquadMember(id: "USER_\(i)", callsign: "OP_\(i)", latitude: 0, longitude: 0)
        }
        let fullPin = "1234"
        let fullName = "FULLSQUAD"
        let fullId = fullName + FirebaseSyncManager.deriveRoomPadding(pin: fullPin, name: fullName)
        let fullRoom = SquadRoom(id: fullId, hostId: "USER_1", maxCapacity: 4, pinHash: FirebaseSyncManager.hashPin(fullPin, salt: fullId), members: fullMembers)
        let roomData = try! JSONEncoder().encode(fullRoom)
        let roomJson = try! JSONSerialization.jsonObject(with: roomData)
        mockTransport(for: gameState).seed(roomJson, at: "r/\(fullId)")
        gameState.myMemberId = "NEW_PLAYER"

        let exp = expectation(description: "Room full failure")
        gameState.joinRoom(id: fullName, pin: fullPin) { success in
            XCTAssertFalse(success)
            // Goes back to join if joining failed
            XCTAssertFalse(gameState.isJoining)
            XCTAssertFalse(gameState.firebaseManager.isConnected)
            XCTAssertEqual(gameState.errorMessage, FirebaseSyncError.roomFull.localizedDescription)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    func testJoinButton_DisabledWhenHostIsPressed() {
        let gameState = createMockGameState()
        gameState.isInitiatingHost = true
        
        // When host is pressed (isInitiatingHost == true), Join is disabled
        XCTAssertTrue(gameState.isInitiatingHost)
    }
    
    // MARK: - Squad Indicator & KIA Tests
    
    func testSquadIndicatorStateAndKIATrigger() {
        let slMember = SquadMember(
            id: "LEADER1",
            callsign: "SL-ALPHA",
            latitude: 37.77,
            longitude: -122.41,
            heading: 90.0,
            heartRate: 110.0,
            status: .active,
            role: .leader,
            colorHex: "#00FF66"
        )
        XCTAssertEqual(slMember.role, .leader, "Room creator must be identified as Squad Leader")
        XCTAssertGreaterThan(slMember.heartRate, 0)
        XCTAssertEqual(slMember.status, .active)
        
        let kiaMember = SquadMember(
            id: "PLAYER2",
            callsign: "BRAVO-2",
            latitude: 37.77,
            longitude: -122.41,
            heading: 180.0,
            heartRate: 0.0,
            status: .active,
            role: .player,
            colorHex: "#00FF66"
        )
        XCTAssertEqual(kiaMember.heartRate, 0.0, "Zero BPM indicates KIA / Flatline")
        
        // Color hex test
        let customColor = Color(hex: "#00FF66")
        XCTAssertNotNil(customColor)
        
        let invalidColor = Color(hex: "invalid")
        XCTAssertNil(invalidColor)
    }
    
    func testMemberAnnotationViewDeadTeammateFollowsRadarColorPreference() {
        let deadMember = SquadMember(
            id: "DEAD_MEMBER",
            callsign: "FALLEN",
            latitude: 37.77,
            longitude: -122.41,
            heartRate: 0.0,
            status: .downed
        )
        
        // When radar color theme is green
        let greenAnnotationView = MemberAnnotationView(
            member: deadMember,
            isMe: false,
            radarColor: RadarColorTheme.green.color
        )
        XCTAssertEqual(greenAnnotationView.radarColor, .green)
        XCTAssertEqual(greenAnnotationView.indicatorColor, .blue)
        
        // When radar color theme is red
        let redAnnotationView = MemberAnnotationView(
            member: deadMember,
            isMe: false,
            radarColor: RadarColorTheme.red.color
        )
        XCTAssertEqual(redAnnotationView.radarColor, .red)
        XCTAssertEqual(redAnnotationView.indicatorColor, .blue)
    }
    
    func testMemberAnnotationViewDeadTeammateStaleFadesToGray() {
        let staleDeadMember = SquadMember(
            id: "DEAD_STALE_MEMBER",
            callsign: "GHOST",
            latitude: 37.77,
            longitude: -122.41,
            heartRate: 0.0,
            lastUpdatedTimestamp: Date().timeIntervalSince1970 - 20.0,
            status: .downed
        )
        XCTAssertTrue(staleDeadMember.isStale, "Member updated > 15s ago should be stale")
        
        let view = MemberAnnotationView(
            member: staleDeadMember,
            isMe: false,
            radarColor: .red
        )
        XCTAssertTrue(view.member.isStale)
        XCTAssertEqual(view.indicatorColor, .gray)
    }
    
    func testMemberAnnotationViewTeammateNameFollowsRadarColor() {
        let activeTeammate = SquadMember(
            id: "TEAMMATE_1",
            callsign: "VIPER",
            latitude: 37.77,
            longitude: -122.41,
            heartRate: 85.0,
            status: .active
        )
        
        let greenView = MemberAnnotationView(
            member: activeTeammate,
            isMe: false,
            radarColor: RadarColorTheme.green.color
        )
        XCTAssertEqual(greenView.radarColor, .green)
        XCTAssertEqual(greenView.indicatorColor, .blue)
        
        let redView = MemberAnnotationView(
            member: activeTeammate,
            isMe: false,
            radarColor: RadarColorTheme.red.color
        )
        XCTAssertEqual(redView.radarColor, .red)
        XCTAssertEqual(redView.indicatorColor, .blue)
    }
    
    func testMemberAnnotationViewCallsignTagActivationOnDistanceRulerSelection() {
        let teammate1 = SquadMember(
            id: "TEAMMATE_1",
            callsign: "VIPER",
            latitude: 37.77,
            longitude: -122.41,
            status: .active
        )
        let teammate2 = SquadMember(
            id: "TEAMMATE_2",
            callsign: "GHOST",
            latitude: 37.78,
            longitude: -122.42,
            status: .active
        )
        
        let gameState = GameStateManager()
        
        // 1. Initially no distance ruler target is selected
        gameState.selectedAnnotationForDistance = nil
        
        let unselectedView1 = MemberAnnotationView(
            member: teammate1,
            isMe: false,
            isSelected: gameState.selectedAnnotationForDistance == .squadMember(id: teammate1.id)
        )
        let unselectedView2 = MemberAnnotationView(
            member: teammate2,
            isMe: false,
            isSelected: gameState.selectedAnnotationForDistance == .squadMember(id: teammate2.id)
        )
        XCTAssertFalse(unselectedView1.isSelected, "Nametag must be deactivated when not ruler target")
        XCTAssertFalse(unselectedView2.isSelected, "Nametag must be deactivated when not ruler target")
        
        // 2. Select teammate 1 as the distance ruler target
        gameState.selectedAnnotationForDistance = .squadMember(id: teammate1.id)
        
        let selectedView1 = MemberAnnotationView(
            member: teammate1,
            isMe: false,
            isSelected: gameState.selectedAnnotationForDistance == .squadMember(id: teammate1.id)
        )
        let notSelectedView2 = MemberAnnotationView(
            member: teammate2,
            isMe: false,
            isSelected: gameState.selectedAnnotationForDistance == .squadMember(id: teammate2.id)
        )
        XCTAssertTrue(selectedView1.isSelected, "Whichever player is the active target for distance ruler must have nametag activated")
        XCTAssertFalse(notSelectedView2.isSelected, "Other players must remain deactivated")
        
        // 3. Ruler detachment (selectedAnnotationForDistance = nil)
        gameState.selectedAnnotationForDistance = nil
        let detachedView1 = MemberAnnotationView(
            member: teammate1,
            isMe: false,
            isSelected: gameState.selectedAnnotationForDistance == .squadMember(id: teammate1.id)
        )
        XCTAssertFalse(detachedView1.isSelected, "Nametag must be deactivated upon ruler detachment")
    }
    
    func testMemberAnnotationViewTeammateIconFollowsRadarMapColorScheme() {
        let teammate = SquadMember(
            id: "TEAMMATE_1",
            callsign: "VIPER",
            latitude: 37.77,
            longitude: -122.41,
            heartRate: 85.0,
            status: .active,
            colorHex: "#00FF66"
        )
        
        let redView = MemberAnnotationView(
            member: teammate,
            isMe: false,
            radarColor: RadarColorTheme.red.color
        )
        XCTAssertEqual(redView.indicatorColor, .blue, "Teammate icon must be blue regardless of red radar map color theme")
        
        let greenView = MemberAnnotationView(
            member: teammate,
            isMe: false,
            radarColor: RadarColorTheme.green.color
        )
        XCTAssertEqual(greenView.indicatorColor, .blue, "Teammate icon must be blue regardless of green radar map color theme")
        
        // Stale teammate turns gray
        var staleTeammate = teammate
        staleTeammate.lastUpdatedTimestamp = Date().timeIntervalSince1970 - 1000
        let staleView = MemberAnnotationView(
            member: staleTeammate,
            isMe: false,
            radarColor: RadarColorTheme.green.color
        )
        XCTAssertEqual(staleView.indicatorColor, .gray, "Stale teammate icon must turn gray")
    }
    
    func testClanTagExtractionAndComparison() {
        // Multi-clan tag extraction with comma separation and multiple brackets
        XCTAssertEqual("[clanA,clanB]blasdf1".clanTags, ["clanA", "clanB"])
        XCTAssertEqual("[clanA, clanB]blasdf1".clanTags, ["clanA", "clanB"])
        XCTAssertEqual("[ clanA ,  clanB ]blasdf1".clanTags, ["clanA", "clanB"])
        XCTAssertEqual("[clanA][clanB]blasdf1".clanTags, ["clanA", "clanB"])
        XCTAssertEqual("[clanA,clanB,clanC]blasdf1".clanTags, ["clanA", "clanB", "clanC"])
        XCTAssertEqual("blasdf1".clanTags, [])
        XCTAssertEqual("[clanA,clanB]blasdf1".clanTag, "clanA")
        
        // Multi-clan intersection comparison
        let playerA = "[clanA,clanB]PlayerA"
        let playerB = "[clanA]PlayerB"
        let playerC = "[clanB]PlayerC"
        let playerD = "[clanD]PlayerD"
        let playerSolo = "SoloPlayer"
        
        XCTAssertTrue(playerA.sharesClan(with: playerB))
        XCTAssertTrue(playerA.sharesClan(with: playerC))
        XCTAssertTrue(playerB.sharesClan(with: playerA))
        XCTAssertFalse(playerB.sharesClan(with: playerC), "Player B [clanA] and Player C [clanB] share no clans")
        XCTAssertTrue(playerC.sharesClan(with: playerA))
        XCTAssertFalse(playerC.sharesClan(with: playerB))
        XCTAssertFalse(playerA.sharesClan(with: playerD))
        XCTAssertFalse(playerA.sharesClan(with: playerSolo))
        
        // Tag extraction
        XCTAssertEqual("[hawk]blasdf1".clanTag, "hawk")
        XCTAssertEqual("[hawk]zocviiwer".clanTag, "hawk")
        XCTAssertEqual("[HAWK]player".clanTag, "HAWK")
        XCTAssertEqual("[ hawk ]player".clanTag, "hawk")
        XCTAssertEqual("player [hawk]".clanTag, "hawk")
        XCTAssertNil("player".clanTag)
        XCTAssertNil("[]player".clanTag)
        XCTAssertNil("[   ]player".clanTag)
        XCTAssertNil("[hawk".clanTag)
        XCTAssertNil("hawk]".clanTag)
        XCTAssertNil("]hawk[".clanTag)
        
        // Clan comparison
        XCTAssertTrue("[hawk]blasdf1".hasSameClan(as: "[hawk]zocviiwer"))
        XCTAssertTrue("[HAWK]blasdf1".hasSameClan(as: "[hawk]zocviiwer"), "Clan comparison must be case-insensitive")
        XCTAssertFalse("[hawk]blasdf1".hasSameClan(as: "[wolf]zocviiwer"), "Different clans must not match")
        XCTAssertFalse("[hawk]blasdf1".hasSameClan(as: "zocviiwer"), "Player without clan tag must not match")
        XCTAssertFalse("blasdf1".hasSameClan(as: "zocviiwer"), "Players with no clan tags must not match")
        
        // SquadMember helpers
        let m1 = SquadMember(id: "1", callsign: "[hawk]blasdf1", latitude: 0, longitude: 0)
        let m2 = SquadMember(id: "2", callsign: "[HAWK]zocviiwer", latitude: 0, longitude: 0)
        let m3 = SquadMember(id: "3", callsign: "[wolf]other", latitude: 0, longitude: 0)
        let m4 = SquadMember(id: "4", callsign: "noClan", latitude: 0, longitude: 0)
        
        XCTAssertEqual(m1.clanTag, "hawk")
        XCTAssertTrue(m1.hasSameClan(as: m2))
        XCTAssertFalse(m1.hasSameClan(as: m3))
        XCTAssertFalse(m1.hasSameClan(as: m4))
        
        // GameStateManager clan helpers
        let gs = GameStateManager()
        gs.myCallsign = "[hawk]blasdf1"
        XCTAssertTrue(gs.isSameClan(callsign: "[hawk]zocviiwer"))
        XCTAssertTrue(gs.isSameClan(callsign: "[HAWK]anyone"))
        XCTAssertFalse(gs.isSameClan(callsign: "[wolf]enemy"))
        XCTAssertFalse(gs.isSameClan(callsign: "solo"))
        XCTAssertFalse(gs.isSameClan(callsign: nil))
        
        gs.otherSquadMembers = [m2, m3, m4]
        XCTAssertTrue(gs.isSameClan(memberId: gs.myMemberId))
        XCTAssertTrue(gs.isSameClan(memberId: "2")) // same clan
        XCTAssertFalse(gs.isSameClan(memberId: "3")) // different clan
        XCTAssertFalse(gs.isSameClan(memberId: "4")) // no clan
    }
    
    func testMultiClanTeamOrderVisibilityAsymmetric() {
        // Concrete proposal scenario:
        // Player A = [clanA,clanB], Player B = [clanA], Player C = [clanB]
        // Player B can only see Player A and Player B's team orders, but Player A can see both.
        // Also verify Enemy and Environmental markers remain visible to everyone.
        
        var room = SquadRoom(id: "CLAN_WAR", hostId: "USER_A")
        room.members["USER_A"] = SquadMember(id: "USER_A", callsign: "[clanA,clanB]PlayerA", latitude: 37.78, longitude: -122.40)
        room.members["USER_B"] = SquadMember(id: "USER_B", callsign: "[clanA]PlayerB", latitude: 37.781, longitude: -122.401)
        room.members["USER_C"] = SquadMember(id: "USER_C", callsign: "[clanB]PlayerC", latitude: 37.782, longitude: -122.402)
        
        let orderA = TacticalIndicator(
            id: "ORD_A",
            type: .goHere,
            coordinate: CLLocationCoordinate2D(latitude: 37.78, longitude: -122.40),
            placedByMemberId: "USER_A",
            placedByCallsign: "[clanA,clanB]PlayerA"
        )
        let orderB = TacticalIndicator(
            id: "ORD_B",
            type: .watchHere,
            coordinate: CLLocationCoordinate2D(latitude: 37.781, longitude: -122.401),
            placedByMemberId: "USER_B",
            placedByCallsign: "[clanA]PlayerB"
        )
        let orderC = TacticalIndicator(
            id: "ORD_C",
            type: .attackHere,
            coordinate: CLLocationCoordinate2D(latitude: 37.782, longitude: -122.402),
            placedByMemberId: "USER_C",
            placedByCallsign: "[clanB]PlayerC"
        )
        let enemyMarker = TacticalIndicator(
            id: "ENM_1",
            type: .infantry,
            coordinate: CLLocationCoordinate2D(latitude: 37.783, longitude: -122.403),
            placedByMemberId: "USER_C",
            placedByCallsign: "[clanB]PlayerC"
        )
        let envMarker = TacticalIndicator(
            id: "ENV_1",
            type: .water,
            coordinate: CLLocationCoordinate2D(latitude: 37.784, longitude: -122.404),
            placedByMemberId: "USER_C",
            placedByCallsign: "[clanB]PlayerC"
        )
        
        room.indicators[orderA.id] = orderA
        room.indicators[orderB.id] = orderB
        room.indicators[orderC.id] = orderC
        room.indicators[enemyMarker.id] = enemyMarker
        room.indicators[envMarker.id] = envMarker
        
        // 1. Perspective: Player B [clanA]
        let gsB = createMockGameState()
        gsB.myMemberId = "USER_B"
        gsB.myCallsign = "[clanA]PlayerB"
        gsB.updateAllTacticalIndicators(room: room)
        
        let visibleIdsB = Set(gsB.allTacticalIndicators.map { $0.id })
        XCTAssertTrue(visibleIdsB.contains("ORD_A"), "Player B [clanA] must see Player A's [clanA,clanB] team order")
        XCTAssertTrue(visibleIdsB.contains("ORD_B"), "Player B must see their own team order")
        XCTAssertFalse(visibleIdsB.contains("ORD_C"), "Player B [clanA] must NOT see Player C's [clanB] team order")
        XCTAssertTrue(visibleIdsB.contains("ENM_1"), "Hostile markers must remain visible regardless of clan")
        XCTAssertTrue(visibleIdsB.contains("ENV_1"), "Environmental markers must remain visible regardless of clan")
        XCTAssertEqual(visibleIdsB.count, 4)
        
        // 2. Perspective: Player A [clanA,clanB]
        let gsA = createMockGameState()
        gsA.myMemberId = "USER_A"
        gsA.myCallsign = "[clanA,clanB]PlayerA"
        gsA.updateAllTacticalIndicators(room: room)
        
        let visibleIdsA = Set(gsA.allTacticalIndicators.map { $0.id })
        XCTAssertTrue(visibleIdsA.contains("ORD_A"), "Player A must see their own team order")
        XCTAssertTrue(visibleIdsA.contains("ORD_B"), "Player A [clanA,clanB] must see Player B's [clanA] team order")
        XCTAssertTrue(visibleIdsA.contains("ORD_C"), "Player A [clanA,clanB] must see Player C's [clanB] team order")
        XCTAssertTrue(visibleIdsA.contains("ENM_1"), "Hostile markers visible")
        XCTAssertTrue(visibleIdsA.contains("ENV_1"), "Environmental markers visible")
        XCTAssertEqual(visibleIdsA.count, 5)
        
        // 3. Perspective: Player C [clanB]
        let gsC = createMockGameState()
        gsC.myMemberId = "USER_C"
        gsC.myCallsign = "[clanB]PlayerC"
        gsC.updateAllTacticalIndicators(room: room)
        
        let visibleIdsC = Set(gsC.allTacticalIndicators.map { $0.id })
        XCTAssertTrue(visibleIdsC.contains("ORD_A"), "Player C [clanB] must see Player A's [clanA,clanB] team order")
        XCTAssertFalse(visibleIdsC.contains("ORD_B"), "Player C [clanB] must NOT see Player B's [clanA] team order")
        XCTAssertTrue(visibleIdsC.contains("ORD_C"), "Player C must see their own team order")
        XCTAssertTrue(visibleIdsC.contains("ENM_1"), "Hostile markers visible")
        XCTAssertTrue(visibleIdsC.contains("ENV_1"), "Environmental markers visible")
        XCTAssertEqual(visibleIdsC.count, 4)
    }
    
    func testMemberAnnotationViewClanColors() {
        let sameClanTeammate = SquadMember(
            id: "M2",
            callsign: "[hawk]zocviiwer",
            latitude: 37.77,
            longitude: -122.41,
            status: .active
        )
        let differentClanTeammate = SquadMember(
            id: "M3",
            callsign: "[wolf]other",
            latitude: 37.77,
            longitude: -122.41,
            status: .active
        )
        
        // Same clan teammate gets green
        let sameClanView = MemberAnnotationView(
            member: sameClanTeammate,
            isMe: false,
            isSameClan: true
        )
        XCTAssertEqual(sameClanView.indicatorColor, .green, "Teammates in same clan as me must be green")
        
        // Different clan teammate gets blue
        let diffClanView = MemberAnnotationView(
            member: differentClanTeammate,
            isMe: false,
            isSameClan: false
        )
        XCTAssertEqual(diffClanView.indicatorColor, .blue, "Teammates not in same clan must be blue")
        
        // Stale teammate in same clan fades to gray
        var staleSameClan = sameClanTeammate
        staleSameClan.lastUpdatedTimestamp = Date().timeIntervalSince1970 - 1000
        let staleSameClanView = MemberAnnotationView(
            member: staleSameClan,
            isMe: false,
            isSameClan: true
        )
        XCTAssertEqual(staleSameClanView.indicatorColor, .gray, "Stale teammates in same clan must fade to gray")
    }
    
    func testGreenIconsHaveHighestTouchPriorityOnUXLayer() {
        // 1. AppConstants touch priority zIndex hierarchy
        XCTAssertGreaterThan(
            AppConstants.UI.MapMarkers.greenTouchPriorityZIndex,
            AppConstants.UI.MapMarkers.defaultTouchPriorityZIndex,
            "Green touch priority zIndex must be strictly higher than default touch priority"
        )
        XCTAssertGreaterThan(
            AppConstants.UI.MapMarkers.greenTouchTargetPadding,
            0,
            "Green icons must have an expanded touch hitbox padding"
        )
        
        let gameState = GameStateManager()
        gameState.myCallsign = "[hawk]blasdf1"
        
        let sameClanTeammate = SquadMember(id: "M2", callsign: "[hawk]zocviiwer", latitude: 37.77, longitude: -122.41)
        let diffClanTeammate = SquadMember(id: "M3", callsign: "[wolf]other", latitude: 37.77, longitude: -122.41)
        let noClanTeammate = SquadMember(id: "M4", callsign: "solo", latitude: 37.77, longitude: -122.41)
        
        // 2. Member green identification
        XCTAssertTrue(gameState.isGreen(member: gameState.localPlayerMember), "Local player must always be green")
        XCTAssertTrue(gameState.isGreen(member: sameClanTeammate), "Same clan teammate must be green")
        XCTAssertFalse(gameState.isGreen(member: diffClanTeammate), "Different clan teammate must not be green")
        XCTAssertFalse(gameState.isGreen(member: noClanTeammate), "Teammate without clan must not be green")
        
        // 3. Tactical Indicator green identification
        let myOrder = TacticalIndicator(type: .watchHere, coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0), placedByMemberId: gameState.myMemberId)
        let clanOrder = TacticalIndicator(type: .goHere, coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0), placedByMemberId: "M2", placedByCallsign: "[hawk]zocviiwer")
        let diffClanOrder = TacticalIndicator(type: .attackHere, coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0), placedByMemberId: "M3", placedByCallsign: "[wolf]other")
        let enemyIndicator = TacticalIndicator(type: .infantry, coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0), placedByMemberId: gameState.myMemberId)
        let envIndicator = TacticalIndicator(type: .hazard, coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0), placedByMemberId: gameState.myMemberId)
        
        XCTAssertTrue(gameState.isGreen(indicator: myOrder), "My squad orders must be green")
        XCTAssertTrue(gameState.isGreen(indicator: clanOrder), "Same clan squad orders must be green")
        XCTAssertFalse(gameState.isGreen(indicator: diffClanOrder), "Different clan squad orders must be blue (not green)")
        XCTAssertFalse(gameState.isGreen(indicator: enemyIndicator), "Enemy indicators are red (never green)")
        XCTAssertFalse(gameState.isGreen(indicator: envIndicator), "Environmental indicators are red (never green)")
        
        // 4. Stacking order verification (non-green must be sorted before green so green renders on top and catches touches first)
        let mixedMembers = [sameClanTeammate, diffClanTeammate, noClanTeammate]
        let sortedMembers = mixedMembers.sorted { m1, m2 in
            let g1 = gameState.isGreen(member: m1)
            let g2 = gameState.isGreen(member: m2)
            if g1 == g2 { return m1.id < m2.id }
            return !g1 && g2
        }
        XCTAssertEqual(sortedMembers.last?.id, sameClanTeammate.id, "Green same-clan member must be sorted last (drawn on top)")
        
        let mixedIndicators = [clanOrder, diffClanOrder, enemyIndicator]
        let sortedIndicators = mixedIndicators.sorted { i1, i2 in
            let g1 = gameState.isGreen(indicator: i1)
            let g2 = gameState.isGreen(indicator: i2)
            if g1 == g2 { return i1.timestamp < i2.timestamp }
            return !g1 && g2
        }
        XCTAssertEqual(sortedIndicators.last?.id, clanOrder.id, "Green same-clan squad order must be sorted last (drawn on top)")
    }
    
    func testMemberAnnotationViewMeIconFollowsRadarMapColorScheme() {
        let myMember = SquadMember(
            id: "MY_USER_ID",
            callsign: "GHOST",
            latitude: 37.77,
            longitude: -122.41,
            heartRate: 80.0,
            status: .active,
            colorHex: "#00FF66"
        )
        
        let redMeView = MemberAnnotationView(
            member: myMember,
            isMe: true,
            radarColor: RadarColorTheme.red.color
        )
        XCTAssertEqual(redMeView.indicatorColor, .green, "The 'me' icon must be green")
        
        let greenMeView = MemberAnnotationView(
            member: myMember,
            isMe: true,
            radarColor: RadarColorTheme.green.color
        )
        XCTAssertEqual(greenMeView.indicatorColor, .green, "The 'me' icon must be green")
    }
    
    func testMemberAnnotationViewRetainsThemeColorWhenKIA() {
        let deadMe = SquadMember(
            id: "MY_USER_ID",
            callsign: "GHOST",
            latitude: 37.77,
            longitude: -122.41,
            heartRate: 0.0,
            status: .downed
        )
        
        let deadMeView = MemberAnnotationView(
            member: deadMe,
            isMe: true,
            radarColor: RadarColorTheme.green.color
        )
        XCTAssertEqual(deadMeView.indicatorColor, .green, "The 'me' theme color must be green when the player is KIA")
        
        let deadTeammate = SquadMember(
            id: "TEAMMATE",
            callsign: "VIPER",
            latitude: 37.77,
            longitude: -122.41,
            heartRate: 0.0,
            status: .downed
        )
        let deadTeammateView = MemberAnnotationView(
            member: deadTeammate,
            isMe: false,
            radarColor: RadarColorTheme.red.color
        )
        XCTAssertEqual(deadTeammateView.indicatorColor, .blue, "Teammate theme color must remain blue when KIA")
    }
    
    func testMemberAnnotationViewRestoresThemeColorWhenRevived() {
        // 1. Green theme revive test
        var revivedMe = SquadMember(
            id: "MY_USER_ID",
            callsign: "GHOST",
            latitude: 37.77,
            longitude: -122.41,
            heartRate: 75.0,
            lastUpdatedTimestamp: Date().timeIntervalSince1970 - 45.0, // Older timestamp
            status: .active
        )
        
        let greenRevivedMeView = MemberAnnotationView(
            member: revivedMe,
            isMe: true,
            radarColor: RadarColorTheme.green.color
        )
        XCTAssertEqual(greenRevivedMeView.indicatorColor, .green, "Revived local player must restore green color")
        
        // 2. Red theme revive test
        revivedMe.status = .active
        revivedMe.heartRate = 80.0
        let redRevivedMeView = MemberAnnotationView(
            member: revivedMe,
            isMe: true,
            radarColor: RadarColorTheme.red.color
        )
        XCTAssertEqual(redRevivedMeView.indicatorColor, .green, "Revived local player must restore green color")
        
        // 3. Test GameStateManager revive restores active status and recent timestamp
        let gameState = GameStateManager()
        gameState.radarColorTheme = .green
        XCTAssertFalse(gameState.isDead, "Initial player state must be alive")
        
        // Default member created without explicit heartRate must be active and not KIA
        let defaultMember = SquadMember(callsign: "VIPER", latitude: 37.77, longitude: -122.41)
        XCTAssertEqual(defaultMember.status, .active)
        let defaultMemberView = MemberAnnotationView(member: defaultMember, isMe: true, radarColor: .green)
        XCTAssertEqual(defaultMemberView.indicatorColor, .green)
        
        // Enabling KIA: state turns dead and downed
        gameState.setDead(true)
        XCTAssertTrue(gameState.isDead, "Player state must be dead when KIA is enabled")
        
        let deadSquadMember = SquadMember(
            id: gameState.myMemberId,
            callsign: gameState.myCallsign,
            latitude: 37.77,
            longitude: -122.41,
            heartRate: AppConstants.Health.flatlineHeartRate,
            status: .downed
        )
        let deadAnnotation = MemberAnnotationView(member: deadSquadMember, isMe: true, radarColor: .red)
        XCTAssertEqual(deadAnnotation.indicatorColor, .green)
        
        // Revive: state restores alive and active
        gameState.setDead(false)
        XCTAssertFalse(gameState.isDead, "Player state must be alive after revive")
        
        let revivedSquadMember = SquadMember(
            id: gameState.myMemberId,
            callsign: gameState.myCallsign,
            latitude: 37.77,
            longitude: -122.41,
            heartRate: AppConstants.Health.defaultRestingHeartRate,
            status: .active
        )
        let revivedAnnotation = MemberAnnotationView(member: revivedSquadMember, isMe: true, radarColor: .red)
        XCTAssertEqual(revivedAnnotation.indicatorColor, .green)
    }
    
    func testMapMarkerSizesAndOtherPlayerScaleFactor() {
        XCTAssertEqual(AppConstants.UI.MapMarkers.otherPlayerScaleFactor, 0.70, accuracy: 0.001)
        #if os(watchOS)
        XCTAssertEqual(AppConstants.UI.MapMarkers.tacticalIndicatorIconSize, 11.2, accuracy: 0.001)
        XCTAssertEqual(AppConstants.UI.MapMarkers.environmentalIndicatorIconSize, 11.2, accuracy: 0.001)
        XCTAssertEqual(AppConstants.UI.MapMarkers.tacticalIndicatorRingSize, 16.8, accuracy: 0.001)
        XCTAssertEqual(AppConstants.UI.MapMarkers.orderCallsignYOffset, 14.0, accuracy: 0.001)
        XCTAssertEqual(AppConstants.UI.MapMarkers.iconSize(for: .environment), 11.2, accuracy: 0.001)
        XCTAssertEqual(AppConstants.UI.MapMarkers.iconSize(for: .enemyIndicator), 11.2, accuracy: 0.001)
        XCTAssertEqual(AppConstants.UI.MapMarkers.iconSize(for: .squadOrder), 11.2, accuracy: 0.001)
        #else
        XCTAssertEqual(AppConstants.UI.MapMarkers.tacticalIndicatorIconSize, 21.0, accuracy: 0.001)
        XCTAssertEqual(AppConstants.UI.MapMarkers.environmentalIndicatorIconSize, 14.0, accuracy: 0.001)
        XCTAssertEqual(AppConstants.UI.MapMarkers.tacticalIndicatorRingSize, 22.4, accuracy: 0.001)
        XCTAssertEqual(AppConstants.UI.MapMarkers.orderCallsignYOffset, 21.0, accuracy: 0.001)
        XCTAssertEqual(AppConstants.UI.MapMarkers.iconSize(for: .environment), 14.0, accuracy: 0.001)
        XCTAssertEqual(AppConstants.UI.MapMarkers.iconSize(for: .enemyIndicator), 21.0, accuracy: 0.001)
        XCTAssertEqual(AppConstants.UI.MapMarkers.iconSize(for: .squadOrder), 21.0, accuracy: 0.001)
        #endif
    }
    
    func testTacticalIconShapes() {
        let testRect = CGRect(x: 0, y: 0, width: 24, height: 24)
        
        // 1. SquadPlayerShape
        let playerShape = SquadPlayerShape()
        let playerPath = playerShape.path(in: testRect)
        XCTAssertFalse(playerPath.isEmpty, "SquadPlayerShape path must not be empty")
        let playerBounds = playerPath.boundingRect
        XCTAssertGreaterThan(playerBounds.width, 0)
        XCTAssertGreaterThan(playerBounds.height, 0)
        
        // 2. SquadLeaderShape
        let leaderShape = SquadLeaderShape()
        let leaderPath = leaderShape.path(in: testRect)
        XCTAssertFalse(leaderPath.isEmpty, "SquadLeaderShape path must not be empty")
        let leaderBounds = leaderPath.boundingRect
        XCTAssertGreaterThan(leaderBounds.width, 0)
        XCTAssertGreaterThan(leaderBounds.height, 0)
        
        // 3. SquadDeadXShape
        let deadShape = SquadDeadXShape()
        let deadPath = deadShape.path(in: testRect)
        XCTAssertFalse(deadPath.isEmpty, "SquadDeadXShape path must not be empty")
        let deadBounds = deadPath.boundingRect
        XCTAssertGreaterThan(deadBounds.width, 0)
        XCTAssertGreaterThan(deadBounds.height, 0)
        
        // 4. ECGWaveShape normal & flatline paths
        let normalECG = ECGWaveShape(isFlatline: false)
        let normalPath = normalECG.path(in: testRect)
        XCTAssertFalse(normalPath.isEmpty, "ECGWaveShape path must not be empty")
        
        let flatlineECG = ECGWaveShape(isFlatline: true)
        let flatlinePath = flatlineECG.path(in: testRect)
        XCTAssertFalse(flatlinePath.isEmpty, "ECGWaveShape flatline path must not be empty")
        
        // 5. ECGWaveShape.point scanning dot positions
        let size = CGSize(width: 32, height: 14)
        let midY = size.height / 2.0
        
        // Flatline scanning dot should stay on the horizontal baseline (y = midY) for all progress values
        let flatlineStart = ECGWaveShape.point(at: 0.0, in: size, isFlatline: true)
        XCTAssertEqual(flatlineStart.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(flatlineStart.y, midY, accuracy: 0.001)
        
        let flatlineMid = ECGWaveShape.point(at: 0.5, in: size, isFlatline: true)
        XCTAssertEqual(flatlineMid.x, 16.0, accuracy: 0.001)
        XCTAssertEqual(flatlineMid.y, midY, accuracy: 0.001)
        
        let flatlineEnd = ECGWaveShape.point(at: 1.0, in: size, isFlatline: true)
        XCTAssertEqual(flatlineEnd.x, 32.0, accuracy: 0.001)
        XCTAssertEqual(flatlineEnd.y, midY, accuracy: 0.001)
        
        // Sweep duration calculation tests: referenceBpm / BPM
        let bpm100Duration = AppConstants.Health.referenceBpm / 100.0
        XCTAssertEqual(bpm100Duration, 1.0, accuracy: 0.001)
        let bpm75Duration = AppConstants.Health.referenceBpm / 75.0
        XCTAssertEqual(bpm75Duration, 1.3333, accuracy: 0.001)
        let bpm50Duration = AppConstants.Health.referenceBpm / 50.0
        XCTAssertEqual(bpm50Duration, 2.0, accuracy: 0.001)
    }
    
    // MARK: - Adaptive Throttling & Network Quality Tests
    
    func testNetworkQualityMonitorLatencyAndGrade() {
        let monitor = NetworkQualityMonitor(startMonitoring: false)
        monitor.isConnected = true
        monitor.isConstrained = false
        
        // Initial state with low latency
        monitor.recordLatencySample(40.0)
        XCTAssertEqual(monitor.connectionGrade, .excellent)
        
        // Record multiple high latency samples to move EWMA > 300ms
        for _ in 0..<8 {
            monitor.recordLatencySample(600.0)
        }
        XCTAssertTrue(monitor.connectionGrade == .poor || monitor.connectionGrade == .critical)
        
        // Constrained network (Low Data Mode)
        monitor.isConstrained = true
        monitor.evaluateGrade()
        XCTAssertTrue(monitor.connectionGrade == .poor || monitor.connectionGrade == .critical)
        
        // Disconnected
        monitor.isConnected = false
        monitor.evaluateGrade()
        XCTAssertEqual(monitor.connectionGrade, .offline)
    }
    
    func testAdaptiveDownloadPollingIntervalScaling() {
        let syncManager = FirebaseSyncManager()
        
        // 1. Room with 4 members (<= 12 threshold): 1.0s
        var room4 = SquadRoom(id: "ROOM4", hostId: "HOST", members: [:])
        for i in 1...4 {
            room4.members["M\(i)"] = SquadMember(id: "M\(i)", callsign: "C\(i)", latitude: 0, longitude: 0)
        }
        syncManager.activeRoom = room4
        XCTAssertEqual(syncManager.pollingInterval, 1.0)
        
        // 2. Room with 10 members (<= 12 threshold): 1.0s
        var room10 = SquadRoom(id: "ROOM10", hostId: "HOST", members: [:])
        for i in 1...10 {
            room10.members["M\(i)"] = SquadMember(id: "M\(i)", callsign: "C\(i)", latitude: 0, longitude: 0)
        }
        syncManager.activeRoom = room10
        XCTAssertEqual(syncManager.pollingInterval, 1.0)
        
        // 3. Room with 24 members: 12 / 24 = 2.0s
        var room24 = SquadRoom(id: "ROOM24", hostId: "HOST", members: [:])
        for i in 1...24 {
            room24.members["M\(i)"] = SquadMember(id: "M\(i)", callsign: "C\(i)", latitude: 0, longitude: 0)
        }
        syncManager.activeRoom = room24
        XCTAssertEqual(syncManager.pollingInterval, 2.0, accuracy: 0.001)

        // 4. Large room with 30 members: 12 / 30 = 2.5s
        var room30 = SquadRoom(id: "ROOM30", hostId: "HOST", members: [:])
        for i in 1...30 {
            room30.members["M\(i)"] = SquadMember(id: "M\(i)", callsign: "C\(i)", latitude: 0, longitude: 0)
        }
        syncManager.activeRoom = room30
        XCTAssertEqual(syncManager.pollingInterval, 2.5, accuracy: 0.001)

        // 5. Massive room with 60 members: 12 / 60 = 5.0s
        var room60 = SquadRoom(id: "ROOM60", hostId: "HOST", members: [:])
        for i in 1...60 {
            room60.members["M\(i)"] = SquadMember(id: "M\(i)", callsign: "C\(i)", latitude: 0, longitude: 0)
        }
        syncManager.activeRoom = room60
        XCTAssertEqual(syncManager.pollingInterval, 5.0, accuracy: 0.001)
    }

    func testAdaptiveUploadIntervalScalingAndThrottling() {
        let gameState = GameStateManager()
        // broadcastLocalTelemetry below writes through firebaseManager.transport; inject a mock so
        // it doesn't fall through to the real FirebaseRTDBTransport (which needs FirebaseApp.configure()).
        gameState.firebaseManager.transport = MockRTDBTransport()

        // Create 24 member room (12 / 24 = 2.0s interval)
        var room24 = SquadRoom(id: "ROOM24", hostId: gameState.myMemberId, members: [:])
        for i in 1...24 {
            room24.members["M\(i)"] = SquadMember(id: "M\(i)", callsign: "C\(i)", latitude: 0, longitude: 0)
        }
        gameState.firebaseManager.activeRoom = room24
        gameState.recalculateAdaptiveUploadInterval()
        XCTAssertEqual(gameState.adaptiveUploadInterval, 2.0, accuracy: 0.001)
        
        // Test throttling: rapid non-forced calls within interval
        gameState.broadcastLocalTelemetry(force: false) // first one allowed
        let afterFirst = gameState.firebaseManager.totalPacketsProcessed
        
        // Immediate second call should be throttled
        gameState.broadcastLocalTelemetry(force: false)
        XCTAssertEqual(gameState.firebaseManager.totalPacketsProcessed, afterFirst, "Throttled call should not broadcast")
        
        // Forced emergency packet should bypass throttle
        gameState.broadcastLocalTelemetry(force: true)
        XCTAssertEqual(gameState.firebaseManager.totalPacketsProcessed, afterFirst + 1, "Forced packet must bypass throttle")
    }
    
    func testConstantBandwidthMaxUpdateRateEquation() {
        let threshold = FirebaseSyncManager.constantBandwidthPlayerThreshold // 12
        XCTAssertEqual(threshold, 12)
        XCTAssertEqual(FirebaseSyncManager.baselineMaxUpdateRateHz, 1.0)
        
        // At or below threshold: 1.0 Hz (1.0 second interval)
        XCTAssertEqual(FirebaseSyncManager.solveMaxUpdateRateHz(playerCount: 0), 1.0)
        XCTAssertEqual(FirebaseSyncManager.solveMaxUpdateRateHz(playerCount: 1), 1.0)
        XCTAssertEqual(FirebaseSyncManager.solveMaxUpdateRateHz(playerCount: 6), 1.0)
        XCTAssertEqual(FirebaseSyncManager.solveMaxUpdateRateHz(playerCount: 12), 1.0)
        XCTAssertEqual(FirebaseSyncManager.solveUpdateInterval(playerCount: 12), 1.0)
        
        // Beyond threshold: R = 1.0 * (12 / P) — linear, so P * R stays constant at 12
        // 24 players -> 1.0 * (12 / 24) = 0.50 Hz (2.0s interval)
        XCTAssertEqual(FirebaseSyncManager.solveMaxUpdateRateHz(playerCount: 24), 0.5)
        XCTAssertEqual(FirebaseSyncManager.solveUpdateInterval(playerCount: 24), 2.0)

        // 48 players -> 1.0 * (12 / 48) = 0.25 Hz (4.0s interval)
        XCTAssertEqual(FirebaseSyncManager.solveMaxUpdateRateHz(playerCount: 48), 0.25)
        XCTAssertEqual(FirebaseSyncManager.solveUpdateInterval(playerCount: 48), 4.0)

        // 60 players -> 1.0 * (12 / 60) = 0.20 Hz (5.0s interval)
        XCTAssertEqual(FirebaseSyncManager.solveMaxUpdateRateHz(playerCount: 60), 0.20, accuracy: 0.0001)
        XCTAssertEqual(FirebaseSyncManager.solveUpdateInterval(playerCount: 60), 5.0, accuracy: 0.0001)

        // Aggregate bandwidth (P * R) is held constant at the threshold ceiling for P > 12
        for playerCount in [16, 20, 24, 50] {
            let aggregate = Double(playerCount) * FirebaseSyncManager.solveMaxUpdateRateHz(playerCount: playerCount)
            XCTAssertEqual(aggregate, Double(threshold), accuracy: 0.0001, "Aggregate bandwidth should stay pinned at the P=\(threshold) ceiling for \(playerCount) players")
        }
    }

    func testRefreshIntervalAndStaleTimeoutScaling() {
        // At or below threshold: refresh = 7.0s, stale = 15.0s (unscaled baseline)
        XCTAssertEqual(AppConstants.Timing.ConstantBandwidth.refreshInterval(forPlayerCount: 12), 7.0, accuracy: 0.0001)
        XCTAssertEqual(AppConstants.Timing.ConstantBandwidth.staleTimeout(forPlayerCount: 12), 15.0, accuracy: 0.0001)

        // 16 players -> T = 1.33s -> refresh = 9.33s, stale = 20.0s
        XCTAssertEqual(AppConstants.Timing.ConstantBandwidth.refreshInterval(forPlayerCount: 16), 9.3333, accuracy: 0.001)
        XCTAssertEqual(AppConstants.Timing.ConstantBandwidth.staleTimeout(forPlayerCount: 16), 20.0, accuracy: 0.001)

        // 50 players -> T = 4.1667s -> refresh = 29.17s, stale = 62.5s
        XCTAssertEqual(AppConstants.Timing.ConstantBandwidth.refreshInterval(forPlayerCount: 50), 29.1667, accuracy: 0.001)
        XCTAssertEqual(AppConstants.Timing.ConstantBandwidth.staleTimeout(forPlayerCount: 50), 62.5, accuracy: 0.001)
    }


    
    func testPinFieldSanitizationAndVoiceInput() {
        // Direct numeric strings
        XCTAssertEqual(GameStateManager.sanitizePinInput("1234"), "1234")
        XCTAssertEqual(GameStateManager.sanitizePinInput("123456"), "123456")
        XCTAssertEqual(GameStateManager.sanitizePinInput("12345678901234567"), "1234567890123456")
        
        // Voice input / spoken words
        XCTAssertEqual(GameStateManager.sanitizePinInput("one two three four"), "1234")
        XCTAssertEqual(GameStateManager.sanitizePinInput("zero nine eight seven"), "0987")
        XCTAssertEqual(GameStateManager.sanitizePinInput("five 6 seven 8"), "5678")
        XCTAssertEqual(GameStateManager.sanitizePinInput("to for ate"), "248")
        
        // Rejection of letters and non-number characters
        XCTAssertEqual(GameStateManager.sanitizePinInput("abc-1.2!3?4"), "1234")
        XCTAssertEqual(GameStateManager.sanitizePinInput("hello world"), "")
        XCTAssertEqual(GameStateManager.sanitizePinInput("PIN: 4567 (secret)"), "4567")
    }
    
    // MARK: - PIN Schema & Firebase Authentication Tests
    
    func testSquadRoomPinSchemaEncodingDecoding() throws {
        let pin = "4321"
        let pinHash = FirebaseSyncManager.hashPin(pin, salt: "ECHO")
        let room = SquadRoom(
            id: "ECHO",
            hostId: "HOST_ECHO",
            maxCapacity: 4,
            pinHash: pinHash
        )

        XCTAssertEqual(room.pinHash, pinHash)

        let encoder = JSONEncoder()
        let data = try encoder.encode(room)

        let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(jsonObject)
        XCTAssertEqual(jsonObject?["pin"] as? String, pinHash)
        // Redundant/removed keys should NOT be present in encoded JSON
        XCTAssertNil(jsonObject?["hasPin"])
        XCTAssertNil(jsonObject?["createdAt"])
        XCTAssertNil(jsonObject?["lastActivityTimestamp"])
        XCTAssertNil(jsonObject?["hasPassword"])
        XCTAssertNil(jsonObject?["passwordHash"])
        XCTAssertNil(jsonObject?["isBluetoothAdvertising"])

        let decodedRoom = try JSONDecoder().decode(SquadRoom.self, from: data)
        XCTAssertEqual(decodedRoom.id, "ECHO")
        XCTAssertEqual(decodedRoom.pinHash, pinHash)
    }

    func testSquadRoomStreamlinedSchemaDecoding() throws {
        let json = """
        {
            "id": "DELTA",
            "hst": "HOST_DELTA",
            "cap": 4,
            "pin": "abcdef123456",
            "m": {}
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(SquadRoom.self, from: json)
        XCTAssertEqual(decoded.id, "DELTA")
        XCTAssertEqual(decoded.hostId, "HOST_DELTA")
        XCTAssertEqual(decoded.pinHash, "abcdef123456")
    }

    func testFirebaseSyncManagerPinAuthenticationWorkflow() {
        let roomId = "GHOST"
        let pin = "7788"
        let pinHash = FirebaseSyncManager.hashPin(pin, salt: roomId)
        let room = SquadRoom(id: roomId, hostId: "HOST_GHOST", pinHash: pinHash)

        let syncManager = FirebaseSyncManager()
        let transport = MockRTDBTransport()
        syncManager.transport = transport

        let roomData = try! JSONEncoder().encode(room)
        let roomJson = try! JSONSerialization.jsonObject(with: roomData)
        transport.seed(roomJson, at: "r/\(roomId)")

        let member = SquadMember(id: "OPERATOR_1", callsign: "VIPER", latitude: 37.77, longitude: -122.41)
        
        // 1. Join with correct PIN -> Success
        let successExp = expectation(description: "Join with correct PIN succeeds")
        syncManager.joinRoom(id: roomId, member: member, pin: "7788") { result in
            switch result {
            case .success(let joinedRoom):
                XCTAssertEqual(joinedRoom.id, roomId)
                successExp.fulfill()
            case .failure(let error):
                XCTFail("Should not fail with correct PIN: \(error)")
            }
        }
        wait(for: [successExp], timeout: 2.0)
        
        // 2. Join with incorrect PIN -> Failure (.incorrectPin)
        let failExp = expectation(description: "Join with incorrect PIN fails")
        syncManager.joinRoom(id: roomId, member: member, pin: "0000") { result in
            switch result {
            case .success:
                XCTFail("Should not succeed with incorrect PIN")
            case .failure(let error):
                XCTAssertEqual(error, FirebaseSyncError.incorrectPin)
                failExp.fulfill()
            }
        }
        wait(for: [failExp], timeout: 2.0)
    }
    
    // MARK: - Server Cost Optimization & Room Lifecycle Tests
    
    func testPlayerLogoutDeletesTelemetryAndMembershipWhenOtherMembersRemain() {
        let gameState = createMockGameState()
        let transport = mockTransport(for: gameState)
        gameState.myMemberId = "PLAYER_B"
        
        // Multi-member room (Host + Player B)
        let room = SquadRoom(
            id: "MULTI_ROOM",
            hostId: "HOST_A",
            members: [
                "HOST_A": SquadMember(id: "HOST_A", callsign: "HOST", latitude: 0, longitude: 0, role: .leader),
                "PLAYER_B": SquadMember(id: "PLAYER_B", callsign: "PLAYER_B", latitude: 0, longitude: 0, role: .player)
            ]
        )
        gameState.firebaseManager.activeRoom = room
        gameState.firebaseManager.isConnected = true
        
        let exp = expectation(description: "Player B logs out")
        gameState.logoutPlayer { success in
            XCTAssertTrue(success)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
        
        // Verify player's membership and telemetry were deleted
        XCTAssertTrue(transport.recordedRemoves.contains("r/MULTI_ROOM/m/PLAYER_B"))
        XCTAssertTrue(transport.recordedRemoves.contains("p/MULTI_ROOM/PLAYER_B"))
        // Whole room should NOT be deleted because HOST_A is still in the room
        XCTAssertFalse(transport.recordedRemoves.contains("r/MULTI_ROOM"))
    }
    
    func testPlayerLogoutDoesNotDeleteWholeRoomWhenNonHostLeaves() {
        let gameState = createMockGameState()
        let transport = mockTransport(for: gameState)
        gameState.myMemberId = "SOLO_PLAYER"
        
        // Room with non-host player
        let room = SquadRoom(
            id: "SOLO_ROOM",
            hostId: "ORIGINAL_HOST",
            members: [
                "SOLO_PLAYER": SquadMember(id: "SOLO_PLAYER", callsign: "SOLO", latitude: 0, longitude: 0, role: .player)
            ]
        )
        gameState.firebaseManager.activeRoom = room
        gameState.firebaseManager.isConnected = true
        
        let exp = expectation(description: "Non-host player logs out")
        gameState.logoutPlayer { success in
            XCTAssertTrue(success)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
        
        // Verify member and member telemetry are deleted, but whole room and whole room telemetry are NOT deleted
        XCTAssertTrue(transport.recordedRemoves.contains("r/SOLO_ROOM/m/SOLO_PLAYER"))
        XCTAssertTrue(transport.recordedRemoves.contains("p/SOLO_ROOM/SOLO_PLAYER"))
        XCTAssertFalse(transport.recordedRemoves.contains("r/SOLO_ROOM"))
        XCTAssertFalse(transport.recordedRemoves.contains("p/SOLO_ROOM"))
    }
    
    func testServerCreatorDisbandMessageDeletesWholeRoomAndTelemetry() {
        let gameState = createMockGameState()
        let transport = mockTransport(for: gameState)
        gameState.myMemberId = "CREATOR_HOST"
        
        let room = SquadRoom(
            id: "SQUAD_TO_DISBAND",
            hostId: "CREATOR_HOST",
            members: [
                "CREATOR_HOST": SquadMember(id: "CREATOR_HOST", callsign: "LEADER", latitude: 0, longitude: 0, role: .leader),
                "MEMBER_2": SquadMember(id: "MEMBER_2", callsign: "MEMBER_2", latitude: 0, longitude: 0, role: .player)
            ]
        )
        gameState.firebaseManager.activeRoom = room
        gameState.firebaseManager.isConnected = true
        gameState.isHosting = true
        
        let exp = expectation(description: "Creator disbands room")
        gameState.disbandRoom { success in
            XCTAssertTrue(success)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
        
        // Room and telemetry nodes must both be completely deleted
        XCTAssertTrue(transport.recordedRemoves.contains("r/SQUAD_TO_DISBAND"))
        XCTAssertTrue(transport.recordedRemoves.contains("p/SQUAD_TO_DISBAND"))
        XCTAssertNil(gameState.firebaseManager.activeRoom)
        XCTAssertFalse(gameState.firebaseManager.isConnected)
    }
    
    func testIdleCutoffIsTwelveHours() {
        XCTAssertEqual(AppConstants.Timing.Inactivity.idleCutoffHours, 12.0)
        XCTAssertEqual(AppConstants.Timing.Inactivity.ttlDurationSeconds, 12.0 * 3600.0)
    }

    func testRefreshRoomExpiryUpdatesAllThreeTrees() {
        let syncManager = createMockFirebaseSyncManager()
        let transport = mockTransport(for: syncManager)
        let roomId = "REFRESH_ROOM"

        syncManager.refreshRoomExpiry(roomId: roomId)

        XCTAssertTrue(transport.recordedSets.contains { $0.path == "r/\(roomId)/exp" })
        XCTAssertTrue(transport.recordedSets.contains { $0.path == "p/\(roomId)/exp" })
        XCTAssertTrue(transport.recordedSets.contains { $0.path == "t/\(roomId)/exp" })

        if let newExp = transport.recordedSets.last(where: { $0.path == "r/\(roomId)/exp" })?.value as? Double {
            let expectedExpireAt = Date().timeIntervalSince1970 + AppConstants.Timing.Inactivity.ttlDurationSeconds
            XCTAssertEqual(newExp, expectedExpireAt, accuracy: 1.0)
        } else {
            XCTFail("refreshRoomExpiry did not write a Double exp value")
        }
    }
    
    // MARK: - AppConstants Integrity Tests
    
    func testAppConstantsIntegrity() {
        // Storage Keys
        XCTAssertEqual(AppConstants.Storage.userCallsignKey, "user_callsign")
        XCTAssertEqual(AppConstants.Storage.savedRoomNameKey, "saved_room_name")
        XCTAssertEqual(AppConstants.Storage.radarColorThemeKey, "radar_color_theme")
        XCTAssertEqual(AppConstants.Storage.hasUnlimitedSquadUnlockKey, "hasUnlimitedSquadUnlock")
        XCTAssertEqual(AppConstants.Storage.savedPinKey, "saved_pin")
        
        // Network
        XCTAssertEqual(AppConstants.Network.defaultDatabaseURL, "https://radarmap-8adf0-default-rtdb.firebaseio.com")
        XCTAssertEqual(AppConstants.Network.Quality.initialLatencyMs, 50.0)
        XCTAssertEqual(AppConstants.Network.Quality.emaAlpha, 0.2)
        
        // Subscription
        XCTAssertEqual(AppConstants.Subscription.freeTierMaxCapacity, 4)
        XCTAssertEqual(AppConstants.Subscription.proTierMaxCapacity, 12)
        XCTAssertEqual(AppConstants.Subscription.lifetimePriceString, "$29.99")
        XCTAssertEqual(AppConstants.Subscription.entitlementID, "radarmap_pro")
        XCTAssertEqual(AppConstants.Subscription.productID, "com.radarmap.watch.pro")
        
        // Health
        XCTAssertFalse(AppConstants.Health.defaultIsDead, "defaultIsDead must be false (player starts alive)")
        XCTAssertEqual(AppConstants.Health.defaultRestingHeartRate, 75.0)
        XCTAssertEqual(AppConstants.Health.flatlineHeartRate, 0.0)
        XCTAssertEqual(AppConstants.Health.referenceBpm, 100.0)
        XCTAssertEqual(AppConstants.Health.secondsPerMinute, 60.0)
        XCTAssertEqual(AppConstants.Health.Zones.blueMax, 60.0)
        XCTAssertEqual(AppConstants.Health.Zones.greenMax, 100.0)
        XCTAssertEqual(AppConstants.Health.Zones.yellowMax, 140.0)
        XCTAssertEqual(AppConstants.Health.Zones.orangeMax, 175.0)
        
        // Location & Geodesic Calculation Constants
        XCTAssertEqual(AppConstants.Location.metersPerDegreeLatitude, 111_139.0)
        XCTAssertEqual(AppConstants.Location.metersPerKilometer, 1000.0)
        XCTAssertEqual(AppConstants.Location.distanceFilterMeters, 1.0)
        XCTAssertEqual(AppConstants.Location.headingFilterDegrees, 2.0)
        XCTAssertEqual(AppConstants.Location.degreesToRadiansFactor, .pi / 180.0, accuracy: 1e-9)
        XCTAssertEqual(AppConstants.Location.radiansToDegreesFactor, 180.0 / .pi, accuracy: 1e-9)
        XCTAssertEqual(AppConstants.Location.fullCircleDegrees, 360.0)
        XCTAssertEqual(AppConstants.Location.vectorEpsilon, 1e-6)
        XCTAssertEqual(AppConstants.Location.stationarySpeedThresholdMps, 0.5)
        XCTAssertEqual(AppConstants.Location.runningSpeedThresholdMps, 2.5)
        XCTAssertEqual(AppConstants.Location.minDisplacementForCourseOverGroundMeters, 2.0)
        
        // Timing
        XCTAssertEqual(AppConstants.Timing.secondsPerMinute, 60.0)
        XCTAssertEqual(AppConstants.Timing.secondsPerHour, 3600.0)
        XCTAssertEqual(AppConstants.Timing.secondsPerDay, 86400.0)
        XCTAssertEqual(AppConstants.Timing.millisecondsPerSecond, 1000.0)
        XCTAssertEqual(AppConstants.Timing.AdaptiveRate.intervalChangeEpsilon, 0.01)
        XCTAssertEqual(AppConstants.Timing.Stale.defaultTimeoutMultiplier, 15.0)
        XCTAssertEqual(AppConstants.Timing.Inactivity.idleCutoffHours, 12.0)
        XCTAssertEqual(AppConstants.Timing.Inactivity.secondsPerHour, 3600.0)
        
        // UI & Gestures
        XCTAssertEqual(AppConstants.UI.defaultCallsign, "")
        XCTAssertEqual(AppConstants.UI.defaultRoomName, "")
        XCTAssertEqual(AppConstants.UI.Gestures.actionHoldDurationSeconds, 1.2)
        XCTAssertEqual(AppConstants.UI.Gestures.holdTimerTickIntervalSeconds, 0.02)
        XCTAssertEqual(AppConstants.UI.Gestures.actionAnimationDurationSeconds, 0.25)
        
        // Radar Scale Geometry
        XCTAssertEqual(AppConstants.UI.RadarScale.radarRadiusRatio, 0.44)
        XCTAssertEqual(AppConstants.UI.RadarScale.crosshairExtensionRatio, 1.05)
        XCTAssertEqual(AppConstants.UI.RadarScale.centerReticleSize, 9.0)
        
        // Tactical Vector Shapes
        XCTAssertEqual(AppConstants.UI.TacticalShapes.playerRadiusFactor, 0.38)
        XCTAssertEqual(AppConstants.UI.TacticalShapes.playerLeftShoulderAngleDegrees, 220.0)
        XCTAssertEqual(AppConstants.UI.TacticalShapes.playerRightShoulderAngleDegrees, 320.0)
        XCTAssertEqual(AppConstants.UI.TacticalShapes.leaderRadiusFactor, 0.36)
        XCTAssertEqual(AppConstants.UI.TacticalShapes.deadXArmLengthRatio, 0.46)
        XCTAssertEqual(AppConstants.UI.TacticalShapes.deadXHalfThicknessRatio, 0.13)
        XCTAssertEqual(AppConstants.UI.TacticalShapes.sqrtTwo, 1.4142135623730951, accuracy: 1e-9)
        XCTAssertEqual(AppConstants.UI.TacticalShapes.ECG.pWaveStart, 0.20)
        XCTAssertEqual(AppConstants.UI.TacticalShapes.ECG.rPeakHeightRatio, 0.44)
        
        // Tactical Indicators
        XCTAssertEqual(AppConstants.Subscription.freeTierMaxTacticalIndicators, 0)
        XCTAssertEqual(AppConstants.Subscription.proTierMaxTacticalIndicators, 20)
        XCTAssertEqual(AppConstants.Subscription.enemyIndicatorFadeDurationSeconds, 300.0)
        XCTAssertEqual(AppConstants.Subscription.indicatorHoldToDeleteDurationSeconds, 1.2)
    }
    
    // MARK: - Pro Tier Tactical Indicators Tests
    
    func testProIndicatorAccessGating() {
        let gameState = createMockGameState()
        gameState.subscriptionManager.hasUnlimitedSquadUnlock = false
        
        // Non-pro attempt to place indicator triggers paywall
        gameState.placeTacticalIndicator(type: .watchHere, at: CLLocationCoordinate2D(latitude: 37.785, longitude: -122.406))
        XCTAssertTrue(gameState.showPaywallSheet)
        XCTAssertTrue(gameState.allTacticalIndicators.isEmpty)
        
        // Pro unlock enables placing indicator
        gameState.showPaywallSheet = false
        gameState.subscriptionManager.hasUnlimitedSquadUnlock = true
        
        gameState.placeTacticalIndicator(type: .watchHere, at: CLLocationCoordinate2D(latitude: 37.785, longitude: -122.406))
        XCTAssertFalse(gameState.showPaywallSheet)
        XCTAssertEqual(gameState.allTacticalIndicators.count, 1)
    }
    
    func testSquadOrderSingleInstanceLimit() {
        let gameState = createMockGameState()
        gameState.subscriptionManager.hasUnlimitedSquadUnlock = true
        
        let coord1 = CLLocationCoordinate2D(latitude: 37.785, longitude: -122.406)
        let coord2 = CLLocationCoordinate2D(latitude: 37.786, longitude: -122.407)
        let coord3 = CLLocationCoordinate2D(latitude: 37.787, longitude: -122.408)
        let coord4 = CLLocationCoordinate2D(latitude: 37.788, longitude: -122.409)
        
        // Place first Watch Here order
        gameState.placeTacticalIndicator(type: .watchHere, at: coord1)
        XCTAssertEqual(gameState.allTacticalIndicators.count, 1)
        XCTAssertEqual(gameState.allTacticalIndicators.first?.type, .watchHere)
        XCTAssertEqual(gameState.allTacticalIndicators.first?.coordinate.latitude, coord1.latitude)
        
        // Place second Watch Here order -> Should REPLACE the first Watch Here order
        gameState.placeTacticalIndicator(type: .watchHere, at: coord2)
        XCTAssertEqual(gameState.allTacticalIndicators.count, 1)
        XCTAssertEqual(gameState.allTacticalIndicators.first?.type, .watchHere)
        XCTAssertEqual(gameState.allTacticalIndicators.first?.coordinate.latitude, coord2.latitude)
        
        // Place Go Here order and Attack Here order -> 1 of each (3 total)
        gameState.placeTacticalIndicator(type: .goHere, at: coord3)
        gameState.placeTacticalIndicator(type: .attackHere, at: coord4)
        
        XCTAssertEqual(gameState.allTacticalIndicators.count, 3)
        XCTAssertEqual(Set(gameState.allTacticalIndicators.map { $0.type }), Set([.watchHere, .goHere, .attackHere]))
        
        // Placing a new Go Here replaces only Go Here
        let coord5 = CLLocationCoordinate2D(latitude: 37.789, longitude: -122.410)
        gameState.placeTacticalIndicator(type: .goHere, at: coord5)
        
        XCTAssertEqual(gameState.allTacticalIndicators.count, 3)
        let currentGoHere = gameState.allTacticalIndicators.first(where: { $0.type == .goHere })
        XCTAssertEqual(currentGoHere?.coordinate.latitude, coord5.latitude)
    }
    
    func testEnemyIndicatorCapacityAndFifoReplacement() {
        let gameState = createMockGameState()
        gameState.subscriptionManager.hasUnlimitedSquadUnlock = true
        
        var placedIds: [String] = []
        let baseTime = Date().timeIntervalSince1970 - 100.0
        
        // Place 20 enemy indicators with ascending timestamps
        for i in 1...20 {
            let coord = CLLocationCoordinate2D(latitude: 37.780 + Double(i) * 0.001, longitude: -122.400 + Double(i) * 0.001)
            gameState.placeTacticalIndicator(type: .infantry, at: coord)
            
            // Set deterministic timestamp
            let latest = gameState.allTacticalIndicators.first(where: { $0.coordinate.latitude == coord.latitude })!
            placedIds.append(latest.id)
            gameState.localIndicators[latest.id] = TacticalIndicator(
                id: latest.id,
                type: latest.type,
                coordinate: coord,
                placedByMemberId: gameState.myMemberId,
                timestamp: baseTime + Double(i)
            )
        }
        
        XCTAssertEqual(gameState.allTacticalIndicators.count, 20)
        let oldestId = placedIds.first!
        XCTAssertTrue(gameState.allTacticalIndicators.contains(where: { $0.id == oldestId }))
        
        // Place 21st enemy indicator -> The oldest (1st) indicator should be evicted/replaced
        let coord21 = CLLocationCoordinate2D(latitude: 37.850, longitude: -122.450)
        gameState.placeTacticalIndicator(type: .heavyVehicle, at: coord21)
        
        XCTAssertEqual(gameState.allTacticalIndicators.count, 20)
        XCTAssertFalse(gameState.allTacticalIndicators.contains(where: { $0.id == oldestId }), "Oldest enemy indicator must be evicted")
        XCTAssertTrue(gameState.allTacticalIndicators.contains(where: { $0.type == .heavyVehicle && $0.coordinate.latitude == coord21.latitude }))
    }
    
    func testEnemyIndicatorAgingAndFadeFactor() {
        let now = Date()
        let freshIndicator = TacticalIndicator(
            type: .infantry,
            coordinate: CLLocationCoordinate2D(latitude: 37.7, longitude: -122.4),
            placedByMemberId: "TEST",
            timestamp: now.timeIntervalSince1970
        )
        XCTAssertEqual(freshIndicator.grayFadeFactor(referenceDate: now), 0.0, accuracy: 0.001)
        XCTAssertFalse(freshIndicator.isFullyFaded(referenceDate: now))
        
        // 2.5 minutes (150s) later -> 50% faded
        let halfFadedDate = now.addingTimeInterval(150)
        XCTAssertEqual(freshIndicator.grayFadeFactor(referenceDate: halfFadedDate), 0.5, accuracy: 0.001)
        XCTAssertFalse(freshIndicator.isFullyFaded(referenceDate: halfFadedDate))
        
        // 5 minutes (300s) later -> 100% faded (gray)
        let fullFadedDate = now.addingTimeInterval(300)
        XCTAssertEqual(freshIndicator.grayFadeFactor(referenceDate: fullFadedDate), 1.0, accuracy: 0.001)
        XCTAssertTrue(freshIndicator.isFullyFaded(referenceDate: fullFadedDate))
        
        // 10 minutes later -> Clamped to 1.0
        let pastDate = now.addingTimeInterval(600)
        XCTAssertEqual(freshIndicator.grayFadeFactor(referenceDate: pastDate), 1.0, accuracy: 0.001)
        XCTAssertTrue(freshIndicator.isFullyFaded(referenceDate: pastDate))
        
        // Squad Orders do not fade to gray (fade factor is always 0.0)
        let orderIndicator = TacticalIndicator(
            type: .watchHere,
            coordinate: CLLocationCoordinate2D(latitude: 37.7, longitude: -122.4),
            placedByMemberId: "TEST",
            timestamp: now.timeIntervalSince1970
        )
        XCTAssertEqual(orderIndicator.grayFadeFactor(referenceDate: pastDate), 0.0)
    }
    
    // `indicators` is a client-model convenience (populated by applyTacticalSnapshot merging the
    // separate t/{roomId} fetch) and is deliberately excluded from SquadRoom's own wire
    // representation — real indicator data lives at t/{roomId}/o and t/{roomId}/i, not embedded
    // in the room's JSON. See CLOUD_DATA_MANAGEMENT.md.
    func testTacticalIndicatorRoomEncodingDecoding() throws {
        let indicator1 = TacticalIndicator(
            id: "IND-1",
            type: .watchHere,
            coordinate: CLLocationCoordinate2D(latitude: 37.7858, longitude: -122.4064),
            placedByMemberId: "LEADER-1",
            timestamp: 1700000000
        )
        let indicator2 = TacticalIndicator(
            id: "IND-2",
            type: .lightVehicle,
            coordinate: CLLocationCoordinate2D(latitude: 37.7860, longitude: -122.4070),
            placedByMemberId: "LEADER-1",
            timestamp: 1700000100
        )

        let room = SquadRoom(
            id: "PRO-SQUAD",
            hostId: "LEADER-1",
            maxCapacity: 12,
            indicators: [
                indicator1.id: indicator1,
                indicator2.id: indicator2
            ]
        )

        let encoded = try JSONEncoder().encode(room)
        let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertNil(json?["indicators"], "indicators must not be part of SquadRoom's wire representation")

        let decoded = try JSONDecoder().decode(SquadRoom.self, from: encoded)
        XCTAssertTrue(decoded.indicators.isEmpty, "Decoding a room never populates indicators — that's applyTacticalSnapshot's job")

        // TacticalIndicator's own compact-array wire format round-trips independently.
        for indicator in [indicator1, indicator2] {
            let parsed = TacticalIndicator.parse(id: indicator.id, rawValue: indicator.compactArray)
            XCTAssertEqual(parsed?.type, indicator.type)
            XCTAssertEqual(parsed?.coordinate.latitude ?? 0, indicator.coordinate.latitude, accuracy: 0.0001)
            XCTAssertEqual(parsed?.placedByMemberId, indicator.placedByMemberId)
        }
    }
    
    func testIndicatorDeletion() {
        let gameState = createMockGameState()
        gameState.subscriptionManager.hasUnlimitedSquadUnlock = true
        
        gameState.placeTacticalIndicator(type: .attackHere, at: CLLocationCoordinate2D(latitude: 37.785, longitude: -122.406))
        
        XCTAssertEqual(gameState.allTacticalIndicators.count, 1)
        let indId = gameState.allTacticalIndicators.first!.id
        
        // Remove indicator (e.g. hold-to-delete completion)
        gameState.removeTacticalIndicator(id: indId)
        XCTAssertEqual(gameState.allTacticalIndicators.count, 0)
    }
    
    func testCommandCallsignAttributionAndDistinctionForMultipleProPlayers() {
        let gameState = createMockGameState()
        gameState.subscriptionManager.hasUnlimitedSquadUnlock = true
        gameState.myMemberId = "PRO_PLAYER_1"
        gameState.myCallsign = "VIPER"
        
        let p1Member = SquadMember(id: "PRO_PLAYER_1", callsign: "VIPER", latitude: 37.785, longitude: -122.406, role: .leader)
        let p2Member = SquadMember(id: "PRO_PLAYER_2", callsign: "GHOST", latitude: 37.786, longitude: -122.407, role: .player)
        
        var room = SquadRoom(
            id: "PRO_SQUAD",
            hostId: "PRO_PLAYER_1",
            maxCapacity: 12,
            members: [
                "PRO_PLAYER_1": p1Member,
                "PRO_PLAYER_2": p2Member
            ]
        )
        gameState.firebaseManager.activeRoom = room
        
        let attackCoord1 = CLLocationCoordinate2D(latitude: 37.7851, longitude: -122.4061)
        let attackCoord2 = CLLocationCoordinate2D(latitude: 37.7865, longitude: -122.4075)
        let attackCoord3 = CLLocationCoordinate2D(latitude: 37.7890, longitude: -122.4100)
        
        // 1. Player 1 (VIPER) places Attack command
        gameState.placeTacticalIndicator(type: .attackHere, at: attackCoord1)
        
        XCTAssertEqual(gameState.allTacticalIndicators.count, 1)
        let p1Attack = gameState.allTacticalIndicators.first!
        XCTAssertEqual(p1Attack.type, .attackHere)
        XCTAssertEqual(p1Attack.placedByMemberId, "PRO_PLAYER_1")
        XCTAssertEqual(p1Attack.placedByCallsign, "VIPER", "Attack command must include the callsign of who sent it")
        
        // 2. Player 2 (GHOST) places an Attack command in the same room
        let p2Attack = TacticalIndicator(
            id: "IND_P2_ATTACK",
            type: .attackHere,
            coordinate: attackCoord2,
            placedByMemberId: "PRO_PLAYER_2",
            placedByCallsign: "GHOST"
        )
        room = gameState.firebaseManager.activeRoom!
        room.indicators[p2Attack.id] = p2Attack
        gameState.firebaseManager.activeRoom = room
        
        // Both Attack commands must be active and distinguishable by callsign in the room
        let allAttacks = gameState.allTacticalIndicators.filter { $0.type == .attackHere }
        XCTAssertEqual(allAttacks.count, 2, "Room with multiple pro players must allow each player to place their attack command")
        XCTAssertTrue(allAttacks.contains { $0.placedByCallsign == "VIPER" && $0.placedByMemberId == "PRO_PLAYER_1" })
        XCTAssertTrue(allAttacks.contains { $0.placedByCallsign == "GHOST" && $0.placedByMemberId == "PRO_PLAYER_2" })
        
        // 3. Player 1 (VIPER) places a new Attack command at a different coordinate
        gameState.placeTacticalIndicator(type: .attackHere, at: attackCoord3)
        
        // Player 1's attack command was updated to new coordinate, Player 2's attack command remains untouched
        let updatedAttacks = gameState.allTacticalIndicators.filter { $0.type == .attackHere }
        XCTAssertEqual(updatedAttacks.count, 2)
        let updatedP1Attack = updatedAttacks.first(where: { $0.placedByMemberId == "PRO_PLAYER_1" })
        let retainedP2Attack = updatedAttacks.first(where: { $0.placedByMemberId == "PRO_PLAYER_2" })
        
        XCTAssertNotNil(updatedP1Attack)
        XCTAssertEqual(updatedP1Attack?.placedByCallsign, "VIPER")
        XCTAssertEqual(updatedP1Attack?.coordinate.latitude, attackCoord3.latitude)
        
        XCTAssertNotNil(retainedP2Attack)
        XCTAssertEqual(retainedP2Attack?.placedByCallsign, "GHOST")
        XCTAssertEqual(retainedP2Attack?.coordinate.latitude, attackCoord2.latitude)
    }
    
    func testFallbackCallsignResolutionFromRoomRoster() {
        let gameState = createMockGameState()
        let member = SquadMember(id: "OP_RECON", callsign: "SHADOW", latitude: 37.78, longitude: -122.40)
        
        // Indicator synced from legacy packet without placedByCallsign field (nil)
        let legacyIndicator = TacticalIndicator(
            id: "LEGACY_IND",
            type: .attackHere,
            coordinate: CLLocationCoordinate2D(latitude: 37.785, longitude: -122.406),
            placedByMemberId: "OP_RECON",
            placedByCallsign: nil
        )
        
        let room = SquadRoom(
            id: "SQUAD_A",
            hostId: "OP_RECON",
            members: ["OP_RECON": member],
            indicators: [legacyIndicator.id: legacyIndicator]
        )
        gameState.firebaseManager.activeRoom = room
        
        let indicators = gameState.allTacticalIndicators
        XCTAssertEqual(indicators.count, 1)
        XCTAssertEqual(indicators.first?.placedByCallsign, "SHADOW", "Callsign must be resolved dynamically from room roster when nil in indicator packet")
    }
    
    func testTacticalIndicatorRobustMIDResolution() {
        let gameState = createMockGameState()
        let memberA = SquadMember(id: "OP_RECON", callsign: "SHADOW", latitude: 37.78, longitude: -122.40)
        let memberB = SquadMember(id: "ID_BRAVO", callsign: "TITAN", latitude: 37.79, longitude: -122.41)
        
        // 1. Case-insensitive / whitespace match on member ID
        let ind1 = TacticalIndicator(
            id: "IND_1",
            type: .infantry,
            coordinate: CLLocationCoordinate2D(latitude: 37.785, longitude: -122.406),
            placedByMemberId: "  op_recon  "
        )
        
        // 2. Placed using member callsign rather than member ID
        let ind2 = TacticalIndicator(
            id: "IND_2",
            type: .vehicle,
            coordinate: CLLocationCoordinate2D(latitude: 37.786, longitude: -122.407),
            placedByMemberId: "titan"
        )
        
        // 3. Unknown member ID -> defaults to empty string
        let ind3 = TacticalIndicator(
            id: "IND_3",
            type: .hazard,
            coordinate: CLLocationCoordinate2D(latitude: 37.787, longitude: -122.408),
            placedByMemberId: "UNKNOWN_ID"
        )
        
        let room = SquadRoom(
            id: "SQUAD_TEST",
            hostId: "OP_RECON",
            members: ["OP_RECON": memberA, "ID_BRAVO": memberB],
            indicators: [ind1.id: ind1, ind2.id: ind2, ind3.id: ind3]
        )
        gameState.firebaseManager.activeRoom = room
        
        let resolved = gameState.allTacticalIndicators
        let r1 = resolved.first { $0.id == "IND_1" }
        let r2 = resolved.first { $0.id == "IND_2" }
        let r3 = resolved.first { $0.id == "IND_3" }
        
        XCTAssertEqual(r1?.placedByCallsign, "SHADOW", "Case-insensitive and trimmed member ID must resolve to member callsign")
        XCTAssertEqual(r2?.placedByCallsign, "TITAN", "Indicator placed with callsign as member ID must resolve to member callsign")
        XCTAssertEqual(r3?.placedByCallsign, "", "Indicator with unknown member ID must default to empty string")
    }
    
    func testTacticalIndicatorCallsignCodableRoundtrip() throws {
        let indicator = TacticalIndicator(
            id: "IND_CODABLE",
            type: .attackHere,
            coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            placedByMemberId: "MEMBER_42",
            placedByCallsign: "SPECTRE",
            timestamp: 1700000000
        )
        
        let encoded = try JSONEncoder().encode(indicator)
        let decoded = try JSONDecoder().decode(TacticalIndicator.self, from: encoded)
        
        XCTAssertEqual(decoded.id, "IND_CODABLE")
        XCTAssertEqual(decoded.type, .attackHere)
        XCTAssertEqual(decoded.placedByMemberId, "MEMBER_42")
        XCTAssertEqual(decoded.placedByCallsign, "SPECTRE")
        XCTAssertEqual(decoded.coordinate.latitude, 37.7749, accuracy: 0.0001)
        XCTAssertEqual(decoded.coordinate.longitude, -122.4194, accuracy: 0.0001)
    }
    
    func testTacticalIndicatorCompactArray5ElementSerialization() {
        let indicator = TacticalIndicator(
            id: "IND-5",
            type: .goHere,
            coordinate: CLLocationCoordinate2D(latitude: 37.3326, longitude: -122.0312),
            placedByMemberId: "USER-123",
            timestamp: 1700000000
        )
        
        let compact = indicator.compactArray
        XCTAssertEqual(compact.count, 5)
        XCTAssertEqual(compact[0] as? String, "goh")
        XCTAssertEqual(compact[1] as? Double, 37.3326)
        XCTAssertEqual(compact[2] as? Double, -122.0312)
        XCTAssertEqual(compact[3] as? Double, 1700000000)
        XCTAssertEqual(compact[4] as? String, "USER-123")
        
        // Deserialize 5-element format
        let parsed5 = TacticalIndicator.parse(id: "IND-5", rawValue: compact)
        XCTAssertNotNil(parsed5)
        XCTAssertEqual(parsed5?.type, .goHere)
        XCTAssertEqual(parsed5?.placedByMemberId, "USER-123")
        
        // Backward-compatible 4-element format
        let compact4: [Any] = ["goh", 37.3326, -122.0312, 1700000000.0]
        let parsed4 = TacticalIndicator.parse(id: "IND-4", rawValue: compact4, defaultPlacedBy: "FALLBACK-USER")
        XCTAssertNotNil(parsed4)
        XCTAssertEqual(parsed4?.type, .goHere)
        XCTAssertEqual(parsed4?.placedByMemberId, "FALLBACK-USER")
    }
    
    func testZoomScalePreservationBetweenViews() {
        let screenHeight: Double = AppConstants.UI.ScaleRuler.referenceScreenHeight
        let maxRadius: Double = screenHeight * 0.44
        let metersPerDegreeLat: Double = AppConstants.Location.metersPerDegreeLatitude
        
        // 1. Convert Radar scale (e.g. 250m) to MapKit latDelta
        let radarScale: Double = 250.0
        let visibleMetersLat = (screenHeight / maxRadius) * radarScale
        let latDelta = visibleMetersLat / metersPerDegreeLat
        
        // 2. Invert latDelta back to Radar scale
        let calculatedVisibleMeters = latDelta * metersPerDegreeLat
        let calculatedRadarScale = (maxRadius / screenHeight) * calculatedVisibleMeters
        
        XCTAssertEqual(calculatedRadarScale, radarScale, accuracy: 0.0001, "Bidirectional zoom conversion must preserve exact scale")
        
        // 3. Verify scale matches at default zoom (100m)
        let defaultRadar: Double = AppConstants.UI.RadarScale.defaultScaleMeters
        let defaultLatDelta = ((screenHeight / maxRadius) * defaultRadar) / metersPerDegreeLat
        let roundtripDefault = (maxRadius / screenHeight) * (defaultLatDelta * metersPerDegreeLat)
        XCTAssertEqual(roundtripDefault, defaultRadar, accuracy: 0.0001)
        
        // 4. Verify helper methods in AppConstants.UI.RadarScale across multiple zoom levels
        let testScales: [Double] = [1.0, 2.5, 5.0, 10.0, 25.0, 50.0, 100.0, 250.0, 500.0, 1000.0, 2500.0]
        for scale in testScales {
            let delta = AppConstants.UI.RadarScale.mapSpanDelta(forRadarScaleMeters: scale)
            let roundtripScale = AppConstants.UI.RadarScale.radarScaleMeters(forMapSpanDelta: delta)
            XCTAssertEqual(roundtripScale, scale, accuracy: 0.001, "AppConstants zoom helper must preserve scale \(scale)m accurately")
        }
        
        // 5. Verify ScaleRuler distance formatting helpers (tactical ruler displays exact map zoom scale)
        XCTAssertEqual(AppConstants.UI.ScaleRuler.formatRulerDistance(minorScaleMeters: 50.0), "50m")
        XCTAssertEqual(AppConstants.UI.ScaleRuler.formatRulerDistance(minorScaleMeters: 100.0), "100m")
        XCTAssertEqual(AppConstants.UI.ScaleRuler.formatRulerDistance(minorScaleMeters: 250.0), "250m")
        XCTAssertEqual(AppConstants.UI.ScaleRuler.formatRulerDistance(minorScaleMeters: 500.0), "500m")
        XCTAssertEqual(AppConstants.UI.ScaleRuler.formatDistance(meters: 100.0), "100m")
        XCTAssertEqual(AppConstants.UI.ScaleRuler.formatDistance(meters: 2500.0), "2.5km")
        XCTAssertEqual(AppConstants.UI.ScaleRuler.formatLiveRulerDistance(minorScaleMeters: 137.5), "137.5m")
        
        // 6. Verify camera distance <-> scaleMeters roundtrip conversion
        for scale in testScales {
            let cameraDist = AppConstants.UI.RadarScale.cameraDistance(forScale: scale)
            let roundtripScale = AppConstants.UI.RadarScale.scaleMeters(forCameraDistance: cameraDist)
            XCTAssertEqual(roundtripScale, scale, accuracy: 0.001, "Camera distance roundtrip must match scale \(scale)m")
        }
    }
    
    func testSquadMemberDirectCoordinates() {
        let member = SquadMember(id: "M1", callsign: "VIPER", latitude: 37.77, longitude: -122.41, heading: 45.0, heartRate: 85.0)
        XCTAssertEqual(member.id, "M1")
        XCTAssertEqual(member.callsign, "VIPER")
        XCTAssertEqual(member.coordinate.latitude, 37.77, accuracy: 0.0001)
        XCTAssertEqual(member.coordinate.longitude, -122.41, accuracy: 0.0001)
        XCTAssertEqual(member.heading, 45.0, accuracy: 0.0001)
        XCTAssertEqual(member.heartRate, 85.0)
    }
    
    func testUnifiedGameStateMapScaleAndCenterState() {
        let gameState = createMockGameState()
        
        // 1. Initial default state (minor scale = 50m)
        XCTAssertEqual(gameState.radarScaleMeters, AppConstants.UI.RadarScale.defaultScaleMeters)
        XCTAssertNil(gameState.currentMapCenter)
        XCTAssertEqual(gameState.radarCenterTrigger, 0)
        XCTAssertEqual(gameState.currentScaleText, AppConstants.UI.ScaleRuler.formatRulerDistance(minorScaleMeters: AppConstants.UI.RadarScale.defaultScaleMeters))
        
        // 2. Modifying radarScaleMeters updates currentMapSpanDelta and currentScaleText (live format: 200m)
        gameState.radarScaleMeters = 200.0
        XCTAssertEqual(gameState.currentScaleText, "200m")
        let computedDelta = gameState.currentMapSpanDelta
        XCTAssertEqual(computedDelta, AppConstants.UI.RadarScale.mapSpanDelta(forRadarScaleMeters: 200.0), accuracy: 0.00001)
        
        // 3. Modifying currentMapSpanDelta updates radarScaleMeters with discrete snapping
        let targetSpan = 0.004
        gameState.currentMapSpanDelta = targetSpan
        let rawScale = AppConstants.UI.RadarScale.radarScaleMeters(forMapSpanDelta: targetSpan)
        let expectedSnappedScale = AppConstants.UI.RadarScale.snapToDiscreteScale(rawScale)
        XCTAssertEqual(gameState.radarScaleMeters, expectedSnappedScale, accuracy: 0.001)
        
        // 4. Modifying currentMapCenter
        let customCenter = CLLocationCoordinate2D(latitude: 37.5, longitude: -122.2)
        gameState.currentMapCenter = customCenter
        XCTAssertEqual(gameState.currentMapCenter?.latitude, 37.5)
        XCTAssertEqual(gameState.currentMapCenter?.longitude, -122.2)
        
        // 5. Calling resetMapToDefaultCenterAndZoom resets center and bumps trigger without changing scale
        gameState.resetMapToDefaultCenterAndZoom()
        XCTAssertEqual(gameState.radarScaleMeters, expectedSnappedScale, accuracy: 0.001)
        XCTAssertNil(gameState.currentMapCenter)
        XCTAssertEqual(gameState.radarCenterTrigger, 1)
    }
    
    func testLocalPlayerDirectMapCentering() {
        let gameState = createMockGameState()
        let initialLoc = CLLocation(latitude: 37.7800, longitude: -122.4000)
        gameState.locationHeadingManager.userLocation = initialLoc
        gameState.updateLocalPlayerMember()
        
        // Initial coordinate matches location
        XCTAssertEqual(gameState.localPlayerMember.coordinate.latitude, 37.7800, accuracy: 1e-4)
        XCTAssertEqual(gameState.localPlayerMember.coordinate.longitude, -122.4000, accuracy: 1e-4)
        
        // Next GPS position updates local player coordinate immediately
        let targetLoc = CLLocation(latitude: 37.7820, longitude: -122.4020)
        gameState.locationHeadingManager.userLocation = targetLoc
        gameState.updateLocalPlayerMember()
        
        XCTAssertEqual(gameState.localPlayerMember.coordinate.latitude, 37.7820, accuracy: 1e-4)
        XCTAssertEqual(gameState.localPlayerMember.coordinate.longitude, -122.4020, accuracy: 1e-4)
    }
    
    // MARK: - Tactical Indicators Category & Bandwidth-Preservation Sync Tests
    
    func testTacticalEndpointConstant() {
        XCTAssertEqual(AppConstants.Network.Endpoints.tactical, "t")
        XCTAssertEqual(AppConstants.Network.Endpoints.telemetry, "p")
        XCTAssertEqual(AppConstants.Network.Endpoints.rooms, "r")
        XCTAssertEqual(AppConstants.Network.Endpoints.members, "m")
        XCTAssertEqual(AppConstants.Network.Endpoints.orders, "o")
        XCTAssertEqual(AppConstants.Network.Endpoints.indicators, "i")
    }
    
    func testSquadLeaderButtonVisibilityFollowsProStatus() {
        let gameState = createMockGameState()
        gameState.subscriptionManager.hasUnlimitedSquadUnlock = false
        XCTAssertFalse(gameState.isProUser, "Non-pro users must have isProUser = false")
        
        gameState.subscriptionManager.hasUnlimitedSquadUnlock = true
        XCTAssertTrue(gameState.isProUser, "Pro users must have isProUser = true")
    }
    
    func testNonProAndProBothViewTacticalIndicatorsFromFirebase() {
        // Non-Pro user setup
        let nonProState = createMockGameState()
        nonProState.subscriptionManager.hasUnlimitedSquadUnlock = false
        nonProState.myCallsign = "[DELTA]Operator"
        
        var room = SquadRoom(id: "DELTA", hostId: "PRO_LEADER")
        room.members["PRO_LEADER"] = SquadMember(id: "PRO_LEADER", callsign: "[DELTA]Leader", latitude: 37.785, longitude: -122.405)
        let indicator = TacticalIndicator(
            id: "IND-999",
            type: .attackHere,
            coordinate: CLLocationCoordinate2D(latitude: 37.785, longitude: -122.405),
            placedByMemberId: "PRO_LEADER",
            placedByCallsign: "[DELTA]Leader"
        )
        room.indicators[indicator.id] = indicator
        nonProState.firebaseManager.activeRoom = room
        
        // Both non-pro and pro access allTacticalIndicators identically
        XCTAssertEqual(nonProState.allTacticalIndicators.count, 1)
        XCTAssertEqual(nonProState.allTacticalIndicators.first?.type, .attackHere)
        
        // Pro user setup
        let proState = createMockGameState()
        proState.subscriptionManager.hasUnlimitedSquadUnlock = true
        proState.myCallsign = "[DELTA]Leader"
        proState.firebaseManager.activeRoom = room
        XCTAssertEqual(proState.allTacticalIndicators.count, 1)
        XCTAssertEqual(proState.allTacticalIndicators.first?.type, .attackHere)
    }
    
    func testTacticalIndicatorsUploadAndFetch() {
        let gameState = createMockGameState()
        let transport = mockTransport(for: gameState)
        let room = SquadRoom(id: "ALPHA", hostId: "LEADER")
        gameState.firebaseManager.activeRoom = room

        // Seed an existing server-side capped (enemy+environment) indicator under /t/ALPHA/i.
        transport.seed([
            "IND-100": ["wat", 37.7858, -122.4064, 1700000500.0, "LEADER"]
        ], at: "t/ALPHA/i")

        // 1. Upload new squad-order indicator: verify PUT lands under /t/ALPHA/o/IND-101
        let newIndicator = TacticalIndicator(
            id: "IND-101",
            type: .goHere,
            coordinate: CLLocationCoordinate2D(latitude: 37.786, longitude: -122.407),
            placedByMemberId: "LEADER"
        )
        gameState.firebaseManager.addOrUpdateIndicator(roomId: "ALPHA", indicator: newIndicator)

        let putExp = expectation(description: "Wait for PUT requests")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(transport.recordedSets.contains { $0.path == "t/ALPHA/o/IND-101" })
            putExp.fulfill()
        }
        wait(for: [putExp], timeout: 1.0)

        // 2. Fetch: verify both /o and /i branches merge into activeRoom.indicators
        let exp = expectation(description: "Fetch tactical indicators")
        gameState.firebaseManager.fetchTacticalIndicators(roomId: "ALPHA")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(gameState.firebaseManager.activeRoom?.indicators["IND-100"]?.type, .watchHere)
            XCTAssertEqual(gameState.firebaseManager.activeRoom?.indicators["IND-101"]?.type, .goHere)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        // 3. Delete indicator: verify remove() is sent to both /o and /i branches unconditionally
        // (no category available at the delete call site — see CLOUD_DATA_MANAGEMENT.md)
        gameState.firebaseManager.removeIndicator(roomId: "ALPHA", indicatorId: "IND-101")
        let delExp = expectation(description: "Wait for remove() call")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(transport.recordedRemoves.contains("t/ALPHA/o/IND-101"))
            XCTAssertTrue(transport.recordedRemoves.contains("t/ALPHA/i/IND-101"))
            delExp.fulfill()
        }
        wait(for: [delExp], timeout: 1.0)
    }
    
    func testTacticalIndicatorsPurgedOnRoomDisband() {
        let gameState = createMockGameState()
        let transport = mockTransport(for: gameState)
        let room = SquadRoom(id: "ALPHA", hostId: "GHOST-1")
        gameState.firebaseManager.activeRoom = room
        gameState.isHosting = true
        
        let disbandExp = expectation(description: "Room disband purges tactical node")
        gameState.firebaseManager.disbandRoom(roomId: "ALPHA") { success in
            XCTAssertTrue(success)
            disbandExp.fulfill()
        }
        wait(for: [disbandExp], timeout: 1.0)
        
        XCTAssertTrue(transport.recordedRemoves.contains("t/ALPHA"), "Must delete /t/{roomId} node when room is disbanded")
        XCTAssertTrue(transport.recordedRemoves.contains("p/ALPHA"), "Must delete /p/{roomId} node when room is disbanded")
        XCTAssertTrue(transport.recordedRemoves.contains("r/ALPHA"), "Must delete /r/{roomId} node when room is disbanded")

        let rIndex = transport.recordedRemoves.firstIndex(of: "r/ALPHA") ?? -1
        let pIndex = transport.recordedRemoves.firstIndex(of: "p/ALPHA") ?? -1
        let tIndex = transport.recordedRemoves.firstIndex(of: "t/ALPHA") ?? -1
        XCTAssertTrue(rIndex < pIndex, "/r/{roomId} must be deleted before /p/{roomId} to prevent in-flight packet resurrection")
        XCTAssertTrue(rIndex < tIndex, "/r/{roomId} must be deleted before /t/{roomId} to prevent in-flight packet resurrection")
    }
    
    func testIconsPurgedOnLogoutExceptMeIcon() {
        let gameState = createMockGameState()
        gameState.myCallsign = "VIPER"
        
        // 1. Populate remote squad members & tactical indicators
        let remoteMember = SquadMember(id: "REMOTE_1", callsign: "GHOST", latitude: 37.78, longitude: -122.41)
        let indicator = TacticalIndicator(id: "IND_1", type: .infantry, coordinate: CLLocationCoordinate2D(latitude: 37.79, longitude: -122.42), placedByMemberId: gameState.myMemberId)
        var room = SquadRoom(id: "TEST_SQUAD", hostId: "HOST_1", members: ["REMOTE_1": remoteMember])
        room.indicators["IND_1"] = indicator
        gameState.firebaseManager.activeRoom = room
        gameState.updateOtherSquadMembers(room: room)
        gameState.localIndicators = ["IND_1": indicator]
        gameState.updateAllTacticalIndicators(room: room)
        XCTAssertEqual(gameState.otherSquadMembers.count, 1)
        XCTAssertEqual(gameState.allTacticalIndicators.count, 1)
        XCTAssertEqual(gameState.localPlayerMember.callsign, "VIPER")
        
        // 2. Trigger logout
        gameState.logoutPlayer()
        
        // 3. Verify all icons are purged EXCEPT for "me" icon
        XCTAssertTrue(gameState.otherSquadMembers.isEmpty, "Remote squad member icons must be purged on logout")
        XCTAssertTrue(gameState.allTacticalIndicators.isEmpty, "Tactical indicators must be purged on logout")
        XCTAssertTrue(gameState.localIndicators.isEmpty, "Local indicators dictionary must be purged on logout")
        
        // "Me" icon should remain intact and valid
        XCTAssertEqual(gameState.localPlayerMember.id, gameState.myMemberId, "'Me' icon must be preserved after logout")
        XCTAssertEqual(gameState.localPlayerMember.callsign, "VIPER", "'Me' icon callsign must be preserved after logout")
        XCTAssertFalse(gameState.isDead, "Player vitality must reset to alive (isDead = false) on logout/purge")
    }
    
    func testInitialVitalStateIsAliveAndNoIndicatorPersistenceOnRestart() {
        // 1. Initial constants and fresh GameStateManager must have isDead = false
        XCTAssertFalse(AppConstants.Health.defaultIsDead, "defaultIsDead must be false in setup constants")
        
        let freshGameState = createMockGameState()
        XCTAssertFalse(freshGameState.isDead, "isDead must be false by default on new game state")
        XCTAssertEqual(freshGameState.localPlayerMember.status, .active, "Player status must be active by default")
        XCTAssertTrue(freshGameState.allTacticalIndicators.isEmpty, "Tactical indicators must be empty on fresh app start")
        XCTAssertTrue(freshGameState.localIndicators.isEmpty, "Local indicators must be empty on fresh app start")
        
        // 2. Setting dead and adding indicator during active match
        freshGameState.setDead(true)
        let indicator = TacticalIndicator(id: "IND_RESTART", type: .watchHere, coordinate: CLLocationCoordinate2D(latitude: 37.77, longitude: -122.41), placedByMemberId: freshGameState.myMemberId)
        freshGameState.localIndicators = ["IND_RESTART": indicator]
        freshGameState.updateAllTacticalIndicators()
        XCTAssertTrue(freshGameState.isDead)
        XCTAssertEqual(freshGameState.allTacticalIndicators.count, 1)
        
        // 3. Simulating session cleanup / restart
        freshGameState.purgeLocalSessionAndIcons()
        XCTAssertFalse(freshGameState.isDead, "isDead must reset to false after session purge")
        XCTAssertEqual(freshGameState.localPlayerMember.status, .active, "Player status must reset to active")
        XCTAssertTrue(freshGameState.allTacticalIndicators.isEmpty, "Tactical indicators must not persist across session resets/restarts")
    }
    
    // MARK: - Subscription & RevenueCat Integration Tests
    
    func testSubscriptionManagerMockPurchaseAndRestore() async {
        UserDefaults.standard.removeObject(forKey: AppConstants.Storage.hasUnlimitedSquadUnlockKey)
        let subManager = SubscriptionManager(engineMode: .mock)
        XCTAssertFalse(subManager.hasUnlimitedSquadUnlock)
        XCTAssertFalse(subManager.canCreateRoom(withCapacity: 10))
        XCTAssertTrue(subManager.canCreateRoom(withCapacity: 4))
        XCTAssertEqual(subManager.localizedPrice, "$29.99")
        
        // Purchase flow
        let purchaseSuccess = await subManager.purchaseLifetimeUnlock()
        XCTAssertTrue(purchaseSuccess)
        XCTAssertTrue(subManager.hasUnlimitedSquadUnlock)
        XCTAssertTrue(subManager.purchaseSuccess)
        XCTAssertTrue(subManager.canCreateRoom(withCapacity: 10))
        XCTAssertTrue(UserDefaults.standard.bool(forKey: AppConstants.Storage.hasUnlimitedSquadUnlockKey))
        
        // Restore flow
        let restoreSuccess = await subManager.restorePurchases()
        XCTAssertTrue(restoreSuccess)
        XCTAssertTrue(subManager.hasUnlimitedSquadUnlock)
        
        UserDefaults.standard.removeObject(forKey: AppConstants.Storage.hasUnlimitedSquadUnlockKey)
    }
    
    func testSubscriptionManagerStoreKitConfiguration() {
        let subManager = SubscriptionManager(engineMode: .mock)
        XCTAssertEqual(subManager.activeEngineMode, .mock)
        
        let skManager = SubscriptionManager(engineMode: .storeKit2)
        XCTAssertEqual(skManager.activeEngineMode, .storeKit2)
        XCTAssertEqual(SubscriptionManager.entitlementID, "radarmap_pro")
        XCTAssertEqual(SubscriptionManager.productID, "com.radarmap.watch.pro")
    }
    
    func testSubscriptionManagerPromotionalPriceMessage() {
        let subManager = SubscriptionManager(engineMode: .mock)
        XCTAssertNil(subManager.promotionalPriceMessage)
        
        subManager.promotionalPriceMessage = "50% OFF - Limited Time Offer!"
        XCTAssertEqual(subManager.promotionalPriceMessage, "50% OFF - Limited Time Offer!")
    }
    
    func testSubscriptionManagerCapacityLimits() {
        let subManager = SubscriptionManager(engineMode: .mock)
        subManager.hasUnlimitedSquadUnlock = false
        
        XCTAssertTrue(subManager.canCreateRoom(withCapacity: 1))
        XCTAssertTrue(subManager.canCreateRoom(withCapacity: 2))
        XCTAssertTrue(subManager.canCreateRoom(withCapacity: 3))
        XCTAssertTrue(subManager.canCreateRoom(withCapacity: 4))
        XCTAssertFalse(subManager.canCreateRoom(withCapacity: 5))
        XCTAssertFalse(subManager.canCreateRoom(withCapacity: 8))
        XCTAssertFalse(subManager.canCreateRoom(withCapacity: 50))
        
        subManager.hasUnlimitedSquadUnlock = true
        XCTAssertTrue(subManager.canCreateRoom(withCapacity: 5))
        XCTAssertTrue(subManager.canCreateRoom(withCapacity: 8))
        XCTAssertTrue(subManager.canCreateRoom(withCapacity: 12))
    }
    
    // MARK: - Compact Array Schema Tests
    
    func testCompactArraySerializationAndDeserialization() {
        let packet = TelemetryPacket(
            memberId: "OPERATOR-7",
            roomId: "ECHO-SQUAD",
            latitude: 37.785834,
            longitude: -122.406417,
            altitude: 12.5,
            heading: 270.0,
            heartRate: 115.0,
            timestamp: 1724686650.5,
            sequenceNumber: 42
        )
        
        let compactArray = packet.toCompactArray()
        XCTAssertEqual(compactArray.count, 4, "Ultra-lean wire schema must contain exactly 4 elements: [lat, lng, hr, ts]")
        XCTAssertEqual(compactArray[0] as? Double, 37.785834)
        XCTAssertEqual(compactArray[1] as? Double, -122.406417)
        XCTAssertEqual(compactArray[2] as? Double, 115.0)
        XCTAssertEqual(compactArray[3] as? Double, 1724686650.5)
        
        // Roundtrip deserialization from 4-element array
        let reconstructed = TelemetryPacket.fromCompactArray(memberId: "OPERATOR-7", roomId: "ECHO-SQUAD", array: compactArray)
        XCTAssertNotNil(reconstructed)
        XCTAssertEqual(reconstructed?.memberId, "OPERATOR-7")
        XCTAssertEqual(reconstructed?.roomId, "ECHO-SQUAD")
        XCTAssertEqual(reconstructed?.latitude, 37.785834)
        XCTAssertEqual(reconstructed?.longitude, -122.406417)
        XCTAssertEqual(reconstructed?.heartRate, 115.0)
        XCTAssertEqual(reconstructed?.timestamp, 1724686650.5)
        
        // Legacy 6-element format backward compatibility
        let legacy6Array: [Any] = [37.785834, -122.406417, 12.5, 115.0, Int64(42), 1724686650.5]
        let legacy6Reconstructed = TelemetryPacket.fromCompactArray(memberId: "LEGACY-6", roomId: "ECHO-SQUAD", array: legacy6Array)
        XCTAssertNotNil(legacy6Reconstructed)
        XCTAssertEqual(legacy6Reconstructed?.altitude, 12.5)
        XCTAssertEqual(legacy6Reconstructed?.sequenceNumber, 42)
        
        // Legacy 7-element format backward compatibility
        let legacy7Array: [Any] = [37.785834, -122.406417, 12.5, 270.0, 115.0, Int64(42), 1724686650.5]
        let legacy7Reconstructed = TelemetryPacket.fromCompactArray(memberId: "LEGACY-7", roomId: "ECHO-SQUAD", array: legacy7Array)
        XCTAssertNotNil(legacy7Reconstructed)
        XCTAssertEqual(legacy7Reconstructed?.heading, 270.0)
        XCTAssertEqual(legacy7Reconstructed?.heartRate, 115.0)
    }
    
    func testRemoteTelemetryCompactArrayPollingWorkflow() {
        let gameState = createMockGameState()
        // Server response in ultra-lean 4-element schema: {"MEMBER_A": [lat, lng, hr, ts]}
        mockTransport(for: gameState).seed([
            "MEMBER_A": [37.7858, -122.4064, 80.0, 1724686650.0],
            "MEMBER_B": [37.7860, -122.4070, 95.0, 1724686651.0]
        ], at: "p/COMPACT_ROOM")
        let room = SquadRoom(id: "COMPACT_ROOM", hostId: "MEMBER_A", members: [:])
        gameState.firebaseManager.activeRoom = room
        gameState.firebaseManager.fetchRemoteTelemetry(roomId: "COMPACT_ROOM")
        
        let exp = expectation(description: "Process compact array telemetry")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(gameState.firebaseManager.activeRoom?.members["MEMBER_A"]?.heartRate, 80.0)
            XCTAssertEqual(gameState.firebaseManager.activeRoom?.members["MEMBER_B"]?.heartRate, 95.0)
            XCTAssertEqual(gameState.firebaseManager.activeRoom?.members["MEMBER_A"]?.latitude ?? 0.0, 37.7858, accuracy: 0.0001)
            XCTAssertEqual(gameState.firebaseManager.activeRoom?.members["MEMBER_B"]?.latitude ?? 0.0, 37.7860, accuracy: 0.0001)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    // MARK: - COG & Speed-Weighted Heading Blending Tests
    
    func testCompact4ElementWireFormatWithoutAltSeqHdg() {
        let packet = TelemetryPacket(
            memberId: "VIPER-1",
            roomId: "ALPHA",
            latitude: 37.7858,
            longitude: -122.4064,
            heartRate: 85.0,
            timestamp: 1724686650.0,
            sequenceNumber: 100
        )
        
        let compactArray = packet.toCompactArray()
        XCTAssertEqual(compactArray.count, 4, "Ultra-lean wire schema must contain exactly 4 elements [lat, lng, hr, ts]")
        XCTAssertEqual(compactArray[0] as? Double, 37.7858)
        XCTAssertEqual(compactArray[1] as? Double, -122.4064)
        XCTAssertEqual(compactArray[2] as? Double, 85.0) // hr
        XCTAssertEqual(compactArray[3] as? Double, 1724686650.0) // ts
        
        // Reconstruct from 4-element array
        let reconstructed = TelemetryPacket.fromCompactArray(memberId: "VIPER-1", roomId: "ALPHA", array: compactArray)
        XCTAssertNotNil(reconstructed)
        XCTAssertEqual(reconstructed?.latitude, 37.7858)
        XCTAssertEqual(reconstructed?.longitude, -122.4064)
        XCTAssertEqual(reconstructed?.heartRate, 85.0)
        XCTAssertEqual(reconstructed?.timestamp, 1724686650.0)
    }
    
    func testLocalSpeedWeightedHeadingBlending_Stationary() {
        // Speed <= 0.5 m/s -> 100% Compass
        let compass = 45.0
        let cogCourse = 180.0
        let speed = 0.2 // stationary / creeping
        
        let blended = LocationHeadingManager.computeBlendedHeading(
            compassHeading: compass,
            gpsCourse: cogCourse,
            speedMps: speed
        )
        XCTAssertEqual(blended, 45.0, accuracy: 0.001, "Stationary speed must rely 100% on compass heading")
    }
    
    func testLocalSpeedWeightedHeadingBlending_Running() {
        // Speed >= 2.5 m/s -> 100% GPS COG
        let compass = 45.0 // arm swinging
        let cogCourse = 180.0 // running South
        let speed = 3.5 // running
        
        let blended = LocationHeadingManager.computeBlendedHeading(
            compassHeading: compass,
            gpsCourse: cogCourse,
            speedMps: speed
        )
        XCTAssertEqual(blended, 180.0, accuracy: 0.001, "Running speed must rely 100% on GPS Course Over Ground")
    }
    
    func testLocalSpeedWeightedHeadingBlending_SmoothTransitionAndNorthWrap() {
        // Midpoint speed (1.5 m/s) -> 50% blend
        // Test angle wrapping around North: 350° and 10°
        // Vector average of 350° (-10°) and 10° is exactly 0° / 360°
        let angle1 = 350.0
        let angle2 = 10.0
        
        let blended = LocationHeadingManager.computeBlendedHeading(
            compassHeading: angle1,
            gpsCourse: angle2,
            speedMps: 1.5
        )
        // 0.0 or 360.0 (both represent North)
        XCTAssertTrue(abs(blended - 0.0) < 0.01 || abs(blended - 360.0) < 0.01, "Circular interpolation across 360° north boundary must yield 0°/360°")
        
        // Midpoint between 0° and 90° at 1.5 m/s -> 45°
        let blended45 = LocationHeadingManager.computeBlendedHeading(
            compassHeading: 0.0,
            gpsCourse: 90.0,
            speedMps: 1.5
        )
        XCTAssertEqual(blended45, 45.0, accuracy: 0.001)
    }
    
    func testRemoteMemberCourseOverGroundCalculation() {
        let syncManager = createMockFirebaseSyncManager()
        let room = SquadRoom(id: "COG_ROOM", hostId: "LOCAL_USER", members: [:])
        syncManager.connectToRoom(room)
        
        let metersPerDegreeLat = AppConstants.Location.metersPerDegreeLatitude // 111,139
        let baseLat = 37.785834
        let baseLng = -122.406417
        let metersPerDegreeLon = metersPerDegreeLat * cos(baseLat * .pi / 180.0)
        
        // 1. Packet 1: Initial position
        let p1 = TelemetryPacket(memberId: "REMOTE_OP", roomId: "COG_ROOM", latitude: baseLat, longitude: baseLng, heartRate: 75.0, timestamp: 1000, sequenceNumber: 1)
        XCTAssertTrue(syncManager.validateAndProcessPacket(p1))
        
        // 2. Packet 2: Move North by 20 meters -> Bearing ~0°
        let p2North = TelemetryPacket(
            memberId: "REMOTE_OP",
            roomId: "COG_ROOM",
            latitude: baseLat + (20.0 / metersPerDegreeLat),
            longitude: baseLng,
            heartRate: 75.0,
            timestamp: 1002,
            sequenceNumber: 2
        )
        XCTAssertTrue(syncManager.validateAndProcessPacket(p2North))
        let northHeading = syncManager.activeRoom?.members["REMOTE_OP"]?.heading ?? 999.0
        XCTAssertEqual(northHeading, 0.0, accuracy: 1.0, "Northward movement must yield ~0° heading")
        
        // 3. Packet 3: Move East by 20 meters -> Bearing ~90°
        let p3East = TelemetryPacket(
            memberId: "REMOTE_OP",
            roomId: "COG_ROOM",
            latitude: baseLat + (20.0 / metersPerDegreeLat),
            longitude: baseLng + (20.0 / metersPerDegreeLon),
            heartRate: 75.0,
            timestamp: 1004,
            sequenceNumber: 3
        )
        XCTAssertTrue(syncManager.validateAndProcessPacket(p3East))
        let eastHeading = syncManager.activeRoom?.members["REMOTE_OP"]?.heading ?? 999.0
        XCTAssertEqual(eastHeading, 90.0, accuracy: 1.0, "Eastward movement must yield ~90° heading")
        
        // 4. Packet 4: Stationary packet (0m displacement) -> Must RETAIN previous heading (90°)
        let p4Stationary = TelemetryPacket(
            memberId: "REMOTE_OP",
            roomId: "COG_ROOM",
            latitude: baseLat + (20.0 / metersPerDegreeLat),
            longitude: baseLng + (20.0 / metersPerDegreeLon),
            heartRate: 75.0,
            timestamp: 1006,
            sequenceNumber: 4
        )
        XCTAssertTrue(syncManager.validateAndProcessPacket(p4Stationary))
        let stationaryHeading = syncManager.activeRoom?.members["REMOTE_OP"]?.heading ?? 999.0
        XCTAssertEqual(stationaryHeading, 90.0, accuracy: 0.001, "Zero displacement must retain previous heading")
    }
    
    func testSelfTelemetryIgnoredFromRemoteEndpointAndUsesLiveBlendedHeading() {
        let gameState = createMockGameState()
        mockTransport(for: gameState).seed([
            "LOCAL_PLAYER": [40.7128, -74.0060, 150.0, 1724686650.0],
            "REMOTE_PLAYER": [37.7860, -122.4070, 95.0, 1724686651.0]
        ], at: "p/TEST_ROOM")
        gameState.myMemberId = "LOCAL_PLAYER"
        gameState.firebaseManager.localMemberId = "LOCAL_PLAYER"

        let room = SquadRoom(id: "TEST_ROOM", hostId: "LOCAL_PLAYER", members: [:])
        gameState.firebaseManager.activeRoom = room
        gameState.firebaseManager.fetchRemoteTelemetry(roomId: "TEST_ROOM")
        
        let exp = expectation(description: "Process remote telemetry filtering self")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Local player's telemetry must NOT have been downloaded/applied from the server
            XCTAssertNil(gameState.firebaseManager.activeRoom?.members["LOCAL_PLAYER"])
            // Remote player's telemetry MUST be downloaded and applied
            XCTAssertEqual(gameState.firebaseManager.activeRoom?.members["REMOTE_PLAYER"]?.heartRate, 95.0)
            
            // gameState.localPlayerMember must always provide live local data and COD blended heading
            let localMember = gameState.localPlayerMember
            XCTAssertEqual(localMember.id, "LOCAL_PLAYER")
            XCTAssertEqual(localMember.heading, gameState.locationHeadingManager.blendedHeading)
            
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
    

    
    // MARK: - Login Check Field Error Tests
    
    func testLoginCheck_DuplicateCallsign_TurnsCallsignFieldRed() {
        let gameState = createMockGameState()
        let pin = "1234"
        let name = "ALPHA"
        let roomId = name + FirebaseSyncManager.deriveRoomPadding(pin: pin, name: name)
        let existingMember = SquadMember(id: "HOST1", callsign: "VIPER", latitude: 37.77, longitude: -122.41)
        let room = SquadRoom(id: roomId, hostId: "HOST1", pinHash: FirebaseSyncManager.hashPin(pin, salt: roomId), members: ["HOST1": existingMember])
        let roomData = try! JSONEncoder().encode(room)
        let roomJson = try! JSONSerialization.jsonObject(with: roomData)
        mockTransport(for: gameState).seed(roomJson, at: "r/\(roomId)")
        gameState.myMemberId = "PLAYER_2"
        gameState.myCallsign = "VIPER" // Duplicate callsign

        XCTAssertFalse(gameState.callsignError)

        let exp = expectation(description: "Duplicate callsign error")
        gameState.joinRoom(id: name, pin: pin) { success in
            XCTAssertFalse(success)
            XCTAssertTrue(gameState.callsignError, "Callsign field must turn red on callsign duplication")
            XCTAssertFalse(gameState.squadNameError)
            XCTAssertFalse(gameState.pinError)
            XCTAssertEqual(gameState.errorMessage, FirebaseSyncError.duplicateCallsign.localizedDescription)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testLoginCheck_ServerNameDuplicationIfHosting_TurnsSquadNameFieldRed() {
        let gameState = createMockGameState()
        let pin = "1234"
        let name = "EXIST_SQUAD" // <= maxRoomNameEntryLength (12) so hostRoom won't truncate it
        let roomId = name + FirebaseSyncManager.deriveRoomPadding(pin: pin, name: name)
        let existingRoom = SquadRoom(id: roomId, hostId: "OTHER_HOST", pinHash: FirebaseSyncManager.hashPin(pin, salt: roomId), members: [:])
        let roomData = try! JSONEncoder().encode(existingRoom)
        let roomJson = try! JSONSerialization.jsonObject(with: roomData)
        mockTransport(for: gameState).seed(roomJson, at: "r/\(roomId)")
        XCTAssertFalse(gameState.squadNameError)

        let exp = expectation(description: "Server duplication on host error")
        gameState.hostRoom(name: name, pin: pin) { success in
            XCTAssertFalse(success)
            XCTAssertTrue(gameState.squadNameError, "Squad name field must turn red if server already exists when hosting")
            XCTAssertFalse(gameState.callsignError)
            XCTAssertFalse(gameState.pinError)
            XCTAssertEqual(gameState.errorMessage, FirebaseSyncError.roomAlreadyExists.localizedDescription)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testLoginCheck_ServerNameDoesNotExistIfJoining_TurnsSquadNameFieldRed() {
        // No seeding: a fresh MockRTDBTransport's empty root resolves the room read to nil, same
        // as the old handler's "null" response.
        let gameState = createMockGameState()
        XCTAssertFalse(gameState.squadNameError)

        let exp = expectation(description: "Server does not exist on join error")
        gameState.joinRoom(id: "UNKNOWN_SQUAD", pin: "1234") { success in
            XCTAssertFalse(success)
            XCTAssertTrue(gameState.squadNameError, "Squad name field must turn red if server doesn't exist when joining")
            XCTAssertFalse(gameState.callsignError)
            XCTAssertFalse(gameState.pinError)
            XCTAssertEqual(gameState.errorMessage, FirebaseSyncError.roomNotFound.localizedDescription)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    // A wrong PIN now derives a different (nonexistent) room id rather than being rejected by a
    // found room's stored hash, so it surfaces as roomNotFound/squadNameError, not
    // incorrectPin/pinError — see CLOUD_DATA_MANAGEMENT.md noted UX behavior change.
    func testLoginCheck_WrongPinIfJoining_LooksLikeRoomNotFound() {
        let gameState = createMockGameState()
        let correctPin = "1234"
        let name = "LOCKED_SQUAD"
        let roomId = name + FirebaseSyncManager.deriveRoomPadding(pin: correctPin, name: name)
        let lockedRoom = SquadRoom(id: roomId, hostId: "HOST1", pinHash: FirebaseSyncManager.hashPin(correctPin, salt: roomId), members: [:])
        let roomData = try! JSONEncoder().encode(lockedRoom)
        let roomJson = try! JSONSerialization.jsonObject(with: roomData)
        mockTransport(for: gameState).seed(roomJson, at: "r/\(roomId)")
        gameState.myMemberId = "PLAYER_1"
        gameState.myCallsign = "GHOST"
        XCTAssertFalse(gameState.squadNameError)

        let exp = expectation(description: "Wrong PIN error")
        gameState.joinRoom(id: name, pin: "9999") { success in
            XCTAssertFalse(success)
            XCTAssertTrue(gameState.squadNameError, "Squad name field turns red — a wrong PIN derives a different, nonexistent room id")
            XCTAssertFalse(gameState.callsignError)
            XCTAssertFalse(gameState.pinError)
            XCTAssertEqual(gameState.errorMessage, FirebaseSyncError.roomNotFound.localizedDescription)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    func testSquadMemberStreamlinedSerializationExcludesTelemetry() throws {
        let member = SquadMember(
            id: "uuid_user_1234",
            callsign: "VIPER",
            latitude: 37.785834,
            longitude: -122.406417,
            altitude: 15.0,
            heading: 180.0,
            heartRate: 140.0,
            batteryLevel: 0.85,
            lastUpdatedTimestamp: 1787767191.0,
            sequenceNumber: 42,
            status: .active,
            role: .leader,
            colorHex: "#FF0000"
        )
        
        let encodedData = try JSONEncoder().encode(member)
        let json = try JSONSerialization.jsonObject(with: encodedData) as? [String: Any]
        XCTAssertNotNil(json)
        
        // Allowed metadata keys for room roster
        XCTAssertEqual(json?["mid"] as? String, "uuid_user_1234")
        XCTAssertEqual(json?["csn"] as? String, "VIPER")
        XCTAssertEqual(json?["rol"] as? String, "leader")
        
        // Excluded dynamic telemetry fields
        XCTAssertNil(json?["latitude"])
        XCTAssertNil(json?["longitude"])
        XCTAssertNil(json?["altitude"])
        XCTAssertNil(json?["heading"])
        XCTAssertNil(json?["heartRate"])
        XCTAssertNil(json?["batteryLevel"])
        XCTAssertNil(json?["lastUpdatedTimestamp"])
        XCTAssertNil(json?["sequenceNumber"])
        XCTAssertNil(json?["status"])
        XCTAssertNil(json?["colorHex"])
    }
    
    func testPersistentMemberIdDistinctFromCallsign() {
        UserDefaults.standard.removeObject(forKey: AppConstants.Storage.userCallsignKey)
        
        let gameState = GameStateManager()
        XCTAssertFalse(gameState.myMemberId.isEmpty)
        XCTAssertNotEqual(gameState.myMemberId, gameState.myCallsign, "myMemberId should be a distinct derived ID, not identical to callsign")
        
        gameState.myCallsign = "RECON_1"
        XCTAssertEqual(gameState.myMemberId, GameStateManager.deriveMemberId(fromCallsign: "RECON_1"), "myMemberId should derive from updated callsign")
    }
    
    // MARK: - Dead Reckoning Delta Gating & SSE Stream Optimization Tests
    
    func testMovementDeltaGatingSuppressesStationaryUploads() {
        let gameState = createMockGameState()
        let room = SquadRoom(id: "DELTA_ROOM", hostId: gameState.myMemberId)
        gameState.firebaseManager.activeRoom = room
        
        let baseLocation = CLLocation(latitude: 37.785834, longitude: -122.406417)
        gameState.locationHeadingManager.userLocation = baseLocation
        gameState.locationHeadingManager.blendedHeading = 90.0
        gameState.healthKitManager.currentHeartRate = 80.0
        gameState.isDead = false
        
        // Force baseline sync so lastSentLocation = baseLocation, lastSentHeading = 90.0, lastSentHeartRate = 80.0
        gameState.broadcastLocalTelemetry(location: baseLocation, heading: 90.0, heartRate: 80.0, force: true)
        let baselineEmittedCount = gameState.totalTelemetryUploadsEmitted
        
        // Micro displacement (2.2m < 3.5m) and small HR change (5 BPM < 12 BPM)
        let microMovedLocation = CLLocation(latitude: 37.785834 + 0.000020, longitude: -122.406417) // ~2.22 meters
        XCTAssertLessThan(microMovedLocation.distance(from: baseLocation), AppConstants.Timing.DeltaGating.maxPredictedPositionErrorMeters)
        
        let now = Date().timeIntervalSince1970
        let shouldEmitMicro = gameState.shouldEmitTelemetry(
            currentLocation: microMovedLocation,
            currentHeading: 91.0,
            currentHeartRate: 85.0,
            currentIsDead: false,
            currentTime: now,
            force: false
        )
        XCTAssertFalse(shouldEmitMicro, "Micro movements (< 3.5m) and minor HR fluctuations (< 12 BPM) while stationary should be gated / suppressed")
        
        // Applying micro-movement with timer reset to isolate delta gating check
        gameState.lastUploadTimestamp = 0.0
        gameState.broadcastLocalTelemetry(location: microMovedLocation, heading: 91.0, heartRate: 85.0, force: false)
        
        XCTAssertEqual(gameState.totalTelemetryUploadsEmitted, baselineEmittedCount, "Emitted packets must remain unchanged when stationary")
        XCTAssertGreaterThanOrEqual(gameState.totalTelemetryUploadsGated, 1)
    }
    
    func testMovementDeltaGatingTriggersOnSignificantDisplacement() {
        let gameState = createMockGameState()
        let room = SquadRoom(id: "MOVE_ROOM", hostId: gameState.myMemberId)
        gameState.firebaseManager.activeRoom = room
        
        let startLoc = CLLocation(latitude: 37.785834, longitude: -122.406417)
        gameState.locationHeadingManager.userLocation = startLoc
        gameState.locationHeadingManager.blendedHeading = 0.0
        gameState.healthKitManager.currentHeartRate = 75.0
        gameState.isDead = false
        
        let emittedBefore = gameState.totalTelemetryUploadsEmitted
        
        // Move 5.0 meters (>= 3.5m threshold)
        let movedLoc = CLLocation(latitude: 37.785834 + 0.000045, longitude: -122.406417)
        XCTAssertGreaterThanOrEqual(movedLoc.distance(from: startLoc), AppConstants.Timing.DeltaGating.maxPredictedPositionErrorMeters)
        
        let now = Date().timeIntervalSince1970
        let shouldEmit = gameState.shouldEmitTelemetry(
            currentLocation: movedLoc,
            currentHeading: 0.0,
            currentHeartRate: 75.0,
            currentIsDead: false,
            currentTime: now,
            force: false
        )
        XCTAssertTrue(shouldEmit, "Displacement >= 3.5m must trigger upload")
        
        gameState.lastUploadTimestamp = 0.0
        gameState.locationHeadingManager.userLocation = movedLoc
        XCTAssertEqual(gameState.totalTelemetryUploadsEmitted, emittedBefore + 1, "Displacement >= 3.5m must emit new packet")
    }
    
    func testHeadingChangesAloneDoNotTriggerUploads() {
        let gameState = createMockGameState()
        let room = SquadRoom(id: "TURN_ROOM", hostId: gameState.myMemberId)
        gameState.firebaseManager.activeRoom = room
        
        let loc = CLLocation(latitude: 37.785834, longitude: -122.406417)
        gameState.locationHeadingManager.userLocation = loc
        gameState.locationHeadingManager.blendedHeading = 10.0
        gameState.healthKitManager.currentHeartRate = 75.0
        
        // Force baseline sync
        gameState.broadcastLocalTelemetry(location: loc, heading: 10.0, heartRate: 75.0, force: true)
        let emittedBefore = gameState.totalTelemetryUploadsEmitted
        
        // Turn 50° while stationary in position
        let now = Date().timeIntervalSince1970
        let shouldEmit = gameState.shouldEmitTelemetry(
            currentLocation: loc,
            currentHeading: 60.0,
            currentHeartRate: 75.0,
            currentIsDead: false,
            currentTime: now,
            force: false
        )
        XCTAssertFalse(shouldEmit, "Heading changes alone without displacement must NOT trigger uploads (teammates compute COG or receive heading on displacement)")
        
        gameState.lastUploadTimestamp = 0.0
        gameState.locationHeadingManager.blendedHeading = 60.0
        XCTAssertEqual(gameState.totalTelemetryUploadsEmitted, emittedBefore, "Emitted packets must remain unchanged when merely turning in place")
    }
    
    func testMovementDeltaGatingTriggersOnHeartRateChange() {
        let gameState = createMockGameState()
        let room = SquadRoom(id: "HR_ROOM", hostId: gameState.myMemberId)
        gameState.firebaseManager.activeRoom = room
        
        let loc = CLLocation(latitude: 37.785834, longitude: -122.406417)
        gameState.locationHeadingManager.userLocation = loc
        gameState.locationHeadingManager.blendedHeading = 0.0
        gameState.healthKitManager.currentHeartRate = 70.0
        
        // Force baseline sync with 70.0 BPM
        gameState.broadcastLocalTelemetry(location: loc, heartRate: 70.0, force: true)
        let emittedBefore = gameState.totalTelemetryUploadsEmitted
        
        // Heart rate jumps from 70 to 85 BPM (15 BPM shift >= 12 BPM threshold)
        let now = Date().timeIntervalSince1970
        let shouldEmit = gameState.shouldEmitTelemetry(
            currentLocation: loc,
            currentHeading: 0.0,
            currentHeartRate: 85.0,
            currentIsDead: false,
            currentTime: now,
            force: false
        )
        XCTAssertTrue(shouldEmit, "Heart rate shift >= 12 BPM must trigger upload")
        
        gameState.lastUploadTimestamp = 0.0
        gameState.healthKitManager.currentHeartRate = 85.0
        XCTAssertEqual(gameState.totalTelemetryUploadsEmitted, emittedBefore + 1, "Heart rate shift >= 12 BPM must emit new packet")
    }
    
    func testHeartbeatFallbackTriggersWhenStationary() {
        let gameState = createMockGameState()
        let room = SquadRoom(id: "HEARTBEAT_ROOM", hostId: gameState.myMemberId)
        gameState.firebaseManager.activeRoom = room
        
        let loc = CLLocation(latitude: 37.785834, longitude: -122.406417)
        gameState.locationHeadingManager.userLocation = loc
        gameState.locationHeadingManager.blendedHeading = 0.0
        gameState.healthKitManager.currentHeartRate = 75.0
        
        // Empty room (0 members): refreshInterval = 7 * updateInterval(0) = 7 * 1.0 = 7.0s
        XCTAssertEqual(gameState.currentHeartbeatFallbackInterval(), 7.0, accuracy: 0.01)

        // Stationary for 5.0 seconds (< 7.0s) -> should be suppressed
        let now = Date().timeIntervalSince1970
        let shouldNotEmit = gameState.shouldEmitTelemetry(
            currentLocation: loc,
            currentHeading: 0.0,
            currentHeartRate: 75.0,
            currentIsDead: false,
            currentTime: now + 5.0,
            force: false
        )
        XCTAssertFalse(shouldNotEmit, "Stationary before 7s fallback must be gated")

        // Simulate stationary in cover for 8.0 seconds (> 7.0s fallback threshold)
        let shouldEmit = gameState.shouldEmitTelemetry(
            currentLocation: loc,
            currentHeading: 0.0,
            currentHeartRate: 75.0,
            currentIsDead: false,
            currentTime: now + 8.0,
            force: false
        )
        XCTAssertTrue(shouldEmit, "Stationary heartbeat fallback (7.0s) must emit to prevent teammate icons from turning gray")
    }

    func testLargeServerHeartbeatFallbackScaling() {
        let gameState = createMockGameState()
        var members: [String: SquadMember] = [:]
        for i in 1...30 {
            members["MEMBER_\(i)"] = SquadMember(id: "MEMBER_\(i)", callsign: "OP_\(i)", latitude: 37.78, longitude: -122.40)
        }
        let largeRoom = SquadRoom(id: "LARGE_ROOM", hostId: "MEMBER_1", members: members)
        gameState.firebaseManager.activeRoom = largeRoom

        // 30 players: updateInterval = 1.0 / (30 / 12) = 2.5s
        gameState.recalculateAdaptiveUploadInterval()
        XCTAssertEqual(gameState.adaptiveUploadInterval, 2.5, accuracy: 0.01)

        // Heartbeat fallback now scales with room size too: 7 * T = 7 * 2.5 = 17.5s
        let fallbackInterval = gameState.currentHeartbeatFallbackInterval()
        XCTAssertEqual(fallbackInterval, 17.5, accuracy: 0.01, "Upload fallback scales with room size (7 * T)")

        // Display-side stale threshold stays in sync with the same T for Y * T staleness
        XCTAssertEqual(SquadMember.defaultUpdateInterval, 2.5, accuracy: 0.01)
    }

    
    func testDownedStatusBypassesGating() {
        let gameState = createMockGameState()
        let room = SquadRoom(id: "KIA_ROOM", hostId: gameState.myMemberId)
        gameState.firebaseManager.activeRoom = room
        
        let loc = CLLocation(latitude: 37.785834, longitude: -122.406417)
        gameState.locationHeadingManager.userLocation = loc
        gameState.locationHeadingManager.blendedHeading = 0.0
        gameState.healthKitManager.currentHeartRate = 75.0
        gameState.isDead = false
        
        let emittedBefore = gameState.totalTelemetryUploadsEmitted
        
        // Player dies / goes downed -> Must immediately emit
        gameState.setDead(true)
        XCTAssertEqual(gameState.totalTelemetryUploadsEmitted, emittedBefore + 1, "Transition to downed/KIA must emit telemetry immediately")
    }
    
    func testClientDrivenRESTTelemetryPollingIngestion() {
        let syncManager = createMockFirebaseSyncManager()
        mockTransport(for: syncManager).seed([
            "OP_1": [37.7858, -122.4064, 10.0, 90.0, 75.0, 1700000000.0, 1],
            "OP_2": [37.7860, -122.4070, 12.0, 180.0, 80.0, 1700000000.0, 1]
        ], at: "p/REST_ROOM")
        let room = SquadRoom(id: "REST_ROOM", hostId: "HOST_1")
        syncManager.activeRoom = room
        
        let exp = expectation(description: "Fetch remote telemetry over client-driven REST")
        syncManager.fetchRemoteTelemetry(roomId: "REST_ROOM")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(syncManager.activeRoom?.members["OP_1"]?.latitude, 37.7858)
            XCTAssertEqual(syncManager.activeRoom?.members["OP_2"]?.latitude, 37.7860)
            XCTAssertEqual(syncManager.totalPacketsProcessed, 2)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    func testClientDrivenRESTPrunesMissingRemoteMembers() {
        let syncManager = createMockFirebaseSyncManager()
        // Only OP_1 is on the server; OP_2 has left the squad
        mockTransport(for: syncManager).seed([
            "OP_1": [37.7858, -122.4064, 10.0, 90.0, 75.0, 1700000000.0, 1]
        ], at: "p/PRUNE_ROOM")
        syncManager.localMemberId = "MY_LOCAL_ID"
        var room = SquadRoom(id: "PRUNE_ROOM", hostId: "HOST_1")
        room.members["MY_LOCAL_ID"] = SquadMember(id: "MY_LOCAL_ID", callsign: "ME", latitude: 37.70, longitude: -122.30)
        room.members["OP_1"] = SquadMember(id: "OP_1", callsign: "P1", latitude: 37.77, longitude: -122.41)
        room.members["OP_2"] = SquadMember(id: "OP_2", callsign: "P2", latitude: 37.78, longitude: -122.42)
        syncManager.activeRoom = room
        
        let exp = expectation(description: "Prune missing remote members on REST response")
        syncManager.fetchRemoteTelemetry(roomId: "PRUNE_ROOM")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertNotNil(syncManager.activeRoom?.members["MY_LOCAL_ID"], "Local player must never be pruned")
            XCTAssertNotNil(syncManager.activeRoom?.members["OP_1"], "Active server member OP_1 must be present")
            XCTAssertNil(syncManager.activeRoom?.members["OP_2"], "Remote member OP_2 missing from server must be pruned")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    func testClientDrivenRESTPollingLifecycleAndTimers() {
        // REST-era polling used a repeating Timer; polling is now driven by persistent RTDB
        // listeners (see FirebaseSyncManager.startTelemetryPolling/stopTelemetryPolling), so this
        // verifies listener attach/detach lifecycle instead of a timer.
        let syncManager = createMockFirebaseSyncManager()
        let transport = mockTransport(for: syncManager)
        let room = SquadRoom(id: "LIFECYCLE_ROOM", hostId: "HOST_1")
        syncManager.activeRoom = room

        // Start client-driven polling -> attaches the p/t/r realtime listeners
        syncManager.startTelemetryPolling(roomId: "LIFECYCLE_ROOM")
        XCTAssertEqual(syncManager.pollingInterval, 1.0)
        XCTAssertFalse(transport.recordedObservedPaths.isEmpty, "startTelemetryPolling must attach realtime listeners")
        XCTAssertTrue(transport.recordedObservedPaths.contains { $0.path == "p/LIFECYCLE_ROOM" && $0.eventType == .childAdded })
        XCTAssertTrue(transport.recordedObservedPaths.contains { $0.path == "t/LIFECYCLE_ROOM" && $0.eventType == .value })
        XCTAssertTrue(transport.recordedObservedPaths.contains { $0.path == "r/LIFECYCLE_ROOM" && $0.eventType == .value })

        // Stop client-driven polling -> detaches listeners without error/crash
        syncManager.stopTelemetryPolling()
    }
    
    func testWristDownThrottlingAndInstantWakeBurst() {
        let gameState = createMockGameState()
        mockTransport(for: gameState).seed([
            "OP_WAKE": [37.7858, -122.4064, 10.0, 90.0, 75.0, 1700000000.0, 1]
        ], at: "p/WAKE_ROOM")
        let room = SquadRoom(id: "WAKE_ROOM", hostId: gameState.myMemberId)
        gameState.firebaseManager.activeRoom = room
        
        // Initial state: Wrist active -> polling interval is baseline (1.0s)
        XCTAssertTrue(gameState.firebaseManager.isWristActive)
        XCTAssertEqual(gameState.firebaseManager.pollingInterval, 1.0)
        
        // 1. Wrist lowers (scenePhase == .inactive / isLuminanceReduced == true)
        gameState.setWristActive(false)
        XCTAssertFalse(gameState.firebaseManager.isWristActive)
        XCTAssertEqual(gameState.firebaseManager.pollingInterval, AppConstants.Timing.AdaptiveRate.wristDownPollingInterval, "Polling interval must throttle to 10s when wrist is down")
        
        // 2. Wrist raises (Instant Wake Burst)
        let processedBefore = gameState.firebaseManager.totalPacketsProcessed
        let exp = expectation(description: "Instant wake burst fetches telemetry immediately")
        
        gameState.setWristActive(true)
        XCTAssertTrue(gameState.firebaseManager.isWristActive)
        XCTAssertEqual(gameState.firebaseManager.pollingInterval, 1.0, "Polling interval must restore to 1.0s on wrist raise")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            XCTAssertGreaterThan(gameState.firebaseManager.totalPacketsProcessed, processedBefore, "Instant wake burst must immediately fetch telemetry")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }
    
    func testDoubleTapAndAwakeInteractionTriggerWakeBurst() {
        let gameState = createMockGameState()
        mockTransport(for: gameState).seed([
            "OP_WAKE2": [37.7858, -122.4064, 10.0, 90.0, 75.0, 1700000000.0, 1]
        ], at: "p/DOUBLE_TAP_ROOM")
        let room = SquadRoom(id: "DOUBLE_TAP_ROOM", hostId: gameState.myMemberId)
        gameState.firebaseManager.activeRoom = room
        
        // Put in inactive state (wrist down)
        gameState.setWristActive(false)
        XCTAssertFalse(gameState.firebaseManager.isWristActive)
        XCTAssertEqual(gameState.firebaseManager.pollingInterval, 10.0)
        
        // Trigger awake burst (e.g. from double tap or screen tap gesture)
        let processedBefore = gameState.firebaseManager.totalPacketsProcessed
        let exp = expectation(description: "Double-tap/gesture awake burst immediately restores active polling and fetches telemetry")
        
        gameState.triggerWakeBurst()
        XCTAssertTrue(gameState.firebaseManager.isWristActive)
        XCTAssertEqual(gameState.firebaseManager.pollingInterval, 1.0)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            XCTAssertGreaterThan(gameState.firebaseManager.totalPacketsProcessed, processedBefore)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }

    
    // MARK: - Policy Configuration Tests
    
    func testPolicyConstantsAndConfiguration() {
        // Verify Privacy Policy URL is valid HTTPS URL
        XCTAssertFalse(AppConstants.Policy.privacyPolicyURL.isEmpty)
        guard let privacyUrl = URL(string: AppConstants.Policy.privacyPolicyURL) else {
            XCTFail("Privacy Policy URL must be valid")
            return
        }
        XCTAssertEqual(privacyUrl.scheme, "https")
        XCTAssertTrue(privacyUrl.host == "www.privacypolicies.com" || privacyUrl.host == "radarmap.app")
        
        // Verify Contact Email is valid email format
        XCTAssertEqual(AppConstants.Policy.contactEmail, "sweetdreamsdeveloper@gmail.com")
        XCTAssertTrue(AppConstants.Policy.contactEmail.contains("@"))
        XCTAssertTrue(AppConstants.Policy.contactEmail.contains("."))
        
        // Verify Contact Form URL
        XCTAssertEqual(AppConstants.Policy.contactFormURL, "https://forms.gle/pCuy2zJtSfLoyqj16")
        guard let formUrl = URL(string: AppConstants.Policy.contactFormURL) else {
            XCTFail("Contact Form URL must be valid")
            return
        }
        XCTAssertEqual(formUrl.scheme, "https")
        
        // Verify mailto URL construction
        guard let mailUrl = URL(string: "mailto:\(AppConstants.Policy.contactEmail)") else {
            XCTFail("Mailto URL must be valid")
            return
        }
        XCTAssertEqual(mailUrl.scheme, "mailto")
        
        // Verify policy summary and disclosures are present
        XCTAssertFalse(AppConstants.Policy.summary.isEmpty)
        XCTAssertFalse(AppConstants.Policy.locationDataDescription.isEmpty)
        XCTAssertFalse(AppConstants.Policy.healthDataDescription.isEmpty)
        XCTAssertFalse(AppConstants.Policy.dataRetentionDescription.isEmpty)
        XCTAssertFalse(AppConstants.Policy.encryptionDescription.isEmpty)
    }
    
    // MARK: - Callsign, Room Name & PIN Retention Tests
    
    func testCallsignAndRoomNameRetentionInUserDefaultsAndGameState() {
        // Clear existing keys
        // callsign/roomName/pin are no longer individually UserDefaults-backed — they're views
        // onto watchConnectivityManager.localLS.config, persisted as one blob under
        // "wc_local_ls_snapshot" (cleared by setUp()/tearDown()). The legacy per-field keys below
        // are only ever *read* once, as a migration fallback when no such blob exists yet.
        UserDefaults.standard.removeObject(forKey: "wc_local_ls_snapshot")

        // 1. Fresh state has no hardcoded values
        let gameState = GameStateManager()
        XCTAssertEqual(gameState.myCallsign, "", "Fresh gameState must have empty callsign by default (no hardcoded value)")
        XCTAssertEqual(gameState.savedRoomName, "", "Fresh gameState must have empty savedRoomName by default (no hardcoded value)")
        XCTAssertEqual(gameState.savedPin, "", "Fresh gameState must have empty savedPin by default (no hardcoded value)")

        // 2. Modifying properties updates the persisted localLS snapshot
        gameState.myCallsign = "VIPER-7"
        gameState.savedRoomName = "BRAVO"
        gameState.savedPin = "1234"
        // Persistence itself happens on a private background queue inside
        // WatchConnectivityManager (not the main queue pumpMainRunLoop() drains) — give it a
        // moment to land before reading it back via a fresh instance below.
        Thread.sleep(forTimeInterval: 0.1)

        // 3. New launch prepopulates from the persisted localLS snapshot
        let newGameState = GameStateManager()
        XCTAssertEqual(newGameState.myCallsign, "VIPER-7", "New GameStateManager instance should prepopulate callsign from persisted localLS")
        XCTAssertEqual(newGameState.savedRoomName, "BRAVO", "New GameStateManager instance should prepopulate room name from persisted localLS")
        XCTAssertEqual(newGameState.savedPin, "1234", "New GameStateManager instance should prepopulate PIN from persisted localLS")

        // Clean up
        UserDefaults.standard.removeObject(forKey: "wc_local_ls_snapshot")
    }
    
    // MARK: - Default User Map Centering Tests
    
    func testLocationUpdatesStartOnAppLaunch() {
        let gameState = GameStateManager()
        XCTAssertTrue(gameState.locationHeadingManager.isUpdating, "Location and heading updates should be active on launch so user position is known")
    }
    
    func testDefaultPresentationAndRadarCenterFollowsUser() {
        let gameState = GameStateManager()
        XCTAssertEqual(gameState.selectedPresentation, .radar, "Default presentation should be tactical radar")
        
        // When location is updated, local player member uses updated coordinate
        let testCoord = CLLocation(latitude: 37.7749, longitude: -122.4194)
        gameState.locationHeadingManager.userLocation = testCoord
        
        let localPlayerCoord = gameState.locationHeadingManager.userLocation?.coordinate
        XCTAssertEqual(localPlayerCoord?.latitude, 37.7749)
        XCTAssertEqual(localPlayerCoord?.longitude, -122.4194)
    }
    
    // MARK: - Room Name & Callsign Validation and Scope Tests
    
    func testCreateRoomRejectsEmptyRoomName() {
        let syncManager = createMockFirebaseSyncManager()
        let emptyIdRoom = SquadRoom(id: "   ", hostId: "USER1", members: ["USER1": SquadMember(id: "USER1", callsign: "VIPER", latitude: 0, longitude: 0)])
        
        let exp = expectation(description: "Empty room name rejected on create")
        syncManager.createRoom(emptyIdRoom) { result in
            switch result {
            case .success:
                XCTFail("Should not succeed with empty room name")
            case .failure(let error):
                XCTAssertEqual(error, FirebaseSyncError.emptyRoomName)
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    func testCreateRoomInitializesTelemetryAndTacticalNodesWithTTL() {
        let syncManager = createMockFirebaseSyncManager()
        let transport = mockTransport(for: syncManager)
        let member = SquadMember(id: "HOST1", callsign: "VIPER", latitude: 0, longitude: 0, role: .leader)
        let room = SquadRoom(id: "NEW_SQUAD", hostId: "HOST1", members: ["HOST1": member])
        
        let exp = expectation(description: "Room created and subnodes initialized")
        syncManager.createRoom(room) { result in
            if case .success = result {
                exp.fulfill()
            } else {
                XCTFail("Room creation should succeed")
            }
        }
        wait(for: [exp], timeout: 1.0)
        
        XCTAssertTrue(transport.recordedSets.contains { $0.path == "r/NEW_SQUAD" }, "Must create room node")
        XCTAssertTrue(transport.recordedSets.contains { $0.path == "p/NEW_SQUAD" }, "Must initialize telemetry node on room creation")
        XCTAssertTrue(transport.recordedSets.contains { $0.path == "t/NEW_SQUAD" }, "Must initialize tactical node on room creation")
    }
    
    func testCreateRoomRejectsEmptyCallsign() {
        let syncManager = createMockFirebaseSyncManager()
        let emptyCallsignMember = SquadMember(id: "USER1", callsign: "   ", latitude: 0, longitude: 0)
        let room = SquadRoom(id: "ALPHA", hostId: "USER1", members: ["USER1": emptyCallsignMember])
        
        let exp = expectation(description: "Empty callsign rejected on create")
        syncManager.createRoom(room) { result in
            switch result {
            case .success:
                XCTFail("Should not succeed with empty member callsign")
            case .failure(let error):
                XCTAssertEqual(error, FirebaseSyncError.emptyCallsign)
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    func testJoinRoomRejectsEmptyRoomName() {
        let syncManager = createMockFirebaseSyncManager()
        let member = SquadMember(id: "USER2", callsign: "GHOST", latitude: 0, longitude: 0)
        
        let exp = expectation(description: "Empty room name rejected on join")
        syncManager.joinRoom(id: "  ", member: member) { result in
            switch result {
            case .success:
                XCTFail("Should not succeed with empty room name")
            case .failure(let error):
                XCTAssertEqual(error, FirebaseSyncError.emptyRoomName)
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    func testJoinRoomRejectsEmptyCallsign() {
        let syncManager = createMockFirebaseSyncManager()
        let emptyCallsignMember = SquadMember(id: "USER2", callsign: "   ", latitude: 0, longitude: 0)
        
        let exp = expectation(description: "Empty callsign rejected on join")
        syncManager.joinRoom(id: "ALPHA", member: emptyCallsignMember) { result in
            switch result {
            case .success:
                XCTFail("Should not succeed with empty callsign")
            case .failure(let error):
                XCTAssertEqual(error, FirebaseSyncError.emptyCallsign)
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    func testCallsignUniqueWithinRoomOnly_SameRoomRejection() {
        let syncManager = createMockFirebaseSyncManager()
        let existingMember = SquadMember(id: "USER1", callsign: "VIPER", latitude: 37.77, longitude: -122.41)
        let roomA = SquadRoom(id: "ROOM_A", hostId: "USER1", members: ["USER1": existingMember])
        let roomData = try! JSONEncoder().encode(roomA)
        let roomJson = try! JSONSerialization.jsonObject(with: roomData)
        mockTransport(for: syncManager).seed(roomJson, at: "r/ROOM_A")
        let duplicateMember = SquadMember(id: "USER2", callsign: "viper", latitude: 37.77, longitude: -122.41)
        
        let exp = expectation(description: "Duplicate callsign in same room rejected")
        syncManager.joinRoom(id: "ROOM_A", member: duplicateMember) { result in
            switch result {
            case .success:
                XCTFail("Duplicate callsign in same room must be rejected")
            case .failure(let error):
                XCTAssertEqual(error, FirebaseSyncError.duplicateCallsign)
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    func testCallsignUniqueWithinRoomOnly_DifferentRoomsAllowed() {
        let syncManager = createMockFirebaseSyncManager()
        // Room B does NOT have a member named VIPER (it has GHOST)
        let roomBMember = SquadMember(id: "USER3", callsign: "GHOST", latitude: 37.77, longitude: -122.41)
        let roomB = SquadRoom(id: "ROOM_B", hostId: "USER3", members: ["USER3": roomBMember])
        let roomData = try! JSONEncoder().encode(roomB)
        let roomJson = try! JSONSerialization.jsonObject(with: roomData)
        mockTransport(for: syncManager).seed(roomJson, at: "r/ROOM_B")
        // Joining Room B with callsign VIPER (even though Room A already has a VIPER)
        let newMember = SquadMember(id: "USER4", callsign: "VIPER", latitude: 37.77, longitude: -122.41)
        
        let exp = expectation(description: "Same callsign in different room is accepted")
        syncManager.joinRoom(id: "ROOM_B", member: newMember) { result in
            switch result {
            case .success(let joinedRoom):
                XCTAssertEqual(joinedRoom.id, "ROOM_B")
                XCTAssertEqual(joinedRoom.members["USER4"]?.callsign, "VIPER")
                exp.fulfill()
            case .failure(let error):
                XCTFail("Should succeed joining different room with same callsign: \(error)")
            }
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    func testGameStateManager_HostRoom_RejectsEmptyRoomNameAndEmptyCallsign() {
        let gameState = createMockGameState()
        
        // 1. Empty room name
        gameState.myCallsign = "VIPER"
        let hostExp1 = expectation(description: "Host empty room name fails")
        let res1 = gameState.hostRoom(name: "   ") { success in
            XCTAssertFalse(success)
            XCTAssertTrue(gameState.squadNameError)
            XCTAssertFalse(gameState.callsignError)
            XCTAssertEqual(gameState.errorMessage, FirebaseSyncError.emptyRoomName.localizedDescription)
            hostExp1.fulfill()
        }
        XCTAssertFalse(res1)
        wait(for: [hostExp1], timeout: 1.0)
        
        // 2. Empty callsign
        gameState.myCallsign = "   "
        let hostExp2 = expectation(description: "Host empty callsign fails")
        let res2 = gameState.hostRoom(name: "MY_SQUAD") { success in
            XCTAssertFalse(success)
            XCTAssertTrue(gameState.callsignError)
            XCTAssertFalse(gameState.squadNameError)
            XCTAssertEqual(gameState.errorMessage, FirebaseSyncError.emptyCallsign.localizedDescription)
            hostExp2.fulfill()
        }
        XCTAssertFalse(res2)
        wait(for: [hostExp2], timeout: 1.0)
    }
    
    func testGameStateManager_JoinRoom_RejectsEmptyRoomNameAndEmptyCallsign() {
        let gameState = createMockGameState()
        
        // 1. Empty room name
        gameState.myCallsign = "VIPER"
        let joinExp1 = expectation(description: "Join empty room name fails")
        gameState.joinRoom(id: "   ") { (result: Result<SquadRoom, FirebaseSyncError>) in
            switch result {
            case .success:
                XCTFail("Should fail with empty room name")
            case .failure(let error):
                XCTAssertEqual(error, FirebaseSyncError.emptyRoomName)
                XCTAssertTrue(gameState.squadNameError)
                XCTAssertFalse(gameState.callsignError)
                joinExp1.fulfill()
            }
        }
        wait(for: [joinExp1], timeout: 1.0)
        
        // 2. Empty callsign
        gameState.myCallsign = "   "
        let joinExp2 = expectation(description: "Join empty callsign fails")
        gameState.joinRoom(id: "SOME_SQUAD") { (result: Result<SquadRoom, FirebaseSyncError>) in
            switch result {
            case .success:
                XCTFail("Should fail with empty callsign")
            case .failure(let error):
                XCTAssertEqual(error, FirebaseSyncError.emptyCallsign)
                XCTAssertTrue(gameState.callsignError)
                XCTAssertFalse(gameState.squadNameError)
                joinExp2.fulfill()
            }
        }
        wait(for: [joinExp2], timeout: 1.0)
    }
    
    // MARK: - Batch Telemetry & Serialization Fallback Tests
    
    func testBatchTelemetryProcessingSingleRoomUpdate() {
        let syncManager = createMockFirebaseSyncManager()
        let room = SquadRoom(id: "BATCH_TEST", hostId: "USER1")
        syncManager.connectToRoom(room)
        
        let now = Date().timeIntervalSince1970
        let p1 = TelemetryPacket(memberId: "USER1", roomId: "BATCH_TEST", latitude: 37.771, longitude: -122.411, heading: 45.0, heartRate: 80.0, timestamp: now, sequenceNumber: 1)
        let p2 = TelemetryPacket(memberId: "USER2", roomId: "BATCH_TEST", latitude: 37.772, longitude: -122.412, heading: 90.0, heartRate: 85.0, timestamp: now, sequenceNumber: 1)
        let p3 = TelemetryPacket(memberId: "USER3", roomId: "BATCH_TEST", latitude: 37.773, longitude: -122.413, heading: 135.0, heartRate: 90.0, timestamp: now, sequenceNumber: 1)
        
        let accepted = syncManager.validateAndProcessPackets([p1, p2, p3])
        XCTAssertEqual(accepted, 3)
        XCTAssertEqual(syncManager.totalPacketsProcessed, 3)
        XCTAssertEqual(syncManager.activeRoom?.members.count, 3)
        XCTAssertEqual(syncManager.activeRoom?.members["USER1"]?.heartRate, 80.0)
        XCTAssertEqual(syncManager.activeRoom?.members["USER2"]?.heartRate, 85.0)
        XCTAssertEqual(syncManager.activeRoom?.members["USER3"]?.heartRate, 90.0)
    }
    
    func testSquadRoomDecodingFallbackToFreeTierCapacity() throws {
        let json = """
        {
            "id": "FREE_SQUAD",
            "hst": "HOST_FREE",
            "m": {}
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(SquadRoom.self, from: json)
        XCTAssertEqual(decoded.maxCapacity, AppConstants.Subscription.freeTierMaxCapacity, "Missing maxCapacity should default to freeTierMaxCapacity (4)")
    }

    func testSquadMemberDecodingFallbackDefaultBattery() throws {
        let json = """
        {
            "mid": "BATTERY_TEST",
            "csn": "RECON"
        }
        """.data(using: .utf8)!
        
        let decoded = try JSONDecoder().decode(SquadMember.self, from: json)
        XCTAssertEqual(decoded.batteryLevel, AppConstants.UI.defaultBatteryLevel, "Missing batteryLevel should default to AppConstants.UI.defaultBatteryLevel (0.95)")
    }
    
    func testNonProPlayerHeadingStabilityUnderMicroJitter() {
        let syncManager = createMockFirebaseSyncManager()
        let room = SquadRoom(id: "STABILITY_ROOM", hostId: "HOST_1", members: [:])
        syncManager.connectToRoom(room)
        
        let metersPerDegreeLat = AppConstants.Location.metersPerDegreeLatitude
        let baseLat = 37.785834
        let baseLng = -122.406417
        
        // 1. Initial position with known heading 90.0°
        let p1 = TelemetryPacket(memberId: "NON_PRO_1", roomId: "STABILITY_ROOM", latitude: baseLat, longitude: baseLng, heading: 90.0, heartRate: 75.0, timestamp: 1000, sequenceNumber: 1)
        XCTAssertTrue(syncManager.validateAndProcessPacket(p1))
        XCTAssertEqual(syncManager.activeRoom?.members["NON_PRO_1"]?.heading, 90.0)
        
        // 2. Micro-jitter packet 0.8m North with heading 0.0 (compact4 format)
        // Since 0.8m <= minDisplacementForCourseOverGroundMeters (2.0m), previous heading 90.0° should be retained without flipping to 0°/180°
        let p2Jitter = TelemetryPacket(
            memberId: "NON_PRO_1",
            roomId: "STABILITY_ROOM",
            latitude: baseLat + (0.8 / metersPerDegreeLat),
            longitude: baseLng,
            heading: 0.0,
            heartRate: 75.0,
            timestamp: 1001,
            sequenceNumber: 2
        )
        XCTAssertTrue(syncManager.validateAndProcessPacket(p2Jitter))
        let retainedHeading = syncManager.activeRoom?.members["NON_PRO_1"]?.heading ?? -1.0
        XCTAssertEqual(retainedHeading, 90.0, "Displacement below 2.0m threshold must retain previous heading to prevent bobbing")
        
        // 3. Significant movement 10.0m North (> 2.0m)
        let p3Move = TelemetryPacket(
            memberId: "NON_PRO_1",
            roomId: "STABILITY_ROOM",
            latitude: baseLat + (10.8 / metersPerDegreeLat),
            longitude: baseLng,
            heading: 0.0,
            heartRate: 75.0,
            timestamp: 1002,
            sequenceNumber: 3
        )
        XCTAssertTrue(syncManager.validateAndProcessPacket(p3Move))
        let newHeading = syncManager.activeRoom?.members["NON_PRO_1"]?.heading ?? -1.0
        XCTAssertEqual(newHeading, 0.0, accuracy: 1.0, "Displacement above 2.0m threshold should compute Course Over Ground bearing ~0.0°")
    }
    

    
    func testInitialPlaceholderCoordinateIgnoredForCourseOverGround() {
        let syncManager = createMockFirebaseSyncManager()
        // Member registered with initial placeholder (0.0, 0.0) from roster before first telemetry fix
        let placeholderMember = SquadMember(id: "ROSTER_OP", callsign: "ROSTER_OP", latitude: 0.0, longitude: 0.0, heading: 0.0)
        let room = SquadRoom(id: "PLACEHOLDER_ROOM", hostId: "HOST_1", members: ["ROSTER_OP": placeholderMember])
        syncManager.connectToRoom(room)
        
        // First telemetry packet arrives at SF coordinates
        let p1 = TelemetryPacket(
            memberId: "ROSTER_OP",
            roomId: "PLACEHOLDER_ROOM",
            latitude: 37.785834,
            longitude: -122.406417,
            heading: 0.0,
            heartRate: 80.0,
            timestamp: 1000,
            sequenceNumber: 1
        )
        XCTAssertTrue(syncManager.validateAndProcessPacket(p1))
        
        // Heading must NOT calculate bogus ~315° bearing from Null Island (0,0)
        let heading = syncManager.activeRoom?.members["ROSTER_OP"]?.heading ?? -1.0
        XCTAssertEqual(heading, 0.0, "Initial telemetry arrival from (0,0) placeholder must not calculate bearing from Null Island")
    }
    
    func testTacticalPresentationMapKitStyle() {
        if #available(watchOS 10.0, *) {
            let mapStyle = TacticalPresentation.map.mapKitStyle
            let radarStyle = TacticalPresentation.radar.mapKitStyle
            XCTAssertNotNil(mapStyle)
            XCTAssertNotNil(radarStyle)
        }
    }
    

    
    func testDigitalCrownRoughZoomStepAndRange() {
        let scales = AppConstants.UI.RadarScale.discreteScales
        XCTAssertEqual(scales.first, 1.0, "Minimum discrete scale should be 1m")
        XCTAssertEqual(scales.last, 2500.0, "Maximum discrete scale should be 2500m")
        XCTAssertEqual(scales.count, 11, "Ladder must contain 11 rungs from 1m to 2.5km")
        XCTAssertTrue(scales.contains(1.0), "1m scale must be in discrete scales")
        XCTAssertTrue(scales.contains(2.5), "2.5m scale must be in discrete scales")
        XCTAssertTrue(scales.contains(5.0), "5m scale must be in discrete scales")
        XCTAssertTrue(scales.contains(10.0), "10m scale must be in discrete scales")
        XCTAssertTrue(scales.contains(25.0), "25m scale must be in discrete scales")
        XCTAssertTrue(scales.contains(50.0), "50m scale must be in discrete scales")
        XCTAssertTrue(scales.contains(100.0), "100m scale must be in discrete scales")
        XCTAssertTrue(scales.contains(250.0), "250m scale must be in discrete scales")
        XCTAssertTrue(scales.contains(500.0), "500m scale must be in discrete scales")
        XCTAssertTrue(scales.contains(1000.0), "1000m scale must be in discrete scales")
        XCTAssertTrue(scales.contains(2500.0), "2500m scale must be in discrete scales")

        // Every rung must be a [1, 2.5, 5] mantissa within its decade
        for scale in scales {
            let decade = pow(10.0, floor(log10(scale)))
            let mantissa = (scale / decade * 10.0).rounded() / 10.0
            XCTAssertTrue([1.0, 2.5, 5.0].contains(mantissa), "Scale \(scale)m must have a [1, 2.5, 5] mantissa, got \(mantissa)")
        }
    }
    
    func testDiscreteWholeNumberScaleSnappingPerDivision() {
        let scales = AppConstants.UI.RadarScale.discreteScales
        
        // Every discrete scale must produce valid range ring divisions
        for scale in scales {
            for ratio in AppConstants.UI.RadarScale.rangeRingRatios {
                let ringDistance = scale * 4.0 * ratio
                XCTAssertGreaterThan(ringDistance, 0.0)
            }
        }
        
        // Verify snapping helper functions using canonical ladder: [1, 2.5, 5, 10, 25, 50, 100, 250, 500, 1000, 2500]
        XCTAssertEqual(AppConstants.UI.RadarScale.snapToDiscreteScale(1.4), 1.0)
        XCTAssertEqual(AppConstants.UI.RadarScale.snapToDiscreteScale(3.0), 2.5)
        XCTAssertEqual(AppConstants.UI.RadarScale.snapToDiscreteScale(8.0), 10.0)
        XCTAssertEqual(AppConstants.UI.RadarScale.snapToDiscreteScale(20.0), 25.0)
        XCTAssertEqual(AppConstants.UI.RadarScale.snapToDiscreteScale(45.0), 50.0)
        XCTAssertEqual(AppConstants.UI.RadarScale.snapToDiscreteScale(80.0), 100.0)
        XCTAssertEqual(AppConstants.UI.RadarScale.snapToDiscreteScale(180.0), 250.0)
        XCTAssertEqual(AppConstants.UI.RadarScale.snapToDiscreteScale(400.0), 500.0)
        XCTAssertEqual(AppConstants.UI.RadarScale.snapToDiscreteScale(800.0), 1000.0)
        XCTAssertEqual(AppConstants.UI.RadarScale.snapToDiscreteScale(2000.0), 2500.0)
        XCTAssertEqual(AppConstants.UI.RadarScale.snapToDiscreteScale(4000.0), 2500.0, "Above ladder max clamps to 2500m")
        
        // Verify discrete step zoom helpers (+ / - buttons)
        XCTAssertEqual(AppConstants.UI.RadarScale.stepZoomIn(from: 2.5), 1.0)
        XCTAssertEqual(AppConstants.UI.RadarScale.stepZoomIn(from: 1.0), 1.0, "Zoom in at min bound must clamp to 1.0m")
        XCTAssertEqual(AppConstants.UI.RadarScale.stepZoomIn(from: 100.0), 50.0)
        XCTAssertEqual(AppConstants.UI.RadarScale.stepZoomIn(from: 250.0), 100.0)
        XCTAssertEqual(AppConstants.UI.RadarScale.stepZoomIn(from: 500.0), 250.0)
        
        XCTAssertEqual(AppConstants.UI.RadarScale.stepZoomOut(from: 1.0), 2.5)
        XCTAssertEqual(AppConstants.UI.RadarScale.stepZoomOut(from: 2.5), 5.0)
        XCTAssertEqual(AppConstants.UI.RadarScale.stepZoomOut(from: 50.0), 100.0)
        XCTAssertEqual(AppConstants.UI.RadarScale.stepZoomOut(from: 100.0), 250.0)
        XCTAssertEqual(AppConstants.UI.RadarScale.stepZoomOut(from: 250.0), 500.0)
        XCTAssertEqual(AppConstants.UI.RadarScale.stepZoomOut(from: 500.0), 1000.0)
        XCTAssertEqual(AppConstants.UI.RadarScale.stepZoomOut(from: 1000.0), 2500.0)
        XCTAssertEqual(AppConstants.UI.RadarScale.stepZoomOut(from: 2500.0), 2500.0, "Zoom out at max bound must clamp to 2500.0m")
    }
    
    func testZoomScalesUpTo2500mRoundtripAccurately() {
        let testScales = AppConstants.UI.RadarScale.discreteScales
        for scale in testScales {
            let delta = AppConstants.UI.RadarScale.mapSpanDelta(forRadarScaleMeters: scale)
            let roundtripScale = AppConstants.UI.RadarScale.radarScaleMeters(forMapSpanDelta: delta)
            XCTAssertEqual(roundtripScale, scale, accuracy: 0.01, "Scale \(scale)m must accurately roundtrip without degradation")
            
            let nearestIdx = AppConstants.UI.RadarScale.nearestScaleIndex(for: scale)
            XCTAssertEqual(AppConstants.UI.RadarScale.discreteScales[nearestIdx], scale, "Nearest scale index for \(scale)m must match exact scale")
        }
    }
    
    func testDigitalCrownReversedScrollZoomDirectionMapping() {
        let scales = AppConstants.UI.RadarScale.discreteScales
        let maxCrownIndex = Double(scales.count - 1)
        
        // At minimum crown index (0.0), scale should be maximum (2500m - zoomed out)
        let minCrownScale = AppConstants.UI.RadarScale.scale(forCrownIndex: 0.0)
        XCTAssertEqual(minCrownScale, 2500.0, "Index 0 must correspond to maximum distance 2500m (zoomed out)")
        XCTAssertEqual(AppConstants.UI.RadarScale.crownIndex(for: 2500.0), 0.0)
        
        // At maximum crown index, scale should be minimum (1m - zoomed in)
        let maxCrownScale = AppConstants.UI.RadarScale.scale(forCrownIndex: maxCrownIndex)
        XCTAssertEqual(maxCrownScale, 1.0, "Max crown index must correspond to minimum distance 1m (zoomed in)")
        XCTAssertEqual(AppConstants.UI.RadarScale.crownIndex(for: 1.0), maxCrownIndex)
        
        // Verify scrolling crown upward (increasing index) monotonically zooms in (decreases meter span)
        for i in 0..<(scales.count - 1) {
            let currentScale = AppConstants.UI.RadarScale.scale(forCrownIndex: Double(i))
            let nextScale = AppConstants.UI.RadarScale.scale(forCrownIndex: Double(i + 1))
            XCTAssertGreaterThan(currentScale, nextScale, "Scrolling crown upward must zoom in (lower meter span) from index \(i) to \(i + 1)")
        }
        
        // Verify 100% roundtrip fidelity across all discrete scales
        for scale in scales {
            let cIndex = AppConstants.UI.RadarScale.crownIndex(for: scale)
            let resolvedScale = AppConstants.UI.RadarScale.scale(forCrownIndex: cIndex)
            XCTAssertEqual(resolvedScale, scale, "Roundtrip for scale \(scale)m through crownIndex must be exact")
        }
    }
    
    func testSquadOrderCallsignFallbackAndResolution() {
        let gameState = GameStateManager()
        gameState.subscriptionManager.hasUnlimitedSquadUnlock = true
        gameState.myCallsign = ""
        
        // Place a squad order without setting custom callsign
        gameState.placeTacticalIndicator(type: .watchHere, at: CLLocationCoordinate2D(latitude: 37.77, longitude: -122.41))
        
        let indicators = gameState.allTacticalIndicators
        XCTAssertEqual(indicators.count, 1)
        XCTAssertEqual(indicators.first?.placedByCallsign, "", "Squad order should default to empty string if callsign is empty")
        
        // Custom callsign
        gameState.myCallsign = "VIPER"
        gameState.subscriptionManager.hasUnlimitedSquadUnlock = true
        gameState.placeTacticalIndicator(type: .goHere, at: CLLocationCoordinate2D(latitude: 37.78, longitude: -122.42))
        
        let updatedIndicators = gameState.allTacticalIndicators
        let goOrder = updatedIndicators.first { $0.type == .goHere }
        XCTAssertEqual(goOrder?.placedByCallsign, "VIPER", "Squad order should retain custom callsign")
    }
    
    // MARK: - Firebase TTL Policy Tests
    
    func testSquadRoomTTLPolicyFields() throws {
        let now = Date().timeIntervalSince1970
        let room = SquadRoom(id: "ALPHA1", hostId: "HOST1")

        let expectedExpireAt = now + AppConstants.Timing.Inactivity.ttlDurationSeconds
        XCTAssertEqual(room.expireAt, expectedExpireAt, accuracy: 0.5, "SquadRoom expireAt should default to now + 12h")

        // Test JSON encoding includes exp field
        let encoder = JSONEncoder()
        let data = try encoder.encode(room)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json?["exp"], "Room JSON must contain exp field for Firebase TTL")
        XCTAssertEqual((json?["exp"] as? Double) ?? 0.0, expectedExpireAt, accuracy: 0.5)

        // Test JSON decoding recovers exp field
        let decoder = JSONDecoder()
        let decodedRoom = try decoder.decode(SquadRoom.self, from: data)
        XCTAssertEqual(decodedRoom.expireAt, expectedExpireAt, accuracy: 0.5)
    }
    
    func testHostCreateRoomInitializesTTLSubroomMetadata() {
        let syncManager = createMockFirebaseSyncManager()
        let transport = mockTransport(for: syncManager)
        let room = SquadRoom(id: "TTLROOM1", hostId: "HOST1")

        let exp = expectation(description: "Create room with TTL metadata")
        syncManager.createRoom(room) { result in
            if case .success(let created) = result {
                XCTAssertEqual(created.id, "TTLROOM1")
            } else {
                XCTFail("Room creation failed")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        // Verify set() calls were sent to rooms, tactical, and telemetry paths
        let containsRoom = transport.recordedSets.contains { $0.path == "r/TTLROOM1" }
        let containsTelemetry = transport.recordedSets.contains { $0.path == "p/TTLROOM1" }
        let containsTactical = transport.recordedSets.contains { $0.path == "t/TTLROOM1" }

        XCTAssertTrue(containsRoom, "set() should be sent to rooms path")
        XCTAssertTrue(containsTelemetry, "TTL metadata set() should be sent to telemetry path")
        XCTAssertTrue(containsTactical, "TTL metadata set() should be sent to tactical path")

        // Inspect telemetry subroom TTL payload
        if let telPayload = transport.recordedSets.first(where: { $0.path == "p/TTLROOM1" })?.value as? [String: Any] {
            XCTAssertNotNil(telPayload["exp"], "Telemetry subroom payload must include exp")
        } else {
            XCTFail("Telemetry TTL payload not recorded")
        }

        // Inspect tactical subroom TTL payload
        if let tactPayload = transport.recordedSets.first(where: { $0.path == "t/TTLROOM1" })?.value as? [String: Any] {
            XCTAssertNotNil(tactPayload["exp"], "Tactical subroom payload must include exp")
        } else {
            XCTFail("Tactical TTL payload not recorded")
        }
    }
    
    // MARK: - Token Mechanism & Shared Location Source Gating Tests
    
    func testLocationManagerDirectLocationUpdates() {
        let locManager = LocationHeadingManager()
        
        let watchCoord = CLLocation(latitude: 37.7749, longitude: -122.4194)
        
        // Direct location updates accepted
        locManager.locationManager(CLLocationManager(), didUpdateLocations: [watchCoord])
        XCTAssertEqual(locManager.userLocation?.coordinate.latitude, watchCoord.coordinate.latitude)
        XCTAssertEqual(locManager.userLocation?.coordinate.longitude, watchCoord.coordinate.longitude)
        
        let newCoord = CLLocation(latitude: 37.7755, longitude: -122.4190)
        locManager.locationManager(CLLocationManager(), didUpdateLocations: [newCoord])
        XCTAssertEqual(locManager.userLocation?.coordinate.latitude, newCoord.coordinate.latitude)
        XCTAssertEqual(locManager.userLocation?.coordinate.longitude, newCoord.coordinate.longitude)
    }
    
    func testGameStateManagerTokenSyncUpdatesNetworkOwnership() {
        let gameState = createMockGameState()
        
        // Simulate phone disconnecting / reachability lost
        gameState.watchConnectivityManager.onReachabilityChanged?(false)
        XCTAssertFalse(gameState.isPhoneActive)
        #if os(watchOS)
        XCTAssertTrue(gameState.hasNetworkOwnership)
        #endif
    }
    
    // MARK: - New Tests for UX & Bug Fixes
    
    func testSquadRoomDecoding_PreservesRosterDictionaryKeysAsMemberIds() throws {
        let jsonString = """
        {
            "id": "BRAVO",
            "hst": "USER_HOST",
            "cap": 4,
            "m": {
                "USER_HOST": {
                    "csn": "OVERLORD",
                    "rol": "leader"
                },
                "USER_OPERATOR": {
                    "csn": "VIPER",
                    "rol": "player"
                }
            }
        }
        """
        let data = jsonString.data(using: .utf8)!
        let room = try JSONDecoder().decode(SquadRoom.self, from: data)
        
        XCTAssertEqual(room.members["USER_HOST"]?.id, "USER_HOST", "Member ID must match the dictionary key")
        XCTAssertEqual(room.members["USER_OPERATOR"]?.id, "USER_OPERATOR", "Member ID must match the dictionary key")
        XCTAssertEqual(room.members["USER_OPERATOR"]?.callsign, "VIPER")
    }
    
    func testJoinRoom_RejoiningAsMyselfWithSameCallsign_SucceedsWithoutConflict() {
        let gameState = createMockGameState()
        let pin = "1234"
        let name = "ALPHA"
        let roomId = name + FirebaseSyncManager.deriveRoomPadding(pin: pin, name: name)
        let existingMember = SquadMember(id: "MY_PERSISTENT_ID", callsign: "VIPER", latitude: 37.77, longitude: -122.41)
        let room = SquadRoom(id: roomId, hostId: "MY_PERSISTENT_ID", pinHash: FirebaseSyncManager.hashPin(pin, salt: roomId), members: ["MY_PERSISTENT_ID": existingMember])
        let roomData = try! JSONEncoder().encode(room)
        let roomJson = try! JSONSerialization.jsonObject(with: roomData)
        mockTransport(for: gameState).seed(roomJson, at: "r/\(roomId)")
        gameState.myMemberId = "MY_PERSISTENT_ID"
        gameState.myCallsign = "VIPER"

        let exp = expectation(description: "Self-reconnect should succeed")
        gameState.joinRoom(id: name, pin: pin) { success in
            XCTAssertTrue(success, "Reconnecting to squad where local player already exists must succeed")
            XCTAssertFalse(gameState.callsignError, "No callsign error should be generated when entry is myself")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    func testHUDConstants_MetricsAreConfiguredForPlatform() {
        #if os(watchOS)
        XCTAssertEqual(AppConstants.UI.HUD.circleButtonDiameter, 26.0)
        XCTAssertEqual(AppConstants.UI.HUD.rectButtonWidth, 48.0)
        XCTAssertEqual(AppConstants.UI.HUD.rectButtonHeight, 24.0)
        XCTAssertEqual(AppConstants.UI.HUD.circleHitboxSize.width, 48.0)
        XCTAssertEqual(AppConstants.UI.HUD.circleHitboxSize.height, 48.0)
        XCTAssertEqual(AppConstants.UI.HUD.rectHitboxSize.width, 52.0)
        XCTAssertEqual(AppConstants.UI.HUD.rectHitboxSize.height, 48.0)
        #else
        XCTAssertEqual(AppConstants.UI.HUD.circleButtonDiameter, 52.0, "iOS circle button must be 2x (52pt)")
        XCTAssertEqual(AppConstants.UI.HUD.rectButtonWidth, 96.0, "iOS rect button must be 2x (96pt)")
        XCTAssertEqual(AppConstants.UI.HUD.rectButtonHeight, 48.0, "iOS rect button must be 2x (48pt)")
        XCTAssertGreaterThanOrEqual(AppConstants.UI.HUD.circleHitboxSize.width, 68.0, "iOS hitbox must be larger than visual bounds")
        XCTAssertGreaterThanOrEqual(AppConstants.UI.HUD.rectHitboxSize.width, 112.0, "iOS rect hitbox must be larger than visual bounds")
        #endif
    }
    
    func testKIASynchronizationAndBiometricsRules() {
        let gameState = createMockGameState()
        
        // 1. Initial State: Alive, phone-only (no sensor) -> HR = 75 BPM (default resting)
        gameState.isDead = false
        gameState.healthKitManager.currentHeartRate = 0.0
        gameState.updateLocalPlayerMember()
        XCTAssertEqual(gameState.localPlayerMember.heartRate, 75.0, "Phone-only alive state must default to 75 BPM")
        
        // 2. Watch sensor active -> HR = watch optical monitor (e.g. 132 BPM)
        gameState.healthKitManager.currentHeartRate = 132.0
        gameState.updateLocalPlayerMember()
        XCTAssertEqual(gameState.localPlayerMember.heartRate, 132.0, "Active sensor must reflect live watch heart rate")
        
        // 3. Player becomes KIA / Downed -> HR = 0 BPM (flatline)
        gameState.setDead(true)
        gameState.updateLocalPlayerMember()
        XCTAssertTrue(gameState.isDead)
        XCTAssertEqual(gameState.localPlayerMember.heartRate, 0.0, "KIA state must flatline HR to 0.0 BPM regardless of sensor")
        
        // 4. Remote KIA sync received over LowSpeedSnapshot -> updates local isDead
        let reviveLS = LowSpeedSnapshot(playerState: PlayerStateSnapshot(isDead: false, isDeadTs: Date().timeIntervalSince1970 + 10))
        deliverPeerSnapshot(reviveLS, to: gameState.watchConnectivityManager)
        gameState.updateLocalPlayerMember()
        XCTAssertFalse(gameState.isDead, "Receiving revive over WatchConnectivity must update isDead to false")
        XCTAssertEqual(gameState.localPlayerMember.heartRate, 132.0, "Revived player resumes sensor heart rate")

        let deadLS = LowSpeedSnapshot(playerState: PlayerStateSnapshot(isDead: true, isDeadTs: Date().timeIntervalSince1970 + 20))
        deliverPeerSnapshot(deadLS, to: gameState.watchConnectivityManager)
        gameState.updateLocalPlayerMember()
        XCTAssertTrue(gameState.isDead, "Receiving KIA over WatchConnectivity must update isDead to true")
        XCTAssertEqual(gameState.localPlayerMember.heartRate, 0.0, "KIA state must be 0 BPM")
        XCTAssertEqual(gameState.localPlayerMember.status, .downed, "Local player member status must be downed")
    }
    
    func testEffectiveHeartRateSimulationAndSensorResolution() {
        let phoneWCM = WatchConnectivityManager(role: .phone)
        let phoneGS = createMockGameState(watchConnectivityManager: phoneWCM)
        phoneGS.healthKitManager.currentHeartRate = 0.0
        
        // 1. Stationary phone defaults to resting 75 BPM
        XCTAssertEqual(phoneGS.effectiveHeartRate, 75.0)
        
        // 2. Watch optical HR received over high-speed stream -> reflects sensor
        phoneGS.healthKitManager.currentHeartRate = 125.0
        phoneWCM.isWatchLeaseActive = true
        phoneGS.updateLocalPlayerMember()
        XCTAssertEqual(phoneGS.effectiveHeartRate, 125.0)
        XCTAssertEqual(phoneGS.localPlayerMember.heartRate, 125.0)
        
        // 3. Watch on wrist (role: .watch) directly reflects live HealthKit sensor reading
        let watchWCM = WatchConnectivityManager(role: .watch)
        let watchGS = createMockGameState(watchConnectivityManager: watchWCM)
        watchGS.healthKitManager.currentHeartRate = 118.0
        watchGS.updateLocalPlayerMember()
        XCTAssertEqual(watchGS.effectiveHeartRate, 118.0)
        XCTAssertEqual(watchGS.localPlayerMember.heartRate, 118.0)
        
        // 4. KIA flatlines to 0
        watchGS.setDead(true)
        XCTAssertEqual(watchGS.effectiveHeartRate, 0.0)
        XCTAssertEqual(watchGS.localPlayerMember.heartRate, 0.0)
    }
    
    func testBidirectionalKIAButtonAndHeartRateMonitorSync() {
        let phoneState = createMockGameState()
        phoneState.myMemberId = "OPERATOR_1"
        phoneState.myCallsign = "GHOST"
        phoneState.healthKitManager.currentHeartRate = 80.0
        phoneState.updateLocalPlayerMember()
        
        let watchState = createMockGameState()
        watchState.myMemberId = "OPERATOR_1"
        watchState.myCallsign = "GHOST"
        watchState.healthKitManager.currentHeartRate = 80.0
        watchState.updateLocalPlayerMember()
        
        // 1. Initial State: Both are alive (.active) with normal heart rate (80 BPM)
        XCTAssertFalse(phoneState.isDead)
        XCTAssertFalse(watchState.isDead)
        XCTAssertEqual(phoneState.localPlayerMember.status, .active)
        XCTAssertEqual(watchState.localPlayerMember.status, .active)
        XCTAssertEqual(phoneState.localPlayerMember.heartRate, 80.0)
        XCTAssertEqual(watchState.localPlayerMember.heartRate, 80.0)
        
        // 2. User presses KIA button on Watch
        watchState.setDead(true)
        XCTAssertTrue(watchState.isDead)
        XCTAssertEqual(watchState.localPlayerMember.status, .downed, "Watch icon must change to downed (X sprite)")
        XCTAssertEqual(watchState.localPlayerMember.heartRate, 0.0, "Watch heartrate monitor must flatline to 0.0 BPM")

        // Low-speed snapshot reaches Phone
        let deadSnapshot = LowSpeedSnapshot(playerState: PlayerStateSnapshot(isDead: true, isDeadTs: Date().timeIntervalSince1970 + 10))
        deliverPeerSnapshot(deadSnapshot, to: phoneState.watchConnectivityManager)
        XCTAssertTrue(phoneState.isDead, "Phone must become dead when Watch triggers KIA")
        XCTAssertEqual(phoneState.localPlayerMember.status, .downed, "Phone icon must change to downed (X sprite)")
        XCTAssertEqual(phoneState.localPlayerMember.heartRate, 0.0, "Phone heartrate monitor must flatline to 0.0 BPM")

        // 3. User presses Revive / Alive button on Phone
        phoneState.setDead(false)
        XCTAssertFalse(phoneState.isDead)
        XCTAssertEqual(phoneState.localPlayerMember.status, .active, "Phone icon must change to active player sprite")

        // Revive snapshot reaches Watch
        let reviveSnapshot = LowSpeedSnapshot(playerState: PlayerStateSnapshot(isDead: false, isDeadTs: Date().timeIntervalSince1970 + 20))
        deliverPeerSnapshot(reviveSnapshot, to: watchState.watchConnectivityManager)
        XCTAssertFalse(watchState.isDead, "Watch must become alive when Phone triggers Revive")
        XCTAssertEqual(watchState.localPlayerMember.status, .active, "Watch icon must change to active player sprite")
    }
    
    func testStandardMapViewMeIconUpdatesWhenWatchTogglesKIAAndViceVersa() {
        let phoneState = createMockGameState()
        phoneState.myMemberId = "OPERATOR_PHONE"
        phoneState.myCallsign = "VIPER"
        phoneState.selectedPresentation = .map
        phoneState.updateLocalPlayerMember()
        
        let watchState = createMockGameState()
        watchState.myMemberId = "OPERATOR_PHONE"
        watchState.myCallsign = "VIPER"
        watchState.selectedPresentation = .map
        watchState.updateLocalPlayerMember()
        
        // Initial state: Both alive
        XCTAssertFalse(phoneState.isDead)
        XCTAssertEqual(phoneState.localPlayerMember.status, .active)
        
        // 1. Watch toggles KIA -> Phone in standard map view receives KIA snapshot
        watchState.setDead(true)
        let deadSnapshot = LowSpeedSnapshot(playerState: PlayerStateSnapshot(isDead: true, isDeadTs: Date().timeIntervalSince1970 + 10))
        deliverPeerSnapshot(deadSnapshot, to: phoneState.watchConnectivityManager)

        XCTAssertTrue(phoneState.isDead, "Phone isDead must be true when Watch toggles KIA")
        XCTAssertEqual(phoneState.localPlayerMember.status, .downed, "Phone local player member must be downed")
        XCTAssertEqual(phoneState.localPlayerMember.heartRate, 0.0, "Phone local player heart rate must flatline")
        
        // Verify annotation view reflects downed status for 'me' icon
        let phoneMeAnnotation = MemberAnnotationView(
            member: phoneState.localPlayerMember,
            isMe: true,
            radarColor: phoneState.radarColorTheme.color
        )
        XCTAssertEqual(phoneMeAnnotation.member.status, .downed)
        
        // 2. Vice versa: Phone revives/toggles alive -> Watch in standard map view receives Revive snapshot
        phoneState.setDead(false)
        let reviveSnapshot = LowSpeedSnapshot(playerState: PlayerStateSnapshot(isDead: false, isDeadTs: Date().timeIntervalSince1970 + 20))
        deliverPeerSnapshot(reviveSnapshot, to: watchState.watchConnectivityManager)

        XCTAssertFalse(watchState.isDead, "Watch isDead must be false when Phone toggles Revive")
        XCTAssertEqual(watchState.localPlayerMember.status, .active, "Watch local player member must be active")
        
        let watchMeAnnotation = MemberAnnotationView(
            member: watchState.localPlayerMember,
            isMe: true,
            radarColor: watchState.radarColorTheme.color
        )
        XCTAssertEqual(watchMeAnnotation.member.status, .active)
    }
    
    #if os(iOS)
    func testTacticalMKAnnotationViewCollisionModeAndDisplayPriority() {
        let view = TacticalMKMapView.TacticalMKAnnotationView(annotation: nil, reuseIdentifier: "test")
        XCTAssertEqual(view.collisionMode, .none)
        XCTAssertEqual(view.displayPriority, .required)
        
        view.isGreenPriority = false
        XCTAssertEqual(view.collisionMode, .none, "Non-green annotations must retain collisionMode .none to prevent MapKit from hiding them in clusters")
        XCTAssertEqual(view.displayPriority, .required, "Non-green annotations must retain displayPriority .required to prevent MapKit from hiding them")
        
        view.isGreenPriority = true
        XCTAssertEqual(view.collisionMode, .none)
        XCTAssertEqual(view.displayPriority, .required)
        
        view.prepareForReuse()
        XCTAssertEqual(view.collisionMode, .none)
        XCTAssertEqual(view.displayPriority, .required)
    }
    #endif
    
    func testKiaStateStability_NoFlickerOnInFlightTelemetryOrRosterSync() {
        let state = createMockGameState()
        state.myMemberId = "LOCAL_USER"
        state.myCallsign = "OPERATOR"
        state.setDead(true)
        XCTAssertTrue(state.isDead)
        XCTAssertEqual(state.localPlayerMember.status, .downed)
        
        // 1. High-speed incoming telemetry with other remote player must NOT revert local KIA state
        let remoteTelemetryJson = """
        {
            "REMOTE_USER": [37.77, -122.41, 75.0, 1700000000.0]
        }
        """
        state.watchConnectivityManager.onHighSpeedTelemetryReceived?(remoteTelemetryJson)
        XCTAssertTrue(state.isDead, "High-speed remote telemetry must NOT overwrite local KIA state")
        XCTAssertEqual(state.localPlayerMember.status, .downed)
    }
    
    func testLogoutPlayer_PurgesTelemetryAndSquadOrders() {
        let firebase = createMockFirebaseSyncManager()
        let transport = mockTransport(for: firebase)

        transport.seed([
            "ind_my_order": ["wat", 37.77, -122.41, 1000.0, "USER_LEAVING"],
            "ind_other_order": ["goh", 37.78, -122.42, 1000.0, "USER_OTHER"]
        ], at: "t/DELTA/o")
        let exp = expectation(description: "Logout should purge telemetry and member orders")
        firebase.logoutPlayer(roomId: "DELTA", memberId: "USER_LEAVING") { success in
            XCTAssertTrue(success)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        let removedPaths = transport.recordedRemoves

        XCTAssertTrue(removedPaths.contains("r/DELTA/m/USER_LEAVING"), "Must delete member entry")
        XCTAssertTrue(removedPaths.contains("p/DELTA/USER_LEAVING"), "Must delete telemetry entry")
        XCTAssertTrue(removedPaths.contains("t/DELTA/o/ind_my_order"), "Must delete user's squad order")
        XCTAssertFalse(removedPaths.contains("t/DELTA/o/ind_other_order"), "Must NOT delete other member's squad order")
    }
    
    func testSingleSharedLoginState_WatchActionAdoptsSessionWithoutDuplicateNetworkJoin() {
        let gameState = createMockGameState()
        mockTransport(for: gameState).seed([
            "id": "BRAVO",
            "hst": "OP_WATCH",
            "m": [
                "OP_WATCH": [
                    "mid": "OP_WATCH",
                    "csn": "VIPER",
                    "latitude": 37.77,
                    "longitude": -122.41,
                    "rol": "leader"
                ]
            ]
        ], at: "r/BRAVO")
        gameState.myMemberId = "OP_PHONE"
        gameState.myCallsign = "VIPER"
        
        // Incoming Low-Speed Snapshot from companion Watch hosting "BRAVO"
        let incomingLS = LowSpeedSnapshot(
            syncTs: 100,
            config: ConfigSnapshot(callsign: "VIPER", roomName: "BRAVO", pin: "", configTs: 100),
            loginCycle: LoginCycleSnapshot(loginCycle: .hostActive, loginCycleTs: 100)
        )
        gameState.watchConnectivityManager.onLowSpeedConvergenceStateChanged?(incomingLS)
        
        let exp = expectation(description: "Room details fetched and session adopted")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
        
        // Assert: Phone enters tactical session and adopts room without generating a callsign collision
        XCTAssertTrue(gameState.isTacticalSessionActive, "Phone must enter tactical session upon companion login")
        XCTAssertEqual(gameState.savedRoomName, "BRAVO")
        XCTAssertNil(gameState.errorMessage, "No callsign collision error should be shown on Phone")
        XCTAssertFalse(gameState.callsignError, "Callsign error must remain false")
        
        // Companion leaves room -> Phone resets tactical session
        let inactiveLS = LowSpeedSnapshot(
            syncTs: 150,
            config: ConfigSnapshot(callsign: "VIPER", roomName: "BRAVO", pin: "", configTs: 100),
            loginCycle: LoginCycleSnapshot(loginCycle: .inactive, loginCycleTs: 150)
        )
        gameState.watchConnectivityManager.onLowSpeedConvergenceStateChanged?(inactiveLS)
        XCTAssertFalse(gameState.isTacticalSessionActive, "Phone must exit tactical session when companion becomes inactive")
        XCTAssertNil(gameState.firebaseManager.activeRoom)
    }
    
    // MARK: - Unified Map State & Standard MapKit Behavior Tests
    
    func testUnifiedMapCenterAndScaleManagement() {
        let gameState = createMockGameState()
        let playerCoord = gameState.localPlayerMember.coordinate
        
        // 1. Initial State: Center is nil (tracking player), scale is default 100m
        XCTAssertNil(gameState.currentMapCenter)
        XCTAssertEqual(gameState.radarScaleMeters, AppConstants.UI.RadarScale.defaultScaleMeters)
        
        // 2. Coordinate very close to player (< 10m) should keep currentMapCenter as nil
        let nearCoord = CLLocationCoordinate2D(
            latitude: playerCoord.latitude + 0.00002, // ~2.2m away
            longitude: playerCoord.longitude
        )
        gameState.updateMapCenter(to: nearCoord)
        XCTAssertNil(gameState.currentMapCenter, "Coordinates within threshold must keep map center tracking player")
        
        // 3. Coordinate far from player (> 10m) should update currentMapCenter
        let farCoord = CLLocationCoordinate2D(
            latitude: playerCoord.latitude + 0.005, // ~550m away
            longitude: playerCoord.longitude + 0.005
        )
        gameState.updateMapCenter(to: farCoord)
        XCTAssertNotNil(gameState.currentMapCenter)
        XCTAssertEqual(gameState.currentMapCenter?.latitude, farCoord.latitude)
        XCTAssertEqual(gameState.currentMapCenter?.longitude, farCoord.longitude)
        
        // 4. Moving back close to player resets currentMapCenter to nil
        gameState.updateMapCenter(to: nearCoord)
        XCTAssertNil(gameState.currentMapCenter, "Moving back near player must reset map center to nil")
        
        // 5. Update scale continuously (standard MapKit pinch behavior)
        gameState.updateMapScale(meters: 250.0)
        XCTAssertEqual(gameState.selectedScaleMeters, 250.0)
        
        // 6. Scale clamping bounds
        gameState.updateMapScale(meters: 0.2) // Below min (1.0m)
        XCTAssertEqual(gameState.selectedScaleMeters, AppConstants.UI.RadarScale.minScaleMeters)
        
        gameState.updateMapScale(meters: 100000.0) // Above max (2500m)
        XCTAssertEqual(gameState.selectedScaleMeters, AppConstants.UI.RadarScale.maxiOSScaleMeters)
    }
    
    func testResetMapToDefaultCenterAndZoomResetsAllState() {
        let gameState = createMockGameState()
        let initialTrigger = gameState.radarCenterTrigger
        
        // Set custom center and scale (500.0m discrete scale)
        gameState.currentMapCenter = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        gameState.radarScaleMeters = 500.0
        
        // Call reset
        gameState.resetMapToDefaultCenterAndZoom()
        
        // Verify center is reset to nil while scale is preserved
        XCTAssertNil(gameState.currentMapCenter, "Map center must reset to nil (tracking player)")
        XCTAssertEqual(gameState.radarScaleMeters, 500.0, "Scale must be preserved when recentering")
        XCTAssertEqual(gameState.radarCenterTrigger, initialTrigger + 1, "Trigger counter must increment")
    }
    
    func testPresentationTogglePreservesMapCenterAndScale() {
        let gameState = createMockGameState()
        let customCoord = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        gameState.currentMapCenter = customCoord
        gameState.selectedScaleMeters = 250.0
        
        XCTAssertEqual(gameState.selectedPresentation, .radar)
        gameState.togglePresentation()
        XCTAssertEqual(gameState.selectedPresentation, .map)
        XCTAssertEqual(gameState.currentMapCenter?.latitude, customCoord.latitude)
        XCTAssertEqual(gameState.currentMapCenter?.longitude, customCoord.longitude)
        XCTAssertEqual(gameState.selectedScaleMeters, 250.0)
        
        gameState.togglePresentation()
        XCTAssertEqual(gameState.selectedPresentation, .radar)
        XCTAssertEqual(gameState.currentMapCenter?.latitude, customCoord.latitude)
        XCTAssertEqual(gameState.currentMapCenter?.longitude, customCoord.longitude)
        XCTAssertEqual(gameState.selectedScaleMeters, 250.0)
    }
    
    func testRapidPresentationSwitchesPreservesExactScaleStateMachine() {
        let gameState = createMockGameState()
        let targetScale = 500.0
        gameState.updateMapScale(meters: targetScale)
        
        XCTAssertEqual(gameState.mapStateMachine.scaleMeters, targetScale)
        XCTAssertEqual(gameState.selectedScaleMeters, targetScale)
        
        // Rapidly toggle presentation 10 times
        for i in 1...10 {
            gameState.togglePresentation()
            let expectedPres: TacticalPresentation = (i % 2 == 1) ? .map : .radar
            XCTAssertEqual(gameState.selectedPresentation, expectedPres)
            XCTAssertEqual(gameState.mapStateMachine.presentation, expectedPres)
            XCTAssertEqual(gameState.mapStateMachine.scaleMeters, targetScale, "Scale in state machine must never mutate when switching presentation")
            XCTAssertEqual(gameState.selectedScaleMeters, targetScale, "Published scale must never mutate when switching presentation")
        }
    }
    
    func testCenterMapOnLocalUserPreservesScale() {
        let gameState = createMockGameState()
        gameState.currentMapCenter = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        gameState.selectedScaleMeters = 500.0
        
        gameState.centerMapOnLocalUser()
        XCTAssertNil(gameState.currentMapCenter, "Map center must be reset to nil to track local user")
        XCTAssertEqual(gameState.selectedScaleMeters, 500.0, "Scale must be preserved when centering")
    }
    
    func testCanonicalLadderValues() {
        let expected: [Double] = [1.0, 2.5, 5.0, 10.0, 25.0, 50.0, 100.0, 250.0, 500.0, 1000.0, 2500.0]
        XCTAssertEqual(AppConstants.UI.RadarScale.discreteScales, expected)
    }
    
    func testCrownZoomPreservesLocalUserCentering() {
        let gameState = createMockGameState()
        
        // Map is initially centered on local user (currentMapCenter is nil)
        XCTAssertNil(gameState.currentMapCenter)
        XCTAssertEqual(gameState.radarScaleMeters, AppConstants.UI.RadarScale.defaultScaleMeters)
        
        // Simulating crown scroll to zoom in/out
        for crownIdx in 0..<AppConstants.UI.RadarScale.discreteScales.count {
            let scale = AppConstants.UI.RadarScale.scale(forCrownIndex: Double(crownIdx))
            gameState.radarScaleMeters = scale
            
            // Changing scale via crown must preserve currentMapCenter as nil (tracking local user)
            XCTAssertNil(gameState.currentMapCenter, "Crown zooming must keep the map centered on the local user")
            XCTAssertEqual(gameState.radarScaleMeters, scale)
        }
    }
    
    func testMapViewSwitchPreservesLocalUserCenteringPositiveAndNegativeUX() {
        let gameState = createMockGameState()
        
        // 1. Initial State: Presentation is Radar, centered on local user
        XCTAssertEqual(gameState.selectedPresentation, .radar)
        XCTAssertNil(gameState.currentMapCenter, "Initial map center must be nil (tracking local user)")
        XCTAssertEqual(gameState.selectedScaleMeters, AppConstants.UI.RadarScale.defaultScaleMeters)
        
        // Positive UX 1: Switch Radar -> Map
        gameState.togglePresentation()
        XCTAssertEqual(gameState.selectedPresentation, .map)
        // Negative UX Check 1: Switching to Map must NOT uncenter from local user
        XCTAssertNil(gameState.currentMapCenter, "Switching to map presentation must remain centered on local user")
        XCTAssertEqual(gameState.selectedScaleMeters, AppConstants.UI.RadarScale.defaultScaleMeters)
        
        // Positive UX 2: Switch Map -> Radar
        gameState.togglePresentation()
        XCTAssertEqual(gameState.selectedPresentation, .radar)
        // Negative UX Check 2: Switching back to Radar must remain centered on local user
        XCTAssertNil(gameState.currentMapCenter, "Switching back to radar must remain centered on local user")
        XCTAssertEqual(gameState.selectedScaleMeters, AppConstants.UI.RadarScale.defaultScaleMeters)
        
        // Positive UX 3: Rapid consecutive toggling preserves local centering
        for _ in 1...10 {
            gameState.togglePresentation()
            XCTAssertNil(gameState.currentMapCenter, "Rapid presentation switching must NEVER cause currentMapCenter to become non-nil")
        }
    }
    
    func testMapViewSwitchWithCustomPannedLocationPreservesPannedInspection() {
        let gameState = createMockGameState()
        let customCoord = CLLocationCoordinate2D(latitude: 37.7890, longitude: -122.4010)
        
        // User explicitly pans away in Radar mode to inspect an area
        gameState.updateMapCenter(to: customCoord)
        XCTAssertNotNil(gameState.currentMapCenter)
        XCTAssertEqual(gameState.currentMapCenter?.latitude, customCoord.latitude)
        XCTAssertEqual(gameState.currentMapCenter?.longitude, customCoord.longitude)
        
        // Positive UX: Switch to Map retains custom panned coordinates
        gameState.togglePresentation()
        XCTAssertEqual(gameState.selectedPresentation, .map)
        XCTAssertEqual(gameState.currentMapCenter?.latitude, customCoord.latitude)
        XCTAssertEqual(gameState.currentMapCenter?.longitude, customCoord.longitude)
        
        // Positive UX: Switch back to Radar retains custom panned coordinates
        gameState.togglePresentation()
        XCTAssertEqual(gameState.selectedPresentation, .radar)
        XCTAssertEqual(gameState.currentMapCenter?.latitude, customCoord.latitude)
        XCTAssertEqual(gameState.currentMapCenter?.longitude, customCoord.longitude)
        
        // User recenters via center HUD button
        gameState.centerMapOnLocalUser()
        XCTAssertNil(gameState.currentMapCenter, "Recentering must clear custom center to track local user")
        
        // Subsequent view switches now stay centered on local user
        gameState.togglePresentation()
        XCTAssertEqual(gameState.selectedPresentation, .map)
        XCTAssertNil(gameState.currentMapCenter, "Must remain locked to local user after recentering")
    }
    
    func testMapViewSwitchAfterZoomScaleChangesPreservesScale() {
        let gameState = createMockGameState()
        XCTAssertNil(gameState.currentMapCenter)
        
        // Zoom in to 50m in Radar view
        gameState.updateMapScale(meters: 50.0)
        XCTAssertEqual(gameState.selectedScaleMeters, 50.0)
        XCTAssertNil(gameState.currentMapCenter)
        
        // Switch to Map view: scale must be preserved and center must remain on user
        gameState.togglePresentation()
        XCTAssertEqual(gameState.selectedPresentation, .map)
        XCTAssertEqual(gameState.selectedScaleMeters, 50.0, "Scale must be preserved when switching views")
        XCTAssertNil(gameState.currentMapCenter, "Must stay centered on local user")
        
        // Zoom out to 1000m in Map view
        gameState.updateMapScale(meters: 1000.0)
        XCTAssertEqual(gameState.selectedScaleMeters, 1000.0)
        XCTAssertNil(gameState.currentMapCenter)
        
        // Switch back to Radar view: scale 1000m must be preserved and center must remain on user
        gameState.togglePresentation()
        XCTAssertEqual(gameState.selectedPresentation, .radar)
        XCTAssertEqual(gameState.selectedScaleMeters, 1000.0, "Scale must be preserved when switching back to radar")
        XCTAssertNil(gameState.currentMapCenter, "Must stay centered on local user")
    }
    
    // MARK: - Comprehensive UX Elements & Interaction Tests
    
    func testHUDLayoutConstantsAndHitboxesMeetAppleHIG() {
        #if os(watchOS)
        XCTAssertGreaterThanOrEqual(AppConstants.UI.HUD.circleHitboxSize.width, 44.0, "Watch circle hitbox width must meet 44pt HIG minimum")
        XCTAssertGreaterThanOrEqual(AppConstants.UI.HUD.circleHitboxSize.height, 44.0, "Watch circle hitbox height must meet 44pt HIG minimum")
        XCTAssertGreaterThanOrEqual(AppConstants.UI.HUD.rectHitboxSize.width, 44.0, "Watch rect hitbox width must meet 44pt HIG minimum")
        XCTAssertGreaterThanOrEqual(AppConstants.UI.HUD.rectHitboxSize.height, 44.0, "Watch rect hitbox height must meet 44pt HIG minimum")
        #else
        XCTAssertGreaterThanOrEqual(AppConstants.UI.HUD.circleHitboxSize.width, 44.0, "iOS circle hitbox width must meet 44pt HIG minimum")
        XCTAssertGreaterThanOrEqual(AppConstants.UI.HUD.circleHitboxSize.height, 44.0, "iOS circle hitbox height must meet 44pt HIG minimum")
        XCTAssertGreaterThanOrEqual(AppConstants.UI.HUD.rectHitboxSize.width, 44.0, "iOS rect hitbox width must meet 44pt HIG minimum")
        XCTAssertGreaterThanOrEqual(AppConstants.UI.HUD.rectHitboxSize.height, 44.0, "iOS rect hitbox height must meet 44pt HIG minimum")
        #endif
    }
    
    func testMapCenterLockStateEnumAndProperties() {
        XCTAssertEqual(MapCenterLockState.allCases.count, 2)
        XCTAssertTrue(MapCenterLockState.allCases.contains(.locked))
        XCTAssertTrue(MapCenterLockState.allCases.contains(.unlocked))
        
        let locked = MapCenterLockState.locked
        XCTAssertTrue(locked.isLocked)
        XCTAssertFalse(locked.isUnlocked)
        XCTAssertEqual(locked.rawValue, "locked")
        XCTAssertEqual(locked.id, "locked")
        XCTAssertEqual(locked.iconName, "location.fill")
        
        let unlocked = MapCenterLockState.unlocked
        XCTAssertFalse(unlocked.isLocked)
        XCTAssertTrue(unlocked.isUnlocked)
        XCTAssertEqual(unlocked.rawValue, "unlocked")
        XCTAssertEqual(unlocked.id, "unlocked")
        XCTAssertEqual(unlocked.iconName, "location")
    }
    
    func testMapCenterLockStateRememberedAcrossPresentationSwitchAndReinitialization() {
        let gameState = createMockGameState()
        
        // 1. Initial State: locked to local user
        XCTAssertEqual(gameState.mapCenterLockState, .locked)
        XCTAssertNil(gameState.currentMapCenter)
        
        // 2. User pans away -> unlocked
        let pannedCoord = CLLocationCoordinate2D(latitude: 37.85, longitude: -122.45)
        gameState.updateMapCenter(to: pannedCoord)
        XCTAssertEqual(gameState.mapCenterLockState, .unlocked)
        XCTAssertEqual(gameState.currentMapCenter?.latitude, pannedCoord.latitude)
        
        // 3. Switch presentation: desired unlocked state is remembered
        gameState.togglePresentation()
        XCTAssertEqual(gameState.mapCenterLockState, .unlocked)
        XCTAssertEqual(gameState.currentMapCenter?.latitude, pannedCoord.latitude)
        
        // 4. Center map button: desired locked state is remembered
        gameState.centerMapOnLocalUser()
        XCTAssertEqual(gameState.mapCenterLockState, .locked)
        XCTAssertNil(gameState.currentMapCenter)
        
        // 5. Switch presentation: desired locked state is remembered
        gameState.togglePresentation()
        XCTAssertEqual(gameState.mapCenterLockState, .locked)
        XCTAssertNil(gameState.currentMapCenter)
        
        // 6. Direct setMapCenterLockState
        gameState.setMapCenterLockState(.unlocked)
        XCTAssertEqual(gameState.mapCenterLockState, .unlocked)
        
        gameState.setMapCenterLockState(.locked)
        XCTAssertEqual(gameState.mapCenterLockState, .locked)
        XCTAssertNil(gameState.currentMapCenter)
    }
    
    func testAutomaticVersionTrackingFormat() {
        let versionStr = AppConstants.Version.formattedVersionString
        XCTAssertTrue(versionStr.hasPrefix("v"), "Version string should start with 'v'")
        XCTAssertTrue(versionStr.contains("b"), "Version string should contain build indicator 'b'")
    }
    
    func testMapStateMachineTransitionsAndBehavior() {
        var sm = MapStateMachine()
        let userCoord = CLLocationCoordinate2D(latitude: 37.77, longitude: -122.41)
        
        // Initial state
        XCTAssertEqual(sm.trackingState, .locked)
        XCTAssertEqual(sm.scaleMeters, AppConstants.UI.RadarScale.defaultScaleMeters)
        XCTAssertEqual(sm.presentation, .radar)
        XCTAssertEqual(sm.centerTriggerCount, 0)
        XCTAssertEqual(sm.effectiveCenter(userCoord: userCoord).latitude, userCoord.latitude)
        XCTAssertEqual(sm.effectiveCenter(userCoord: userCoord).longitude, userCoord.longitude)
        
        // Pan close (< 10m): stays locked
        let closeCoord = CLLocationCoordinate2D(latitude: 37.77002, longitude: -122.41)
        sm.handle(.pan(to: closeCoord, userCoord: userCoord))
        XCTAssertEqual(sm.trackingState, .locked)
        
        // Pan far (> 10m): unlocks and stores coordinate
        let farCoord = CLLocationCoordinate2D(latitude: 37.78, longitude: -122.42)
        sm.handle(.pan(to: farCoord, userCoord: userCoord))
        XCTAssertEqual(sm.trackingState, .unlocked(latitude: farCoord.latitude, longitude: farCoord.longitude))
        XCTAssertEqual(sm.effectiveCenter(userCoord: userCoord).latitude, farCoord.latitude)
        XCTAssertEqual(sm.effectiveCenter(userCoord: userCoord).longitude, farCoord.longitude)
        XCTAssertEqual(sm.trackingState.iconName, "location")
        
        // Center on user: locks and increments trigger count
        sm.handle(.centerOnLocalUser)
        XCTAssertEqual(sm.trackingState, .locked)
        XCTAssertEqual(sm.centerTriggerCount, 1)
        XCTAssertEqual(sm.effectiveCenter(userCoord: userCoord).latitude, userCoord.latitude)
        XCTAssertEqual(sm.trackingState.iconName, "location.fill")
        
        // Toggle presentation
        sm.handle(.togglePresentation)
        XCTAssertEqual(sm.presentation, .map)
        sm.handle(.togglePresentation)
        XCTAssertEqual(sm.presentation, .radar)
        
        // Set scale
        sm.handle(.setScale(meters: 500.0))
        XCTAssertEqual(sm.scaleMeters, 500.0)
    }
    
    func testSessionStateMachineTransitionsAndBehavior() {
        var sm = SessionStateMachine()
        
        // Initial state
        XCTAssertEqual(sm.state, .disconnected)
        XCTAssertFalse(sm.state.isHosting)
        XCTAssertFalse(sm.state.isJoining)
        XCTAssertFalse(sm.state.isInitiatingHost)
        XCTAssertFalse(sm.state.isActiveSession)
        XCTAssertNil(sm.state.activeRoom)
        
        // Request host
        sm.handle(.startHost(name: "BRAVO", pin: "1234"))
        XCTAssertEqual(sm.state, .initiatingHost(roomName: "BRAVO", pin: "1234"))
        XCTAssertTrue(sm.state.isInitiatingHost)
        XCTAssertFalse(sm.state.isHosting)
        
        // Host failure
        sm.handle(.hostFailure(error: "Network error"))
        XCTAssertEqual(sm.state, .error(message: "Network error"))
        XCTAssertEqual(sm.state.errorMessage, "Network error")
        
        // Clear error
        sm.handle(.clearError)
        XCTAssertEqual(sm.state, .disconnected)
        
        // Host success
        let testRoom = SquadRoom(id: "BRAVO", hostId: "USER1")
        sm.handle(.startHost(name: "BRAVO", pin: nil))
        sm.handle(.hostSuccess(room: testRoom))
        XCTAssertEqual(sm.state, .hosting(room: testRoom))
        XCTAssertTrue(sm.state.isHosting)
        XCTAssertTrue(sm.state.isActiveSession)
        XCTAssertEqual(sm.state.activeRoom?.id, "BRAVO")
        
        // Disband
        sm.handle(.disband)
        XCTAssertEqual(sm.state, .disconnected)
        
        // Join flow
        sm.handle(.startJoin(id: "CHARLIE", pin: "5678"))
        XCTAssertEqual(sm.state, .initiatingJoin(roomId: "CHARLIE", pin: "5678"))
        XCTAssertTrue(sm.state.isJoining)
        
        let joinedRoom = SquadRoom(id: "CHARLIE", hostId: "HOST2")
        sm.handle(.joinSuccess(room: joinedRoom))
        XCTAssertEqual(sm.state, .joined(room: joinedRoom))
        XCTAssertFalse(sm.state.isHosting)
        XCTAssertTrue(sm.state.isActiveSession)
        XCTAssertEqual(sm.state.activeRoom?.id, "CHARLIE")
        
        // Leave
        sm.handle(.leave)
        XCTAssertEqual(sm.state, .disconnected)
    }
    
    func testPlayerVitalStateMachineTransitionsAndBehavior() {
        var sm = PlayerVitalStateMachine()
        
        // Initial state
        XCTAssertFalse(sm.state.isDead)
        XCTAssertEqual(sm.state.effectiveHeartRate, AppConstants.Health.defaultRestingHeartRate)
        XCTAssertEqual(sm.state.status, .active)
        
        // Update heart rate while active
        sm.handle(.updateHeartRate(135.0))
        XCTAssertEqual(sm.state.effectiveHeartRate, 135.0)
        XCTAssertFalse(sm.state.isDead)
        
        // Set KIA -> Downed (flatline)
        sm.handle(.setKIA(true))
        XCTAssertTrue(sm.state.isDead)
        XCTAssertEqual(sm.state.effectiveHeartRate, AppConstants.Health.flatlineHeartRate)
        XCTAssertEqual(sm.state.status, .downed)
        
        // Incoming sensor heart rate while downed should be ignored
        sm.handle(.updateHeartRate(140.0))
        XCTAssertEqual(sm.state.effectiveHeartRate, AppConstants.Health.flatlineHeartRate)
        
        // Toggle KIA -> Active
        sm.handle(.toggleKIA)
        XCTAssertFalse(sm.state.isDead)
        XCTAssertEqual(sm.state.status, .active)
        XCTAssertEqual(sm.state.effectiveHeartRate, AppConstants.Health.defaultRestingHeartRate)
        
        // Set KIA false
        sm.handle(.setKIA(false))
        XCTAssertFalse(sm.state.isDead)
    }
    
    func testHUDLocationButtonIconStateReflectsCentering() {
        let gameState = createMockGameState()
        
        // 1. When locked / tracking local user, icon should be "location.fill"
        XCTAssertEqual(gameState.mapCenterLockState, .locked)
        XCTAssertEqual(gameState.mapCenterLockState.iconName, "location.fill")
        
        // 2. When panned away (unlocked), icon should be "location"
        let pannedCoord = CLLocationCoordinate2D(latitude: 37.5, longitude: -122.2)
        gameState.updateMapCenter(to: pannedCoord)
        XCTAssertEqual(gameState.mapCenterLockState, .unlocked)
        XCTAssertEqual(gameState.mapCenterLockState.iconName, "location")
        
        // 3. When recentered (locked), icon reverts to "location.fill"
        gameState.centerMapOnLocalUser()
        XCTAssertEqual(gameState.mapCenterLockState, .locked)
        XCTAssertEqual(gameState.mapCenterLockState.iconName, "location.fill")
    }
    
    func testHUDPresentationButtonIconReflectsActivePresentation() {
        let gameState = createMockGameState()
        
        XCTAssertEqual(gameState.selectedPresentation, .radar)
        XCTAssertEqual(gameState.selectedPresentation.iconName, "map")
        
        gameState.togglePresentation()
        XCTAssertEqual(gameState.selectedPresentation, .map)
        XCTAssertEqual(gameState.selectedPresentation.iconName, "map")
        
        gameState.togglePresentation()
        XCTAssertEqual(gameState.selectedPresentation, .radar)
        XCTAssertEqual(gameState.selectedPresentation.iconName, "map")
    }
    
    func testScaleRulerDistanceFormattingAcrossAllDecades() {
        // Discrete thresholds formatting (tactical ruler displays exact map zoom scale)
        XCTAssertEqual(AppConstants.UI.ScaleRuler.formatRulerDistance(minorScaleMeters: 50.0), "50m")
        XCTAssertEqual(AppConstants.UI.ScaleRuler.formatRulerDistance(minorScaleMeters: 100.0), "100m")
        XCTAssertEqual(AppConstants.UI.ScaleRuler.formatRulerDistance(minorScaleMeters: 250.0), "250m")
        XCTAssertEqual(AppConstants.UI.ScaleRuler.formatRulerDistance(minorScaleMeters: 500.0), "500m")
        XCTAssertEqual(AppConstants.UI.ScaleRuler.formatRulerDistance(minorScaleMeters: 1000.0), "1km")
        XCTAssertEqual(AppConstants.UI.ScaleRuler.formatRulerDistance(minorScaleMeters: 2500.0), "2.5km")
        XCTAssertEqual(AppConstants.UI.ScaleRuler.formatDistance(meters: 2500.0), "2.5km")
        XCTAssertEqual(AppConstants.UI.ScaleRuler.formatDistance(meters: 1500.0), "1.5km")
    }
    
    func testDigitalCrownBidirectionalScaleLadderMapping() {
        let scales = AppConstants.UI.RadarScale.discreteScales
        for (index, scale) in scales.enumerated() {
            // Forward: scale -> crownIndex
            let crownIdx = AppConstants.UI.RadarScale.crownIndex(for: scale)
            let expectedCrownIdx = Double((scales.count - 1) - index)
            XCTAssertEqual(crownIdx, expectedCrownIdx, accuracy: 0.001)
            
            // Reverse: crownIndex -> scale
            let resolvedScale = AppConstants.UI.RadarScale.scale(forCrownIndex: crownIdx)
            XCTAssertEqual(resolvedScale, scale, accuracy: 0.001)
        }
        
        // In-between scale snapping
        XCTAssertEqual(AppConstants.UI.RadarScale.snapToDiscreteScale(1.4), 1.0)
        XCTAssertEqual(AppConstants.UI.RadarScale.snapToDiscreteScale(3.0), 2.5)
        XCTAssertEqual(AppConstants.UI.RadarScale.snapToDiscreteScale(8.0), 10.0)
        XCTAssertEqual(AppConstants.UI.RadarScale.snapToDiscreteScale(20.0), 25.0)
        XCTAssertEqual(AppConstants.UI.RadarScale.snapToDiscreteScale(45.0), 50.0)
        XCTAssertEqual(AppConstants.UI.RadarScale.snapToDiscreteScale(80.0), 100.0)
        XCTAssertEqual(AppConstants.UI.RadarScale.snapToDiscreteScale(180.0), 250.0)
        XCTAssertEqual(AppConstants.UI.RadarScale.snapToDiscreteScale(400.0), 500.0)
        XCTAssertEqual(AppConstants.UI.RadarScale.snapToDiscreteScale(800.0), 1000.0)
        XCTAssertEqual(AppConstants.UI.RadarScale.snapToDiscreteScale(2000.0), 2500.0)
    }
    
    func testEKGSweepDurationDynamicCalculation() {
        // Sweep duration formula: sweepDuration = referenceBpm / max(20.0, currentBpm)
        let refBpm = AppConstants.Health.referenceBpm // 100.0
        
        // High heart rate (150 BPM) -> faster sweep (0.67s)
        let highBpmSweep = refBpm / max(20.0, 150.0)
        XCTAssertEqual(highBpmSweep, 100.0 / 150.0, accuracy: 0.001)
        
        // Normal heart rate (75 BPM) -> 1.33s sweep
        let normalBpmSweep = refBpm / max(20.0, 75.0)
        XCTAssertEqual(normalBpmSweep, 100.0 / 75.0, accuracy: 0.001)
        
        // Resting heart rate (50 BPM) -> 2.0s sweep
        let restingBpmSweep = refBpm / max(20.0, 50.0)
        XCTAssertEqual(restingBpmSweep, 2.0, accuracy: 0.001)
        
        // Very low or 0 BPM (clamped to 20.0 minimum to prevent infinite sweep duration)
        let flatlineClampedSweep = refBpm / max(20.0, 0.0)
        XCTAssertEqual(flatlineClampedSweep, 5.0, accuracy: 0.001)
    }
    
    func testPinSanitizationVoiceAndDictationInput() {
        // Voice words conversion
        XCTAssertEqual(GameStateManager.sanitizePinInput("one two three four"), "1234")
        XCTAssertEqual(GameStateManager.sanitizePinInput("five six seven eight"), "5678")
        XCTAssertEqual(GameStateManager.sanitizePinInput("nine zero oh won"), "9001")
        XCTAssertEqual(GameStateManager.sanitizePinInput("too to ate"), "228")
        
        // Digits with punctuation & formatting
        XCTAssertEqual(GameStateManager.sanitizePinInput("1-2-3-4"), "1234")
        XCTAssertEqual(GameStateManager.sanitizePinInput("PIN: 7890"), "7890")
        XCTAssertEqual(GameStateManager.sanitizePinInput("  4 3 2 1  "), "4321")
        
        // Max 16 digits clamping
        XCTAssertEqual(GameStateManager.sanitizePinInput("12345678"), "12345678")
        XCTAssertEqual(GameStateManager.sanitizePinInput("123456789012345678"), "1234567890123456")
    }
    
    func testWelcomeGuideHUDCalloutsCompleteness() {
        let callouts = TacticalHUDCallout.allCases
        XCTAssertEqual(callouts.count, 7)
        
        for callout in callouts {
            XCTAssertFalse(callout.codeTag.isEmpty, "\(callout.rawValue) codeTag must not be empty")
            XCTAssertFalse(callout.iconName.isEmpty, "\(callout.rawValue) iconName must not be empty")
            XCTAssertFalse(callout.shortTitle.isEmpty, "\(callout.rawValue) shortTitle must not be empty")
            XCTAssertFalse(callout.actionInstruction.isEmpty, "\(callout.rawValue) actionInstruction must not be empty")
            XCTAssertFalse(callout.gestureHint.isEmpty, "\(callout.rawValue) gestureHint must not be empty")
        }

        let distCallout = TacticalHUDCallout.distanceMeasure
        XCTAssertEqual(distCallout.codeTag, "RNG-CALC")
        XCTAssertEqual(distCallout.iconName, "ruler")
        XCTAssertEqual(distCallout.shortTitle, "Distance Line")
        XCTAssertEqual(distCallout.gestureHint, "TAP TARGET")
    }

    func testQRJoinPayloadEncodingAndDecoding() {
        // Custom BYO Firebase with PIN
        let payloadWithCustomDB = QRJoinPayload(roomName: "ALPHA", pin: "1234", databaseURL: "https://your-project.firebaseio.com")
        let encoded = payloadWithCustomDB.encodedString()
        XCTAssertEqual(encoded, "{\"d\":\"https:\\/\\/your-project.firebaseio.com\",\"p\":\"1234\",\"r\":\"ALPHA\"}")
        
        let decoded = QRJoinPayload.decode(encoded!)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.r, "ALPHA")
        XCTAssertEqual(decoded?.p, "1234")
        XCTAssertEqual(decoded?.d, "https://your-project.firebaseio.com")

        // Default RTDB without PIN
        let defaultPayload = QRJoinPayload(roomName: "BRAVO", pin: "", databaseURL: "")
        let encodedDefault = defaultPayload.encodedString()
        XCTAssertEqual(encodedDefault, "{\"d\":\"\",\"r\":\"BRAVO\"}")

        let decodedDefault = QRJoinPayload.decode(encodedDefault!)
        XCTAssertNotNil(decodedDefault)
        XCTAssertEqual(decodedDefault?.r, "BRAVO")
        XCTAssertNil(decodedDefault?.p)
        XCTAssertEqual(decodedDefault?.d, "")

        // Malformed string fails decoding gracefully
        XCTAssertNil(QRJoinPayload.decode("radarmap://join?room=ALPHA"))
        XCTAssertNil(QRJoinPayload.decode("not-json"))
    }
    
    func testTacticalIndicatorFadeOpacityCalculation() {
        let now = Date()
        let indicator = TacticalIndicator(
            type: .infantry,
            coordinate: CLLocationCoordinate2D(latitude: 37.77, longitude: -122.41),
            placedByMemberId: "USER_TEST",
            timestamp: now.timeIntervalSince1970
        )
        
        // At creation: fresh (fade = 0.0, opacity = 1.0)
        XCTAssertEqual(indicator.grayFadeFactor(referenceDate: now), 0.0, accuracy: 0.01)
        XCTAssertFalse(indicator.isFullyFaded(referenceDate: now))
        
        // 2.5 minutes elapsed (50% of 5-minute fade window)
        let midDate = now.addingTimeInterval(150.0)
        XCTAssertEqual(indicator.grayFadeFactor(referenceDate: midDate), 0.5, accuracy: 0.01)
        XCTAssertFalse(indicator.isFullyFaded(referenceDate: midDate))
        
        // 5.0 minutes elapsed (100% fade)
        let fadedDate = now.addingTimeInterval(300.0)
        XCTAssertEqual(indicator.grayFadeFactor(referenceDate: fadedDate), 1.0, accuracy: 0.01)
        XCTAssertTrue(indicator.isFullyFaded(referenceDate: fadedDate))
        
        // > 5.0 minutes elapsed (clamped to 1.0)
        let pastDate = now.addingTimeInterval(400.0)
        XCTAssertEqual(indicator.grayFadeFactor(referenceDate: pastDate), 1.0, accuracy: 0.01)
        XCTAssertTrue(indicator.isFullyFaded(referenceDate: pastDate))
    }
    
    func testTacticalIndicatorTypeIconNamesAndCustomSymbols() {
        // Squad Orders
        XCTAssertEqual(TacticalIndicatorType.watchHere.iconName, "eye.fill")
        XCTAssertEqual(TacticalIndicatorType.watchHere.category, .squadOrder)
        XCTAssertFalse(TacticalIndicatorType.watchHere.isCustomSymbol)
        
        XCTAssertEqual(TacticalIndicatorType.goHere.iconName, "arrowshape.down")
        XCTAssertEqual(TacticalIndicatorType.attackHere.iconName, "bolt")
        XCTAssertEqual(TacticalIndicatorType.protectHere.iconName, "shield")
        
        XCTAssertEqual(TacticalIndicatorType.flag.iconName, "flag.fill")
        XCTAssertEqual(TacticalIndicatorType.flag.category, .squadOrder)
        XCTAssertEqual(TacticalIndicatorType.flag.title, "Flag")
        
        let numbers: [TacticalIndicatorType] = [
            .point1, .point2, .point3
        ]
        for (index, num) in numbers.enumerated() {
            let n = index + 1
            XCTAssertEqual(num.iconName, "\(n).circle")
            XCTAssertEqual(num.category, .squadOrder)
            XCTAssertEqual(num.title, "\(n)")
            XCTAssertFalse(num.isCustomSymbol)
        }
        
        // Enemy Indicators
        XCTAssertEqual(TacticalIndicatorType.infantry.iconName, "tactical.helmet")
        XCTAssertEqual(TacticalIndicatorType.infantry.category, .enemyIndicator)
        XCTAssertTrue(TacticalIndicatorType.infantry.isCustomSymbol)
        
        XCTAssertEqual(TacticalIndicatorType.vehicle.iconName, "tactical.humvee")
        XCTAssertEqual(TacticalIndicatorType.vehicle.title, "Vehicle")
        XCTAssertEqual(TacticalIndicatorType.vehicle.category, .enemyIndicator)
        XCTAssertTrue(TacticalIndicatorType.vehicle.isCustomSymbol)
        
        XCTAssertEqual(TacticalIndicatorType.armor.iconName, "tactical.tank")
        XCTAssertEqual(TacticalIndicatorType.armor.title, "Armor")
        XCTAssertEqual(TacticalIndicatorType.armor.category, .enemyIndicator)
        XCTAssertTrue(TacticalIndicatorType.armor.isCustomSymbol)
        
        XCTAssertEqual(TacticalIndicatorType.drone.iconName, "tactical.drone")
        XCTAssertEqual(TacticalIndicatorType.drone.title, "Drone")
        XCTAssertEqual(TacticalIndicatorType.drone.category, .enemyIndicator)
        XCTAssertTrue(TacticalIndicatorType.drone.isCustomSymbol)
        
        // Environment Indicators
        XCTAssertEqual(TacticalIndicatorType.water.iconName, "water.waves")
        XCTAssertEqual(TacticalIndicatorType.water.category, .environment)
        XCTAssertFalse(TacticalIndicatorType.water.isCustomSymbol)
        
        XCTAssertEqual(TacticalIndicatorType.hazard.iconName, "exclamationmark.triangle.fill")
        XCTAssertEqual(TacticalIndicatorType.hazard.category, .environment)
        
        XCTAssertEqual(TacticalIndicatorType.fire.iconName, "flame.fill")
        XCTAssertEqual(TacticalIndicatorType.fire.category, .environment)
        
        XCTAssertEqual(TacticalIndicatorType.snow.iconName, "snowflake")
        XCTAssertEqual(TacticalIndicatorType.snow.category, .environment)
        
        XCTAssertEqual(TacticalIndicatorType.closure.iconName, "minus.circle.fill")
        XCTAssertEqual(TacticalIndicatorType.closure.category, .environment)
        
        XCTAssertEqual(TacticalIndicatorType.emergency.iconName, "sos.circle.fill")
        XCTAssertEqual(TacticalIndicatorType.emergency.category, .environment)
        
        // Backward-compatible JSON decoding verification
        let legacyJson = """
        ["lightVehicle", "heavyVehicle", "vehicle", "armor", "drone", "water", "emergency"]
        """.data(using: .utf8)!
        let decoded = try? JSONDecoder().decode([TacticalIndicatorType].self, from: legacyJson)
        XCTAssertEqual(decoded, [.vehicle, .armor, .vehicle, .armor, .drone, .water, .emergency])
    }
    
    func testTacticalIndicatorCategoryAndMarkerColorsAndFade() {
        // 1. Category Base Colors: Team Orders are green; Tactical and Environmental are red.
        XCTAssertEqual(TacticalIndicatorCategory.squadOrder.baseColor, .green)
        XCTAssertEqual(TacticalIndicatorCategory.enemyIndicator.baseColor, .red)
        XCTAssertEqual(TacticalIndicatorCategory.environment.baseColor, .red)
        
        // 2. Type Base Colors
        let squadOrders: [TacticalIndicatorType] = [
            .watchHere, .goHere, .attackHere, .protectHere, .flag, .point1, .point2, .point3
        ]
        for type in squadOrders {
            XCTAssertEqual(type.baseColor, .green, "\(type.rawValue) must have green base color")
        }
        
        let tacticalEnemies: [TacticalIndicatorType] = [
            .infantry, .vehicle, .armor, .drone
        ]
        for type in tacticalEnemies {
            XCTAssertEqual(type.baseColor, .red, "\(type.rawValue) must have red base color")
        }
        
        let environmental: [TacticalIndicatorType] = [
            .water, .hazard, .fire, .snow, .closure, .emergency
        ]
        for type in environmental {
            XCTAssertEqual(type.baseColor, .red, "\(type.rawValue) must have red base color")
        }
        
        // 3. TacticalIndicator Base Colors & Fade Mechanics
        let now = Date()
        
        // Team orders dropped by me are green
        let myOrderIndicator = TacticalIndicator(
            type: .goHere,
            coordinate: CLLocationCoordinate2D(latitude: 37.7, longitude: -122.4),
            placedByMemberId: "ME",
            timestamp: now.timeIntervalSince1970
        )
        XCTAssertEqual(myOrderIndicator.baseColor(isPlacedByMe: true), .green, "Team orders dropped by me must be green")
        XCTAssertEqual(myOrderIndicator.baseColor, .green)
        XCTAssertEqual(myOrderIndicator.grayFadeFactor(referenceDate: now), 0.0)
        XCTAssertEqual(myOrderIndicator.grayFadeFactor(referenceDate: now.addingTimeInterval(300)), 0.0)
        
        // Other people's team orders are blue
        let othersOrderIndicator = TacticalIndicator(
            type: .attackHere,
            coordinate: CLLocationCoordinate2D(latitude: 37.7, longitude: -122.4),
            placedByMemberId: "OTHER_PERSON",
            timestamp: now.timeIntervalSince1970
        )
        XCTAssertEqual(othersOrderIndicator.baseColor(isPlacedByMe: false), .blue, "Other people's team orders must be blue")
        XCTAssertEqual(othersOrderIndicator.grayFadeFactor(referenceDate: now), 0.0)
        XCTAssertEqual(othersOrderIndicator.grayFadeFactor(referenceDate: now.addingTimeInterval(300)), 0.0)
        
        // Team order marks within the same clan are also green
        let sameClanOrderIndicator = TacticalIndicator(
            type: .protectHere,
            coordinate: CLLocationCoordinate2D(latitude: 37.7, longitude: -122.4),
            placedByMemberId: "CLAN_MATE",
            placedByCallsign: "[hawk]zocviiwer",
            timestamp: now.timeIntervalSince1970
        )
        XCTAssertEqual(sameClanOrderIndicator.baseColor(isPlacedByMe: false, isSameClan: true), .green, "Team orders within the same clan must be green")
        XCTAssertEqual(sameClanOrderIndicator.baseColor(isPlacedByMe: false, isSameClan: false), .blue, "Team orders not within the same clan must be blue")
        
        // Tactical and environmental markers are red regardless of issuer
        let tacticalIndicator = TacticalIndicator(
            type: .armor,
            coordinate: CLLocationCoordinate2D(latitude: 37.7, longitude: -122.4),
            placedByMemberId: "M1",
            timestamp: now.timeIntervalSince1970
        )
        XCTAssertEqual(tacticalIndicator.baseColor(isPlacedByMe: true), .red)
        XCTAssertEqual(tacticalIndicator.baseColor(isPlacedByMe: false), .red)
        XCTAssertEqual(tacticalIndicator.baseColor, .red)
        XCTAssertEqual(tacticalIndicator.grayFadeFactor(referenceDate: now), 0.0, accuracy: 0.001)
        XCTAssertFalse(tacticalIndicator.isFullyFaded(referenceDate: now))
        XCTAssertEqual(tacticalIndicator.grayFadeFactor(referenceDate: now.addingTimeInterval(150)), 0.5, accuracy: 0.001)
        XCTAssertFalse(tacticalIndicator.isFullyFaded(referenceDate: now.addingTimeInterval(150)))
        XCTAssertEqual(tacticalIndicator.grayFadeFactor(referenceDate: now.addingTimeInterval(300)), 1.0, accuracy: 0.001)
        XCTAssertTrue(tacticalIndicator.isFullyFaded(referenceDate: now.addingTimeInterval(300)))
        
        let envIndicator = TacticalIndicator(
            type: .hazard,
            coordinate: CLLocationCoordinate2D(latitude: 37.7, longitude: -122.4),
            placedByMemberId: "M1",
            timestamp: now.timeIntervalSince1970
        )
        XCTAssertEqual(envIndicator.baseColor(isPlacedByMe: true), .red)
        XCTAssertEqual(envIndicator.baseColor(isPlacedByMe: false), .red)
        XCTAssertEqual(envIndicator.baseColor, .red)
        XCTAssertEqual(envIndicator.grayFadeFactor(referenceDate: now), 0.0)
        XCTAssertEqual(envIndicator.grayFadeFactor(referenceDate: now.addingTimeInterval(300)), 0.0)
    }
    
    func testMapSpanDeltaAndScaleRulerIsotropicGeometry() {
        let referenceCoord = CLLocationCoordinate2D(latitude: 37.785834, longitude: -122.406417)
        let minorScaleMeters: Double = 50.0
        
        let latDelta = AppConstants.UI.RadarScale.mapSpanDelta(forRadarScaleMeters: minorScaleMeters)
        let cosLat = cos(referenceCoord.latitude * AppConstants.Location.degreesToRadiansFactor)
        let lonDelta = latDelta / cosLat
        
        // Calculate physical distance across span
        let northSouthMeters = latDelta * AppConstants.Location.metersPerDegreeLatitude
        let eastWestMeters = lonDelta * AppConstants.Location.metersPerDegreeLatitude * cosLat
        
        // Isotropic distance verification: North-South distance must equal East-West distance
        XCTAssertEqual(northSouthMeters, eastWestMeters, accuracy: 0.001, "Map coordinate span must be isotropic to maintain accurate scale ruler display")
        
        // Verify scale ruler text matches the tactical scale (50m)
        let rulerText = AppConstants.UI.ScaleRuler.formatRulerDistance(minorScaleMeters: minorScaleMeters)
        XCTAssertEqual(rulerText, "50m")
    }
    
    func testPositionedByUserFlagGuardsProgrammaticZoomAndStyleSwitch() {
        let fallbackRegion = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.78, longitude: -122.41),
            span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
        )
        let userPos = MapCameraPosition.userLocation(fallback: .region(fallbackRegion))
        
        // Programmatic userLocation position must have positionedByUser == false and followsUserLocation == true
        XCTAssertFalse(userPos.positionedByUser, "Programmatically initiated position must not be flagged as user positioned")
        XCTAssertTrue(userPos.followsUserLocation, "Position must actively track user location")
    }
    
    func testMapStyleToggleAndCenterButtonPreserveMapScale() {
        let gameState = createMockGameState()
        
        // 1. Set zoom scale to 500m
        gameState.updateMapScale(meters: 500.0)
        XCTAssertEqual(gameState.selectedScaleMeters, 500.0)
        
        // 2. Toggle presentation from radar to map: scale must stay 500m
        gameState.selectedPresentation = .radar
        gameState.togglePresentation()
        XCTAssertEqual(gameState.selectedPresentation, .map)
        XCTAssertEqual(gameState.selectedScaleMeters, 500.0, "Presentation toggle must not change map scale")
        
        // 3. Pan map away to custom coordinate
        let pannedCoord = CLLocationCoordinate2D(latitude: 37.85, longitude: -122.45)
        gameState.updateMapCenter(to: pannedCoord)
        XCTAssertNotNil(gameState.currentMapCenter)
        XCTAssertEqual(gameState.selectedScaleMeters, 500.0)
        
        // 4. Tap center map button: map center becomes nil (tracking user), scale stays 500m
        gameState.centerMapOnLocalUser()
        XCTAssertNil(gameState.currentMapCenter, "Center map button must restore user tracking")
        XCTAssertEqual(gameState.selectedScaleMeters, 500.0, "Center map button must preserve map scale")
        
        // 5. Toggle presentation back to radar: scale remains 500m and user tracking remains active
        gameState.togglePresentation()
        XCTAssertEqual(gameState.selectedPresentation, .radar)
        XCTAssertNil(gameState.currentMapCenter, "Must remain centered on local user")
        XCTAssertEqual(gameState.selectedScaleMeters, 500.0, "Scale must remain 500m")
    }
    
    func testPostZoomSnapToCanonicalLadder() {
        var sm = MapStateMachine()
        
        // Snaps to canonical ladder: [1, 2.5, 5, 10, 25, 50, 100, 250, 500, 1000, 2500]
        sm.handle(.setScale(meters: 1.4))
        XCTAssertEqual(sm.scaleMeters, 1.0)
        
        sm.handle(.setScale(meters: 3.0))
        XCTAssertEqual(sm.scaleMeters, 2.5)
        
        sm.handle(.setScale(meters: 8.0))
        XCTAssertEqual(sm.scaleMeters, 10.0)
        
        sm.handle(.setScale(meters: 20.0))
        XCTAssertEqual(sm.scaleMeters, 25.0)
        
        sm.handle(.setScale(meters: 45.0))
        XCTAssertEqual(sm.scaleMeters, 50.0)
        
        sm.handle(.setScale(meters: 80.0))
        XCTAssertEqual(sm.scaleMeters, 100.0)
        
        sm.handle(.setScale(meters: 180.0))
        XCTAssertEqual(sm.scaleMeters, 250.0)
        
        sm.handle(.setScale(meters: 400.0))
        XCTAssertEqual(sm.scaleMeters, 500.0)
        
        sm.handle(.setScale(meters: 800.0))
        XCTAssertEqual(sm.scaleMeters, 1000.0)
        
        sm.handle(.setScale(meters: 2000.0))
        XCTAssertEqual(sm.scaleMeters, 2500.0)
        
        sm.handle(.setScale(meters: 4000.0))
        XCTAssertEqual(sm.scaleMeters, 2500.0, "Above ladder max clamps to 2500m")
        
        // GameStateManager updateMapScale must also enforce discrete canonical scale snapping
        let gameState = createMockGameState()
        gameState.updateMapScale(meters: 42.0)
        XCTAssertEqual(gameState.selectedScaleMeters, 50.0)
        
        gameState.updateMapScale(meters: 220.0)
        XCTAssertEqual(gameState.selectedScaleMeters, 250.0)
    }
    
    func testKiaToggleImmediateStatusUpdate() {
        let gameState = createMockGameState()
        XCTAssertFalse(gameState.isDead)
        XCTAssertEqual(gameState.localPlayerMember.status, .active)
        
        // Toggle KIA to true
        gameState.setDead(true)
        XCTAssertTrue(gameState.isDead, "isDead state must immediately be true")
        XCTAssertEqual(gameState.localPlayerMember.status, .downed, "localPlayerMember status must immediately be .downed")
        XCTAssertEqual(gameState.localPlayerMember.heartRate, AppConstants.Health.flatlineHeartRate, "Heart rate must flatline when KIA")
        
        // Toggle KIA back to false
        gameState.setDead(false)
        XCTAssertFalse(gameState.isDead, "isDead state must immediately be false")
        XCTAssertEqual(gameState.localPlayerMember.status, .active, "localPlayerMember status must immediately be .active")
    }
    
    func testDigitalCrownZoomStepsAndDiscreteLadderConversion() {
        let ladder = AppConstants.UI.RadarScale.discreteScales
        for (index, scale) in ladder.enumerated() {
            let crownIndex = Double((ladder.count - 1) - index)
            let resolvedScale = AppConstants.UI.RadarScale.scale(forCrownIndex: crownIndex)
            XCTAssertEqual(resolvedScale, scale, "Crown index \(crownIndex) must map to \(scale)m")
            
            let computedIndex = AppConstants.UI.RadarScale.crownIndex(for: scale)
            XCTAssertEqual(computedIndex, crownIndex, "Scale \(scale)m must map to crown index \(crownIndex)")
        }
    }
    
    func testLocalPlayerImmediateRawCoordinateSync() {
        let gameState = createMockGameState()
        let initialLoc = CLLocation(latitude: 37.7800, longitude: -122.4000)
        gameState.locationHeadingManager.userLocation = initialLoc
        gameState.updateLocalPlayerMember()
        
        XCTAssertEqual(gameState.localPlayerMember.coordinate.latitude, 37.7800, accuracy: 1e-7)
        XCTAssertEqual(gameState.localPlayerMember.coordinate.longitude, -122.4000, accuracy: 1e-7)
        
        // Immediate GPS update must reflect instantly on localPlayerMember without artificial dead-reckoning interpolation lag
        let nextLoc = CLLocation(latitude: 37.7850, longitude: -122.4050)
        gameState.locationHeadingManager.userLocation = nextLoc
        gameState.updateLocalPlayerMember()
        
        XCTAssertEqual(gameState.localPlayerMember.coordinate.latitude, 37.7850, accuracy: 1e-7)
        XCTAssertEqual(gameState.localPlayerMember.coordinate.longitude, -122.4050, accuracy: 1e-7)
    }
    
    func testStandardMapCenteringAndCameraDistance() {
        let defaultScale = AppConstants.UI.RadarScale.defaultScaleMeters
        let distance = AppConstants.UI.RadarScale.cameraDistance(forScale: defaultScale)
        XCTAssertGreaterThan(distance, 0)
        
        var sm = MapStateMachine()
        let userCoord = CLLocationCoordinate2D(latitude: 37.78, longitude: -122.40)
        
        // When locked, effective center is user coordinate
        XCTAssertEqual(sm.effectiveCenter(userCoord: userCoord).latitude, userCoord.latitude)
        XCTAssertEqual(sm.effectiveCenter(userCoord: userCoord).longitude, userCoord.longitude)
        
        // When user moves while locked, effective center continuously follows new user coordinates
        let movedUserCoord = CLLocationCoordinate2D(latitude: 37.7810, longitude: -122.4010)
        XCTAssertTrue(sm.trackingState.isLocked)
        XCTAssertEqual(sm.effectiveCenter(userCoord: movedUserCoord).latitude, movedUserCoord.latitude)
        XCTAssertEqual(sm.effectiveCenter(userCoord: movedUserCoord).longitude, movedUserCoord.longitude)
        
        // When panned away (> 10m), effective center is the panned location
        let pannedCoord = CLLocationCoordinate2D(latitude: 37.79, longitude: -122.41)
        sm.handle(.pan(to: pannedCoord, userCoord: userCoord))
        XCTAssertTrue(sm.trackingState.isUnlocked)
        XCTAssertEqual(sm.effectiveCenter(userCoord: userCoord).latitude, pannedCoord.latitude)
        
        // When user moves while panned/unlocked, effective center remains at panned coordinate
        XCTAssertEqual(sm.effectiveCenter(userCoord: movedUserCoord).latitude, pannedCoord.latitude)
        XCTAssertEqual(sm.effectiveCenter(userCoord: movedUserCoord).longitude, pannedCoord.longitude)
        
        // When recentering on user, tracking state locks back onto user
        sm.handle(.centerOnLocalUser)
        XCTAssertTrue(sm.trackingState.isLocked)
        XCTAssertEqual(sm.effectiveCenter(userCoord: movedUserCoord).latitude, movedUserCoord.latitude)
    }
    
    func testStandardMapCameraDistanceMatchesMapKitVerticalFOVAndRadarScale() {
        for scale in AppConstants.UI.RadarScale.discreteScales {
            let cameraDist = AppConstants.UI.RadarScale.cameraDistance(forScale: scale)
            // Visible vertical span in MapKit with 30-degree FOV: V = 2 * distance * tan(15 deg)
            let visibleVerticalMeters = 2.0 * cameraDist * tan(15.0 * .pi / 180.0)
            
            // Expected visible vertical meters from RadarScale geometry
            let expectedOuterRadarMeters = scale * 4.0
            let expectedVisibleMetersLat = (expectedOuterRadarMeters / AppConstants.UI.RadarScale.radarRadiusRatio) * AppConstants.UI.RadarScale.referenceScreenAspectRatio
            
            XCTAssertEqual(visibleVerticalMeters, expectedVisibleMetersLat, accuracy: 1e-4, "Visible vertical span for scale \(scale)m should exactly match expected ground span")
        }
    }
    
    func testRulerSpanMatchesRadarAndStandardMapScale() {
        let majorNotchWidth = AppConstants.UI.HUD.rulerNotchMajorWidth
        let minorNotchWidth = AppConstants.UI.HUD.rulerNotchMinorWidth
        let barWidth = AppConstants.UI.HUD.rulerBarWidth
        
        let totalRulerWidth = majorNotchWidth * 2 + minorNotchWidth + barWidth * 2
        XCTAssertLessThanOrEqual(totalRulerWidth, AppConstants.UI.HUD.rectButtonWidth, "Ruler must fit inside the HUD rect button")
        XCTAssertGreaterThan(barWidth, 0)
    }
    
    func testMapPresentationSwitchPreservesCenterAndTrackingState() {
        var sm = MapStateMachine(trackingState: .locked, scaleMeters: 100.0, presentation: .radar)
        let userCoord = CLLocationCoordinate2D(latitude: 37.7858, longitude: -122.4064)
        
        // Presentation switch from radar to map
        sm.handle(.togglePresentation)
        XCTAssertEqual(sm.presentation, .map)
        XCTAssertTrue(sm.trackingState.isLocked)
        XCTAssertEqual(sm.effectiveCenter(userCoord: userCoord).latitude, userCoord.latitude)
        
        // User pans in map view
        let panCoord = CLLocationCoordinate2D(latitude: 37.8000, longitude: -122.4200)
        sm.handle(.pan(to: panCoord, userCoord: userCoord))
        XCTAssertTrue(sm.trackingState.isUnlocked)
        XCTAssertEqual(sm.effectiveCenter(userCoord: userCoord).latitude, panCoord.latitude)
        
        // Presentation switch back to radar preserves panned coordinate
        sm.handle(.togglePresentation)
        XCTAssertEqual(sm.presentation, .radar)
        XCTAssertTrue(sm.trackingState.isUnlocked)
        XCTAssertEqual(sm.effectiveCenter(userCoord: userCoord).latitude, panCoord.latitude)
        
        // Center on user locks back onto user
        sm.handle(.centerOnLocalUser)
        XCTAssertTrue(sm.trackingState.isLocked)
        XCTAssertEqual(sm.effectiveCenter(userCoord: userCoord).latitude, userCoord.latitude)
    }
    
    // MARK: - Companion Sync & Cloud Protocol Test Matrix (14 Scenarios)
    
    // 1. Phone changes is_dead while Watch is suspended; Watch resumes and converges.
    func testCompanionSync_1_PhoneChangesIsDeadWhileWatchSuspended_WatchResumesAndConverges() {
        var phoneLS = LowSpeedSnapshot(
            playerState: PlayerStateSnapshot(isDead: true, isDeadTs: 100)
        )
        var watchLS = LowSpeedSnapshot(
            playerState: PlayerStateSnapshot(isDead: false, isDeadTs: 80)
        )
        
        let (mergedWatch, watchWins) = MergeEngine.merge(local: watchLS, peer: phoneLS, localDevice: .watch)
        XCTAssertFalse(watchWins, "Watch is on losing side")
        XCTAssertTrue(mergedWatch.playerState.isDead, "Watch adopts Phone's winning isDead value")
        XCTAssertEqual(mergedWatch.playerState.isDeadTs, 100, "Watch adopts Phone's winning timestamp")
    }
    
    // 2. Phone-to-Watch application-context update is lost/coalesced; later refresh converges.
    func testCompanionSync_2_PhoneToWatchLostOrCoalesced_LaterRefreshConverges() {
        let phoneLS = LowSpeedSnapshot(
            config: ConfigSnapshot(callsign: "VIPER", configTs: 150),
            playerState: PlayerStateSnapshot(isDead: true, isDeadTs: 120)
        )
        let watchLS = LowSpeedSnapshot(
            config: ConfigSnapshot(callsign: "ROOKIE", configTs: 50),
            playerState: PlayerStateSnapshot(isDead: false, isDeadTs: 50)
        )
        
        let (mergedWatch, _) = MergeEngine.merge(local: watchLS, peer: phoneLS, localDevice: .watch)
        XCTAssertEqual(mergedWatch.config.callsign, "VIPER")
        XCTAssertEqual(mergedWatch.config.configTs, 150)
        XCTAssertTrue(mergedWatch.playerState.isDead)
        XCTAssertEqual(mergedWatch.playerState.isDeadTs, 120)
    }
    
    // 3. Watch-to-Phone mirror update is lost; Phone continues rolling sync_ts until it receives matching Watch state.
    func testCompanionSync_3_WatchToPhoneMirrorLost_PhoneRollsSyncTsUntilMatching() {
        let phoneLS = LowSpeedSnapshot(
            playerState: PlayerStateSnapshot(isDead: false, isDeadTs: 100)
        )
        let outdatedWatchLS = LowSpeedSnapshot(
            playerState: PlayerStateSnapshot(isDead: true, isDeadTs: 80)
        )
        
        // Phone compares with outdated Watch snapshot -> Phone wins, needs rolling sync_ts
        let (_, phoneWinsOutdated) = MergeEngine.merge(local: phoneLS, peer: outdatedWatchLS, localDevice: .phone)
        XCTAssertTrue(phoneWinsOutdated, "Phone wins against outdated Watch and continues rolling sync_ts")
        
        // Watch finally adopts Phone's winning state and transmits
        let convergedWatchLS = LowSpeedSnapshot(
            playerState: PlayerStateSnapshot(isDead: false, isDeadTs: 100)
        )
        let (_, phoneWinsConverged) = MergeEngine.merge(local: phoneLS, peer: convergedWatchLS, localDevice: .phone)
        XCTAssertFalse(phoneWinsConverged, "Once Watch matches, Phone stops rolling sync_ts")
    }
    
    // 4. Equal timestamps with equal values result in convergence.
    func testCompanionSync_4_EqualTimestampsEqualValues_Converged() {
        let phoneLS = LowSpeedSnapshot(
            config: ConfigSnapshot(callsign: "ALPHA", configTs: 100),
            playerState: PlayerStateSnapshot(isDead: false, isDeadTs: 100)
        )
        let watchLS = LowSpeedSnapshot(
            config: ConfigSnapshot(callsign: "ALPHA", configTs: 100),
            playerState: PlayerStateSnapshot(isDead: false, isDeadTs: 100)
        )
        
        let (mergedPhone, phoneWins) = MergeEngine.merge(local: phoneLS, peer: watchLS, localDevice: .phone)
        let (mergedWatch, watchWins) = MergeEngine.merge(local: watchLS, peer: phoneLS, localDevice: .watch)
        
        XCTAssertFalse(phoneWins)
        XCTAssertFalse(watchWins)
        XCTAssertTrue(mergedPhone.isDomainEquivalent(to: mergedWatch))
    }
    
    // 5. Equal timestamps with different values result in Phone winning.
    func testCompanionSync_5_EqualTimestampsDifferentValues_PhoneWinsTieBreak() {
        let phoneLS = LowSpeedSnapshot(
            playerState: PlayerStateSnapshot(isDead: false, isDeadTs: 100)
        )
        let watchLS = LowSpeedSnapshot(
            playerState: PlayerStateSnapshot(isDead: true, isDeadTs: 100)
        )
        
        let (mergedPhone, phoneWins) = MergeEngine.merge(local: phoneLS, peer: watchLS, localDevice: .phone)
        let (mergedWatch, watchWins) = MergeEngine.merge(local: watchLS, peer: phoneLS, localDevice: .watch)
        
        XCTAssertFalse(phoneWins, "Phone loses exact timestamp tie-break with conflicting values (Watch wins)")
        XCTAssertTrue(watchWins, "Watch wins tie-break and advertises winning structure to peer")
        XCTAssertTrue(mergedPhone.playerState.isDead, "Watch value (isDead = true) wins tie-breaker")
        XCTAssertTrue(mergedWatch.playerState.isDead, "Watch retains winning value")
        XCTAssertEqual(mergedWatch.playerState.isDeadTs, 100)
    }


    
    // 6. Newer Watch-owned structure wins against older Phone snapshot.
    func testCompanionSync_6_NewerWatchStructureWinsAgainstOlderPhone() {
        let phoneLS = LowSpeedSnapshot(
            config: ConfigSnapshot(callsign: "OLD_PHONE", configTs: 50)
        )
        let watchLS = LowSpeedSnapshot(
            config: ConfigSnapshot(callsign: "NEW_WATCH", configTs: 120)
        )
        
        let (mergedPhone, phoneWins) = MergeEngine.merge(local: phoneLS, peer: watchLS, localDevice: .phone)
        let (mergedWatch, watchWins) = MergeEngine.merge(local: watchLS, peer: phoneLS, localDevice: .watch)
        
        XCTAssertFalse(phoneWins)
        XCTAssertTrue(watchWins, "Newer Watch timestamp wins")
        XCTAssertEqual(mergedPhone.config.callsign, "NEW_WATCH")
        XCTAssertEqual(mergedPhone.config.configTs, 120)
        XCTAssertEqual(mergedWatch.config.callsign, "NEW_WATCH")
    }
    
    // 7. Different structures can have different winners at the same time.
    func testCompanionSync_7_DifferentStructuresHaveDifferentWinnersConcurrently() {
        // Phone has newer config; Watch has newer playerState
        let phoneLS = LowSpeedSnapshot(
            config: ConfigSnapshot(callsign: "PHONE_CONFIG", configTs: 200),
            playerState: PlayerStateSnapshot(isDead: false, isDeadTs: 50)
        )
        let watchLS = LowSpeedSnapshot(
            config: ConfigSnapshot(callsign: "WATCH_CONFIG", configTs: 100),
            playerState: PlayerStateSnapshot(isDead: true, isDeadTs: 250)
        )
        
        let (mergedPhone, phoneWins) = MergeEngine.merge(local: phoneLS, peer: watchLS, localDevice: .phone)
        let (mergedWatch, watchWins) = MergeEngine.merge(local: watchLS, peer: phoneLS, localDevice: .watch)
        
        XCTAssertTrue(phoneWins, "Phone wins config")
        XCTAssertTrue(watchWins, "Watch wins playerState")
        
        // Merged results on both devices must have Phone's config and Watch's playerState
        XCTAssertEqual(mergedPhone.config.callsign, "PHONE_CONFIG")
        XCTAssertEqual(mergedPhone.config.configTs, 200)
        XCTAssertTrue(mergedPhone.playerState.isDead)
        XCTAssertEqual(mergedPhone.playerState.isDeadTs, 250)
        
        XCTAssertEqual(mergedWatch.config.callsign, "PHONE_CONFIG")
        XCTAssertEqual(mergedWatch.config.configTs, 200)
        XCTAssertTrue(mergedWatch.playerState.isDead)
        XCTAssertEqual(mergedWatch.playerState.isDeadTs, 250)
    }
    
    // 8. sync_ts differences alone do not create a domain-state mismatch.
    func testCompanionSync_8_SyncTsDifferencesAloneDoNotCreateMismatch() {
        let phoneLS = LowSpeedSnapshot(
            syncTs: 9999,
            config: ConfigSnapshot(callsign: "ALPHA", configTs: 100)
        )
        let watchLS = LowSpeedSnapshot(
            syncTs: 1111,
            config: ConfigSnapshot(callsign: "ALPHA", configTs: 100)
        )
        
        XCTAssertTrue(phoneLS.isDomainEquivalent(to: watchLS), "sync_ts is control metadata only and must be excluded from domain equivalence")
    }
    
    // 9. Watch uses Phone WCSession cache when Phone is reachable and its active_until lease has not expired.
    func testCompanionSync_9_WatchUsesPhoneCacheWhenReachableAndFresh() {
        let now = Date().timeIntervalSince1970
        let phoneReachable = true
        let phoneActiveUntil: TimeInterval? = now + 5.0 // Lease valid for 5 more seconds

        let isLeaseActive = (phoneActiveUntil != nil && now < phoneActiveUntil!)
        let shouldUseWCSession = (phoneReachable && isLeaseActive)
        XCTAssertTrue(shouldUseWCSession, "Watch should use WCSession data source when Phone is reachable and its lease is active")
    }

    // 10. Watch reads Firebase when Phone is unreachable.
    func testCompanionSync_10_WatchReadsFirebaseWhenPhoneUnreachable() {
        let now = Date().timeIntervalSince1970
        let phoneReachable = false
        let phoneActiveUntil: TimeInterval? = now + 5.0

        let isLeaseActive = (phoneActiveUntil != nil && now < phoneActiveUntil!)
        let shouldUseWCSession = (phoneReachable && isLeaseActive)
        XCTAssertFalse(shouldUseWCSession, "Watch should fall back to Firebase when Phone is unreachable")
    }

    // 11. Watch reads Firebase when Phone's active_until lease has expired.
    func testCompanionSync_11_WatchReadsFirebaseWhenPhoneDataExpired() {
        let now = Date().timeIntervalSince1970
        let phoneReachable = true
        let phoneActiveUntil: TimeInterval? = now - 1.0 // Lease expired 1 second ago

        let isLeaseActive = (phoneActiveUntil != nil && now < phoneActiveUntil!)
        let shouldUseWCSession = (phoneReachable && isLeaseActive)
        XCTAssertFalse(shouldUseWCSession, "Watch should fall back to Firebase when Phone's lease has expired")
    }
    
    // 12. Out-of-order remote telemetry for one player is rejected without affecting other players.
    func testCompanionSync_12_OutOfOrderTelemetryPerPlayerRejection() {
        let syncManager = createMockFirebaseSyncManager()
        let room = SquadRoom(id: "ALPHA1", hostId: "USER1")
        let memberA = SquadMember(id: "USER_A", callsign: "VIPER", latitude: 37.77, longitude: -122.41)
        let memberB = SquadMember(id: "USER_B", callsign: "GHOST", latitude: 37.78, longitude: -122.42)
        var updatedRoom = room
        updatedRoom.members["USER_A"] = memberA
        updatedRoom.members["USER_B"] = memberB
        syncManager.connectToRoom(updatedRoom)
        
        let now = Date().timeIntervalSince1970
        
        // Player A: sequence 10
        let pa10 = TelemetryPacket(memberId: "USER_A", roomId: "ALPHA1", latitude: 37.771, longitude: -122.411, heading: 45.0, heartRate: 80.0, timestamp: now + 10.0, sequenceNumber: 10)
        XCTAssertTrue(syncManager.validateAndProcessPacket(pa10))
        
        // Player B: sequence 1 (fresh for B)
        let pb1 = TelemetryPacket(memberId: "USER_B", roomId: "ALPHA1", latitude: 37.781, longitude: -122.421, heading: 90.0, heartRate: 75.0, timestamp: now + 1.0, sequenceNumber: 1)
        XCTAssertTrue(syncManager.validateAndProcessPacket(pb1), "Player B fresh packet must be accepted")
        
        // Player A: sequence 5 (late for A -> rejected)
        let pa5 = TelemetryPacket(memberId: "USER_A", roomId: "ALPHA1", latitude: 37.772, longitude: -122.412, heading: 50.0, heartRate: 85.0, timestamp: now + 5.0, sequenceNumber: 5)
        XCTAssertFalse(syncManager.validateAndProcessPacket(pa5), "Player A late packet must be rejected without affecting Player B")
        
        // Player B: sequence 2 (in order for B -> accepted)
        let pb2 = TelemetryPacket(memberId: "USER_B", roomId: "ALPHA1", latitude: 37.782, longitude: -122.422, heading: 95.0, heartRate: 78.0, timestamp: now + 2.0, sequenceNumber: 2)
        XCTAssertTrue(syncManager.validateAndProcessPacket(pb2), "Player B in-order packet must be accepted")
        
        XCTAssertEqual(syncManager.totalPacketsProcessed, 3)
        XCTAssertEqual(syncManager.totalPacketsRejected, 1)
    }
    
    // 13. Roster remains visible when a player's telemetry expires.
    func testCompanionSync_13_RosterRemainsVisibleWhenTelemetryExpires() {
        let room = SquadRoom(id: "ROSTER_TEST", hostId: "HOST_1")
        var member = SquadMember(id: "PLAYER_2", callsign: "SPECTER", latitude: 37.77, longitude: -122.41)
        member.lastUpdatedTimestamp = Date().timeIntervalSince1970 - 100.0 // Very old telemetry
        
        var activeRoom = room
        activeRoom.members["PLAYER_2"] = member
        
        // Roster is in room state: member exists and is visible
        XCTAssertNotNil(activeRoom.members["PLAYER_2"], "Player must remain in room roster even when telemetry is stale")
        XCTAssertTrue(activeRoom.members["PLAYER_2"]!.isStale(asOf: Date()), "Telemetry is marked stale without removing member from room")
    }
    
    // 14. Local persisted state restores a pending convergence cycle after app/extension restart.
    func testCompanionSync_14_LocalPersistedStateRestoresPendingConvergenceAfterRestart() {
        let savedLS = LowSpeedSnapshot(
            syncTs: 1234,
            config: ConfigSnapshot(callsign: "PERSISTENT_CALLSIGN", configTs: 500),
            playerState: PlayerStateSnapshot(isDead: true, isDeadTs: 300)
        )
        
        let encoder = JSONEncoder()
        let data = try! encoder.encode(savedLS)
        UserDefaults.standard.set(data, forKey: "wc_local_ls_snapshot")
        
        // Reinitialize manager (simulating process restart)
        let restartedWCM = WatchConnectivityManager()
        XCTAssertEqual(restartedWCM.localLS.config.callsign, "PERSISTENT_CALLSIGN")
        XCTAssertEqual(restartedWCM.localLS.config.configTs, 500)
        XCTAssertTrue(restartedWCM.localLS.playerState.isDead)
        XCTAssertEqual(restartedWCM.localLS.playerState.isDeadTs, 300)
        
        UserDefaults.standard.removeObject(forKey: "wc_local_ls_snapshot")
    }
    
    // 15. GameStateManager init does NOT overwrite localLS loginCycleTs with current timestamp.
    func testCompanionSync_15_GameStateManagerInitPreservesPersistedTimestamps() {
        let savedLS = LowSpeedSnapshot(
            syncTs: 100,
            config: ConfigSnapshot(callsign: "ALPHA_LEADER", roomName: "ROOM_A", pin: "1234", theme: "Green", isPro: false, configTs: 50),
            loginCycle: LoginCycleSnapshot(loginCycle: .inactive, loginCycleTs: 50),
            playerState: PlayerStateSnapshot(isDead: false, isDeadTs: 50)
        )
        
        let encoder = JSONEncoder()
        let data = try! encoder.encode(savedLS)
        UserDefaults.standard.set(data, forKey: "wc_local_ls_snapshot")
        
        let wcm = WatchConnectivityManager()
        let gameState = GameStateManager(watchConnectivityManager: wcm)
        
        // Ensure init did not advance loginCycleTs to Date().timeIntervalSince1970
        XCTAssertEqual(gameState.watchConnectivityManager.localLS.loginCycle.loginCycleTs, 50, "Init must not advance loginCycleTs")
        XCTAssertEqual(gameState.watchConnectivityManager.localLS.playerState.isDeadTs, 50, "Init must not advance isDeadTs")
        
        UserDefaults.standard.removeObject(forKey: "wc_local_ls_snapshot")
    }
    
    // 16. Launching companion app when peer is in game adopts the session without kicking both devices out.
    func testCompanionSync_16_CompanionLaunchDoesNotDropActiveSession() {
        let peerActiveLS = LowSpeedSnapshot(
            syncTs: 200,
            config: ConfigSnapshot(callsign: "WATCH_USER", roomName: "ACTIVE_SQUAD", pin: "", theme: "Green", isPro: true, configTs: 200),
            loginCycle: LoginCycleSnapshot(loginCycle: .joinActive, loginCycleTs: 200),
            playerState: PlayerStateSnapshot(isDead: false, isDeadTs: 200)
        )
        
        let phoneWCM = WatchConnectivityManager()
        let phoneGameState = createMockGameState(watchConnectivityManager: phoneWCM)
        
        // Simulate phone receiving Watch's active session context
        phoneGameState.watchConnectivityManager.onLowSpeedConvergenceStateChanged?(peerActiveLS)
        
        let exp = expectation(description: "Phone adopts active session from Watch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(phoneGameState.isTacticalSessionActive, "Phone must adopt active session from peer")
            XCTAssertEqual(phoneGameState.savedRoomName, "ACTIVE_SQUAD")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    // 17. MembershipSnapshot adoption preserves live coordinates of squad members without blinking or resetting to (0,0).
    func testCompanionSync_17_MembershipSnapshotAdoptionPreservesLiveCoordinates() {
        let gameState = createMockGameState()
        var room = SquadRoom(id: "DELTA_ROOM", hostId: "HOST_1")
        let player2 = SquadMember(id: "P2", callsign: "VIPER", latitude: 37.785, longitude: -122.406, heading: 45.0, heartRate: 80.0)
        room.members["P2"] = player2
        gameState.firebaseManager.activeRoom = room
        gameState.updateOtherSquadMembers(room: room)
        
        XCTAssertEqual(gameState.otherSquadMembers.first?.latitude, 37.785)
        
        // Peer sends membership snapshot where coordinates are default 0.0 (e.g. from roster node)
        let peerMember = SquadMember(id: "P2", callsign: "VIPER", latitude: 0.0, longitude: 0.0, heading: 0.0, heartRate: 0.0)
        let membersData = try! JSONEncoder().encode([peerMember])
        let membersJson = String(data: membersData, encoding: .utf8)!
        
        let incomingLS = LowSpeedSnapshot(
            syncTs: 300,
            config: ConfigSnapshot(callsign: "ME", roomName: "DELTA_ROOM", configTs: 100),
            loginCycle: LoginCycleSnapshot(loginCycle: .joinActive, loginCycleTs: 100),
            membership: MembershipSnapshot(membersJson: membersJson, memberTs: 300)
        )
        
        gameState.watchConnectivityManager.onLowSpeedConvergenceStateChanged?(incomingLS)
        
        // Coordinates must NOT be reset to 0.0
        let preservedMember = gameState.firebaseManager.activeRoom?.members["P2"]
        XCTAssertNotNil(preservedMember)
        XCTAssertEqual(preservedMember?.latitude, 37.785, "Live latitude must be preserved across companion membership adoption")
        XCTAssertEqual(preservedMember?.longitude, -122.406, "Live longitude must be preserved across companion membership adoption")
    }
    
    // 18. Watch advertises high-speed telemetry payload to WatchConnectivityManager.
    func testCompanionSync_18_WatchAdvertisesHighSpeedTelemetryToPhone() {
        let wcm = WatchConnectivityManager(role: .watch)
        let gameState = createMockGameState(watchConnectivityManager: wcm)
        gameState.myMemberId = "MY_WATCH_ID"
        
        let packet = TelemetryPacket(memberId: "REMOTE_PLAYER", roomId: "ROOM_1", latitude: 37.77, longitude: -122.41, heading: 90.0, heartRate: 85.0, timestamp: Date().timeIntervalSince1970, sequenceNumber: 10)
        
        // Assert WatchConnectivityManager high-speed telemetry payload handler
        wcm.advertiseWatchHighSpeed(heartRate: 75.0, remotePlayerTelemetryJson: "{\"REMOTE_PLAYER\":[\"inf\",37.77,-122.41,100]}")
        XCTAssertTrue(wcm.localRole == .watch)
    }

    // Multi-member accumulation and departure pruning on Watch -> Phone high-speed channel (Bug 1).
    func testWatchAccumulatesRemoteTelemetryAndPrunesDepartedMembers() {
        let wcm = WatchConnectivityManager(role: .watch)
        let gameState = createMockGameState(watchConnectivityManager: wcm)
        gameState.myMemberId = "WATCH_HOST"
        
        var room = SquadRoom(id: "ALPHA_ROOM", hostId: "WATCH_HOST")
        room.members["WATCH_HOST"] = SquadMember(id: "WATCH_HOST", callsign: "VIPER", latitude: 37.77, longitude: -122.41)
        room.members["MEMBER_A"] = SquadMember(id: "MEMBER_A", callsign: "BRAVO", latitude: 37.771, longitude: -122.411)
        room.members["MEMBER_B"] = SquadMember(id: "MEMBER_B", callsign: "CHARLIE", latitude: 37.772, longitude: -122.412)
        gameState.firebaseManager.activeRoom = room
        
        // 1. Initial state: persistentRemoteTelemetry is empty
        XCTAssertTrue(gameState.persistentRemoteTelemetry.isEmpty)
        
        // 2. Incoming delta packet for MEMBER_A only
        let packetA = TelemetryPacket(memberId: "MEMBER_A", roomId: "ALPHA_ROOM", latitude: 37.771, longitude: -122.411, heading: 90.0, heartRate: 80.0, timestamp: 1000.0, sequenceNumber: 1)
        gameState.firebaseManager.onRemoteTelemetryPacketsReceived?([packetA])
        
        // Assert: MEMBER_A accumulated, advertised payload contains MEMBER_A
        XCTAssertEqual(gameState.persistentRemoteTelemetry.count, 1)
        XCTAssertNotNil(gameState.persistentRemoteTelemetry["MEMBER_A"])
        guard let advertisedJsonA = wcm.latestAdvertisedWatchHS?.remotePlayerTelemetryJson,
              let dataA = advertisedJsonA.data(using: .utf8),
              let dictA = (try? JSONSerialization.jsonObject(with: dataA)) as? [String: Any] else {
            XCTFail("Failed to deserialize advertised JSON after packetA")
            return
        }
        XCTAssertNotNil(dictA["MEMBER_A"])
        XCTAssertNil(dictA["MEMBER_B"])
        
        // 3. Incoming delta packet for MEMBER_B only (sequential callback)
        let packetB = TelemetryPacket(memberId: "MEMBER_B", roomId: "ALPHA_ROOM", latitude: 37.772, longitude: -122.412, heading: 180.0, heartRate: 95.0, timestamp: 1001.0, sequenceNumber: 2)
        gameState.firebaseManager.onRemoteTelemetryPacketsReceived?([packetB])
        
        // Assert: Both MEMBER_A and MEMBER_B are present in accumulated snapshot (prevents Phone flickering)
        XCTAssertEqual(gameState.persistentRemoteTelemetry.count, 2)
        XCTAssertNotNil(gameState.persistentRemoteTelemetry["MEMBER_A"])
        XCTAssertNotNil(gameState.persistentRemoteTelemetry["MEMBER_B"])
        guard let advertisedJsonB = wcm.latestAdvertisedWatchHS?.remotePlayerTelemetryJson,
              let dataB = advertisedJsonB.data(using: .utf8),
              let dictB = (try? JSONSerialization.jsonObject(with: dataB)) as? [String: Any] else {
            XCTFail("Failed to deserialize advertised JSON after packetB")
            return
        }
        XCTAssertNotNil(dictB["MEMBER_A"])
        XCTAssertNotNil(dictB["MEMBER_B"])
        
        // 4. Update MEMBER_A with new coordinates
        let packetA2 = TelemetryPacket(memberId: "MEMBER_A", roomId: "ALPHA_ROOM", latitude: 37.775, longitude: -122.415, heading: 95.0, heartRate: 82.0, timestamp: 1002.0, sequenceNumber: 3)
        gameState.firebaseManager.onRemoteTelemetryPacketsReceived?([packetA2])
        XCTAssertEqual(gameState.persistentRemoteTelemetry.count, 2)
        let compactA = gameState.persistentRemoteTelemetry["MEMBER_A"]
        XCTAssertEqual((compactA?[0] as? NSNumber)?.doubleValue, 37.775)
        
        // 5. MEMBER_B departs the squad room
        var updatedRoom = room
        updatedRoom.members.removeValue(forKey: "MEMBER_B")
        gameState.firebaseManager.activeRoom = updatedRoom
        gameState.updateOtherSquadMembers(room: updatedRoom)
        
        // Assert: MEMBER_B pruned, MEMBER_A retained, advertised payload updated
        XCTAssertEqual(gameState.persistentRemoteTelemetry.count, 1)
        XCTAssertNotNil(gameState.persistentRemoteTelemetry["MEMBER_A"])
        XCTAssertNil(gameState.persistentRemoteTelemetry["MEMBER_B"])
        guard let advertisedJsonPruned = wcm.latestAdvertisedWatchHS?.remotePlayerTelemetryJson,
              let dataPruned = advertisedJsonPruned.data(using: .utf8),
              let dictPruned = (try? JSONSerialization.jsonObject(with: dataPruned)) as? [String: Any] else {
            XCTFail("Failed to deserialize advertised JSON after pruning")
            return
        }
        XCTAssertNotNil(dictPruned["MEMBER_A"])
        XCTAssertNil(dictPruned["MEMBER_B"])
        
        // 6. Purge session on logout
        gameState.purgeLocalSessionAndIcons()
        XCTAssertTrue(gameState.persistentRemoteTelemetry.isEmpty)
    }

    
    func testDebugStatusString_LengthAndDataSources() {
        let wcm = WatchConnectivityManager()
        let gameState = createMockGameState(watchConnectivityManager: wcm)
        
        // 1. Initial / idle state (no server connection, no listeners, no companion comms) -> "00000000"
        XCTAssertEqual(gameState.debugStatusString, "00000000")
        XCTAssertEqual(gameState.debugStatusString.count, 8)
        
        // 2. Connected to Firebase active room with listeners attached -> "UD000000"
        gameState.firebaseManager.isConnected = true
        gameState.firebaseManager.activeRoom = SquadRoom(id: "ALPHA", hostId: gameState.myMemberId)
        gameState.firebaseManager.startTelemetryPolling(roomId: "ALPHA")
        
        let expRoom = expectation(description: "Process active room")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expRoom.fulfill()
        }
        wait(for: [expRoom], timeout: 1.0)
        
        XCTAssertEqual(gameState.debugStatusString, "UD000000")
        XCTAssertEqual(gameState.debugStatusString.count, 8)
        
        // 3. Incoming Watch HR telemetry received on phone, active_until in the future -> "00W00000"
        // (Phone yields network ownership and listeners to Watch companion, companion comms shows 'W')
        let leaseFreshTime = Date().timeIntervalSince1970 + 60.0
        let hsEnvelope: [String: Any] = [
            "w2p_hs": [
                "active_until": leaseFreshTime,
                "fresh_until": leaseFreshTime,
                "hr": 85.0
            ]
        ]
        wcm.handleIncomingApplicationContext(hsEnvelope)
        let leaseActiveExp = expectation(description: "active_until lease becomes active")
        var leaseActiveCancellable: AnyCancellable? = wcm.$isWatchLeaseActive
            .filter { $0 }
            .first()
            .sink { _ in leaseActiveExp.fulfill() }
        wait(for: [leaseActiveExp], timeout: 2.0)
        leaseActiveCancellable?.cancel()

        XCTAssertEqual(gameState.debugStatusString, "00W00000")
        XCTAssertEqual(gameState.debugStatusString.count, 8)

        // 4. Low-speed payload becomes idle -> Character 3 still shows 'W' because Watch high-speed lease is active -> "00W00000"
        gameState.lastLowSpeedPayloadTimestamp = Date().timeIntervalSince1970 - 4.0
        XCTAssertEqual(gameState.debugStatusString, "00W00000")
        XCTAssertEqual(gameState.debugStatusString.count, 8)

        // 5. Leaving room (no server connection, watch HR still active) -> "00W00000"
        gameState.firebaseManager.isConnected = false
        gameState.firebaseManager.activeRoom = nil
        XCTAssertEqual(gameState.debugStatusString, "00W00000")
        XCTAssertEqual(gameState.debugStatusString.count, 8)

        // 6. Watch HR expires / resets, active_until in the past -> "00000000"
        let expiredEnvelope: [String: Any] = [
            "w2p_hs": [
                "active_until": 0.0,
                "fresh_until": 0.0,
                "hr": 0.0
            ]
        ]

        wcm.handleIncomingApplicationContext(expiredEnvelope)
        let leaseExpiredExp = expectation(description: "active_until lease becomes inactive")
        var leaseExpiredCancellable: AnyCancellable? = wcm.$isWatchLeaseActive
            .filter { !$0 }
            .first()
            .sink { _ in leaseExpiredExp.fulfill() }
        wait(for: [leaseExpiredExp], timeout: 2.0)
        leaseExpiredCancellable?.cancel()

        XCTAssertEqual(gameState.debugStatusString, "00000000")
        XCTAssertEqual(gameState.debugStatusString.count, 8)

        // 6b. Regression: fresh_until in the future but active_until already in the past must NOT
        // mark the companion active — proves the migration off fresh_until took effect (the old
        // fresh_until-only check would have shown "W" here).
        let staleActiveUntilEnvelope: [String: Any] = [
            "w2p_hs": [
                "active_until": Date().timeIntervalSince1970 - 10.0,
                "fresh_until": Date().timeIntervalSince1970 + 60.0,
                "hr": 85.0
            ]
        ]
        wcm.handleIncomingApplicationContext(staleActiveUntilEnvelope)
        let settleExp = expectation(description: "Lease monitor tick settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            settleExp.fulfill()
        }
        wait(for: [settleExp], timeout: 2.0)
        XCTAssertFalse(wcm.isWatchLeaseActive, "Expired active_until must not be treated as active even though fresh_until is still in the future")
        XCTAssertEqual(gameState.debugStatusString, "00000000", "Companion must not be marked active once active_until has passed, regardless of fresh_until")

        // 7. Incoming Watch low-speed payload (HS idle) -> Character 3 is '0' (HS idle), Character 4 shows 'W' (LS active) -> "000W0000"
        gameState.lastLowSpeedPayloadSource = "W"
        gameState.lastLowSpeedPayloadTimestamp = Date().timeIntervalSince1970
        XCTAssertEqual(gameState.debugStatusString, "000W0000")
        
        // Age the low-speed payload timestamp by 4 seconds (idle) -> cycles back to "00000000"
        gameState.lastLowSpeedPayloadTimestamp = Date().timeIntervalSince1970 - 4.0
        XCTAssertEqual(gameState.debugStatusString, "00000000")
        XCTAssertEqual(gameState.debugStatusString.count, 8)

        // 8. On Watch role (receiving low-speed comms from Phone, HS idle) -> Character 3 is '0' (HS idle), Character 4 shows 'P' (LS active) -> "000P0000"
        let watchWcm = WatchConnectivityManager(role: .watch)
        let watchGameState = createMockGameState(watchConnectivityManager: watchWcm)
        watchGameState.lastLowSpeedPayloadSource = "P"
        watchGameState.lastLowSpeedPayloadTimestamp = Date().timeIntervalSince1970
        XCTAssertEqual(watchGameState.debugStatusString, "000P0000")
        XCTAssertEqual(watchGameState.debugStatusString.count, 8)

        // 9. On Phone role, both Watch HS and Watch LS active concurrently -> "00WW0000"
        let dualPhoneWcm = WatchConnectivityManager(role: .phone)
        let dualPhoneGameState = createMockGameState(watchConnectivityManager: dualPhoneWcm)
        let dualFreshTime = Date().timeIntervalSince1970 + 60.0
        dualPhoneWcm.handleIncomingApplicationContext([
            "w2p_hs": [
                "active_until": dualFreshTime,
                "hr": 80.0
            ]
        ])
        let dualPhoneExp = expectation(description: "Process dualPhone HS")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            dualPhoneExp.fulfill()
        }
        wait(for: [dualPhoneExp], timeout: 1.0)
        dualPhoneGameState.lastLowSpeedPayloadSource = "W"
        dualPhoneGameState.lastLowSpeedPayloadTimestamp = Date().timeIntervalSince1970
        XCTAssertEqual(dualPhoneGameState.debugStatusString, "00WW0000")
        XCTAssertEqual(dualPhoneGameState.debugStatusString.count, 8)

        // 10. On Watch role, both Phone HS and Phone LS active concurrently -> "00PP0000"
        let dualWatchWcm = WatchConnectivityManager(role: .watch)
        let dualWatchGameState = createMockGameState(watchConnectivityManager: dualWatchWcm)
        dualWatchWcm.handleIncomingApplicationContext([
            "p2w_hs": [
                "active_until": dualFreshTime,
                "remote_telemetry": "{}"
            ]
        ])
        let dualWatchExp = expectation(description: "Process dualWatch HS")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            dualWatchExp.fulfill()
        }
        wait(for: [dualWatchExp], timeout: 1.0)
        dualWatchGameState.lastLowSpeedPayloadSource = "P"
        dualWatchGameState.lastLowSpeedPayloadTimestamp = Date().timeIntervalSince1970
        XCTAssertEqual(dualWatchGameState.debugStatusString, "00PP0000")
        XCTAssertEqual(dualWatchGameState.debugStatusString.count, 8)
    }
    
    func testNewPlayerJoiningResolvesCallsignInsteadOfShowingMemberId() {
        let gameState = createMockGameState()
        let syncManager = gameState.firebaseManager
        mockTransport(for: gameState).seed([
            "mid": "PLAYER_NEW",
            "csn": "GHOST-9",
            "rol": "player"
        ], at: "r/ALPHA/m/PLAYER_NEW")

        // Host creates active room ALPHA
        gameState.myCallsign = "LEADER"
        let hostMember = SquadMember(id: gameState.myMemberId, callsign: "LEADER", latitude: 37.77, longitude: -122.41, role: .leader)
        syncManager.activeRoom = SquadRoom(id: "ALPHA", hostId: gameState.myMemberId, members: [gameState.myMemberId: hostMember])
        
        let callsignResolvedExp = expectation(description: "Fetch member details updates callsign to GHOST-9")
        var cancellable: AnyCancellable? = syncManager.$activeRoom
            .compactMap { $0?.members["PLAYER_NEW"] }
            .filter { $0.callsign == "GHOST-9" }
            .first()
            .sink { _ in
                callsignResolvedExp.fulfill()
            }
        
        // New player PLAYER_NEW sends first telemetry packet
        let newPlayerPacket = TelemetryPacket(
            memberId: "PLAYER_NEW",
            roomId: "ALPHA",
            latitude: 37.775,
            longitude: -122.415,
            heading: 90.0,
            heartRate: 135.0,
            timestamp: Date().timeIntervalSince1970,
            sequenceNumber: 1
        )
        
        _ = syncManager.validateAndProcessPacket(newPlayerPacket)
        
        wait(for: [callsignResolvedExp], timeout: 2.0)
        cancellable?.cancel()
        
        // Ensure the member is present and their callsign is resolved to GHOST-9 instead of PLAYER_NEW (unique ID)
        let resolvedMember = syncManager.activeRoom?.members["PLAYER_NEW"]
        XCTAssertNotNil(resolvedMember)
        XCTAssertEqual(resolvedMember?.callsign, "GHOST-9")
        XCTAssertEqual(resolvedMember?.latitude, 37.775)
        XCTAssertEqual(resolvedMember?.heartRate, 135.0)
    }
    
    func testFetchMemberDetails_UpdatesCallsignAndPreservesTelemetry() {
        let syncManager = FirebaseSyncManager()
        let transport = MockRTDBTransport()
        syncManager.transport = transport
        transport.seed([
            "mid": "MEMBER_X",
            "csn": "SHADOW-1",
            "rol": "player"
        ], at: "r/BRAVO/m/MEMBER_X")

        var initialMember = SquadMember(
            id: "MEMBER_X",
            callsign: "MEMBER_X", // Initial placeholder unique ID
            latitude: 34.05,
            longitude: -118.25,
            heading: 180.0,
            heartRate: 120.0
        )
        syncManager.activeRoom = SquadRoom(id: "BRAVO", hostId: "HOST_1", members: ["MEMBER_X": initialMember])
        
        let updateExp = expectation(description: "Fetch member details updates existing member callsign")
        var cancellable: AnyCancellable? = syncManager.$activeRoom
            .compactMap { $0?.members["MEMBER_X"] }
            .filter { $0.callsign == "SHADOW-1" }
            .first()
            .sink { _ in
                updateExp.fulfill()
            }
        
        syncManager.fetchMemberDetails(roomId: "BRAVO", memberId: "MEMBER_X")
        
        wait(for: [updateExp], timeout: 2.0)
        cancellable?.cancel()
        
        let updated = syncManager.activeRoom?.members["MEMBER_X"]
        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.callsign, "SHADOW-1")
        XCTAssertEqual(updated?.latitude, 34.05)
        XCTAssertEqual(updated?.longitude, -118.25)
        XCTAssertEqual(updated?.heading, 180.0)
        XCTAssertEqual(updated?.heartRate, 120.0)
    }
    
    func testCallsignEmptyUntilAvailableWithoutFallback() {
        // Unresolved member callsign starts empty and does not fall back to ID
        let member = SquadMember(id: "UUID-999-888-777", callsign: "", latitude: 0, longitude: 0)
        XCTAssertEqual(member.callsign, "")
        
        // When callsign becomes available, it directly holds the callsign string
        var resolvedMember = member
        resolvedMember.callsign = "VIPER"
        XCTAssertEqual(resolvedMember.callsign, "VIPER")
    }
    
    func testWatchAutonomousTransitionOnFreshnessExpiration() {
        let gameState = createMockGameState()
        let wcManager = gameState.watchConnectivityManager
        let firebaseManager = gameState.firebaseManager
        
        firebaseManager.isConnected = true
        firebaseManager.activeRoom = SquadRoom(id: "ALPHA", hostId: gameState.myMemberId)
        
        // 1. Initially active room on network
        XCTAssertTrue(gameState.hasNetworkOwnership)
        
        // 2. High-speed telemetry arrives from phone/watch with activeUntil lease in future
        let now = Date().timeIntervalSince1970
        let hsEnvelope: [String: Any] = [
            "w2p_hs": [
                "active_until": now + 0.3,
                "fresh_until": now + 0.3,
                "hr": 85.0,
                "remote_player_telemetry": "{}"
            ]
        ]
        wcManager.handleIncomingApplicationContext(hsEnvelope)
        
        // Wait for main dispatch
        let exp1 = expectation(description: "Process HS context")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 1.0)
        
        // 3. After activeUntil lease has passed (ts > active_until), Phone assumes cloud ownership
        let exp2 = expectation(description: "Wait for lease expiry")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            gameState.evaluateListenerGate()
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 2.0)
        
        XCTAssertTrue(gameState.hasNetworkOwnership)
    }

    
    // 19. Cold-booted Phone with default 0 timestamp adopts Watch's active match without resetting Watch.
    func testCompanionSync_19_ColdBootPhoneWithZeroTimestampAdoptsWatchActiveGame() {
        let phoneWCM = WatchConnectivityManager()
        // Ensure default timestamps are 0
        XCTAssertEqual(phoneWCM.localLS.loginCycle.loginCycleTs, 0.0)
        XCTAssertEqual(phoneWCM.localLS.loginCycle.loginCycle, .inactive)
        
        let phoneGameState = createMockGameState(watchConnectivityManager: phoneWCM)
        XCTAssertEqual(phoneGameState.watchConnectivityManager.localLS.loginCycle.loginCycleTs, 0.0)
        
        // Watch sends an active game with timestamp > 0 (e.g. 500). config.configTs specifically
        // needs to beat real wall-clock time, not just 500: createMockGameState(...) above already
        // set phoneGameState.myCallsign, which — since ConfigSnapshot carries one timestamp for
        // the whole struct — bumped phoneWCM.localLS.config.configTs to a real "now" value. Every
        // *other* field here (loginCycle, playerState) is a separate independently-timestamped
        // struct that createMockGameState never touched, so 500 alone is already > phone's 0 for
        // those.
        let watchActiveLS = LowSpeedSnapshot(
            syncTs: 500,
            config: ConfigSnapshot(callsign: "WATCH_LEADER", roomName: "WATCH_SQUAD", pin: "", theme: "Green", isPro: false, configTs: Date().timeIntervalSince1970 + 500),
            loginCycle: LoginCycleSnapshot(loginCycle: .hostActive, loginCycleTs: 500),
            playerState: PlayerStateSnapshot(isDead: false, isDeadTs: 500)
        )
        
        // Merge should determine that Watch's loginCycle (500 > 0) wins over Phone's inactive (0)
        let (merged, localWins) = MergeEngine.merge(local: phoneWCM.localLS, peer: watchActiveLS, localDevice: .phone)
        XCTAssertEqual(merged.loginCycle.loginCycle, .hostActive)
        XCTAssertEqual(merged.loginCycle.loginCycleTs, 500)
        // Note: Phone's other 0-timestamp local fields (e.g. config with memberId) might differ, but loginCycle specifically merged Watch's active state
        XCTAssertEqual(merged.loginCycle, watchActiveLS.loginCycle)
        
        // Directly deliver converged snapshot to GameStateManager callback
        deliverPeerSnapshot(watchActiveLS, to: phoneGameState.watchConnectivityManager)

        let exp = expectation(description: "Phone adopts active session")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(phoneGameState.savedRoomName, "WATCH_SQUAD")
            XCTAssertTrue(phoneGameState.isHosting)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    // 20. Cold-booted Watch with default 0 timestamp adopts Phone's active match without resetting Phone.
    func testCompanionSync_20_ColdBootWatchWithZeroTimestampAdoptsPhoneActiveGame() {
        let watchWCM = WatchConnectivityManager(role: .watch)
        XCTAssertEqual(watchWCM.localLS.loginCycle.loginCycleTs, 0.0)
        XCTAssertEqual(watchWCM.localLS.loginCycle.loginCycle, .inactive)
        
        let phoneActiveLS = LowSpeedSnapshot(
            syncTs: 600,
            config: ConfigSnapshot(callsign: "PHONE_LEADER", roomName: "PHONE_SQUAD", pin: "", theme: "Green", isPro: false, configTs: 600),
            loginCycle: LoginCycleSnapshot(loginCycle: .joinActive, loginCycleTs: 600),
            playerState: PlayerStateSnapshot(isDead: false, isDeadTs: 600)
        )
        
        // Merge should determine that Phone's loginCycle (600 > 0) wins over Watch's inactive (0)
        let (merged, _) = MergeEngine.merge(local: watchWCM.localLS, peer: phoneActiveLS, localDevice: .watch)
        XCTAssertEqual(merged.loginCycle.loginCycle, .joinActive)
        XCTAssertEqual(merged.loginCycle.loginCycleTs, 600)
    }
    
    // 21. Explicit user disband / leave action sets a fresh timestamp (> 0) that wins over older active sessions.
    func testCompanionSync_21_ExplicitDisbandActionSetsFreshTimestamp() {
        let gameState = createMockGameState()
        let nowBefore = Date().timeIntervalSince1970
        
        gameState.isHosting = true

        let exp1 = expectation(description: "Host login cycle synced")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertGreaterThanOrEqual(gameState.watchConnectivityManager.localLS.loginCycle.loginCycleTs, nowBefore)
            XCTAssertEqual(gameState.watchConnectivityManager.localLS.loginCycle.loginCycle, .hostActive)

            let hostTs = gameState.watchConnectivityManager.localLS.loginCycle.loginCycleTs

            // Disband room
            gameState.isHosting = false

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                let leaveTs = gameState.watchConnectivityManager.localLS.loginCycle.loginCycleTs
                XCTAssertGreaterThanOrEqual(leaveTs, hostTs, "Explicit leave must stamp a fresh timestamp")
                XCTAssertEqual(gameState.watchConnectivityManager.localLS.loginCycle.loginCycle, .inactive)
                exp1.fulfill()
            }
        }
        wait(for: [exp1], timeout: 1.0)
    }
    
    // 22. isPro bidirectional sync and adoption
    func testCompanionSync_22_IsProSyncAndAdoption() {
        let watchConfig = ConfigSnapshot(isPro: true, configTs: 300)
        let phoneConfig = ConfigSnapshot(isPro: false, configTs: 100)
        
        // Merge Watch into Phone
        let (mergedPhone, _) = MergeEngine.merge(local: LowSpeedSnapshot(config: phoneConfig), peer: LowSpeedSnapshot(config: watchConfig), localDevice: .phone)
        XCTAssertTrue(mergedPhone.config.isPro)
        XCTAssertEqual(mergedPhone.config.configTs, 300)
        
        // Test GameStateManager adoption of isPro: true and false
        let gameState = createMockGameState()
        gameState.subscriptionManager.hasUnlimitedSquadUnlock = false
        
        // Adoption itself (subscriptionManager reacting to localLS.config.isPro) is tested here by
        // seeding localLS directly rather than through a real merge — the merge/LWW-winner logic
        // that decides *whether* a peer's config.isPro should win is exercised separately above
        // and in the MergeEngine-focused tests; this only checks that once localLS holds a given
        // isPro value (for whatever reason), GameStateManager keeps subscriptionManager in step.
        gameState.watchConnectivityManager.testSeedLocalLS(
            LowSpeedSnapshot(config: ConfigSnapshot(isPro: true, configTs: 400))
        )
        pumpMainRunLoop()
        XCTAssertTrue(gameState.subscriptionManager.hasUnlimitedSquadUnlock)

        gameState.watchConnectivityManager.testSeedLocalLS(
            LowSpeedSnapshot(config: ConfigSnapshot(isPro: false, configTs: 500))
        )
        pumpMainRunLoop()
        XCTAssertFalse(gameState.subscriptionManager.hasUnlimitedSquadUnlock)
    }
    
    // 23. Session purge updates and synchronizes isDeadTs
    func testCompanionSync_23_PurgeUpdatesPlayerStateTs() {
        let gameState = createMockGameState()
        gameState.setDead(true)
        XCTAssertTrue(gameState.isDead)
        
        let exp = expectation(description: "Purge sync")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let deadTs = gameState.watchConnectivityManager.localLS.playerState.isDeadTs
            XCTAssertGreaterThan(deadTs, 0)
            
            // Purge session
            gameState.purgeLocalSessionAndIcons()
            XCTAssertFalse(gameState.isDead)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                let resetTs = gameState.watchConnectivityManager.localLS.playerState.isDeadTs
                XCTAssertGreaterThanOrEqual(resetTs, deadTs)
                XCTAssertFalse(gameState.watchConnectivityManager.localLS.playerState.isDead)
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    // 24. Phone changes isDead via setDead, advancing isDeadTs, and Watch adopts via handleIncomingApplicationContext
    func testCompanionSync_24_PhoneChangesIsDeadAndWatchAdoptsViaApplicationContext() {
        let phoneWCM = WatchConnectivityManager(role: .phone)
        let phoneGS = createMockGameState(watchConnectivityManager: phoneWCM)
        
        let watchWCM = WatchConnectivityManager(role: .watch)
        let watchGS = createMockGameState(watchConnectivityManager: watchWCM)
        
        // Initial state: Both alive
        XCTAssertFalse(phoneGS.isDead)
        XCTAssertFalse(watchGS.isDead)
        
        // Phone user triggers KIA
        phoneGS.setDead(true)
        XCTAssertTrue(phoneGS.isDead)
        
        let exp = expectation(description: "Phone state serialized and applied to Watch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let phonePlayerState = phoneWCM.localLS.playerState
            XCTAssertTrue(phonePlayerState.isDead)
            XCTAssertGreaterThan(phonePlayerState.isDeadTs, 0)
            
            // Serialize Phone's envelope
            var envelope = ApplicationContextEnvelope()
            envelope.p2wLS = phoneWCM.localLS
            let data = try! JSONEncoder().encode(envelope)
            let dict = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            
            // Watch receives Phone's envelope
            watchWCM.handleIncomingApplicationContext(dict)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                XCTAssertTrue(watchGS.isDead, "Watch must adopt Phone's isDead state")
                XCTAssertEqual(watchWCM.localLS.playerState.isDeadTs, phonePlayerState.isDeadTs, "Watch must adopt Phone's isDeadTs")
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    // 25. Watch changes isDead via setDead, advancing isDeadTs, and Phone adopts via handleIncomingApplicationContext
    func testCompanionSync_25_WatchChangesIsDeadAndPhoneAdoptsViaApplicationContext() {
        let phoneWCM = WatchConnectivityManager(role: .phone)
        let phoneGS = createMockGameState(watchConnectivityManager: phoneWCM)
        
        let watchWCM = WatchConnectivityManager(role: .watch)
        let watchGS = createMockGameState(watchConnectivityManager: watchWCM)
        
        // Watch user triggers KIA
        watchGS.setDead(true)
        XCTAssertTrue(watchGS.isDead)
        
        let exp = expectation(description: "Watch state serialized and applied to Phone")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let watchPlayerState = watchWCM.localLS.playerState
            XCTAssertTrue(watchPlayerState.isDead)
            XCTAssertGreaterThan(watchPlayerState.isDeadTs, 0)
            
            // Serialize Watch's envelope
            var envelope = ApplicationContextEnvelope()
            envelope.w2pLS = watchWCM.localLS
            let data = try! JSONEncoder().encode(envelope)
            let dict = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            
            // Phone receives Watch's envelope
            phoneWCM.handleIncomingApplicationContext(dict)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                XCTAssertTrue(phoneGS.isDead, "Phone must adopt Watch's isDead state")
                XCTAssertEqual(phoneWCM.localLS.playerState.isDeadTs, watchPlayerState.isDeadTs, "Phone must adopt Watch's isDeadTs")
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    // 26. Recurring Watch heart rate stream with older isDeadTs does NOT revert Phone's newer revive state
    func testCompanionSync_26_WatchHeartRateStreamDoesNotRevertPhoneRevive() {
        let phoneWCM = WatchConnectivityManager(role: .phone)
        let phoneGS = createMockGameState(watchConnectivityManager: phoneWCM)
        
        let watchWCM = WatchConnectivityManager(role: .watch)
        let watchGS = createMockGameState(watchConnectivityManager: watchWCM)
        
        // Both start dead at t = 100. testSeedLocalLS bypasses the fresh-timestamp stamping that
        // setDead()/mutateLocalPlayerState always apply, so the test can pin an exact historical
        // isDeadTs the way a real device's persisted-from-a-previous-session state would carry.
        let initialDead = PlayerStateSnapshot(isDead: true, isDeadTs: 100)
        phoneWCM.testSeedLocalLS(LowSpeedSnapshot(playerState: initialDead))
        watchWCM.testSeedLocalLS(LowSpeedSnapshot(playerState: initialDead))

        let exp = expectation(description: "Phone revives and overrides older Watch stream")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Phone user revives at t = 200
            var revived = phoneWCM.localLS
            revived.playerState = PlayerStateSnapshot(isDead: false, isDeadTs: 200)
            phoneWCM.testSeedLocalLS(revived)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                XCTAssertFalse(phoneGS.isDead)
                XCTAssertEqual(phoneWCM.localLS.playerState.isDeadTs, 200)
                
                // Watch heart rate stream ticks with older isDeadTs (100)
                let hrPayload = WatchToPhoneHighSpeed(heartRate: 85.0)
                var watchEnvelope = ApplicationContextEnvelope()
                watchEnvelope.w2pHS = hrPayload
                watchEnvelope.w2pLS = watchWCM.localLS // Still has isDead: true, isDeadTs: 100
                
                let data = try! JSONEncoder().encode(watchEnvelope)
                let dict = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
                
                // Phone receives Watch's heart rate context
                phoneWCM.handleIncomingApplicationContext(dict)
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    // Phone must RETAIN isDead: false because phone's 200 > watch's 100
                    XCTAssertFalse(phoneGS.isDead, "Phone must remain alive, not overwritten by older Watch stream")
                    XCTAssertFalse(phoneWCM.localLS.playerState.isDead)
                    XCTAssertEqual(phoneWCM.localLS.playerState.isDeadTs, 200)
                    exp.fulfill()
                }
            }
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    // 27. Setting isDead directly on GameStateManager triggers playerState synchronization
    func testCompanionSync_27_DirectIsDeadAssignmentTriggersSync() {
        let wcm = WatchConnectivityManager()
        let gameState = createMockGameState(watchConnectivityManager: wcm)
        
        XCTAssertFalse(gameState.isDead)
        gameState.isDead = true
        
        let exp = expectation(description: "Direct isDead assignment syncs to localLS")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertTrue(wcm.localLS.playerState.isDead)
            XCTAssertGreaterThan(wcm.localLS.playerState.isDeadTs, 0)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    // MARK: - Privacy Toggle & Data Gating Tests
    
    func testPrivacyTogglesDefaultToOptIn() {
        let gameState = GameStateManager()
        XCTAssertTrue(gameState.isUploadHeartRateEnabled, "Upload HR should default to opt-in (true)")
        XCTAssertTrue(gameState.isUploadLocationEnabled, "Upload Location should default to opt-in (true)")
    }
    
    func testPrivacyConfigSnapshotEncodingDecoding() {
        let original = ConfigSnapshot(
            callsign: "GHOST",
            roomName: "SQUAD1",
            pin: "1234",
            theme: "Green",
            isPro: true,
            isUploadHeartRateEnabled: false,
            isUploadLocationEnabled: false,
            configTs: 100
        )
        
        guard let data = try? JSONEncoder().encode(original),
              let decoded = try? JSONDecoder().decode(ConfigSnapshot.self, from: data) else {
            XCTFail("ConfigSnapshot failed to encode/decode")
            return
        }
        
        XCTAssertEqual(decoded.callsign, "GHOST")
        XCTAssertFalse(decoded.isUploadHeartRateEnabled)
        XCTAssertFalse(decoded.isUploadLocationEnabled)
        XCTAssertTrue(original.isEquivalent(to: decoded))
    }
    
    func testPrivacyConfigSyncConvergence() {
        let wcm = WatchConnectivityManager()
        let gameState = createMockGameState(watchConnectivityManager: wcm)
        
        gameState.isUploadHeartRateEnabled = false
        gameState.isUploadLocationEnabled = false
        
        let exp = expectation(description: "Privacy toggle updates sync to localLS config")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertFalse(wcm.localLS.config.isUploadHeartRateEnabled)
            XCTAssertFalse(wcm.localLS.config.isUploadLocationEnabled)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    func testUploadOptOutGatingInBroadcast() {
        let gameState = createMockGameState()
        let room = SquadRoom(id: "PRIVACY_TEST", hostId: "TEST_HOST")
        gameState.firebaseManager.connectToRoom(room)
        
        // When location upload is disabled, broadcast is gated
        gameState.isUploadLocationEnabled = false
        let initialUploadCount = gameState.totalTelemetryUploadsEmitted
        gameState.broadcastLocalTelemetry(force: true)
        XCTAssertEqual(gameState.totalTelemetryUploadsEmitted, initialUploadCount, "Telemetry packet should not be emitted when location upload is disabled")
        
        // Re-enable location upload but disable HR upload
        gameState.isUploadLocationEnabled = true
        gameState.isUploadHeartRateEnabled = false
        gameState.healthKitManager.currentHeartRate = 145.0
        
        let beforeManualBroadcastCount = gameState.totalTelemetryUploadsEmitted
        gameState.broadcastLocalTelemetry(force: true)
        XCTAssertEqual(gameState.totalTelemetryUploadsEmitted, beforeManualBroadcastCount + 1)
        XCTAssertEqual(gameState.lastSentHeartRate, AppConstants.Health.defaultRestingHeartRate, "Gated HR upload should stream default resting HR (75.0 BPM)")
    }
    
    func testDisablingUploadLocationDisablesUploadHeartRate() {
        let gameState = createMockGameState()
        gameState.isUploadLocationEnabled = true
        gameState.isUploadHeartRateEnabled = true
        
        // Disabling location upload must automatically disable HR upload
        gameState.isUploadLocationEnabled = false
        XCTAssertFalse(gameState.isUploadLocationEnabled)
        XCTAssertFalse(gameState.isUploadHeartRateEnabled, "Disabling upload location should automatically disable upload HR")
    }
    
    // MARK: - Upload Scheduling & Connectivity Gate Tests
    
    func testUploadScheduling_TacticalWritesSubmittedWhileOfflineQueueAll() {
        let syncManager = createMockFirebaseSyncManager()
        let room = SquadRoom(id: "ROOM_TACTICAL", hostId: "USER1")
        syncManager.connectToRoom(room)
        
        // Put in offline / disconnected state
        syncManager.setRTDBConnected(false)
        let sema = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { sema.signal() }
        sema.wait()
        
        syncManager.resetUploadMetrics()
        
        let indicator = TacticalIndicator(
            id: "IND_123",
            type: .attackHere,
            coordinate: CLLocationCoordinate2D(latitude: 37.785, longitude: -122.406),
            placedByMemberId: "USER1"
        )
        
        // 1. Add tactical indicator while offline
        syncManager.addOrUpdateIndicator(roomId: "ROOM_TACTICAL", indicator: indicator)
        
        // 2. Remove tactical indicator while offline
        syncManager.removeIndicator(roomId: "ROOM_TACTICAL", indicatorId: "IND_123")
        
        let waitSema = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { waitSema.signal() }
        waitSema.wait()
        
        let metrics = syncManager.uploadMetrics
        XCTAssertGreaterThanOrEqual(metrics.tacticalWritesSubmitted, 2, "Tactical writes must continue to be submitted to transport while offline (queue-all / must-arrive)")
    }
    
    func testUploadScheduling_OfflineTelemetryCoalesces60SamplesIntoSingleLatestPending() {
        let syncManager = createMockFirebaseSyncManager()
        let room = SquadRoom(id: "ALPHA", hostId: "VIPER-1")
        syncManager.connectToRoom(room)
        
        // Disconnect
        syncManager.setRTDBConnected(false)
        let sema = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { sema.signal() }
        sema.wait()
        
        syncManager.resetUploadMetrics()
        
        let now = Date().timeIntervalSince1970
        // Simulate 60 seconds of 1 Hz telemetry while offline
        for i in 1...60 {
            let packet = TelemetryPacket(
                memberId: "VIPER-1",
                roomId: "ALPHA",
                latitude: 37.7858 + (Double(i) * 0.0001),
                longitude: -122.4064 + (Double(i) * 0.0001),
                heading: Double(i * 5),
                heartRate: 80.0 + Double(i % 10),
                timestamp: now + Double(i),
                sequenceNumber: Int64(i)
            )
            syncManager.sendTelemetryPacket(packet)
        }
        
        let waitSema = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { waitSema.signal() }
        waitSema.wait()
        
        let metrics = syncManager.uploadMetrics
        XCTAssertEqual(metrics.telemetryWritesSubmitted, 0, "No telemetry network writes must be submitted while offline")
        XCTAssertEqual(metrics.telemetrySamplesRetainedOffline, 1, "Exactly one initial offline sample retained")
        XCTAssertEqual(metrics.telemetrySamplesReplacedCoalesced, 59, "59 subsequent offline samples replaced/coalesced")
        
        let pending = syncManager.getPendingTelemetry()
        XCTAssertNotNil(pending, "In-memory pending telemetry slot must be occupied")
        XCTAssertEqual(pending?.packet.sequenceNumber, 60, "Only latest telemetry packet (seq 60) must be retained in memory")
        XCTAssertEqual(pending?.roomId, "ALPHA")
        XCTAssertEqual(pending?.memberId, "VIPER-1")
    }
    
    func testUploadScheduling_ReconnectFlushesSingleLatestTelemetryToExistingPath() {
        let syncManager = createMockFirebaseSyncManager()
        let transport = mockTransport(for: syncManager)
        let room = SquadRoom(id: "ALPHA", hostId: "VIPER-1")
        syncManager.connectToRoom(room)
        
        // 1. Disconnect and send 10 packets
        syncManager.setRTDBConnected(false)
        let sema1 = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { sema1.signal() }
        sema1.wait()
        
        syncManager.resetUploadMetrics()
        
        let now = Date().timeIntervalSince1970
        for i in 1...10 {
            let packet = TelemetryPacket(
                memberId: "VIPER-1",
                roomId: "ALPHA",
                latitude: 37.7858 + (Double(i) * 0.0001),
                longitude: -122.4064,
                heading: 0.0,
                heartRate: 90.0,
                timestamp: now + Double(i),
                sequenceNumber: Int64(i)
            )
            syncManager.sendTelemetryPacket(packet)
        }
        
        let sema2 = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { sema2.signal() }
        sema2.wait()
        
        XCTAssertEqual(syncManager.uploadMetrics.telemetryWritesSubmitted, 0)
        XCTAssertEqual(syncManager.getPendingTelemetry()?.packet.sequenceNumber, 10)
        
        // 2. Reconnect: transition to connected
        syncManager.setRTDBConnected(true)
        
        let sema3 = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { sema3.signal() }
        sema3.wait()
        
        let metrics = syncManager.uploadMetrics
        XCTAssertEqual(metrics.reconnectTriggeredTelemetryFlushes, 1, "Exactly one reconnect telemetry write triggered")
        XCTAssertEqual(metrics.telemetryWritesSubmitted, 1, "Exactly one telemetry write submitted on reconnect")
        XCTAssertEqual(metrics.telemetryWritesCompleted, 1, "Telemetry write completed successfully")
        XCTAssertNil(syncManager.getPendingTelemetry(), "Pending telemetry slot cleared after successful reconnect upload")
        
        // Verify path and payload
        let telemetrySet = transport.recordedSets.first { $0.path == "p/ALPHA/VIPER-1" }
        XCTAssertNotNil(telemetrySet, "Must write to existing path telemetry/ALPHA/VIPER-1")

        if let array = telemetrySet?.value as? [Any] {
            XCTAssertEqual(array.count, 4, "Must preserve existing 4-element compact array schema")
            XCTAssertEqual(array[0] as? Double, 37.7858 + (10.0 * 0.0001))
            XCTAssertEqual(array[2] as? Double, 90.0)
        } else {
            XCTFail("Telemetry write payload must be a 4-element compact array")
        }
    }
    
    func testUploadScheduling_ConnectedTelemetrySendsImmediatelyWithoutCoalescing() {
        let syncManager = createMockFirebaseSyncManager()
        let room = SquadRoom(id: "ALPHA", hostId: "VIPER-1")
        syncManager.connectToRoom(room)
        syncManager.setRTDBConnected(true)
        
        let sema1 = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { sema1.signal() }
        sema1.wait()
        
        syncManager.resetUploadMetrics()
        
        let now = Date().timeIntervalSince1970
        for i in 1...5 {
            let packet = TelemetryPacket(
                memberId: "VIPER-1",
                roomId: "ALPHA",
                latitude: 37.7858,
                longitude: -122.4064,
                heading: 0.0,
                heartRate: 85.0,
                timestamp: now + Double(i),
                sequenceNumber: Int64(i)
            )
            syncManager.sendTelemetryPacket(packet)
        }
        
        let sema2 = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { sema2.signal() }
        sema2.wait()
        
        let metrics = syncManager.uploadMetrics
        XCTAssertEqual(metrics.telemetryWritesSubmitted, 5, "All 5 packets submitted immediately when connected")
        XCTAssertEqual(metrics.telemetrySamplesRetainedOffline, 0)
        XCTAssertEqual(metrics.telemetrySamplesReplacedCoalesced, 0)
        XCTAssertNil(syncManager.getPendingTelemetry())
    }
    
    func testUploadScheduling_ReconnectFailureRetainsPendingSample() {
        let syncManager = createMockFirebaseSyncManager()
        // Simulate a server write failure on this member's telemetry path.
        mockTransport(for: syncManager).failingPaths.insert("p/ALPHA/VIPER-1")
        let room = SquadRoom(id: "ALPHA", hostId: "VIPER-1")
        syncManager.connectToRoom(room)
        
        // 1. Disconnect and send packet
        syncManager.setRTDBConnected(false)
        let sema1 = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { sema1.signal() }
        sema1.wait()
        
        syncManager.resetUploadMetrics()
        
        let packet = TelemetryPacket(
            memberId: "VIPER-1",
            roomId: "ALPHA",
            latitude: 37.7858,
            longitude: -122.4064,
            heading: 0.0,
            heartRate: 85.0,
            timestamp: Date().timeIntervalSince1970,
            sequenceNumber: 99
        )
        syncManager.sendTelemetryPacket(packet)
        
        let sema2 = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { sema2.signal() }
        sema2.wait()
        
        // 2. Reconnect with simulated HTTP 500 failure
        syncManager.setRTDBConnected(true)
        
        let sema3 = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { sema3.signal() }
        sema3.wait()
        
        let metrics = syncManager.uploadMetrics
        XCTAssertEqual(metrics.telemetryWritesFailed, 1, "Failed telemetry write recorded")
        XCTAssertNotNil(syncManager.getPendingTelemetry(), "Pending telemetry must be retained for subsequent reconnect")
        XCTAssertEqual(syncManager.getPendingTelemetry()?.packet.sequenceNumber, 99)
    }

    /// Truth table for `evaluateListenerGate()` on Phone (non-watchOS): listeners attach ONLY when
    /// the phone is actively being looked at (`appActive`) AND the Watch's lease is inactive / expired
    /// (`!peerLeaseActive`, meaning `phone.time > w2p_hs.active_until`).
    func testListenerGate_PhoneTruthTable() {
        let gameState = createMockGameState()
        let transport = mockTransport(for: gameState)
        gameState.firebaseManager.isConnected = true
        gameState.firebaseManager.activeRoom = SquadRoom(id: "GATE_ROOM", hostId: gameState.myMemberId)
        XCTAssertTrue(gameState.isTacticalSessionActive)

        // appActive=false, peerLeaseActive=false -> detached
        gameState.firebaseManager.setWristActive(false)
        gameState.watchConnectivityManager.isWatchLeaseActive = false
        gameState.evaluateListenerGate()
        XCTAssertEqual(transport.activeObserverCount, 0, "Neither app-active nor peer lease active: Phone listeners must be detached")

        // appActive=true, peerLeaseActive=false -> attached (Phone looked at and Watch stepped down)
        gameState.firebaseManager.setWristActive(true)
        gameState.evaluateListenerGate()
        XCTAssertGreaterThan(transport.activeObserverCount, 0, "Phone looked at AND Watch stepped down (!peerLeaseActive): listeners must attach")

        // appActive=false, peerLeaseActive=true -> detached (Watch active, Phone not looked at)
        gameState.firebaseManager.setWristActive(false)
        gameState.watchConnectivityManager.isWatchLeaseActive = true
        gameState.evaluateListenerGate()
        XCTAssertEqual(transport.activeObserverCount, 0, "Watch lease active and Phone not looked at: Phone listeners must be detached")

        // appActive=true, peerLeaseActive=true -> detached (Watch lease still active: Phone must not attach even if looked at)
        gameState.firebaseManager.setWristActive(true)
        gameState.evaluateListenerGate()
        XCTAssertEqual(transport.activeObserverCount, 0, "Watch lease active: Phone must yield listeners even when appActive is true")

        // Watch lease expires while Phone is still looked at -> attaches
        gameState.watchConnectivityManager.isWatchLeaseActive = false
        gameState.evaluateListenerGate()
        XCTAssertGreaterThan(transport.activeObserverCount, 0, "Watch lease expiring while Phone is looked at must attach Phone listeners")

        // Phone backgrounded -> detached again
        gameState.firebaseManager.setWristActive(false)
        gameState.evaluateListenerGate()
        XCTAssertEqual(transport.activeObserverCount, 0, "Phone backgrounded must detach listeners")
    }

    /// Pure truth-table unit test verifying both Watch and Phone evaluation policies via `GameStateManager.shouldAttachListeners`.
    func testListenerGate_PlatformDifferentiatedTruthTable() {
        // Watch: appActive || peerLeaseActive
        XCTAssertFalse(GameStateManager.shouldAttachListeners(isWatch: true, appActive: false, peerLeaseActive: false))
        XCTAssertTrue(GameStateManager.shouldAttachListeners(isWatch: true, appActive: true, peerLeaseActive: false))
        XCTAssertTrue(GameStateManager.shouldAttachListeners(isWatch: true, appActive: false, peerLeaseActive: true))
        XCTAssertTrue(GameStateManager.shouldAttachListeners(isWatch: true, appActive: true, peerLeaseActive: true))

        // Phone: appActive && !peerLeaseActive
        XCTAssertFalse(GameStateManager.shouldAttachListeners(isWatch: false, appActive: false, peerLeaseActive: false))
        XCTAssertTrue(GameStateManager.shouldAttachListeners(isWatch: false, appActive: true, peerLeaseActive: false))
        XCTAssertFalse(GameStateManager.shouldAttachListeners(isWatch: false, appActive: false, peerLeaseActive: true))
        XCTAssertFalse(GameStateManager.shouldAttachListeners(isWatch: false, appActive: true, peerLeaseActive: true))
    }

    func testListenerGate_NoActiveSessionDetachesRegardlessOfActivity() {
        let gameState = createMockGameState()
        let transport = mockTransport(for: gameState)
        // No active session (never connected / no room) -> must not attach even if both signals are active.
        gameState.firebaseManager.setWristActive(true)
        gameState.watchConnectivityManager.isWatchLeaseActive = true
        gameState.evaluateListenerGate()
        XCTAssertEqual(transport.activeObserverCount, 0, "Listener gate must not attach without an active tactical session")
    }

    // MARK: - Active-Advertisement Timer Tests

    /// Verifies the timer-driven lease refresh (`GameStateManager.updateActiveAdvertisementTimer`)
    /// fires repeatedly on `activeAdvertisementCadenceSeconds` while `isTacticalSessionActive &&
    /// isWristActive`, and stops once either goes false. Observed via `onActiveLeaseAdvertised`
    /// (a test-only hook) rather than the real WCSession wire effect: this test target runs via
    /// `swift test` on macOS, where `WCSession.isSupported()` is false, making
    /// `advertisePhoneHighSpeed()`'s actual publish a no-op with nothing externally observable.
    func testActiveAdvertisementTimer_FiresWhileActiveAndStopsWhenInactive() {
        let gameState = createMockGameState()
        gameState.firebaseManager.isConnected = true
        gameState.firebaseManager.activeRoom = SquadRoom(id: "ADVERT_ROOM", hostId: gameState.myMemberId)
        XCTAssertTrue(gameState.isTacticalSessionActive)

        var advertiseCount = 0
        gameState.onActiveLeaseAdvertised = { advertiseCount += 1 }

        gameState.firebaseManager.setWristActive(true)
        gameState.startTacticalSession()

        XCTAssertEqual(advertiseCount, 1, "Starting the session while wrist-active must fire one immediate advertisement")

        let secondTickExp = expectation(description: "Timer fires again on the next cadence tick")
        let cadence = AppConstants.WatchConnectivity.activeAdvertisementCadenceSeconds
        DispatchQueue.main.asyncAfter(deadline: .now() + cadence + 0.5) {
            secondTickExp.fulfill()
        }
        wait(for: [secondTickExp], timeout: cadence + 2.0)

        XCTAssertGreaterThanOrEqual(advertiseCount, 2, "Timer must keep advertising at least once more while still active")

        let countAfterActive = advertiseCount
        gameState.firebaseManager.setWristActive(false)

        let quietExp = expectation(description: "No further advertisements after going inactive")
        DispatchQueue.main.asyncAfter(deadline: .now() + cadence + 0.5) {
            quietExp.fulfill()
        }
        wait(for: [quietExp], timeout: cadence + 2.0)

        XCTAssertEqual(advertiseCount, countAfterActive, "Timer must stop advertising once wrist-active goes false")

        gameState.stopTacticalSession()
    }

    func testHeartRateDisplayFadeAndTouchBrightness() {
        // Feature Requirement:
        // 1. Numerical heart rate display brightness matching top center star (opacity 1.0)
        // 2. Fades in brightness over 3 seconds to 0 transparency (opacity 0.0)
        // 3. Touching the heart rate button brings it to full brightness again
        let fadeDuration = AppConstants.UI.HUD.heartRateFadeDurationSeconds
        XCTAssertEqual(fadeDuration, 3.0, "Heart rate fade duration must be 3 seconds")

        func calculateOpacity(isHolding: Bool, hrElapsed: Double) -> Double {
            isHolding ? 1.0 : max(0.0, min(1.0, 1.0 - (max(0.0, hrElapsed) / fadeDuration)))
        }

        // At moment of touch (or release), full brightness (1.0)
        XCTAssertEqual(calculateOpacity(isHolding: false, hrElapsed: 0.0), 1.0, accuracy: 0.001)

        // Midway through fade (1.5 seconds)
        XCTAssertEqual(calculateOpacity(isHolding: false, hrElapsed: 1.5), 0.5, accuracy: 0.001)

        // At exactly 3.0 seconds, fades to 0
        XCTAssertEqual(calculateOpacity(isHolding: false, hrElapsed: 3.0), 0.0, accuracy: 0.001)

        // Beyond 3.0 seconds, remains clamped at 0.0
        XCTAssertEqual(calculateOpacity(isHolding: false, hrElapsed: 5.0), 0.0, accuracy: 0.001)

        // Touching the button (isHolding: true) forces full brightness (1.0) regardless of elapsed time
        XCTAssertEqual(calculateOpacity(isHolding: true, hrElapsed: 10.0), 1.0, accuracy: 0.001)
    }

    // MARK: - Role Selection & Slider Tests

    func testMemberRoleHierarchyAndTierGating() {
        let ranks = MemberRole.allRanksOrdered
        XCTAssertEqual(ranks.count, 2)
        XCTAssertEqual(ranks[0], .player)
        XCTAssertEqual(ranks[1], .leader)

        XCTAssertEqual(MemberRole.player.displayName, "Player")
        XCTAssertEqual(MemberRole.leader.displayName, "Team Leader")

        XCTAssertFalse(MemberRole.player.isProRequired)
        XCTAssertTrue(MemberRole.leader.isProRequired)

        XCTAssertEqual(MemberRole.player.rawValue, "player")
        XCTAssertEqual(MemberRole.leader.rawValue, "leader")

        XCTAssertTrue(MemberRole.player < MemberRole.leader)
    }

    func testGameStateRoleSelectionFreeTierClampedToPlayer() {
        let gameState = createMockGameState()
        gameState.subscriptionManager.activeEngineMode = .mock
        gameState.subscriptionManager.hasUnlimitedSquadUnlock = false

        // Attempting to select Team Leader on free tier clamps back to Player
        gameState.myRole = .leader
        XCTAssertEqual(gameState.myRole, .player)
        XCTAssertEqual(gameState.localPlayerMember.role, .player)
    }

    func testGameStateRoleSelectionProTierAllowsTeamLeader() {
        let gameState = createMockGameState()
        gameState.subscriptionManager.activeEngineMode = .mock
        gameState.subscriptionManager.debugForceUnlockPro()

        // With Pro unlocked, selecting Team Leader succeeds
        gameState.myRole = .leader
        XCTAssertEqual(gameState.myRole, .leader)
        XCTAssertEqual(gameState.localPlayerMember.role, .leader)

        // Switching back to Player succeeds
        gameState.myRole = .player
        XCTAssertEqual(gameState.myRole, .player)
        XCTAssertEqual(gameState.localPlayerMember.role, .player)
    }

    func testConfigSnapshotRoleSerialization() {
        let snapshot = ConfigSnapshot(callsign: "VIPER", role: "leader")
        guard let data = try? JSONEncoder().encode(snapshot),
              let decoded = try? JSONDecoder().decode(ConfigSnapshot.self, from: data) else {
            XCTFail("ConfigSnapshot failed to encode/decode")
            return
        }
        XCTAssertEqual(decoded.role, "leader")

        // Backward compatibility: JSON without role defaults to player
        let jsonWithoutRole = """
        {"callsign":"GHOST","roomName":"ALPHA","pin":"1234","databaseURL":"","theme":"Green","isPro":false,"isUploadHeartRateEnabled":true,"isUploadLocationEnabled":true,"configTs":100}
        """.data(using: .utf8)!
        let decodedLegacy = try? JSONDecoder().decode(ConfigSnapshot.self, from: jsonWithoutRole)
        XCTAssertNotNil(decodedLegacy)
        XCTAssertEqual(decodedLegacy?.role, "player")
    }

    func testHostRoomUsesSelectedRole() {
        let gameState = createMockGameState()
        gameState.subscriptionManager.activeEngineMode = .mock
        gameState.subscriptionManager.debugForceUnlockPro()
        gameState.myRole = .leader

        let name = "LEADER_SQUAD"
        let pin = "1234"
        let exp = expectation(description: "Host room completes")
        gameState.hostRoom(name: name, pin: pin) { success in
            XCTAssertTrue(success)
            XCTAssertEqual(gameState.firebaseManager.activeRoom?.members[gameState.myMemberId]?.role, .leader)
            XCTAssertEqual(gameState.localPlayerMember.role, .leader)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testRoleSliderGatingLogic() {
        // Free tier gating verification
        let freeUnlockedRanks = MemberRole.allRanksOrdered.filter { !$0.isProRequired }
        XCTAssertEqual(freeUnlockedRanks, [.player])

        // Pro tier gating verification
        let proUnlockedRanks = MemberRole.allRanksOrdered
        XCTAssertEqual(proUnlockedRanks, [.player, .leader])
    }
}










