import Foundation
import Combine
import CoreLocation
import SwiftUI
import CryptoKit

public final class GameStateManager: ObservableObject {
    // MARK: - WCSession-synced fields
    //
    // Every field below is a pure read/write view onto `watchConnectivityManager.localOther` —
    // the single source of truth shared with the companion device for config/loginCycle/
    // playerState. There is no separate storage here: a local edit writes straight into
    // `localOther` (via the matching `mutateLocal*` call), and a remote convergence merge
    // updating `localOther` *is* these properties changing — there's no separate "adopt the
    // remote value" step. Side effects that used to live in each property's `didSet`
    // (persistence, `myMemberId` re-derivation, `updateLocalMember()`, etc.) now live in the
    // `$localOther` diff-sink in `bindManagers()`, since that's the one place both local edits
    // and remote merges actually land.
    public var myCallsign: String {
        get { watchConnectivityManager.localOther.config.callsign }
        set { watchConnectivityManager.mutateLocalConfig { $0.callsign = newValue } }
    }
    public var radarColorTheme: RadarColorTheme {
        get { RadarColorTheme(rawValue: watchConnectivityManager.localOther.config.theme) ?? .green }
        set { watchConnectivityManager.mutateLocalConfig { $0.theme = newValue.rawValue } }
    }
    public var savedRoomName: String {
        get { watchConnectivityManager.localOther.config.roomName }
        set { watchConnectivityManager.mutateLocalConfig { $0.roomName = newValue } }
    }
    public var savedPin: String {
        get { watchConnectivityManager.localOther.config.pin }
        set { watchConnectivityManager.mutateLocalConfig { $0.pin = newValue } }
    }
    /// Host-provided Firebase Realtime Database URL for squads that run against their own
    /// Firebase project instead of the shared default (see BRING_YOUR_OWN_FIREBASE.md). Empty means
    /// "use the shared default project."
    public var customDatabaseURL: String {
        get { watchConnectivityManager.localOther.config.databaseURL }
        set { watchConnectivityManager.mutateLocalConfig { $0.databaseURL = newValue } }
    }
    public var isUploadHeartRateEnabled: Bool {
        get { watchConnectivityManager.localOther.config.isUploadHeartRateEnabled }
        set { watchConnectivityManager.mutateLocalConfig { $0.isUploadHeartRateEnabled = newValue } }
    }
    public var isUploadLocationEnabled: Bool {
        get { watchConnectivityManager.localOther.config.isUploadLocationEnabled }
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
        get { watchConnectivityManager.localOther.config.isEncryptionEnabled }
        set {
            watchConnectivityManager.mutateLocalConfig { $0.isEncryptionEnabled = newValue }
            let roomId = watchConnectivityManager.roomGet().roomId
            if !roomId.isEmpty {
                firebaseManager.setEncryptionContext(pin: savedPin, roomId: roomId, isEncryptionEnabled: newValue)
            }
        }
    }
    public var myRole: MemberRole {
        get {
            let roleStr = watchConnectivityManager.localOther.config.role
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
            updateSelfInRoom { $0.role = effectiveRole }
        }
    }
    /// Coarse room-lifecycle state, mirrored from `localOther.loginCycle`. `sessionStateMachine`,
    /// `isInitiatingHost`, and `isJoining` (below) track richer local in-flight state that
    /// `LoginCycleState`'s 3 coarse cases (inactive/hostActive/joinActive) don't capture, and stay
    /// local-only.
    public var isHosting: Bool {
        get { watchConnectivityManager.localOther.loginCycle.loginCycle == .hostActive }
        set { watchConnectivityManager.mutateLocalLoginCycle { $0.loginCycle = newValue ? .hostActive : .inactive } }
    }
    public var isDead: Bool {
        get { watchConnectivityManager.localOther.playerState.isDead }
        set { watchConnectivityManager.mutateLocalPlayerState { $0.isDead = newValue } }
    }

    /// Optimistically updates this device's own row in the shared `Room` store — for instant
    /// local display feedback ahead of the Firebase round trip, same "multiple legitimate
    /// callers of one Set()" pattern used for local tactical marker placement (see the
    /// implementation plan §4). A no-op if self doesn't have a Room row yet (e.g. before the
    /// initial join/host roster write has landed).
    private func updateSelfInRoom(_ mutate: (inout SquadMember) -> Void) {
        var room = watchConnectivityManager.roomGet()
        guard let idx = room.members.firstIndex(where: { $0.id == myMemberId }) else { return }
        mutate(&room.members[idx])
        watchConnectivityManager.roomSet(room)
        firebaseManager.updateMember(room.members[idx])
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
        sessionStateMachine.state.isActiveSession || (firebaseManager.isConnected && !watchConnectivityManager.roomGet().roomId.isEmpty)
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
    //
    // `allTacticalIndicators` ("Marker annotations" in the architecture diagram) is a derived
    // display view computed purely from `watchConnectivityManager.tacticalGet()` — the single
    // shared `Tactical` store. There is no separate local-pending layer anymore (deleted
    // `localIndicators`): local marker placement writes straight into the same `Tactical`
    // instance the Firebase pipeline writes to (see `placeTacticalIndicator`/
    // `removeTacticalIndicator`), one store with multiple legitimate callers.
    @Published public private(set) var allTacticalIndicators: [TacticalIndicator] = []

    public func updateAllTacticalIndicators(room: RoomSnapshot? = nil) {
        let currentRoom = room ?? watchConnectivityManager.roomGet()
        let rawIndicators = watchConnectivityManager.tacticalGet().indicators

        if rawIndicators.isEmpty {
            if !allTacticalIndicators.isEmpty { allTacticalIndicators = [] }
            pruneSelectionIfStale()
            return
        }

        let mapped = rawIndicators.map { ind -> TacticalIndicator in
            var updated = ind
            let trimmedPlacedBy = ind.placedByMemberId.trimmingCharacters(in: .whitespacesAndNewlines)

            // 1. Direct or case-insensitive match in current room members by member ID
            var resolvedMember: SquadMember? = nil
            if let direct = currentRoom.members.first(where: { $0.id == trimmedPlacedBy || $0.id == ind.placedByMemberId }) {
                resolvedMember = direct
            } else {
                for member in currentRoom.members {
                    if member.id.caseInsensitiveCompare(trimmedPlacedBy) == .orderedSame {
                        resolvedMember = member
                        break
                    }
                }
                if resolvedMember == nil {
                    for member in currentRoom.members {
                        let clean = member.callsign.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !clean.isEmpty && clean.caseInsensitiveCompare(trimmedPlacedBy) == .orderedSame {
                            resolvedMember = member
                            break
                        }
                    }
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

        // Squad orders are clan-private: visible only to the issuer ("Me") or teammates sharing >= 1 clan.
        // Enemy indicators and environmental hazards remain squad-wide (visible to all players).
        let visible = mapped.filter { ind in
            guard ind.category == .squadOrder else { return true }
            return isIndicatorFromSameClan(ind)
        }

        let sorted = visible.sorted { $0.timestamp < $1.timestamp }
        if allTacticalIndicators != sorted {
            allTacticalIndicators = sorted
        }
        pruneSelectionIfStale()
    }

    private var isEnforcingTacticalIndicatorMaintenance = false

    /// Sweep of expired non-order indicators plus `mti` cap enforcement, run by every member.
    /// Operates via deterministic oldest-first eviction so the cap holds across all squad peers
    /// without requiring a per-write Cloud Function trigger. Every member computes the same
    /// oldest-first overflow from the same shared `Tactical` view, so their deletes target the
    /// same IDs; a delete on an already-deleted path is an idempotent no-op, so redundant deletes
    /// from multiple members are harmless rather than a race.
    ///
    /// Re-entrancy guarded: `removeTacticalIndicator` writes `Tactical` via `Set()`, which
    /// `bindManagers()`'s `$localRoom`/`onTacticalConvergenceStateChanged` reactions call this
    /// function again for, synchronously, before the original call returns. Without this guard,
    /// evicting N over-cap indicators recurses N stack frames deep (one nested re-entry per
    /// eviction) instead of iterating — under heavy marker volume this recursion can run deep
    /// enough to overflow the stack (observed as an EXC_BAD_ACCESS at an unrelated line once the
    /// stack pointer passed its guard page).
    public func enforceTacticalIndicatorMaintenance(room: RoomSnapshot? = nil) {
        guard !isEnforcingTacticalIndicatorMaintenance else { return }
        isEnforcingTacticalIndicatorMaintenance = true
        defer { isEnforcingTacticalIndicatorMaintenance = false }

        let expiredIds = watchConnectivityManager.tacticalGet().indicators.filter { $0.category != .squadOrder && $0.isExpired }.map { $0.id }
        for id in expiredIds {
            removeTacticalIndicator(id: id)
        }

        let currentRoom = room ?? watchConnectivityManager.roomGet()
        let cap = currentRoom.maxTacticalIndicators > 0 ? currentRoom.maxTacticalIndicators : (subscriptionManager.hasUnlimitedSquadUnlock ? AppConstants.Subscription.proTierMaxTacticalIndicators : AppConstants.Subscription.freeTierMaxTacticalIndicators)
        let cappedIndicators = allTacticalIndicators.filter { $0.category != .squadOrder }.sorted { $0.timestamp < $1.timestamp }
        guard cappedIndicators.count > cap else { return }
        for indicator in cappedIndicators.prefix(cappedIndicators.count - cap) {
            removeTacticalIndicator(id: indicator.id)
        }
    }
    
    // Squad Members
    @Published public var otherSquadMembers: [SquadMember] = []

    /// Constructs the display list for other squad members ("Player annotations" minus self in
    /// the architecture diagram) by combining two independent memory elements: `Room` (identity —
    /// callsign/role) and `persistentRemoteTelemetry` (live position — "w2p Telemetry", populated
    /// either directly from this device's own Firebase listener or relayed via WCSession
    /// high-speed when the companion device holds network ownership; see
    /// `FirebaseSyncManager.validateAndProcessPacket(s)` and `onHighSpeedTelemetryReceived`).
    /// Room no longer carries live position data at all — see `local player management`'s
    /// analogous split for self (`updateLocalPlayerMember`). "is valid member and has telemetry?"
    /// from the architecture diagram is exactly the `compactMap`'s two guards below: a member
    /// must be confirmed via BOTH the roster/membership channel (`Room`, iterated here) and the
    /// telemetry channel (`persistentRemoteTelemetry`) before it's displayed at all — failing
    /// either excludes the member entirely rather than rendering a guessed team color that later
    /// flips once the missing side resolves.
    public func updateOtherSquadMembers(room: RoomSnapshot? = nil) {
        let currentRoom = room ?? watchConnectivityManager.roomGet()

        let activeMemberIds = Set(currentRoom.members.map { $0.id })
        persistentRemoteTelemetry = persistentRemoteTelemetry.filter { activeMemberIds.contains($0.key) }

        // Previous display state per id — needed to compute course-over-ground heading and to
        // seed dead-reckoning's previous-sample fields, same as
        // `FirebaseSyncManager.updateMember(with:in:)` used to do when position lived inside
        // `activeRoom.members`. Now that position lives entirely in `persistentRemoteTelemetry`,
        // this state is rebuilt here from the last computed `otherSquadMembers` instead.
        var previousById: [String: SquadMember] = [:]
        for m in otherSquadMembers { previousById[m.id] = m }

        let filtered: [SquadMember] = currentRoom.members.compactMap { roomMember -> SquadMember? in
            guard roomMember.id != myMemberId else { return nil }
            guard let compact = persistentRemoteTelemetry[roomMember.id],
                  let packet = TelemetryPacket.fromCompactArray(memberId: roomMember.id, roomId: currentRoom.roomId, array: compact) else { return nil }
            var display = roomMember
            display.latitude = packet.latitude
            display.longitude = packet.longitude
            display.altitude = packet.altitude ?? 0
            display.heartRate = packet.heartRate
            display.lastUpdatedTimestamp = packet.timestamp
            display.sequenceNumber = packet.sequenceNumber
            display.status = packet.heartRate == AppConstants.Health.flatlineHeartRate ? .downed : .active

            if let previous = previousById[roomMember.id] {
                let prevLoc = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                let newLoc = CLLocation(latitude: packet.latitude, longitude: packet.longitude)
                let distanceMoved = prevLoc.distance(from: newLoc)
                let isInitialPlaceholder = abs(previous.latitude) < 1e-5 && abs(previous.longitude) < 1e-5
                if packet.heading > 0.0 {
                    display.heading = packet.heading
                } else if !isInitialPlaceholder && distanceMoved > AppConstants.Location.minDisplacementForCourseOverGroundMeters {
                    display.heading = FirebaseSyncManager.calculateBearing(
                        from: CLLocationCoordinate2D(latitude: previous.latitude, longitude: previous.longitude),
                        to: CLLocationCoordinate2D(latitude: packet.latitude, longitude: packet.longitude)
                    )
                } else {
                    // Zero displacement and no explicit packet heading: retain previous heading.
                    display.heading = previous.heading
                }
                if previous.lastUpdatedTimestamp > 0 {
                    display.lastAnimationDuration = 0.0
                    let wasPlaceholder = abs(previous.latitude) < 1e-5 && abs(previous.longitude) < 1e-5
                    if !wasPlaceholder {
                        display.previousLatitude = previous.latitude
                        display.previousLongitude = previous.longitude
                        display.previousUpdatedTimestamp = previous.lastUpdatedTimestamp
                    }
                }
            } else {
                display.heading = packet.heading
            }
            return display
        }.sorted { $0.id < $1.id }

        if otherSquadMembers != filtered {
            otherSquadMembers = filtered
        }
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
    
    /// Cached host status — updated via Combine only when isHosting, Room, or myMemberId
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

    /// "local player management" from the architecture diagram: combines position/telemetry read
    /// directly from local GPS (no Firebase round-trip — self is always locally authoritative,
    /// no roster/telemetry confirmation wait the way `updateOtherSquadMembers` requires for
    /// others) with membership info (role) read live from `Room.Get()` rather than a frozen local
    /// value — this is what would let a future commander-reassigned-role feature reach display
    /// (see the implementation plan's "Room-self-liveness enables future role reassignment").
    public func updateLocalPlayerMember() {
        let rawLoc = locationHeadingManager.userLocation?.coordinate ?? AppConstants.Location.fallbackCoordinate
        let rawHeading = locationHeadingManager.blendedHeading
        let hr = effectiveHeartRate
        let roomRole = watchConnectivityManager.roomGet().members.first(where: { $0.id == myMemberId })?.role
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
            role: roomRole ?? myRole
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
        guard watchConnectivityManager.localOther.loginCycle.loginCycle != .inactive else { return false }
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
    /// Last `localOther` this device has already reacted to — used by the `$localOther` sink in
    /// `bindManagers()` to diff old vs. new and run field-change side effects exactly once,
    /// regardless of whether the change was a local edit or a remote merge.
    private var lastAppliedOther: OtherSnapshot = OtherSnapshot()
    /// `config.roomName` as of the last remote-merge room-lifecycle adoption pass — tracked
    /// separately from `lastAppliedOther` because `onOtherConvergenceStateChanged` (remote-merge
    /// only) needs "the value before this specific merge", and by the time it fires, the general
    /// `$localOther` sink above has already advanced `lastAppliedOther` to the new value.
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
        // isDead, isHosting) reads directly from `watchConnectivityManager.localOther`, which the
        // manager already loaded/migrated from persistence in its own init — nothing to seed here.
        self.isCustomDatabaseURLEnabled = UserDefaults.standard.object(forKey: AppConstants.Storage.isCustomDatabaseURLEnabledKey) as? Bool ?? true
        self.recentDatabaseURLs = UserDefaults.standard.stringArray(forKey: AppConstants.Storage.recentDatabaseURLsKey) ?? []

        self.myMemberId = GameStateManager.deriveMemberId(fromCallsign: watchConnectivityManager.localOther.config.callsign)

        firebaseManager.localMemberId = myMemberId
        firebaseManager.watchConnectivityManager = watchConnectivityManager

        #if !os(watchOS)
        // Default resting heart rate on iOS standalone
        self.healthKitManager.currentHeartRate = AppConstants.Health.defaultRestingHeartRate
        #endif

        self.lastAppliedOther = watchConnectivityManager.localOther
        self.lastAdoptedRoomName = watchConnectivityManager.localOther.config.roomName

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
    // Config/playerState/loginCycle/membership/tactical no longer need explicit sync functions —
    // writes go straight through the computed properties above (`myCallsign = ...`,
    // `isDead = ...`, etc., which call `watchConnectivityManager.mutateLocal*` directly) or
    // directly through `roomSet`/`tacticalSet` at the specific call sites that own that content
    // (`FirebaseSyncManager`'s Observer pipelines, `updateSelfInRoom`,
    // `placeTacticalIndicator`/`removeTacticalIndicator`). There is nothing left to bridge —
    // deleted `syncMembershipToWatchConnectivity`/`syncTacticalToWatchConnectivity` entirely.

    /// Updates persistent remote telemetry map ("w2p Telemetry" in the architecture diagram) with
    /// incoming packets and prunes departed members. Does not itself trigger a WatchConnectivity
    /// send — the single 1Hz activeAdvertisementTimer tick (see advertiseActiveLease) reads
    /// persistentRemoteTelemetry fresh on every fire and is the sole place `*_hs` (one atomic
    /// Codable struct) is actually sent.
    public func updateRemoteTelemetry(packets: [TelemetryPacket] = []) {
        for packet in packets {
            if packet.memberId != myMemberId {
                persistentRemoteTelemetry[packet.memberId] = packet.toCompactArray()
            }
        }

        // Prune departed members who are no longer in the active squad room
        let activeIds = Set(watchConnectivityManager.roomGet().members.map { $0.id })
        persistentRemoteTelemetry = persistentRemoteTelemetry.filter { activeIds.contains($0.key) }
        updateOtherSquadMembers()
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
        // Firebase-direct remote telemetry hook — fires on whichever platform currently holds
        // Firebase listener ownership (see evaluateListenerGate); "w2p Telemetry" in the
        // architecture diagram is populated from this path OR from `onHighSpeedTelemetryReceived`
        // below (WCSession relay), whichever source is actually live right now. Not
        // watch-exclusive: either platform can hold listener ownership.
        firebaseManager.onRemoteTelemetryPacketsReceived = { [weak self] packets in
            guard let self = self else { return }
            self.updateRemoteTelemetry(packets: packets)
        }

        // 1. High-speed remote telemetry
        watchConnectivityManager.onHighSpeedTelemetryReceived = { [weak self] (telemetryJson: String) in
            guard let self = self else { return }
            guard let data = telemetryJson.data(using: .utf8),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            
            var packets: [TelemetryPacket] = []
            let currentRoomId = self.watchConnectivityManager.roomGet().roomId
            let roomId = !currentRoomId.isEmpty ? currentRoomId : self.savedRoomName
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
        
        // 4. Room converged snapshot received. `room` is already the post-convergence, reconciled
        // value (Get() semantics) by the time this fires — nothing to copy anywhere, just refresh
        // the derived display state that reads Room.
        watchConnectivityManager.onRoomConvergenceStateChanged = { [weak self] room in
            guard let self = self else { return }
            self.lastLowSpeedPayloadTimestamp = Date().timeIntervalSince1970
            #if os(watchOS)
            self.lastLowSpeedPayloadSource = "P"
            #else
            self.lastLowSpeedPayloadSource = "W"
            #endif
            self.updateOtherSquadMembers(room: room)
            self.updateAllTacticalIndicators(room: room)
            self.updateLocalPlayerMember()
        }

        // 4b. Tactical converged snapshot received. Applies on both platforms: `Tactical` is a
        // single shared structure and nothing in it is platform-exclusive. `MergeEngine.mergeTactical`
        // only lets a structure "win" when its timestamp is newer than what's already adopted, so
        // on a device whose own Firebase listener is attached and current this is a no-op; it only
        // takes effect when this device's own listener is detached (e.g. Phone while Watch holds
        // the network lease, evaluateListenerGate()) and the peer's relayed copy is the only
        // source of current tactical state.
        watchConnectivityManager.onTacticalConvergenceStateChanged = { [weak self] _ in
            guard let self = self else { return }
            self.lastLowSpeedPayloadTimestamp = Date().timeIntervalSince1970
            #if os(watchOS)
            self.lastLowSpeedPayloadSource = "P"
            #else
            self.lastLowSpeedPayloadSource = "W"
            #endif
            self.updateAllTacticalIndicators()
        }

        // 4c. Other (config/loginCycle/playerState) converged snapshot received. Field adoption
        // itself needs nothing here — `other` has already been assigned into
        // `watchConnectivityManager.localOther` (and the `$localOther` sink in `bindManagers()`
        // has already reacted to it) by the time this callback fires. What's left is
        // room-lifecycle side effects, which are remote-merge-specific (a local host/join action
        // drives Firebase directly via `hostRoom`/`joinRoom`, not through here) and so can't live
        // in that general sink.
        watchConnectivityManager.onOtherConvergenceStateChanged = { [weak self] other in
            guard let self = self else { return }
            self.lastLowSpeedPayloadTimestamp = Date().timeIntervalSince1970
            #if os(watchOS)
            self.lastLowSpeedPayloadSource = "P"
            #else
            self.lastLowSpeedPayloadSource = "W"
            #endif
            self.isApplyingRemoteSync = true

            let config = other.config
            // Captured by the previous pass through this callback (not `self.savedRoomName`,
            // which by now already reflects `other` itself) so this switch can tell whether the
            // room name actually changed since the last remote merge.
            let previousRoomName = self.lastAdoptedRoomName
            self.lastAdoptedRoomName = config.roomName

            let cycle = other.loginCycle
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
                if self.isTacticalSessionActive || !self.watchConnectivityManager.roomGet().roomId.isEmpty || self.isHosting {
                    self.isHosting = false
                    self.isInitiatingHost = false
                    self.isJoining = false
                    self.stopTacticalSession()
                    self.purgeLocalSessionAndIcons()
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
        let loginActive = watchConnectivityManager.localOther.loginCycle.loginCycle != .inactive
        let currentRoomId = watchConnectivityManager.roomGet().roomId
        let effectiveRoomId = !currentRoomId.isEmpty ? currentRoomId : (!savedRoomName.isEmpty ? savedRoomName : nil)
        guard loginActive, let roomId = effectiveRoomId else {
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



        watchConnectivityManager.$localRoom
            .sink { [weak self] room in
                guard let self = self else { return }
                #if os(watchOS)
                let isCompanionActive = self.isPhoneActive || (self.watchConnectivityManager.isWatchLeaseActive && self.watchConnectivityManager.isReachable)
                #else
                let isCompanionActive = false
                #endif
                if !room.roomId.isEmpty && !self.isApplyingRemoteSync && !isCompanionActive {
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
            watchConnectivityManager.$localOther.map { $0.loginCycle.loginCycle == .hostActive },
            watchConnectivityManager.$localRoom,
            $myMemberId
        )
        .sink { [weak self] isHosting, room, memberId in
            guard let self = self else { return }
            let isHost: Bool
            if isHosting {
                isHost = true
            } else if !room.roomId.isEmpty {
                isHost = room.hostId == memberId
            } else {
                isHost = false
            }
            if self.isCurrentMemberHost != isHost {
                self.isCurrentMemberHost = isHost
            }
        }
        .store(in: &cancellables)

        watchConnectivityManager.$localRoom
            .sink { [weak self] newRoom in
                guard let self = self else { return }
                self.updateOtherSquadMembers(room: newRoom)
                self.updateAllTacticalIndicators(room: newRoom)
                self.updateLocalPlayerMember()
                self.enforceTacticalIndicatorMaintenance(room: newRoom)
            }
            .store(in: &cancellables)

        // Mirrors the `$localRoom` sink above for Tactical: refreshes the derived
        // `allTacticalIndicators` view on ANY change to the shared `Tactical` store, whether from
        // local marker placement, the Firebase pipeline, or a remote WCSession merge — so no
        // future `tacticalSet(...)` call site needs to remember to refresh it itself.
        watchConnectivityManager.$localTactical
            .sink { [weak self] _ in
                self?.updateAllTacticalIndicators()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(watchConnectivityManager.$localRoom, firebaseManager.networkQualityMonitor.$connectionGrade)
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
        // non-`localOther`-derived property) — neither is subject to the `@Published`
        // willSet-vs-actual-value lag described below, so no `.receive(on:)` is needed here.
        watchConnectivityManager.$localOther
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

        // Single funnel for the rest of `localOther`'s field-change side effects — fires
        // identically whether the change was a local edit (a computed-property setter above) or a
        // remote convergence merge, since both ultimately just assign into
        // `watchConnectivityManager.localOther`. `@Published` publishes from `willSet`, before the
        // backing field is actually updated, so reading `watchConnectivityManager.localOther`
        // (e.g. via the `isDead`/`myCallsign`/etc. computed properties, which the side effects
        // below call into) from a synchronous sink would see the stale pre-change value —
        // `.receive(on:)` defers to the next run loop turn, by which point the write has landed.
        watchConnectivityManager.$localOther
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newOther in
                guard let self = self else { return }
                let old = self.lastAppliedOther
                self.lastAppliedOther = newOther

                if old.config.callsign != newOther.config.callsign {
                    self.updateLocalMember()
                    self.updateAllTacticalIndicators()
                    self.updateOtherSquadMembers()
                }
                if old.playerState.isDead != newOther.playerState.isDead
                    || old.loginCycle.loginCycle != newOther.loginCycle.loginCycle
                    || old.config.callsign != newOther.config.callsign
                    || old.config.role != newOther.config.role {
                    self.updateLocalPlayerMember()
                }
                if self.subscriptionManager.hasUnlimitedSquadUnlock != newOther.config.isPro {
                    self.subscriptionManager.hasUnlimitedSquadUnlock = newOther.config.isPro
                    UserDefaults.standard.set(newOther.config.isPro, forKey: AppConstants.Storage.hasUnlimitedSquadUnlockKey)
                    if !newOther.config.isPro && self.myRole.isProRequired {
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
        let memberCount = watchConnectivityManager.roomGet().members.count
        return AppConstants.Timing.ConstantBandwidth.refreshInterval(forPlayerCount: memberCount)
    }

    public func recalculateAdaptiveUploadInterval() {
        let memberCount = watchConnectivityManager.roomGet().members.count
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
                guard let self = self, self.isCurrentMemberHost else { return }
                let roomId = self.watchConnectivityManager.roomGet().roomId
                guard !roomId.isEmpty else { return }
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
    
    /// "loginCycle went inactive? purge telemetry, room, and tactical" from the architecture
    /// diagram: `Set()` is the only door into `Room`/`Tactical`, so this calls it directly with
    /// a cleared value on each. `persistentRemoteTelemetry` ("w2p Telemetry") has no such
    /// indirection — it's a plain local dictionary — so it's cleared directly via `removeAll()`.
    public func purgeLocalSessionAndIcons() {
        persistentRemoteTelemetry.removeAll()
        allTacticalIndicators.removeAll()
        otherSquadMembers.removeAll()
        watchConnectivityManager.roomSet(RoomSnapshot())
        watchConnectivityManager.tacticalSet(TacticalSnapshot())
        firebaseManager.resetLocalSessionAndIcons()
        isDead = AppConstants.Health.defaultIsDead
        updateLocalPlayerMember()
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

    /// Converts the synced `Room` (an ordered array, for deterministic WCSession `Equatable`
    /// comparison) into a `SquadRoom` (a dictionary, the server/session-machine shape) — needed
    /// only where an API predating this refactor (`SessionStateMachine`) still expects the
    /// dictionary-keyed type. Not a second copy of Room's content: called on demand from
    /// `watchConnectivityManager.roomGet()`, never cached.
    public static func squadRoom(from room: RoomSnapshot) -> SquadRoom {
        SquadRoom(
            id: room.roomId,
            hostId: room.hostId,
            maxCapacity: room.maxCapacity,
            maxTacticalIndicators: room.maxTacticalIndicators,
            pinHash: room.pinHash,
            members: Dictionary(uniqueKeysWithValues: room.members.map { ($0.id, $0) })
        )
    }

    // MARK: - Clan Affiliation Helpers

    /// Checks whether the given callsign shares the same clan tag as the local player (`myCallsign`).
    public func isSameClan(callsign: String?) -> Bool {
        guard let callsign = callsign else {
            return false
        }
        return myCallsign.hasSameClan(as: callsign)
    }

    /// Checks whether the given member (by member ID) shares the same clan tag as the local player.
    public func isSameClan(memberId: String) -> Bool {
        if memberId == myMemberId { return true }
        if let member = otherSquadMembers.first(where: { $0.id == memberId }) {
            return isSameClan(callsign: member.callsign)
        }
        if let roomMember = watchConnectivityManager.roomGet().members.first(where: { $0.id == memberId }) {
            return isSameClan(callsign: roomMember.callsign)
        }
        return false
    }

    /// Checks whether a tactical indicator was placed by a member of the same clan (or local player).
    public func isIndicatorFromSameClan(_ indicator: TacticalIndicator) -> Bool {
        if indicator.placedByMemberId == myMemberId { return true }
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
            let placerCallsign = watchConnectivityManager.roomGet().members.first(where: { $0.id == indicator.placedByMemberId })?.callsign ?? ""
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
        // firebaseManager.createRoom's own completion publishes the real server room into Room via
        // Set(), and the reactive $localRoom sink in bindManagers() diffs otherSquadMembers/allTacticalIndicators
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
        // firebaseManager.joinRoom's own completion publishes the real server room into Room via
        // Set(), and the reactive $localRoom sink in bindManagers() diffs otherSquadMembers/allTacticalIndicators
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
                let roomSnapshot = self.watchConnectivityManager.roomGet()
                if !roomSnapshot.roomId.isEmpty {
                    let room = GameStateManager.squadRoom(from: roomSnapshot)
                    self.sendSessionAction(isHosting ? .hostSuccess(room: room) : .joinSuccess(room: room), republishLoginCycle: false)
                }
                self.startTacticalSession()
            }
        }
    }
    
    public func disbandRoom(completion: ((Bool) -> Void)? = nil) {
        let currentRoomId = watchConnectivityManager.roomGet().roomId
        let roomId: String? = !currentRoomId.isEmpty ? currentRoomId : nil
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
        let currentRoomId = watchConnectivityManager.roomGet().roomId
        let roomId: String? = !currentRoomId.isEmpty ? currentRoomId : nil
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
        // `dead`/heartRate/lastUpdatedTimestamp are display state, not roster identity — they
        // reach other players via telemetry (heart rate flatline -> `.downed` status, derived in
        // `updateOtherSquadMembers`), not via Room, so there's nothing to write into Room here.
        updateLocalPlayerMember()
        updateOtherSquadMembers()
        objectWillChange.send()
        broadcastLocalTelemetry(force: true)
    }

    // MARK: - Telemetry Dispatch

    private func makeCurrentSquadMember(role: MemberRole) -> SquadMember {
        let loc = locationHeadingManager.userLocation?.coordinate ?? AppConstants.Location.fallbackCoordinate
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

    /// Reflects a local callsign change into `Room` (self's own row), matching
    /// `updateSelfInRoom`'s "multiple legitimate callers of one Set()" pattern above. `oldId`
    /// (when a callsign change derives a new `myMemberId`) removes the stale row under the old id
    /// and clears its local freshness bookkeeping — the server-side row under the old id is left
    /// to expire via TTL, same as before this refactor.
    private func updateLocalMember(oldId: String? = nil) {
        guard hasNetworkOwnership else { return }
        var room = watchConnectivityManager.roomGet()
        let lookupId = oldId ?? myMemberId
        guard let member = room.members.first(where: { $0.id == lookupId }) ?? room.members.first(where: { $0.id == myMemberId }) else { return }

        if let oldId = oldId, oldId != myMemberId {
            firebaseManager.removeMember(id: oldId)
            room.members.removeAll { $0.id == oldId }
        }

        let updated = SquadMember(
            id: myMemberId,
            callsign: myCallsign,
            latitude: 0,
            longitude: 0,
            heading: locationHeadingManager.blendedHeading,
            lastUpdatedTimestamp: Date().timeIntervalSince1970,
            role: member.role
        )

        if let idx = room.members.firstIndex(where: { $0.id == myMemberId }) {
            room.members[idx] = updated
        } else {
            room.members.append(updated)
        }
        watchConnectivityManager.roomSet(room)
        firebaseManager.updateMember(updated)
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
        let roomId = watchConnectivityManager.roomGet().roomId
        guard !roomId.isEmpty else { return }
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
            roomId: roomId,
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
        
        let currentRoomId = watchConnectivityManager.roomGet().roomId
        let roomId: String? = !currentRoomId.isEmpty ? currentRoomId : nil
        let currentIndicators = allTacticalIndicators

        if type.category == .squadOrder {
            let existingSameType = currentIndicators.filter { $0.type == type && $0.placedByMemberId == myMemberId }
            for ind in existingSameType {
                removeTacticalIndicator(id: ind.id)
            }
        }

        let cleanCallsign = myCallsign.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedCallsign = cleanCallsign.isEmpty ? (watchConnectivityManager.roomGet().members.first(where: { $0.id == myMemberId })?.callsign ?? "") : cleanCallsign

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
            let prospective = (watchConnectivityManager.tacticalGet().indicators.filter { $0.category != .squadOrder } + [newIndicator]).sorted { $0.timestamp < $1.timestamp }
            if prospective.count > cap {
                for old in prospective.prefix(prospective.count - cap) {
                    removeTacticalIndicator(id: old.id)
                }
            }
        }

        // Local marker placement: one store, multiple legitimate callers — writes straight into
        // the same `Tactical` instance the Firebase pipeline writes to (see the implementation
        // plan §4), not a third parallel copy.
        var tactical = watchConnectivityManager.tacticalGet()
        tactical.indicators.append(newIndicator)
        watchConnectivityManager.tacticalSet(tactical)

        if let roomId = roomId {
            firebaseManager.addOrUpdateIndicator(roomId: roomId, indicator: newIndicator)
        }
        updateAllTacticalIndicators()
        enforceTacticalIndicatorMaintenance()
    }

    public func removeTacticalIndicator(id: String) {
        var tactical = watchConnectivityManager.tacticalGet()
        tactical.indicators.removeAll { $0.id == id }
        watchConnectivityManager.tacticalSet(tactical)

        let currentRoomId = watchConnectivityManager.roomGet().roomId
        if !currentRoomId.isEmpty {
            firebaseManager.removeIndicator(roomId: currentRoomId, indicatorId: id)
        }
        updateAllTacticalIndicators()
    }
}

#if DEBUG
extension GameStateManager {
    /// 8-character text-based debug field.
    /// Driven purely by reading the status of existing variables (zero helper functions).
    /// - Character 1 (index 0): Upstream link to server attached
    ///   - 'U' when upstream link to server is attached (`hasNetworkOwnership && isConnected && !Room.roomId.isEmpty`).
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
        let isUpstreamAttached = hasNetworkOwnership && firebaseManager.isConnected && !watchConnectivityManager.roomGet().roomId.isEmpty
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
