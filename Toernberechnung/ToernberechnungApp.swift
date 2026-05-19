import SwiftUI
import SwiftData

// MARK: - SwiftData-Modelle für persistente App-Daten

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
        createdAt: Date = .now
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

// MARK: - App-Einstiegspunkt und ModelContainer-Setup

@main
struct ToernberechnungApp: App {
    private let modelContainer: ModelContainer = {
        let schema = Schema([CalculationRecord.self, WeatherSnapshot.self, AuditLog.self, CrewMemberRecord.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: false)
        return try! ModelContainer(for: schema, configurations: [configuration])
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
    }
}
