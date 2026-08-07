import SwiftUI
import UIKit

extension ContentView {
    func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .appCardSurface(cornerRadius: 22)
    }

    func harbourPicker(title: String, selection: Binding<String>, embedded: Bool = false) -> some View {
        let picker = Picker(title, selection: selection) {
            ForEach(harbours) { harbour in
                Text(harbour.name).tag(harbour.id)
            }
        }
        .pickerStyle(.menu)
        .tint(Color(hex: 0x3C82FF))

        return Group {
            if embedded {
                // Embedded picker sits INSIDE a glass card, so we stay
                // on `appFieldSurface` (flat) — never stack glass on glass.
                picker.appFieldSurface(cornerRadius: 14)
            } else {
                card { picker }
            }
        }
    }

    func metricCard(_ title: String, text: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.secondary)
            Text(text)
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(Color.appPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text(caption)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .appMetricSurface(cornerRadius: 20)
    }

    func placeholderCard(icon: String, title: String, text: String) -> some View {
        card {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 34))
                    .foregroundStyle(Color(hex: 0xA7C8FF))
                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .multilineTextAlignment(.center)
                Text(text)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        }
    }

    func infoChip(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.secondary)
            Text(value)
                .font(.system(size: 16, weight: .semibold))
        }
        .appFieldSurface(cornerRadius: 16)
    }

    func numberField(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .number.precision(.fractionLength(1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
        }
        .font(.system(size: 15, weight: .medium))
    }

    func durationText(_ hours: Double) -> String {
        let totalMinutes = max(Int((hours * 60).rounded()), 0)
        return "\(totalMinutes / 60)h \(totalMinutes % 60)m"
    }

    // German-locale, Berlin-timezone formatters. These delegate to
    // `AppDateFormatters` so the whole app uses one consistent set.
    static var dateFormatter: DateFormatter { AppDateFormatters.dayMonthYear }
    static var timeFormatter: DateFormatter { AppDateFormatters.hourMinute }
    static var slotFormatter: DateFormatter { AppDateFormatters.hourMinute }

    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ActivityShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

enum AppHeaderBrandStyle {
    case white
    case primary

    var color: Color {
        switch self {
        case .white: return .white
        case .primary: return .appPrimary
        }
    }
}

// The header floats over the current content without painting a separate
// surface, so the map remains continuous behind the TideNode wordmark.
struct AppHeader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(MaritimeNoticeCenter.self) private var maritimeNoticeCenter

    let brandStyle: AppHeaderBrandStyle
    let unreadNoticeCount: Int
    let noticePulseTrigger: Int
    let noticesAction: (MaritimeNoticeSummary?) -> Void
    let refreshAction: () -> Void
    let settingsAction: () -> Void

    @State private var noticePulse = false
    @State private var noticePreviewShown = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image("TideNodeMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text("TideNode")
                    .font(.system(size: 25, weight: .heavy))
                    .foregroundStyle(brandStyle.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            Spacer()
            headerActions
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Color.clear)
        .onChange(of: noticePulseTrigger) { _, _ in
            guard unreadNoticeCount > 0, !reduceMotion else { return }
            noticePulse = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(620))
                noticePulse = false
            }
        }
    }

    @ViewBuilder
    private var headerActions: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 10) {
                headerActionButtons
            }
        } else {
            headerActionButtons
        }
    }

    private var headerActionButtons: some View {
        HStack(spacing: 10) {
            Button {
                noticePreviewShown.toggle()
            } label: {
                Image(systemName: "bell.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(headerIconColor)
                    .appDarkCircularLiquidGlass(diameter: 44)
                    .overlay(alignment: .topTrailing) {
                        if unreadNoticeCount > 0 {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 9, height: 9)
                                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                .scaleEffect(noticePulse ? 1.32 : 1)
                                .shadow(color: .red.opacity(noticePulse ? 0.60 : 0.22), radius: noticePulse ? 6 : 2)
                                .animation(.spring(response: 0.30, dampingFraction: 0.68), value: noticePulse)
                                .offset(x: 1, y: -1)
                                .zIndex(1)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Nachrichten für Seefahrer")
            .accessibilityValue(unreadNoticeCount == 0 ? "Keine ungelesenen Meldungen" : "\(unreadNoticeCount) ungelesen")
            .popover(
                isPresented: $noticePreviewShown,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .top
            ) {
                MaritimeNoticeQuickLook(
                    onOpenNotice: { notice in
                        dismissNoticePreview(andOpen: notice)
                    },
                    onShowAll: {
                        dismissNoticePreview(andOpen: nil)
                    }
                )
                .environment(maritimeNoticeCenter)
                .presentationCompactAdaptation(.popover)
                .presentationBackground(.clear)
            }

            Button(action: refreshAction) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(headerIconColor)
                    .appDarkCircularLiquidGlass(diameter: 44)
            }
            .buttonStyle(.plain)

            Button(action: settingsAction) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(headerIconColor)
                    .appDarkCircularLiquidGlass(diameter: 44)
            }
            .buttonStyle(.plain)
        }
    }

    private var headerIconColor: Color {
        if #available(iOS 26.0, *) {
            return .appPrimary
        }
        return .white
    }

    private func dismissNoticePreview(andOpen notice: MaritimeNoticeSummary?) {
        noticePreviewShown = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            noticesAction(notice)
        }
    }
}

struct CircleButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.85))
                .appCircularGlass(diameter: 44)
        }
        .buttonStyle(.plain)
    }
}

struct BoatTypePicker: View {
    @Environment(BoatProfileStore.self) private var boatProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Bootstyp", systemImage: "sailboat.fill")
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(Color.secondary)

            HStack(spacing: 10) {
                Image(systemName: "sailboat.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(hex: 0x3C82FF))
                    .frame(width: 28, height: 28)
                    .background(Color(hex: 0x3C82FF).opacity(0.12), in: Circle())

                Picker("Bootstyp", selection: selection) {
                    ForEach(
                        BoatTypeCatalog.selectableTypes(including: boatProfile.boatType),
                        id: \.self
                    ) { type in
                        Text(type).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .tint(Color(hex: 0x3C82FF))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .appFieldSurface(cornerRadius: 16)

            syncStatus
        }
    }

    private var selection: Binding<String> {
        Binding(
            get: { boatProfile.boatType },
            set: { boatProfile.selectBoatType($0) }
        )
    }

    @ViewBuilder
    private var syncStatus: some View {
        switch boatProfile.syncState {
        case .localOnly:
            Label("Auf diesem Gerät gespeichert", systemImage: "iphone")
                .foregroundStyle(Color.secondary)
        case .syncing:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Wird mit Crewspace synchronisiert …")
            }
            .foregroundStyle(Color.secondary)
        case .synced:
            Label("Mit Crewspace synchronisiert", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Crewspace-Synchronisierung ausstehend", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(Color.orange)
                Text(message)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
                Button("Erneut versuchen") {
                    boatProfile.retrySync()
                }
                .buttonStyle(.plain)
                .fontWeight(.bold)
                .foregroundStyle(Color(hex: 0x3C82FF))
            }
        }
    }
}

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("boatName") private var boatName = ""
    @AppStorage("boatCallsign") private var boatCallsign = ""
    @AppStorage("boatDraft") private var boatDraft = "1.1"
    @AppStorage("safetyMargin") private var safetyMargin = "0.0"
    @AppStorage("boatLength") private var boatLength = "10.5"
    @AppStorage("appearanceMode") private var appearanceMode = AppAppearanceMode.light.rawValue
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    settingsHero
                    CrewspaceAccountSettingsView()
                    boatSection
                    appearanceSection
                    onboardingSection
                    sourcesSection
                    legalSection
                }
                .padding(16)
            }
            // iOS 26 sheets get an automatic Liquid Glass background —
            // any opaque background we paint would hide that. The helper
            // hides our gradient on 26+ and keeps it as a clean fallback
            // for 18/25.
            .appSheetBackground {
                LinearGradient(
                    colors: [Color.appBackground, Color.cardBackground, Color.fieldBackground],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
        }
        // Sheets form their own presentation boundary. Applying the selected
        // appearance here makes an already open settings sheet update
        // immediately instead of retaining the scheme it was presented with.
        .preferredColorScheme(activeAppearance.colorScheme)
    }

    private var settingsHero: some View {
        settingsGlassCard {
            HStack(spacing: 14) {
                Image("TideNodeMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text("TideNode")
                        .font(.system(size: 28, weight: .heavy))
                        .foregroundStyle(Color.appPrimary)
                    Text("Profile, Darstellung und Datenquellen")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }

                Spacer()
            }
        }
    }

    private var boatSection: some View {
        settingsSection(title: "Bootsprofil", icon: "sailboat.fill") {
            settingsTextField("Bootsname", text: $boatName, icon: "tag.fill")
            BoatTypePicker()
            settingsTextField("Rufzeichen", text: $boatCallsign, icon: "antenna.radiowaves.left.and.right")
            HStack(spacing: 10) {
                settingsDecimalField("Tiefgang (m)", text: $boatDraft, icon: "arrow.down.to.line")
                settingsDecimalField("Länge (m)", text: $boatLength, icon: "ruler")
            }
            HStack(spacing: 10) {
                settingsDecimalField("Sicherheitsmarge (m)", text: $safetyMargin, icon: "shield.checkered")
            }
        }
    }

    private var appearanceSection: some View {
        settingsSection(title: "Darstellung", icon: "paintpalette.fill") {
            HStack(spacing: 6) {
                ForEach(AppAppearanceMode.allCases) { mode in
                    appearanceButton(mode)
                }
            }
            .padding(5)
            .background(Color.primary.opacity(0.055), in: Capsule())
            .sensoryFeedback(.selection, trigger: appearanceMode)
        }
    }

    private func appearanceButton(_ mode: AppAppearanceMode) -> some View {
        let selected = activeAppearance == mode
        return Button {
            appearanceMode = mode.rawValue
        } label: {
            appearanceIcon(mode)
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.66))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(selected ? Color.appPrimary : Color.clear, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(
                            selected ? Color.white.opacity(0.22) : Color.primary.opacity(0.08),
                            lineWidth: 0.8
                        )
                }
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(7)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.accessibilityLabel)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func appearanceIcon(_ mode: AppAppearanceMode) -> some View {
        switch mode {
        case .light:
            Image(systemName: "sun.max.fill")
                .font(.system(size: 25, weight: .semibold))
        case .dark:
            Image(systemName: "moon.fill")
                .font(.system(size: 25, weight: .semibold))
        }
    }

    private var activeAppearance: AppAppearanceMode {
        AppAppearanceMode.resolved(from: appearanceMode)
    }

    private var sourcesSection: some View {
        settingsSection(title: "Datenquellen", icon: "network") {
            sourceRow(name: "BSH", detail: "Gezeiten, Hoch- und Niedrigwasser", icon: "water.waves")
            sourceRow(name: "Apple Weather", detail: "WeatherKit-Prognosen, Wind und Böen", icon: "cloud.sun.rain.fill")
            sourceRow(name: "Firebase Auth", detail: "Sicherer Crewspace-Zugang mit eindeutiger Skipper-ID", icon: "lock.fill")
        }
    }

    private var onboardingSection: some View {
        settingsSection(title: "Einführung", icon: "sparkles.rectangle.stack.fill") {
            Button {
                dismiss()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(180))
                    hasSeenOnboarding = false
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.appPrimary)
                        .frame(width: 36, height: 36)
                        .background(Color.appPrimary.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Einführung erneut ansehen")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.primary)
                        Text("Törnplanung, Wetter und Crewspace")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.secondary)
                }
            }
            .buttonStyle(.plain)
            .appFieldSurface(cornerRadius: 16)
        }
    }

    private var legalSection: some View {
        settingsGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("© 2026 TideNode")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Color.appPrimary)
                Text("TideNode ersetzt keine Seeordnung, amtlichen Bekanntmachungen, Revierinformationen oder die nautische Verantwortung der Schiffsführung.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.secondary)
            }
        }
    }

    private func settingsSection<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        settingsGlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Label(title, systemImage: icon)
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(Color.appPrimary)
                content()
            }
        }
    }

    // Top-level settings card → Liquid Glass on iOS 26.
    private func settingsGlassCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .appCardSurface(cornerRadius: 24)
    }

    // Decimal field that works on German keyboards. The .decimalPad
    // keyboard on a German locale shows a comma, not a dot, so the
    // raw String the user types is "1,5". We persist with a dot so
    // `Double("1.5")` keeps working everywhere, but the visible value
    // shows whichever the user typed last. Both notations round-trip
    // safely.
    private func settingsDecimalField(
        _ title: String,
        text rawStorage: Binding<String>,
        icon: String
    ) -> some View {
        let displayBinding = Binding<String>(
            get: {
                // Show what's stored; users see dots in legacy data
                // but new edits will appear with whichever separator
                // the keyboard offers.
                rawStorage.wrappedValue
            },
            set: { newValue in
                // Strip everything except digits, comma, dot, minus;
                // then normalize the decimal separator to a dot before
                // persisting, so the engine's `Double(_:)` parser still
                // accepts the value on any locale.
                let filtered = newValue.filter { "0123456789.,-".contains($0) }
                rawStorage.wrappedValue = filtered.replacingOccurrences(of: ",", with: ".")
            }
        )

        return HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color(hex: 0x3C82FF))
                .frame(width: 28, height: 28)
                .background(Color(hex: 0x3C82FF).opacity(0.12))
                .clipShape(Circle())
            TextField(title, text: displayBinding)
                .keyboardType(.decimalPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .font(.system(size: 15, weight: .semibold))
        }
        .appFieldSurface(cornerRadius: 16)
    }

    // Inline text-field row. Sits INSIDE a glass card, so it stays as a
    // flat field on every OS (never stack glass on glass).
    private func settingsTextField(
        _ title: String,
        text: Binding<String>,
        icon: String,
        keyboard: UIKeyboardType = .default,
        capitalization: TextInputAutocapitalization = .words,
        textContentType: UITextContentType? = nil,
        autocorrectionDisabled: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color(hex: 0x3C82FF))
                .frame(width: 28, height: 28)
                .background(Color(hex: 0x3C82FF).opacity(0.12))
                .clipShape(Circle())
            TextField(title, text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(capitalization)
                .textContentType(textContentType)
                .autocorrectionDisabled(autocorrectionDisabled)
                .font(.system(size: 15, weight: .semibold))
        }
        .appFieldSurface(cornerRadius: 16)
    }

    private func sourceRow(name: String, detail: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color(hex: 0x0D9488))
                .frame(width: 34, height: 34)
                .background(Color(hex: 0x0D9488).opacity(0.12))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.appPrimary)
                Text(detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.secondary)
            }
            Spacer()
        }
        .appFieldSurface(cornerRadius: 16)
    }
}

extension Color {
    init(hex: UInt64) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    static var appBackground: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: 0x121214) : .systemGroupedBackground
        })
    }

    static var cardBackground: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: 0x1C1C1E) : .secondarySystemGroupedBackground
        })
    }

    static var fieldBackground: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: 0x2C2C2E) : .tertiarySystemGroupedBackground
        })
    }

    static var chatOverlayBackground: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: 0x121214) : .systemBackground
        })
    }

    static var chatSidebarBackground: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: 0x1C1C1E) : .secondarySystemBackground
        })
    }

    static var chatElementBackground: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: 0x2C2C2E) : .secondarySystemBackground
        })
    }

    static var chatFieldBackground: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: 0x2C2C2E) : .tertiarySystemBackground
        })
    }

    static var appPrimary: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: 0xA7C8FF) : UIColor.appPrimary
        })
    }

    static var glassTint: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: 0x1F2937) : UIColor(hex: 0xF8FBFF)
        })
    }
}

extension UIColor {
    static var appPrimary: UIColor {
        UIColor(hex: 0x244B92)
    }

    convenience init(hex: UInt64) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
