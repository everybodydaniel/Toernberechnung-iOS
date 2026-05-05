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
    @Query(sort: \CalculationRecord.createdAt, order: .reverse) var calculations: [CalculationRecord]
    @Query(sort: \WeatherSnapshot.fetchedAt, order: .reverse) var weatherSnapshots: [WeatherSnapshot]
    @Query(sort: \CrewMemberRecord.createdAt, order: .forward) var crewMembers: [CrewMemberRecord]
    @AppStorage("appearanceMode") private var appearanceMode = "system"

    @State private var selectedTab: AppTab = .map
    @State private var settingsShown = false
    @State var startHarbourID = HarbourOption.options[0].id
    @State var destinationHarbourID = HarbourOption.options[3].id
    @State var weatherRegionID = HarbourOption.options[2].id
    @State var tideHarbourID = HarbourOption.options[2].id
    @State var departure = Date()
    @State var highWater = Date()
    @State var distanceNM = 14.5
    @State var speedKnots = 6.2
    @State var offsetMinutes = 25.0
    @State var mth = 2.4
    @State var referenceDepth = 2.7
    @State var bshWaterLevel = 0.3
    @State var chartDepth = 0.4
    @State var boatDraft = 1.1
    @State var depthMode: DepthMode = .mhw
    @State var exportedPDFURL: URL?
    @State var shareSheetPresented = false
    @State var weatherLoading = false
    @State var weatherReading: WeatherReading?
    @State var islandWeather: [String: WeatherReading] = [:]
    @State var weatherError: String?
    @State var tideLoading = false
    @State var tideReading: TideReading?
    @State var islandTides: [String: TideReading] = [:]
    @State var tideError: String?
    @State var newCrewName = ""
    @State var newCrewRole = CrewRoleOption.deck.rawValue
    @State var newCrewEmergencyContact = ""
    @State var newCrewEmergencyPhone = ""
    @State var newCrewNotes = ""

    private let crew: [CrewMember] = [
        .init(name: "Leon", role: "Navigator", status: "ONBOARD", accent: .blue),
        .init(name: "Benedikt", role: "First Mate", status: "ONBOARD", accent: .blue),
        .init(name: "Laura", role: "Gast", status: "OFF-DUTY", accent: .gray)
    ]

    var harbours: [HarbourOption] { HarbourOption.options }
    var startHarbour: HarbourOption { HarbourOption.byID(startHarbourID) }
    var destinationHarbour: HarbourOption { HarbourOption.byID(destinationHarbourID) }
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
        .task { await bootstrapIfNeeded() }
        .onChange(of: selectedTab) { _, tab in
            if tab == .weather {
                Task { await loadWeather(force: islandWeather.isEmpty) }
            } else if tab == .tides {
                Task { await loadIslandTides(force: islandTides.isEmpty) }
            }
        }
        .onChange(of: weatherRegionID) { _, _ in
            if selectedTab == .weather {
                Task { await loadWeather(force: islandWeather[weatherRegionID] == nil) }
            }
        }
        .onChange(of: tideHarbourID) { _, _ in
            Task { await loadTides(force: true) }
        }
        .onChange(of: destinationHarbourID) { _, _ in
            syncRouteDefaults()
            Task { await loadTides(force: true) }
        }
        .onChange(of: startHarbourID) { _, _ in
            syncRouteDefaults()
        }
        .onChange(of: departure) { _, _ in
            Task { await loadTides(force: false) }
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
            AppHeader(refreshAction: { Task { await refreshActiveTab() } }, settingsAction: {
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

    private func refreshActiveTab() async {
        switch selectedTab {
        case .weather:
            await loadWeather(force: true)
        case .tides:
            await loadIslandTides(force: true)
        case .map:
            await MainActor.run {
                writeAudit(action: "READ", source: "karte", statement: "SELECT ukc, wt, fmw FROM manual_passage_preview LIMIT 1", status: "ok")
            }
            await loadTides(force: true)
        default:
            await MainActor.run {
                writeAudit(action: "READ", source: "ui", statement: "SELECT tab, refreshed_at FROM ui_state WHERE tab = '\(selectedTab.label)' LIMIT 1", status: "ok")
            }
        }
    }
}
