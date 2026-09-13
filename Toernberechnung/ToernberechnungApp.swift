import SwiftUI
import SwiftData
import UIKit

enum AppAppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case light
    case dark

    var id: Self { self }

    static func resolved(from storedValue: String) -> AppAppearanceMode {
        AppAppearanceMode(rawValue: storedValue) ?? .light
    }

    var colorScheme: ColorScheme {
        switch self {
        case .light: return .light
        case .dark: return .dark
        }
    }

    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .light: return .light
        case .dark: return .dark
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .light: return "Heller Modus"
        case .dark: return "Dunkler Modus"
        }
    }
}

private struct MaritimeWeatherServiceEnvironmentKey: EnvironmentKey {
    static let defaultValue = MaritimeWeatherService.shared
}

extension EnvironmentValues {
    var maritimeWeatherService: MaritimeWeatherService {
        get { self[MaritimeWeatherServiceEnvironmentKey.self] }
        set { self[MaritimeWeatherServiceEnvironmentKey.self] = newValue }
    }
}

@Model
final class CalculationRecord {
    var routeTitle: String
    var startName: String
    var destinationName: String
    var departureAt: Date
    var arrivalAt: Date
    var distanceNM: Double
    var status: String
    var fmw: Double
    var wt: Double
    var wuk: Double
    var weatherSummary: String = ""
    var tideSummary: String = ""
    var crewSummary: String = ""
    var notes: String = ""
    var createdAt: Date

    // MARK: - Voyage fields
    //
    // Filled in by `ActiveVoyageManager.stopVoyageAndSaveLogbook` when a
    // live tracked trip ends. For planning-only entries these stay at
    // their default zero / empty values, so the model stays backwards-
    // compatible with previously saved records.

    /// True when the record represents an actually sailed voyage (not a
    /// planning-only calculation).
    var isActualVoyage: Bool = false
    /// GPS-measured distance in nautical miles.
    var actualDistanceNM: Double = 0
    /// Mean speed-over-ground in knots, averaged over GPS samples.
    var averageSOGKnots: Double = 0
    /// Peak SOG observed during the voyage.
    var maxSOGKnots: Double = 0
    /// Voyage duration in seconds (`arrivalAt − departureAt`).
    var voyageDurationSeconds: Double = 0
    /// JSON-encoded breadcrumb trail: an array of `{lat,lon,ts}` triples.
    /// Stored as text so the SwiftData schema stays trivial.
    var breadcrumbJSON: String = ""

    init(
        routeTitle: String,
        startName: String,
        destinationName: String,
        departureAt: Date,
        arrivalAt: Date,
        distanceNM: Double,
        status: String,
        fmw: Double,
        wt: Double,
        wuk: Double,
        weatherSummary: String = "",
        tideSummary: String = "",
        crewSummary: String = "",
        notes: String = "",
        createdAt: Date = .now,
        isActualVoyage: Bool = false,
        actualDistanceNM: Double = 0,
        averageSOGKnots: Double = 0,
        maxSOGKnots: Double = 0,
        voyageDurationSeconds: Double = 0,
        breadcrumbJSON: String = ""
    ) {
        self.routeTitle = routeTitle
        self.startName = startName
        self.destinationName = destinationName
        self.departureAt = departureAt
        self.arrivalAt = arrivalAt
        self.distanceNM = distanceNM
        self.status = status
        self.fmw = fmw
        self.wt = wt
        self.wuk = wuk
        self.weatherSummary = weatherSummary
        self.tideSummary = tideSummary
        self.crewSummary = crewSummary
        self.notes = notes
        self.createdAt = createdAt
        self.isActualVoyage = isActualVoyage
        self.actualDistanceNM = actualDistanceNM
        self.averageSOGKnots = averageSOGKnots
        self.maxSOGKnots = maxSOGKnots
        self.voyageDurationSeconds = voyageDurationSeconds
        self.breadcrumbJSON = breadcrumbJSON
    }
}

@Model
final class WeatherSnapshot {
    var regionID: String
    var regionName: String
    var stationID: String
    var stationName: String
    var currentSummary: String
    var slotSummary: String
    var fetchedAt: Date

    init(
        regionID: String,
        regionName: String,
        stationID: String,
        stationName: String,
        currentSummary: String,
        slotSummary: String,
        fetchedAt: Date = .now
    ) {
        self.regionID = regionID
        self.regionName = regionName
        self.stationID = stationID
        self.stationName = stationName
        self.currentSummary = currentSummary
        self.slotSummary = slotSummary
        self.fetchedAt = fetchedAt
    }
}

@Model
final class AuditLog {
    var action: String
    var source: String
    var statement: String
    var status: String
    var createdAt: Date

    init(
        action: String,
        source: String,
        statement: String,
        status: String,
        createdAt: Date = .now
    ) {
        self.action = action
        self.source = source
        self.statement = statement
        self.status = status
        self.createdAt = createdAt
    }
}

@Model
final class CrewMemberRecord {
    var name: String
    var role: String
    var emergencyContact: String = ""
    var emergencyPhone: String = ""
    var notes: String = ""
    var isOnBoard: Bool
    var createdAt: Date

    init(
        name: String,
        role: String,
        emergencyContact: String = "",
        emergencyPhone: String = "",
        notes: String = "",
        isOnBoard: Bool = true,
        createdAt: Date = .now
    ) {
        self.name = name
        self.role = role
        self.emergencyContact = emergencyContact
        self.emergencyPhone = emergencyPhone
        self.notes = notes
        self.isOnBoard = isOnBoard
        self.createdAt = createdAt
    }
}

/// Locally planned crew appointment. Everything lives on the device; there is
/// no account, no sync and no sharing.
@Model
final class CrewEventRecord {
    var title: String
    var startsAt: Date
    var endsAt: Date
    var location: String = ""
    var notes: String = ""
    /// Raw value of `CrewEventCategory`. Stored as text so adding a category
    /// later stays a lightweight schema change.
    var category: String = CrewEventCategory.other.rawValue
    var isAllDay: Bool = false
    /// Names of the crew members assigned to this appointment. Plain strings
    /// rather than a relationship — a deleted crew member should not silently
    /// rewrite an already planned appointment.
    var attendees: [String] = []
    var createdAt: Date

    init(
        title: String,
        startsAt: Date,
        endsAt: Date,
        location: String = "",
        notes: String = "",
        category: String = CrewEventCategory.other.rawValue,
        isAllDay: Bool = false,
        attendees: [String] = [],
        createdAt: Date = .now
    ) {
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.location = location
        self.notes = notes
        self.category = category
        self.isAllDay = isAllDay
        self.attendees = attendees
        self.createdAt = createdAt
    }
}

@main
struct ToernberechnungApp: App {
    private let modelContainer: ModelContainer = {
        let schema = Schema([
            CalculationRecord.self,
            WeatherSnapshot.self,
            AuditLog.self,
            CrewMemberRecord.self,
            CrewEventRecord.self
        ])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: false)
        return try! ModelContainer(for: schema, configurations: [configuration])
    }()

    /// Live GPS service.  Shared across every tab so the background
    /// recording survives navigation away from the Map tab.
    @State private var locationService: LocationService
    @State private var navigationTracker: NavigationTracker
    @State private var voyageManager: ActiveVoyageManager
    @AppStorage("appearanceMode") private var appearanceMode = AppAppearanceMode.light.rawValue
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    private let weatherService: MaritimeWeatherService

    init() {
        if ProcessInfo.processInfo.environment["UITEST_RESET_ONBOARDING"] == "1" {
            UserDefaults.standard.set(false, forKey: "hasSeenOnboarding")
        }
        let loc = LocationService()
        let tracker = NavigationTracker()
        let weather = MaritimeWeatherService()
        let voyage = ActiveVoyageManager(
            locationService: loc,
            tracker: tracker,
            weatherService: weather
        )
        weatherService = weather
        _locationService = State(initialValue: loc)
        _navigationTracker = State(initialValue: tracker)
        _voyageManager = State(initialValue: voyage)

        // Start SeaMask building asynchronously on launch
        NauticalRouteService.shared.buildSeaMask()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if hasSeenOnboarding {
                    ContentView()
                        .transition(.opacity.combined(with: .scale(scale: 1.015)))
                } else {
                    TideNodeOnboardingView {
                        withAnimation(.easeInOut(duration: 0.32)) {
                            hasSeenOnboarding = true
                        }
                    }
                    .transition(.opacity)
                }
            }
                // Window-level tap recognizer so tapping next to a field
                // closes the keyboard, in sheets as well as in the tabs.
                .background(KeyboardDismissGestureInstaller())
                .environment(locationService)
                .environment(navigationTracker)
                .environment(voyageManager)
                .environment(\.maritimeWeatherService, weatherService)
                // Force German locale + Berlin timezone for every native
                // SwiftUI control (DatePicker, formatted dates, …) so the
                // UI never falls back to en_US / UTC.
                .environment(\.locale, Locale(identifier: "de_DE"))
                .environment(\.timeZone, TimeZone(identifier: "Europe/Berlin") ?? .current)
                .environment(\.calendar, {
                    var cal = Calendar(identifier: .gregorian)
                    cal.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
                    cal.locale = Locale(identifier: "de_DE")
                    return cal
                }())
                .preferredColorScheme(activeAppearance.colorScheme)
                .onAppear {
                    let appearance = activeAppearance
                    if appearanceMode != appearance.rawValue {
                        appearanceMode = appearance.rawValue
                    }
                    applyAppearance(appearance)
                }
                .onChange(of: appearanceMode) { _, newValue in
                    applyAppearance(AppAppearanceMode.resolved(from: newValue))
                }
        }
        .modelContainer(modelContainer)
    }

    private var activeAppearance: AppAppearanceMode {
        AppAppearanceMode.resolved(from: appearanceMode)
    }

    @MainActor
    private func applyAppearance(_ appearance: AppAppearanceMode) {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = appearance.userInterfaceStyle
            }
        }
    }
}

private enum OnboardingPage: Int, CaseIterable, Identifiable {
    case route
    case weather
    case warnings
    case crew

    var id: Int { rawValue }

    var eyebrow: String {
        switch self {
        case .route: return "TÖRN UND NAVIGATION"
        case .weather: return "WETTER AUF DER ROUTE"
        case .warnings: return "SEEFAHRER-MELDUNGEN"
        case .crew: return "GEMEINSAM AN BORD"
        }
    }

    var title: String {
        switch self {
        case .route: return "Sicher planen.\nKlar navigieren."
        case .weather: return "Wind und Wetter vorausdenken."
        case .warnings: return "Meldungen lesen.\nInformiert ablegen."
        case .crew: return "Crew und Termine\nim Blick behalten."
        }
    }

    var accessibilityTitle: String {
        title.replacingOccurrences(of: "\n", with: " ")
    }

    var detail: String {
        switch self {
        case .route:
            return "Plane Törns durchs Wattenmeer, prüfe Passagefenster und zeichne deine Fahrt per GPS auf."
        case .weather:
            return "Behalte Wind, Böen und Vorhersagen für dein Revier und deine Route kompakt im Blick."
        case .warnings:
            return "Informiere dich über Sperrungen, Gefahren und veränderte Seezeichen in der Nordsee. Lies die Meldungen und öffne verortete Hinweise direkt auf der Karte."
        case .crew:
            return "Erfasse Rollen, Notfallkontakte, Termine und die Anwesenheit an Bord."
        }
    }

    var accent: Color {
        switch self {
        case .route: return Color(hex: 0x0EA5E9)
        case .weather: return Color(hex: 0xF59E0B)
        case .warnings: return Color(hex: 0xEA580C)
        case .crew: return Color(hex: 0x0D9488)
        }
    }


}

struct TideNodeOnboardingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onFinish: () -> Void
    @State private var selection = OnboardingPage.route
    @State private var safetyNoticeAccepted = false

    var body: some View {
        ZStack {
            onboardingBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                brandHeader
                TabView(selection: $selection) {
                    ForEach(OnboardingPage.allCases) { page in
                        OnboardingPageView(page: page, isActive: selection == page, reduceMotion: reduceMotion)
                            .tag(page)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                footer
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
    }

    private var onboardingBackground: some View {
        LinearGradient(
            colors: [
                Color(uiColor: .systemBackground),
                Color(hex: 0xDDF4F3).opacity(0.82),
                Color(hex: 0xDCEBFA).opacity(0.76)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var brandHeader: some View {
        HStack(spacing: 11) {
            Image("TideNodeMark")
                .resizable()
                .scaledToFit()
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            Text("TideNode")
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(Color.appPrimary)
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 7) {
                ForEach(OnboardingPage.allCases) { page in
                    Capsule()
                        .fill(page == selection ? selection.accent : Color.secondary.opacity(0.22))
                        .frame(width: page == selection ? 28 : 8, height: 8)
                        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.8), value: selection)
                }
            }

            if selection == .crew {
                Button {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.82)) {
                        safetyNoticeAccepted.toggle()
                    }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: safetyNoticeAccepted ? "checkmark.square.fill" : "square")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(safetyNoticeAccepted ? selection.accent : Color.secondary)
                            .contentTransition(.symbolEffect(.replace))

                        // Shown in full. The page above is top-aligned in its
                        // scroll view, so the slack there absorbs the extra
                        // height without pushing any copy off screen.
                        Text(
                            "Ich habe verstanden, dass TideNode nur eine Planungshilfe ist und keine " +
                                "amtlichen nautischen Veröffentlichungen, aktuellen Bekanntmachungen, " +
                                "Revierinformationen, Wetterbeurteilung oder die Verantwortung der " +
                                "Schiffsführung ersetzt."
                        )
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.primary)
                            .multilineTextAlignment(.leading)
                            .lineSpacing(1)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .secondarySystemBackground).opacity(0.82), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(safetyNoticeAccepted ? selection.accent.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("onboardingSafetyAcknowledgement")
                .accessibilityLabel("Sicherheitshinweis bestätigen")
                .accessibilityValue(safetyNoticeAccepted ? "Bestätigt" : "Nicht bestätigt")
            }

            Button {
                advance()
            } label: {
                HStack {
                    Text(selection == .crew ? "Loslegen" : "Fortfahren")
                    Spacer()
                    Image(systemName: selection == .crew ? "checkmark" : "arrow.right")
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(primaryButtonColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(selection == .crew && !safetyNoticeAccepted)
            .accessibilityHint(selection == .crew && !safetyNoticeAccepted ? "Bestätige zuerst den Sicherheitshinweis." : "")

            Button("Überspringen", action: skipToSafetyNotice)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.secondary)
                .frame(minHeight: 32)
                .opacity(selection == .crew ? 0 : 1)
                .disabled(selection == .crew)
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private func advance() {
        guard selection != .crew else {
            guard safetyNoticeAccepted else { return }
            onFinish()
            return
        }
        let next = OnboardingPage(rawValue: selection.rawValue + 1) ?? .crew
        if reduceMotion {
            selection = next
        } else {
            withAnimation(.spring(response: 0.48, dampingFraction: 0.84)) {
                selection = next
            }
        }
    }

    private var primaryButtonColor: Color {
        if selection == .crew && !safetyNoticeAccepted {
            return Color.secondary.opacity(0.32)
        }
        return selection.accent
    }

    private func skipToSafetyNotice() {
        guard selection != .crew else { return }
        if reduceMotion {
            selection = .crew
        } else {
            withAnimation(.spring(response: 0.48, dampingFraction: 0.84)) {
                selection = .crew
            }
        }
    }
}

private struct OnboardingPageView: View {
    let page: OnboardingPage
    let isActive: Bool
    let reduceMotion: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                OnboardingIllustration(page: page, isActive: isActive, reduceMotion: reduceMotion)
                    .frame(maxWidth: 560)
                    .frame(height: 280)

                VStack(spacing: 12) {
                    Text(page.eyebrow)
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(page.accent)
                    Text(page.title)
                        .font(.system(size: 31, weight: .heavy))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(page.accessibilityTitle)
                    Text(page.detail)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .frame(maxWidth: 520)


                }
                .opacity(isActive ? 1 : 0.35)
                .offset(y: isActive || reduceMotion ? 0 : 14)
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.5, dampingFraction: 0.84).delay(0.08), value: isActive)
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 18)
        }
        .scrollIndicators(.hidden)
    }
}

private struct OnboardingIllustration: View {
    let page: OnboardingPage
    let isActive: Bool
    let reduceMotion: Bool
    @State private var routeAnimationStartedAt = Date()

    var body: some View {
        Group {
            switch page {
            case .route: routeIllustration
            case .weather: weatherIllustration
            case .warnings: warningsIllustration
            case .crew: crewIllustration
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appFloatingOverlay(cornerRadius: 34)
        .scaleEffect(isActive || reduceMotion ? 1 : 0.94)
        .opacity(isActive ? 1 : 0.55)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.52, dampingFraction: 0.78), value: isActive)
        .onAppear {
            if isActive {
                routeAnimationStartedAt = Date()
            }
        }
        .onChange(of: isActive) { _, active in
            if active {
                routeAnimationStartedAt = Date()
            }
        }
    }

    private var warningsIllustration: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(page.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nordsee Warnmeldungen")
                        .font(.system(size: 16, weight: .heavy))
                    Text("Hinweise für dein Revier")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            warningPreviewRow("Gefahren und Sperrungen", icon: "exclamationmark.triangle.fill", tint: .orange)
            warningPreviewRow("Tonnen und Seezeichen", icon: "mappin.and.ellipse", tint: .blue)
            warningPreviewRow("Hinweise auf der Karte", icon: "map.fill", tint: .teal)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func warningPreviewRow(_ title: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var routeIllustration: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !isActive)) { timeline in
            GeometryReader { proxy in
                let phase = timeline.date.timeIntervalSinceReferenceDate
                let elapsed = timeline.date.timeIntervalSince(routeAnimationStartedAt)
                let progress = reduceMotion ? CGFloat(0.72) : min(CGFloat(elapsed / 5.2), 1)
                let boatPosition = routePoint(progress: progress, in: proxy.size)
                let boatBob = reduceMotion || progress >= 1 ? CGFloat.zero : CGFloat(sin(phase * 2.2) * 2.5)

                ZStack {
                    RoundedRectangle(cornerRadius: 25, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: 0x8ED8EC), Color(hex: 0x1688B8), Color(hex: 0x075985)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    Canvas { context, size in
                        let phases = [phase * 0.48, phase * 0.7 + 1.4, phase * 0.92 + 2.8]
                        let colors = [
                            Color.white.opacity(0.18),
                            Color(hex: 0x67E8F9).opacity(0.24),
                            Color(hex: 0x082F49).opacity(0.2)
                        ]
                        for index in phases.indices {
                            let path = wavePath(
                                size: size,
                                baseline: size.height * (0.48 + CGFloat(index) * 0.14),
                                amplitude: 8 + CGFloat(index) * 3,
                                phase: phases[index]
                            )
                            context.fill(path, with: .color(colors[index]))
                        }
                    }

                    Path { path in
                        path.move(to: routeStart(in: proxy.size))
                        path.addCurve(
                            to: routeEnd(in: proxy.size),
                            control1: routeControlOne(in: proxy.size),
                            control2: routeControlTwo(in: proxy.size)
                        )
                    }
                    .stroke(
                        Color.white.opacity(0.78),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [8, 7])
                    )

                    routePin("START", icon: "mappin.circle.fill")
                        .position(routeStart(in: proxy.size))
                    routePin("ZIEL", icon: "flag.checkered.circle.fill")
                        .position(routeEnd(in: proxy.size))

                    Image(systemName: "sailboat.fill")
                        .font(.system(size: 43, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: Color(hex: 0x083B66).opacity(0.45), radius: 9, y: 6)
                        .position(x: boatPosition.x, y: boatPosition.y + boatBob)
                }
                .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 25, style: .continuous)
                        .stroke(Color.white.opacity(0.42), lineWidth: 1)
                }
            }
        }
    }

    private func routePin(_ title: String, icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 25, weight: .bold))
            Text(title).font(.system(size: 8, weight: .heavy))
        }
        .foregroundStyle(.white)
        .shadow(color: Color(hex: 0x083B66).opacity(0.5), radius: 4, y: 2)
    }

    // The weather card sizes to its own content and is pinned to the top, so
    // the card never grows into the container edge — that keeps the same
    // breathing room below the illustration as on the route and crew pages.
    private var weatherIllustration: some View {
        VStack(spacing: 0) {
            weatherCard
            Spacer(minLength: 0)
        }
    }

    private var weatherCard: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !isActive)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 25, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: 0x2D9CDB), Color(hex: 0x1261A0), Color(hex: 0x153A67)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .fill(Color.yellow.opacity(0.2))
                    .frame(width: 122, height: 122)
                    .blur(radius: 18)
                    .scaleEffect(reduceMotion ? 1 : 1 + CGFloat(sin(phase * 1.1) * 0.08))
                    .offset(x: 25, y: -38)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Norderney", systemImage: "location.fill")
                                .font(.system(size: 17, weight: .heavy))
                            Text("Heute · Jetzt")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.72))
                        }
                        Spacer()
                        Image(systemName: "sun.max.fill")
                            .font(.system(size: 38, weight: .semibold))
                            .foregroundStyle(Color.yellow)
                            .rotationEffect(.degrees(reduceMotion ? 0 : phase * 7))
                            .scaleEffect(reduceMotion ? 1 : 1 + CGFloat(sin(phase * 1.25) * 0.035))
                            .shadow(color: Color.yellow.opacity(0.55), radius: 12)
                    }

                    HStack(alignment: .lastTextBaseline, spacing: 12) {
                        Text("21°")
                            .font(.system(size: 44, weight: .thin))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sonnig")
                                .font(.system(size: 16, weight: .bold))
                            Text("H: 23°  T: 17°")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.76))
                        }
                    }

                    HStack(spacing: 0) {
                        weatherHour("Jetzt", symbol: "sun.max.fill", temperature: "21°")
                        weatherHour("20:00", symbol: "sun.max.fill", temperature: "20°")
                        weatherHour("21:00", symbol: "cloud.sun.fill", temperature: "19°")
                        weatherHour("22:00", symbol: "moon.stars.fill", temperature: "18°")
                    }
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    HStack(spacing: 18) {
                        Label("Wind 11 kn", systemImage: "wind")
                        Label("Böen 15 kn", systemImage: "wind.circle.fill")
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
                }
                .foregroundStyle(.white)
                .padding(15)
            }
            .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 25, style: .continuous)
                    .stroke(Color.white.opacity(0.42), lineWidth: 1)
            }
        }
    }

    private func weatherHour(_ time: String, symbol: String, temperature: String) -> some View {
        VStack(spacing: 4) {
            Text(time)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.72))
            Image(systemName: symbol)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 16, weight: .semibold))
            Text(temperature)
                .font(.system(size: 12, weight: .heavy))
        }
        .frame(maxWidth: .infinity)
    }

    private func routeStart(in size: CGSize) -> CGPoint {
        CGPoint(x: 40, y: size.height * 0.72)
    }

    private func routeEnd(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width - 40, y: size.height * 0.28)
    }

    private func routeControlOne(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width * 0.35, y: size.height * 0.88)
    }

    private func routeControlTwo(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width * 0.62, y: size.height * 0.12)
    }

    private func routePoint(progress: CGFloat, in size: CGSize) -> CGPoint {
        let start = routeStart(in: size)
        let controlOne = routeControlOne(in: size)
        let controlTwo = routeControlTwo(in: size)
        let end = routeEnd(in: size)
        let inverse = 1 - progress
        let x = inverse * inverse * inverse * start.x
            + 3 * inverse * inverse * progress * controlOne.x
            + 3 * inverse * progress * progress * controlTwo.x
            + progress * progress * progress * end.x
        let y = inverse * inverse * inverse * start.y
            + 3 * inverse * inverse * progress * controlOne.y
            + 3 * inverse * progress * progress * controlTwo.y
            + progress * progress * progress * end.y
        return CGPoint(x: x, y: y)
    }

    private func wavePath(size: CGSize, baseline: CGFloat, amplitude: CGFloat, phase: Double) -> Path {
        var path = Path()
        let wavePhase = CGFloat(phase)
        path.move(to: CGPoint(x: 0, y: baseline))
        for x in stride(from: CGFloat.zero, through: size.width, by: 3) {
            let normalized = x / max(size.width, 1)
            let y = baseline
                + sin(normalized * .pi * 3 + wavePhase) * amplitude
                + sin(normalized * .pi * 5 - wavePhase * 0.65) * amplitude * 0.32
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        return path
    }

    private var crewIllustration: some View {
        VStack(spacing: 15) {
            GeometryReader { proxy in
                let size = proxy.size
                let left = CGPoint(x: size.width * 0.28, y: size.height * 0.62)
                let right = CGPoint(x: size.width * 0.72, y: size.height * 0.62)
                let pulse = reduceMotion || !isActive ? CGFloat.zero : CGFloat((sin(Date().timeIntervalSinceReferenceDate * 2.0) + 1) * 0.5)

                ZStack {
                    // Both chips float on one line just above the avatars and
                    // share the same offset, so they stay level with each other.
                    planningChip("Sa · 14:00", icon: "calendar", tint: Color.appPrimary)
                        .position(x: size.width * 0.31, y: size.height * 0.20 - pulse * 3)

                    planningChip("Langeoog", icon: "mappin.and.ellipse", tint: Color(hex: 0x0D9488))
                        .position(x: size.width * 0.70, y: size.height * 0.20 - pulse * 3)

                    Path { path in
                        path.move(to: CGPoint(x: left.x + 34, y: left.y - 6))
                        path.addCurve(
                            to: CGPoint(x: right.x - 34, y: right.y - 6),
                            control1: CGPoint(x: size.width * 0.42, y: size.height * 0.46),
                            control2: CGPoint(x: size.width * 0.58, y: size.height * 0.46)
                        )
                    }
                    .stroke(Color.appPrimary.opacity(0.16), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [7, 7]))

                    crewAvatar("person.fill", tint: Color.appPrimary)
                        .position(left)
                    crewAvatar("person.fill", tint: Color(hex: 0x0D9488))
                        .position(right)
                }
            }
            .frame(height: 112)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: isActive)

            HStack(spacing: 10) {
                crewFeature("person.3.fill", title: "Crew", tint: Color(hex: 0x0EA5E9))
                crewFeature("calendar.badge.checkmark", title: "Termine", tint: Color.orange)
                crewFeature("person.badge.shield.checkmark.fill", title: "Rollen", tint: Color(hex: 0x0D9488))
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func planningChip(_ text: String, icon: String, tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 12, weight: .heavy))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(tint, in: Capsule())
            .shadow(color: tint.opacity(0.22), radius: 10, y: 6)
    }

    private func crewAvatar(_ icon: String, tint: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 25, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 62, height: 62)
            .background(tint, in: Circle())
            .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 4))
    }

    private func crewFeature(_ icon: String, title: String, tint: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 23, weight: .bold)).foregroundStyle(tint)
            Text(title).font(.system(size: 10, weight: .heavy))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.fieldBackground.opacity(0.82), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
