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
        case .conditions: return "Wetter"
        case .crew: return "Crewspace"
        case .logbook: return "Logbuch"
        }
    }

    var icon: String {
        switch self {
        case .map: return "map.fill"
        case .conditions: return "cloud.sun.rain.fill"
        case .crew: return "person.2.badge.gearshape.fill"
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

struct ContentView: View {
    @Environment(\.modelContext) var modelContext
    @Environment(LocationService.self) var locationService
    @Environment(NavigationTracker.self) var navigationTracker
    @Environment(ActiveVoyageManager.self) var voyageManager
    @Environment(\.maritimeWeatherService) var maritimeWeatherService
    @Query(sort: \CalculationRecord.createdAt, order: .reverse) var calculations: [CalculationRecord]
    @Query(sort: \WeatherSnapshot.fetchedAt, order: .reverse) var weatherSnapshots: [WeatherSnapshot]
    @Query(sort: \CrewMemberRecord.createdAt, order: .forward) var crewMembers: [CrewMemberRecord]
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    @State var selectedTab: AppTab = .map
    @State var weatherHeaderVisible = true
    @State var crewHeaderVisible = true
    @State var logbookHeaderVisible = true
    @State var selectedConditionsSection: ConditionsSection = .weather
    @State var settingsShown = false
    @State var warningsSheetShown = false
    @State var maritimeWarningsService = MaritimeWarningsService.shared
    @State var mapFocusCoordinate: CLLocationCoordinate2D?
    @State var selectedMapWarning: MaritimeWarning?
    @State var nautiDashboardMode: NautiDashboardMode = .dashboard
    @State var dashboardDetentBeforeNauti: DashboardDetent = .nautiOnly
    @State var nautiFocusDismissTrigger = 0
    @State var mapPlanningShown = false
    @State var intermediateStopPickerShown = false
    /// Drives the map dashboard's bottom inset so the Nauti chat input keeps
    /// sitting directly above the software keyboard instead of behind it.
    @State var keyboardVisible = false
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
    var body: some View {
        mainContent
    }

    // Split from `mainContent` purely so the Swift type checker can cope: the
    // combined presentation + lifecycle chain exceeded its budget.
    private var presentationSurface: some View {
        appNavigation
        .background(Color.appBackground.ignoresSafeArea())
        .blur(radius: selectedWeatherDay == nil ? 0 : 12)
        .animation(.easeInOut(duration: 0.24), value: selectedWeatherDay != nil)
        .sheet(isPresented: $settingsShown) {
            SettingsSheet {
                if let plan = viewModel.routePlan {
                    viewModel.runCalculation(plan: plan)
                }
            }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $warningsSheetShown) {
            MaritimeWarningsSheetView(
                service: maritimeWarningsService,
                onSelectCoordinate: { coord in
                    warningsSheetShown = false
                    selectedTab = .map
                    mapFocusCoordinate = coord
                },
                onSelectWarning: { warning in
                    warningsSheetShown = false
                    selectedTab = .map
                    if let coord = warning.coordinate {
                        mapFocusCoordinate = coord
                    }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        selectedMapWarning = warning
                    }
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $mapPlanningShown) {
            manualPlanningSheet
                .presentationSizing(.page)
                .presentationDetents([.large])
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
                selection: $tideStationID
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
    }

    private var dataLifecycleSurface: some View {
        presentationSurface
        .task {
            await bootstrapIfNeeded()
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
    }

    // A third segment, again only to keep each modifier chain inside the type
    // checker's budget.
    private var mainContent: some View {
        dataLifecycleSurface
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
            handleScenePhaseChange(phase)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            nautiSpeechController.cancel()
            nautiViewModel.releaseResources()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
    }

    @MainActor
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        if phase != .active {
            nautiSpeechController.cancel()
        }
        // When the app comes back to the foreground, re-check the BSH peak
        // forecast for whatever the user is currently looking at. Cache TTL
        // keeps the actual network calls cheap.
        guard phase == .active else { return }
        Task {
            await aiAccess.refresh()
            await maritimeWarningsService.refreshIfNeeded()
            await loadWaterLevelForecast(for: tideStationID, force: false)
            if selectedTab == .map {
                await loadWaterLevelForecast(for: destinationHarbour.tideStationID, force: false)
            }
            // Weather used to be revalidated only on tab entry, so a long
            // background stint left a stale forecast on screen. The TTL cache
            // makes this free when the data is still fresh.
            if selectedTab == .conditions, selectedConditionsSection == .weather {
                await loadWeather(userInitiated: false)
            }
        }
    }

    @ViewBuilder
    private var appNavigation: some View {
        if isPad {
            currentScreen
                .overlay(alignment: .bottom) {
                    if !keyboardVisible {
                        FloatingAppTabBar(selection: $selectedTab, showsLabels: true)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                            .zIndex(4)
                    }
                }
        } else if #available(iOS 26.0, *) {
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
            .toolbarBackgroundVisibility(.hidden, for: .tabBar)
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
        if isPad { return 104 }
        if #available(iOS 26.0, *) {
            return 0
        }
        return 104
    }

    var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    @ViewBuilder
    private func screen(for tab: AppTab, @ViewBuilder content: @escaping () -> some View) -> some View {
        if tab == .map {
            ZStack(alignment: .top) {
                // `.container` only — the bare `.ignoresSafeArea()` also
                // covers the `.keyboard` region, which opted the whole map
                // tab (and with it the Nauti chat input) out of keyboard
                // avoidance. The chart itself still bleeds edge to edge via
                // its own `.ignoresSafeArea()` inside `calculatorTab()`.
                content()
                    .ignoresSafeArea(.container)

                VStack(spacing: 12) {
                    appHeader(brandStyle: .white)
                    if isPad {
                        mapRouteControls
                            .padding(.horizontal, 16)
                            .opacity(nautiDashboardMode.isExpanded ? 0 : 1)
                            .allowsHitTesting(!nautiDashboardMode.isExpanded)
                    }
                }
                .zIndex(1)
            }
            .background(Color.black.ignoresSafeArea())
        } else if tab == .conditions {
            ZStack(alignment: .top) {
                content()

                scrollingAppHeader(brandStyle: .white, isVisible: weatherHeaderVisible)
                    .zIndex(1)
            }
            .background(Color.appBackground.ignoresSafeArea())
        } else if tab == .crew {
            ZStack(alignment: .top) {
                content()
                    .padding(.bottom, crewspaceContainerBottomPadding)

                scrollingAppHeader(brandStyle: .primary, isVisible: crewHeaderVisible)
                    .zIndex(1)
            }
            .background(Color.appBackground.ignoresSafeArea())
        } else if tab == .logbook {
            ZStack(alignment: .top) {
                content()

                scrollingAppHeader(brandStyle: .primary, isVisible: logbookHeaderVisible)
                    .zIndex(1)
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
                    .zIndex(1)
            }
            .background(Color.appBackground.ignoresSafeArea())
        }
    }

    private func scrollingAppHeader(brandStyle: AppHeaderBrandStyle, isVisible: Bool) -> some View {
        appHeader(brandStyle: brandStyle)
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : -16)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
            .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.24), value: isVisible)
    }

    private func appHeader(brandStyle: AppHeaderBrandStyle) -> some View {
        AppHeader(
            brandStyle: brandStyle,
            settingsAction: { settingsShown = true },
            warningsAction: { warningsSheetShown = true },
            unreadWarningsCount: maritimeWarningsService.unreadCount
        )
        .padding(.top, isPad ? 16 : 0)
    }
}
