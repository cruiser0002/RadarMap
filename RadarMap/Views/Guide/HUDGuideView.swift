import SwiftUI

// MARK: - Tactical HUD Guide Screen
public struct HUDGuideView: View {
    @EnvironmentObject var gameState: GameStateManager
    @State private var selectedCallout: TacticalHUDCallout? = .tacticalCommands
    
    private let tacticalGreen = Color(red: 0.15, green: 0.95, blue: 0.35)
    
    public init() {}
    
    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header Section
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(tacticalGreen)
                            .frame(width: 8, height: 8)
                            .shadow(color: tacticalGreen.opacity(0.8), radius: 4)
                        
                        Text("TACTICAL HUD GUIDE")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(tacticalGreen)
                            .tracking(1.5)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(tacticalGreen.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(tacticalGreen.opacity(0.35), lineWidth: 1))
                    
                    Text("Tactical HUD")
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .foregroundStyle(.primary)
                    
                    Text("Interactive controls guide & display overview")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 12)
                
                // Visual Guide / Clean Watch Display
                VStack(spacing: 0) {
                    Image("WatchGuideDiagram")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 36, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [Color(white: 0.4), Color(white: 0.15), Color(white: 0.3)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 3
                                )
                        )
                        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
                        .padding(.vertical, 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color.gray.opacity(0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24)
                                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                        )
                )
                .padding(.horizontal)
                
                // Active Callout Feature Card
                if let active = selectedCallout {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            HStack(spacing: 6) {
                                Image(systemName: active.iconName)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(tacticalGreen)
                                
                                Text(active.shortTitle)
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                    .foregroundStyle(.primary)
                            }
                            
                            Spacer()
                            
                            HStack(spacing: 6) {
                                Text(active.gestureHint)
                                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                                    .foregroundStyle(active == .heartRate ? Color.orange : tacticalGreen)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background((active == .heartRate ? Color.orange : tacticalGreen).opacity(0.15), in: Capsule())
                                
                                Text(active.codeTag)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        
                        Text(active.actionInstruction)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.gray.opacity(0.2))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(tacticalGreen.opacity(0.4), lineWidth: 1.5)
                            )
                    )
                    .padding(.horizontal)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
                
                // Quick Reference Grid
                VStack(alignment: .leading, spacing: 14) {
                    Text("QUICK CONTROLS DIRECTORY")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                    
                    ForEach(TacticalHUDCallout.allCases) { item in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                selectedCallout = item
                            }
                        } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(selectedCallout == item ? tacticalGreen.opacity(0.2) : Color.primary.opacity(0.05))
                                        .frame(width: 38, height: 38)
                                    
                                    Image(systemName: item.iconName)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(selectedCallout == item ? tacticalGreen : .primary)
                                }
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(item.shortTitle)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.primary)
                                        
                                        Spacer()
                                        
                                        Text(item.gestureHint)
                                            .font(.system(size: 9, weight: .heavy, design: .monospaced))
                                            .foregroundStyle(item == .heartRate ? Color.orange : .secondary)
                                    }
                                    
                                    Text(item.actionInstruction)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(selectedCallout == item ? Color.gray.opacity(0.25) : Color.gray.opacity(0.12))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14)
                                            .stroke(selectedCallout == item ? tacticalGreen.opacity(0.5) : Color.clear, lineWidth: 1)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("HUD Guide")
        #if os(watchOS) || os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
