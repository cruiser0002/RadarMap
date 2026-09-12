import SwiftUI
import MapKit

#if canImport(WatchKit)
import WatchKit
#endif

public struct TacticalRadarMapView: View {
    @EnvironmentObject var gameState: GameStateManager
    #if os(watchOS)
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    #endif
    #if DEBUG
    @AppStorage(AppConstants.Storage.isDebugDisplayEnabledKey) private var isDebugFieldEnabled: Bool = true
    #endif
    @State private var showingSettingsSheet: Bool = false
    @State private var showingIndicatorMenuSheet: Bool = false
    @State private var showingPaywallSheet: Bool = false
    @State private var lastCameraCenterCoordinate: CLLocationCoordinate2D? = nil
    #if os(watchOS)
    /// Incremented to tell CrownInputView to re-claim focus. Using a counter rather than
    /// a Bool so that repeated requests are always observable as distinct changes.
    @State private var crownFocusTrigger: Int = 0
    #endif
    
    // Hold gesture state for KIA / Revive
    @State private var isHoldingActionButton: Bool = false
    @State private var actionProgress: Double = 0.0
    @State private var holdTimer: Timer? = nil
    @State private var actionCompletedForCurrentTouch: Bool = false
    @State private var heartRateTouchDate: Date = Date()
    
    // EKG scan speed — dynamically computed from live heart rate and KIA state.
    private var sweepDuration: Double {
        let bpm = gameState.effectiveHeartRate
        return AppConstants.Health.referenceBpm / max(20.0, bpm > 0 ? bpm : AppConstants.Health.defaultRestingHeartRate)
    }

    // Numeric BPM readout — mirrors the same effective-heart-rate rule used when
    // broadcasting telemetry (GameStateManager.sendTelemetry): flatline (0) when KIA,
    // speed-simulated or live optical HR.
    private var displayedHeartRate: Int {
        Int(gameState.effectiveHeartRate)
    }
    
    public init() {}
    
    private var meMember: SquadMember {
        gameState.localPlayerMember
    }
    
    private var otherSquadMembers: [SquadMember] {
        gameState.otherSquadMembers
    }
    
    private var radarThemeColor: Color {
        gameState.radarColorTheme.color
    }
    
    private var uiThemeColor: Color {
        if gameState.selectedPresentation == .radar {
            return radarThemeColor
        } else {
            return .primary
        }
    }
    
    /// Snaps the current (freely pinch/pan-zoomed) map scale to the nearest discrete
    /// `[1, 2.5, 5]` radar ladder value. Called on transition into `.radar` so the range
    /// rings always land on a clean decade scale. Reads `liveMapScaleMeters` — the
    /// standard map view's actual live camera scale — rather than the committed
    /// `mapStateMachine.scaleMeters`, since standard map's native Apple-Maps-style zoom
    /// never writes back into the committed scale while it's being freely zoomed.
    private func snapScaleToRadarLadder() {
        let snapped = AppConstants.UI.RadarScale.snapToDiscreteScale(gameState.liveMapScaleMeters)
        gameState.sendMapAction(.setScale(meters: snapped))
        gameState.liveMapScaleMeters = snapped
    }

    public var body: some View {
        ZStack {
            // Standard Native MapKit View
            if gameState.selectedPresentation != .radar {
                StandardMapView(
                    gameState: gameState,
                    lastCameraCenterCoordinate: $lastCameraCenterCoordinate,
                    onRequestCrownFocus: {
                        #if os(watchOS)
                        crownFocusTrigger += 1
                        #endif
                    }
                )
                .edgesIgnoringSafeArea(.all)
                .zIndex(0)
            }

            // Concentric Range Ring Radar View
            if gameState.selectedPresentation == .radar {
                RadarMapView()
                    .edgesIgnoringSafeArea(.all)
                    .zIndex(1)
            }
            
            // Tactical HUD Overlays (Highest priority over map)
            VStack {
                // Top HUD (Upper left: Config, Center: Squad Leader / Commander Button, Upper right: +/- on phone or Version & Debug info)
                ZStack(alignment: .top) {
                    // Left and Right edge controls
                    HStack(alignment: .top) {
                        // Upper left: Settings gear
                        Button(action: {
                            showingSettingsSheet = true
                        }) {
                            ZStack {
                                Circle()
                                    .fill(Color.black.opacity(0.85))
                                    .shadow(color: .black.opacity(0.75), radius: 2.5)
                                
                                Image(systemName: "gearshape.fill")
                                    .font(.system(size: AppConstants.UI.HUD.circleIconFontSize, weight: .semibold))
                                    .foregroundColor(uiThemeColor)
                            }
                            .frame(width: AppConstants.UI.HUD.circleButtonDiameter, height: AppConstants.UI.HUD.circleButtonDiameter)
                            .frame(width: AppConstants.UI.HUD.circleHitboxSize.width, height: AppConstants.UI.HUD.circleHitboxSize.height, alignment: .center)
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .focusable(false)

                        Spacer()

                        // Upper right: Version & Debug Info on Phone / Watch
                        #if !os(watchOS)
                        VStack(alignment: .trailing, spacing: 2) {
                            #if DEBUG
                            if isDebugFieldEnabled {
                                Text(AppConstants.Version.formattedVersionString)
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(uiThemeColor.opacity(0.6))
                                TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                                    Text(gameState.debugStatusString)
                                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                                        .foregroundColor(uiThemeColor.opacity(0.6))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                            #endif
                        }
                        .frame(minWidth: AppConstants.UI.HUD.circleHitboxSize.width, minHeight: AppConstants.UI.HUD.circleHitboxSize.height, alignment: .trailing)
                        #else
                        VStack(alignment: .trailing, spacing: 1) {
                            #if DEBUG
                            if isDebugFieldEnabled {
                                Text(AppConstants.Version.formattedVersionString)
                                    .font(.system(size: 6, weight: .bold, design: .monospaced))
                                    .foregroundColor(uiThemeColor.opacity(0.55))
                                TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                                    Text(gameState.debugStatusString)
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundColor(uiThemeColor.opacity(0.55))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                            #endif
                        }
                        .frame(minWidth: AppConstants.UI.HUD.circleHitboxSize.width, minHeight: AppConstants.UI.HUD.circleHitboxSize.height, alignment: .trailing)
                        #endif
                    }

                    // Center Top: Squad Leader / Commander Button (Single star) - perfectly centered horizontally regardless of edge item widths
                    if gameState.subscriptionManager.hasUnlimitedSquadUnlock {
                        Button(action: {
                            gameState.openIndicatorMenu()
                        }) {
                            ZStack {
                                RoundedRectangle(cornerRadius: AppConstants.UI.HUD.rectCornerRadius)
                                    .fill(Color.black.opacity(0.85))
                                
                                Image(systemName: "star.fill")
                                    .font(.system(size: AppConstants.UI.HUD.circleIconFontSize, weight: .bold))
                                    .foregroundColor(uiThemeColor)
                                
                                RoundedRectangle(cornerRadius: AppConstants.UI.HUD.rectCornerRadius)
                                    .stroke(uiThemeColor.opacity(0.75), lineWidth: 1.0)
                            }
                            .frame(width: AppConstants.UI.HUD.rectButtonWidth, height: AppConstants.UI.HUD.rectButtonHeight)
                            .frame(width: AppConstants.UI.HUD.rectHitboxSize.width, height: AppConstants.UI.HUD.rectHitboxSize.height, alignment: .center)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                    }
                }
                .padding(.horizontal, AppConstants.UI.HUD.horizontalPadding)
                .padding(.top, AppConstants.UI.HUD.topPadding)
                
                Spacer()
                
                // Bottom HUD: Center/Zoom (bottom left), Ruler or KIA (bottom center), Map Style Switch (bottom right)
                HStack(alignment: .center) {
                    // Bottom left: Map centering & default zoom (all views)
                    Button(action: {
                        centerMapToUser()
                    }) {
                        ZStack {
                            Circle()
                                .fill(Color.black.opacity(0.85))
                                .shadow(color: .black.opacity(0.75), radius: 2.5)
                            
                            Image(systemName: gameState.showsAsCenterLocked ? "location.fill" : "location")
                                .font(.system(size: AppConstants.UI.HUD.circleIconFontSize, weight: .semibold))
                                .foregroundColor(uiThemeColor)
                        }
                        .frame(width: AppConstants.UI.HUD.circleButtonDiameter, height: AppConstants.UI.HUD.circleButtonDiameter)
                        .frame(width: AppConstants.UI.HUD.circleHitboxSize.width, height: AppConstants.UI.HUD.circleHitboxSize.height, alignment: .center)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)

                    Spacer()

                    // Bottom center: Fixed slot for both views (KIA on Radar, Ruler on MapKit)
                    Group {
                        if gameState.selectedPresentation == .radar {
                            let themeColor = uiThemeColor
                            let buttonWidth: CGFloat = AppConstants.UI.HUD.rectButtonWidth
                            let buttonHeight: CGFloat = AppConstants.UI.HUD.rectButtonHeight
                            let cornerRad: CGFloat = AppConstants.UI.HUD.rectCornerRadius
                            let ekgSize: CGSize = AppConstants.UI.HUD.ekgWaveSize
                            #if os(watchOS)
                            let scanInterval = isLuminanceReduced ? 1.0 : AppConstants.Timing.DisplayRefresh.radarUIIntervalSeconds
                            #else
                            let scanInterval = AppConstants.Timing.DisplayRefresh.radarUIIntervalSeconds
                            #endif
                            
                            TimelineView(.periodic(from: .now, by: scanInterval)) { timeline in
                                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                                let progress = (elapsed.truncatingRemainder(dividingBy: sweepDuration)) / sweepDuration
                                let hrElapsed = max(0.0, timeline.date.timeIntervalSince(heartRateTouchDate))
                                let hrOpacity = isHoldingActionButton ? 1.0 : max(0.0, min(1.0, 1.0 - (hrElapsed / AppConstants.UI.HUD.heartRateFadeDurationSeconds)))
                                
                                ZStack(alignment: .leading) {
                                    // Background
                                    RoundedRectangle(cornerRadius: cornerRad)
                                        .fill(Color.black.opacity(0.85))
                                    
                                    // Left-to-right progress fill on hold
                                    if actionProgress > 0 {
                                        RoundedRectangle(cornerRadius: cornerRad)
                                            .fill(themeColor.opacity(0.55))
                                            .frame(width: max(0, buttonWidth * CGFloat(actionProgress)))
                                    }
                                    
                                    // Center EKG graphic with tracking scanning dot
                                    ZStack {
                                        // Heartbeat pulse wave (ECG waveform or flatline when dead)
                                        ECGWaveShape(isFlatline: gameState.isDead)
                                            .stroke(
                                                themeColor.opacity(gameState.isDead ? 0.7 : 0.45),
                                                style: StrokeStyle(lineWidth: AppConstants.UI.HUD.ekgLineWidth, lineCap: .round, lineJoin: .round)
                                            )

                                        // Scanning dot riding along the EKG / flatline line
                                        let dotPos = ECGWaveShape.point(at: CGFloat(progress), in: ekgSize, isFlatline: gameState.isDead)

                                        // Subtle glow halo
                                        Circle()
                                            .fill(themeColor.opacity(0.35))
                                            .frame(width: AppConstants.UI.HUD.ekgHaloSize, height: AppConstants.UI.HUD.ekgHaloSize)
                                            .position(dotPos)

                                        // Bright center core dot
                                        Circle()
                                            .fill(Color.white)
                                            .frame(width: AppConstants.UI.HUD.ekgDotSize, height: AppConstants.UI.HUD.ekgDotSize)
                                            .position(dotPos)
                                    }
                                    .frame(width: ekgSize.width, height: ekgSize.height)
                                    // Numeric BPM readout, overlaid on top without affecting the EKG
                                    // graphic's layout size — full brightness matching the top center
                                    // star button, fading over 3 seconds to 0 transparency; touching
                                    // the button brings it back to full brightness.
                                    .overlay(
                                        Text("\(displayedHeartRate)")
                                            .font(.system(size: AppConstants.UI.HUD.heartRateFontSize, weight: .bold, design: .monospaced))
                                            .foregroundColor(themeColor)
                                            .opacity(hrOpacity)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.5)
                                            .frame(width: buttonWidth, height: buttonHeight)
                                    )
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    
                                    // Tactical outer border
                                    RoundedRectangle(cornerRadius: cornerRad)
                                        .stroke(
                                            themeColor.opacity(isHoldingActionButton ? 1.0 : 0.75),
                                            lineWidth: isHoldingActionButton ? 2.0 : 1.0
                                        )
                                }
                                .frame(width: buttonWidth, height: buttonHeight)
                            }
                            .frame(width: AppConstants.UI.HUD.rectHitboxSize.width, height: AppConstants.UI.HUD.rectHitboxSize.height, alignment: .center)
                            .contentShape(Rectangle())
                            .highPriorityGesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { _ in
                                        heartRateTouchDate = Date()
                                        startActionHold()
                                    }
                                    .onEnded { _ in
                                        heartRateTouchDate = Date()
                                        cancelActionHold()
                                    }
                            )
                        } else {
                            // Tactical Scale Ruler for MapKit views (Fixed slot matching KIA button)
                            VStack(spacing: 2) {
                                // Ruler notches
                                HStack(spacing: 0) {
                                    Rectangle()
                                        .fill(uiThemeColor.opacity(0.9))
                                        .frame(width: AppConstants.UI.HUD.rulerNotchMajorWidth, height: AppConstants.UI.HUD.rulerNotchMajorHeight)
                                    
                                    Rectangle()
                                        .fill(uiThemeColor.opacity(0.6))
                                        .frame(width: AppConstants.UI.HUD.rulerBarWidth, height: AppConstants.UI.HUD.rulerBarHeight)
                                    
                                    Rectangle()
                                        .fill(uiThemeColor.opacity(0.9))
                                        .frame(width: AppConstants.UI.HUD.rulerNotchMajorWidth, height: AppConstants.UI.HUD.rulerNotchMajorHeight)
                                    
                                    Rectangle()
                                        .fill(uiThemeColor.opacity(0.6))
                                        .frame(width: AppConstants.UI.HUD.rulerBarWidth, height: AppConstants.UI.HUD.rulerBarHeight)
                                    
                                    Rectangle()
                                        .fill(uiThemeColor.opacity(0.9))
                                        .frame(width: AppConstants.UI.HUD.rulerNotchMajorWidth, height: AppConstants.UI.HUD.rulerNotchMajorHeight)
                                }
                                
                                Text(gameState.currentScaleText)
                                    .font(.system(size: AppConstants.UI.HUD.rulerFontSize, weight: .bold, design: .monospaced))
                                    .foregroundColor(uiThemeColor.opacity(0.9))
                            }
                            .frame(width: AppConstants.UI.HUD.rectButtonWidth, height: AppConstants.UI.HUD.rectButtonHeight)
                            .background(Color.black.opacity(0.85))
                            .overlay(
                                RoundedRectangle(cornerRadius: AppConstants.UI.HUD.rectCornerRadius)
                                    .stroke(uiThemeColor.opacity(0.35), lineWidth: 1)
                            )
                            .cornerRadius(AppConstants.UI.HUD.rectCornerRadius)
                            .frame(width: AppConstants.UI.HUD.rectHitboxSize.width, height: AppConstants.UI.HUD.rectHitboxSize.height, alignment: .center)
                            .contentShape(Rectangle())
                            .highPriorityGesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { _ in
                                        startActionHold()
                                    }
                                    .onEnded { _ in
                                        cancelActionHold()
                                    }
                            )
                        }
                    }
                    
                    Spacer()
                    
                    // Bottom right: Presentation switch (Map <-> Radar)
                    Button(action: {
                        togglePresentation()
                    }) {
                        ZStack {
                            Circle()
                                .fill(Color.black.opacity(0.85))
                                .shadow(color: .black.opacity(0.75), radius: 2.5)
                            
                            Image(systemName: "map")
                                .font(.system(size: AppConstants.UI.HUD.circleIconFontSize, weight: .semibold))
                                .foregroundColor(uiThemeColor)
                        }
                        .frame(width: AppConstants.UI.HUD.circleButtonDiameter, height: AppConstants.UI.HUD.circleButtonDiameter)
                        .frame(width: AppConstants.UI.HUD.circleHitboxSize.width, height: AppConstants.UI.HUD.circleHitboxSize.height, alignment: .center)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
                .padding(.horizontal, AppConstants.UI.HUD.horizontalPadding)
                .padding(.bottom, AppConstants.UI.HUD.bottomPadding)
            }
            .edgesIgnoringSafeArea(.all)
            .zIndex(10)
        }
        #if os(watchOS)
        .overlay(
            CrownInputView(
                crownIndex: Binding(
                    get: { AppConstants.UI.RadarScale.crownIndex(for: gameState.selectedScaleMeters) },
                    set: { newIndex in
                        let newScale = AppConstants.UI.RadarScale.scale(forCrownIndex: newIndex)
                        if abs(gameState.selectedScaleMeters - newScale) > 0.01 {
                            gameState.sendMapAction(.setScale(meters: newScale))
                        }
                    }
                ),
                scaleCount: AppConstants.UI.RadarScale.discreteScales.count,
                focusTrigger: $crownFocusTrigger,
                onTap: { crownFocusTrigger += 1 }
            )
        )
        #endif
        .navigationTitle("Radar")
        #if os(watchOS) || os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showingSettingsSheet) {
            NavigationStack {
                SettingsView()
                    .environmentObject(gameState)
            }
        }
        .sheet(isPresented: $showingIndicatorMenuSheet) {
            TacticalIndicatorMenuView()
                .environmentObject(gameState)
        }
        .sheet(isPresented: $showingPaywallSheet) {
            NavigationStack {
                PaywallView()
                    .environmentObject(gameState)
            }
        }
        .onChange(of: gameState.selectedPresentation) { _, newPresentation in
            if newPresentation == .radar {
                snapScaleToRadarLadder()
            }
        }
        .onChange(of: gameState.showIndicatorMenuSheet) { _, isShowing in
            if isShowing {
                showingIndicatorMenuSheet = true
            } else {
                showingIndicatorMenuSheet = false
            }
        }
        .onChange(of: showingIndicatorMenuSheet) { _, isShowing in
            if !isShowing && gameState.showIndicatorMenuSheet {
                DispatchQueue.main.async {
                    gameState.showIndicatorMenuSheet = false
                }
            }
        }
        .onChange(of: gameState.showPaywallSheet) { _, isShowing in
            if isShowing {
                showingPaywallSheet = true
            } else {
                showingPaywallSheet = false
            }
        }
        .onChange(of: showingPaywallSheet) { _, isShowing in
            if !isShowing && gameState.showPaywallSheet {
                DispatchQueue.main.async {
                    gameState.showPaywallSheet = false
                }
            }
        }
        #if os(watchOS)
        .onChange(of: showingSettingsSheet) { _, isShowing in
            if !isShowing { crownFocusTrigger += 1 }
        }
        .onChange(of: showingIndicatorMenuSheet) { _, isShowing in
            if !isShowing { crownFocusTrigger += 1 }
        }
        .onChange(of: showingPaywallSheet) { _, isShowing in
            if !isShowing { crownFocusTrigger += 1 }
        }
        #endif
        .onChange(of: gameState.selectedPresentation) { _, newPresentation in
            if newPresentation == .radar {
                heartRateTouchDate = Date()
            }
        }
        .onAppear {
            heartRateTouchDate = Date()
            #if os(watchOS)
            crownFocusTrigger += 1
            #endif
            DispatchQueue.main.async {
                gameState.locationHeadingManager.requestPermissions()
                gameState.locationHeadingManager.startUpdates()
            }
        }
    }
    
    // MARK: - Hold-to-Act (KIA / Revive) Gesture Handling
    
    private func startActionHold() {
        guard !isHoldingActionButton, !actionCompletedForCurrentTouch else { return }
        isHoldingActionButton = true
        actionProgress = 0.0
        
        withAnimation(.linear(duration: AppConstants.UI.Gestures.actionHoldDurationSeconds)) {
            actionProgress = 1.0
        }
        
        holdTimer?.invalidate()
        let timer = Timer(timeInterval: AppConstants.UI.Gestures.actionHoldDurationSeconds, repeats: false) { _ in
            triggerAction()
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }
    
    private func cancelActionHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        actionCompletedForCurrentTouch = false
        withAnimation(.easeOut(duration: 0.15)) {
            isHoldingActionButton = false
            actionProgress = 0.0
        }
        #if os(watchOS)
        crownFocusTrigger += 1
        #endif
    }
    
    private func triggerAction() {
        holdTimer?.invalidate()
        holdTimer = nil
        isHoldingActionButton = false
        actionCompletedForCurrentTouch = true
        actionProgress = 0.0
        
        withAnimation(.easeInOut(duration: AppConstants.UI.Gestures.actionAnimationDurationSeconds)) {
            gameState.setDead(!gameState.isDead)
        }
        #if os(watchOS)
        crownFocusTrigger += 1
        #endif
    }
    
    private func centerMapToUser() {
        gameState.centerMapOnLocalUser()
        #if os(watchOS)
        crownFocusTrigger += 1
        #endif
    }
    
    private func togglePresentation() {
        gameState.togglePresentation()
        #if os(watchOS)
        crownFocusTrigger += 1
        #endif
    }
}
