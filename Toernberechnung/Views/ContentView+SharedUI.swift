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

    // Formatierer mit deutscher Sprache und Berliner Zeitzone. Verwenden
    // `AppDateFormatters`, damit die Formate in der gesamten App einheitlich bleiben.
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

// Die Kopfzeile liegt ohne eigene Hintergrundfläche über dem Inhalt.
// So bleibt die Karte hinter dem TideNode-Schriftzug durchgehend sichtbar.
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
                    // Äußerer pulsierender Lichtkreis
                    Circle()
                        .fill(Color(red: 1.0, green: 0.18, blue: 0.22).opacity(0.55))
                        .frame(width: 14, height: 14)
                        .scaleEffect(isGlowPulsing ? 1.45 : 0.85)
                        .opacity(isGlowPulsing ? 0.9 : 0.3)
                        .blur(radius: 2)

                    // Innerer leuchtender Punkt mit dunklem Rand
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

    // Die Glasfläche liegt außerhalb des Buttons; `.contentShape` ist der
    // letzte Modifier im Button-Inhalt. Innerhalb des Inhalts fing der interaktive
    // Glaseffekt Tipps ab, wenn eine Scrollansicht oder Karte darunter lag.
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
    @AppStorage("boatSpeed") private var boatSpeed = "6.0"
    @AppStorage("appearanceMode") private var appearanceMode = AppAppearanceMode.light.rawValue
    @State private var introductionShown = false
    @State private var privacyPolicyShown = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    settingsHero
                    boatSection
                    appearanceSection
                    onboardingSection
                    sourcesSection
                    privacySection
                    legalSection
                }
                .padding(16)
            }
            // Modale Ansichten erhalten ab iOS 26 automatisch einen Liquid-Glass-Hintergrund.
            // Ein deckender eigener Hintergrund würde ihn verdecken. Die Hilfsfunktion
            // blendet deshalb ab iOS 26 den Farbverlauf aus und behält ihn für ältere Versionen.
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
        // Modale Ansichten haben einen eigenen Darstellungsbereich. Das gesetzte
        // Erscheinungsbild wird deshalb auch hier angewendet, damit eine bereits
        // geöffnete Einstellungsansicht sofort auf Änderungen reagiert.
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
        .sheet(isPresented: $privacyPolicyShown) {
            PrivacyPolicySheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: boatDraft) { _, _ in onBoatSettingsChanged() }
        .onChange(of: safetyMargin) { _, _ in onBoatSettingsChanged() }
        .onChange(of: boatSpeed) { _, _ in onBoatSettingsChanged() }
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
            settingsMeasurementField("Reisegeschwindigkeit", storage: $boatSpeed, unit: "kn", icon: "speedometer", identifier: "BoatSpeedField")
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
            sourceRow(name: "BrightSky / DWD", detail: "Offene Wetter- und Winddaten des Deutschen Wetterdienstes für die Routenberechnung", icon: "wind")
            sourceRow(name: "Apple Weather", detail: "WeatherKit-Prognosen, Wind und Böen", icon: "cloud.sun.rain.fill")
            sourceRow(name: "OpenStreetMap / OpenSeaMap", detail: "Kartendaten und Seezeichen; Lizenzhinweise direkt auf der Karte", icon: "map")
            sourceRow(name: "Wattsegler", detail: "Veröffentlichte Lotungswerte mit Quellen- und Datumsangabe", icon: "ruler")
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

    private var privacySection: some View {
        settingsSection(title: "Datenschutz & Privatsphäre", icon: "hand.raised.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Törns, Notizen, Crew-Daten und GPS-Aufzeichnungen werden lokal gespeichert. Wetter- und Kartenabfragen benötigen Internetverbindungen.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.secondary)

                Button {
                    privacyPolicyShown = true
                } label: {
                    HStack {
                        Label("Datenschutzerklärung lesen", systemImage: "doc.text.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.appPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var legalSection: some View {
        settingsGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("© 2026 Daniel Horst")
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

    // Äußere Einstellungskarte mit Liquid Glass ab iOS 26.
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
                    // Dezimalwerte weiterhin als Zeichenketten im vorhandenen, sprachunabhängigen Format speichern.
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

    // MARK: - Direkte Zahleneingabe für Länge und Sicherheitsabstand

    /// Textfeldzeile für Dezimalzahlen.
    /// – `.decimalPad` bietet Ziffern und Dezimaltrennzeichen.
    /// – Andere Zeichen werden nach jeder Eingabe entfernt.
    /// – Beim Bestätigen wird der Wert deutsch mit zwei Nachkommastellen formatiert,
    ///   z. B. "0.1" → "0,10" und "12" → "12,00".
    /// – Die `@AppStorage`-Zeichenkette behält das interne Punktformat, z. B. "12.00".
    private func settingsMeasurementField(
        _ title: String,
        storage: Binding<String>,
        unit: String = "m",
        icon: String,
        identifier: String
    ) -> some View {
        MeasurementTextField(
            title: title,
            storage: storage,
            unit: unit,
            icon: icon,
            identifier: identifier
        )
        .appFieldSurface(cornerRadius: 16)
    }

    // Textfeldzeile innerhalb einer Glaskarte. Sie bleibt auf allen
    // Betriebssystemversionen ohne zusätzlichen Glaseffekt.
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

// MARK: - Kompakte Datumauswahl mit transparentem oder weißem Unteransichtshintergrund
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

// Nur die äußere vertikale Scrollansicht beobachten, keine eingebetteten horizontalen Elemente.
extension View {
    func tracksAppHeaderVisibility(_ visible: Binding<Bool>) -> some View {
        onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top <= 2
        } action: { _, isAtTop in
            visible.wrappedValue = isAtTop
        }
    }
}

struct PrivacyPolicySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Datenschutz bei TideNode")
                            .font(.system(size: 22, weight: .heavy))
                            .foregroundStyle(Color.appPrimary)
                        Text("Der Schutz deiner Daten hat bei TideNode oberste Priorität. Die App ist nach dem Grundsatz „Privacy by Design“ konzipiert.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.secondary)
                    }
                    .padding(.bottom, 6)

                    privacyCard(
                        icon: "person.crop.circle.badge.xmark",
                        title: "Keine Benutzerkonten & kein Tracking",
                        detail: "TideNode erfordert keine Registrierung und kein Benutzerkonto. Es werden keinerlei Werbetracker, Analytics oder Drittanbieter-Tracking-SDKs eingesetzt."
                    )

                    privacyCard(
                        icon: "internaldrive",
                        title: "Lokale Speicherung deiner Inhalte",
                        detail: "Alle Törnplanungen, Routen, Logbücher, Crewdaten und Kalendertermine werden ausschließlich lokal auf deinem Gerät gespeichert."
                    )

                    privacyCard(
                        icon: "location.fill",
                        title: "Standortdaten & Hintergrund-GPS",
                        detail: "Deine GPS-Spur wird während eines aktiven Törns lokal im Logbuch gespeichert. "
                            + "Für ortsbezogene Wetterabfragen und Kartenkacheln können Koordinaten oder "
                            + "Informationen zum betrachteten Kartenausschnitt an externe Anbieter gelangen."
                    )

                    privacyCard(
                        icon: "water.waves",
                        title: "Wetter- und Gezeitendaten",
                        detail: "Gezeiten- und Wasserstandsvorhersagen stammen aus den amtlichen Schnittstellen des BSH "
                            + "(Bundesamt für Seeschifffahrt und Hydrographie). Wetter- und Winddaten werden über die "
                            + "BrightSky-Schnittstelle (DWD – Deutscher Wetterdienst) sowie Apple WeatherKit bezogen. "
                            + "Dabei können Ortskoordinaten und technisch notwendige Verbindungsdaten übertragen werden."
                    )

                    privacyCard(
                        icon: "mic.fill",
                        title: "Lokale Spracheingabe bei Nauti",
                        detail: "Spracheingabe startet nur auf deinen Wunsch. Audio wird lokal verarbeitet und nicht gespeichert oder hochgeladen. "
                            + "Fehlende Sprachmodelle können von Apple heruntergeladen werden. Den erkannten Text prüfst du vor dem Senden."
                    )

                    Link(destination: URL(string: "https://everybodydaniel.github.io/Toernberechnung-iOS/datenschutz.html")!) {
                        Label("Vollständige Datenschutzerklärung online", systemImage: "arrow.up.right.square")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .padding(20)
            }
            .navigationTitle("Datenschutz")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Schließen") { dismiss() }
                        .fontWeight(.bold)
                }
            }
        }
    }

    private func privacyCard(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.appPrimary)
                .frame(width: 28)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.primary)
                Text(detail)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .lineSpacing(2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
