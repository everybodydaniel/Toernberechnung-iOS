import SwiftUI

enum NautiDashboardMode: Equatable {
    case dashboard
    case chat
    case history

    var isExpanded: Bool { self != .dashboard }
}

enum NautiDashboardGeometry {
    /// Der Bereich wird an seinen Grenzen abgeschnitten und darf deshalb nicht
    /// höher sein als der verfügbare Platz über `bottomInset`. Sonst würde
    /// die Tastatur die Chat-Eingabe am unteren Rand verdecken.
    static func panelHeight(availableHeight: CGFloat, bottomInset: CGFloat = 0) -> CGFloat {
        let ideal = min(max(availableHeight * 0.56, 380), 520)
        // `headerClearance` hält AppHeader oberhalb des Bereichs sichtbar.
        // Ohne diesen Abstand könnte die Mindesthöhe von 380 pt den verfügbaren
        // Platz bei geöffneter Tastatur auf kleinen Geräten überschreiten.
        let headerClearance: CGFloat = 76
        return max(min(ideal, availableHeight - bottomInset - headerClearance), 220)
    }

    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.18)
            : .spring(response: 0.4, dampingFraction: 0.75)
    }
}

/// Inhalt direkt in der gemeinsamen dunkelgrauen Glasfläche des Kartenbereichs.
/// Diese Ansicht fügt keinen eigenen Material- oder Glashintergrund hinzu.
struct NautiInlineDashboardHost: View {
    @Binding var mode: NautiDashboardMode
    @Bindable var viewModel: NautiChatViewModel

    let focusDismissTrigger: Int
    let onCollapse: () -> Void
    let onAction: (NautiActionDispatch) -> Void
    let onPayloadAction: (NautiChatPayload) -> Void
    let accessState: AIAccessState
    let onRetryAvailability: () -> Void

    var body: some View {
        NautiPremiumChatOverlay(
            mode: $mode,
            viewModel: viewModel,
            focusDismissTrigger: focusDismissTrigger,
            onCollapse: onCollapse,
            onAction: onAction,
            onPayloadAction: onPayloadAction,
            accessState: accessState,
            onRetryAvailability: onRetryAvailability
        )
        .foregroundStyle(Color.primary)
        .tint(Color.appPrimary)
    }
}
