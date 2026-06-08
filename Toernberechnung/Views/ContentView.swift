import SwiftUI
import SwiftData
import CoreLocation
import UIKit

private enum AppTab: Hashable {
    case map, weather, tides, crew, logbook

    var title: String {
        switch self {
        case .map: return "KARTE"
        case .weather: return "WETTER"
        case .tides: return "GEZEITEN"
        case .crew: return "CREW"
        case .logbook: return "LOGBUCH"
        }
    }

    var label: String {
        switch self {
        case .map: return "Karte"
        case .weather: return "Wetter"
        case .tides: return "Gezeiten"
        case .crew: return "Crew"
        case .logbook: return "Logbuch"
        }
    }

    var icon: String {
        switch self {
        case .map: return "map.fill"
        case .weather: return "cloud.sun.fill"
        case .tides: return "water.waves"
        case .crew: return "person.3.fill"
        case .logbook: return "book.closed.fill"
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
    @Query(sort: \CalculationRecord.createdAt, order: .reverse) var calculations: [CalculationRecord]
    @Query(sort: \WeatherSnapshot.fetchedAt, order: .reverse) var weatherSnapshots: [WeatherSnapshot]
    @Query(sort: \CrewMemberRecord.createdAt, order: .forward) var crewMembers: [CrewMemberRecord]
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab: AppTab = .map
    @State private var settingsShown = false
    @State var voyageDisclaimerShown = false
    @State var stopVoyageAlertShown = false
    @State var navigationFullScreenShown = false
    @State var mapFullScreenShown = false
    @State var viewModel = RoutePlannerViewModel()
    @State var weatherRegionID = HarbourOption.options[2].id
    @State var tideHarbourID = HarbourOption.options[2].id
    @State var exportedPDFURL: URL?
    @State var shareSheetPresented = false
    @State var weatherLoading = false
    @State var weatherReading: WeatherReading?
    @State var islandWeather: [String: WeatherReading] = [:]
    @State var weatherError: String?
    @State var windfinderReading: WindfinderService.Reading? = nil
    @State var windfinderLoading = false
    @State var tideLoading = false
    @State var tideReading: TideReading?
    @State var islandTides: [String: TideReading] = [:]
    @State var tideError: String?
    @State var waterLevelForecasts: [String: WaterLevelForecast] = [:]
    @State var waterLevelLoading = false
    @State var waterLevelError: String?
    @State var newCrewName = ""
    @State var newCrewRole = CrewRoleOption.deck.rawValue
    @State var newCrewEmergencyContact = ""
    @State var newCrewEmergencyPhone = ""
    @State var newCrewNotes = ""

    var harbours: [HarbourOption] { HarbourOption.options }
    var weatherHarbour: HarbourOption { HarbourOption.byID(weatherRegionID) }
    var tideHarbour: HarbourOption { HarbourOption.byID(tideHarbourID) }
    var compactColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: horizontalSizeClass == .regular ? 3 : 1)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            screen(for: .map, content: calculatorTab)
                .tag(AppTab.map)
                .tabItem { Label(AppTab.map.label, systemImage: AppTab.map.icon) }

            screen(for: .weather, content: weatherTab)
                .tag(AppTab.weather)
                .tabItem { Label(AppTab.weather.label, systemImage: AppTab.weather.icon) }

            screen(for: .tides, content: tidesTab)
                .tag(AppTab.tides)
                .tabItem { Label(AppTab.tides.label, systemImage: AppTab.tides.icon) }

            screen(for: .crew, content: crewTab)
                .tag(AppTab.crew)
                .tabItem { Label(AppTab.crew.label, systemImage: AppTab.crew.icon) }

            screen(for: .logbook, content: logbookTab)
                .tag(AppTab.logbook)
                .tabItem { Label(AppTab.logbook.label, systemImage: AppTab.logbook.icon) }
        }
        .tint(Color(hex: 0x3C82FF))
        // iOS 26: Tab Bar adopts Liquid Glass automatically. We just
        // opt in to the auto-minimize behaviour. iOS 18: no-op.
        .appTabBarMinimize()
        .background(Color.appBackground.ignoresSafeArea())
        .sheet(isPresented: $settingsShown) {
            SettingsSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(preferredColorScheme)
        }
        .preferredColorScheme(preferredColorScheme)
        .sheet(isPresented: $shareSheetPresented) {
            if let exportedPDFURL {
                ActivityView(activityItems: [exportedPDFURL])
            }
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
        .fullScreenCover(isPresented: $mapFullScreenShown) {
            FullScreenMapView(
                isPresented: $mapFullScreenShown,
                start: viewModel.startHarbour,
                destination: viewModel.destinationHarbour,
                routePlan: viewModel.routePlan,
                waypointResults: viewModel.calculationResult?.waypointResults,
                breadcrumbs: voyageManager.breadcrumbs.map(\.coordinate)
            )
            .preferredColorScheme(preferredColorScheme)
        }
        .alert("Aktive Fahrt beenden?", isPresented: $stopVoyageAlertShown) {
            Button("Fahrt beenden", role: .destructive) {
                finishActiveVoyage()
            }
            Button("Weiter aufzeichnen", role: .cancel) { }
        } message: {
            Text("Die aufgezeichnete Strecke wird ins Logbuch übernommen und das GPS-Tracking gestoppt.")
        }
        .task { await bootstrapIfNeeded() }
        .onChange(of: selectedTab) { _, tab in
            if tab == .weather {
                Task {
                    await loadWeather(force: islandWeather.isEmpty)
                    await loadWindfinder(for: weatherRegionID, force: false)
                }
            } else if tab == .tides {
                Task {
                    await loadIslandTides(force: islandTides.isEmpty)
                    await loadWaterLevelForecast(for: HarbourOption.byID(tideHarbourID), force: false)
                }
            }
        }
        .onChange(of: weatherRegionID) { _, newID in
            if selectedTab == .weather {
                Task {
                    await loadWeather(force: islandWeather[newID] == nil)
                    await loadWindfinder(for: newID, force: false)
                }
            }
        }
        .onChange(of: viewModel.destinationHarbourID) { _, _ in
            syncRouteDefaults()
            syncRouteWeatherStatus()
            Task {
                await loadTides(force: true)
                await loadWaterLevelForecast(for: destinationHarbour, force: false)
            }
        }
        .onChange(of: viewModel.startHarbourID) { _, _ in
            syncRouteDefaults()
        }
        .onChange(of: viewModel.departure) { _, _ in
            Task { await loadTides(force: false) }
        }
        .onChange(of: tideHarbourID) { _, newID in
            if selectedTab == .tides {
                let harbour = HarbourOption.byID(newID)
                Task {
                    await loadAstronomicalTide(for: harbour)
                    await loadWaterLevelForecast(for: harbour, force: false)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // When the app comes back to the foreground, re-check the BSH
            // peak forecast for whatever the user is currently looking at.
            // Cache TTL keeps the actual network calls cheap.
            guard phase == .active else { return }
            Task {
                let harbour = HarbourOption.byID(tideHarbourID)
                await loadWaterLevelForecast(for: harbour, force: false)
                if selectedTab == .map {
                    await loadWaterLevelForecast(for: destinationHarbour, force: false)
                }
            }
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private func screen(for tab: AppTab, @ViewBuilder content: @escaping () -> some View) -> some View {
        VStack(spacing: 0) {
            AppHeader(refreshAction: { Task { await reloadEntirePage() } }, settingsAction: {
                settingsShown = true
            })
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Text(tab.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                    content()
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 28)
            }
            .background(Color.appBackground)
        }
    }

    /// Full page reload (the header refresh button). Regardless of the active
    /// tab, this re-syncs the route defaults, recomputes the route + passage
    /// window and force-refreshes every data source the app shows — weather,
    /// wind, island tides, the destination/Pegel tides and the BSH
    /// water-level forecasts — so the whole page reflects fresh data.
    @MainActor
    private func reloadEntirePage() async {
        writeAudit(action: "READ", source: "ui", statement: "SELECT * FROM page_state -- full reload", status: "ok")

        syncRouteDefaults()
        viewModel.onRouteChanged()

        await loadWeather(force: true)
        await loadWindfinder(for: weatherRegionID, force: true)
        await loadTides(force: true)
        await loadIslandTides(force: true)
        await loadWaterLevelForecast(for: destinationHarbour, force: true)
        await loadWaterLevelForecast(for: HarbourOption.byID(tideHarbourID), force: true)
    }
}
