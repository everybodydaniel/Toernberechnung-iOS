import SwiftUI
import SwiftData
import CoreLocation
import UIKit

enum AppTab: Hashable, CaseIterable {
    case map, conditions, crew, logbook

    var title: String {
        switch self {
        case .map: return "KARTE"
        case .conditions: return "REVIER"
        case .crew: return "CREWSPACE"
        case .logbook: return "LOGBUCH"
        }
    }

    var label: String {
        switch self {
        case .map: return "Karte"
        case .conditions: return "Revier"
        case .crew: return "Crewspace"
        case .logbook: return "Logbuch"
        }
    }

    var icon: String {
        switch self {
        case .map: return "map.fill"
        case .conditions: return "cloud.sun.rain.fill"
        case .crew: return "bubble.left.and.bubble.right.fill"
        case .logbook: return "book.closed.fill"
        }
    }
}

enum ConditionsSection: String, CaseIterable, Identifiable {
    case weather
    case tides

    var id: Self { self }

    var label: String {
        switch self {
        case .weather: return "Wetter"
        case .tides: return "Gezeiten"
        }
    }

    var icon: String {
        switch self {
        case .weather: return "cloud.sun.fill"
        case .tides: return "water.waves"
        }
    }
}

private struct CrewMember: Identifiable {
    let id = UUID()
    let name: String
    let role: String
    let status: String
    let accent: Color
}

struct ContentView: View {
    @Environment(\.modelContext) var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(LocationService.self) var locationService
    @Environment(NavigationTracker.self) var navigationTracker
    @Environment(ActiveVoyageManager.self) var voyageManager
    @Environment(SocialAuthViewModel.self) var socialAuth
    @Environment(CrewspaceStore.self) var crewspaceStore
    @Environment(MaritimeNoticeCenter.self) var maritimeNoticeCenter
    @Environment(\.maritimeWeatherService) var maritimeWeatherService
    @Query(sort: \CalculationRecord.createdAt, order: .reverse) var calculations: [CalculationRecord]
    @Query(sort: \WeatherSnapshot.fetchedAt, order: .reverse) var weatherSnapshots: [WeatherSnapshot]
    @Query(sort: \CrewMemberRecord.createdAt, order: .forward) var crewMembers: [CrewMemberRecord]
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    @State var selectedTab: AppTab = .map
    @State var selectedConditionsSection: ConditionsSection = .weather
    @State var settingsShown = false
    @State var maritimeNoticesShown = false
    @State var selectedMaritimeNotice: MaritimeNoticeSummary?
    @State var maritimeNoticeDetent: PresentationDetent = .medium
    @State var nautiDashboardMode: NautiDashboardMode = .dashboard
    @State var dashboardDetentBeforeNauti: DashboardDetent = .nautiOnly
    @State var nautiFocusDismissTrigger = 0
    @State var mapPlanningShown = false
    @State var intermediateStopPickerShown = false
    @State var mapHeaderHidden = false
    @State var pendingNautiAction: NautiPendingAction?
    @State var pendingNautiConversationID: UUID?
    @State var dismissedNautiIssueID: String?
    @State var aiAccess = AIAccessController()
    @State var nautiViewModel = NautiChatViewModel()
    @State var nautiSpeechController = NautiSpeechInputController()
    @State var voyageDisclaimerShown = false
    @State var stopVoyageAlertShown = false
    @State var navigationFullScreenShown = false
    @State var viewModel = RoutePlannerViewModel()
    @State var dashboardDetent: DashboardDetent = .nautiOnly
    @State var dashboardDragOffset: CGFloat = 0
    @State var routeDashboardRevealPending = false
    @State var weatherRegionID = HarbourOption.options[2].id
    @State var tideStationID = "111P"
    @State var tideStationPickerShown = false
    @State var activityShareItem: ActivityShareItem?
    @State var selectedLogbookRecord: CalculationRecord?
    @State var logbookExportInProgress = false
    @State var logbookDeleteError: String?
    @State var editingLogbookRecord: CalculationRecord?
    @State var logbookEditorShown = false
    @State var weatherLoading = false
    @State var weatherReport: MarineWeatherReport?
    @State var islandWeatherReports: [String: MarineWeatherReport] = [:]
    @State var islandCurrentWeather: [String: MarineCurrentWeather] = [:]
    @State var islandWindForecasts: [String: [MarineHourlyForecast]] = [:]
    @State var islandCurrentWeatherLoading = false
    @State var windMapLoading = false
    @State var weatherError: String?
    @State var weatherAttribution: MarineWeatherAttribution?
    @State var selectedWindMapHour: Date?
    @State var selectedWeatherDay: WeatherDaySelection?
    @State var weatherLocationPickerShown = false
    @State var weatherRefreshFeedbackTrigger = 0
    @State var weatherRefreshToast: String?
    @State var weatherRefreshToastID = UUID()
    @State var tideLoading = false
    @State var tideReading: TideReading?
    @State var islandTides: [String: TideReading] = [:]
    @State var tideError: String?
    @State var waterLevelForecasts: [String: WaterLevelForecast] = [:]
    @State var waterLevelLoading = false
    @State var waterLevelError: String?
    @AppStorage("crewspace.activeCrewGroupID") var activeCrewGroupID = ""

    var harbours: [HarbourOption] { HarbourOption.options }
    var weatherHarbour: HarbourOption { HarbourOption.byID(weatherRegionID) }
    var tideStation: BSHTideStation {
        BSHTideStationCatalog.station(id: tideStationID)
            ?? BSHTideStationCatalog.stations[0]
    }
    var tideHarbour: HarbourOption {
        HarbourOption.options.first(where: { $0.tideStationID == tideStationID })
            ?? HarbourOption.options[2]
    }
    var compactColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: horizontalSizeClass == .regular ? 3 : 1)
    }

    var body: some View {
        mainContent
            .task {
                if crewspaceStore.pendingConversationID != nil {
                    selectedTab = .crew
                }
            }
            .onChange(of: crewspaceStore.pendingConversationID) { _, conversationID in
                if conversationID != nil {
                    selectedTab = .crew
                }
            }
    }

    private var mainContent: some View {
        appNavigation
        .background(Color.appBackground.ignoresSafeArea())
        .blur(radius: selectedWeatherDay == nil ? 0 : 12)
        .animation(.easeInOut(duration: 0.24), value: selectedWeatherDay != nil)
        .sheet(isPresented: $settingsShown) {
            SettingsSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $maritimeNoticesShown, onDismiss: {
            selectedMaritimeNotice = nil
        }) {
            MaritimeNoticesView(initialNotice: selectedMaritimeNotice)
                .environment(maritimeNoticeCenter)
                .presentationDetents([.medium, .large], selection: $maritimeNoticeDetent)
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(30)
        }
        .sheet(isPresented: $mapPlanningShown) {
            manualPlanningSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedWeatherDay) { selection in
            WeatherDayDetailView(selection: selection)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.clear)
                .presentationCornerRadius(32)
        }
        .sheet(isPresented: $tideStationPickerShown) {
            TideStationPickerSheet(
                selection: $tideStationID,
                readings: islandTides
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.clear)
            .presentationCornerRadius(30)
        }
        // Action confirmations stay modal; the conversation itself lives inline
        // in the map dashboard.
        .sheet(item: $pendingNautiAction) { action in
            NautiActionConfirmationSheet(
                pendingAction: action,
                onConfirm: { confirmNautiAction(action) },
                onCancel: {
                    pendingNautiAction = nil
                    pendingNautiConversationID = nil
                }
            )
            .presentationDetents([.height(360)])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $activityShareItem) { item in
            ActivityView(activityItems: [item.url])
        }
        .alert("Achtung – Sicherheitshinweis", isPresented: $voyageDisclaimerShown) {
            Button("Akzeptieren & Fahrt starten", role: .destructive) {
                startActiveVoyage()
                navigationFullScreenShown = true
            }
            Button("Abbrechen", role: .cancel) { }
        } message: {
            Text("Achtung: Diese Route ist eine Planungshilfe. Navigieren Sie stets nach Sicht und aktuellen Seezeichen. Die App ersetzt keine offizielle Seekarte.")
        }
        .fullScreenCover(isPresented: $navigationFullScreenShown) {
            FullScreenNavigationView(
                start: viewModel.startHarbour,
                destination: viewModel.destinationHarbour,
                routePlan: viewModel.routePlan,
                waypointResults: viewModel.calculationResult?.waypointResults,
                onStopVoyage: { finishActiveVoyage() }
            )
            .environment(locationService)
            .environment(navigationTracker)
            .environment(voyageManager)
            .preferredColorScheme(.dark)
        }
        .alert("Aktive Fahrt beenden?", isPresented: $stopVoyageAlertShown) {
            Button("Fahrt beenden", role: .destructive) {
                finishActiveVoyage()
            }
            Button("Weiter aufzeichnen", role: .cancel) { }
        } message: {
            Text("Die aufgezeichnete Strecke wird ins Logbuch übernommen und das GPS-Tracking gestoppt.")
        }
        .task {
            await bootstrapIfNeeded()
            await maritimeNoticeCenter.setActive(scenePhase == .active)
        }
        .task(id: routeWeatherRequestKey) {
            await validateCurrentRouteWeather()
        }
        .onChange(of: selectedTab) { _, tab in
            if tab != .conditions {
                weatherLocationPickerShown = false
            }
            if tab == .conditions {
                Task { await loadSelectedConditionsSection() }
            }
        }
        .onChange(of: selectedConditionsSection) { _, _ in
            guard selectedTab == .conditions else { return }
            Task { await loadSelectedConditionsSection() }
        }
        .onChange(of: weatherRegionID) { _, _ in
            if selectedTab == .conditions && selectedConditionsSection == .weather {
                Task {
                    await loadWeather(userInitiated: false)
                }
            }
        }
        .onChange(of: viewModel.destinationHarbourID) { _, _ in
            syncRouteDefaults()
            if let destination = viewModel.selectedDestinationHarbour {
                Task {
                    await loadAstronomicalTide(for: destination)
                    await loadWaterLevelForecast(for: destination, force: false)
                }
            }
        }
        .onChange(of: viewModel.startHarbourID) { _, _ in
            syncRouteDefaults()
        }
        .onChange(of: viewModel.departure) { _, _ in
            Task { await loadTides(force: false) }
        }
        .onChange(of: proactiveNautiIssue?.id) { _, _ in
            dismissedNautiIssueID = nil
        }
        .onChange(of: nautiDashboardMode) { oldMode, newMode in
            if oldMode.isExpanded, newMode == .dashboard {
                revealRouteDashboardIfPending()
            }
        }
        .onChange(of: selectedTab) { _, newTab in
            if newTab != .map, nautiDashboardMode.isExpanded {
                closeNautiChat()
            }
        }
        .onChange(of: mapPlanningShown) { _, isShown in
            if !isShown { revealRouteDashboardIfPending() }
        }
        .onChange(of: viewModel.routePlan?.id) { _, routeID in
            handleRoutePresentationChange(routeID: routeID)
        }
        .onChange(of: viewModel.isCalculating) { _, isCalculating in
            handleRouteCalculationStateChange(isCalculating: isCalculating)
        }
        .onChange(of: tideStationID) { _, newID in
            if selectedTab == .conditions && selectedConditionsSection == .tides {
                Task {
                    await loadAstronomicalTide(for: newID)
                    await loadWaterLevelForecast(for: newID, force: false)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            Task { await maritimeNoticeCenter.setActive(phase == .active) }
            if phase != .active {
                nautiSpeechController.cancel()
            }
            // When the app comes back to the foreground, re-check the BSH
            // peak forecast for whatever the user is currently looking at.
            // Cache TTL keeps the actual network calls cheap.
            guard phase == .active else { return }
            Task {
                await aiAccess.refresh()
                await loadWaterLevelForecast(for: tideStationID, force: false)
                if selectedTab == .map {
                    await loadWaterLevelForecast(for: destinationHarbour.tideStationID, force: false)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            nautiSpeechController.cancel()
            nautiViewModel.releaseResources()
        }
    }

    @ViewBuilder
    private var appNavigation: some View {
        if #available(iOS 26.0, *) {
            TabView(selection: $selectedTab) {
                Tab(AppTab.map.label, systemImage: AppTab.map.icon, value: AppTab.map) {
                    screen(for: .map, content: calculatorTab)
                }

                Tab(AppTab.conditions.label, systemImage: AppTab.conditions.icon, value: AppTab.conditions) {
                    screen(for: .conditions, content: conditionsTab)
                }

                Tab(AppTab.crew.label, systemImage: AppTab.crew.icon, value: AppTab.crew) {
                    screen(for: .crew, content: crewTab)
                }

                Tab(AppTab.logbook.label, systemImage: AppTab.logbook.icon, value: AppTab.logbook) {
                    screen(for: .logbook, content: logbookTab)
                }
            }
            .tint(Color(hex: 0x0077B6))
            .tabBarMinimizeBehavior(.onScrollDown)
        } else {
            currentScreen
                .overlay(alignment: .bottom) {
                    FloatingAppTabBar(selection: $selectedTab)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(4)
                }
        }
    }

    @ViewBuilder
    private var currentScreen: some View {
        switch selectedTab {
        case .map:
            screen(for: .map, content: calculatorTab)
        case .conditions:
            screen(for: .conditions, content: conditionsTab)
        case .crew:
            screen(for: .crew, content: crewTab)
        case .logbook:
            screen(for: .logbook, content: logbookTab)
        }
    }

    @MainActor
    func loadSelectedConditionsSection(userInitiated: Bool = false) async {
        switch selectedConditionsSection {
        case .weather:
            await loadWeather(userInitiated: userInitiated)
        case .tides:
            await loadIslandTides(force: userInitiated || islandTides.isEmpty)
            await loadWaterLevelForecast(for: tideStationID, force: userInitiated)
        }
    }

    private var crewspaceContainerBottomPadding: CGFloat {
        if #available(iOS 26.0, *) {
            return 0
        }
        return 104
    }

    @ViewBuilder
    private func screen(for tab: AppTab, @ViewBuilder content: @escaping () -> some View) -> some View {
        if tab == .map {
            ZStack(alignment: .top) {
                content()
                    .ignoresSafeArea()

                appHeader(brandStyle: .white)
                .opacity(mapHeaderHidden ? 0 : 1)
                .offset(y: mapHeaderHidden ? -34 : 0)
                .allowsHitTesting(!mapHeaderHidden)
                .animation(.spring(response: 0.28, dampingFraction: 0.86), value: mapHeaderHidden)
            }
            .background(Color.black.ignoresSafeArea())
        } else if tab == .conditions {
            ZStack(alignment: .top) {
                content()

                appHeader(brandStyle: .white)
            }
            .background(Color.appBackground.ignoresSafeArea())
        } else if tab == .crew {
            ZStack(alignment: .top) {
                content()
                    .padding(.top, 72)
                    .padding(.bottom, crewspaceContainerBottomPadding)

                appHeader(brandStyle: .primary)
            }
            .background(Color.appBackground.ignoresSafeArea())
        } else if tab == .logbook {
            ZStack(alignment: .top) {
                content()

                appHeader(brandStyle: .primary)
            }
            .background(Color.appBackground.ignoresSafeArea())
        } else {
            ZStack(alignment: .top) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        Text(tab.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.secondary)
                        content()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 72)
                    .padding(.bottom, 118)
                }

                appHeader(brandStyle: .primary)
            }
            .background(Color.appBackground.ignoresSafeArea())
        }
    }

    private func appHeader(brandStyle: AppHeaderBrandStyle) -> some View {
        AppHeader(
            brandStyle: brandStyle,
            unreadNoticeCount: maritimeNoticeCenter.unreadCount,
            noticePulseTrigger: maritimeNoticeCenter.pulseTrigger,
            noticesAction: { notice in
                selectedMaritimeNotice = notice
                maritimeNoticeDetent = .medium
                maritimeNoticesShown = true
            },
            refreshAction: { Task { await reloadEntirePage() } },
            settingsAction: { settingsShown = true }
        )
    }

    /// Full page reload (the header refresh button). Regardless of the active
    /// tab, this re-syncs the route defaults, recomputes the route + passage
    /// window and force-refreshes every data source the app shows — Apple
    /// Weather, island tides, the destination/Pegel tides and the BSH
    /// water-level forecasts — so the whole page reflects fresh data.
    @MainActor
    func reloadEntirePage() async {
        writeAudit(action: "READ", source: "ui", statement: "SELECT * FROM page_state -- full reload", status: "ok")

        if viewModel.hasCompleteRouteInput {
            viewModel.onRouteChanged()
        }

        await loadWeather(userInitiated: true)
        await loadTides(force: true)
        await loadIslandTides(force: true)
        await loadWaterLevelForecast(for: tideStationID, force: true)
        await maritimeNoticeCenter.refresh(force: true)
    }
}
