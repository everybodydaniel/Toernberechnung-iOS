import SwiftUI
import UIKit

extension ContentView {
    func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .appCardSurface(cornerRadius: 22)
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

struct SkipperAvatarView: View {
    let urlString: String?
    let name: String
    let diameter: CGFloat

    var body: some View {
        ZStack {
            if let url = Self.remoteURL(from: urlString) {
                AsyncImage(url: url) { phase in
                    if !Self.usesInitials(for: phase), let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        initials
                    }
                }
            } else {
                initials
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.65), lineWidth: 1))
    }

    static func remoteURL(from urlString: String?) -> URL? {
        guard let rawValue = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              let url = URL(string: rawValue),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil else { return nil }
        return url
    }

    static func usesInitials(for phase: AsyncImagePhase) -> Bool {
        if case .success = phase {
            return false
        }
        return true
    }

    private var initials: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: diameter * 0.42, weight: .heavy))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(
                    colors: [Color(hex: 0x0077B6), Color.appPrimary],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }
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
    let brandStyle: AppHeaderBrandStyle
    let settingsAction: () -> Void
    var warningsAction: (() -> Void)? = nil
    var unreadWarningsCount: Int = 0

    @State private var isGlowPulsing: Bool = false

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
            HStack(spacing: 8) {
                if let warningsAction {
                    warningsButton(action: warningsAction)
                }
                settingsButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Color.clear)
    }

    private func warningsButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "bell.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(headerIconColor)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .appDarkCircularLiquidGlass(diameter: 44)
        .overlay(alignment: .topTrailing) {
            if unreadWarningsCount > 0 {
                ZStack {
                    // Outer pulsing breathing halo
                    Circle()
                        .fill(Color(red: 1.0, green: 0.18, blue: 0.22).opacity(0.55))
                        .frame(width: 14, height: 14)
                        .scaleEffect(isGlowPulsing ? 1.45 : 0.85)
                        .opacity(isGlowPulsing ? 0.9 : 0.3)
                        .blur(radius: 2)

                    // Sharp inner glowing dot with dark outline
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 1.0, green: 0.35, blue: 0.35),
                                    Color(red: 0.95, green: 0.08, blue: 0.12)
                                ],
                                center: .center,
                                startRadius: 1,
                                endRadius: 5
                            )
                        )
                        .frame(width: 9, height: 9)
                        .overlay(
                            Circle()
                                .stroke(Color.black.opacity(0.45), lineWidth: 1)
                        )
                        .shadow(color: Color.red.opacity(0.9), radius: 3, x: 0, y: 0)
                }
                .padding(.top, 4)
                .padding(.trailing, 4)
                .allowsHitTesting(false)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                isGlowPulsing = true
            }
        }
        .accessibilityLabel(unreadWarningsCount > 0 ? "Nautische Warnungen, \(unreadWarningsCount) ungelesen" : "Nautische Warnungen")
        .accessibilityIdentifier("AppHeaderWarningsButton")
    }

    // The glass surface sits OUTSIDE the button and `.contentShape` is the
    // last modifier inside the label. With the glass inside the label its
    // interactive effect swallowed the tap wherever a scroll view or the
    // MapLibre chart sat underneath the header — which was every tab except
    // Crewspace, the only one that pads its content below the header.
    private var settingsButton: some View {
        Button(action: settingsAction) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(headerIconColor)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .appDarkCircularLiquidGlass(diameter: 44)
        .accessibilityLabel("Einstellungen")
        .accessibilityIdentifier("AppHeaderSettingsButton")
    }

    private var headerIconColor: Color {
        if #available(iOS 26.0, *) {
            return .appPrimary
        }
        return .white
    }
}

struct SettingsSheet: View {
    var onBoatSettingsChanged: () -> Void = {}
    @AppStorage("boatName") private var boatName = ""
    @AppStorage("boatCallsign") private var boatCallsign = ""
    @AppStorage("boatDraft") private var boatDraft = "1.1"
    @AppStorage("safetyMargin") private var safetyMargin = "0.0"
    @AppStorage("boatLength") private var boatLength = "10.5"
    @AppStorage("appearanceMode") private var appearanceMode = AppAppearanceMode.light.rawValue
    @State private var introductionShown = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    settingsHero
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
        .fullScreenCover(isPresented: $introductionShown) {
            TideNodeOnboardingView { introductionShown = false }
                .overlay(alignment: .topTrailing) {
                    Button {
                        introductionShown = false
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .appCircularGlass()
                    .padding(16)
                    .accessibilityLabel("Einführung schließen")
                }
        }
        .onChange(of: boatDraft) { _, _ in onBoatSettingsChanged() }
        .onChange(of: safetyMargin) { _, _ in onBoatSettingsChanged() }
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
            settingsTextField("Rufzeichen", text: $boatCallsign, icon: "antenna.radiowaves.left.and.right")
            settingsMeasurementMenu("Tiefgang", storage: $boatDraft, tenths: Array(stride(from: 2, through: 20, by: 2)), icon: "arrow.down.to.line", identifier: "BoatDraftMenu")
            settingsMeasurementField("Länge", storage: $boatLength, icon: "ruler", identifier: "BoatLengthField")
            settingsMeasurementField("Sicherheitsmarge", storage: $safetyMargin, icon: "shield.checkered", identifier: "SafetyMarginField")
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
            sourceRow(name: "BSH", detail: "Gezeiten, Hoch- und Niedrigwasser sowie nautische Warnnachrichten", icon: "water.waves")
            sourceRow(name: "WSV / ELWIS", detail: "Bekanntmachungen für Seefahrer", icon: "antenna.radiowaves.left.and.right")
            sourceRow(name: "Apple Weather", detail: "WeatherKit-Prognosen, Wind und Böen", icon: "cloud.sun.rain.fill")
        }
    }

    private var onboardingSection: some View {
        settingsSection(title: "Einführung", icon: "sparkles.rectangle.stack.fill") {
            Button {
                introductionShown = true
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
            .contentShape(Rectangle())
            .appFieldSurface(cornerRadius: 16)
            .accessibilityIdentifier("ReplayIntroductionButton")
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

    private func settingsMeasurementMenu(
        _ title: String,
        storage: Binding<String>,
        tenths: [Int],
        icon: String,
        identifier: String
    ) -> some View {
        let currentValue = Double(storage.wrappedValue.replacingOccurrences(of: ",", with: "."))

        return Menu {
            ForEach(tenths, id: \.self) { tenth in
                let value = Double(tenth) / 10
                Button {
                    // Persist the existing decimal-string contract without locale ambiguity.
                    storage.wrappedValue = "\(tenth / 10).\(tenth % 10)"
                } label: {
                    if currentValue == value {
                        Label(measurementLabel(value), systemImage: "checkmark")
                    } else {
                        Text(measurementLabel(value))
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.appPrimary)
                    .frame(width: 28, height: 28)
                    .background(Color.appPrimary.opacity(0.12), in: Circle())
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(currentValue.map(measurementLabel) ?? "Bitte auswählen")
                    .font(.body.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.appPrimary)
            }
            .foregroundStyle(Color.primary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .appFieldSurface(cornerRadius: 16)
        .accessibilityIdentifier(identifier)
    }

    private func measurementLabel(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " m"
    }

    // MARK: - Manual numeric input field (replaces dropdown for Länge & Sicherheitsmarge)

    /// A text-field row that only accepts decimal numbers.
    /// – Keyboard is `.decimalPad` (digits + separator, no emoji).
    /// – Non-numeric characters are stripped on every keystroke.
    /// – On commit the value is normalised to German locale with exactly two
    ///   fraction digits (e.g. "0.1" → "0,10", "12" → "12,00").
    /// – The underlying `@AppStorage` string keeps the dot-decimal contract
    ///   used elsewhere ("12.00").
    private func settingsMeasurementField(
        _ title: String,
        storage: Binding<String>,
        icon: String,
        identifier: String
    ) -> some View {
        MeasurementTextField(
            title: title,
            storage: storage,
            icon: icon,
            identifier: identifier
        )
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

// MARK: - Custom Compact DatePicker with Transparent/White Subview Background
struct CustomCompactDatePicker: View {
    @Binding var selection: Date
    var components: DatePickerComponents = [.date, .hourAndMinute]
    var backgroundColor: UIColor = .clear

    var body: some View {
        DatePicker(
            "",
            selection: $selection,
            displayedComponents: components
        )
        .labelsHidden()
        .datePickerStyle(.compact)
        .environment(\.locale, AppDateFormatters.germanLocale)
        .environment(\.timeZone, AppDateFormatters.berlinTimeZone)
    }
}

// Observe only the main vertical scroll view, not nested horizontal controls.
extension View {
    func tracksAppHeaderVisibility(_ visible: Binding<Bool>) -> some View {
        onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top <= 2
        } action: { _, isAtTop in
            visible.wrappedValue = isAtTop
        }
    }
}
