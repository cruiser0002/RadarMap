import SwiftUI
import CoreLocation
#if canImport(UIKit)
import UIKit
#endif

/// Concentric range-ring radar view for low-power OLED tactical display.
public struct RadarMapView: View {
    @EnvironmentObject var gameState: GameStateManager
    
    // Pan State
    @State private var dragOffset: CGSize = .zero
    @State private var baseScale: Double = AppConstants.UI.RadarScale.defaultScaleMeters
    #if !os(watchOS)
    @State private var pinchInitialScale: Double? = nil
    #endif
    
    public init() {}
    
    private var sortedOtherSquadMembers: [SquadMember] {
        gameState.otherSquadMembers.sorted { m1, m2 in
            let g1 = gameState.isGreen(member: m1)
            let g2 = gameState.isGreen(member: m2)
            if g1 == g2 { return m1.id < m2.id }
            return !g1 && g2
        }
    }
    
    private var sortedTacticalIndicators: [TacticalIndicator] {
        gameState.allTacticalIndicators.sorted { i1, i2 in
            let g1 = gameState.isGreen(indicator: i1)
            let g2 = gameState.isGreen(indicator: i2)
            if g1 == g2 { return i1.timestamp < i2.timestamp }
            return !g1 && g2
        }
    }
    
    public var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let screenCenter = CGPoint(x: size.width / 2, y: size.height / 2)
            let meMember = gameState.localPlayerMember
            let centerCoord = gameState.mapCenterLockState == .locked ? meMember.coordinate : (gameState.currentMapCenter ?? meMember.coordinate)
            let centerPoint = CGPoint(
                x: screenCenter.x + dragOffset.width,
                y: screenCenter.y + dragOffset.height
            )
            let maxRadius = min(size.width, size.height) * AppConstants.UI.RadarScale.radarRadiusRatio
            
            let metersPerDegreeLat = AppConstants.Location.metersPerDegreeLatitude
            let metersPerDegreeLon = metersPerDegreeLat * cos(centerCoord.latitude * AppConstants.Location.degreesToRadiansFactor)
            let currentScaleMeters = gameState.liveMapScaleMeters > 0 ? gameState.liveMapScaleMeters : gameState.radarScaleMeters
            let outerRadarDistanceMeters = currentScaleMeters * 4.0
            let pointsPerMeter = outerRadarDistanceMeters > 0 ? Double(maxRadius) / outerRadarDistanceMeters : 1.0
            
            ZStack {
                // Maximum Black Background for OLED Power Conservation
                Color.black
                    .edgesIgnoringSafeArea(.all)
                
                let themeColor = gameState.radarColorTheme.color
                
                // Concentric Tactical Range Rings (Red or Green - 4 clicks of minor scale)
                ForEach(AppConstants.UI.RadarScale.rangeRingRatios, id: \.self) { ratio in
                    Circle()
                        .stroke(
                            ratio == 1.0 ? themeColor.opacity(0.85) : themeColor.opacity(0.4),
                            lineWidth: ratio == 1.0 ? 1.5 : 1.0
                        )
                        .frame(width: maxRadius * 2 * ratio, height: maxRadius * 2 * ratio)
                        .position(screenCenter)
                }
                
                // Full Diameter Crosshair (+)
                Path { path in
                    let length = maxRadius * AppConstants.UI.RadarScale.crosshairExtensionRatio
                    // Horizontal axis
                    path.move(to: CGPoint(x: screenCenter.x - length, y: screenCenter.y))
                    path.addLine(to: CGPoint(x: screenCenter.x + length, y: screenCenter.y))
                    // Vertical axis
                    path.move(to: CGPoint(x: screenCenter.x, y: screenCenter.y - length))
                    path.addLine(to: CGPoint(x: screenCenter.x, y: screenCenter.y + length))
                }
                .stroke(themeColor.opacity(0.45), lineWidth: 1.0)
                
                // Bold Center '+' Reticle
                Path { path in
                    let plusSize: CGFloat = CGFloat(AppConstants.UI.RadarScale.centerReticleSize)
                    path.move(to: CGPoint(x: screenCenter.x - plusSize, y: screenCenter.y))
                    path.addLine(to: CGPoint(x: screenCenter.x + plusSize, y: screenCenter.y))
                    path.move(to: CGPoint(x: screenCenter.x, y: screenCenter.y - plusSize))
                    path.addLine(to: CGPoint(x: screenCenter.x, y: screenCenter.y + plusSize))
                }
                .stroke(themeColor, lineWidth: 2.0)
                
                // Range Ring Distance Labels (4 intervals: 1S, 2S, 3S, 4S)
                ForEach(Array(AppConstants.UI.RadarScale.rangeRingRatios.enumerated()), id: \.offset) { index, ratio in
                    let clickCount = Double(index + 1)
                    // Live scale (not the committed/settled scale) so labels update in real
                    // time while pinching, matching the Ruler/Radar spec requirement to track
                    // every change even during the gesture/animation.
                    let ringDist = gameState.liveMapScaleMeters * clickCount
                    let diagOffset = (maxRadius * ratio) * cos(.pi / 4.0)
                    Text(AppConstants.UI.ScaleRuler.formatDistance(meters: ringDist))
                        .font(.system(size: AppConstants.UI.HUD.rulerFontSize, weight: .bold, design: .monospaced))
                        .foregroundColor(themeColor.opacity(0.8))
                        .position(x: screenCenter.x + diagOffset, y: screenCenter.y - diagOffset)
                }
                
                // Active Remote Squad Members within outer radar distance (d <= 4S)
                ForEach(sortedOtherSquadMembers, id: \.id) { member in
                    let displayCoordinate = gameState.remoteDisplayPositions[member.id] ?? member.coordinate
                    let d = gameState.distanceToLocalPlayer(from: displayCoordinate)
                    if d <= outerRadarDistanceMeters {
                        let offset = pointOffset(for: displayCoordinate, centerCoord: centerCoord, metersPerDegreeLat: metersPerDegreeLat, metersPerDegreeLon: metersPerDegreeLon, pointsPerMeter: pointsPerMeter)
                        let isSameClan = gameState.isSameClan(callsign: member.callsign)

                        MemberAnnotationView(
                            member: member,
                            isMe: false,
                            isSameClan: isSameClan,
                            isSelected: gameState.selectedAnnotationForDistance == .squadMember(id: member.id),
                            radarColor: themeColor,
                            onTap: {
                                guard gameState.pendingIndicatorPlacementType == nil else { return }
                                gameState.toggleAnnotationSelection(.squadMember(id: member.id))
                            }
                        )
                        .position(x: centerPoint.x + offset.x, y: centerPoint.y + offset.y)
                        .zIndex(isSameClan ? AppConstants.UI.MapMarkers.greenTouchPriorityZIndex : AppConstants.UI.MapMarkers.defaultTouchPriorityZIndex)
                        .animation(.linear(duration: 0), value: displayCoordinate)
                    }
                }

                // Active Tactical Indicators within outer radar distance (d <= 4S)
                ForEach(sortedTacticalIndicators) { indicator in
                    let d = gameState.distanceToLocalPlayer(from: indicator.coordinate)
                    if d <= outerRadarDistanceMeters {
                        let offset = pointOffset(for: indicator.coordinate, centerCoord: centerCoord, metersPerDegreeLat: metersPerDegreeLat, metersPerDegreeLon: metersPerDegreeLon, pointsPerMeter: pointsPerMeter)
                        let isPlacedByMe = indicator.placedByMemberId == gameState.myMemberId
                        let isSameClan = gameState.isIndicatorFromSameClan(indicator)
                        let isGreen = (indicator.category == .squadOrder) && (isPlacedByMe || isSameClan)

                        TacticalIndicatorOverlayView(
                            indicator: indicator,
                            isPlacedByMe: isPlacedByMe,
                            isSameClan: isSameClan,
                            radarColor: themeColor,
                            onDelete: {
                                gameState.removeTacticalIndicator(id: indicator.id)
                            },
                            onTap: {
                                guard gameState.pendingIndicatorPlacementType == nil else { return }
                                gameState.toggleAnnotationSelection(.tacticalIndicator(id: indicator.id))
                            }
                        )
                        .position(x: centerPoint.x + offset.x, y: centerPoint.y + offset.y)
                        .zIndex(isGreen ? AppConstants.UI.MapMarkers.greenTouchPriorityZIndex : AppConstants.UI.MapMarkers.defaultTouchPriorityZIndex)
                    }
                }

                // Local Player "Me" (Always pinned to local player offset / center)
                let meOffset = pointOffset(for: meMember.coordinate, centerCoord: centerCoord, metersPerDegreeLat: metersPerDegreeLat, metersPerDegreeLon: metersPerDegreeLon, pointsPerMeter: pointsPerMeter)
                MemberAnnotationView(
                    member: meMember,
                    isMe: true,
                    radarColor: themeColor,
                    onTap: {
                        gameState.selectedAnnotationForDistance = nil
                    }
                )
                .position(x: centerPoint.x + meOffset.x, y: centerPoint.y + meOffset.y)
                .zIndex(AppConstants.UI.MapMarkers.greenTouchPriorityZIndex + 1.0)

                // Tap-to-Measure Distance Line: single thin line from "me" to the selected
                // annotation, with the distance labeled at its midpoint. Purely local UI state.
                Group {
                    if let selection = gameState.selectedAnnotationForDistance,
                       let selectedCoordinate = gameState.coordinate(for: selection) {
                        let mePoint = CGPoint(x: centerPoint.x + meOffset.x, y: centerPoint.y + meOffset.y)
                        let selectedOffset = pointOffset(for: selectedCoordinate, centerCoord: centerCoord, metersPerDegreeLat: metersPerDegreeLat, metersPerDegreeLon: metersPerDegreeLon, pointsPerMeter: pointsPerMeter)
                        let selectedPoint = CGPoint(x: centerPoint.x + selectedOffset.x, y: centerPoint.y + selectedOffset.y)
                        let midpoint = CGPoint(x: (mePoint.x + selectedPoint.x) / 2, y: (mePoint.y + selectedPoint.y) / 2)
                        let distanceMeters = GameStateManager.distance(from: meMember.coordinate, to: selectedCoordinate)

                        Path { path in
                            path.move(to: mePoint)
                            path.addLine(to: selectedPoint)
                        }
                        .stroke(themeColor.opacity(0.85), lineWidth: 1.0)

                        Text(AppConstants.UI.ScaleRuler.formatDistance(meters: distanceMeters))
                            .font(.system(size: AppConstants.UI.MapMarkers.callsignFontSize, weight: .bold, design: .monospaced))
                            .foregroundColor(themeColor)
                            .lineLimit(1)
                            .padding(.horizontal, 3.0)
                            .padding(.vertical, 1.0)
                            .background(Color.black.opacity(0.85))
                            .cornerRadius(3)
                            .fixedSize()
                            .position(midpoint)
                    }
                }
                .allowsHitTesting(false)
                .zIndex(1.0)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        if abs(value.translation.width) < 4 && abs(value.translation.height) < 4 {
                            return
                        }
                        let endCenter = coordinate(
                            for: CGPoint(x: screenCenter.x - value.translation.width, y: screenCenter.y - value.translation.height),
                            centerScreenPoint: screenCenter,
                            centerCoord: centerCoord,
                            metersPerDegreeLat: metersPerDegreeLat,
                            metersPerDegreeLon: metersPerDegreeLon,
                            pointsPerMeter: pointsPerMeter
                        )
                        gameState.sendMapAction(.pan(to: endCenter, userCoord: meMember.coordinate))
                        dragOffset = .zero
                    }
            )
            #if !os(watchOS)
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        if pinchInitialScale == nil {
                            pinchInitialScale = gameState.liveMapScaleMeters > 0 ? gameState.liveMapScaleMeters : gameState.mapStateMachine.scaleMeters
                        }
                        guard let initial = pinchInitialScale, value.magnification > 0 else { return }
                        // Pinching in (magnification > 1) zooms IN (smaller scaleMeters)
                        // Pinching out (magnification < 1) zooms OUT (larger scaleMeters)
                        let newScale = initial / Double(value.magnification)
                        let clamped = min(max(newScale, AppConstants.UI.RadarScale.minScaleMeters), AppConstants.UI.RadarScale.maxiOSScaleMeters)
                        gameState.liveMapScaleMeters = clamped
                    }
                    .onEnded { value in
                        guard let initial = pinchInitialScale, value.magnification > 0 else {
                            pinchInitialScale = nil
                            return
                        }
                        let newScale = initial / Double(value.magnification)
                        let clamped = min(max(newScale, AppConstants.UI.RadarScale.minScaleMeters), AppConstants.UI.RadarScale.maxiOSScaleMeters)
                        let snapped = AppConstants.UI.RadarScale.snapToDiscreteScale(clamped)
                        pinchInitialScale = nil
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            gameState.sendMapAction(.setScale(meters: snapped))
                            gameState.liveMapScaleMeters = snapped
                        }
                    }
            )
            #endif
            .onTapGesture { location in
                if gameState.pendingIndicatorPlacementType != nil {
                    let tappedCoord = coordinate(
                        for: location,
                        centerScreenPoint: centerPoint,
                        centerCoord: centerCoord,
                        metersPerDegreeLat: metersPerDegreeLat,
                        metersPerDegreeLon: metersPerDegreeLon,
                        pointsPerMeter: pointsPerMeter
                    )
                    gameState.placeTacticalIndicator(at: tappedCoord)
                }
            }
            .onChange(of: gameState.mapStateMachine.scaleMeters) { _, newScale in
                baseScale = newScale
            }
            .onChange(of: gameState.mapStateMachine.centerTriggerCount) { _, _ in
                withAnimation(.easeInOut(duration: 0.25)) {
                    dragOffset = .zero
                    baseScale = gameState.mapStateMachine.scaleMeters
                }
            }
            .onChange(of: gameState.mapStateMachine.trackingState) { _, state in
                if state.isLocked {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        dragOffset = .zero
                    }
                }
            }
            .onAppear {
                baseScale = gameState.mapStateMachine.scaleMeters
                if gameState.mapStateMachine.trackingState.isLocked {
                    dragOffset = .zero
                }
            }
        }
    }
    
    private func pointOffset(for target: CLLocationCoordinate2D, centerCoord: CLLocationCoordinate2D, metersPerDegreeLat: Double, metersPerDegreeLon: Double, pointsPerMeter: Double) -> CGPoint {
        let dLat = target.latitude - centerCoord.latitude
        let dLon = target.longitude - centerCoord.longitude
        
        let metersEast = dLon * metersPerDegreeLon
        let metersNorth = dLat * metersPerDegreeLat
        
        let x = CGFloat(metersEast * pointsPerMeter)
        let y = CGFloat(-metersNorth * pointsPerMeter)
        
        return CGPoint(x: x, y: y)
    }
    
    private func coordinate(for screenPoint: CGPoint, centerScreenPoint: CGPoint, centerCoord: CLLocationCoordinate2D, metersPerDegreeLat: Double, metersPerDegreeLon: Double, pointsPerMeter: Double) -> CLLocationCoordinate2D {
        guard pointsPerMeter > 0, metersPerDegreeLat > 0, metersPerDegreeLon > 0 else { return centerCoord }
        
        let dx = Double(screenPoint.x - centerScreenPoint.x)
        let dy = Double(screenPoint.y - centerScreenPoint.y)
        
        let metersEast = dx / pointsPerMeter
        let metersNorth = -dy / pointsPerMeter
        
        let dLat = metersNorth / metersPerDegreeLat
        let dLon = metersEast / metersPerDegreeLon
        
        return CLLocationCoordinate2D(
            latitude: centerCoord.latitude + dLat,
            longitude: centerCoord.longitude + dLon
        )
    }
}

/// Alias for backward compatibility
public typealias SimpleRadarMapView = RadarMapView
