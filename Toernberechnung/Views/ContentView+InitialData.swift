import SwiftUI

// MARK: - Erstbefüllung: Initialdaten beim ersten App-Start anlegen

extension ContentView {
    @MainActor
    func bootstrapIfNeeded() async {
        syncRouteDefaults()
        if viewModel.routePlan == nil {
            viewModel.onRouteChanged()
        }
        await loadTides(force: tideReading == nil)
        if crewMembers.isEmpty {
            modelContext.insert(CrewMemberRecord(name: "Skipper", role: CrewRoleOption.navigation.rawValue, isOnBoard: true))
            modelContext.insert(CrewMemberRecord(name: "Crew", role: CrewRoleOption.deck.rawValue, isOnBoard: true))
            try? modelContext.save()
        }
    }

    @MainActor
    func writeAudit(action: String, source: String, statement: String, status: String) {
        modelContext.insert(AuditLog(action: action, source: source, statement: statement, status: status))
    }
}
