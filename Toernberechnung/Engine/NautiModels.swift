import Foundation
import Observation

struct NautiChatMessage: Identifiable, Equatable, Codable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let text: String
    let payload: NautiChatPayload?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        payload: NautiChatPayload? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.payload = payload
        self.createdAt = createdAt
    }
}

enum NautiChatPayload: Equatable, Codable, Sendable {
    case weather(NautiWeatherCard)
    case tide(NautiTideCard)
}

struct NautiWeatherCard: Equatable, Codable, Sendable {
    let harbourName: String
    let dayTitle: String
    let condition: String
    let icon: String
    let minTemperatureC: Double
    let maxTemperatureC: Double
    let maxWindKnots: Double
    let maxGustKnots: Double?
    let precipitationChance: Int
    let precipitationMM: Double
    let slots: [NautiWeatherSlot]
    let sourceText: String
    var harbourID: String? = nil
    var targetDate: Date? = nil
}

struct NautiWeatherSlot: Equatable, Identifiable, Codable, Sendable {
    let id: UUID
    let timeLabel: String
    let temperatureC: Double
    let windKnots: Double
    let windDirection: Int
    let precipitationChance: Int
    let icon: String

    init(
        id: UUID = UUID(),
        timeLabel: String,
        temperatureC: Double,
        windKnots: Double,
        windDirection: Int,
        precipitationChance: Int,
        icon: String
    ) {
        self.id = id
        self.timeLabel = timeLabel
        self.temperatureC = temperatureC
        self.windKnots = windKnots
        self.windDirection = windDirection
        self.precipitationChance = precipitationChance
        self.icon = icon
    }
}

struct NautiTideCard: Equatable, Codable, Sendable {
    let harbourName: String
    let stationName: String
    let dayTitle: String
    let events: [NautiTideCardEvent]
    let sourceText: String
    var harbourID: String? = nil
    var targetDate: Date? = nil
}

struct NautiTideCardEvent: Equatable, Identifiable, Codable, Sendable {
    let id: UUID
    let type: String
    let timeLabel: String
    let heightMeters: Double?
    let heightText: String

    init(
        id: UUID = UUID(),
        type: String,
        timeLabel: String,
        heightMeters: Double?,
        heightText: String
    ) {
        self.id = id
        self.type = type
        self.timeLabel = timeLabel
        self.heightMeters = heightMeters
        self.heightText = heightText
    }

    var isHighWater: Bool {
        type.uppercased() == "HW"
    }
}

enum NautiActionKind: String, Equatable, Codable, Sendable {
    case planTrip
    case saveTrip
    case openNavigation
    case getWeatherSummary
    case getTideSummary
    case getWaterLevelSummary
    case showWeather
    case showTides
    case showWaterLevel
    case sendMessage
    case createEvent
    case addCrewMember
    case removeCrewMember
}

enum NautiRecipientKind: String, Equatable, Codable, Sendable {
    case direct
    case group
}

enum NautiEventTargetKind: String, Equatable, Codable, Sendable {
    case personal
    case direct
    case group
}

struct NautiAppAction: Equatable, Codable, Sendable {
    var kind: NautiActionKind
    var startHarbourID: String?
    var destinationHarbourID: String?
    var intermediateStopIDs: [String]
    var departureAt: String?
    var harbourID: String?
    var targetDate: String?
    var message: String?
    var openNavigation: Bool
    var saveTrip: Bool
    var recipientKind: NautiRecipientKind?
    var recipientQuery: String?
    var messageText: String?
    var eventTitle: String?
    var eventNotes: String?
    var eventLocation: String?
    var eventStartAt: String?
    var eventEndAt: String?
    var eventTargetKind: NautiEventTargetKind?
    var eventTargetQuery: String?
    var skipperID: String?
    var crewRole: String?
    var groupQuery: String?

    init(
        kind: NautiActionKind,
        startHarbourID: String? = nil,
        destinationHarbourID: String? = nil,
        intermediateStopIDs: [String] = [],
        departureAt: String? = nil,
        harbourID: String? = nil,
        targetDate: String? = nil,
        message: String? = nil,
        openNavigation: Bool = false,
        saveTrip: Bool = false,
        recipientKind: NautiRecipientKind? = nil,
        recipientQuery: String? = nil,
        messageText: String? = nil,
        eventTitle: String? = nil,
        eventNotes: String? = nil,
        eventLocation: String? = nil,
        eventStartAt: String? = nil,
        eventEndAt: String? = nil,
        eventTargetKind: NautiEventTargetKind? = nil,
        eventTargetQuery: String? = nil,
        skipperID: String? = nil,
        crewRole: String? = nil,
        groupQuery: String? = nil
    ) {
        self.kind = kind
        self.startHarbourID = startHarbourID
        self.destinationHarbourID = destinationHarbourID
        self.intermediateStopIDs = intermediateStopIDs
        self.departureAt = departureAt
        self.harbourID = harbourID
        self.targetDate = targetDate
        self.message = message
        self.openNavigation = openNavigation
        self.saveTrip = saveTrip
        self.recipientKind = recipientKind
        self.recipientQuery = recipientQuery
        self.messageText = messageText
        self.eventTitle = eventTitle
        self.eventNotes = eventNotes
        self.eventLocation = eventLocation
        self.eventStartAt = eventStartAt
        self.eventEndAt = eventEndAt
        self.eventTargetKind = eventTargetKind
        self.eventTargetQuery = eventTargetQuery
        self.skipperID = skipperID
        self.crewRole = crewRole
        self.groupQuery = groupQuery
    }

    var departureDate: Date? {
        Self.date(from: departureAt, includeTime: true)
    }

    var targetDay: Date? {
        Self.date(from: targetDate, includeTime: false)
    }

    var eventStartDate: Date? {
        Self.date(from: eventStartAt, includeTime: true)
    }

    var eventEndDate: Date? {
        Self.date(from: eventEndAt, includeTime: true)
    }

    private static func date(from rawValue: String?, includeTime: Bool) -> Date? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: rawValue) {
            return date
        }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: rawValue) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        formatter.dateFormat = includeTime ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        return formatter.date(from: rawValue)
    }
}

struct NautiConversationMessage: Equatable, Sendable {
    enum Role: String, Sendable {
        case user
        case assistant
    }

    let role: Role
    let text: String
}

struct NautiInferenceRequest: Equatable, Sendable {
    let messages: [NautiConversationMessage]
    let requestedAt: Date

    init(messages: [NautiConversationMessage], requestedAt: Date = .now) {
        self.messages = messages
        self.requestedAt = requestedAt
    }

    func limited(maxMessages: Int = 12, maxCharacters: Int = 8_000) -> NautiInferenceRequest {
        guard maxMessages > 0, maxCharacters > 0 else {
            return NautiInferenceRequest(messages: [], requestedAt: requestedAt)
        }

        var remainingCharacters = maxCharacters
        var retained: [NautiConversationMessage] = []

        for message in messages.suffix(maxMessages).reversed() where remainingCharacters > 0 {
            let normalized = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }

            let text = String(normalized.prefix(remainingCharacters))
            retained.append(NautiConversationMessage(role: message.role, text: text))
            remainingCharacters -= text.count
        }

        return NautiInferenceRequest(messages: retained.reversed(), requestedAt: requestedAt)
    }
}

struct NautiInferenceResult: Equatable, Sendable {
    let text: String
    let action: NautiAppAction?
}

struct NautiActionDispatch: Equatable, Sendable {
    let conversationID: UUID
    let action: NautiAppAction
}

struct NautiConversation: Identifiable, Equatable, Codable, Sendable {
    static let defaultTitle = "Neuer Chat"

    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var isPinned: Bool
    var hasCustomTitle: Bool
    var draft: String
    var messages: [NautiChatMessage]

    init(
        id: UUID = UUID(),
        title: String = NautiConversation.defaultTitle,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isPinned: Bool = false,
        hasCustomTitle: Bool = false,
        draft: String = "",
        messages: [NautiChatMessage] = [NautiChatMessage.welcome]
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.hasCustomTitle = hasCustomTitle
        self.draft = draft
        self.messages = messages
    }
}

extension NautiChatMessage {
    static var welcome: NautiChatMessage {
        NautiChatMessage(role: .assistant, text: "Moin, ich bin Nauti. Wie kann ich dir helfen?")
    }
}

enum LocalAIUnavailableReason: Equatable, Sendable {
    case requiresIOS26
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unsupportedGerman

    var message: String {
        switch self {
        case .requiresIOS26:
            return "Nauti benötigt iOS 26 und Apple Intelligence. Die manuelle Planung bleibt vollständig verfügbar."
        case .deviceNotEligible:
            return "Dieses Gerät unterstützt Apples lokale Sprach-KI nicht. Die manuelle Planung bleibt vollständig verfügbar."
        case .appleIntelligenceNotEnabled:
            return "Aktiviere Apple Intelligence in den Systemeinstellungen, um Nauti lokal zu verwenden."
        case .modelNotReady:
            return "Das lokale Sprachmodell wird noch vorbereitet. Versuche es in Kürze erneut."
        case .unsupportedGerman:
            return "Das lokale Sprachmodell unterstützt die deutsche Sprache auf diesem Gerät derzeit nicht."
        }
    }

    var icon: String {
        switch self {
        case .requiresIOS26: return "iphone.gen3"
        case .deviceNotEligible: return "cpu"
        case .appleIntelligenceNotEnabled: return "apple.intelligence"
        case .modelNotReady: return "arrow.down.circle"
        case .unsupportedGerman: return "character.bubble"
        }
    }
}

enum LocalAIAvailability: Equatable, Sendable {
    case available
    case unavailable(LocalAIUnavailableReason)
}

enum LocalAIInferenceError: LocalizedError, Equatable, Sendable {
    case unavailable(LocalAIUnavailableReason)
    case busy
    case cancelled
    case contextTooLarge
    case guardrailViolation
    case assetsUnavailable
    case unsupportedLanguage
    case invalidGeneratedAction(String)
    case generationFailed

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason.message
        case .busy: return "Nauti verarbeitet bereits eine Anfrage."
        case .cancelled: return "Die lokale Antwort wurde abgebrochen."
        case .contextTooLarge: return "Der Chatverlauf ist für eine lokale Antwort zu lang. Beginne bitte eine neue Frage."
        case .guardrailViolation: return "Nauti kann diese Anfrage aus Sicherheitsgründen nicht beantworten."
        case .assetsUnavailable: return "Das lokale Sprachmodell ist momentan nicht einsatzbereit."
        case .unsupportedLanguage: return "Das lokale Sprachmodell unterstützt diese Sprache nicht."
        case .invalidGeneratedAction(let question): return question
        case .generationFailed: return "Nauti konnte lokal keine Antwort erzeugen. Versuche es erneut."
        }
    }
}

protocol LocalAIInferenceClient: Sendable {
    func availability() async -> LocalAIAvailability
    func infer(_ request: NautiInferenceRequest) async throws -> NautiInferenceResult
    func cancelCurrentInference() async
    func releaseResources() async
}

enum NautiActionValidator {
    static func validate(_ action: NautiAppAction, reply: String) -> NautiInferenceResult {
        var action = action

        switch action.kind {
        case .planTrip:
            guard let start = action.startHarbourID, HarbourOption.options.contains(where: { $0.id == start }) else {
                return clarification("Von welchem Hafen möchtest du starten?")
            }
            guard let destination = action.destinationHarbourID,
                  HarbourOption.options.contains(where: { $0.id == destination }) else {
                return clarification("Welchen Zielhafen soll ich einplanen?")
            }
            guard start != destination else {
                return clarification("Start- und Zielhafen müssen unterschiedlich sein. Welches Ziel möchtest du wählen?")
            }
            guard action.departureDate != nil else {
                return clarification("An welchem Tag und um welche Uhrzeit möchtest du abfahren?")
            }

            var seen = Set<String>()
            action.intermediateStopIDs = action.intermediateStopIDs.filter { harbourID in
                harbourID != start
                    && harbourID != destination
                    && HarbourOption.options.contains(where: { $0.id == harbourID })
                    && seen.insert(harbourID).inserted
            }

        case .getWeatherSummary, .getTideSummary, .getWaterLevelSummary,
             .showWeather, .showTides, .showWaterLevel:
            guard let harbourID = action.harbourID,
                  HarbourOption.options.contains(where: { $0.id == harbourID }) else {
                return clarification("Für welche Insel oder welchen Hafen soll ich die Daten öffnen?")
            }
            if action.targetDate != nil, action.targetDay == nil {
                return clarification("Für welches gültige Datum soll ich die Daten laden?")
            }

        case .saveTrip, .openNavigation:
            break

        case .sendMessage:
            guard let recipient = normalized(action.recipientQuery), !recipient.isEmpty else {
                return clarification("An wen möchtest du die Nachricht senden?")
            }
            guard let text = normalized(action.messageText), !text.isEmpty else {
                return clarification("Welchen Text soll die Nachricht enthalten?")
            }
            action.recipientQuery = recipient
            action.messageText = text

        case .createEvent:
            guard let title = normalized(action.eventTitle), !title.isEmpty else {
                return clarification("Welchen Titel soll der Termin haben?")
            }
            guard let startsAt = action.eventStartDate else {
                return clarification("An welchem Tag und um welche Uhrzeit beginnt der Termin?")
            }
            guard let endsAt = action.eventEndDate, endsAt > startsAt else {
                return clarification("Wann endet der Termin? Die Endzeit muss nach der Startzeit liegen.")
            }
            if action.eventTargetKind != nil, action.eventTargetKind != .personal,
               normalized(action.eventTargetQuery) == nil {
                return clarification("Mit welchem Kontakt oder welcher Gruppe soll der Termin geteilt werden?")
            }
            action.eventTitle = title
            action.eventNotes = normalized(action.eventNotes)
            action.eventLocation = normalized(action.eventLocation)
            action.eventTargetQuery = normalized(action.eventTargetQuery)

        case .addCrewMember, .removeCrewMember:
            guard let skipperID = normalized(action.skipperID), isValidSkipperID(skipperID) else {
                return clarification("Welche gültige Skipper-ID soll ich verwenden?")
            }
            action.skipperID = skipperID
            if action.kind == .addCrewMember {
                guard let role = canonicalCrewRole(action.crewRole) else {
                    return clarification("Welche Rolle soll das Crewmitglied erhalten?")
                }
                action.crewRole = role
            }
            action.groupQuery = normalized(action.groupQuery)
        }

        return NautiInferenceResult(text: reply, action: action)
    }

    static func clarification(_ question: String) -> NautiInferenceResult {
        NautiInferenceResult(text: question, action: nil)
    }

    static func canonicalCrewRole(_ rawValue: String?) -> String? {
        guard let normalized = normalized(rawValue)?.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "de_DE")
        ).lowercased() else { return nil }

        switch normalized {
        case "skipper": return "Skipper"
        case "co skipper", "co-skipper", "coskipper": return "Co-Skipper"
        case "navigation", "navigator": return "Navigation"
        case "wachfuhrung", "wache", "watch lead": return "Wachführung"
        case "deck": return "Deck"
        case "sicherheit medizin", "sicherheit/medizin", "medizin", "sanitater": return "Sicherheit/Medizin"
        case "crew", "crewmitglied": return "Crew"
        default: return nil
        }
    }

    static func isValidSkipperID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-]{6,128}$"#, options: .regularExpression) != nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
@Observable
final class AIAccessController {
    var hasSubscriptionAccess = true
    private(set) var localAvailability: LocalAIAvailability = .unavailable(.modelNotReady)

    @ObservationIgnored
    private let inferenceClient: any LocalAIInferenceClient

    init(inferenceClient: any LocalAIInferenceClient = LocalAIInferenceManager.shared) {
        self.inferenceClient = inferenceClient
    }

    var state: AIAccessState {
        guard hasSubscriptionAccess else { return .locked }
        switch localAvailability {
        case .available: return .available
        case .unavailable(let reason): return .unavailable(reason)
        }
    }

    func refresh() async {
        localAvailability = await inferenceClient.availability()
    }
}

enum AIAccessState: Equatable {
    case available
    case locked
    case unavailable(LocalAIUnavailableReason)

    var canUseAssistant: Bool {
        self == .available
    }

    var noticeMessage: String? {
        switch self {
        case .available: return nil
        case .locked:
            return "Nauti ist Teil des TideNode-Abos. Die manuelle Planung bleibt ohne Einschränkungen verfügbar."
        case .unavailable(let reason):
            return reason.message
        }
    }

    var noticeIcon: String {
        switch self {
        case .available: return "checkmark.circle"
        case .locked: return "lock.fill"
        case .unavailable(let reason): return reason.icon
        }
    }
}

enum NautiProactiveAccent: Equatable {
    case cyan
    case amber
    case red
}

enum NautiProactiveAction: Equatable {
    case showPassageWindow
    case adoptSuggestedDeparture(Date)
    case showWeather
    case openPlanner

    var title: String {
        switch self {
        case .showPassageWindow: return "Fenster ansehen"
        case .adoptSuggestedDeparture: return "Zeit vorschlagen"
        case .showWeather: return "Wetter ansehen"
        case .openPlanner: return "Planung öffnen"
        }
    }
}

struct NautiProactiveIssue: Identifiable, Equatable {
    let id: String
    let title: String
    let message: String
    let icon: String
    let accent: NautiProactiveAccent
    let primaryAction: NautiProactiveAction
    let secondaryAction: NautiProactiveAction
}

enum NautiProactiveIssueResolver {
    static func resolve(
        routeStatus: CombinedRouteStatus?,
        weatherStatus: WeatherStatus,
        routeTitle: String,
        departure: Date,
        passageWindow: PassageWindowScanner.Window?
    ) -> NautiProactiveIssue? {
        if routeStatus == .noGo {
            if weatherStatus == .noGo {
                return NautiProactiveIssue(
                    id: "weather-no-go",
                    title: "Wetterlage kritisch",
                    message: "Wind, Böen oder Sicht liegen für den gewählten Zeitpunkt außerhalb der Sicherheitsgrenzen.",
                    icon: "wind.warning",
                    accent: .red,
                    primaryAction: .showWeather,
                    secondaryAction: .openPlanner
                )
            }

            return NautiProactiveIssue(
                id: "route-no-go-\(routeTitle)-\(departure.timeIntervalSince1970)",
                title: "Törn aktuell nicht sicher",
                message: "Für die gewählte Route liegt mindestens eine kritische Einschränkung vor. Prüfe Passagefenster und Planung, bevor du fortfährst.",
                icon: "exclamationmark.triangle.fill",
                accent: .red,
                primaryAction: .showPassageWindow,
                secondaryAction: .openPlanner
            )
        }

        if let window = passageWindow, !window.contains(departure) {
            return NautiProactiveIssue(
                id: "departure-outside-window-\(window.start.timeIntervalSince1970)-\(window.end.timeIntervalSince1970)",
                title: "Abfahrt außerhalb des Fensters",
                message: "Die Abfahrt liegt nicht im sicheren Zeitraum \(window.displayString). Nauti kann eine passende Startzeit vorschlagen.",
                icon: "clock.badge.exclamationmark.fill",
                accent: .amber,
                primaryAction: .showPassageWindow,
                secondaryAction: .adoptSuggestedDeparture(window.start)
            )
        }

        return nil
    }
}

struct NautiResolvedMessageAction: Equatable, Sendable {
    let conversationID: String
    let conversationTitle: String
    let text: String
}

struct NautiResolvedEventAction: Equatable, Sendable {
    let conversationID: String?
    let targetTitle: String
    let title: String
    let notes: String?
    let location: String?
    let startsAt: Date
    let endsAt: Date
}

struct NautiResolvedCrewAction: Equatable, Sendable {
    let conversationID: String
    let groupTitle: String
    let skipperID: String
    let crewRole: String?
}

enum NautiPendingAction: Identifiable {
    case tripPlan(NautiAppAction)
    case saveTrip
    case openNavigation
    case suggestedDeparture(Date)
    case sendMessage(NautiResolvedMessageAction)
    case createEvent(NautiResolvedEventAction)
    case addCrewMember(NautiResolvedCrewAction)
    case removeCrewMember(NautiResolvedCrewAction)

    var id: String {
        switch self {
        case .tripPlan(let action):
            return "trip-plan-\(action.startHarbourID ?? "")-\(action.destinationHarbourID ?? "")-\(action.departureAt ?? "")"
        case .saveTrip: return "save-trip"
        case .openNavigation: return "open-navigation"
        case .suggestedDeparture(let date): return "suggested-departure-\(date.timeIntervalSince1970)"
        case .sendMessage(let action): return "message-\(action.conversationID)-\(action.text)"
        case .createEvent(let action): return "event-\(action.startsAt.timeIntervalSince1970)-\(action.title)"
        case .addCrewMember(let action): return "crew-add-\(action.conversationID)-\(action.skipperID)"
        case .removeCrewMember(let action): return "crew-remove-\(action.conversationID)-\(action.skipperID)"
        }
    }

    var title: String {
        switch self {
        case .tripPlan: return "Törn übernehmen?"
        case .saveTrip: return "Törn speichern?"
        case .openNavigation: return "Navigation starten?"
        case .suggestedDeparture: return "Abfahrt anpassen?"
        case .sendMessage: return "Nachricht senden?"
        case .createEvent: return "Termin erstellen?"
        case .addCrewMember: return "Crewmitglied hinzufügen?"
        case .removeCrewMember: return "Crewmitglied entfernen?"
        }
    }

    var confirmTitle: String {
        switch self {
        case .tripPlan: return "Törn übernehmen"
        case .saveTrip: return "Im Logbuch speichern"
        case .openNavigation: return "Weiter zur Navigation"
        case .suggestedDeparture: return "Zeit übernehmen"
        case .sendMessage: return "Nachricht senden"
        case .createEvent: return "Termin eintragen"
        case .addCrewMember: return "Crewmitglied hinzufügen"
        case .removeCrewMember: return "Crewmitglied entfernen"
        }
    }

    var message: String {
        switch self {
        case .tripPlan(let action):
            var details: [String] = []
            if let start = action.startHarbourID { details.append("Start: \(Self.harbourDisplayName(for: start))") }
            if let destination = action.destinationHarbourID { details.append("Ziel: \(Self.harbourDisplayName(for: destination))") }
            if let departure = action.departureDate {
                details.append("Abfahrt: \(AppDateFormatters.dayMonthYear.string(from: departure)) \(AppDateFormatters.hourMinute.string(from: departure)) Uhr")
            }
            if action.saveTrip { details.append("Der Törn wird zusätzlich im Logbuch gespeichert.") }
            if action.openNavigation { details.append("Danach wird die Navigation vorbereitet.") }
            return details.isEmpty
                ? "Nauti hat einen Törn-Vorschlag vorbereitet."
                : details.joined(separator: "\n")
        case .saveTrip:
            return "Der aktuelle manuell geplante Törn wird im Logbuch gespeichert."
        case .openNavigation:
            return "Die Navigation wird erst nach dem bekannten Sicherheitshinweis gestartet."
        case .suggestedDeparture(let date):
            return "Nauti schlägt \(AppDateFormatters.dayMonthYear.string(from: date)) um \(AppDateFormatters.hourMinute.string(from: date)) Uhr als sichere Abfahrt vor."
        case .sendMessage(let action):
            return "An: \(action.conversationTitle)\n\n\(action.text)"
        case .createEvent(let action):
            let start = "\(AppDateFormatters.dayMonthYear.string(from: action.startsAt)) um \(AppDateFormatters.hourMinute.string(from: action.startsAt)) Uhr"
            let end = AppDateFormatters.hourMinute.string(from: action.endsAt)
            return "\(action.title)\n\(start) bis \(end) Uhr\nKalender: \(action.targetTitle)"
        case .addCrewMember(let action):
            return "Skipper-ID: \(action.skipperID)\nRolle: \(action.crewRole ?? "Crew")\nGruppe: \(action.groupTitle)"
        case .removeCrewMember(let action):
            return "Skipper-ID: \(action.skipperID)\nGruppe: \(action.groupTitle)"
        }
    }

    private static func harbourDisplayName(for id: String) -> String {
        guard let harbour = HarbourOption.optionalByID(id) else { return id }
        return harbour.name.components(separatedBy: ",").first ?? harbour.name
    }
}

enum NautiPreparedCommand {
    case direct(NautiAppAction)
    case pending(NautiPendingAction)
    case clarification(String)
}

@MainActor
enum NautiCommandDispatcher {
    static func prepare(
        _ action: NautiAppAction,
        store: CrewspaceStore,
        currentSkipperID: String?,
        activeGroupID: String
    ) async -> NautiPreparedCommand {
        switch action.kind {
        case .sendMessage:
            return resolveMessage(action, store: store, currentSkipperID: currentSkipperID)
        case .createEvent:
            return resolveEvent(action, store: store, currentSkipperID: currentSkipperID)
        case .addCrewMember, .removeCrewMember:
            return await resolveCrew(
                action,
                store: store,
                currentSkipperID: currentSkipperID,
                activeGroupID: activeGroupID
            )
        default:
            return .direct(action)
        }
    }

    private static func resolveMessage(
        _ action: NautiAppAction,
        store: CrewspaceStore,
        currentSkipperID: String?
    ) -> NautiPreparedCommand {
        guard let query = action.recipientQuery, let text = action.messageText else {
            return .clarification("An wen und welchen Text soll ich senden?")
        }
        let matches = store.resolveConversations(
            matching: query,
            isGroup: action.recipientKind.map { $0 == .group },
            currentSkipperID: currentSkipperID
        )
        return resolvedConversation(matches, query: query) { conversation in
            .pending(.sendMessage(NautiResolvedMessageAction(
                conversationID: conversation.id,
                conversationTitle: conversation.title,
                text: text
            )))
        }
    }

    private static func resolveEvent(
        _ action: NautiAppAction,
        store: CrewspaceStore,
        currentSkipperID: String?
    ) -> NautiPreparedCommand {
        guard let title = action.eventTitle,
              let startsAt = action.eventStartDate,
              let endsAt = action.eventEndDate else {
            return .clarification("Für den Termin fehlen Titel, Start oder Endzeit.")
        }

        let makePending: (CrewspaceConversationDTO?) -> NautiPreparedCommand = { conversation in
            .pending(.createEvent(NautiResolvedEventAction(
                conversationID: conversation?.id,
                targetTitle: conversation?.title ?? "Persönlicher Kalender",
                title: title,
                notes: action.eventNotes,
                location: action.eventLocation,
                startsAt: startsAt,
                endsAt: endsAt
            )))
        }

        let targetKind = action.eventTargetKind ?? .personal
        guard targetKind != .personal else { return makePending(nil) }
        guard let query = action.eventTargetQuery else {
            return .clarification("Mit wem soll der Termin geteilt werden?")
        }
        let matches = store.resolveConversations(
            matching: query,
            isGroup: targetKind == .group,
            currentSkipperID: currentSkipperID
        )
        return resolvedConversation(matches, query: query, transform: makePending)
    }

    private static func resolveCrew(
        _ action: NautiAppAction,
        store: CrewspaceStore,
        currentSkipperID: String?,
        activeGroupID: String
    ) async -> NautiPreparedCommand {
        guard let skipperID = action.skipperID else {
            return .clarification("Welche Skipper-ID soll ich verwenden?")
        }

        let groups: [CrewspaceConversationDTO]
        if let query = action.groupQuery {
            groups = store.resolveConversations(matching: query, isGroup: true, currentSkipperID: currentSkipperID)
        } else if let active = store.conversations.first(where: { $0.id == activeGroupID && $0.isGroup }) {
            groups = [active]
        } else {
            return .clarification("Für welche Crewspace-Gruppe soll ich die Crew ändern?")
        }

        guard groups.count == 1, let group = groups.first else {
            return conversationClarification(groups, query: action.groupQuery ?? "aktive Crew")
        }

        do {
            let info = try await store.groupInfo(conversationID: group.id)
            guard info.canManage else {
                return .clarification("Du darfst die Crew dieser Gruppe nicht verwalten.")
            }
            let existing = info.members.first { $0.skipperID == skipperID }
            if action.kind == .addCrewMember, existing != nil {
                return .clarification("Diese Skipper-ID gehört bereits zur Crew von \(group.title).")
            }
            if action.kind == .removeCrewMember, existing == nil {
                return .clarification("Diese Skipper-ID ist nicht Teil der Crew von \(group.title).")
            }
            let resolved = NautiResolvedCrewAction(
                conversationID: group.id,
                groupTitle: group.title,
                skipperID: skipperID,
                crewRole: action.crewRole
            )
            return .pending(action.kind == .addCrewMember ? .addCrewMember(resolved) : .removeCrewMember(resolved))
        } catch {
            return .clarification("Die Crewgruppe konnte nicht geprüft werden: \(error.localizedDescription)")
        }
    }

    private static func resolvedConversation(
        _ matches: [CrewspaceConversationDTO],
        query: String,
        transform: (CrewspaceConversationDTO) -> NautiPreparedCommand
    ) -> NautiPreparedCommand {
        guard matches.count == 1, let match = matches.first else {
            return conversationClarification(matches, query: query)
        }
        return transform(match)
    }

    private static func conversationClarification(
        _ matches: [CrewspaceConversationDTO],
        query: String
    ) -> NautiPreparedCommand {
        if matches.isEmpty {
            return .clarification("Ich finde keinen bekannten Chat oder keine Gruppe für „\(query)“. Öffne zuerst den Kontakt in Crewspace.")
        }
        let names = matches.prefix(4).map(\.title).joined(separator: ", ")
        return .clarification("„\(query)“ ist mehrdeutig. Meinst du \(names)?")
    }
}
