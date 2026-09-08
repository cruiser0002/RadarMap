import SwiftUI
#if os(iOS)
import UIKit
#elseif os(watchOS)
import WatchKit
#endif

public struct RoleSliderView: View {
    @Binding public var selectedRole: MemberRole
    public var isProUnlocked: Bool
    public var isDisabled: Bool
    public var themeColor: Color

    @State private var dragOffset: CGFloat? = nil

    private let ranks: [MemberRole] = MemberRole.allRanksOrdered

    public init(
        selectedRole: Binding<MemberRole>,
        isProUnlocked: Bool,
        isDisabled: Bool = false,
        themeColor: Color = .green
    ) {
        self._selectedRole = selectedRole
        self.isProUnlocked = isProUnlocked
        self.isDisabled = isDisabled
        self.themeColor = themeColor
    }

    private var selectedIndex: Int {
        ranks.firstIndex(of: selectedRole) ?? 0
    }

    private func isRankUnlocked(_ role: MemberRole) -> Bool {
        if role.isProRequired {
            return isProUnlocked
        }
        return true
    }

    private func triggerHaptic() {
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        #elseif os(watchOS)
        WKInterfaceDevice.current().play(.click)
        #endif
    }

    private func selectRank(at index: Int) {
        guard index >= 0 && index < ranks.count else { return }
        let targetRole = ranks[index]
        // Free tier is only allowed unlocked ranks (e.g. Player). Silently ignore locked ranks.
        guard isRankUnlocked(targetRole) else { return }
        if targetRole != selectedRole {
            selectedRole = targetRole
            triggerHaptic()
        }
    }

    public var body: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width
            let thumbRadius: CGFloat = 8
            let horizontalPadding: CGFloat = 16
            let usableWidth = max(1, totalWidth - 2 * horizontalPadding)
            let count = ranks.count

            let xForIndex: (Int) -> CGFloat = { idx in
                if count <= 1 { return totalWidth / 2 }
                return horizontalPadding + usableWidth * CGFloat(idx) / CGFloat(count - 1)
            }

            let currentThumbX: CGFloat = {
                if let drag = dragOffset {
                    return min(max(horizontalPadding, drag), totalWidth - horizontalPadding)
                }
                return xForIndex(selectedIndex)
            }()

            ZStack(alignment: .topLeading) {
                // Base rail line
                Path { path in
                    path.move(to: CGPoint(x: horizontalPadding, y: 12))
                    path.addLine(to: CGPoint(x: totalWidth - horizontalPadding, y: 12))
                }
                .stroke(Color.gray.opacity(0.35), lineWidth: 2)

                // Active highlight track
                Path { path in
                    path.move(to: CGPoint(x: horizontalPadding, y: 12))
                    path.addLine(to: CGPoint(x: currentThumbX, y: 12))
                }
                .stroke(themeColor.opacity(0.8), lineWidth: 2)

                // Vertical tick marks & labels under marks
                ForEach(0..<count, id: \.self) { idx in
                    let role = ranks[idx]
                    let tickX = xForIndex(idx)
                    let isUnlocked = isRankUnlocked(role)
                    let isCurrent = (idx == selectedIndex)

                    // Vertical tick mark
                    Rectangle()
                        .fill(isCurrent ? themeColor : (isUnlocked ? Color.gray.opacity(0.7) : Color.gray.opacity(0.3)))
                        .frame(width: 2, height: 10)
                        .position(x: tickX, y: 12)

                    // Label under the mark
                    VStack(spacing: 2) {
                        HStack(spacing: 2) {
                            if !isUnlocked {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 7))
                                    .foregroundColor(.gray.opacity(0.6))
                            }
                            Text(role.displayName)
                                .font(.system(size: 8, weight: isCurrent ? .bold : .medium, design: .monospaced))
                                .foregroundColor(isCurrent ? themeColor : (isUnlocked ? .primary : .gray.opacity(0.5)))
                                .lineLimit(1)
                        }
                    }
                    .frame(width: max(40, usableWidth / CGFloat(max(1, count))), alignment: .center)
                    .position(x: tickX, y: 30)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !isDisabled else { return }
                        selectRank(at: idx)
                    }
                }

                // Draggable Slider Thumb
                Circle()
                    .fill(themeColor)
                    .frame(width: thumbRadius * 2, height: thumbRadius * 2)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                    )
                    .shadow(color: themeColor.opacity(0.5), radius: 3, x: 0, y: 1)
                    .position(x: currentThumbX, y: 12)
            }
            .contentShape(Rectangle())
            .gesture(
                isDisabled ? nil :
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let clampedX = min(max(horizontalPadding, value.location.x), totalWidth - horizontalPadding)
                        let fraction = (clampedX - horizontalPadding) / usableWidth
                        let nearestIndex = Int(round(fraction * CGFloat(count - 1)))
                        let targetRole = ranks[min(max(0, nearestIndex), count - 1)]

                        if isRankUnlocked(targetRole) {
                            dragOffset = clampedX
                        } else {
                            // Clamp drag visual to highest allowed mark without nagging
                            let maxAllowedIndex = ranks.lastIndex(where: { isRankUnlocked($0) }) ?? 0
                            dragOffset = xForIndex(maxAllowedIndex)
                        }
                    }
                    .onEnded { value in
                        let clampedX = min(max(horizontalPadding, value.location.x), totalWidth - horizontalPadding)
                        let fraction = (clampedX - horizontalPadding) / usableWidth
                        let rawIndex = Int(round(fraction * CGFloat(count - 1)))
                        let clampedIndex = min(max(0, rawIndex), count - 1)
                        let targetRole = ranks[clampedIndex]

                        if isRankUnlocked(targetRole) {
                            selectRank(at: clampedIndex)
                        } else {
                            // Revert/snap back to allowed mark silently
                            let maxAllowedIndex = ranks.lastIndex(where: { isRankUnlocked($0) }) ?? 0
                            selectRank(at: maxAllowedIndex)
                        }
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                            dragOffset = nil
                        }
                    }
            )
        }
        .frame(height: 44)
        .padding(.vertical, 4)
        .opacity(isDisabled ? 0.6 : 1.0)
    }
}
