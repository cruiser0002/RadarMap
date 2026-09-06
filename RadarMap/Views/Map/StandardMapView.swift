import SwiftUI
import MapKit
import CoreLocation

/// Standard Map presentation router: uses TacticalMKMapView on iOS and SwiftUI Map on watchOS / other platforms.
public struct StandardMapView: View {
    @ObservedObject var gameState: GameStateManager
    @Binding var lastCameraCenterCoordinate: CLLocationCoordinate2D?
    let onRequestCrownFocus: () -> Void
    
    public init(
        gameState: GameStateManager,
        lastCameraCenterCoordinate: Binding<CLLocationCoordinate2D?>,
        onRequestCrownFocus: @escaping () -> Void = {}
    ) {
        self.gameState = gameState
        self._lastCameraCenterCoordinate = lastCameraCenterCoordinate
        self.onRequestCrownFocus = onRequestCrownFocus
    }
    
    public var body: some View {
        #if os(iOS)
        TacticalMKMapView(
            gameState: gameState,
            onMapTapped: { coordinate in
                if gameState.pendingIndicatorPlacementType != nil {
                    gameState.placeTacticalIndicator(at: coordinate)
                }
            }
        )
        #else
        NativeSwiftUIMapView(
            gameState: gameState,
            lastCameraCenterCoordinate: $lastCameraCenterCoordinate,
            onRequestCrownFocus: onRequestCrownFocus
        )
        #endif
    }
}

#if !os(iOS)
/// Native SwiftUI MapKit View retaining system-managed GPS source selection.
struct NativeSwiftUIMapView: View {
    @ObservedObject var gameState: GameStateManager
    @Binding var lastCameraCenterCoordinate: CLLocationCoordinate2D?
    let onRequestCrownFocus: () -> Void
    
    @State private var position: MapCameraPosition
    @State private var currentCameraDistance: Double
    @State private var hasSettledInitialCamera: Bool = false
    @State private var userDidPan: Bool = false
    
    init(
        gameState: GameStateManager,
        lastCameraCenterCoordinate: Binding<CLLocationCoordinate2D?>,
        onRequestCrownFocus: @escaping () -> Void = {}
    ) {
        self.gameState = gameState
        self._lastCameraCenterCoordinate = lastCameraCenterCoordinate
        self.onRequestCrownFocus = onRequestCrownFocus
        
        let scale = gameState.selectedScaleMeters
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
        let distance = AppConstants.UI.RadarScale.cameraDistance(forScale: gameState.selectedScaleMeters)
        if gameState.mapStateMachine.trackingState.isLocked {
            return MapCameraBounds(minimumDistance: distance, maximumDistance: distance)
        } else {
            let minDistance = AppConstants.UI.RadarScale.cameraDistance(forScale: AppConstants.UI.RadarScale.minScaleMeters)
            let maxDistance = AppConstants.UI.RadarScale.cameraDistance(forScale: AppConstants.UI.RadarScale.maxScaleMeters)
            return MapCameraBounds(minimumDistance: minDistance, maximumDistance: maxDistance)
        }
    }
    
    var body: some View {
        MapReader { proxy in
            Map(
                position: $position,
                bounds: cameraBounds,
                interactionModes: .pan
            ) {
                // Remote Teammates
                ForEach(otherSquadMembers, id: \.id) { member in
                    let displayCoordinate = gameState.remoteDisplayPositions[member.id] ?? member.coordinate
                    Annotation(
                        member.callsign,
                        coordinate: displayCoordinate,
                        anchor: .center
                    ) {
                        MemberAnnotationView(
                            member: member,
                            isMe: false,
                            radarColor: radarThemeColor
                        )
                        .animation(.linear(duration: 0), value: displayCoordinate)
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
                
                // Native User Location customized without owning coordinates
                UserAnnotation {
                    MemberAnnotationView(
                        member: meMember,
                        isMe: true,
                        radarColor: radarThemeColor
                    )
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .mapControls { }
            .onMapCameraChange(frequency: .onEnd) { context in
                guard hasSettledInitialCamera else { return }
                let center = context.camera.centerCoordinate
                lastCameraCenterCoordinate = center
                let userCoord = gameState.localPlayerMember.coordinate
                
                let dLat = (center.latitude - userCoord.latitude) * AppConstants.Location.metersPerDegreeLatitude
                let dLon = (center.longitude - userCoord.longitude) * AppConstants.Location.metersPerDegreeLatitude * cos(center.latitude * AppConstants.Location.degreesToRadiansFactor)
                let panDist = hypot(dLat, dLon)
                
                if position.positionedByUser && panDist > AppConstants.Location.centerThresholdMeters {
                    gameState.sendMapAction(.pan(to: center, userCoord: userCoord))
                }
                #if os(watchOS)
                if userDidPan {
                    userDidPan = false
                    gameState.sendMapAction(.pan(to: center, userCoord: userCoord))
                    onRequestCrownFocus()
                }
                #endif
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
        .onChange(of: gameState.selectedScaleMeters) { _, newScale in
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
            let distance = AppConstants.UI.RadarScale.cameraDistance(forScale: gameState.selectedScaleMeters)
            currentCameraDistance = distance
            let camera = MapCamera(centerCoordinate: userCoord, distance: distance, heading: 0, pitch: 0)
            withAnimation(.easeInOut(duration: 0.25)) {
                position = .userLocation(fallback: .camera(camera))
            }
        }
        .onChange(of: gameState.mapStateMachine.trackingState) { _, state in
            let distance = AppConstants.UI.RadarScale.cameraDistance(forScale: gameState.selectedScaleMeters)
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
            userDidPan = false
            let distance = AppConstants.UI.RadarScale.cameraDistance(forScale: gameState.selectedScaleMeters)
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
#endif
