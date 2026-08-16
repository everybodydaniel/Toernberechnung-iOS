import SwiftUI

extension ContentView {
    @MainActor
    func bootstrapIfNeeded() async {
        // A route is deliberately not seeded. Weather and tides keep their
        // own independent default locations until the skipper plans a trip.
        await nautiViewModel.loadHistory()
        await aiAccess.refresh()
        await maritimeWeatherService.prepare()
        await loadWeather(userInitiated: false)
        await loadTides(force: tideReading == nil)
        await loadWaterLevelForecast(for: tideStationID, force: false)
        removeLegacyCrewSeedIfNeeded()
    }

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
