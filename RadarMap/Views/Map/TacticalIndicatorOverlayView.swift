import SwiftUI
import CoreLocation

// MARK: - Tactical Indicator Icon Component

public struct TacticalIndicatorIcon: View {
    public let type: TacticalIndicatorType
    public let size: CGFloat
    
    public init(type: TacticalIndicatorType, size: CGFloat = 16) {
        self.type = type
        self.size = size
    }
    
    public var body: some View {
        type.iconImage
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}

// MARK: - Tactical Indicator Marker View (with Hold-to-Delete countdown)

public struct TacticalIndicatorOverlayView: View {
    public let indicator: TacticalIndicator
    public let radarColor: Color
    public let onDelete: () -> Void
    public let onTap: (() -> Void)?

    @State private var isHolding: Bool = false
    @State private var holdProgress: Double = 0.0
    @State private var holdTimer: Timer? = nil
    @State private var holdStartTime: Date? = nil
    @State private var didTriggerDelete: Bool = false

    public init(
        indicator: TacticalIndicator,
        radarColor: Color,
        onDelete: @escaping () -> Void,
        onTap: (() -> Void)? = nil
    ) {
        self.indicator = indicator
        self.radarColor = radarColor
        self.onDelete = onDelete
        self.onTap = onTap
    }
    
    /// Calculate color taking into account the 5-minute fade to gray rule for enemy indicators
    private func markerColor(fadeFactor: Double) -> Color {
        if indicator.category == .enemyIndicator {
            if fadeFactor >= 1.0 {
                return Color.gray.opacity(0.85)
            } else if fadeFactor > 0.0 {
                // Blend radar theme color towards gray
                return radarColor.opacity(1.0 - (fadeFactor * 0.5))
            }
        }
        return radarColor
    }
    
    public var body: some View {
        let markers = AppConstants.UI.MapMarkers.self
        let iconSize: CGFloat = markers.tacticalIndicatorIconSize
        let ringSize: CGFloat = markers.tacticalIndicatorRingSize
        let touchTargetSize: CGFloat = ringSize
        let fadeFactor = indicator.grayFadeFactor()
        // Use the raw radar color for the cache key so it stays stable across the 5-min fade.
        // The grayscale desaturation is applied as a GPU-side modifier on the returned Image,
        // which is cheaper and doesn't defeat the sprite cache.
        let color = markerColor(fadeFactor: fadeFactor)   // used only for the label overlay below
        
        ZStack {
            // Delete countdown progress ring only visible during hold
            if holdProgress > 0 {
                Circle()
                    .trim(from: 0, to: CGFloat(holdProgress))
                    .stroke(
                        Color.red.opacity(0.95),
                        style: StrokeStyle(lineWidth: 2.0, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: ringSize, height: ringSize)
            }
            
            // Center Tactical Indicator Icon (Pre-rendered Hardware GPU Texture)
            // Cache key uses `radarColor` (stable) — grayscale fade handled by GPU modifier below.
            TacticalSpriteCache.shared.indicatorSprite(type: indicator.type, color: radarColor, size: iconSize)
                .grayscale(indicator.category == .enemyIndicator ? fadeFactor : 0.0)
        }
        .frame(width: touchTargetSize, height: touchTargetSize)
        .contentShape(Circle())
        .overlay(alignment: .top) {
            if indicator.category == .squadOrder,
               let callsign = indicator.placedByCallsign?.trimmingCharacters(in: .whitespacesAndNewlines),
               !callsign.isEmpty {
                Text(callsign)
                    .font(.system(size: markers.callsignFontSize, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
                    .lineLimit(1)
                    .padding(.horizontal, 3.0)
                    .padding(.vertical, 1.0)
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(3)
                    .fixedSize()
                    .offset(y: markers.orderCallsignYOffset)
            }
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    startHold()
                }
                .onEnded { _ in
                    let wasDeleting = didTriggerDelete
                    didTriggerDelete = false
                    cancelHold()
                    if !wasDeleting {
                        onTap?()
                    }
                }
        )
        .onDisappear {
            cancelHold()
        }
    }
    
    private func startHold() {
        guard !isHolding else { return }
        isHolding = true
        holdStartTime = Date()
        holdProgress = 0.0
        
        holdTimer?.invalidate()
        let duration = AppConstants.Subscription.indicatorHoldToDeleteDurationSeconds
        let timer = Timer(timeInterval: AppConstants.UI.Gestures.holdTimerTickIntervalSeconds, repeats: true) { _ in
            guard let start = holdStartTime else { return }
            let elapsed = Date().timeIntervalSince(start)
            let progress = min(1.0, elapsed / duration)
            
            withAnimation(.linear(duration: AppConstants.UI.Gestures.holdTimerTickIntervalSeconds)) {
                holdProgress = progress
            }
            
            if progress >= 1.0 {
                completeDeletion()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }
    
    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        holdStartTime = nil
        withAnimation(.easeOut(duration: 0.2)) {
            isHolding = false
            holdProgress = 0.0
        }
    }
    
    private func completeDeletion() {
        holdTimer?.invalidate()
        holdTimer = nil
        holdStartTime = nil
        isHolding = false
        holdProgress = 0.0
        didTriggerDelete = true
        onDelete()
    }
}
