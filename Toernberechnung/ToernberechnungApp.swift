import SwiftUI
import SwiftData

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

@main
struct ToernberechnungApp: App {
    private let modelContainer: ModelContainer = {
        let schema = Schema([CalculationRecord.self, WeatherSnapshot.self, AuditLog.self, CrewMemberRecord.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: false)
        return try! ModelContainer(for: schema, configurations: [configuration])
    }()

    /// Live GPS service.  Shared across every tab so the background
    /// recording survives navigation away from the Map tab.
    @State private var locationService = LocationService()
    @State private var navigationTracker = NavigationTracker()
    @State private var voyageManager: ActiveVoyageManager

    init() {
        let loc = LocationService()
        let tracker = NavigationTracker()
        let voyage = ActiveVoyageManager(locationService: loc, tracker: tracker)
        _locationService = State(initialValue: loc)
        _navigationTracker = State(initialValue: tracker)
        _voyageManager = State(initialValue: voyage)

        // Start SeaMask building asynchronously on launch
        NauticalRouteService.shared.buildSeaMask()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(locationService)
                .environment(navigationTracker)
                .environment(voyageManager)
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
        }
        .modelContainer(modelContainer)
    }
}
