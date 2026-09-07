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
    var isHandlingUserInteraction = false
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
    
    public init(
        gameState: GameStateManager,
        onMapTapped: ((CLLocationCoordinate2D) -> Void)? = nil
    ) {
        self.gameState = gameState
        self.onMapTapped = onMapTapped
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    public func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        // Standard map view is stock Apple Maps behavior end to end: native continuous
        // pinch-zoom/pan and native .follow tracking, with no altitude overrides of our own
        // and no discrete step snapping — that ladder is exclusively a Radar view concern
        // (see TacticalRadarMapView.snapScaleToRadarLadder). Letting MapKit fully own the
        // camera (rather than fighting it with our own setCamera calls) is what avoids the
        // camera fighting itself on tracking-mode transitions.
        if gameState.mapStateMachine.trackingState.isLocked {
            mapView.userTrackingMode = .follow
        } else if let panned = gameState.mapStateMachine.trackingState.pannedCoordinate {
            mapView.setCenter(panned, animated: false)
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
    
    public final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: TacticalMKMapView
        let cameraState = TacticalPhoneCameraState()
        private var displayLink: CADisplayLink?
        private weak var activeMapView: MKMapView?
        var lastObservedCenterTrigger: Int
        var lastObservedLockState: Bool

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
            let radarColor = parent.gameState.radarColorTheme.color
            let key = ObjectIdentifier(view)
            if let host = memberHosts[key] {
                host.rootView = MemberAnnotationView(member: member, isMe: isMe, radarColor: radarColor)
                host.view.frame = view.bounds
            } else {
                view.subviews.forEach { $0.removeFromSuperview() }
                let host = UIHostingController(rootView: MemberAnnotationView(member: member, isMe: isMe, radarColor: radarColor))
                host.view.backgroundColor = .clear
                host.view.frame = view.bounds
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
            let half = touchTargetSize / 2
            view.frame = CGRect(x: 0, y: 0, width: touchTargetSize, height: touchTargetSize)
            view.centerOffset = .zero
            
            let key = ObjectIdentifier(view)
            let radarColor = parent.gameState.radarColorTheme.color
            let onDelete: () -> Void = { [weak self] in
                self?.parent.gameState.removeTacticalIndicator(id: indicator.id)
            }
            
            if let host = tacticalHosts[key] {
                host.rootView = TacticalIndicatorOverlayView(
                    indicator: indicator,
                    radarColor: radarColor,
                    onDelete: onDelete
                )
                host.view.frame = CGRect(x: -half, y: -half, width: touchTargetSize, height: touchTargetSize)
            } else {
                view.subviews.forEach { $0.removeFromSuperview() }
                let host = UIHostingController(rootView: TacticalIndicatorOverlayView(
                    indicator: indicator,
                    radarColor: radarColor,
                    onDelete: onDelete
                ))
                host.view.backgroundColor = .clear
                host.view.frame = CGRect(x: -half, y: -half, width: touchTargetSize, height: touchTargetSize)
                view.addSubview(host.view)
                tacticalHosts[key] = host
            }
        }
        
        /// Drops the cached hosting controller for a removed tactical indicator view.
        private func releaseTacticalContent(for view: MKAnnotationView) {
            tacticalHosts.removeValue(forKey: ObjectIdentifier(view))
        }
        
        func setupDisplayLink(for mapView: MKMapView) {
            self.activeMapView = mapView
            let link = CADisplayLink(target: self, selector: #selector(readLiveRulerGeometry))
            link.add(to: .main, forMode: .common)
            self.displayLink = link
        }
        
        func tearDown() {
            displayLink?.invalidate()
            displayLink = nil
        }
        
        @objc private func readLiveRulerGeometry() {
            // Ruler must always reflect the map's true current scale in real time —
            // tracking every change, including during camera animations — not just
            // while a pinch gesture is active. Per UX spec: "displays actual map
            // zoom scale in real time tracking its every change even during animations."
            guard let mapView = activeMapView else { return }
            // Read-only: this loop never writes the camera. The ruler just honestly reports
            // whatever scale the (fully MapKit-owned) camera actually is.
            let liveScale = currentRulerScale(in: mapView)
            if abs(parent.gameState.liveMapScaleMeters - liveScale) > 0.05 {
                parent.gameState.liveMapScaleMeters = liveScale
            }
        }

        func currentRulerScale(in mapView: MKMapView) -> CLLocationDistance {
            let rulerWidthPoints = Double(AppConstants.UI.HUD.rulerBarWidth + (AppConstants.UI.HUD.rulerNotchMajorWidth * 2))
            let centerPoint = CGPoint(x: mapView.bounds.midX, y: mapView.bounds.midY)
            let p1 = CGPoint(x: centerPoint.x - (rulerWidthPoints / 2.0), y: centerPoint.y)
            let p2 = CGPoint(x: centerPoint.x + (rulerWidthPoints / 2.0), y: centerPoint.y)
            
            let c1 = mapView.convert(p1, toCoordinateFrom: mapView)
            let c2 = mapView.convert(p2, toCoordinateFrom: mapView)
            
            let loc1 = CLLocation(latitude: c1.latitude, longitude: c1.longitude)
            let loc2 = CLLocation(latitude: c2.latitude, longitude: c2.longitude)
            let dist = loc1.distance(from: loc2)
            return max(1.0, dist)
        }

        /// Re-centers on the user for both the center-map button and the auto-relock-on-
        /// pan-back path, by simply re-engaging native `.follow` — same as Apple Maps'
        /// own locate-me button. No manual camera correction: letting MapKit own the
        /// transition (including its own handling of any residual pan/deceleration motion)
        /// is what avoids fighting its camera, which is what caused the altitude to jump
        /// to a MapKit-computed default after a previous, more hands-on version of this.
        func recenterOnUser(in mapView: MKMapView) {
            mapView.setUserTrackingMode(.follow, animated: true)
        }

        @objc func handlePinchGesture(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                cameraState.isPinching = true
            default:
                cameraState.isPinching = false
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
                        applyMemberContent(member: member, isMe: false, to: view, size: AppConstants.UI.MapMarkers.markerFrameSize)
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
        }
        
        // MARK: - MKMapViewDelegate
        
        public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                let identifier = "UserLocationView"
                var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                if view == nil {
                    view = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
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
                var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                if view == nil {
                    view = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                    view?.canShowCallout = false
                }
                view?.annotation = annotation
                if let view {
                    applyMemberContent(member: memberAnno.member, isMe: false, to: view, size: AppConstants.UI.MapMarkers.markerFrameSize)
                }
                return view
            }
            
            if let tacticalAnno = annotation as? TacticalIndicatorMKAnnotation {
                let identifier = "TacticalIndicatorAnnotationView"
                var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                if view == nil {
                    view = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                    view?.canShowCallout = false
                }
                view?.annotation = annotation
                if let view {
                    applyTacticalContent(indicator: tacticalAnno.indicator, to: view)
                }
                return view
            }
            
            return nil
        }

        public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }

        // MapKit automatically drops user-tracking mode to `.none` the moment the user
        // drags the map away from the followed location — this is the native signal that
        // panning has taken the map off centering (spec: "standard mapkit pan, map no
        // longer centers on local user").
        public func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            // See TacticalPhoneCameraState.isPinching: a zoom-only pinch also drops tracking
            // to .none and must not be misread as the user having panned away.
            guard !cameraState.isPinching else { return }
            guard mode == .none, let userCoord = mapView.userLocation.location?.coordinate else { return }
            parent.gameState.sendMapAction(.pan(to: mapView.centerCoordinate, userCoord: userCoord))
        }

        // While panned, keep re-evaluating distance-to-user on every region change so the
        // map re-locks automatically once panned back near the user (spec: "if panned back
        // near user, reapply center map mode").
        public func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard !cameraState.isPinching else { return }
            guard mapView.userTrackingMode == .none,
                  let userCoord = mapView.userLocation.location?.coordinate else { return }
            parent.gameState.sendMapAction(.pan(to: mapView.centerCoordinate, userCoord: userCoord))
        }
    }
}
#endif
