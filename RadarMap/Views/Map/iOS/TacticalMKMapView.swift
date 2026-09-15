#if os(iOS)
import SwiftUI
import MapKit
import CoreLocation

/// Custom MKAnnotation representation for teammate annotations.
final class SquadMemberAnnotation: NSObject, MKAnnotation {
    let memberId: String
    dynamic var coordinate: CLLocationCoordinate2D
    var member: SquadMember
    
    init(member: SquadMember) {
        self.memberId = member.id
        self.coordinate = member.coordinate
        self.member = member
        super.init()
    }
}

/// Marker for the midpoint label of the tap-to-measure distance line (single instance, local UI state only).
final class DistanceLabelMKAnnotation: NSObject, MKAnnotation {
    dynamic var coordinate: CLLocationCoordinate2D
    var text: String

    init(coordinate: CLLocationCoordinate2D, text: String) {
        self.coordinate = coordinate
        self.text = text
        super.init()
    }
}

/// Small label badge, styled consistently with the callsign/order-callsign badges, shown at the
/// midpoint of the tap-to-measure distance line.
private struct DistanceLabelView: View {
    let text: String
    let radarColor: Color

    var body: some View {
        Text(text)
            .font(.system(size: AppConstants.UI.MapMarkers.callsignFontSize, weight: .bold, design: .monospaced))
            .foregroundColor(radarColor)
            .lineLimit(1)
            .padding(.horizontal, 3.0)
            .padding(.vertical, 1.0)
            .background(Color.black.opacity(0.85))
            .cornerRadius(3)
            .fixedSize()
    }
}

/// Custom MKAnnotation representation for tactical indicator annotations.
final class TacticalIndicatorMKAnnotation: NSObject, MKAnnotation {
    let indicatorId: String
    dynamic var coordinate: CLLocationCoordinate2D
    var indicator: TacticalIndicator

    init(indicator: TacticalIndicator) {
        self.indicatorId = indicator.id
        self.coordinate = indicator.coordinate
        self.indicator = indicator
        super.init()
    }
}

/// Coordinator state tracking gesture transitions and preventing feedback loops.
@MainActor
final class TacticalPhoneCameraState: ObservableObject {
    // True for the duration of an active pinch gesture. MapKit drops userTrackingMode to
    // .none the instant a pinch begins — even a zoom-only pinch that never moves the map
    // center — which would otherwise be misread by the pan-detection delegates below as
    // "user panned away" and trigger our own re-lock/recenter machinery mid-zoom, fighting
    // the native zoom and snapping it back. This flag exists purely to tell those delegates
    // to ignore that transient drop, matching how a native Maps-style pinch just zooms in
    // place without disturbing tracking state.
    var isPinching = false
}

/// iPhone/iPad Native MKMapView adapter hosted in UIViewRepresentable.
public struct TacticalMKMapView: UIViewRepresentable {
    @ObservedObject var gameState: GameStateManager
    let onMapTapped: ((CLLocationCoordinate2D) -> Void)?
    // Whether this map view is the one currently on screen (vs. kept mounted but hidden behind
    // the radar presentation). Kept mounted rather than added/removed by SwiftUI's `if` because
    // repeatedly creating/destroying an MKMapView is a documented VectorKit crash source
    // (CFRelease in TileGroupNotificationManager::~TileGroupNotificationManager, reproduces from
    // toggling alone with no login/annotations/pan required). While not visible, `updateUIView`
    // skips annotation sync and recentering, and the display link pauses, to keep the background
    // cost down — MapKit's own tile/camera engine still runs, since there's no public API to
    // fully suspend it, but our own per-frame/per-update work stops.
    let isVisible: Bool

    public init(
        gameState: GameStateManager,
        isVisible: Bool = true,
        onMapTapped: ((CLLocationCoordinate2D) -> Void)? = nil
    ) {
        self.gameState = gameState
        self.isVisible = isVisible
        self.onMapTapped = onMapTapped
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    public func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        // Standard map view maintains continuous zoom feel during gestures, but enforces
        // the canonical decade ladder on gesture release via a persistent CameraZoomRange
        // clamp. Clamping minCenterCoordinateDistance == maxCenterCoordinateDistance continuously
        // forces MapKit's camera to stay at our discrete tactical altitude without fighting
        // tracking mode transitions or drifting speed-dependent altitude in .follow mode.
        // The clamp is temporarily relaxed to [minScale, maxScale] only while an active pinch is in flight.
        //
        // A fresh MKMapView otherwise starts at MapKit's own default world region, and only
        // eases into place once userTrackingMode animates the camera over — an animation that
        // rapid presentation toggling (switch-view button mashed) tears down and restarts
        // before it ever completes, leaving the map visibly stuck zoomed out at that default
        // region. Seeding the initial region explicitly from the radar's own current center
        // and scale means the map is already framed correctly the instant it appears, with no
        // dependence on that animation finishing.
        let initialCenter = gameState.mapStateMachine.effectiveCenter(userCoord: gameState.localPlayerMember.coordinate)
        let initialSpanDelta = AppConstants.UI.RadarScale.mapSpanDelta(forRadarScaleMeters: gameState.selectedScaleMeters)
        let initialRegion = MKCoordinateRegion(
            center: initialCenter,
            span: MKCoordinateSpan(latitudeDelta: initialSpanDelta, longitudeDelta: initialSpanDelta)
        )
        mapView.setRegion(initialRegion, animated: false)

        let initialDistance = AppConstants.UI.RadarScale.cameraDistance(forScale: gameState.selectedScaleMeters)
        mapView.setCameraZoomRange(.init(minCenterCoordinateDistance: initialDistance, maxCenterCoordinateDistance: initialDistance), animated: false)

        if gameState.mapStateMachine.trackingState.isLocked {
            mapView.userTrackingMode = .follow
        }
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        mapView.isZoomEnabled = true
        mapView.showsCompass = false
        mapView.showsScale = false
        
        // Dark-first tactical map configuration with muted emphasis
        if #available(iOS 16.0, *) {
            let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
            config.pointOfInterestFilter = .excludingAll
            mapView.preferredConfiguration = config
        }
        mapView.overrideUserInterfaceStyle = .dark

        mapView.insetsLayoutMarginsFromSafeArea = false
        mapView.layoutMargins = .zero

        // Attach tap recognizer for indicator placement
        let tapRecognizer = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTapGesture(_:))
        )
        tapRecognizer.delegate = context.coordinator
        mapView.addGestureRecognizer(tapRecognizer)

        // Purely observational — flags pinch-active state so the pan-detection delegates
        // can ignore MapKit's transient tracking-mode drop during a zoom-only pinch. Never
        // mutates the camera or scale itself; native pinch-to-zoom handles that entirely.
        let pinchRecognizer = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinchGesture(_:))
        )
        pinchRecognizer.delegate = context.coordinator
        mapView.addGestureRecognizer(pinchRecognizer)
        
        context.coordinator.setupDisplayLink(for: mapView)
        
        return mapView
    }
    
    public func updateUIView(_ uiView: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.setVisible(isVisible, mapView: uiView)

        // While hidden behind the radar presentation, skip recentering and annotation sync —
        // there's nothing to show, and it's our main lever for keeping the always-mounted map's
        // background cost down (see `isVisible`'s doc comment). `lastObservedCenterTrigger`/
        // `lastObservedLockState` intentionally go stale while hidden, so becoming visible again
        // re-detects any change that happened while hidden and recenters once, same as if the
        // button had just been pressed.
        guard isVisible else { return }

        // 1. Center-map button: event-driven re-tracking, not polled on a schedule.
        var needsRecenter = false
        if gameState.radarCenterTrigger != context.coordinator.lastObservedCenterTrigger {
            context.coordinator.lastObservedCenterTrigger = gameState.radarCenterTrigger
            needsRecenter = true
        }

        // 1b. Panned back near the user: the state machine auto-relocks (see MapStateMachine
        // .pan), but MapKit's own tracking mode was left at .none by the earlier manual pan —
        // re-engage native follow so the camera actually recenters.
        let isLocked = gameState.mapStateMachine.trackingState.isLocked
        if isLocked != context.coordinator.lastObservedLockState {
            context.coordinator.lastObservedLockState = isLocked
            if isLocked && uiView.userTrackingMode == .none {
                needsRecenter = true
            }
        }

        // Pressing the center button always changes both the trigger count and (if panned
        // away) the lock state in the same update pass — recenter once, not twice.
        if needsRecenter {
            context.coordinator.recenterOnUser(in: uiView)
        }

        // 2. Synchronize teammate annotations idempotently
        context.coordinator.syncAnnotations(in: uiView)
    }
    
    public static func dismantleUIView(_ uiView: MKMapView, coordinator: Coordinator) {
        coordinator.tearDown()
    }
    
    // MARK: - Coordinator
    final class TacticalMKAnnotationView: MKAnnotationView {
        override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
            super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
            collisionMode = .none
            displayPriority = .required
        }
        
        required init?(coder aDecoder: NSCoder) {
            super.init(coder: aDecoder)
            collisionMode = .none
            displayPriority = .required
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            collisionMode = .none
            displayPriority = .required
        }

        var isGreenPriority: Bool = false {
            didSet {
                zPriority = isGreenPriority ? .max : .defaultUnselected
                layer.zPosition = isGreenPriority ? 100.0 : 10.0
                displayPriority = .required
                collisionMode = .none
            }
        }
        
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            if super.point(inside: point, with: event) {
                return true
            }
            if isGreenPriority {
                let padding = AppConstants.UI.MapMarkers.greenTouchTargetPadding
                let expanded = bounds.insetBy(dx: -padding, dy: -padding)
                return expanded.contains(point)
            }
            return false
        }
    }
    
    public final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: TacticalMKMapView
        let cameraState = TacticalPhoneCameraState()
        private var displayLink: CADisplayLink?
        private weak var activeMapView: MKMapView?
        var lastObservedCenterTrigger: Int
        var lastObservedLockState: Bool
        private var lastAppliedVisibility = true

        // Guards against re-issuing setUserTrackingMode(.follow) while a previous recenter
        // animation is still in flight. Without this, rapid button taps restart the camera
        // animation mid-flight, and MapKit's transient .none tracking-mode drop during that
        // restart gets misread by the pan-detection delegates as a manual pan to whatever
        // interpolated (mid-animation) coordinate the camera happened to be sweeping through,
        // relocking the map onto an essentially random location.
        private var isRecentering = false
        private var wasLockedBeforePinch = false

        // Set once dismantleUIView/tearDown runs (e.g. switching away from the .map presentation).
        // MapKit fires a final didChange(mode: .none)/regionDidChange as tracking naturally stops
        // during teardown — without this guard, the existing pan-detection logic misreads that as
        // "user panned away" and unlocks tracking, so switching to radar and back silently drops
        // follow-me mode.
        private var isTornDown = false

        // Hosting controllers for member marker content, keyed by the MKAnnotationView they're
        // attached to. Reused across syncAnnotations passes instead of being torn down and
        // recreated every call — recreating a UIHostingController on every single sync (which
        // can run dozens of times a second, e.g. while following a moving teammate) lets SwiftUI's own
        // insertion/removal transition for the new view visibly lag behind the container's
        // instant reposition, so the icon appears detached from its true (correctly-tracked)
        // annotation view. Updating an existing controller's rootView instead is an in-place
        // SwiftUI update with no transition, so the content always stays glued to its container.
        private var memberHosts: [ObjectIdentifier: UIHostingController<MemberAnnotationView>] = [:]
        private var tacticalHosts: [ObjectIdentifier: UIHostingController<TacticalIndicatorOverlayView>] = [:]

        // Tap-to-Measure Distance Line: at most one polyline + midpoint label exist at a time.
        private var distanceLabelHosts: [ObjectIdentifier: UIHostingController<DistanceLabelView>] = [:]
        private var distancePolyline: MKPolyline?
        private var distanceLabelAnnotation: DistanceLabelMKAnnotation?

        init(_ parent: TacticalMKMapView) {
            self.parent = parent
            self.lastObservedCenterTrigger = parent.gameState.radarCenterTrigger
            self.lastObservedLockState = parent.gameState.mapStateMachine.trackingState.isLocked
            super.init()
        }

        /// Creates or updates (never recreates) the hosted MemberAnnotationView content for
        /// `view`, sized and anchored via `view.bounds`/`centerOffset` — never `view.frame`,
        /// since MKMapView continuously repositions the annotation view's frame itself.
        private func applyMemberContent(member: SquadMember, isMe: Bool, to view: MKAnnotationView, size: CGFloat) {
            view.centerOffset = .zero
            view.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            view.clipsToBounds = false
            view.collisionMode = .none
            view.displayPriority = .required
            let radarColor = parent.gameState.radarColorTheme.color
            let isSameClan = !isMe && parent.gameState.isSameClan(callsign: member.callsign)
            let isGreen = isMe || isSameClan
            if let tacView = view as? TacticalMKAnnotationView {
                tacView.isGreenPriority = isGreen
            } else {
                view.zPriority = isGreen ? .max : .defaultUnselected
                view.layer.zPosition = isGreen ? 100.0 : 10.0
                view.displayPriority = .required
                view.collisionMode = .none
            }
            let isSelected = !isMe && (parent.gameState.selectedAnnotationForDistance == .squadMember(id: member.id))
            let onTap: () -> Void = { [weak self] in
                guard let self, self.parent.gameState.pendingIndicatorPlacementType == nil else { return }
                if isMe {
                    self.parent.gameState.selectedAnnotationForDistance = nil
                } else {
                    self.parent.gameState.toggleAnnotationSelection(.squadMember(id: member.id))
                }
            }
            let key = ObjectIdentifier(view)
            if let host = memberHosts[key] {
                host.rootView = MemberAnnotationView(member: member, isMe: isMe, isSameClan: isSameClan, isSelected: isSelected, radarColor: radarColor, onTap: onTap)
                host.view.clipsToBounds = false
                host.view.frame = view.bounds
                host.view.layoutIfNeeded()
            } else {
                view.subviews.forEach { $0.removeFromSuperview() }
                let host = UIHostingController(rootView: MemberAnnotationView(member: member, isMe: isMe, isSameClan: isSameClan, isSelected: isSelected, radarColor: radarColor, onTap: onTap))
                host.view.backgroundColor = .clear
                host.view.clipsToBounds = false
                host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                host.view.frame = view.bounds
                host.view.layoutIfNeeded()
                view.addSubview(host.view)
                memberHosts[key] = host
            }
        }

        /// Drops the cached hosting controller for a removed annotation view, if any.
        private func releaseMemberContent(for view: MKAnnotationView) {
            memberHosts.removeValue(forKey: ObjectIdentifier(view))
        }
        
        /// Creates or updates the hosted TacticalIndicatorOverlayView content for `view`.
        private func applyTacticalContent(indicator: TacticalIndicator, to view: MKAnnotationView) {
            let touchTargetSize = AppConstants.UI.MapMarkers.tacticalIndicatorRingSize
            view.centerOffset = .zero
            view.bounds = CGRect(x: 0, y: 0, width: touchTargetSize, height: touchTargetSize)
            view.clipsToBounds = false
            view.collisionMode = .none
            view.displayPriority = .required
            
            let key = ObjectIdentifier(view)
            let radarColor = parent.gameState.radarColorTheme.color
            let isPlacedByMe = (indicator.placedByMemberId == parent.gameState.myMemberId)
            let isSameClan = parent.gameState.isIndicatorFromSameClan(indicator)
            let isGreen = (indicator.category == .squadOrder) && (isPlacedByMe || isSameClan)
            if let tacView = view as? TacticalMKAnnotationView {
                tacView.isGreenPriority = isGreen
            } else {
                view.zPriority = isGreen ? .max : .defaultUnselected
                view.layer.zPosition = isGreen ? 100.0 : 10.0
                view.displayPriority = .required
                view.collisionMode = .none
            }
            let onDelete: () -> Void = { [weak self] in
                self?.parent.gameState.removeTacticalIndicator(id: indicator.id)
            }
            let onTap: () -> Void = { [weak self] in
                guard let self, self.parent.gameState.pendingIndicatorPlacementType == nil else { return }
                self.parent.gameState.toggleAnnotationSelection(.tacticalIndicator(id: indicator.id))
            }

            if let host = tacticalHosts[key] {
                host.rootView = TacticalIndicatorOverlayView(
                    indicator: indicator,
                    isPlacedByMe: isPlacedByMe,
                    isSameClan: isSameClan,
                    radarColor: radarColor,
                    onDelete: onDelete,
                    onTap: onTap
                )
                host.view.clipsToBounds = false
                host.view.frame = view.bounds
                host.view.layoutIfNeeded()
            } else {
                view.subviews.forEach { $0.removeFromSuperview() }
                let host = UIHostingController(rootView: TacticalIndicatorOverlayView(
                    indicator: indicator,
                    isPlacedByMe: isPlacedByMe,
                    isSameClan: isSameClan,
                    radarColor: radarColor,
                    onDelete: onDelete,
                    onTap: onTap
                ))
                host.view.backgroundColor = .clear
                host.view.clipsToBounds = false
                host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                host.view.frame = view.bounds
                host.view.layoutIfNeeded()
                view.addSubview(host.view)
                tacticalHosts[key] = host
            }
        }
        
        /// Drops the cached hosting controller for a removed tactical indicator view.
        private func releaseTacticalContent(for view: MKAnnotationView) {
            tacticalHosts.removeValue(forKey: ObjectIdentifier(view))
        }

        /// Creates or updates the hosted DistanceLabelView content for `view`, auto-sizing the
        /// hosting view's bounds to the label's intrinsic size.
        private func applyDistanceLabelContent(text: String, to view: MKAnnotationView) {
            view.collisionMode = .none
            view.displayPriority = .required
            let radarColor = parent.gameState.radarColorTheme.color
            let key = ObjectIdentifier(view)
            let rootView = DistanceLabelView(text: text, radarColor: radarColor)
            let host: UIHostingController<DistanceLabelView>
            if let existing = distanceLabelHosts[key] {
                existing.rootView = rootView
                host = existing
            } else {
                view.subviews.forEach { $0.removeFromSuperview() }
                host = UIHostingController(rootView: rootView)
                host.view.backgroundColor = .clear
                view.addSubview(host.view)
                distanceLabelHosts[key] = host
            }
            let size = host.sizeThatFits(in: CGSize(width: 200, height: 40))
            view.bounds = CGRect(origin: .zero, size: size)
            host.view.frame = view.bounds
            view.centerOffset = .zero
        }

        /// Drops the cached hosting controller for a removed distance-label view.
        private func releaseDistanceLabelContent(for view: MKAnnotationView) {
            distanceLabelHosts.removeValue(forKey: ObjectIdentifier(view))
        }

        /// Adds/updates the single tap-to-measure polyline + midpoint label, or removes both when
        /// no annotation is selected. Purely local UI state — never synced.
        private func updateDistanceLine(in mapView: MKMapView) {
            guard let selection = parent.gameState.selectedAnnotationForDistance,
                  let selectedCoordinate = parent.gameState.coordinate(for: selection) else {
                clearDistanceLine(in: mapView)
                return
            }

            let meCoordinate = parent.gameState.localPlayerMember.coordinate
            let midpoint = CLLocationCoordinate2D(
                latitude: (meCoordinate.latitude + selectedCoordinate.latitude) / 2,
                longitude: (meCoordinate.longitude + selectedCoordinate.longitude) / 2
            )
            let labelText = AppConstants.UI.ScaleRuler.formatDistance(
                meters: GameStateManager.distance(from: meCoordinate, to: selectedCoordinate)
            )

            if let existingPolyline = distancePolyline {
                mapView.removeOverlay(existingPolyline)
            }
            let polyline = MKPolyline(coordinates: [meCoordinate, selectedCoordinate], count: 2)
            distancePolyline = polyline
            mapView.addOverlay(polyline)

            if let existingLabel = distanceLabelAnnotation {
                existingLabel.coordinate = midpoint
                existingLabel.text = labelText
                if let view = mapView.view(for: existingLabel) {
                    applyDistanceLabelContent(text: labelText, to: view)
                }
            } else {
                let label = DistanceLabelMKAnnotation(coordinate: midpoint, text: labelText)
                distanceLabelAnnotation = label
                mapView.addAnnotation(label)
            }
            refreshMemberSelectionState(in: mapView)
        }

        private func clearDistanceLine(in mapView: MKMapView) {
            if let existingPolyline = distancePolyline {
                mapView.removeOverlay(existingPolyline)
                distancePolyline = nil
            }
            if let existingLabel = distanceLabelAnnotation {
                if let view = mapView.view(for: existingLabel) {
                    releaseDistanceLabelContent(for: view)
                }
                mapView.removeAnnotation(existingLabel)
                distanceLabelAnnotation = nil
            }
            refreshMemberSelectionState(in: mapView)
        }

        private func refreshMemberSelectionState(in mapView: MKMapView) {
            let existingMembers = mapView.annotations.compactMap { $0 as? SquadMemberAnnotation }
            for anno in existingMembers {
                if let view = mapView.view(for: anno) {
                    let teammateFrameSize = AppConstants.UI.MapMarkers.markerFrameSize * AppConstants.UI.MapMarkers.otherPlayerScaleFactor
                    applyMemberContent(member: anno.member, isMe: false, to: view, size: teammateFrameSize)
                }
            }
        }


        func setupDisplayLink(for mapView: MKMapView) {
            self.activeMapView = mapView
            let link = CADisplayLink(target: self, selector: #selector(readLiveRulerGeometry))
            link.add(to: .main, forMode: .common)
            self.displayLink = link
        }

        /// Called every `updateUIView` with the map's current on-screen visibility. Pauses the
        /// per-frame ruler display link and disables user interaction while hidden behind the
        /// radar presentation — the cheap part of keeping this view's own background cost down
        /// now that it stays mounted instead of being destroyed/recreated on every toggle.
        func setVisible(_ visible: Bool, mapView: MKMapView) {
            guard visible != lastAppliedVisibility else { return }
            lastAppliedVisibility = visible
            displayLink?.isPaused = !visible
            mapView.isUserInteractionEnabled = visible
        }


        func tearDown() {
            isTornDown = true
            displayLink?.invalidate()
            displayLink = nil
            // Cancel any in-flight animated tracking-mode transition (e.g. from recenterOnUser)
            // and detach the delegate synchronously, so MapKit's own async animation/callback
            // machinery can't touch this view after it's removed from the hierarchy and starts
            // deallocating — leaving an animation running across dismantle is a known MapKit
            // crash source.
            if let mapView = activeMapView {
                mapView.setUserTrackingMode(.none, animated: false)
                mapView.delegate = nil
            }
            activeMapView = nil
        }
        
        @objc private func readLiveRulerGeometry() {
            guard let mapView = activeMapView else { return }
            // When not actively pinching, the camera is locked at selectedScaleMeters via CameraZoomRange.
            // Avoid projecting screen pixels at rest so tiny projection offsets never distort exact ladder scales (e.g. 25m, 10m).
            if !cameraState.isPinching {
                if abs(parent.gameState.liveMapScaleMeters - parent.gameState.selectedScaleMeters) > 0.001 {
                    parent.gameState.liveMapScaleMeters = parent.gameState.selectedScaleMeters
                }
                return
            }
            let liveScale = currentRulerScale(in: mapView)
            if abs(parent.gameState.liveMapScaleMeters - liveScale) > 0.05 {
                parent.gameState.liveMapScaleMeters = liveScale
            }
        }

        func currentRulerScale(in mapView: MKMapView) -> CLLocationDistance {
            AppConstants.UI.RadarScale.continuousScaleMeters(forCameraDistance: mapView.camera.centerCoordinateDistance)
        }

        /// Re-centers on the user for both the center-map button and the auto-relock-on-
        /// pan-back path, by simply re-engaging native `.follow` — same as Apple Maps'
        /// own locate-me button. Altitude stability comes from the standing CameraZoomRange
        /// clamp (seeded in makeUIView and re-asserted on pinch release) rather than a per-transition
        /// manual camera override, so MapKit enforces the altitude constraint continuously
        /// against its own tracking-mode transitions without popping or drifting.
        func recenterOnUser(in mapView: MKMapView) {
            guard !isRecentering else { return }
            isRecentering = true
            // Deferred to the next run loop turn: `recenterOnUser` is called synchronously from
            // `updateUIView`, which is itself inside a SwiftUI view-update pass. Mutating
            // `gameState.isMapFollowConfirmed` (a `@Published` property) or calling
            // `setUserTrackingMode` (which can synchronously invoke the `didChange mode:`
            // delegate callback, itself mutating `@Published` state) from within that pass is
            // exactly SwiftUI's "Publishing changes from within view updates" case — undefined
            // behavior, not just a benign warning.
            DispatchQueue.main.async { [weak self, weak mapView] in
                guard let self = self, let mapView = mapView, !self.isTornDown else { return }
                // Optimistically unconfirmed until mapView(_:didChange:) reports .follow — if the
                // transition silently never lands (e.g. no fresh location yet), the HUD button stays
                // truthful ("unlocked") instead of assuming the request succeeded.
                self.parent.gameState.isMapFollowConfirmed = false
                mapView.setUserTrackingMode(.follow, animated: true)
            }
            // Self-healing fallback in case .follow never gets confirmed (e.g. no user
            // location yet) — don't let a missed confirmation permanently wedge the guard.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.isRecentering = false
            }
        }

        @objc func handlePinchGesture(_ recognizer: UIPinchGestureRecognizer) {
            guard let mapView = recognizer.view as? MKMapView else { return }
            switch recognizer.state {
            case .began:
                cameraState.isPinching = true
                wasLockedBeforePinch = parent.gameState.mapStateMachine.trackingState.isLocked
                let minDistance = AppConstants.UI.RadarScale.cameraDistance(forScale: AppConstants.UI.RadarScale.minScaleMeters)
                let maxDistance = AppConstants.UI.RadarScale.cameraDistance(forScale: AppConstants.UI.RadarScale.maxiOSScaleMeters)
                mapView.setCameraZoomRange(.init(minCenterCoordinateDistance: minDistance, maxCenterCoordinateDistance: maxDistance), animated: false)

            case .changed:
                cameraState.isPinching = true

            case .ended, .cancelled:
                let liveScale = currentRulerScale(in: mapView)
                let snapped = AppConstants.UI.RadarScale.snapToDiscreteScale(liveScale)
                let targetDistance = AppConstants.UI.RadarScale.cameraDistance(forScale: snapped)
                
                parent.gameState.sendMapAction(.setScale(meters: snapped))
                parent.gameState.liveMapScaleMeters = snapped

                // Note: a pinch-to-zoom deliberately never dispatches a `.pan` action, even
                // though it can shift `mapView.centerCoordinate` noticeably (MapKit zooms toward
                // the pinch's focal point, not the user). Treating that incidental drift as a
                // manual pan spuriously unlocked tracking on pure zoom gestures — see the
                // recenter below, which re-engages `.follow` unconditionally when the pinch
                // started locked, regardless of how far the zoom moved the center.

                // Not animated: the live pinch has already settled the camera visually close to
                // targetDistance, so the snap to the exact discrete value is imperceptible — and
                // critically, this avoids racing an animated setCameraZoomRange transition against
                // recenterOnUser's animated setUserTrackingMode(.follow) below. Two concurrent
                // animated camera transitions were coalescing/dropping the .follow didChange
                // callback, leaving the HUD button stuck showing "unlocked" even once the camera
                // had visibly settled back into following the user.
                mapView.setCameraZoomRange(.init(minCenterCoordinateDistance: targetDistance, maxCenterCoordinateDistance: targetDistance), animated: false)

                if wasLockedBeforePinch && parent.gameState.mapStateMachine.trackingState.isLocked {
                    recenterOnUser(in: mapView)
                    // Show the HUD button as locked immediately rather than waiting on
                    // mapView(_:didChange:) to confirm .follow. The camera is already sitting at
                    // the exact target distance (set above) and the pinch never actually left
                    // .locked, so re-engaging .follow here is a formality, not a real transition —
                    // there's no meaningful risk of the button lying ahead of the camera.
                    parent.gameState.isMapFollowConfirmed = true
                }

                wasLockedBeforePinch = false
                cameraState.isPinching = false

            default:
                cameraState.isPinching = false
                wasLockedBeforePinch = false
            }
        }

        @objc func handleTapGesture(_ recognizer: UITapGestureRecognizer) {
            guard let mapView = recognizer.view as? MKMapView else { return }
            if recognizer.state == .ended {
                let tapPoint = recognizer.location(in: mapView)
                let coord = mapView.convert(tapPoint, toCoordinateFrom: mapView)
                parent.onMapTapped?(coord)
            }
        }
        
        func syncAnnotations(in mapView: MKMapView) {
            // Local player ("me") user-location annotation: refresh its hosted rotation/content
            // on every sync pass so the icon heading transform keeps tracking the live,
            // locally-computed speed-weighted COD (blendedHeading) instead of freezing at
            // whatever heading was current when MapKit first created the annotation view.
            // viewFor(annotation:) is only invoked by MapKit once per view creation, so without
            // this explicit refresh here the me icon rotation goes stale after first draw.
            if let userLocationView = mapView.view(for: mapView.userLocation) {
                // Set bounds (size only), never frame — MapKit continuously repositions this
                // view's frame/center itself during .follow tracking; overwriting frame here
                // (with an explicit origin) fights that every sync pass and drags the dot away
                // from the map's true center.
                applyMemberContent(
                    member: parent.gameState.localPlayerMember,
                    isMe: true,
                    to: userLocationView,
                    size: AppConstants.UI.MapMarkers.markerFrameSize
                )
            }

            // Teammates
            let existingMembers = mapView.annotations.compactMap { $0 as? SquadMemberAnnotation }
            let currentMembers = parent.gameState.otherSquadMembers
            let currentMemberIds = Set(currentMembers.map { $0.id })
            
            for anno in existingMembers where !currentMemberIds.contains(anno.memberId) {
                if let view = mapView.view(for: anno) {
                    releaseMemberContent(for: view)
                }
                mapView.removeAnnotation(anno)
            }

            for member in currentMembers {
                let displayCoordinate = parent.gameState.remoteDisplayPositions[member.id] ?? member.coordinate
                if let existing = existingMembers.first(where: { $0.memberId == member.id }) {
                    existing.coordinate = displayCoordinate
                    existing.member = member
                    if let view = mapView.view(for: existing) {
                        let teammateFrameSize = AppConstants.UI.MapMarkers.markerFrameSize * AppConstants.UI.MapMarkers.otherPlayerScaleFactor
                        applyMemberContent(member: member, isMe: false, to: view, size: teammateFrameSize)
                    }
                } else {
                    let newAnno = SquadMemberAnnotation(member: member)
                    newAnno.coordinate = displayCoordinate
                    mapView.addAnnotation(newAnno)
                }
            }
            
            // Tactical indicators
            let existingTactical = mapView.annotations.compactMap { $0 as? TacticalIndicatorMKAnnotation }
            let currentTactical = parent.gameState.allTacticalIndicators
            let currentTacticalIds = Set(currentTactical.map { $0.id })
            
            for anno in existingTactical where !currentTacticalIds.contains(anno.indicatorId) {
                if let view = mapView.view(for: anno) {
                    releaseTacticalContent(for: view)
                }
                mapView.removeAnnotation(anno)
            }
            
            for indicator in currentTactical {
                if let existing = existingTactical.first(where: { $0.indicatorId == indicator.id }) {
                    existing.coordinate = indicator.coordinate
                    existing.indicator = indicator
                    if let view = mapView.view(for: existing) {
                        applyTacticalContent(indicator: indicator, to: view)
                    }
                } else {
                    let newAnno = TacticalIndicatorMKAnnotation(indicator: indicator)
                    mapView.addAnnotation(newAnno)
                }
            }

            updateDistanceLine(in: mapView)
        }

        // MARK: - MKMapViewDelegate
        
        public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                let identifier = "UserLocationView"
                var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? TacticalMKAnnotationView
                if view == nil {
                    view = TacticalMKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                    view?.canShowCallout = false
                }
                view?.annotation = annotation
                if let view {
                    applyMemberContent(member: parent.gameState.localPlayerMember, isMe: true, to: view, size: AppConstants.UI.MapMarkers.markerFrameSize)
                }
                return view
            }

            if let memberAnno = annotation as? SquadMemberAnnotation {
                let identifier = "SquadMemberAnnotationView"
                var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? TacticalMKAnnotationView
                if view == nil {
                    view = TacticalMKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                    view?.canShowCallout = false
                }
                view?.annotation = annotation
                if let view {
                    let teammateFrameSize = AppConstants.UI.MapMarkers.markerFrameSize * AppConstants.UI.MapMarkers.otherPlayerScaleFactor
                    applyMemberContent(member: memberAnno.member, isMe: false, to: view, size: teammateFrameSize)
                }
                return view
            }
            
            if let tacticalAnno = annotation as? TacticalIndicatorMKAnnotation {
                let identifier = "TacticalIndicatorAnnotationView"
                var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? TacticalMKAnnotationView
                if view == nil {
                    view = TacticalMKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                    view?.canShowCallout = false
                }
                view?.annotation = annotation
                if let view {
                    applyTacticalContent(indicator: tacticalAnno.indicator, to: view)
                }
                return view
            }

            if let distanceLabelAnno = annotation as? DistanceLabelMKAnnotation {
                let identifier = "DistanceLabelAnnotationView"
                var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                if view == nil {
                    view = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                    view?.canShowCallout = false
                }
                view?.annotation = annotation
                if let view {
                    applyDistanceLabelContent(text: distanceLabelAnno.text, to: view)
                }
                return view
            }

            return nil
        }

        public func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor(parent.gameState.radarColorTheme.color).withAlphaComponent(0.85)
                renderer.lineWidth = 1.0
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }

        // MapKit automatically drops user-tracking mode to `.none` the moment the user
        // drags the map away from the followed location — this is the native signal that
        // panning has taken the map off centering (spec: "standard mapkit pan, map no
        // longer centers on local user").
        public func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            guard !isTornDown else { return }
            if mode == .follow {
                isRecentering = false
                parent.gameState.isMapFollowConfirmed = true
            }
            // See TacticalPhoneCameraState.isPinching: a zoom-only pinch also drops tracking
            // to .none and must not be misread as the user having panned away. Likewise while
            // a programmatic recenter animation is still in flight, MapKit can transiently
            // report .none mid-transition — don't mistake that for a manual pan and relock
            // onto whatever (interpolated, effectively arbitrary) coordinate it reports.
            guard !cameraState.isPinching, !isRecentering else { return }
            guard mode == .none, let userCoord = mapView.userLocation.location?.coordinate else { return }
            parent.gameState.isMapFollowConfirmed = false
            parent.gameState.sendMapAction(.pan(to: mapView.centerCoordinate, userCoord: userCoord))
        }

        // While panned, keep re-evaluating distance-to-user on every region change so the
        // map re-locks automatically once panned back near the user (spec: "if panned back
        // near user, reapply center map mode").
        public func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard !isTornDown else { return }
            guard !cameraState.isPinching, !isRecentering else { return }
            guard mapView.userTrackingMode == .none,
                  let userCoord = mapView.userLocation.location?.coordinate else { return }
            parent.gameState.sendMapAction(.pan(to: mapView.centerCoordinate, userCoord: userCoord))
        }
    }
}
#endif
