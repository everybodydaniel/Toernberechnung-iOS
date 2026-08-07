import SwiftUI

/// The assistant is intentionally a contextual presence rather than a fixed
/// action button. In the normal state it is quiet; concrete safety issues
/// expand it into an immediately actionable recommendation.
struct NautiPresenceBubble: View {
    let issue: NautiProactiveIssue?
    let onOpenChat: () -> Void
    let onPrimaryAction: (NautiProactiveAction) -> Void
    let onSecondaryAction: (NautiProactiveAction) -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let issue {
                issueBubble(issue)
            } else {
                standardBubble
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.84), value: issue?.id)
    }

    private var standardBubble: some View {
        Button(action: onOpenChat) {
            HStack(spacing: 10) {
                NautiSymbolAvatar()
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nauti")
                        .font(.system(size: 15, weight: .heavy))
                    Text("Törn, Wetter oder Gezeiten")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: 0x0077B6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .appFloatingOverlay(cornerRadius: 26, tint: Color(hex: 0x14B8A6).opacity(0.16))
        .accessibilityLabel("Nauti Chat öffnen")
    }

    private func issueBubble(_ issue: NautiProactiveIssue) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: issue.icon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(accentColor(for: issue.accent), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("Nauti hat etwas erkannt")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(Color.secondary)
                    Text(issue.title)
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(Color.appPrimary)
                }

                Spacer(minLength: 0)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.2), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Nauti Hinweis schließen")
            }

            Text(issue.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(issue.primaryAction.title) {
                    onPrimaryAction(issue.primaryAction)
                }
                .appGlassButton(tint: accentColor(for: issue.accent))

                Button(issue.secondaryAction.title) {
                    onSecondaryAction(issue.secondaryAction)
                }
                .appGlassButton(tint: Color.appPrimary)
            }

            Button("Mit Nauti besprechen", action: onOpenChat)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(accentColor(for: issue.accent))
        }
        .padding(14)
        .frame(maxWidth: 360, alignment: .leading)
        .appFloatingOverlay(cornerRadius: 28, tint: accentColor(for: issue.accent).opacity(0.18))
        .accessibilityElement(children: .contain)
    }

    private func accentColor(for accent: NautiProactiveAccent) -> Color {
        switch accent {
        case .cyan: return Color(hex: 0x0891B2)
        case .amber: return Color(hex: 0xD97706)
        case .red: return Color(hex: 0xDC2626)
        }
    }
}

struct NautiChatOverlay: View {
    @Bindable var viewModel: NautiChatViewModel

    let onClose: () -> Void
    let onAction: (NautiActionDispatch) -> Void
    let accessState: AIAccessState
    let onRetryAvailability: () -> Void

    @FocusState private var inputFocused: Bool

    var body: some View {
        chatPanel
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .appSheetBackground {
                Color.appBackground.ignoresSafeArea()
            }
    }

    private var chatPanel: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            transcript
            inputBar
        }
        .onAppear {
            inputFocused = accessState.canUseAssistant
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            NautiSymbolAvatar()
                .frame(width: 42, height: 42)
                .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text("Nauti")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(Color.appPrimary)
                Text("Skipper-KI")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.secondary)
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 34, height: 34)
                    .background(Color.fieldBackground, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Nauti Chat schliessen")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if !accessState.canUseAssistant {
                        NautiAccessNotice(
                            state: accessState,
                            onRetryAvailability: onRetryAvailability
                        )
                    }

                    ForEach(viewModel.messages) { message in
                        NautiMessageBubble(message: message)
                            .id(message.id)
                    }

                    if viewModel.isSending {
                        NautiTypingBubble()
                            .id("typing")
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: viewModel.isSending) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Nachricht", text: $viewModel.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.fieldBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .disabled(!accessState.canUseAssistant)

            Button(action: send) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        LinearGradient(
                            colors: [Color(hex: 0x0077B6), Color(hex: 0x14B8A6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canSend || !accessState.canUseAssistant)
            .opacity(viewModel.canSend && accessState.canUseAssistant ? 1 : 0.45)
            .accessibilityLabel("Senden")
        }
        .padding(12)
        .background(Color.cardBackground.opacity(0.72))
    }

    private func send() {
        guard viewModel.canSend, accessState.canUseAssistant else { return }
        Task {
            if let dispatch = await viewModel.sendCurrentDraft(when: accessState) {
                onAction(dispatch)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.22)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }
}

struct NautiActionConfirmationSheet: View {
    let pendingAction: NautiPendingAction
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Color(hex: 0x0891B2))
                    .frame(width: 58, height: 58)
                    .background(Color(hex: 0x0891B2).opacity(0.12), in: Circle())

                Text(pendingAction.title)
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(Color.appPrimary)

                Text(pendingAction.message)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Button(pendingAction.confirmTitle, action: onConfirm)
                    .appProminentButton(tint: Color(hex: 0x0077B6))

                Button("Abbrechen", action: onCancel)
                    .appGlassButton(tint: Color.appPrimary)
            }
            .padding(24)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct NautiAccessNotice: View {
    let state: AIAccessState
    let onRetryAvailability: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: state.noticeIcon)
                .foregroundStyle(Color(hex: 0xD97706))

            VStack(alignment: .leading, spacing: 8) {
                Text(state.noticeMessage ?? "Nauti ist momentan nicht verfügbar.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.secondary)

                if state != .locked {
                    Button("Erneut prüfen", action: onRetryAvailability)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(hex: 0x0077B6))
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(Color(hex: 0xD97706).opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct NautiMessageBubble: View {
    let message: NautiChatMessage
    let onPayloadAction: ((NautiChatPayload) -> Void)?

    init(
        message: NautiChatMessage,
        onPayloadAction: ((NautiChatPayload) -> Void)? = nil
    ) {
        self.message = message
        self.onPayloadAction = onPayloadAction
    }

    private var isUser: Bool {
        message.role == .user
    }

    var body: some View {
        if isUser {
            VStack(alignment: .trailing, spacing: 3) {
                Text("DU")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color.secondary)
                Text(message.text)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 46)
        } else {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "sailboat.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.cyan)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text("NAUTI")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Color.secondary)

                    assistantContentContainer
                        .frame(maxWidth: 620, alignment: .leading)
                }

                Spacer(minLength: 24)
            }
        }
    }

    @ViewBuilder
    private var assistantContentContainer: some View {
        if let payload = message.payload, let onPayloadAction {
            Button {
                onPayloadAction(payload)
            } label: {
                assistantContent
            }
            .buttonStyle(.plain)
            .accessibilityHint("Öffnet die Daten im Revier-Tab")
        } else {
            assistantContent
        }
    }

    @ViewBuilder
    private var assistantContent: some View {
        if case let .weather(card)? = message.payload {
            NautiWeatherCardView(card: card)
        } else if case let .tide(card)? = message.payload {
            NautiTideCardView(card: card)
        } else {
            Text(message.text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct NautiTideCardView: View {
    let card: NautiTideCard

    private var nextEvent: NautiTideCardEvent? {
        card.events.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "water.waves")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.cyan)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(card.harbourName)
                        .font(.system(size: 18, weight: .heavy))
                    Text(card.dayTitle)
                        .font(.system(size: 12, weight: .bold))
                        .opacity(0.78)
                    Text(card.stationName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .opacity(0.78)
                }

                Spacer(minLength: 0)
            }

            if let nextEvent {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(nextEvent.type)
                        .font(.system(size: 28, weight: .heavy))
                    Text(nextEvent.timeLabel)
                        .font(.system(size: 28, weight: .heavy))
                    Text(nextEvent.heightText)
                        .font(.system(size: 15, weight: .bold))
                        .opacity(0.84)
                }
            }

            NautiTideCurve(events: card.events)
                .frame(height: 72)
                .padding(.vertical, 4)

            VStack(spacing: 7) {
                ForEach(card.events) { event in
                    HStack(spacing: 9) {
                        Image(systemName: event.isHighWater ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(event.isHighWater ? Color.cyan : Color.teal)

                        Text(event.type)
                            .font(.system(size: 12, weight: .heavy))
                            .frame(width: 28, alignment: .leading)

                        Text(event.timeLabel)
                            .font(.system(size: 14, weight: .heavy))

                        Spacer()

                        Text(event.heightText)
                            .font(.system(size: 13, weight: .bold))
                            .opacity(0.86)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                }
            }

            Label("Im Revier öffnen", systemImage: "arrow.up.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.cyan)
        }
        .foregroundStyle(.primary)
        .padding(.leading, 12)
        .padding(.vertical, 4)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.cyan.opacity(0.75))
                .frame(width: 2)
        }
    }
}

private struct NautiTideCurve: View {
    let events: [NautiTideCardEvent]

    var body: some View {
        GeometryReader { proxy in
            let points = curvePoints(in: proxy.size)
            ZStack {
                if points.count > 1 {
                    Path { path in
                        path.move(to: points[0])
                        for index in points.indices.dropFirst() {
                            path.addLine(to: points[index])
                        }
                    }
                    .stroke(Color.cyan.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }

                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    Circle()
                        .fill(events[index].isHighWater ? Color.cyan : Color.teal)
                        .frame(width: 7, height: 7)
                        .position(point)
                }
            }
        }
    }

    private func curvePoints(in size: CGSize) -> [CGPoint] {
        guard !events.isEmpty else { return [] }
        let heights = events.map { $0.heightMeters ?? 0 }
        let minHeight = heights.min() ?? 0
        let maxHeight = heights.max() ?? 1
        let range = max(maxHeight - minHeight, 0.1)
        let horizontalPadding: CGFloat = 16
        let verticalPadding: CGFloat = 14
        let usableWidth = max(size.width - horizontalPadding * 2, 1)
        let usableHeight = max(size.height - verticalPadding * 2, 1)

        return events.enumerated().map { index, event in
            let xFraction = events.count == 1 ? 0.5 : CGFloat(index) / CGFloat(events.count - 1)
            let height = event.heightMeters ?? minHeight
            let yFraction = CGFloat((height - minHeight) / range)
            return CGPoint(
                x: horizontalPadding + usableWidth * xFraction,
                y: verticalPadding + usableHeight * (1 - yFraction)
            )
        }
    }
}

private struct NautiWeatherCardView: View {
    let card: NautiWeatherCard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: weatherSymbol(card.icon))
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(Color.cyan)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(card.harbourName)
                        .font(.system(size: 18, weight: .heavy))
                    Text(card.dayTitle)
                        .font(.system(size: 12, weight: .bold))
                        .opacity(0.78)
                    Text(card.condition)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int(card.minTemperatureC.rounded()))-\(Int(card.maxTemperatureC.rounded()))")
                    .font(.system(size: 34, weight: .heavy))
                Text("°C")
                    .font(.system(size: 18, weight: .heavy))
                    .opacity(0.84)
            }

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ], spacing: 8) {
                metric("Wind", "\(Int(card.maxWindKnots.rounded())) kn", "wind")
                metric("Böen", card.maxGustKnots.map { "\(Int($0.rounded())) kn" } ?? "-", "tornado")
                metric("Regen", "\(card.precipitationChance)%", "cloud.rain")
            }

            if !card.slots.isEmpty {
                HStack(spacing: 8) {
                    ForEach(card.slots.prefix(4)) { slot in
                        VStack(spacing: 5) {
                            Text(slot.timeLabel)
                                .font(.system(size: 10, weight: .bold))
                                .opacity(0.78)
                            Image(systemName: weatherSymbol(slot.icon))
                                .font(.system(size: 15, weight: .semibold))
                            Text("\(Int(slot.temperatureC.rounded()))°")
                                .font(.system(size: 13, weight: .heavy))
                            Text("\(Int(slot.windKnots.rounded())) kn")
                                .font(.system(size: 10, weight: .bold))
                                .opacity(0.78)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                }
            }

            Label("Im Revier öffnen", systemImage: "arrow.up.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.cyan)
        }
        .foregroundStyle(.primary)
        .padding(.leading, 12)
        .padding(.vertical, 4)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.cyan.opacity(0.75))
                .frame(width: 2)
        }
    }

    private func metric(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .opacity(0.85)
            Text(value)
                .font(.system(size: 14, weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .opacity(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }

    private func weatherSymbol(_ icon: String) -> String {
        let value = icon.lowercased()
        if value.contains("thunder") { return "cloud.bolt.rain.fill" }
        if value.contains("snow") { return "snowflake" }
        if value.contains("rain") || value.contains("shower") { return "cloud.rain.fill" }
        if value.contains("fog") || value.contains("mist") { return "cloud.fog.fill" }
        if value.contains("cloud") { return "cloud.fill" }
        if value.contains("night") || value.contains("moon") { return "moon.stars.fill" }
        return "sun.max.fill"
    }
}

struct NautiTypingBubble: View {
    @State private var animate = false

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: "sailboat.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.cyan)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 5) {
                Text("NAUTI")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color.secondary)

                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(Color.cyan)
                            .frame(width: 6, height: 6)
                            .opacity(animate ? 1 : 0.25)
                            .animation(
                                .easeInOut(duration: 0.55)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(index) * 0.16),
                                value: animate
                            )
                    }
                }
            }

            Spacer(minLength: 42)
        }
        .onAppear {
            animate = true
        }
    }
}

struct NautiSymbolAvatar: View {
    var body: some View {
        Image(systemName: "sailboat.fill")
            .font(.system(size: 24, weight: .heavy))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(
                    colors: [Color(hex: 0x0077B6), Color(hex: 0x14B8A6)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Circle()
            )
    }
}
