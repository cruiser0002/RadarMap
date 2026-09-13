import Foundation
import Combine
import CoreLocation
import SwiftUI
import CryptoKit

public final class GameStateManager: ObservableObject {
    // MARK: - WCSession-synced fields
    //
    // Every field below is a pure read/write view onto `watchConnectivityManager.localLS` — the
    // single source of truth shared with the companion device. There is no separate storage here:
    // a local edit writes straight into `localLS` (via the matching `mutateLocal*` call), and a
    // remote convergence merge updating `localLS` *is* these properties changing — there's no
    // separate "adopt the remote value" step. Side effects that used to live in each property's
    // `didSet` (persistence, `myMemberId` re-derivation, `updateLocalMember()`, etc.) now live in
    // the single `$localLS` diff-sink in `bindManagers()`, since that's the one place both local
    // edits and remote merges actually land.
    public var myCallsign: String {
        get { watchConnectivityManager.localLS.config.callsign }
        set { watchConnectivityManager.mutateLocalConfig { $0.callsign = newValue } }
    }
    public var radarColorTheme: RadarColorTheme {
        get { RadarColorTheme(rawValue: watchConnectivityManager.localLS.config.theme) ?? .green }
        set { watchConnectivityManager.mutateLocalConfig { $0.theme = newValue.rawValue } }
    }
    public var savedRoomName: String {
        get { watchConnectivityManager.localLS.config.roomName }
        set { watchConnectivityManager.mutateLocalConfig { $0.roomName = newValue } }
    }
    public var savedPin: String {
        get { watchConnectivityManager.localLS.config.pin }
        set { watchConnectivityManager.mutateLocalConfig { $0.pin = newValue } }
    }
    /// Host-provided Firebase Realtime Database URL for squads that run against their own
    /// Firebase project instead of the shared default (see BRING_YOUR_OWN_FIREBASE.md). Empty means
    /// "use the shared default project."
    public var customDatabaseURL: String {
        get { watchConnectivityManager.localLS.config.databaseURL }
        set { watchConnectivityManager.mutateLocalConfig { $0.databaseURL = newValue } }
    }
    public var isUploadHeartRateEnabled: Bool {
        get { watchConnectivityManager.localLS.config.isUploadHeartRateEnabled }
        set { watchConnectivityManager.mutateLocalConfig { $0.isUploadHeartRateEnabled = newValue } }
    }
    public var isUploadLocationEnabled: Bool {
        get { watchConnectivityManager.localLS.config.isUploadLocationEnabled }
        set {
            watchConnectivityManager.mutateLocalConfig {
                $0.isUploadLocationEnabled = newValue
                if !newValue {
                    $0.isUploadHeartRateEnabled = false
                }
            }
        }
    }
    /// Whether this device encrypts its own outbound telemetry/tactical writes. Synced
    /// phone<->watch via `ConfigSnapshot.isEncryptionEnabled` (not a raw per-device flag) so the
    /// two devices can't disagree about it and silently fail to decrypt each other's payloads —
    /// see docs/CLOUD_DATA_MANAGEMENT.md §5.E.
    public var isEncryptionEnabled: Bool {
        get { watchConnectivityManager.localLS.config.isEncryptionEnabled }
        set {
            watchConnectivityManager.mutateLocalConfig { $0.isEncryptionEnabled = newValue }
            if let roomId = firebaseManager.activeRoom?.id, !roomId.isEmpty {
                firebaseManager.setEncryptionContext(pin: savedPin, roomId: roomId, isEncryptionEnabled: newValue)
            }
        }
    }
    public var myRole: MemberRole {
        get {
            let roleStr = watchConnectivityManager.localLS.config.role
            let parsed = MemberRole(rawValue: roleStr) ?? .player
            if parsed.isProRequired && !subscriptionManager.hasUnlimitedSquadUnlock {
                return .player
            }
            return parsed
        }
        set {
            let effectiveRole = (newValue.isProRequired && !subscriptionManager.hasUnlimitedSquadUnlock) ? .player : newValue
            watchConnectivityManager.mutateLocalConfig { $0.role = effectiveRole.rawValue }
            UserDefaults.standard.set(effectiveRole.rawValue, forKey: AppConstants.Storage.userRoleKey)
            updateLocalPlayerMember()
            if let activeRoom = firebaseManager.activeRoom, var member = activeRoom.members[myMemberId] {
                member.role = effectiveRole
                firebaseManager.activeRoom?.members[myMemberId] = member
                firebaseManager.updateMember(member)
            }
        }
    }
    /// Coarse room-lifecycle state, mirrored from `localLS.loginCycle`. `sessionStateMachine`,
    /// `isInitiatingHost`, and `isJoining` (below) track richer local in-flight state that
    /// `LoginCycleState`'s 3 coarse cases (inactive/hostActive/joinActive) don't capture, and stay
    /// local-only.
    public var isHosting: Bool {
        get { watchConnectivityManager.localLS.loginCycle.loginCycle == .hostActive }
        set { watchConnectivityManager.mutateLocalLoginCycle { $0.loginCycle = newValue ? .hostActive : .inactive } }
    }
    public var isDead: Bool {
        get { watchConnectivityManager.localLS.playerState.isDead }
        set { watchConnectivityManager.mutateLocalPlayerState { $0.isDead = newValue } }
    }

    // MARK: - Local-only fields

    @Published public var myMemberId: String {
        didSet {
            firebaseManager.localMemberId = myMemberId
            persistentRemoteTelemetry.removeValue(forKey: myMemberId)
            updateLocalPlayerMember()
            updateOtherSquadMembers()
            updateAllTacticalIndicators()
        }
    }
    // Single Sources of Truth: Deterministic State Machines
    @Published public private(set) var mapStateMachine = MapStateMachine()
    @Published public private(set) var sessionStateMachine = SessionStateMachine()

    // Synchronized Published State Accessors
    @Published public var selectedPresentation: TacticalPresentation = .radar {
        didSet {
            if mapStateMachine.presentation != selectedPresentation {
                mapStateMachine.handle(.togglePresentation)
            }
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
    @Published public var isInitiatingHost: Bool = false
    @Published public var isJoining: Bool = false
    @Published public var showPaywallSheet: Bool = false
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

    /// Whether MapKit's native `.follow` user-tracking mode is actually confirmed engaged on the
    /// iOS map presentation (TacticalMKMapView), as opposed to merely requested. Set optimistically
    /// false when a recenter is requested and only flipped true once MapKit's delegate confirms the
    /// transition — see Coordinator.recenterOnUser / mapView(_:didChange:) in TacticalMKMapView.
    /// Radar presentation and watchOS have no native map to confirm against, so this stays at its
    /// default and is ignored there (see `showsAsCenterLocked`).
    @Published public var isMapFollowConfirmed: Bool = true

    /// True when the map-centering HUD button should render as "locked". Combines the app-level
    /// tracking intent (`mapCenterLockState`) with, on the iOS map presentation only, confirmation
    /// that native `.follow` tracking is actually engaged — so the button can't lie and show
    /// "locked" while the camera has silently stopped following the user (e.g. a pinch-release
    /// recenter that never got confirmed).
    public var showsAsCenterLocked: Bool {
        mapCenterLockState.isLocked && (selectedPresentation != .map || isMapFollowConfirmed)
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
        Self.distance(from: localPlayerMember.coordinate, to: coordinate)
    }

    /// Equirectangular approximation, accurate enough at tactical (sub-kilometer) ranges.
    public static func distance(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let dLat = (b.latitude - a.latitude) * AppConstants.Location.metersPerDegreeLatitude
        let dLon = (b.longitude - a.longitude) * AppConstants.Location.metersPerDegreeLatitude * cos(b.latitude * AppConstants.Location.degreesToRadiansFactor)
        return hypot(dLat, dLon)
    }

    // MARK: - Tap-to-Measure Distance Line (local UI state only, never synced)

    public enum MeasuredAnnotationSelection: Equatable {
        case squadMember(id: String)
        case tacticalIndicator(id: String)
    }

    /// The annotation currently selected for the tap-to-measure distance line, if any. This is
    /// purely local UI state (not part of any synced/Codable payload) — never read or written by
    /// FirebaseSyncManager.
    @Published public var selectedAnnotationForDistance: MeasuredAnnotationSelection? = nil

    public func toggleAnnotationSelection(_ selection: MeasuredAnnotationSelection) {
        selectedAnnotationForDistance = (selectedAnnotationForDistance == selection) ? nil : selection
    }

    /// Resolves a selection to its live display coordinate, or nil if the underlying entity no
    /// longer exists (already removed/expired).
    public func coordinate(for selection: MeasuredAnnotationSelection) -> CLLocationCoordinate2D? {
        switch selection {
        case .squadMember(let id):
            guard let member = otherSquadMembers.first(where: { $0.id == id }) else { return nil }
            return remoteDisplayPositions[id] ?? member.coordinate
        case .tacticalIndicator(let id):
            return allTacticalIndicators.first(where: { $0.id == id })?.coordinate
        }
    }

    /// Clears `selectedAnnotationForDistance` if the entity it refers to has disappeared. Called
    /// after `otherSquadMembers`/`allTacticalIndicators` are recomputed.
    private func pruneSelectionIfStale() {
        guard let selection = selectedAnnotationForDistance else { return }
        if coordinate(for: selection) == nil {
            selectedAnnotationForDistance = nil
        }
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
    
    /// - Parameter republishLoginCycle: Whether this call should also write/publish
    ///   `loginCycle` from the resulting state machine state. True for every locally-initiated
    ///   action (pressing Join/Host — the peer needs to learn about *our own* new state). False
    ///   when called from `adoptCompanionSession`, where `loginCycle` was already set correctly
    ///   by the peer's own publish that triggered the adoption in the first place — re-deriving
    ///   and republishing it here would only be reflecting our own peer's state back at it, and
    ///   `isHosting`'s setter can't distinguish "not hosting because inactive" from "not hosting
    ///   because joined," so doing so overwrites a live `.joinActive`/`.hostActive` with a
    ///   spurious `.inactive` until the corrective branch below fires moments later.
    public func sendSessionAction(_ action: SessionAction, republishLoginCycle: Bool = true) {
        sessionStateMachine.handle(action)
        if republishLoginCycle {
            isHosting = sessionStateMachine.state.isHosting
        }
        isInitiatingHost = sessionStateMachine.state.isInitiatingHost
        isJoining = sessionStateMachine.state.isJoining
        // `isHosting`'s setter is the only writer of `loginCycle`, and it only ever
        // publishes .hostActive/.inactive — there's no `isJoined`-style computed property
        // for the symmetric .joined(room:) case. Publish .joinActive directly here so the
        // peer device's LWW merge actually learns "this device joined a room"; without
        // this, `loginCycle` never leaves .inactive on a successful join and the peer
        // never converges on the joined session.
        if republishLoginCycle, case .joined = sessionStateMachine.state {
            watchConnectivityManager.mutateLocalLoginCycle { $0.loginCycle = .joinActive }
        }
        if let err = sessionStateMachine.state.errorMessage {
            errorMessage = err
        }
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

        var mergedMap = localIndicators
        if let currentRoom = currentRoom {
            for (id, ind) in currentRoom.indicators {
                mergedMap[id] = ind
            }
        }

        let rawIndicators = Array(mergedMap.values)
        if rawIndicators.isEmpty {
            if !allTacticalIndicators.isEmpty { allTacticalIndicators = [] }
            syncTacticalToWatchConnectivity()
            pruneSelectionIfStale()
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
                } else {
                    for (key, member) in members {
                        if key.caseInsensitiveCompare(trimmedPlacedBy) == .orderedSame ||
                           member.id.caseInsensitiveCompare(trimmedPlacedBy) == .orderedSame {
                            resolvedMember = member
                            break
                        }
                    }
                    if resolvedMember == nil {
                        for member in members.values {
                            let clean = member.callsign.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !clean.isEmpty && clean.caseInsensitiveCompare(trimmedPlacedBy) == .orderedSame {
                                resolvedMember = member
                                break
                            }
                        }
                    }
                }
            }
            
            let trimmedLocalId = self.myMemberId.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedLocalCallsign = self.myCallsign.trimmingCharacters(in: .whitespacesAndNewlines)
            let isLocalPlayer = self.localIndicators[ind.id] != nil || (!trimmedPlacedBy.isEmpty && (
                trimmedPlacedBy.caseInsensitiveCompare(trimmedLocalId) == .orderedSame ||
                (!trimmedLocalCallsign.isEmpty && trimmedPlacedBy.caseInsensitiveCompare(trimmedLocalCallsign) == .orderedSame)
            ))
            
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
        
        // Squad orders are clan-private: visible only to the issuer ("Me") or teammates sharing >= 1 clan.
        // Enemy indicators and environmental hazards remain squad-wide (visible to all players).
        let visible = mapped.filter { ind in
            guard ind.category == .squadOrder else { return true }
            return isIndicatorFromSameClan(ind)
        }
        
        let sorted = visible.sorted { $0.timestamp < $1.timestamp }
        if allTacticalIndicators != sorted {
            allTacticalIndicators = sorted
            syncTacticalToWatchConnectivity()
        }
        pruneSelectionIfStale()
    }
    
    /// Sweep of expired non-order indicators plus `mti` cap enforcement, run by every member.
    /// Operates via deterministic oldest-first eviction so the cap holds across all squad peers
    /// without requiring a per-write Cloud Function trigger. Every member computes the same
    /// oldest-first overflow from the same merged `allTacticalIndicators` view, so their deletes
    /// target the same IDs; a delete on an already-deleted path is an idempotent no-op, so redundant
    /// deletes from multiple members are harmless rather than a race.
    public func enforceTacticalIndicatorMaintenance(room: SquadRoom? = nil) {
        let expiredIds = localIndicators.values.filter { $0.category != .squadOrder && $0.isExpired }.map { $0.id }
        for id in expiredIds {
            localIndicators.removeValue(forKey: id)
        }

        let currentRoom = room ?? firebaseManager.activeRoom
        let cap = currentRoom?.maxTacticalIndicators ?? (subscriptionManager.hasUnlimitedSquadUnlock ? AppConstants.Subscription.proTierMaxTacticalIndicators : AppConstants.Subscription.freeTierMaxTacticalIndicators)
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
            // Not re-advertised immediately — persistentRemoteTelemetry is read fresh by the
            // single 1Hz activeAdvertisementTimer tick (see advertiseActiveLease), which is the
            // sole trigger for *_hs sends.
            persistentRemoteTelemetry.removeAll()
            syncMembershipToWatchConnectivity()
            pruneSelectionIfStale()
            return
        }
        // A member must be confirmed via BOTH the roster/membership channel and the telemetry
        // channel before we display or classify them — see FirebaseSyncManager.isMemberConfirmed
        // and CLOUD_DATA_MANAGEMENT.md. Failing either check excludes the member entirely rather
        // than rendering a guessed team color that later flips once the missing side resolves.
        let filtered = currentRoom.members.values
            .filter { $0.id != myMemberId && firebaseManager.isMemberConfirmed($0.id) }
            .sorted { $0.id < $1.id }
        if otherSquadMembers != filtered {
            otherSquadMembers = filtered
        }
        let activeMemberIds = Set(currentRoom.members.keys)
        persistentRemoteTelemetry = persistentRemoteTelemetry.filter { activeMemberIds.contains($0.key) }
        syncMembershipToWatchConnectivity()
        pruneSelectionIfStale()
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
    
    /// Simulated HR derived from the 20-sample SMA of movement speed (`LocationHeadingManager.smoothedSpeedMps`).
    /// Stands in for `AppConstants.Health.defaultRestingHeartRate` wherever no watch optical
    /// reading is present — see `isWatchHeartRateSourcePresent`.
    public var simulatedHeartRateFromSpeed: Double {
        min(
            AppConstants.Health.maxSimulatedHeartRate,
            AppConstants.Health.defaultRestingHeartRate + locationHeadingManager.smoothedSpeedMps * AppConstants.Health.simulatedHeartRateSlopeBpmPerMps
        )
    }

    /// True when a watch optical reading is present:
    /// - On watchOS (or when localRole == .watch): the watch IS the optical heart rate source. Present when
    ///   `healthKitManager.currentHeartRate > 0 || healthKitManager.isSessionActive`.
    /// - On iOS/other: the watch's `w2p_hs` lease is active (`isWatchLeaseActive`), or an optical reading
    ///   has been directly supplied (e.g. mock test injection).
    public var isWatchHeartRateSourcePresent: Bool {
        if watchConnectivityManager.localRole == .watch {
            return healthKitManager.currentHeartRate > 0 || healthKitManager.isSessionActive
        } else {
            return watchConnectivityManager.isWatchLeaseActive || (healthKitManager.currentHeartRate > 0 && healthKitManager.currentHeartRate != AppConstants.Health.defaultRestingHeartRate)
        }
    }

    /// Canonical effective heart rate for the local player.
    /// - If KIA/downed: flatline 0.0 BPM.
    /// - If heart rate upload/sharing is disabled: speed-simulated resting HR.
    /// - Otherwise: live optical heart rate if available, falling back to speed-simulated HR.
    public var effectiveHeartRate: Double {
        if isDead {
            return AppConstants.Health.flatlineHeartRate
        } else if !isUploadHeartRateEnabled {
            return simulatedHeartRateFromSpeed
        } else if isWatchHeartRateSourcePresent {
            return healthKitManager.currentHeartRate
        } else {
            return simulatedHeartRateFromSpeed
        }
    }

    public func updateLocalPlayerMember() {
        let rawLoc = locationHeadingManager.userLocation?.coordinate ?? AppConstants.Location.fallbackCoordinate
        let rawHeading = locationHeadingManager.blendedHeading
        let hr = effectiveHeartRate
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
            role: firebaseManager.activeRoom?.members[myMemberId]?.role ?? myRole
        )
    }
    
    // Dependencies
    public let locationHeadingManager = LocationHeadingManager()
    public let healthKitManager = HealthKitManager()
    public let firebaseManager = FirebaseSyncManager()
    public let subscriptionManager = SubscriptionManager()
    public let watchConnectivityManager: WatchConnectivityManager
    
    // PRD Network Ownership and Activity Tokens
    /// Single uplink gate for every write to `firebaseManager` (telemetry, member metadata,
    /// isDead, etc.) — `(host_active OR join_active) AND` the per-platform device condition.
    /// Requiring `loginCycle` here too (not just the device condition) means a device that
    /// hasn't actually joined/hosted a session never writes, regardless of lease state.
    public var hasNetworkOwnership: Bool {
        guard watchConnectivityManager.localLS.loginCycle.loginCycle != .inactive else { return false }
        #if os(watchOS)
        // Watch is primary cloud client
        return true
        #else
        // `isWatchLeaseActive` is only refreshed by WatchConnectivityManager's 1Hz timer (or a
        // fresh HS payload arriving) — a plain read here can be up to a full tick stale, or
        // indefinitely stale if that timer isn't running (e.g. suspended in the background).
        // Correct a stale "still active" reading against the actual lease deadline before deciding ownership.
        watchConnectivityManager.correctStaleLeaseExpiry()
        // Phone connects only if Watch lease is expired/inactive
        return !watchConnectivityManager.isWatchLeaseActive
        #endif
    }
    @Published public var isPhoneActive: Bool = false
    @Published public var isWatchActive: Bool = false

    /// Is the user looking at this device right now (foreground/on-wrist)? Canonical, externally
    /// read flag — owned here, not by `FirebaseSyncManager`, since it gates WCSession-domain
    /// behavior (`updateActiveAdvertisementTimer`) as well as Firebase-domain behavior
    /// (`evaluateListenerGate`), and WCSession must stay decoupled from the Firebase manager's
    /// own lifecycle (see COMPANION_DATA_SYNC_MODEL.md's "Zero Web/Firebase Coupling" invariant).
    /// `FirebaseSyncManager` still keeps its own private copy for its adaptive-polling math; set
    /// via `setWristActive(_:)` below, never read externally.
    @Published public private(set) var isWristActive: Bool = true

    
    public var lastLowSpeedPayloadTimestamp: TimeInterval = 0
    public var lastLowSpeedPayloadSource: Character = "0"
    
    private var isApplyingRemoteSync: Bool = false
    /// Last `localLS` this device has already reacted to — used by the `$localLS` sink in
    /// `bindManagers()` to diff old vs. new and run field-change side effects exactly once,
    /// regardless of whether the change was a local edit or a remote merge.
    private var lastAppliedLS: LowSpeedSnapshot = LowSpeedSnapshot()
    /// `config.roomName` as of the last remote-merge room-lifecycle adoption pass — tracked
    /// separately from `lastAppliedLS` because `onLowSpeedConvergenceStateChanged` (remote-merge
    /// only) needs "the value before this specific merge", and by the time it fires, the general
    /// `$localLS` sink above has already advanced `lastAppliedLS` to the new value.
    private var lastAdoptedRoomName: String = ""
    private var cancellables = Set<AnyCancellable>()
    private var localSequenceCounter: Int64 = 0
    private var timer: AnyCancellable?
    private var freshnessExpiryTimer: AnyCancellable?
    private var activeAdvertisementTimer: AnyCancellable?
    internal private(set) var persistentRemoteTelemetry: [String: [Any]] = [:]
    
    public init(watchConnectivityManager: WatchConnectivityManager = WatchConnectivityManager.shared) {
        self.watchConnectivityManager = watchConnectivityManager

        // Every synced field (callsign, roomName, pin, databaseURL, theme, upload toggles,
        // isDead, isHosting) reads directly from `watchConnectivityManager.localLS`, which the
        // manager already loaded/migrated from persistence in its own init — nothing to seed here.
        self.isCustomDatabaseURLEnabled = UserDefaults.standard.object(forKey: AppConstants.Storage.isCustomDatabaseURLEnabledKey) as? Bool ?? true
        self.recentDatabaseURLs = UserDefaults.standard.stringArray(forKey: AppConstants.Storage.recentDatabaseURLsKey) ?? []

        self.myMemberId = GameStateManager.deriveMemberId(fromCallsign: watchConnectivityManager.localLS.config.callsign)

        firebaseManager.localMemberId = myMemberId

        #if !os(watchOS)
        // Default resting heart rate on iOS standalone
        self.healthKitManager.currentHeartRate = AppConstants.Health.defaultRestingHeartRate
        #endif

        self.lastAppliedLS = watchConnectivityManager.localLS
        self.lastAdoptedRoomName = watchConnectivityManager.localLS.config.roomName

        updateLocalPlayerMember()
        updateOtherSquadMembers()
        updateAllTacticalIndicators()

        setupWatchConnectivity()
        bindManagers()
        locationHeadingManager.requestPermissions()
        locationHeadingManager.startUpdates()

        // Request HealthKit workout session authorization at app launch
        healthKitManager.requestAuthorization()

        // Continuous companion lease advertisement across WCSession (strictly Phone <-> Watch)
        updateActiveAdvertisementTimer()
    }

    // MARK: - Outbound WCSession Structure Synchronization
    //
    // Config/playerState/loginCycle no longer need explicit sync functions — writes go straight
    // through the computed properties above (`myCallsign = ...`, `isDead = ...`, etc.), which call
    // `watchConnectivityManager.mutateLocal*` directly. Membership/tactical remain here since
    // they're serialized *views* of other owned state (Firebase room membership, local tactical
    // indicators), not simple leaf fields with a 1:1 property to assign through.

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
    
    /// Updates persistent remote telemetry map with incoming packets and prunes departed members.
    /// Does not itself trigger a WatchConnectivity send — the single 1Hz activeAdvertisementTimer
    /// tick (see advertiseActiveLease) reads persistentRemoteTelemetry fresh on every fire and is
    /// the sole place `*_hs` (one atomic Codable struct) is actually sent.
    public func updateRemoteTelemetry(packets: [TelemetryPacket] = []) {
        for packet in packets {
            if packet.memberId != myMemberId {
                persistentRemoteTelemetry[packet.memberId] = packet.toCompactArray()
            }
        }

        // Prune departed members who are no longer in the active squad room
        if let room = firebaseManager.activeRoom {
            let activeIds = Set(room.members.keys)
            persistentRemoteTelemetry = persistentRemoteTelemetry.filter { activeIds.contains($0.key) }
        }
    }

    /// Serializes and advertises the complete accumulated remote telemetry snapshot (Watch -> Phone).
    public func advertiseWatchHighSpeedState(heartRate: Double? = nil) {
        guard watchConnectivityManager.localRole == .watch else { return }
        let effectiveHr: Double
        if let hr = heartRate {
            effectiveHr = isDead ? AppConstants.Health.flatlineHeartRate : hr
        } else {
            effectiveHr = effectiveHeartRate
        }
        let json: String
        if !persistentRemoteTelemetry.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: persistentRemoteTelemetry),
           let str = String(data: data, encoding: .utf8) {
            json = str
        } else {
            json = "{}"
        }
        watchConnectivityManager.advertiseWatchHighSpeed(heartRate: effectiveHr, remotePlayerTelemetryJson: json)
    }

    // MARK: - Inbound WCSession Callbacks & Watch-Centric Cloud Policy

    private func setupWatchConnectivity() {
        // High-speed remote telemetry hook (Watch -> Phone)
        #if os(watchOS) || DEBUG
        firebaseManager.onRemoteTelemetryPacketsReceived = { [weak self] packets in
            guard let self = self else { return }
            guard self.watchConnectivityManager.localRole == .watch else { return }
            self.updateRemoteTelemetry(packets: packets)
        }
        #endif

        // 1. High-speed remote telemetry
        watchConnectivityManager.onHighSpeedTelemetryReceived = { [weak self] (telemetryJson: String) in
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
            self.evaluateListenerGate()
        }
        
        // 2. High-speed optical heart rate (Watch -> Phone)
        watchConnectivityManager.onHighSpeedHeartRateReceived = { [weak self] (hr: Double) in
            guard let self = self else { return }
            if self.isDead {
                self.healthKitManager.currentHeartRate = AppConstants.Health.flatlineHeartRate
            } else if hr > 0 {
                self.healthKitManager.currentHeartRate = hr
            }
        }
        
        // 3. Lease status changed (peer active_until lease monitored locally)
        watchConnectivityManager.onWatchLeaseStatusChanged = { [weak self] isWatchActive in
            guard let self = self else { return }
            if self.watchConnectivityManager.localRole == .phone {
                self.isWatchActive = isWatchActive
            } else {
                self.isPhoneActive = isWatchActive
            }
            self.evaluateListenerGate()
            self.objectWillChange.send()
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
            // Config/playerState field adoption itself needs nothing here — `mergedSnapshot` has
            // already been assigned into `watchConnectivityManager.localLS` (and the `$localLS`
            // sink in `bindManagers()` has already reacted to it) by the time this callback fires.
            // What's left is room-lifecycle side effects, which are remote-merge-specific (a local
            // host/join action drives Firebase directly via `hostRoom`/`joinRoom`, not through
            // here) and so can't live in that general sink.
            self.isApplyingRemoteSync = true

            let config = mergedSnapshot.config
            // Captured by the previous pass through this callback (not `self.savedRoomName`,
            // which by now already reflects `mergedSnapshot` itself) so this switch can tell
            // whether the room name actually changed since the last remote merge.
            let previousRoomName = self.lastAdoptedRoomName
            self.lastAdoptedRoomName = config.roomName

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

            // Tactical indicators adoption. Applies on both platforms: *_ls is a single merged
            // structure and nothing in it is platform-exclusive. MergeEngine.merge only lets this
            // structure "win" when its timestamp is newer than what's already adopted, so on a
            // device whose own Firebase listener is attached and current this is a no-op; it only
            // takes effect when this device's own listener is detached (e.g. Phone while Watch
            // holds the network lease, evaluateListenerGate()) and the peer's relayed copy is the
            // only source of current tactical state.
            if let tacData = mergedSnapshot.tactical.tacticalJson.data(using: .utf8),
               let indicators = try? JSONDecoder().decode([TacticalIndicator].self, from: tacData) {
                var newLocalMap: [String: TacticalIndicator] = [:]
                for ind in indicators {
                    newLocalMap[ind.id] = ind
                }
                self.localIndicators = newLocalMap
                self.updateAllTacticalIndicators()
            }

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
            self.evaluateListenerGate()
        }
    }
    
    /// Determines whether realtime downstream listeners should be attached, based on platform-specific rules:
    /// - Watch: appActive || peerLeaseActive
    ///   (app_active OR watch.Time < p2w_hs.active_until)
    /// - Phone: appActive && !peerLeaseActive
    ///   (app_active AND phone.time > w2p_hs.active_until)
    public static func shouldAttachListeners(isWatch: Bool, appActive: Bool, peerLeaseActive: Bool) -> Bool {
        if isWatch {
            return appActive || peerLeaseActive
        } else {
            return appActive && !peerLeaseActive
        }
    }

    /// Listener attach/detach gate: decides whether this device should have the three realtime
    /// Firebase listeners attached right now. Independent of the Uplink/ownership gate
    /// (`hasNetworkOwnership`) — a device can be gated off writes while still needing listeners
    /// attached (or vice versa).
    ///
    /// Gated on `(host_active OR join_active) AND` the per-platform device condition below —
    /// `loginCycle` (not `isTacticalSessionActive`) is the session-active signal, since it's the
    /// single synced source of truth for "did we actually choose to host/join," rather than a
    /// second, locally-derived flag that could drift from it.
    ///
    /// Differentiated per platform per architecture specification:
    /// - Watch: appActive || peerLeaseActive
    ///   i.e. app_active OR (watch.Time < p2w_hs.active_until)
    /// - Phone: appActive && !peerLeaseActive
    ///   i.e. app_active AND (phone.time > w2p_hs.active_until)
    public func evaluateListenerGate() {
        let loginActive = watchConnectivityManager.localLS.loginCycle.loginCycle != .inactive
        guard loginActive,
              let roomId = firebaseManager.activeRoom?.id ?? (!savedRoomName.isEmpty ? savedRoomName : nil) else {
            firebaseManager.stopTelemetryPolling()
            return
        }
        let appActive = isWristActive
        // Correct a stale "still active" reading against the actual lease deadline rather than
        // trusting the 1Hz timer's possibly-stale cache (see hasNetworkOwnership) —
        // evaluateListenerGate is called from one-off triggers (app resume, reachability change)
        // that need an up-to-date answer immediately, not whenever the timer next happens to tick.
        watchConnectivityManager.correctStaleLeaseExpiry()
        let peerLeaseActive = watchConnectivityManager.isWatchLeaseActive
        #if os(watchOS)
        let isWatch = true
        #else
        let isWatch = false
        #endif
        let shouldAttach = Self.shouldAttachListeners(isWatch: isWatch, appActive: appActive, peerLeaseActive: peerLeaseActive)
        shouldAttach ? firebaseManager.startTelemetryPolling(roomId: roomId) : firebaseManager.stopTelemetryPolling()
    }
    
    private func bindManagers() {



        firebaseManager.$activeRoom
            .sink { [weak self] room in
                guard let self = self else { return }
                #if os(watchOS)
                let isCompanionActive = self.isPhoneActive || (self.watchConnectivityManager.isWatchLeaseActive && self.watchConnectivityManager.isReachable)
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

        watchConnectivityManager.$p2wHS
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        watchConnectivityManager.$w2pHS
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        watchConnectivityManager.$isWatchLeaseActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                guard let self = self else { return }
                if self.watchConnectivityManager.localRole == .phone {
                    self.isWatchActive = active
                } else {
                    self.isPhoneActive = active
                }
                self.objectWillChange.send()
            }
            .store(in: &cancellables)
        
        Publishers.CombineLatest3(
            watchConnectivityManager.$localLS.map { $0.loginCycle.loginCycle == .hostActive },
            firebaseManager.$activeRoom,
            $myMemberId
        )
        .sink { [weak self] isHosting, room, memberId in
            guard let self = self else { return }
            let isHost: Bool
            if isHosting {
                isHost = true
            } else if let room = room {
                isHost = room.hostId == memberId
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
                self.enforceTacticalIndicatorMaintenance(room: newRoom)
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
                guard let self = self else { return }
                self.watchConnectivityManager.mutateLocalConfig { $0.isPro = isUnlocked }
            }
            .store(in: &cancellables)

        // myMemberId re-derivation specifically needs to happen synchronously/immediately (not
        // deferred to the next run loop turn like the general sink below) — it used to run inside
        // `myCallsign`'s own `didSet`, atomically with the callsign change, and other code (tests
        // included) can legitimately overwrite `myMemberId` directly afterward; a deferred
        // re-derivation firing later would stomp that override out from under it. This sink only
        // reads the value Combine hands it (`newCallsign`) and `self.myMemberId` (a plain,
        // non-`localLS`-derived property) — neither is subject to the `@Published`
        // willSet-vs-actual-value lag described below, so no `.receive(on:)` is needed here.
        watchConnectivityManager.$localLS
            .map { $0.config.callsign }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] newCallsign in
                guard let self = self else { return }
                let derivedId = GameStateManager.deriveMemberId(fromCallsign: newCallsign)
                if derivedId != self.myMemberId {
                    self.myMemberId = derivedId
                }
            }
            .store(in: &cancellables)

        // Single funnel for the rest of `localLS`'s field-change side effects — fires identically
        // whether the change was a local edit (a computed-property setter above) or a remote
        // convergence merge, since both ultimately just assign into
        // `watchConnectivityManager.localLS`. `@Published` publishes from `willSet`, before the
        // backing field is actually updated, so reading `watchConnectivityManager.localLS` (e.g.
        // via the `isDead`/`myCallsign`/etc. computed properties, which the side effects below
        // call into) from a synchronous sink would see the stale pre-change value —
        // `.receive(on:)` defers to the next run loop turn, by which point the write has landed.
        watchConnectivityManager.$localLS
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newLS in
                guard let self = self else { return }
                let old = self.lastAppliedLS
                self.lastAppliedLS = newLS

                if old.config.callsign != newLS.config.callsign {
                    self.updateLocalMember()
                    self.updateAllTacticalIndicators()
                    self.updateOtherSquadMembers()
                }
                if old.playerState.isDead != newLS.playerState.isDead
                    || old.loginCycle.loginCycle != newLS.loginCycle.loginCycle
                    || old.config.callsign != newLS.config.callsign
                    || old.config.role != newLS.config.role {
                    self.updateLocalPlayerMember()
                }
                if self.subscriptionManager.hasUnlimitedSquadUnlock != newLS.config.isPro {
                    self.subscriptionManager.hasUnlimitedSquadUnlock = newLS.config.isPro
                    UserDefaults.standard.set(newLS.config.isPro, forKey: AppConstants.Storage.hasUnlimitedSquadUnlockKey)
                    if !newLS.config.isPro && self.myRole.isProRequired {
                        self.myRole = .player
                    }
                }
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
        
        // Stream heart rate updates. `*_hs` (p2w_hs/w2p_hs) is one Codable struct sent as one
        // atomic unit at a single 1Hz rate — advertiseActiveLease()'s timer tick is the sole
        // trigger for that send (see updateActiveAdvertisementTimer), so this sink does not call
        // advertiseWatchHighSpeedState() itself; it only needs to keep healthKitManager.currentHeartRate
        // current, which the timer tick reads via effectiveHeartRate on its next 1Hz fire.
        healthKitManager.$currentHeartRate
            .sink { [weak self] hr in
                guard let self = self else { return }
                self.broadcastLocalTelemetry(heartRate: hr, force: false)
            }
            .store(in: &cancellables)
        
        // Coalesced local-member refresh. Throttled (rather than debounced-to-zero) to cap the
        // re-render rate at the same cadence as the radar UI's own display refresh — location and
        // heading can otherwise deliver updates far faster than SwiftUI can retire the resulting
        // re-render on watchOS, and a zero-duration debounce doesn't limit sustained bursts, only
        // coalesces updates landing in the same run-loop turn. `latest: true` ensures the most
        // recent sensor values still win rather than being dropped.
        Publishers.MergeMany(
            locationHeadingManager.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            healthKitManager.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            locationHeadingManager.$userLocation.map { _ in () }.eraseToAnyPublisher(),
            locationHeadingManager.$blendedHeading.map { _ in () }.eraseToAnyPublisher(),
            healthKitManager.$currentHeartRate.map { _ in () }.eraseToAnyPublisher()
        )
        .throttle(for: .seconds(AppConstants.Timing.DisplayRefresh.radarUIIntervalSeconds), scheduler: RunLoop.main, latest: true)
        .sink { [weak self] in
            self?.updateLocalPlayerMember()
            self?.objectWillChange.send()
        }
        .store(in: &cancellables)
    }
    
    // MARK: - Adaptive Rate Control
    
    public func currentHeartbeatRefreshInterval() -> TimeInterval {
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
        let interval = currentHeartbeatRefreshInterval()
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
        // Companion adoption (a low-speed convergence push from the phone) can call this from a
        // passive background WCSession wake. Starting a live HKWorkoutSession there has been
        // observed to hang forever in a synchronous HealthKit XPC call (enableCollection ->
        // healthd), blocking main until the OS watchdog SIGKILLs the app after its 600s
        // background-action budget. Only kick HealthKit off when the watch is actually
        // active/on-wrist (a real foreground start); otherwise handleAppResume() ->
        // resumeLiveHeartRateSession() starts it the next time the app is actually foregrounded,
        // since isTacticalSessionActive will already be true by then.
        if isWristActive {
            healthKitManager.requestAuthorization { [weak self] _ in
                self?.healthKitManager.startLiveHeartRateSession()
            }
        }

        restartHeartbeatTimer()
        startDeadReckoningTimer()
        startTTLRefreshTimer()
        evaluateListenerGate()
        updateActiveAdvertisementTimer()
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

    /// Guarantees this device's own `active_until` lease (`p2w_hs` on Phone, `w2p_hs` on Watch)
    /// refreshes at least once per `activeAdvertisementCadenceSeconds`, so a gap in incidental
    /// traffic (no HR sample, no telemetry to relay) can't let the 5s lease lapse. WCSession
    /// transport is strictly for Phone-to-Watch companion communication and is completely
    /// decoupled from Firebase/server room connection. Runs unconditionally at 1Hz once started —
    /// owned by `GameStateManager` itself, not `FirebaseSyncManager`, precisely so this timer's
    /// lifecycle never depends on the Firebase manager's own lifecycle.
    ///
    /// Deliberately NOT gated on `isWristActive`: Always-On display dims the screen
    /// (`isLuminanceReduced` -> `isWristActive == false`) without suspending the process, and this
    /// loop must keep ticking through that — the only qualifier for whether a tick actually reaches
    /// the peer is `isReachable`, checked downstream inside `advertiseWatchHighSpeed`/
    /// `advertisePhoneHighSpeed` (session activation + reachability), never up here. Gating the loop
    /// itself on wrist activity is exactly what stopped the Watch's lease from refreshing while
    /// dimmed, even though `isReachable` alone would have handled the send-vs-fallback decision
    /// correctly.
    ///
    /// Also NOT gated on `isReachable` directly: that property reflects live two-way messaging
    /// availability (foreground/high-priority-background), which is known to unreliably read
    /// `false` even while a companion is genuinely alive and running (e.g. a watch mid-workout
    /// with the screen off) — exactly this app's primary posture. `updateApplicationContext`
    /// (what this ultimately falls back to) is explicitly designed to keep working via the system
    /// WatchConnectivity daemon regardless of reachability, so gating on it would risk suppressing
    /// real lease refreshes to a backgrounded-but-active companion for a negligible power saving.
    ///
    /// This timer is also the sole trigger for the high-speed `*_hs` send (see `advertiseActiveLease`
    /// below) — `*_hs` is one Codable struct sent as one atomic unit at this single 1Hz rate,
    /// regardless of which underlying source (HR, telemetry, lease) actually changed.
    private func updateActiveAdvertisementTimer() {
        guard activeAdvertisementTimer == nil else { return }
        advertiseActiveLease()
        activeAdvertisementTimer = Timer.publish(every: AppConstants.WatchConnectivity.activeAdvertisementCadenceSeconds, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.advertiseActiveLease()
            }
    }

    /// Test-only observation hook: fires whenever `advertiseActiveLease()` runs, since the actual
    /// WCSession send it triggers has no externally observable effect in a host-only (e.g.
    /// `swift test` on macOS) environment where `WCSession.isSupported()` is false. Not called in
    /// production logic — only ever set by tests.
    var onActiveLeaseAdvertised: (() -> Void)?

    private func advertiseActiveLease() {
        // Same 1Hz tick also advances the sim_hr speed SMA (see LocationHeadingManager.sampleSpeedForSMA) —
        // sim_hr and the w2p_hs/p2w_hs lease refresh share one "Local refresh rate (1Hz)" clock by design.
        locationHeadingManager.sampleSpeedForSMA()
        #if os(watchOS)
        advertiseWatchHighSpeedState()
        #else
        watchConnectivityManager.advertisePhoneHighSpeed()
        #endif
        self.objectWillChange.send()
        onActiveLeaseAdvertised?()
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
        persistentRemoteTelemetry.removeAll()
        localIndicators.removeAll()
        allTacticalIndicators.removeAll()
        otherSquadMembers.removeAll()
        firebaseManager.resetLocalSessionAndIcons()
        isDead = AppConstants.Health.defaultIsDead
        updateLocalPlayerMember()
        syncMembershipToWatchConnectivity()
        syncTacticalToWatchConnectivity()
    }
    
    /// Canonical setter for `isWristActive` — always forwards to `firebaseManager.setWristActive`
    /// and re-runs both gates unconditionally (no `guard isWristActive != active else { return }`
    /// short-circuit). That guard was considered and deliberately rejected: `handleAppResume`/
    /// `handleAppSuspend` call this on every scenePhase transition (the common case in
    /// production), and `FirebaseSyncManager.setWristActive` has its own internal safety net that
    /// re-fetches telemetry when listeners are detached even if its cached flag didn't change —
    /// a short-circuit here would silently swallow calls that safety net depends on seeing.
    /// `evaluateListenerGate()`/`updateActiveAdvertisementTimer()` are already called redundantly
    /// from multiple other sites in this class, so calling them unconditionally here is safe.
    public func setWristActive(_ active: Bool) {
        isWristActive = active
        firebaseManager.setWristActive(active)
        if active {
            locationHeadingManager.exitLowPowerMode()
        } else {
            locationHeadingManager.enterLowPowerMode()
        }
        evaluateListenerGate()
        updateActiveAdvertisementTimer()
    }

    public func handleAppResume() {
        locationHeadingManager.exitLowPowerMode()
        locationHeadingManager.startUpdates()
        if isTacticalSessionActive {
            healthKitManager.resumeLiveHeartRateSession()
        }
        setWristActive(true)
    }


    public func handleAppSuspend() {
        locationHeadingManager.enterLowPowerMode()
        if isTacticalSessionActive {
            healthKitManager.pauseLiveHeartRateSession()
        } else {
            healthKitManager.stopLiveHeartRateSession()
        }
        setWristActive(false)
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
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in FirebaseSyncManager.crockfordAlphabet.randomElement(using: &generator)! })
    }

    /// Deterministically derives the local device's `myMemberId` from its callsign, so the
    /// phone and watch companion apps — which each run an independent `GameStateManager` with
    /// no shared `UserDefaults` (no App Group entitlement) — converge on the same member id for
    /// the same callsign without depending on a WatchConnectivity sync round-trip. Shares
    /// `FirebaseSyncManager.crockfordEncode`'s SHA256-into-Crockford-alphabet primitive with
    /// `deriveRoomPadding`, always emitting exactly `shortMemberIdLength` characters to satisfy
    /// the server-side `$memberId.length == 8` validation in database.rules.json regardless of
    /// callsign content.
    public static func deriveMemberId(fromCallsign callsign: String) -> String {
        let normalized = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let combined = "memberid:\(normalized)"
        return FirebaseSyncManager.crockfordEncode(digest: SHA256.hash(data: Data(combined.utf8)), length: shortMemberIdLength)
    }

    // MARK: - Clan Affiliation Helpers

    /// Checks whether the given callsign shares the same clan tag as the local player (`myCallsign`).
    public func isSameClan(callsign: String?) -> Bool {
        guard let callsign = callsign else { return false }
        return myCallsign.hasSameClan(as: callsign)
    }

    /// Checks whether the given member (by member ID) shares the same clan tag as the local player.
    public func isSameClan(memberId: String) -> Bool {
        if memberId == myMemberId { return true }
        if let member = otherSquadMembers.first(where: { $0.id == memberId }) {
            return isSameClan(callsign: member.callsign)
        }
        if let roomMember = firebaseManager.activeRoom?.members[memberId] {
            return isSameClan(callsign: roomMember.callsign)
        }
        return false
    }

    /// Checks whether a tactical indicator was placed by a member of the same clan (or local player).
    public func isIndicatorFromSameClan(_ indicator: TacticalIndicator) -> Bool {
        if indicator.placedByMemberId == myMemberId || localIndicators[indicator.id] != nil { return true }
        let trimmedLocal = myCallsign.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLocal.isEmpty,
           let callsign = indicator.placedByCallsign?.trimmingCharacters(in: .whitespacesAndNewlines),
           callsign.caseInsensitiveCompare(trimmedLocal) == .orderedSame {
            return true
        }
        if let callsign = indicator.placedByCallsign, !callsign.isEmpty {
            if isSameClan(callsign: callsign) { return true }
            if myCallsign.clanTags.isEmpty && callsign.clanTags.isEmpty { return true }
        }
        if isSameClan(memberId: indicator.placedByMemberId) { return true }
        if myCallsign.clanTags.isEmpty {
            let placerCallsign = firebaseManager.activeRoom?.members[indicator.placedByMemberId]?.callsign ?? ""
            if placerCallsign.clanTags.isEmpty {
                return true
            }
        }
        return false
    }

    /// Determines whether a squad member renders as a green icon (local player or same clan).
    public func isGreen(member: SquadMember) -> Bool {
        if member.id == myMemberId { return true }
        return isSameClan(callsign: member.callsign)
    }

    /// Determines whether a tactical indicator renders as a green icon (team order placed by local player or same clan).
    public func isGreen(indicator: TacticalIndicator) -> Bool {
        guard indicator.category == .squadOrder else { return false }
        return indicator.placedByMemberId == myMemberId || isIndicatorFromSameClan(indicator)
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
                result.append(String(String.UnicodeScalarView(token.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) })))
            }
        }

        return String(result.prefix(AppConstants.UI.maxPinLength))
    }

    /// ASCII alphanumerics plus space and `[ ]` — the latter preserved so `String.clanTag`
    /// (SquadMember.swift) can still extract a bracket-enclosed clan tag out of a sanitized
    /// callsign; a plain-alphanumerics filter like `sanitizeRoomNameInput`'s would silently break
    /// clan-tag matching for every user who types one.
    private static let callsignAllowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 []")

    /// Sanitizes free-typed text destined for the Callsign field: strips to
    /// `callsignAllowedCharacters`, uppercases (matching room name's convention and keeping
    /// `hasSameClan`'s case-insensitive comparison moot), truncated to `maxLength`.
    public static func sanitizeCallsignInput(_ input: String, maxLength: Int = AppConstants.UI.maxCallsignLength) -> String {
        let filtered = String(String.UnicodeScalarView(input.unicodeScalars.filter { callsignAllowedCharacters.contains($0) }))
        return String(filtered.uppercased().prefix(maxLength))
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

        let squadId = FirebaseSyncManager.deriveRoomId(name: cleanedName, pin: cleanedPin)
        let hostMember = makeCurrentSquadMember(role: myRole)
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
        // Deliberately no purgeLocalSessionAndIcons() here: a redundant Host press (e.g. the
        // companion device re-hosting the same room under the shared identity) must not wipe
        // already-synced session state before we even know the network call is redundant.
        // firebaseManager.createRoom's own completion assigns the real server room, and the
        // reactive $activeRoom sink in bindManagers() diffs otherSquadMembers/allTacticalIndicators
        // from that — a genuine room change still clears stale icons correctly, just from real
        // data instead of blasting to empty first.
        firebaseManager.setEncryptionContext(pin: cleanedPin, roomId: squadId, isEncryptionEnabled: isEncryptionEnabled)

        firebaseManager.createRoom(room) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.sendSessionAction(.hostSuccess(room: room))
                self.clearFieldErrors()
                self.updateLocalPlayerMember()
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

        let cleanId = isPreDerivedId ? truncatedName : FirebaseSyncManager.deriveRoomId(name: truncatedName, pin: cleanedPin)

        sendSessionAction(.startJoin(id: cleanId, pin: cleanedPin))
        errorMessage = nil
        // Deliberately no purgeLocalSessionAndIcons() here: a redundant Join press (e.g. the
        // companion device re-joining the same room under the shared identity) must not wipe
        // already-synced session state before we even know the network call is redundant.
        // firebaseManager.joinRoom's own completion assigns the real server room, and the
        // reactive $activeRoom sink in bindManagers() diffs otherSquadMembers/allTacticalIndicators
        // from that — a genuine room change still clears stale icons correctly, just from real
        // data instead of blasting to empty first.
        firebaseManager.setEncryptionContext(pin: cleanedPin, roomId: cleanId, isEncryptionEnabled: isEncryptionEnabled)

        let localMember = makeCurrentSquadMember(role: myRole)

        firebaseManager.joinRoom(id: cleanId, member: localMember, pin: cleanedPin) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let room):
                // A room that wasn't disbanded gracefully (app killed, crash, connectivity
                // loss) survives server-side with its original `hostId` intact. If the
                // device "joining" is that same host reconnecting to its own room, treat it
                // as a host reconnect rather than a join — otherwise `loginCycle` would
                // publish .joinActive, the peer would adopt this device as a non-host member,
                // and host-only affordances (disband, tactical authority) would be lost.
                if room.hostId == self.myMemberId {
                    self.sendSessionAction(.hostSuccess(room: room))
                } else {
                    self.sendSessionAction(.joinSuccess(room: room))
                }
                self.clearFieldErrors()
                self.updateLocalPlayerMember()
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
        let cleanName = roomName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanName.isEmpty else { return }

        if self.savedRoomName != cleanName {
            self.savedRoomName = cleanName
        }
        if let pin = pin, !pin.isEmpty {
            self.savedPin = pin
        }
        // `loginCycle` is already correct here — it's what the peer just published to trigger
        // this adoption in the first place. Don't write `self.isHosting` (it isn't local
        // bookkeeping despite the name; its setter mutates and republishes `loginCycle` over
        // WCSession) — doing so would overwrite a live `.joinActive`/`.hostActive` with a
        // spurious `.inactive`, since that setter has no way to represent "joined." See
        // sendSessionAction's `republishLoginCycle` parameter below.
        self.isInitiatingHost = false
        self.isJoining = false
        self.clearFieldErrors()
        self.errorMessage = nil

        guard !self.savedPin.isEmpty else { return }

        // Same FirebaseSyncManager.deriveRoomId call hostRoom/joinRoom use — the peer's
        // roomName/pin already carry everything needed (§ConfigSnapshot), so the full room id
        // is derived here rather than tracked as separate synced state.
        let cleanId = FirebaseSyncManager.deriveRoomId(name: cleanName, pin: self.savedPin)

        firebaseManager.setEncryptionContext(pin: self.savedPin, roomId: cleanId, isEncryptionEnabled: isEncryptionEnabled)

        self.isApplyingRemoteSync = true
        firebaseManager.connectToExistingRoom(roomId: cleanId) { [weak self] success in
            guard let self = self else { return }
            self.isApplyingRemoteSync = false
            if success {
                // Keep `sessionStateMachine` in step with the peer-driven adoption, not just
                // the `isHosting`/`isJoining` flags set above — otherwise a session adopted
                // from a WCSession merge (rather than this device's own hostRoom/joinRoom call)
                // leaves the state machine stuck on `.disconnected`, diverging from a
                // locally-initiated session for any consumer that reads `sessionStateMachine.state`.
                if let room = self.firebaseManager.activeRoom {
                    self.sendSessionAction(isHosting ? .hostSuccess(room: room) : .joinSuccess(room: room), republishLoginCycle: false)
                }
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
    
    public func setDead(_ dead: Bool) {
        isDead = dead
        let now = Date().timeIntervalSince1970
        if hasNetworkOwnership, var room = firebaseManager.activeRoom, var member = room.members[myMemberId] {
            member.status = dead ? .downed : .active
            member.heartRate = effectiveHeartRate
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
        let hr = effectiveHeartRate

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
        guard hasNetworkOwnership, let room = firebaseManager.activeRoom else { return }
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
        
        let heartbeatRefresh = currentHeartbeatRefreshInterval()
        if (currentTime - lastSentTimestamp) >= heartbeatRefresh {
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
        
        let effectiveHr: Double
        if isDead {
            effectiveHr = AppConstants.Health.flatlineHeartRate
        } else if !isUploadHeartRateEnabled {
            // HR upload opted out: broadcast the speed-simulated resting HR rather than the raw sensor value
            effectiveHr = simulatedHeartRateFromSpeed
        } else if let explicitHr = heartRate {
            effectiveHr = explicitHr
        } else {
            effectiveHr = self.effectiveHeartRate
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
            let existingSameType = currentIndicators.filter { $0.type == type && $0.placedByMemberId == myMemberId }
            for ind in existingSameType {
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

        localIndicators[newIndicator.id] = newIndicator

        if let roomId = roomId {
            firebaseManager.addOrUpdateIndicator(roomId: roomId, indicator: newIndicator)
        }
        updateAllTacticalIndicators()
        enforceTacticalIndicatorMaintenance()
    }
    
    public func removeTacticalIndicator(id: String) {
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

#if DEBUG
extension GameStateManager {
    /// 8-character text-based debug field.
    /// Driven purely by reading the status of existing variables (zero helper functions).
    /// - Character 1 (index 0): Upstream link to server attached
    ///   - 'U' when upstream link to server is attached (`hasNetworkOwnership && isConnected && activeRoom != nil`).
    ///   - '0' when upstream link is not attached or inactive.
    /// - Character 2 (index 1): Server listener attached
    ///   - 'D' when downstream server listener is attached (`firebaseManager.attachedTelemetryRoomId != nil`).
    ///   - '0' when server listener is not attached.
    /// - Character 3 (index 2): HS stream transmission activity
    ///   - 'P' when high-speed stream transmission is active from Phone.
    ///   - 'W' when high-speed stream transmission is active from Watch.
    ///   - '0' when no high-speed stream data.
    /// - Character 4 (index 3): LS stream transmission activity
    ///   - 'P' when low-speed stream transmission is active from Phone.
    ///   - 'W' when low-speed stream transmission is active from Watch.
    ///   - '0' when no low-speed stream data.
    /// - Character 5 (index 4): Sign of companion activeUntil - localdevice.time ('+' or '-')
    /// - Character 6 (index 5): Time delta magnitude in seconds, capped at 9 ('0'..'9')
    /// - Character 7 (index 6): WCSession activation state ('A' when .activated, '0' otherwise)
    /// - Character 8 (index 7): WCSession reachability ('R' when isReachable, '0' otherwise)
    public var debugStatusString: String {
        let now = Date().timeIntervalSince1970
        
        // Character 1: Upstream link to server attached (U or 0)
        let isUpstreamAttached = hasNetworkOwnership && firebaseManager.isConnected && (firebaseManager.activeRoom != nil)
        let upstreamChar: Character = isUpstreamAttached ? "U" : "0"
        
        // Character 2: Server listener attached (D or 0)
        let isListenerAttached = firebaseManager.attachedTelemetryRoomId != nil
        let listenerChar: Character = isListenerAttached ? "D" : "0"
        
        // Character 3: HS stream transmission activity (P from phone, W from watch, 0 no data)
        let isHSActive = watchConnectivityManager.isWatchLeaseActive || (watchConnectivityManager.companionActiveUntil > now)
        let hsChar: Character
        if watchConnectivityManager.localRole == .phone {
            hsChar = (isHSActive || isWatchActive) ? "W" : "0"
        } else {
            hsChar = (isHSActive || isPhoneActive) ? "P" : "0"
        }
        
        // Character 4: LS stream transmission activity (P from phone, W from watch, 0 no data)
        let isRecentLowSpeed = (now - lastLowSpeedPayloadTimestamp) < 3.0
        let lsChar: Character
        if watchConnectivityManager.localRole == .phone {
            lsChar = (isRecentLowSpeed && lastLowSpeedPayloadSource == "W") ? "W" : "0"
        } else {
            lsChar = (isRecentLowSpeed && lastLowSpeedPayloadSource == "P") ? "P" : "0"
        }
        
        // Characters 5 & 6: Companion activeUntil lease horizon (sign [+, -] and seconds capped at 9)
        let diff = watchConnectivityManager.companionActiveUntil - now
        let signChar: Character = diff >= 0 ? "+" : "-"
        let roundedDiff = abs(diff).rounded()
        let cappedSeconds: Int
        if roundedDiff.isNaN || roundedDiff >= 9.0 {
            cappedSeconds = 9
        } else {
            cappedSeconds = max(0, Int(roundedDiff))
        }
        let timeChar = Character("\(cappedSeconds)")
        
        // Character 7: WCSession activation state ('A' when .activated, '0' otherwise)
        let activatedChar: Character = watchConnectivityManager.debugLiveIsActivated ? "A" : "0"

        // Character 8: WCSession reachability ('R' when isReachable, '0' otherwise)
        let reachableChar: Character = watchConnectivityManager.debugLiveIsReachable ? "R" : "0"
        
        return "\(upstreamChar)\(listenerChar)\(hsChar)\(lsChar)\(signChar)\(timeChar)\(activatedChar)\(reachableChar)"
    }
}
#endif
