import SwiftUI

public struct MemberAnnotationView: View {
    public let member: SquadMember
    public let isMe: Bool
    public let isSameClan: Bool
    public let isSelected: Bool
    public let radarColor: Color
    public let onTap: (() -> Void)?

    public init(
        member: SquadMember,
        isMe: Bool = false,
        isSameClan: Bool = false,
        isSelected: Bool = false,
        radarColor: Color = .green,
        onTap: (() -> Void)? = nil
    ) {
        self.member = member
        self.isMe = isMe
        self.isSameClan = isSameClan
        self.isSelected = isSelected
        self.radarColor = radarColor
        self.onTap = onTap
    }
    
    /// Determines whether the player is considered KIA / Downed
    private var isKIA: Bool {
        member.status == .downed
    }
    
    /// Indicator theme color based on state, self-status, clan affiliation, or staleness:
    /// - Local player ("Me") is green.
    /// - Players in the same clan as me are green (or gray when stale).
    /// - Other teammates are blue (or gray when stale).
    public var indicatorColor: Color {
        if isMe {
            return .green
        }
        if member.isStale {
            return .gray
        }
        return isSameClan ? .green : .blue
    }
    
    public var body: some View {
        let markers = AppConstants.UI.MapMarkers.self
        let scale: CGFloat = isMe ? 1.0 : markers.otherPlayerScaleFactor
        let scaledFrameSize = markers.markerFrameSize * scale

        // Tactical Vector Marker (center is the exact coordinate and breathing circle center)
        ZStack {
            if isKIA {
                // KIA / Downed Marker ("X" shape)
                SquadDeadXShape()
                    .fill(indicatorColor)
                    .overlay(
                        SquadDeadXShape()
                            .stroke(Color.black.opacity(0.8), lineWidth: 1.2)
                    )
                    .shadow(color: .black.opacity(0.7), radius: 2)
                    .frame(width: markers.deadXIconSize, height: markers.deadXIconSize)
            } else {
                // Live Squad Indicator (SL vs Teammate Player)
                switch member.role {
                case .leader:
                    // Squad Leader (SL) Icon
                    ZStack {
                        SquadLeaderShape()
                            .fill(indicatorColor)
                            .overlay(
                                SquadLeaderShape()
                                    .stroke(Color.black.opacity(0.8), lineWidth: 1.2)
                            )
                            .shadow(color: .black.opacity(0.7), radius: 2)
                            .frame(width: markers.leaderIconSize, height: markers.leaderIconSize)
                            .rotationEffect(.degrees(member.heading))
                        
                        // Central heart-rate pulse core
                        SquadPulseCore(heartRate: member.heartRate, tintColor: indicatorColor)
                            .frame(width: markers.pulseCoreSize, height: markers.pulseCoreSize)
                    }
                    .frame(width: markers.markerFrameSize, height: markers.markerFrameSize)
                default: // .player, and any future role without a dedicated icon yet
                    // Regular Squad Player Icon
                    ZStack {
                        SquadPlayerShape()
                            .fill(indicatorColor)
                            .overlay(
                                SquadPlayerShape()
                                    .stroke(Color.black.opacity(0.8), lineWidth: 1.2)
                            )
                            .shadow(color: .black.opacity(0.7), radius: 2)
                            .frame(width: markers.playerIconSize, height: markers.playerIconSize)
                            .rotationEffect(.degrees(member.heading))
                        
                        // Central heart-rate pulse core
                        SquadPulseCore(heartRate: member.heartRate, tintColor: indicatorColor)
                            .frame(width: markers.pulseCoreSize, height: markers.pulseCoreSize)
                    }
                    .frame(width: markers.markerFrameSize, height: markers.markerFrameSize)
                }
            }
        }
        .frame(width: markers.markerFrameSize, height: markers.markerFrameSize)
        .overlay(alignment: .top) {
            if isSelected {
                let cleanCallsign = member.callsign.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanCallsign.isEmpty {
                    // Callsign directly under the icon without altering the view center anchor, activated when selected as distance ruler target
                    Text(cleanCallsign)
                        .font(.system(size: markers.callsignFontSize, weight: .bold, design: .monospaced))
                        .foregroundColor(indicatorColor)
                        .lineLimit(1)
                        .padding(.horizontal, 3.0)
                        .padding(.vertical, 1.0)
                        .background(Color.black.opacity(0.85))
                        .cornerRadius(3)
                        .fixedSize()
                        .offset(y: markers.callsignYOffset)
                }
            }
        }
        .scaleEffect(scale)
        .frame(width: scaledFrameSize, height: scaledFrameSize)
        .contentShape(Rectangle().inset(by: (isMe || isSameClan) ? -markers.greenTouchTargetPadding : 0))
        .onTapGesture { onTap?() }
    }
}
