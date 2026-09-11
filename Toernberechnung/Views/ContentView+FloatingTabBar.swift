import SwiftUI

struct FloatingAppTabBar: View {
    @Binding var selection: AppTab
    var showsLabels = false

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                FloatingAppTabButton(
                    tab: tab,
                    isSelected: selection == tab,
                    showsLabel: showsLabels,
                    action: {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            selection = tab
                        }
                    }
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: showsLabels ? 480 : 390)
        .floatingTabBarSurface()
        .shadow(color: .black.opacity(0.18), radius: 22, y: 12)
        .accessibilityElement(children: .contain)
    }
}

private struct FloatingAppTabButton: View {
    let tab: AppTab
    let isSelected: Bool
    let showsLabel: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if showsLabel {
                VStack(spacing: 4) {
                    Image(systemName: tab.icon)
                        .font(.system(size: 19, weight: .semibold))
                        .frame(height: 26)
                    Text(tab.label)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(height: 16)
                }
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 58)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Color(hex: 0x0077B6).opacity(0.85))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.28), lineWidth: 0.5))
                    }
                }
                .contentShape(Capsule())
            } else {
                Image(systemName: tab.icon)
                    .font(.system(size: isSelected ? 19 : 18, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.88))
                    .frame(width: isSelected ? 58 : 48, height: isSelected ? 58 : 48)
                    .background {
                        if isSelected {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color(hex: 0x38BDF8), Color(hex: 0x0077B6)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .overlay(Circle().stroke(Color.white.opacity(0.30), lineWidth: 0.8))
                                .shadow(color: Color(hex: 0x0077B6).opacity(0.38), radius: 12, y: 7)
                        } else {
                            Circle()
                                .fill(Color.white.opacity(0.001))
                        }
                    }
                    .contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private extension View {
    @ViewBuilder
    func floatingTabBarSurface() -> some View {
        let shape = Capsule(style: .continuous)
        if #available(iOS 26.0, *) {
            self
                .glassEffect(.regular, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .background(Color(hex: 0x5E7077).opacity(0.48), in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.28), lineWidth: 0.8))
        }
    }
}
