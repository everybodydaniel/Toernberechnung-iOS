import SwiftUI

enum NautiDashboardMode: Equatable {
    case dashboard
    case chat
    case history

    var isExpanded: Bool { self != .dashboard }
}

enum NautiDashboardGeometry {
    /// The panel is hard-clipped, so it must never be taller than what is
    /// actually left above `bottomInset` — otherwise the chat input at its
    /// bottom edge gets cut off once the keyboard shrinks the container.
    static func panelHeight(availableHeight: CGFloat, bottomInset: CGFloat = 0) -> CGFloat {
        let ideal = min(max(availableHeight * 0.56, 380), 520)
        // `headerClearance` keeps the AppHeader visible above the panel; without
        // it the 380pt floor can exceed what is left once the keyboard shrinks
        // the container on smaller devices.
        let headerClearance: CGFloat = 76
        return max(min(ideal, availableHeight - bottomInset - headerClearance), 220)
    }

    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.18)
            : .spring(response: 0.4, dampingFraction: 0.75)
    }
}

/// Content hosted directly inside the map dashboard's single graphite Glass
/// surface. This view deliberately adds no material or Glass of its own.
struct NautiInlineDashboardHost: View {
    @Binding var mode: NautiDashboardMode
    @Bindable var viewModel: NautiChatViewModel
    @Bindable var speechController: NautiSpeechInputController

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
            speechController: speechController,
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
