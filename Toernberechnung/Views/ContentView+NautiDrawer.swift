import SwiftUI

enum NautiDashboardMode: Equatable {
    case dashboard
    case chat
    case history

    var isExpanded: Bool { self != .dashboard }
}

enum NautiDashboardGeometry {
    static func panelHeight(availableHeight: CGFloat) -> CGFloat {
        min(max(availableHeight * 0.56, 380), 520)
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
