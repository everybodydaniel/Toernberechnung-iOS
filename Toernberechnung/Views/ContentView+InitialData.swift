import SwiftUI
import SwiftData

extension ContentView {
    @MainActor
    func bootstrapIfNeeded() async {
        #if DEBUG
        handleScreenshotLaunchEnvironment()
        #endif

        // Es wird keine Route vorbelegt. Wetter und Gezeiten behalten ihre eigenen
        // Standardorte, bis der Skipper einen Törn plant.
        await nautiViewModel.loadHistory()
        await aiAccess.refresh()
        await maritimeWeatherService.prepare()
        await loadWeather(userInitiated: false)
        await loadTides(force: tideReading == nil)
        await loadWaterLevelForecast(for: tideStationID, force: false)
        removeLegacyCrewSeedIfNeeded()
    }

    #if DEBUG
    @MainActor
    private func handleScreenshotLaunchEnvironment() {
        let env = ProcessInfo.processInfo.environment

        if env["SEED_DEMO_DATA"] == "1" {
            let events = (try? modelContext.fetch(FetchDescriptor<CrewEventRecord>())) ?? []
            let hasToday = events.contains { Calendar.current.isDateInToday($0.startsAt) }
            if !hasToday {
                let cal = Calendar.current
                let today = Date()
                let startToday = cal.date(bySettingHour: 16, minute: 0, second: 0, of: today) ?? today
                let endToday = cal.date(bySettingHour: 17, minute: 30, second: 0, of: today) ?? today
                modelContext.insert(CrewEventRecord(
                    title: "Sicherheitsbriefing & Check",
                    startsAt: startToday,
                    endsAt: endToday,
                    location: "Borkum Fischerbalje",
                    notes: "Rettungswesten, Seefunk, Notausrüstung",
                    category: CrewEventCategory.briefing.rawValue,
                    attendees: ["Daniel", "Markus"]
                ))
            }
            if events.isEmpty {
                let cal = Calendar.current
                let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                let start = cal.date(bySettingHour: 10, minute: 30, second: 0, of: tomorrow) ?? tomorrow
                let end = cal.date(bySettingHour: 15, minute: 0, second: 0, of: tomorrow) ?? tomorrow
                modelContext.insert(CrewEventRecord(
                    title: "Törnstart Norderney",
                    startsAt: start,
                    endsAt: end,
                    location: "Borkum ➔ Norderney",
                    notes: "Gemeinsames Ablegen bei Hochwasser",
                    category: CrewEventCategory.departure.rawValue,
                    attendees: ["Daniel", "Markus"]
                ))
            }
            let crew = try? modelContext.fetch(FetchDescriptor<CrewMemberRecord>())
            if crew?.isEmpty ?? true {
                modelContext.insert(CrewMemberRecord(name: "Daniel Horst", role: "Skipper", emergencyContact: "Sarah Horst", emergencyPhone: "+49 170 1234567", notes: "SKS, SRC, Ersthelfer", isOnBoard: true))
                modelContext.insert(CrewMemberRecord(name: "Markus Weber", role: "Navigator", emergencyContact: "Familie Weber", emergencyPhone: "+49 171 9876543", notes: "Funk & Navigation", isOnBoard: true))
            }
            let calculations = try? modelContext.fetch(FetchDescriptor<CalculationRecord>())
            if calculations?.isEmpty ?? true {
                let cal = Calendar.current
                let yesterday = cal.date(byAdding: .day, value: -1, to: Date()) ?? Date()
                let dep = cal.date(bySettingHour: 10, minute: 15, second: 0, of: yesterday) ?? yesterday
                let arr = cal.date(bySettingHour: 14, minute: 30, second: 0, of: yesterday) ?? yesterday
                modelContext.insert(CalculationRecord(
                    routeTitle: "Borkum nach Norderney",
                    startName: "Borkum, Fischerbalje",
                    destinationName: "Norderney, Hafen",
                    departureAt: dep,
                    arrivalAt: arr,
                    distanceNM: 22.4,
                    status: "Erfolgreich abgeschlossen",
                    fmw: 2.4,
                    wt: 1.8,
                    wuk: 0.6,
                    weatherSummary: "Wind SSW 4 Bft (14 kn), 16°C, Sicht gut",
                    tideSummary: "HW Borkum 10:45, NW Norderney 16:26",
                    crewSummary: "Daniel Horst (Skipper), Markus Weber (Crew)",
                    notes: "Gute Reise durchs Memmert Wattfahrwasser bei auflaufendem Wasser.",
                    createdAt: arr,
                    isActualVoyage: true,
                    actualDistanceNM: 22.8,
                    averageSOGKnots: 5.8,
                    maxSOGKnots: 7.4,
                    voyageDurationSeconds: 15300
                ))

                let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                let dep2 = cal.date(bySettingHour: 11, minute: 0, second: 0, of: tomorrow) ?? tomorrow
                let arr2 = cal.date(bySettingHour: 14, minute: 15, second: 0, of: tomorrow) ?? tomorrow
                modelContext.insert(CalculationRecord(
                    routeTitle: "Norderney nach Langeoog",
                    startName: "Norderney, Hafen",
                    destinationName: "Langeoog, Hafen",
                    departureAt: dep2,
                    arrivalAt: arr2,
                    distanceNM: 18.2,
                    status: "Geplant für morgen",
                    fmw: 2.1,
                    wt: 1.6,
                    wuk: 0.5,
                    weatherSummary: "Wind WSW 3-4 Bft (12 kn), 17°C",
                    tideSummary: "HW Norderney 11:30",
                    crewSummary: "Daniel Horst (Skipper), Markus Weber (Crew)",
                    notes: "Passage über das Baltrumer Wattfahrwasser geplant.",
                    createdAt: Date(),
                    isActualVoyage: false
                ))
            }
            try? modelContext.save()
        }

        if let tabArg = env["LAUNCH_TAB"] {
            switch tabArg {
            case "map_route":
                selectedTab = .map
                viewModel.startHarbourID = "borkum_harbor"
                viewModel.destinationHarbourID = "norderney_harbor"
                viewModel.onRouteChanged()
                routeDashboardRevealPending = true
                dashboardDetent = .full
            case "map_planning":
                selectedTab = .map
                viewModel.startHarbourID = "borkum_harbor"
                viewModel.destinationHarbourID = "norderney_harbor"
                mapPlanningShown = true
            case "weather":
                selectedTab = .conditions
                selectedConditionsSection = .weather
            case "tides":
                selectedTab = .conditions
                selectedConditionsSection = .tides
            case "crew", "crew_planning":
                selectedTab = .crew
            case "warnings":
                warningsSheetShown = true
            case "nauti":
                selectedTab = .map
                nautiDashboardMode = .chat
            case "logbook":
                selectedTab = .logbook
            case "logbook_detail":
                selectedTab = .logbook
                let calculations = try? modelContext.fetch(FetchDescriptor<CalculationRecord>())
                selectedLogbookRecord = calculations?.first
            default:
                break
            }
        }
    }
    #endif

    @MainActor
    func writeAudit(action: String, source: String, statement: String, status: String) {
        modelContext.insert(AuditLog(action: action, source: source, statement: statement, status: status))
    }

    @MainActor
    private func removeLegacyCrewSeedIfNeeded() {
        let migrationKey = "crewspace.removedLegacyDemoCrew.v1"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: migrationKey) }

        guard crewMembers.count == 2 else { return }
        let legacyRows = crewMembers.filter { member in
            member.isOnBoard
                && member.emergencyContact.isEmpty
                && member.emergencyPhone.isEmpty
                && member.notes.isEmpty
                && ((member.name == "Skipper" && member.role == CrewRoleOption.navigation.rawValue)
                    || (member.name == "Crew" && member.role == CrewRoleOption.deck.rawValue))
        }
        guard legacyRows.count == 2 else { return }
        legacyRows.forEach(modelContext.delete)
        try? modelContext.save()
    }
}
