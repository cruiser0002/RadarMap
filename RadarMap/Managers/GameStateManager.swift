import Foundation
import Combine
import CoreLocation
import SwiftUI
import CryptoKit

public final class GameStateManager: ObservableObject {
    @Published public var myCallsign: String {
        didSet {
            UserDefaults.standard.set(myCallsign, forKey: AppConstants.Storage.userCallsignKey)
            let derivedId = GameStateManager.deriveMemberId(fromCallsign: myCallsign)
            if derivedId != myMemberId {
                myMemberId = derivedId
            }
            updateLocalMember()
            updateLocalPlayerMember()
            updateAllTacticalIndicators()
            syncConfigToWatchConnectivity()
        }
    }
    @Published public var myMemberId: String {
        didSet {
            firebaseManager.localMemberId = myMemberId
            updateLocalPlayerMember()
            updateOtherSquadMembers()
            updateAllTacticalIndicators()
            syncConfigToWatchConnectivity()
        }
    }
    // Single Sources of Truth: Deterministic State Machines
    @Published public private(set) var mapStateMachine = MapStateMachine()
    @Published public private(set) var sessionStateMachine = SessionStateMachine()
    @Published public private(set) var playerVitalStateMachine = PlayerVitalStateMachine()
    
    // Synchronized Published State Accessors
    @Published public var selectedPresentation: TacticalPresentation = .radar {
        didSet {
            if mapStateMachine.presentation != selectedPresentation {
                mapStateMachine.handle(.togglePresentation)
            }
        }
    }
    @Published public var radarColorTheme: RadarColorTheme = .green {
        didSet {
            UserDefaults.standard.set(radarColorTheme.rawValue, forKey: AppConstants.Storage.radarColorThemeKey)
            syncConfigToWatchConnectivity()
        }
    }
    @Published public var savedRoomName: String {
        didSet {
            UserDefaults.standard.set(savedRoomName, forKey: AppConstants.Storage.savedRoomNameKey)
            syncConfigToWatchConnectivity()
        }
    }
    @Published public var savedPin: String {
        didSet {
            UserDefaults.standard.set(savedPin, forKey: AppConstants.Storage.savedPinKey)
            syncConfigToWatchConnectivity()
        }
    }
    /// Host-provided Firebase Realtime Database URL for squads that run against their own
    /// Firebase project instead of the shared default (see BRING_YOUR_OWN_FIREBASE.md). Empty means
    /// "use the shared default project."
    @Published public var customDatabaseURL: String {
        didSet {
            UserDefaults.standard.set(customDatabaseURL, forKey: AppConstants.Storage.customDatabaseURLKey)
        }
    }
    /// Master switch for the custom database URL feature. Off: the URL field and camera button
    /// are grayed out, and host/join always uses the shared default RTDB regardless of whatever
    /// text is sitting in `customDatabaseURL`. On: the field/camera are editable, and host/join
    /// uses `customDatabaseURL` (falling back to the default only if it's empty). Defaults to on
    /// so a fresh install behaves like a plain "type your URL" field.
    @Published public var isCustomDatabaseURLEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isCustomDatabaseURLEnabled, forKey: AppConstants.Storage.isCustomDatabaseURLEnabledKey)
        }
    }
    /// Most-recently-used custom database URLs, newest first, capped at
    /// `AppConstants.UI.maxRecentDatabaseURLs`, for quick reselection in `DatabaseURLField`.
    @Published public private(set) var recentDatabaseURLs: [String] {
        didSet {
            UserDefaults.standard.set(recentDatabaseURLs, forKey: AppConstants.Storage.recentDatabaseURLsKey)
        }
    }
    /// Records a successfully-used custom database URL, moving it to the front of
    /// `recentDatabaseURLs` and trimming the list to `AppConstants.UI.maxRecentDatabaseURLs`.
    public func rememberRecentDatabaseURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = recentDatabaseURLs.filter { $0 != trimmed }
        updated.insert(trimmed, at: 0)
        recentDatabaseURLs = Array(updated.prefix(AppConstants.UI.maxRecentDatabaseURLs))
    }
    @Published public var isUploadHeartRateEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isUploadHeartRateEnabled, forKey: AppConstants.Storage.isUploadHeartRateEnabledKey)
            syncConfigToWatchConnectivity()
        }
    }
    @Published public var isUploadLocationEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isUploadLocationEnabled, forKey: AppConstants.Storage.isUploadLocationEnabledKey)
            if !isUploadLocationEnabled && isUploadHeartRateEnabled {
                isUploadHeartRateEnabled = false
            }
            syncConfigToWatchConnectivity()
        }
    }
    @Published public var isHosting: Bool = false {
        didSet {
            updateLocalPlayerMember()
            syncLoginCycleToWatchConnectivity()
        }
    }
    @Published public var isInitiatingHost: Bool = false
    @Published public var isJoining: Bool = false
    @Published public var showPaywallSheet: Bool = false
    @Published public var isDead: Bool = AppConstants.Health.defaultIsDead {
        didSet {
            updateLocalPlayerMember()
            syncPlayerStateToWatchConnectivity()
        }
    }
    @Published public var errorMessage: String? = nil
    
    // Canonical Scale & Map State
    @Published public var selectedScaleMeters: CLLocationDistance = TacticalScalePolicy.defaultScale {
        didSet {
            if mapStateMachine.scaleMeters != selectedScaleMeters {
                mapStateMachine.handle(.setScale(meters: selectedScaleMeters))
            }
            if liveMapScaleMeters != selectedScaleMeters {
                liveMapScaleMeters = selectedScaleMeters
            }
        }
    }
    /// Backward-compatibility alias for radarScaleMeters
    public var radarScaleMeters: Double {
        get { selectedScaleMeters }
        set { selectedScaleMeters = newValue }
    }
    /// The actual live zoom scale directly tracking the map's camera properties / pinch interactions
    @Published public var liveMapScaleMeters: Double = TacticalScalePolicy.defaultScale
    @Published public var currentMapCenter: CLLocationCoordinate2D? = nil {
        didSet {
            if let center = currentMapCenter {
                if mapStateMachine.trackingState.pannedCoordinate?.latitude != center.latitude || mapStateMachine.trackingState.pannedCoordinate?.longitude != center.longitude {
                    mapStateMachine = MapStateMachine(
                        trackingState: .unlocked(latitude: center.latitude, longitude: center.longitude),
                        scaleMeters: selectedScaleMeters,
                        presentation: selectedPresentation,
                        centerTriggerCount: radarCenterTrigger
                    )
                    mapCenterLockState = .unlocked
                }
            } else if mapStateMachine.trackingState.isUnlocked {
                mapStateMachine.handle(.centerOnLocalUser)
                mapCenterLockState = .locked
            }
        }
    }
    @Published public var radarCenterTrigger: Int = 0
    @Published public var mapCenterLockState: MapCenterLockState = .locked {
        didSet {
            if mapCenterLockState == .locked && mapStateMachine.trackingState.isUnlocked {
                mapStateMachine.handle(.centerOnLocalUser)
                currentMapCenter = nil
            }
        }
    }
    
    // Tactical Indicators & Commander Menu State
    @Published public var showIndicatorMenuSheet: Bool = false
    @Published public var pendingIndicatorPlacementType: TacticalIndicatorType? = nil
    
    public var currentMapSpanDelta: Double {
        get {
            AppConstants.UI.RadarScale.mapSpanDelta(forRadarScaleMeters: selectedScaleMeters)
        }
        set {
            sendMapAction(.setScale(meters: AppConstants.UI.RadarScale.radarScaleMeters(forMapSpanDelta: newValue)))
        }
    }
    
    public var currentScaleText: String {
        AppConstants.UI.ScaleRuler.formatLiveRulerDistance(minorScaleMeters: liveMapScaleMeters)
    }
    
    public var isTacticalSessionActive: Bool {
        sessionStateMachine.state.isActiveSession || (firebaseManager.isConnected && firebaseManager.activeRoom != nil)
    }
    
    public func distanceToLocalPlayer(from coordinate: CLLocationCoordinate2D) -> Double {
        let playerCoord = localPlayerMember.coordinate
        let dLat = (coordinate.latitude - playerCoord.latitude) * AppConstants.Location.metersPerDegreeLatitude
        let dLon = (coordinate.longitude - playerCoord.longitude) * AppConstants.Location.metersPerDegreeLatitude * cos(coordinate.latitude * AppConstants.Location.degreesToRadiansFactor)
        return hypot(dLat, dLon)
    }
    
    // MARK: - State Machine Action Handlers
    
    public func sendMapAction(_ action: MapAction) {
        mapStateMachine.handle(action)
        if selectedPresentation != mapStateMachine.presentation {
            selectedPresentation = mapStateMachine.presentation
        }
        if selectedScaleMeters != mapStateMachine.scaleMeters {
            selectedScaleMeters = mapStateMachine.scaleMeters
        }
        let panned = mapStateMachine.trackingState.pannedCoordinate
        if currentMapCenter?.latitude != panned?.latitude || currentMapCenter?.longitude != panned?.longitude {
            currentMapCenter = panned
        }
        if radarCenterTrigger != mapStateMachine.centerTriggerCount {
            radarCenterTrigger = mapStateMachine.centerTriggerCount
        }
        if mapCenterLockState != mapStateMachine.lockState {
            mapCenterLockState = mapStateMachine.lockState
        }
    }
    
    public func sendSessionAction(_ action: SessionAction) {
        sessionStateMachine.handle(action)
        isHosting = sessionStateMachine.state.isHosting
        isInitiatingHost = sessionStateMachine.state.isInitiatingHost
        isJoining = sessionStateMachine.state.isJoining
        if let err = sessionStateMachine.state.errorMessage {
            errorMessage = err
        }
        syncLoginCycleToWatchConnectivity()
    }
    
    public func sendPlayerVitalAction(_ action: PlayerVitalAction) {
        playerVitalStateMachine.handle(action)
        isDead = playerVitalStateMachine.state.isDead
        syncPlayerStateToWatchConnectivity(forceTimestampUpdate: true)
    }
    
    public func updateMapCenter(to coordinate: CLLocationCoordinate2D) {
        sendMapAction(.pan(to: coordinate, userCoord: localPlayerMember.coordinate))
    }
    
    public func setMapCenterLockState(_ state: MapCenterLockState) {
        if state == .locked {
            sendMapAction(.centerOnLocalUser)
        } else {
            let center = currentMapCenter ?? localPlayerMember.coordinate
            mapStateMachine = MapStateMachine(
                trackingState: .unlocked(latitude: center.latitude, longitude: center.longitude),
                scaleMeters: selectedScaleMeters,
                presentation: selectedPresentation,
                centerTriggerCount: radarCenterTrigger
            )
            mapCenterLockState = .unlocked
            currentMapCenter = center
        }
    }
    
    public func updateMapScale(meters: Double) {
        sendMapAction(.setScale(meters: meters))
    }
    
    public func centerMapOnLocalUser() {
        sendMapAction(.centerOnLocalUser)
    }
    
    public func resetMapToDefaultCenterAndZoom() {
        sendMapAction(.centerOnLocalUser)
    }
    
    public func togglePresentation() {
        sendMapAction(.togglePresentation)
    }
    
    // Login Field Error States
    @Published public var callsignError: Bool = false
    @Published public var squadNameError: Bool = false
    @Published public var pinError: Bool = false
    @Published public var databaseURLError: Bool = false

    public func clearFieldErrors() {
        callsignError = false
        squadNameError = false
        pinError = false
        databaseURLError = false
    }
    
    // Pro Tier Tactical Indicators
    @Published public var localIndicators: [String: TacticalIndicator] = [:] {
        didSet {
            updateAllTacticalIndicators()
        }
    }
    
    @Published public private(set) var allTacticalIndicators: [TacticalIndicator] = []
    
    private var isUpdatingTacticalIndicators = false
    
    public func updateAllTacticalIndicators(room: SquadRoom? = nil) {
        guard !isUpdatingTacticalIndicators else { return }
        isUpdatingTacticalIndicators = true
        defer { isUpdatingTacticalIndicators = false }
        
        let currentRoom = room ?? firebaseManager.activeRoom
        let now = Date().timeIntervalSince1970
        deletedIndicatorTombstones = deletedIndicatorTombstones.filter { now - $0.value < 600 }
        
        var mergedMap = localIndicators
        if let currentRoom = currentRoom {
            for (id, ind) in currentRoom.indicators {
                if deletedIndicatorTombstones[id] == nil {
                    mergedMap[id] = ind
                }
            }
        }
        
        for tombstoneId in deletedIndicatorTombstones.keys {
            mergedMap.removeValue(forKey: tombstoneId)
        }
        
        let rawIndicators = Array(mergedMap.values)
        if rawIndicators.isEmpty {
            if !allTacticalIndicators.isEmpty { allTacticalIndicators = [] }
            syncTacticalToWatchConnectivity()
            return
        }
        
        let mapped = rawIndicators.map { ind -> TacticalIndicator in
            var updated = ind
            let trimmedPlacedBy = ind.placedByMemberId.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // 1. Direct or case-insensitive match in current room members by member ID or dictionary key
            var resolvedMember: SquadMember? = nil
            if let members = currentRoom?.members {
                if let direct = members[trimmedPlacedBy] ?? members[ind.placedByMemberId] {
                    resolvedMember = direct
                } else if let caseMatch = members.first(where: {
                    $0.key.caseInsensitiveCompare(trimmedPlacedBy) == .orderedSame ||
                    $0.value.id.caseInsensitiveCompare(trimmedPlacedBy) == .orderedSame
                })?.value {
                    resolvedMember = caseMatch
                } else if let callsignMatch = members.values.first(where: {
                    !$0.callsign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    $0.callsign.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmedPlacedBy) == .orderedSame
                }) {
                    resolvedMember = callsignMatch
                }
            }
            
            let trimmedLocalId = self.myMemberId.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedLocalCallsign = self.myCallsign.trimmingCharacters(in: .whitespacesAndNewlines)
            let isLocalPlayer = !trimmedPlacedBy.isEmpty && (
                trimmedPlacedBy.caseInsensitiveCompare(trimmedLocalId) == .orderedSame ||
                (!trimmedLocalCallsign.isEmpty && trimmedPlacedBy.caseInsensitiveCompare(trimmedLocalCallsign) == .orderedSame)
            )
            
            if let member = resolvedMember, !member.callsign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updated.placedByCallsign = member.callsign
            } else if isLocalPlayer, !trimmedLocalCallsign.isEmpty {
                updated.placedByCallsign = trimmedLocalCallsign
            } else if let existing = ind.placedByCallsign?.trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
                updated.placedByCallsign = existing
            } else {
                updated.placedByCallsign = ""
            }
            return updated
        }
        
        let sorted = mapped.sorted { $0.timestamp < $1.timestamp }
        if allTacticalIndicators != sorted {
            allTacticalIndicators = sorted
            syncTacticalToWatchConnectivity()
        }
    }
    
    /// Sweep of expired non-order indicators plus `mti` cap enforcement, run by every member.
    /// The Cloud Function `pruneExcessTacticalIndicators` (see CLOUD_DATA_MANAGEMENT.md) is the
    /// authoritative pruner when it's deployed, but self-hosted rooms may not run Cloud Functions
    /// at all — this mirrors its oldest-first eviction so the cap still holds without one. Every
    /// member computes the same oldest-first overflow from the same merged `allTacticalIndicators`
    /// view, so their deletes target the same IDs; a delete on an already-deleted path is a no-op,
    /// so redundant deletes from multiple members are harmless rather than a race.
    public func enforceTacticalIndicatorMaintenance() {
        let expiredIds = localIndicators.values.filter { $0.category != .squadOrder && $0.isExpired }.map { $0.id }
        let now = Date().timeIntervalSince1970
        for id in expiredIds {
            localIndicators.removeValue(forKey: id)
            deletedIndicatorTombstones[id] = now
        }

        let cap = firebaseManager.activeRoom?.maxTacticalIndicators ?? AppConstants.Subscription.freeTierMaxTacticalIndicators
        let cappedIndicators = allTacticalIndicators.filter { $0.category != .squadOrder }.sorted { $0.timestamp < $1.timestamp }
        guard cappedIndicators.count > cap else { return }
        for indicator in cappedIndicators.prefix(cappedIndicators.count - cap) {
            removeTacticalIndicator(id: indicator.id)
        }
    }
    
    // Squad Members
    @Published public var otherSquadMembers: [SquadMember] = []
    
    public func updateOtherSquadMembers(room: SquadRoom? = nil) {
        let currentRoom = room ?? firebaseManager.activeRoom
        guard let currentRoom = currentRoom else {
            if !otherSquadMembers.isEmpty { otherSquadMembers = [] }
            syncMembershipToWatchConnectivity()
            return
        }
        let filtered = currentRoom.members.values.filter { $0.id != myMemberId }.sorted { $0.id < $1.id }
        if otherSquadMembers != filtered {
            otherSquadMembers = filtered
        }
        syncMembershipToWatchConnectivity()
    }
    
    public var isProUser: Bool {
        subscriptionManager.hasUnlimitedSquadUnlock
    }
    
    @Published public var adaptiveUploadInterval: TimeInterval = AppConstants.Timing.AdaptiveRate.baselineInterval
    public var lastUploadTimestamp: TimeInterval = 0.0
    
    // Method 1: Dead Reckoning & Telemetry Delta Gating State
    public var lastSentLocation: CLLocation? = nil
    public var lastSentHeading: Double? = nil
    public var lastSentHeartRate: Double? = nil
    public var lastSentIsDead: Bool? = nil
    public var lastSentTimestamp: TimeInterval = 0.0
    // One sample further back than lastSentLocation — the minimum history needed to derive a
    // velocity vector for predictive gating (see shouldEmitTelemetry / predictedPositionError).
    public var secondLastSentLocation: CLLocation? = nil
    public var secondLastSentTimestamp: TimeInterval = 0.0

    /// Dead-reckoned positions for `otherSquadMembers`, recomputed locally at
    /// `AppConstants.Timing.DisplayRefresh.remotePlayerDeadReckoningHz` independent of how often
    /// real telemetry actually arrives (see DEAD_RECKONING.md). Keyed by member id. Views should
    /// prefer this over a member's raw `latitude`/`longitude` for smooth remote-position rendering.
    @Published public private(set) var remoteDisplayPositions: [String: CLLocationCoordinate2D] = [:]
    private var deadReckoningTimer: AnyCancellable?
    public var totalTelemetryUploadsEmitted: Int = 0
    public var totalTelemetryUploadsGated: Int = 0
    
    /// Cached host status — updated via Combine only when isHosting, activeRoom, or myMemberId
    /// changes, rather than re-evaluating a dictionary lookup on every sensor tick.
    @Published public private(set) var isCurrentMemberHost: Bool = false
    
    /// Live local player member with live smoothed location, live blended heading (COD + speed weight), and live health stats.
    @Published public private(set) var localPlayerMember: SquadMember = SquadMember(
        id: "",
        callsign: "OPERATOR",
        latitude: AppConstants.Location.fallbackLatitude,
        longitude: AppConstants.Location.fallbackLongitude,
        heading: 0,
        heartRate: AppConstants.Health.defaultRestingHeartRate,
        batteryLevel: AppConstants.UI.defaultBatteryLevel,
        lastUpdatedTimestamp: 0,
        sequenceNumber: 0,
        status: .active,
        role: .player
    )
    
    public func updateLocalPlayerMember() {
        let rawLoc = locationHeadingManager.userLocation?.coordinate ?? AppConstants.Location.fallbackCoordinate
        let rawHeading = locationHeadingManager.blendedHeading
        let hr = isDead ? AppConstants.Health.flatlineHeartRate : (healthKitManager.currentHeartRate > 0 ? healthKitManager.currentHeartRate : AppConstants.Health.defaultRestingHeartRate)
        localPlayerMember = SquadMember(
            id: myMemberId,
            callsign: myCallsign.isEmpty ? "OPERATOR" : myCallsign,
            latitude: rawLoc.latitude,
            longitude: rawLoc.longitude,
            heading: rawHeading,
            heartRate: hr,
            batteryLevel: AppConstants.UI.defaultBatteryLevel,
            lastUpdatedTimestamp: Date().timeIntervalSince1970,
            sequenceNumber: localSequenceCounter,
            status: isDead ? .downed : .active,
            role: isCurrentMemberHost ? .leader : .player
        )
    }
    
    // Dependencies
    public let locationHeadingManager = LocationHeadingManager()
    public let healthKitManager = HealthKitManager()
    public let firebaseManager = FirebaseSyncManager()
    public let subscriptionManager = SubscriptionManager()
    public let watchConnectivityManager: WatchConnectivityManager
    
    // PRD Network Ownership and Activity Tokens
    public var hasNetworkOwnership: Bool {
        #if os(watchOS)
        // Watch is primary cloud client
        return true
        #else
        // Phone connects only if Watch lease is expired/inactive
        return !watchConnectivityManager.isWatchLeaseActive
        #endif
    }
    @Published public var isPhoneActive: Bool = false
    @Published public var isWatchActive: Bool = false

    
    public var lastLowSpeedPayloadTimestamp: TimeInterval = 0
    public var lastLowSpeedPayloadSource: Character = "0"
    
    private var isApplyingRemoteSync: Bool = false
    private var cancellables = Set<AnyCancellable>()
    private var localSequenceCounter: Int64 = 0
    private var timer: AnyCancellable?
    private var freshnessExpiryTimer: AnyCancellable?
    private var deletedIndicatorTombstones: [String: TimeInterval] = [:]
    
    public init(watchConnectivityManager: WatchConnectivityManager = WatchConnectivityManager.shared) {
        self.watchConnectivityManager = watchConnectivityManager
        self.isApplyingRemoteSync = true
        
        let savedCallsign = UserDefaults.standard.string(forKey: AppConstants.Storage.userCallsignKey) ?? ""
        self.myCallsign = savedCallsign
        
        self.myMemberId = GameStateManager.deriveMemberId(fromCallsign: savedCallsign)
        self.savedRoomName = UserDefaults.standard.string(forKey: AppConstants.Storage.savedRoomNameKey) ?? ""
        self.savedPin = UserDefaults.standard.string(forKey: AppConstants.Storage.savedPinKey) ?? ""
        self.customDatabaseURL = UserDefaults.standard.string(forKey: AppConstants.Storage.customDatabaseURLKey) ?? ""
        self.isCustomDatabaseURLEnabled = UserDefaults.standard.object(forKey: AppConstants.Storage.isCustomDatabaseURLEnabledKey) as? Bool ?? true
        self.recentDatabaseURLs = UserDefaults.standard.stringArray(forKey: AppConstants.Storage.recentDatabaseURLsKey) ?? []
        
        let savedUploadHR = UserDefaults.standard.object(forKey: AppConstants.Storage.isUploadHeartRateEnabledKey) as? Bool ?? true
        self.isUploadHeartRateEnabled = savedUploadHR
        
        let savedUploadLoc = UserDefaults.standard.object(forKey: AppConstants.Storage.isUploadLocationEnabledKey) as? Bool ?? true
        self.isUploadLocationEnabled = savedUploadLoc
        
        firebaseManager.localMemberId = myMemberId
        
        #if !os(watchOS)
        // Default resting heart rate on iOS standalone
        self.healthKitManager.currentHeartRate = AppConstants.Health.defaultRestingHeartRate
        #endif
        
        if let savedTheme = UserDefaults.standard.string(forKey: AppConstants.Storage.radarColorThemeKey),
           let theme = RadarColorTheme(rawValue: savedTheme) {
            self.radarColorTheme = theme
        }
        
        self.isDead = watchConnectivityManager.localLS.playerState.isDead
        self.playerVitalStateMachine = PlayerVitalStateMachine(initialState: self.isDead ? .downed : .active(heartRate: AppConstants.Health.defaultRestingHeartRate))
        
        updateLocalPlayerMember()
        updateOtherSquadMembers()
        updateAllTacticalIndicators()
        
        setupWatchConnectivity()
        bindManagers()
        locationHeadingManager.requestPermissions()
        locationHeadingManager.startUpdates()
        
        // Request HealthKit workout session authorization at app launch
        healthKitManager.requestAuthorization()
        
        self.isApplyingRemoteSync = false
    }
    
    // MARK: - Outbound WCSession Structure Synchronization
    
    public func syncConfigToWatchConnectivity(timestamp: TimeInterval? = nil) {
        guard !isApplyingRemoteSync else { return }
        let current = watchConnectivityManager.localLS.config
        let isPro = subscriptionManager.hasUnlimitedSquadUnlock
        if current.callsign == myCallsign &&
           current.roomName == savedRoomName &&
           current.pin == savedPin &&
           current.databaseURL == customDatabaseURL &&
           current.theme == radarColorTheme.rawValue &&
           current.isPro == isPro &&
           current.isUploadHeartRateEnabled == isUploadHeartRateEnabled &&
           current.isUploadLocationEnabled == isUploadLocationEnabled {
            return
        }
        let now = timestamp ?? Date().timeIntervalSince1970
        let config = ConfigSnapshot(
            callsign: myCallsign,
            roomName: savedRoomName,
            pin: savedPin,
            databaseURL: customDatabaseURL,
            theme: radarColorTheme.rawValue,
            isPro: isPro,
            isUploadHeartRateEnabled: isUploadHeartRateEnabled,
            isUploadLocationEnabled: isUploadLocationEnabled,
            configTs: now
        )
        watchConnectivityManager.updateLocalStructures(config: config)
    }
    
    public func syncLoginCycleToWatchConnectivity(timestamp: TimeInterval? = nil) {
        guard !isApplyingRemoteSync else { return }
        let state: LoginCycleState
        if isHosting {
            state = .hostActive
        } else if sessionStateMachine.state.isActiveSession {
            state = .joinActive
        } else {
            state = .inactive
        }
        if watchConnectivityManager.localLS.loginCycle.loginCycle == state {
            return
        }
        let now = timestamp ?? Date().timeIntervalSince1970
        let cycle = LoginCycleSnapshot(loginCycle: state, loginCycleTs: now)
        watchConnectivityManager.updateLocalStructures(loginCycle: cycle)
    }
    
    public func syncPlayerStateToWatchConnectivity(timestamp: TimeInterval? = nil, forceTimestampUpdate: Bool = false) {
        guard !isApplyingRemoteSync else { return }
        let currentSnapshot = watchConnectivityManager.localLS.playerState
        if !forceTimestampUpdate && currentSnapshot.isDead == isDead && timestamp == nil {
            return
        }
        let now = timestamp ?? Date().timeIntervalSince1970
        let ps = PlayerStateSnapshot(isDead: isDead, isDeadTs: now)
        watchConnectivityManager.updateLocalStructures(playerState: ps)
    }
    
    public func syncMembershipToWatchConnectivity(timestamp: TimeInterval? = nil) {
        guard !isApplyingRemoteSync else { return }
        guard let room = firebaseManager.activeRoom else {
            if watchConnectivityManager.localLS.membership.membersJson != "[]" {
                let mem = MembershipSnapshot(membersJson: "[]", memberTs: timestamp ?? Date().timeIntervalSince1970)
                watchConnectivityManager.updateLocalStructures(membership: mem)
            }
            return
        }
        let roster = room.members.values.map { member in
            SquadMember(id: member.id, callsign: member.callsign, latitude: 0.0, longitude: 0.0, role: member.role)
        }.sorted { $0.id < $1.id }
        
        if let data = try? JSONEncoder().encode(roster), let json = String(data: data, encoding: .utf8) {
            if watchConnectivityManager.localLS.membership.membersJson == json {
                return
            }
            let mem = MembershipSnapshot(membersJson: json, memberTs: timestamp ?? Date().timeIntervalSince1970)
            watchConnectivityManager.updateLocalStructures(membership: mem)
        }
    }
    
    public func syncTacticalToWatchConnectivity(timestamp: TimeInterval? = nil) {
        guard !isApplyingRemoteSync else { return }
        let indicators = allTacticalIndicators
        if let data = try? JSONEncoder().encode(indicators), let json = String(data: data, encoding: .utf8) {
            if watchConnectivityManager.localLS.tactical.tacticalJson == json {
                return
            }
            let tac = TacticalSnapshot(tacticalJson: json, tacticalTs: timestamp ?? Date().timeIntervalSince1970)
            watchConnectivityManager.updateLocalStructures(tactical: tac)
        }
    }
    
    // MARK: - Inbound WCSession Callbacks & Watch-Centric Cloud Policy
    
    private func setupWatchConnectivity() {
        // High-speed remote telemetry hook (Watch -> Phone)
        #if os(watchOS)
        firebaseManager.onRemoteTelemetryPacketsReceived = { [weak self] packets in
            guard let self = self else { return }
            var telemetryMap: [String: Any] = [:]
            for packet in packets {
                if packet.memberId != self.myMemberId {
                    telemetryMap[packet.memberId] = packet.toCompactArray()
                }
            }
            if !telemetryMap.isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: telemetryMap),
               let json = String(data: data, encoding: .utf8) {
                let hr = self.isDead ? AppConstants.Health.flatlineHeartRate : (self.healthKitManager.currentHeartRate > 0 ? self.healthKitManager.currentHeartRate : AppConstants.Health.defaultRestingHeartRate)
                self.watchConnectivityManager.advertiseWatchHighSpeed(heartRate: hr, remotePlayerTelemetryJson: json)
            }
        }
        #endif
        
        // 1. High-speed remote telemetry
        watchConnectivityManager.onHighSpeedTelemetryReceived = { [weak self] (telemetryJson: String, freshUntil: TimeInterval) in
            guard let self = self else { return }
            guard let data = telemetryJson.data(using: .utf8),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            
            var packets: [TelemetryPacket] = []
            let roomId = self.firebaseManager.activeRoom?.id ?? self.savedRoomName
            for (memberId, rawVal) in dict {
                if memberId == self.myMemberId { continue }
                if let packet = FirebaseSyncManager.parseTelemetryPacket(memberId: memberId, roomId: roomId, rawValue: rawVal) {
                    packets.append(packet)
                }
            }
            if !packets.isEmpty {
                self.firebaseManager.validateAndProcessPackets(packets)
            }
            #if !os(watchOS)
            self.evaluatePhoneCloudClientPolicy()
            #endif
        }
        
        // 2. High-speed optical heart rate (Watch -> Phone)
        watchConnectivityManager.onHighSpeedHeartRateReceived = { [weak self] (hr: Double, freshUntil: TimeInterval) in
            guard let self = self else { return }
            if self.isDead {
                self.healthKitManager.currentHeartRate = AppConstants.Health.flatlineHeartRate
            } else if hr > 0 {
                self.healthKitManager.currentHeartRate = hr
            }
        }
        
        // 3. Lease status changed (Watch active_until lease monitored on Phone)
        watchConnectivityManager.onWatchLeaseStatusChanged = { [weak self] isWatchActive in
            guard let self = self else { return }
            #if !os(watchOS)
            self.evaluatePhoneCloudClientPolicy()
            #endif
        }
        
        // 4. Low-speed converged snapshot received
        watchConnectivityManager.onLowSpeedConvergenceStateChanged = { [weak self] (mergedSnapshot: LowSpeedSnapshot) in
            guard let self = self else { return }
            self.lastLowSpeedPayloadTimestamp = Date().timeIntervalSince1970
            #if os(watchOS)
            self.lastLowSpeedPayloadSource = "P"
            #else
            self.lastLowSpeedPayloadSource = "W"
            #endif
            self.isApplyingRemoteSync = true
            
            // Config adoption
            let config = mergedSnapshot.config
            // Captured before the write below so the room-lifecycle switch can tell whether the
            // room name textbox actually changed, rather than comparing against
            // firebaseManager.activeRoom?.id — which is the derived (salted+padded) Firebase room
            // id, never equal to the plain name carried in config.roomName.
            let previousRoomName = self.savedRoomName
            if !config.callsign.isEmpty && self.myCallsign != config.callsign {
                self.myCallsign = config.callsign
            }
            if !config.roomName.isEmpty && self.savedRoomName != config.roomName {
                self.savedRoomName = config.roomName
            }
            if !config.pin.isEmpty && self.savedPin != config.pin {
                self.savedPin = config.pin
            }
            // Unlike roomName/pin above, empty is a meaningful value here ("use the shared
            // default project"), so it's adopted unconditionally rather than skipped.
            if self.customDatabaseURL != config.databaseURL {
                self.customDatabaseURL = config.databaseURL
            }
            if let theme = RadarColorTheme(rawValue: config.theme), self.radarColorTheme != theme {
                self.radarColorTheme = theme
            }
            if self.subscriptionManager.hasUnlimitedSquadUnlock != config.isPro {
                self.subscriptionManager.hasUnlimitedSquadUnlock = config.isPro
                UserDefaults.standard.set(config.isPro, forKey: AppConstants.Storage.hasUnlimitedSquadUnlockKey)
            }
            if self.isUploadHeartRateEnabled != config.isUploadHeartRateEnabled {
                self.isUploadHeartRateEnabled = config.isUploadHeartRateEnabled
                UserDefaults.standard.set(config.isUploadHeartRateEnabled, forKey: AppConstants.Storage.isUploadHeartRateEnabledKey)
            }
            if self.isUploadLocationEnabled != config.isUploadLocationEnabled {
                self.isUploadLocationEnabled = config.isUploadLocationEnabled
                UserDefaults.standard.set(config.isUploadLocationEnabled, forKey: AppConstants.Storage.isUploadLocationEnabledKey)
            }
            
            // Player state adoption
            let ps = mergedSnapshot.playerState
            if self.isDead != ps.isDead {
                self.setDead(ps.isDead, syncRemote: false)
            }
            
            // Room lifecycle adoption
            let cycle = mergedSnapshot.loginCycle
            switch cycle.loginCycle {
            case .hostActive:
                if previousRoomName != config.roomName || !self.isTacticalSessionActive {
                    self.adoptCompanionSession(roomName: config.roomName, isHosting: true, pin: config.pin)
                }
            case .joinActive:
                if previousRoomName != config.roomName || !self.isTacticalSessionActive {
                    self.adoptCompanionSession(roomName: config.roomName, isHosting: false, pin: config.pin)
                }
            case .inactive:
                if self.isTacticalSessionActive || self.firebaseManager.activeRoom != nil || self.isHosting {
                    self.isHosting = false
                    self.isInitiatingHost = false
                    self.isJoining = false
                    self.stopTacticalSession()
                    self.purgeLocalSessionAndIcons()
                    self.firebaseManager.resetLocalSessionAndIcons()
                }
            }
            
            // Tactical indicators adoption — watch only (phone is the canonical owner of localIndicators)
            #if os(watchOS)
            if let tacData = mergedSnapshot.tactical.tacticalJson.data(using: .utf8),
               let indicators = try? JSONDecoder().decode([TacticalIndicator].self, from: tacData) {
                var newLocalMap: [String: TacticalIndicator] = [:]
                for ind in indicators {
                    newLocalMap[ind.id] = ind
                }
                self.localIndicators = newLocalMap
                self.updateAllTacticalIndicators()
            }
            #endif
            
            // Membership adoption: update room members while preserving live coordinates
            if cycle.loginCycle != .inactive,
               let memData = mergedSnapshot.membership.membersJson.data(using: .utf8),
               let members = try? JSONDecoder().decode([SquadMember].self, from: memData),
               !members.isEmpty {
                var room = self.firebaseManager.activeRoom ?? SquadRoom(id: self.savedRoomName.isEmpty ? config.roomName : self.savedRoomName, hostId: "")
                var hasChanges = false
                for member in members {
                    if var existing = room.members[member.id] {
                        if existing.callsign != member.callsign || existing.role != member.role {
                            existing.callsign = member.callsign
                            existing.role = member.role
                            room.members[member.id] = existing
                            hasChanges = true
                        }
                    } else {
                        room.members[member.id] = member
                        hasChanges = true
                    }
                }
                if hasChanges {
                    self.firebaseManager.activeRoom = room
                    self.updateOtherSquadMembers(room: room)
                    self.updateLocalPlayerMember()
                }
            }
            
            self.isApplyingRemoteSync = false
        }
        
        // 5. Reachability changes
        watchConnectivityManager.onReachabilityChanged = { [weak self] _ in
            guard let self = self else { return }
            #if !os(watchOS)
            self.evaluatePhoneCloudClientPolicy()
            #endif
        }
    }
    
    /// Watch-Centric Cloud Policy:
    /// Watch is ALWAYS the primary cloud client during an active session.
    /// Phone is on stand-by and only connects to cloud if Watch lease expires (Phone.Time > w2p_hs.active_until).
    public func evaluatePhoneCloudClientPolicy() {
        #if !os(watchOS)
        let isWatchActive = watchConnectivityManager.isWatchLeaseActive
        let hasActiveSession = isTacticalSessionActive
        
        if hasActiveSession {
            if isWatchActive {
                // Watch is active cloud client; Phone stands down to conserve battery
                if firebaseManager.isConnected {
                    firebaseManager.stopTelemetryPolling()
                }
            } else {
                // Watch is absent or lease expired; Phone assumes cloud client duties
                if let roomId = firebaseManager.activeRoom?.id ?? (!savedRoomName.isEmpty ? savedRoomName : nil) {
                    firebaseManager.startTelemetryPolling(roomId: roomId)
                }
            }
        }
        #endif
    }
    
    private func bindManagers() {



        firebaseManager.$activeRoom
            .sink { [weak self] room in
                guard let self = self else { return }
                #if os(watchOS)
                let isCompanionActive = self.isPhoneActive || ((self.watchConnectivityManager.latestRemoteHSFreshUntil > Date().timeIntervalSince1970) && self.watchConnectivityManager.isReachable)
                #else
                let isCompanionActive = false
                #endif
                if room != nil && !self.isApplyingRemoteSync && !isCompanionActive {
                    self.lastLowSpeedPayloadSource = "N"
                    self.lastLowSpeedPayloadTimestamp = Date().timeIntervalSince1970
                }
            }
            .store(in: &cancellables)
        
        firebaseManager.$errorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.errorMessage = error
            }
            .store(in: &cancellables)
        
        Publishers.CombineLatest3(
            $isHosting,
            firebaseManager.$activeRoom,
            $myMemberId
        )
        .sink { [weak self] isHosting, room, memberId in
            guard let self = self else { return }
            let isHost: Bool
            if isHosting {
                isHost = true
            } else if let room = room {
                isHost = room.hostId == memberId || (room.members[memberId]?.role == .leader)
            } else {
                isHost = false
            }
            if self.isCurrentMemberHost != isHost {
                self.isCurrentMemberHost = isHost
            }
        }
        .store(in: &cancellables)
            
        firebaseManager.$activeRoom
            .sink { [weak self] newRoom in
                guard let self = self else { return }
                self.updateOtherSquadMembers(room: newRoom)
                self.updateAllTacticalIndicators(room: newRoom)
                self.updateLocalPlayerMember()
                self.enforceTacticalIndicatorMaintenance()
            }
            .store(in: &cancellables)
            
        Publishers.CombineLatest(firebaseManager.$activeRoom, firebaseManager.networkQualityMonitor.$connectionGrade)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recalculateAdaptiveUploadInterval()
            }
            .store(in: &cancellables)
            
        subscriptionManager.$hasUnlimitedSquadUnlock
            .dropFirst()
            .sink { [weak self] isUnlocked in
                guard let self = self, !self.isApplyingRemoteSync else { return }
                self.syncConfigToWatchConnectivity()
            }
            .store(in: &cancellables)
            
        // Stream location updates to network telemetry.
        locationHeadingManager.$userLocation
            .compactMap { $0 }
            .sink { [weak self] loc in
                guard let self = self else { return }
                self.broadcastLocalTelemetry(location: loc, force: false)
            }
            .store(in: &cancellables)
        
        // Stream heart rate updates
        healthKitManager.$currentHeartRate
            .sink { [weak self] hr in
                guard let self = self else { return }
                #if os(watchOS)
                let effectiveHr = self.isDead ? AppConstants.Health.flatlineHeartRate : hr
                if effectiveHr > 0 || self.isDead {
                    self.watchConnectivityManager.advertiseWatchHighSpeed(heartRate: effectiveHr)
                }
                #endif
                self.broadcastLocalTelemetry(heartRate: hr, force: false)
            }
            .store(in: &cancellables)
        
        // Coalesced local-member refresh
        Publishers.MergeMany(
            locationHeadingManager.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            healthKitManager.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            locationHeadingManager.$userLocation.map { _ in () }.eraseToAnyPublisher(),
            locationHeadingManager.$blendedHeading.map { _ in () }.eraseToAnyPublisher(),
            healthKitManager.$currentHeartRate.map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .seconds(0), scheduler: RunLoop.main)
        .sink { [weak self] in
            self?.updateLocalPlayerMember()
            self?.objectWillChange.send()
        }
        .store(in: &cancellables)
    }
    
    // MARK: - Adaptive Rate Control
    
    public func currentHeartbeatFallbackInterval() -> TimeInterval {
        let memberCount = firebaseManager.activeRoom?.members.count ?? 0
        return AppConstants.Timing.ConstantBandwidth.refreshInterval(forPlayerCount: memberCount)
    }

    public func recalculateAdaptiveUploadInterval() {
        let memberCount = firebaseManager.activeRoom?.members.count ?? 0
        let grade = firebaseManager.networkQualityMonitor.connectionGrade

        let calculatedInterval = FirebaseSyncManager.solveUpdateInterval(playerCount: memberCount)

        // Keep the display-side stale threshold (SquadMember.isStale) in sync with the
        // room-size-scaled update interval, so peers gray out at Y * T(P), not a fixed value.
        SquadMember.defaultUpdateInterval = calculatedInterval

        let newInterval: TimeInterval
        if grade == .critical || grade == .offline {
            newInterval = max(AppConstants.Timing.AdaptiveRate.criticalInterval, calculatedInterval)
        } else if grade == .poor {
            newInterval = max(AppConstants.Timing.AdaptiveRate.poorInterval, calculatedInterval)
        } else {
            newInterval = calculatedInterval
        }

        if abs(self.adaptiveUploadInterval - newInterval) > AppConstants.Timing.AdaptiveRate.intervalChangeEpsilon {
            self.adaptiveUploadInterval = newInterval
            if timer != nil {
                restartHeartbeatTimer()
            }
        }
    }
    
    private func restartHeartbeatTimer() {
        timer?.cancel()
        let interval = currentHeartbeatFallbackInterval()
        timer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.broadcastLocalTelemetry(force: true)
            }
    }
    
    // MARK: - Game Lifecycle
    
    public func startTacticalSession() {
        locationHeadingManager.requestPermissions()
        locationHeadingManager.startUpdates()
        healthKitManager.requestAuthorization { [weak self] _ in
            self?.healthKitManager.startLiveHeartRateSession()
        }

        restartHeartbeatTimer()
        startDeadReckoningTimer()
        startTTLRefreshTimer()
    }

    public func stopTacticalSession() {
        isHosting = false
        isInitiatingHost = false
        isJoining = false
        // Compass + GPS keep running even when logged out so the "me" icon on the map
        // always reflects live heading (see LocationHeadingManager.startUpdates/stopUpdates).
        healthKitManager.stopLiveHeartRateSession()
        timer?.cancel()
        timer = nil
        deadReckoningTimer?.cancel()
        deadReckoningTimer = nil
        freshnessExpiryTimer?.cancel()
        freshnessExpiryTimer = nil
        remoteDisplayPositions = [:]
        lastSentLocation = nil
        lastSentHeading = nil
        lastSentHeartRate = nil
        lastSentIsDead = nil
        lastSentTimestamp = 0.0
        secondLastSentLocation = nil
        secondLastSentTimestamp = 0.0
        sendSessionAction(.leave)
        purgeLocalSessionAndIcons()
    }

    /// Re-pushes `exp` on all three top-level trees once per hour while this member is hosting,
    /// keeping an actively-hosted room alive past the idle cutoff (see CLOUD_DATA_MANAGEMENT.md §5).
    /// Not server-enforced; gated client-side on `isCurrentMemberHost`.
    private func startTTLRefreshTimer() {
        freshnessExpiryTimer?.cancel()
        freshnessExpiryTimer = Timer.publish(every: AppConstants.Timing.Inactivity.ttlRefreshIntervalSeconds, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, self.isCurrentMemberHost, let roomId = self.firebaseManager.activeRoom?.id else { return }
                self.firebaseManager.refreshRoomExpiry(roomId: roomId)
            }
    }

    /// Recomputes `remoteDisplayPositions` at a fixed cadence
    /// (`AppConstants.Timing.DisplayRefresh.remotePlayerDeadReckoningHz`), independent of the
    /// network's actual telemetry arrival rate — see DEAD_RECKONING.md.
    private func startDeadReckoningTimer() {
        deadReckoningTimer?.cancel()
        deadReckoningTimer = Timer.publish(every: AppConstants.Timing.DisplayRefresh.remotePlayerDeadReckoningIntervalSeconds, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshRemoteDisplayPositions()
            }
    }

    private func refreshRemoteDisplayPositions() {
        guard !otherSquadMembers.isEmpty else {
            if !remoteDisplayPositions.isEmpty { remoteDisplayPositions = [:] }
            return
        }
        let now = Date().timeIntervalSince1970
        var positions: [String: CLLocationCoordinate2D] = [:]
        positions.reserveCapacity(otherSquadMembers.count)
        for member in otherSquadMembers {
            positions[member.id] = member.extrapolatedCoordinate(at: now)
        }
        remoteDisplayPositions = positions
    }
    
    public func purgeLocalSessionAndIcons() {
        deletedIndicatorTombstones.removeAll()
        localIndicators.removeAll()
        allTacticalIndicators.removeAll()
        otherSquadMembers.removeAll()
        firebaseManager.resetLocalSessionAndIcons()
        isDead = AppConstants.Health.defaultIsDead
        sendPlayerVitalAction(.setKIA(AppConstants.Health.defaultIsDead))
        updateLocalPlayerMember()
        syncPlayerStateToWatchConnectivity(forceTimestampUpdate: true)
        syncMembershipToWatchConnectivity()
        syncTacticalToWatchConnectivity()
    }
    
    public func purgeIconsOnLogout() {
        purgeLocalSessionAndIcons()
    }
    
    public func setWristActive(_ active: Bool) {
        firebaseManager.setWristActive(active)
        if active {
            locationHeadingManager.exitLowPowerMode()
        } else {
            locationHeadingManager.enterLowPowerMode()
        }
    }
    
    public func handleAppResume() {
        locationHeadingManager.exitLowPowerMode()
        locationHeadingManager.startUpdates()
        if isTacticalSessionActive {
            healthKitManager.resumeLiveHeartRateSession()
        }
        firebaseManager.setWristActive(true)
        #if !os(watchOS)
        evaluatePhoneCloudClientPolicy()
        #endif
    }

    
    public func handleAppSuspend() {
        locationHeadingManager.enterLowPowerMode()
        if isTacticalSessionActive {
            healthKitManager.pauseLiveHeartRateSession()
        } else {
            healthKitManager.stopLiveHeartRateSession()
        }
        firebaseManager.setWristActive(false)
    }
    
    public func triggerWakeBurst() {
        firebaseManager.triggerWakeBurst()
    }
    
    // MARK: - Room Actions

    /// Generates a short, Firebase-key-safe random identifier, used as a fallback id for a
    /// squad member constructed/decoded without one (e.g. a roster entry missing `mid`).
    ///
    /// This id is embedded as a path segment on every telemetry/tactical/room write and delta
    /// event a device ever sends or receives — a `UUID().uuidString` (36 chars) here costs
    /// ~28 bytes of wire overhead on every single packet, on top of the actual payload. An
    /// 8-character id from a 32-symbol alphabet (Crockford-style, excluding easily-confused
    /// O/0/I/1) still carries 40 bits of entropy, far more than enough to avoid a collision
    /// within one room's member cap (birthday-bound collision odds at 999 members are ~4e-7),
    /// while cutting that per-packet path overhead by roughly three quarters.
    ///
    /// Note: the local device's own `myMemberId` no longer uses this — see `deriveMemberId`.
    public static let shortMemberIdLength = 8

    public static func generateShortMemberId(length: Int = shortMemberIdLength) -> String {
        let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }

    /// Deterministically derives the local device's `myMemberId` from its callsign, so the
    /// phone and watch companion apps — which each run an independent `GameStateManager` with
    /// no shared `UserDefaults` (no App Group entitlement) — converge on the same member id for
    /// the same callsign without depending on a WatchConnectivity sync round-trip. Mirrors
    /// `FirebaseSyncManager.deriveRoomPadding`'s SHA256-into-Crockford-alphabet pattern, always
    /// emitting exactly `shortMemberIdLength` characters to satisfy the server-side
    /// `$memberId.length == 8` validation in database.rules.json regardless of callsign content.
    public static func deriveMemberId(fromCallsign callsign: String) -> String {
        let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
        let normalized = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let combined = "memberid:\(normalized)"
        let digest = Array(SHA256.hash(data: Data(combined.utf8)))
        return String(digest.prefix(shortMemberIdLength).map { alphabet[Int($0) % alphabet.count] })
    }

    /// ASCII `[A-Za-z0-9]` only — the character set every Firebase-RTDB-path-derived text field
    /// (room name, PIN) is restricted to. Deliberately narrower than "not a Firebase-illegal
    /// character": rejecting all non-ASCII outright (Greek letters, emoji, CJK, combining marks)
    /// avoids the grapheme-cluster-vs-UTF-16-length mismatch between Swift's `String.count` (used
    /// to size `deriveRoomPadding`'s output) and the server's `.validate` rule, which counts
    /// UTF-16 code units — a mismatch that let some Unicode names overpad past the 16-character
    /// room-id cap and get silently rejected. See CLOUD_DATA_MANAGEMENT.md §6.A.
    private static let asciiAlphanumerics = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    /// Sanitizes free-typed text destined to become (part of) a Firebase RTDB path key — today,
    /// only the room/squad name — to ASCII alphanumerics, uppercased, truncated to `maxLength`.
    public static func sanitizeRoomNameInput(_ input: String, maxLength: Int = AppConstants.UI.maxRoomNameEntryLength) -> String {
        let filtered = String(String.UnicodeScalarView(input.unicodeScalars.filter { asciiAlphanumerics.contains($0) }))
        return String(filtered.uppercased().prefix(maxLength))
    }

    public static func sanitizePinInput(_ input: String) -> String {
        let wordMapping = AppConstants.UI.pinWordMapping

        let lowercased = input.lowercased()
        let tokens = lowercased.components(separatedBy: CharacterSet.alphanumerics.inverted)
        var result = ""
        for token in tokens {
            if let digit = wordMapping[token] {
                result.append(digit)
            } else {
                result.append(String(String.UnicodeScalarView(token.unicodeScalars.filter { asciiAlphanumerics.contains($0) })))
            }
        }

        return String(result.prefix(AppConstants.UI.maxPinLength))
    }
    
    /// Resolves which Firebase Realtime Database the upcoming host/join session should use and
    /// applies it to `firebaseManager`. Precedence: an explicit `databaseURL` (e.g. decoded from
    /// a scanned QR code) always wins, regardless of `isCustomDatabaseURLEnabled` — that toggle
    /// only governs this device's own persisted `customDatabaseURL` setting, not a URL handed to
    /// it by a host's join code. Otherwise, if the custom URL feature is enabled, the persisted
    /// `customDatabaseURL` setting is used; otherwise (or if it's empty) the shared default, so a
    /// session started with no override never inherits a stale one from a previous session.
    /// Returns `false` (and sets `databaseURLError`) when a non-empty custom URL fails
    /// `AppConstants.Network.isValidDatabaseURL` — callers must not proceed to host/join in that
    /// case, since an unvalidated string would otherwise reach `Database.database(url:)`, which
    /// terminates the app with an uncaught exception rather than failing gracefully.
    @discardableResult
    private func applyDatabaseURL(_ explicit: String?) -> Bool {
        let trimmedExplicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedExplicit.isEmpty {
            guard AppConstants.Network.isValidDatabaseURL(trimmedExplicit) else {
                databaseURLError = true
                return false
            }
            firebaseManager.databaseURL = trimmedExplicit
            rememberRecentDatabaseURL(trimmedExplicit)
            return true
        }
        guard isCustomDatabaseURLEnabled else {
            firebaseManager.databaseURL = AppConstants.Network.defaultDatabaseURL
            return true
        }
        let trimmedSaved = customDatabaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSaved.isEmpty || AppConstants.Network.isValidDatabaseURL(trimmedSaved) else {
            databaseURLError = true
            return false
        }
        firebaseManager.databaseURL = trimmedSaved.isEmpty ? AppConstants.Network.defaultDatabaseURL : trimmedSaved
        if !trimmedSaved.isEmpty {
            rememberRecentDatabaseURL(trimmedSaved)
        }
        return true
    }

    @discardableResult
    public func hostRoom(name: String, pin: String? = nil, databaseURL: String? = nil, completion: ((Bool) -> Void)? = nil) -> Bool {
        let cleanedName = GameStateManager.sanitizeRoomNameInput(name)
        let cleanedCallsign = myCallsign.trimmingCharacters(in: .whitespacesAndNewlines)

        clearFieldErrors()
        guard applyDatabaseURL(databaseURL) else {
            let err = FirebaseSyncError.invalidDatabaseURL
            errorMessage = err.localizedDescription
            completion?(false)
            return false
        }

        if cleanedName.isEmpty {
            squadNameError = true
            let err = FirebaseSyncError.emptyRoomName
            errorMessage = err.localizedDescription
            completion?(false)
            return false
        }

        if cleanedCallsign.isEmpty {
            callsignError = true
            let err = FirebaseSyncError.emptyCallsign
            errorMessage = err.localizedDescription
            completion?(false)
            return false
        }

        self.savedRoomName = cleanedName

        let cleanedPin = pin.map { GameStateManager.sanitizePinInput($0) }
        if let cp = cleanedPin, !cp.isEmpty {
            self.savedPin = cp
        }
        guard let cleanedPin, !cleanedPin.isEmpty else {
            pinError = true
            let err = FirebaseSyncError.incorrectPin
            errorMessage = err.localizedDescription
            completion?(false)
            return false
        }

        let squadId = cleanedName + FirebaseSyncManager.deriveRoomPadding(pin: cleanedPin, name: cleanedName)
        let hostMember = makeCurrentSquadMember(role: .leader)
        let passHash = FirebaseSyncManager.hashPin(cleanedPin, salt: squadId)

        let capacity = subscriptionManager.hasUnlimitedSquadUnlock ? AppConstants.Subscription.proTierMaxCapacity : AppConstants.Subscription.freeTierMaxCapacity
        let maxTactical = subscriptionManager.hasUnlimitedSquadUnlock ? AppConstants.Subscription.proTierMaxTacticalIndicators : AppConstants.Subscription.freeTierMaxTacticalIndicators

        let room = SquadRoom(
            id: squadId,
            hostId: myMemberId,
            maxCapacity: capacity,
            maxTacticalIndicators: maxTactical,
            pinHash: passHash,
            members: [myMemberId: hostMember]
        )

        sendSessionAction(.startHost(name: cleanedName, pin: cleanedPin))
        errorMessage = nil
        purgeLocalSessionAndIcons()
        firebaseManager.setEncryptionContext(pin: cleanedPin, roomId: squadId)

        firebaseManager.createRoom(room) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.sendSessionAction(.hostSuccess(room: room))
                self.clearFieldErrors()
                self.startTacticalSession()
                completion?(true)
            case .failure(let error):
                self.sendSessionAction(.hostFailure(error: error.localizedDescription))
                switch error {
                case .roomAlreadyExists, .emptyRoomName:
                    self.squadNameError = true
                case .emptyCallsign, .duplicateCallsign:
                    self.callsignError = true
                default:
                    break
                }
                completion?(false)
            }
        }
        return true
    }
    
    /// - Parameter isPreDerivedId: true when `id` already *is* the full derived room id. false
    ///   (default — manual entry, and also QR-scanned joins, whose payload carries the plain
    ///   room name rather than the derived id) means `id` is the plain (<=12-char) name to
    ///   truncate and re-derive the full id from.
    public func joinRoom(id: String, name: String? = nil, pin: String? = nil, databaseURL: String? = nil, isPreDerivedId: Bool = false, onResult: ((Result<SquadRoom, FirebaseSyncError>) -> Void)?) {
        let truncatedName = GameStateManager.sanitizeRoomNameInput(
            id,
            maxLength: isPreDerivedId ? AppConstants.UI.maxRoomNameLength : AppConstants.UI.maxRoomNameEntryLength
        )
        let cleanCallsign = myCallsign.trimmingCharacters(in: .whitespacesAndNewlines)

        clearFieldErrors()
        guard applyDatabaseURL(databaseURL) else {
            onResult?(.failure(.invalidDatabaseURL))
            return
        }

        if truncatedName.isEmpty {
            self.squadNameError = true
            let err = FirebaseSyncError.emptyRoomName
            self.errorMessage = err.localizedDescription
            onResult?(.failure(err))
            return
        }

        if cleanCallsign.isEmpty {
            self.callsignError = true
            let err = FirebaseSyncError.emptyCallsign
            self.errorMessage = err.localizedDescription
            onResult?(.failure(err))
            return
        }

        // truncatedName is the plain typed name only when isPreDerivedId is false. For a
        // QR-scanned join it's the full derived (salted+padded) room id instead — persisting
        // that into savedRoomName (the "name I last typed to host/join with", reused to prefill
        // the Create/Settings name field) would surface a garbage string next time, and if
        // re-hosted, get re-salted into a nonsense QR code. Only save it when it's actually a
        // plain name the user typed.
        if !isPreDerivedId {
            self.savedRoomName = truncatedName
        }

        let cleanedPin = pin.map { GameStateManager.sanitizePinInput($0) }
        if let cp = cleanedPin, !cp.isEmpty {
            self.savedPin = cp
        }
        guard let cleanedPin, !cleanedPin.isEmpty else {
            self.pinError = true
            let err = FirebaseSyncError.incorrectPin
            self.errorMessage = err.localizedDescription
            onResult?(.failure(err))
            return
        }

        let cleanId = isPreDerivedId ? truncatedName : (truncatedName + FirebaseSyncManager.deriveRoomPadding(pin: cleanedPin, name: truncatedName))

        sendSessionAction(.startJoin(id: cleanId, pin: cleanedPin))
        errorMessage = nil
        purgeLocalSessionAndIcons()
        firebaseManager.setEncryptionContext(pin: cleanedPin, roomId: cleanId)

        let localMember = makeCurrentSquadMember(role: .player)

        firebaseManager.joinRoom(id: cleanId, member: localMember, pin: cleanedPin) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let room):
                self.sendSessionAction(.joinSuccess(room: room))
                self.clearFieldErrors()
                self.startTacticalSession()
                onResult?(.success(room))
            case .failure(let error):
                self.sendSessionAction(.joinFailure(error: error.localizedDescription))
                switch error {
                case .duplicateCallsign, .emptyCallsign:
                    self.callsignError = true
                case .roomNotFound, .roomAlreadyExists, .emptyRoomName:
                    self.squadNameError = true
                case .incorrectPin, .incorrectPassword:
                    self.pinError = true
                default:
                    break
                }
                onResult?(.failure(error))
            }
        }
    }
    
    public func joinRoom(id: String, name: String? = nil, pin: String? = nil, databaseURL: String? = nil, isPreDerivedId: Bool = false, completion: ((Bool) -> Void)? = nil) {
        joinRoom(id: id, name: name, pin: pin, databaseURL: databaseURL, isPreDerivedId: isPreDerivedId) { (result: Result<SquadRoom, FirebaseSyncError>) in
            switch result {
            case .success:
                completion?(true)
            case .failure:
                completion?(false)
            }
        }
    }
    
    public func adoptCompanionSession(roomName: String, isHosting: Bool, pin: String? = nil) {
        let cleanId = roomName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanId.isEmpty else { return }

        if self.savedRoomName != cleanId {
            self.savedRoomName = cleanId
        }
        if let pin = pin, !pin.isEmpty {
            self.savedPin = pin
        }
        self.isHosting = isHosting
        self.isInitiatingHost = false
        self.isJoining = false
        self.clearFieldErrors()
        self.errorMessage = nil

        firebaseManager.setEncryptionContext(pin: self.savedPin, roomId: cleanId)

        self.isApplyingRemoteSync = true
        firebaseManager.connectToExistingRoom(roomId: cleanId) { [weak self] success in
            guard let self = self else { return }
            self.isApplyingRemoteSync = false
            if success {
                self.startTacticalSession()
            }
        }
    }
    
    public func disbandRoom(completion: ((Bool) -> Void)? = nil) {
        let roomId = firebaseManager.activeRoom?.id
        stopTacticalSession()
        purgeLocalSessionAndIcons()
        guard let id = roomId else {
            firebaseManager.leaveRoom(isHost: true, memberId: myMemberId)
            purgeLocalSessionAndIcons()
            completion?(true)
            return
        }
        firebaseManager.disbandRoom(roomId: id) { [weak self] success in
            self?.purgeLocalSessionAndIcons()
            completion?(success)
        }
    }
    
    public func logoutPlayer(completion: ((Bool) -> Void)? = nil) {
        let roomId = firebaseManager.activeRoom?.id
        stopTacticalSession()
        purgeLocalSessionAndIcons()
        guard let id = roomId else {
            firebaseManager.leaveRoom(isHost: false, memberId: myMemberId)
            purgeLocalSessionAndIcons()
            completion?(true)
            return
        }
        firebaseManager.logoutPlayer(roomId: id, memberId: myMemberId) { [weak self] success in
            self?.purgeLocalSessionAndIcons()
            completion?(success)
        }
    }
    
    public func leaveCurrentRoom(completion: ((Bool) -> Void)? = nil) {
        if isCurrentMemberHost {
            disbandRoom(completion: completion)
        } else {
            logoutPlayer(completion: completion)
        }
    }
    
    public func setDead(_ dead: Bool, syncRemote: Bool = true) {
        if !syncRemote {
            isApplyingRemoteSync = true
        }
        sendPlayerVitalAction(.setKIA(dead))
        if !syncRemote {
            isApplyingRemoteSync = false
        }
        let now = Date().timeIntervalSince1970
        if var room = firebaseManager.activeRoom, var member = room.members[myMemberId] {
            member.status = dead ? .downed : .active
            member.heartRate = dead ? AppConstants.Health.flatlineHeartRate : (healthKitManager.currentHeartRate > 0 ? healthKitManager.currentHeartRate : AppConstants.Health.defaultRestingHeartRate)
            member.lastUpdatedTimestamp = now
            room.members[myMemberId] = member
            firebaseManager.activeRoom = room
            firebaseManager.updateMember(member)
        }
        updateLocalPlayerMember()
        updateOtherSquadMembers()
        objectWillChange.send()
        broadcastLocalTelemetry(force: true)
    }
    
    // MARK: - Telemetry Dispatch
    
    private func makeCurrentSquadMember(role: MemberRole) -> SquadMember {
        let loc = locationHeadingManager.userLocation?.coordinate ?? (firebaseManager.activeRoom?.members[myMemberId]?.coordinate ?? AppConstants.Location.fallbackCoordinate)
        let heading = locationHeadingManager.blendedHeading
        let hr = isDead ? AppConstants.Health.flatlineHeartRate : (healthKitManager.currentHeartRate > 0 ? healthKitManager.currentHeartRate : AppConstants.Health.defaultRestingHeartRate)
        
        return SquadMember(
            id: myMemberId,
            callsign: myCallsign,
            latitude: loc.latitude,
            longitude: loc.longitude,
            heading: heading,
            heartRate: hr,
            batteryLevel: AppConstants.UI.defaultBatteryLevel,
            lastUpdatedTimestamp: Date().timeIntervalSince1970,
            sequenceNumber: localSequenceCounter,
            status: isDead ? .downed : .active,
            role: role
        )
    }

    private func updateLocalMember(oldId: String? = nil) {
        guard let room = firebaseManager.activeRoom else { return }
        let lookupId = oldId ?? myMemberId
        guard var member = room.members[lookupId] ?? room.members[myMemberId] else { return }
        
        if let oldId = oldId, oldId != myMemberId {
            firebaseManager.removeMember(id: oldId)
        }
        
        member.callsign = myCallsign
        member.heading = locationHeadingManager.blendedHeading
        member.lastUpdatedTimestamp = Date().timeIntervalSince1970
        firebaseManager.updateMember(member)
    }
    
    public func shouldEmitTelemetry(
        currentLocation: CLLocation,
        currentHeading: Double,
        currentHeartRate: Double,
        currentIsDead: Bool,
        currentTime: TimeInterval,
        force: Bool = false
    ) -> Bool {
        if force { return true }
        
        guard let prevLocation = lastSentLocation,
              let prevHeartRate = lastSentHeartRate,
              let prevIsDead = lastSentIsDead else {
            return true
        }
        
        if prevIsDead != currentIsDead {
            return true
        }
        
        let heartbeatFallback = currentHeartbeatFallbackInterval()
        if (currentTime - lastSentTimestamp) >= heartbeatFallback {
            return true
        }

        if AppConstants.Timing.DeltaGating.heartRateDeltaGatingEnabled,
           abs(currentHeartRate - prevHeartRate) >= AppConstants.Timing.DeltaGating.minHeartRateDeltaBpm {
            return true
        }

        let predictionError = predictedPositionError(currentLocation: currentLocation, currentTime: currentTime, prevLocation: prevLocation)
        return predictionError >= AppConstants.Timing.DeltaGating.maxPredictedPositionErrorMeters
    }

    /// Predicts where a peer's dead-reckoning model would place us right now, using only the last
    /// two *sent* samples — the same two points any peer already received — then returns the
    /// distance between that prediction and our actual current location. Peers extrapolate our
    /// position with simple constant-velocity dead reckoning between updates; if our real position
    /// still matches what that extrapolation would show, sending an update teaches peers nothing new.
    /// With fewer than two prior samples (or a degenerate interval between them), falls back to raw
    /// displacement from the last sent position, since no velocity can be derived yet.
    private func predictedPositionError(currentLocation: CLLocation, currentTime: TimeInterval, prevLocation: CLLocation) -> Double {
        guard let prevPrevLocation = secondLastSentLocation else {
            return currentLocation.distance(from: prevLocation)
        }

        guard let predictedCoordinate = DeadReckoning.predictedCoordinate(
            sampleA: (prevPrevLocation.coordinate, secondLastSentTimestamp),
            sampleB: (prevLocation.coordinate, lastSentTimestamp),
            atTime: currentTime
        ) else {
            return currentLocation.distance(from: prevLocation)
        }

        let predictedLocation = CLLocation(latitude: predictedCoordinate.latitude, longitude: predictedCoordinate.longitude)
        return currentLocation.distance(from: predictedLocation)
    }
    
    public func broadcastLocalTelemetry(
        location: CLLocation? = nil,
        heading: Double? = nil,
        heartRate: Double? = nil,
        force: Bool = false
    ) {
        guard let room = firebaseManager.activeRoom else { return }
        guard hasNetworkOwnership else { return }
        
        let now = Date().timeIntervalSince1970
        if !force && (now - lastUploadTimestamp) < adaptiveUploadInterval {
            return
        }
        
        let currentLoc = location ?? locationHeadingManager.userLocation ?? CLLocation(latitude: AppConstants.Location.fallbackLatitude, longitude: AppConstants.Location.fallbackLongitude)
        let loc = currentLoc.coordinate
        let alt = currentLoc.altitude
        let currentHeading = heading ?? locationHeadingManager.blendedHeading
        
        guard isUploadLocationEnabled else {
            // Location upload opted out: do not upload position / heading telemetry packets to the server
            return
        }
        
        let rawHr = heartRate ?? healthKitManager.currentHeartRate
        let effectiveHr: Double
        if isDead {
            effectiveHr = AppConstants.Health.flatlineHeartRate
        } else if !isUploadHeartRateEnabled {
            // HR upload opted out: broadcast default resting HR (75 BPM)
            effectiveHr = AppConstants.Health.defaultRestingHeartRate
        } else {
            effectiveHr = rawHr > 0 ? rawHr : AppConstants.Health.defaultRestingHeartRate
        }
        let currentHr = effectiveHr
        
        let shouldEmit = shouldEmitTelemetry(
            currentLocation: currentLoc,
            currentHeading: currentHeading,
            currentHeartRate: currentHr,
            currentIsDead: isDead,
            currentTime: now,
            force: force
        )
        
        guard shouldEmit else {
            totalTelemetryUploadsGated += 1
            return
        }
        
        lastUploadTimestamp = now
        totalTelemetryUploadsEmitted += 1
        secondLastSentLocation = lastSentLocation
        secondLastSentTimestamp = lastSentTimestamp
        lastSentLocation = currentLoc
        lastSentHeading = currentHeading
        lastSentHeartRate = currentHr
        lastSentIsDead = isDead
        lastSentTimestamp = now
        
        localSequenceCounter += 1
        
        let packet = TelemetryPacket(
            memberId: myMemberId,
            roomId: room.id,
            latitude: loc.latitude,
            longitude: loc.longitude,
            altitude: alt,
            heading: currentHeading,
            heartRate: currentHr,
            timestamp: now,
            sequenceNumber: localSequenceCounter
        )
        
        firebaseManager.sendTelemetryPacket(packet)
    }
    
    // MARK: - Pro Tier Tactical Indicators Management
    
    public func openIndicatorMenu() {
        if subscriptionManager.hasUnlimitedSquadUnlock {
            showIndicatorMenuSheet = true
        } else {
            showPaywallSheet = true
        }
    }
    
    public func selectIndicatorForPlacement(_ type: TacticalIndicatorType) {
        showIndicatorMenuSheet = false
        pendingIndicatorPlacementType = type
    }
    
    public func cancelIndicatorPlacement() {
        pendingIndicatorPlacementType = nil
    }
    
    public func placeTacticalIndicator(at coordinate: CLLocationCoordinate2D) {
        guard let type = pendingIndicatorPlacementType else { return }
        placeTacticalIndicator(type: type, at: coordinate)
        pendingIndicatorPlacementType = nil
    }
    
    public func placeTacticalIndicator(type: TacticalIndicatorType, at coordinate: CLLocationCoordinate2D) {
        guard subscriptionManager.hasUnlimitedSquadUnlock else {
            showPaywallSheet = true
            return
        }
        
        let roomId = firebaseManager.activeRoom?.id
        let currentIndicators = allTacticalIndicators
        
        if type.category == .squadOrder {
            let existingFromIssuer = currentIndicators.filter { $0.category == .squadOrder && $0.placedByMemberId == myMemberId }
            for ind in existingFromIssuer {
                removeTacticalIndicator(id: ind.id)
            }
        }
        
        let cleanCallsign = myCallsign.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedCallsign = cleanCallsign.isEmpty ? (firebaseManager.activeRoom?.members[myMemberId]?.callsign ?? "") : cleanCallsign
        
        let newIndicator = TacticalIndicator(
            type: type,
            coordinate: coordinate,
            placedByMemberId: myMemberId,
            placedByCallsign: resolvedCallsign
        )

        // Rule 2: enemy + environment indicators share one cap (mti). Compute overflow against
        // the prospective post-add set and stream those deletes to Firebase BEFORE the new
        // indicator's create write, so no observer's stream (or the Cloud Function's onWrite
        // trigger) ever briefly sees more than `cap` indicators on the wire.
        if type.category != .squadOrder {
            let cap = subscriptionManager.hasUnlimitedSquadUnlock ? AppConstants.Subscription.proTierMaxTacticalIndicators : AppConstants.Subscription.freeTierMaxTacticalIndicators
            let prospective = (localIndicators.values.filter { $0.category != .squadOrder } + [newIndicator]).sorted { $0.timestamp < $1.timestamp }
            if prospective.count > cap {
                for old in prospective.prefix(prospective.count - cap) {
                    removeTacticalIndicator(id: old.id)
                }
            }
        }

        deletedIndicatorTombstones.removeValue(forKey: newIndicator.id)
        localIndicators[newIndicator.id] = newIndicator

        if let roomId = roomId {
            firebaseManager.addOrUpdateIndicator(roomId: roomId, indicator: newIndicator)
        }
        updateAllTacticalIndicators()
        enforceTacticalIndicatorMaintenance()
    }
    
    public func removeTacticalIndicator(id: String) {
        deletedIndicatorTombstones[id] = Date().timeIntervalSince1970
        localIndicators.removeValue(forKey: id)
        if var room = firebaseManager.activeRoom {
            room.indicators.removeValue(forKey: id)
            firebaseManager.activeRoom = room
        }
        if let roomId = firebaseManager.activeRoom?.id {
            firebaseManager.removeIndicator(roomId: roomId, indicatorId: id)
        }
        updateAllTacticalIndicators()
    }
}

extension GameStateManager {
    /// 8-character text-based debug field.
    /// - Character 1 (index 0): "Other player" telemetry stream
    ///   - 'N' when receiving other player telemetry from the web (Firebase active room).
    ///   - 'P' when Watch is receiving other player telemetry from Phone companion.
    ///   - '0' when no other player telemetry stream is active.
    /// - Character 2 (index 1): Watch -> Phone HR telemetry stream
    ///   - 'W' when Phone is receiving live HR from Watch companion (or Watch is streaming HR).
    ///   - '0' when no Watch HR stream is active.
    /// - Character 3 (index 2): Low-speed codable source (active within 3.0s of receipt, cycles back to 0 when idle)
    ///   - 'N' when low-speed codable packet received from web (Firebase).
    ///   - 'P' when Watch low-speed packet received from Phone companion.
    ///   - 'W' when Phone low-speed packet received from Watch companion.
    ///   - '0' when idle (> 3.0s without low-speed codable packet) or disconnected.
    /// - Characters 4..8 (indices 3..7): Reserved placeholder zeros ("00000").
    public var debugStatusString: String {
        let otherPlayerChar: Character
        let watchHRChar: Character
        let lowSpeedChar: Character
        let now = Date().timeIntervalSince1970
        
        #if os(watchOS)
        // Character 1: Other player telemetry stream
        let isReceivingFromPhone = (isPhoneActive || watchConnectivityManager.isReachable) && (watchConnectivityManager.latestRemoteHSFreshUntil > now)
        if isReceivingFromPhone {
            otherPlayerChar = "P"
        } else if firebaseManager.isConnected && firebaseManager.activeRoom != nil {
            otherPlayerChar = "N"
        } else {
            otherPlayerChar = "0"
        }
        
        // Character 2: Watch -> Phone HR telemetry stream
        if healthKitManager.currentHeartRate > 0 {
            watchHRChar = "W"
        } else {
            watchHRChar = "0"
        }
        #else
        // Character 1: Other player telemetry stream
        if firebaseManager.isConnected && firebaseManager.activeRoom != nil {
            otherPlayerChar = "N"
        } else {
            otherPlayerChar = "0"
        }
        
        // Character 2: Watch -> Phone HR telemetry stream
        if watchConnectivityManager.latestRemoteHSFreshUntil > now {
            watchHRChar = "W"
        } else {
            watchHRChar = "0"
        }
        #endif
        
        // Character 3: Low-speed codable source (active for 3.0s, cycles back to 0 when idle)
        if (now - lastLowSpeedPayloadTimestamp) < 3.0 {
            lowSpeedChar = lastLowSpeedPayloadSource
        } else {
            lowSpeedChar = "0"
        }
        
        return "\(otherPlayerChar)\(watchHRChar)\(lowSpeedChar)00000"
    }
}

