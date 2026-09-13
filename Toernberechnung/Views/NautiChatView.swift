import SwiftUI

// Shared Nauti chat building blocks used by the inline dashboard chat
// (`NautiPremiumChatOverlay`) and by the action confirmation sheet.
//
// The former standalone `NautiChatOverlay` and `NautiPresenceBubble` lived
// here too; both had no remaining call sites and were removed.

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
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .bold))
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
            Text(NautiAnswerFormatting.attributed(message.text))
                .lineSpacing(4)
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
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.cyan)
                .symbolEffect(.pulse, options: .repeating)
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
        Image(systemName: "sparkles")
            .font(.system(size: 20, weight: .heavy))
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

/// Render emphasis and preserve paragraph spacing, including older chat replies.
enum NautiAnswerFormatting {
    static func attributed(_ text: String) -> AttributedString {
        // Repair inline numbered headings emitted by earlier prompts. Require
        // bold heading syntax so decimals, times and ordinary numbers stay intact.
        let spaced = text.replacingOccurrences(
            of: #"[ \t]+(?=\d{1,2}\.[ \t]+\*\*)"#,
            with: "\n\n",
            options: .regularExpression
        )
        return (try? AttributedString(
            markdown: spaced,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(spaced)
    }
}
