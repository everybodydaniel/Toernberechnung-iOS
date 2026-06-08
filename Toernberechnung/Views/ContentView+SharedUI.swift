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

struct SwipeDeleteRow<Content: View>: View {
    let deleteAction: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var offset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .leading) {
            Button(action: deleteAction) {
                Label("Löschen", systemImage: "trash.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 104, alignment: .center)
                    .frame(maxHeight: .infinity)
            }
            .background(Color.red)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .opacity(offset > 1 ? 1 : 0)

            content()
                .offset(x: offset)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 18)
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            offset = max(0, min(118, value.translation.width))
                        }
                        .onEnded { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) { offset = 0 }
                                return
                            }
                            if value.translation.width > 160 {
                                deleteAction()
                            } else {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                                    offset = value.translation.width > 64 ? 104 : 0
                                }
                            }
                        }
                )
        }
    }
}

// AppHeader sits at the top of every tab, just under the system status
// bar. On iOS 26 it becomes a true Liquid Glass top bar (closer to the
// system NavigationBar) and on iOS 18 it stays as ultraThinMaterial.
struct AppHeader: View {
    let refreshAction: () -> Void
    let settingsAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sailboat.fill")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(Color(hex: 0x3C82FF))
                Text("TÖRNCALCULATOR")
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(Color.appPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer()
            Button(action: refreshAction) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x3C82FF))
            }
            Button(action: settingsAction) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.primary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .appFloatingOverlay(cornerRadius: 0)
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

struct SettingsSheet: View {
    @AppStorage("profileName") private var profileName = ""
    @AppStorage("profileEmail") private var profileEmail = ""
    @AppStorage("profilePhone") private var profilePhone = ""
    @AppStorage("boatName") private var boatName = ""
    @AppStorage("boatType") private var boatType = "Segelyacht"
    @AppStorage("boatCallsign") private var boatCallsign = ""
    @AppStorage("boatDraft") private var boatDraft = "1.1"
    @AppStorage("safetyMargin") private var safetyMargin = "0.0"
    @AppStorage("boatLength") private var boatLength = "10.5"
    @AppStorage("appearanceMode") private var appearanceMode = "system"

    private let boatTypes = ["Segelyacht", "Motoryacht", "Katamaran", "Jolle", "Arbeitsboot"]
    private let appearanceOptions = [("system", "System"), ("light", "Hell"), ("dark", "Dunkel")]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    settingsHero
                    profileSection
                    boatSection
                    appearanceSection
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
            .preferredColorScheme(preferredColorScheme)
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private var settingsHero: some View {
        settingsGlassCard {
            HStack(spacing: 14) {
                Image(systemName: "sailboat.circle.fill")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(Color(hex: 0x3C82FF))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Törncalculator™")
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

    private var profileSection: some View {
        settingsSection(title: "Nutzerprofil", icon: "person.crop.circle.fill") {
            settingsTextField("Name", text: $profileName, icon: "person.fill")
            settingsTextField(
                "E-Mail",
                text: $profileEmail,
                icon: "envelope.fill",
                keyboard: .emailAddress,
                capitalization: .never,
                textContentType: .emailAddress,
                autocorrectionDisabled: true
            )
            settingsTextField("Telefon", text: $profilePhone, icon: "phone.fill", keyboard: .phonePad)
        }
    }

    private var boatSection: some View {
        settingsSection(title: "Bootsprofil", icon: "sailboat.fill") {
            settingsTextField("Bootsname", text: $boatName, icon: "tag.fill")
            Picker("Bootstyp", selection: $boatType) {
                ForEach(boatTypes, id: \.self) { type in
                    Text(type).tag(type)
                }
            }
            .pickerStyle(.menu)
            .tint(Color(hex: 0x3C82FF))
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
            Picker("Darstellung", selection: $appearanceMode) {
                ForEach(appearanceOptions, id: \.0) { option in
                    Text(option.1).tag(option.0)
                }
            }
            .pickerStyle(.segmented)

        }
    }

    private var sourcesSection: some View {
        settingsSection(title: "Datenquellen", icon: "network") {
            sourceRow(name: "BSH", detail: "Gezeiten, Hoch- und Niedrigwasser", icon: "water.waves")
            sourceRow(name: "DWD", detail: "Wetterdaten und kompakte Vorhersagen", icon: "cloud.sun.rain.fill")
            sourceRow(name: "Lokale Profile", detail: "Nutzer- und Bootsdaten bleiben auf dem Gerät", icon: "lock.fill")
        }
    }

    private var legalSection: some View {
        settingsGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("© 2026 Törncalculator™")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Color.appPrimary)
                Text("Törncalculator ersetzt keine Seeordnung, amtlichen Bekanntmachungen, Revierinformationen oder die nautische Verantwortung der Schiffsführung.")
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
        Color(uiColor: .systemGroupedBackground)
    }

    static var cardBackground: Color {
        Color(uiColor: .secondarySystemGroupedBackground)
    }

    static var fieldBackground: Color {
        Color(uiColor: .tertiarySystemGroupedBackground)
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
