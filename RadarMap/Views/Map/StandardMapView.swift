import SwiftUI
import MapKit
#if canImport(UIKit)
import UIKit
#endif

/// Standard Native MapKit View for full topographic and geographic navigation with custom tactical annotations and Crown zoom.
public struct StandardMapView: View {
    @EnvironmentObject var gameState: GameStateManager
    @Binding var lastCameraCenterCoordinate: CLLocationCoordinate2D?
    let onRequestCrownFocus: () -> Void
    
    @State private var position: MapCameraPosition
    @State private var currentCameraDistance: Double
    @State private var hasSettledInitialCamera: Bool = false
    @State private var userDidPan: Bool = false
    @State private var isUserZooming: Bool = false
    @State private var baseScale: Double = AppConstants.UI.RadarScale.defaultScaleMeters
    
    public init(
        gameState: GameStateManager,
        lastCameraCenterCoordinate: Binding<CLLocationCoordinate2D?>,
        onRequestCrownFocus: @escaping () -> Void = {}
    ) {
        self._lastCameraCenterCoordinate = lastCameraCenterCoordinate
        self.onRequestCrownFocus = onRequestCrownFocus
        
        let scale = gameState.mapStateMachine.scaleMeters
        let distance = AppConstants.UI.RadarScale.cameraDistance(forScale: scale)
        let center = gameState.mapStateMachine.effectiveCenter(userCoord: gameState.localPlayerMember.coordinate)
        let camera = MapCamera(centerCoordinate: center, distance: distance, heading: 0, pitch: 0)
        if gameState.mapStateMachine.trackingState.isLocked {
            self._position = State(initialValue: .userLocation(fallback: .camera(camera)))
        } else {
            self._position = State(initialValue: .camera(camera))
        }
        self._currentCameraDistance = State(initialValue: distance)
    }
    
    private var otherSquadMembers: [SquadMember] {
        gameState.otherSquadMembers
    }
    
    private var meMember: SquadMember {
        gameState.localPlayerMember
    }
    
    private var radarThemeColor: Color {
        gameState.radarColorTheme.color
    }
    
    private var cameraBounds: MapCameraBounds {
        let currentScaleDistance = AppConstants.UI.RadarScale.cameraDistance(forScale: gameState.mapStateMachine.scaleMeters)
        if position.positionedByUser {
            let minDistance = AppConstants.UI.RadarScale.cameraDistance(forScale: AppConstants.UI.RadarScale.minScaleMeters)
            let maxDistance = AppConstants.UI.RadarScale.cameraDistance(forScale: AppConstants.UI.RadarScale.maxiOSScaleMeters)
            return MapCameraBounds(minimumDistance: minDistance, maximumDistance: maxDistance)
        } else if gameState.mapStateMachine.trackingState.isLocked {
            return MapCameraBounds(minimumDistance: currentScaleDistance, maximumDistance: currentScaleDistance)
        } else {
            let minDistance = AppConstants.UI.RadarScale.cameraDistance(forScale: AppConstants.UI.RadarScale.minScaleMeters)
            let maxDistance = AppConstants.UI.RadarScale.cameraDistance(forScale: AppConstants.UI.RadarScale.maxiOSScaleMeters)
            return MapCameraBounds(minimumDistance: minDistance, maximumDistance: maxDistance)
        }
    }
    
    public static func cameraDistance(forScale scaleMeters: Double) -> Double {
        AppConstants.UI.RadarScale.cameraDistance(forScale: scaleMeters)
    }
    
    public var body: some View {
        MapReader { proxy in
            Map(
                position: $position,
                bounds: cameraBounds,
                interactionModes: {
                    #if os(watchOS)
                    return .pan
                    #else
                    return [.pan, .zoom]
                    #endif
                }()
            ) {
                // Remote Teammate Annotations
                ForEach(otherSquadMembers, id: \.id) { member in
                    Annotation(
                        member.callsign,
                        coordinate: member.coordinate,
                        anchor: .center
                    ) {
                        MemberAnnotationView(
                            member: member,
                            isMe: false,
                            radarColor: radarThemeColor
                        )
                        .animation(.linear(duration: 0), value: member.coordinate)
                    }
                    .annotationTitles(.hidden)
                }
                
                // Tactical Indicators
                ForEach(gameState.allTacticalIndicators, id: \.id) { indicator in
                    Annotation(
                        "",
                        coordinate: indicator.coordinate,
                        anchor: .center
                    ) {
                        TacticalIndicatorOverlayView(
                            indicator: indicator,
                            radarColor: radarThemeColor,
                            onDelete: {
                                gameState.removeTacticalIndicator(id: indicator.id)
                            }
                        )
                    }
                }
                
                // CRITICAL RULE: NEVER CHANGE "ME" FROM UserAnnotation TO Annotation.
                // UserAnnotation is required to suppress MapKit's default native blue dot and replace it with our custom vector icon.
                UserAnnotation {
                    MemberAnnotationView(
                        member: meMember,
                        isMe: true,
                        radarColor: radarThemeColor
                    )
                }
            }
            .mapStyle(gameState.selectedMapStyle.mapKitStyle)
            .mapControls { }
            .onMapCameraChange(frequency: .continuous) { context in
                currentCameraDistance = context.camera.distance
                let liveScale = AppConstants.UI.RadarScale.scaleMeters(forCameraDistance: context.camera.distance)
                if position.positionedByUser {
                    let scaleDelta = abs(liveScale - gameState.mapStateMachine.scaleMeters)
                    if scaleDelta > 0.5 {
                        isUserZooming = true
                    }
                }
                if abs(gameState.liveMapScaleMeters - liveScale) > 0.001 {
                    gameState.liveMapScaleMeters = liveScale
                }
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                guard hasSettledInitialCamera else { return }
                
                let center = context.camera.centerCoordinate
                lastCameraCenterCoordinate = center
                let userCoord = gameState.localPlayerMember.coordinate
                
                // Check if user panned away beyond the center threshold
                let dLat = (center.latitude - userCoord.latitude) * AppConstants.Location.metersPerDegreeLatitude
                let dLon = (center.longitude - userCoord.longitude) * AppConstants.Location.metersPerDegreeLatitude * cos(center.latitude * AppConstants.Location.degreesToRadiansFactor)
                let panDist = hypot(dLat, dLon)
                let priorFollowMeLocked = gameState.mapStateMachine.trackingState.isLocked && panDist <= AppConstants.Location.centerThresholdMeters
                
                // Only unlock tracking if the user physically dragged/panned away
                if position.positionedByUser && panDist > AppConstants.Location.centerThresholdMeters {
                    gameState.sendMapAction(.pan(to: center, userCoord: userCoord))
                }
                
                // ONLY snap scale if an actual user zoom operation took place
                if isUserZooming {
                    isUserZooming = false
                    
                    let currentScale = AppConstants.UI.RadarScale.scaleMeters(forCameraDistance: context.camera.distance)
                    let snappedScale = AppConstants.UI.RadarScale.snapToDiscreteScale(currentScale)
                    let targetDistance = AppConstants.UI.RadarScale.cameraDistance(forScale: snappedScale)
                    currentCameraDistance = targetDistance
                    
                    gameState.sendMapAction(.setScale(meters: snappedScale))
                    
                    let targetCenter = gameState.mapStateMachine.effectiveCenter(userCoord: userCoord)
                    let camera = MapCamera(centerCoordinate: targetCenter, distance: targetDistance, heading: 0, pitch: 0)
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        if priorFollowMeLocked {
                            position = .userLocation(fallback: .camera(camera))
                        } else {
                            position = .camera(camera)
                        }
                    }
                }
                onRequestCrownFocus()
            }
            .onTapGesture { screenPoint in
                if gameState.pendingIndicatorPlacementType != nil,
                   let coordinate = proxy.convert(screenPoint, from: .local) {
                    gameState.placeTacticalIndicator(at: coordinate)
                }
            }
            #if os(watchOS)
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { _ in
                        userDidPan = true
                    }
                    .onEnded { _ in
                        onRequestCrownFocus()
                    }
            )
            #endif
            .edgesIgnoringSafeArea(.all)
        }
        .edgesIgnoringSafeArea(.all)
        .onChange(of: gameState.mapStateMachine.scaleMeters) { _, newScale in
            baseScale = newScale
            isUserZooming = false
            let targetDistance = AppConstants.UI.RadarScale.cameraDistance(forScale: newScale)
            if abs(currentCameraDistance - targetDistance) > 1.0 {
                currentCameraDistance = targetDistance
                let targetCenter = gameState.mapStateMachine.effectiveCenter(userCoord: meMember.coordinate)
                let camera = MapCamera(centerCoordinate: targetCenter, distance: targetDistance, heading: 0, pitch: 0)
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    if gameState.mapStateMachine.trackingState.isLocked {
                        position = .userLocation(fallback: .camera(camera))
                    } else {
                        position = .camera(camera)
                    }
                }
            }
        }
        .onChange(of: gameState.mapStateMachine.centerTriggerCount) { _, _ in
            let userCoord = meMember.coordinate
            lastCameraCenterCoordinate = userCoord
            userDidPan = false
            isUserZooming = false
            let distance = AppConstants.UI.RadarScale.cameraDistance(forScale: gameState.mapStateMachine.scaleMeters)
            currentCameraDistance = distance
            let camera = MapCamera(centerCoordinate: userCoord, distance: distance, heading: 0, pitch: 0)
            withAnimation(.easeInOut(duration: 0.25)) {
                position = .userLocation(fallback: .camera(camera))
            }
        }
        .onChange(of: gameState.mapStateMachine.trackingState) { _, state in
            isUserZooming = false
            let distance = AppConstants.UI.RadarScale.cameraDistance(forScale: gameState.mapStateMachine.scaleMeters)
            let targetCenter = state.isLocked ? meMember.coordinate : (state.pannedCoordinate ?? meMember.coordinate)
            lastCameraCenterCoordinate = targetCenter
            currentCameraDistance = distance
            let camera = MapCamera(centerCoordinate: targetCenter, distance: distance, heading: 0, pitch: 0)
            withAnimation(.easeInOut(duration: 0.25)) {
                if state.isLocked {
                    position = .userLocation(fallback: .camera(camera))
                } else {
                    position = .camera(camera)
                }
            }
        }
        .onAppear {
            hasSettledInitialCamera = false
            baseScale = gameState.mapStateMachine.scaleMeters
            userDidPan = false
            isUserZooming = false
            gameState.liveMapScaleMeters = gameState.mapStateMachine.scaleMeters
            let distance = AppConstants.UI.RadarScale.cameraDistance(forScale: gameState.mapStateMachine.scaleMeters)
            currentCameraDistance = distance
            let targetCenter = gameState.mapStateMachine.effectiveCenter(userCoord: meMember.coordinate)
            lastCameraCenterCoordinate = targetCenter
            let camera = MapCamera(centerCoordinate: targetCenter, distance: distance, heading: 0, pitch: 0)
            if gameState.mapStateMachine.trackingState.isLocked {
                position = .userLocation(fallback: .camera(camera))
            } else {
                position = .camera(camera)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                hasSettledInitialCamera = true
            }
        }
    }
}
