import SwiftUI
import UIKit

extension ContentView {
    func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 12, y: 8)
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
                picker
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.fieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        }
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .padding(14)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 8)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.fieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter
    }()

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static let slotFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

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
        .background(Color.cardBackground)
        .shadow(color: .black.opacity(0.04), radius: 6, y: 4)
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
                .frame(width: 44, height: 44)
                .background(Color.cardBackground)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.08), radius: 10, y: 6)
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
    @AppStorage("boatLength") private var boatLength = "10.5"
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("distanceUnit") private var distanceUnit = "nm"
    @AppStorage("depthUnit") private var depthUnit = "m"
    @AppStorage("speedUnit") private var speedUnit = "kn"
    @AppStorage("temperatureUnit") private var temperatureUnit = "c"
    @AppStorage("timeFormat") private var timeFormat = "24h"

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
                    unitsSection
                    sourcesSection
                    legalSection
                }
                .padding(16)
            }
            .background(
                LinearGradient(
                    colors: [Color.appBackground, Color.cardBackground, Color.fieldBackground],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
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
                settingsTextField("Tiefgang (m)", text: $boatDraft, icon: "arrow.down.to.line", keyboard: .decimalPad)
                settingsTextField("Länge (m)", text: $boatLength, icon: "ruler", keyboard: .decimalPad)
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

    private var unitsSection: some View {
        settingsSection(title: "Einheiten", icon: "ruler.fill") {
            Picker("Distanz", selection: $distanceUnit) {
                Text("nm").tag("nm")
                Text("km").tag("km")
            }
            .pickerStyle(.segmented)

            Picker("Tiefe", selection: $depthUnit) {
                Text("m").tag("m")
                Text("ft").tag("ft")
            }
            .pickerStyle(.segmented)

            Picker("Geschwindigkeit", selection: $speedUnit) {
                Text("kn").tag("kn")
                Text("km/h").tag("kmh")
            }
            .pickerStyle(.segmented)

            Picker("Temperatur", selection: $temperatureUnit) {
                Text("°C").tag("c")
                Text("°F").tag("f")
            }
            .pickerStyle(.segmented)

            Picker("Zeitformat", selection: $timeFormat) {
                Text("24 h").tag("24h")
                Text("12 h").tag("12h")
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

    private func settingsGlassCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

        return content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardBackground, in: shape)
            .overlay { shape.stroke(Color.primary.opacity(0.06), lineWidth: 1) }
    }

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
        .padding(12)
        .background(Color.fieldBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
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
        .padding(12)
        .background(Color.fieldBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
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
