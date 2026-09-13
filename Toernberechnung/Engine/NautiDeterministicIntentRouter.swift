import Foundation

/// Routes high-confidence maritime data commands without asking the language
/// model to reinterpret them. It also sanitizes generated trip plans against
/// the latest user sentence so old context cannot leak into a new command.
enum NautiDeterministicIntentRouter {
    private enum DataIntent {
        case weather
        case tides
        case waterLevel
    }

    static func crewspaceEditor(in text: String) -> NautiCrewspaceEditorRequest.Kind? {
        let text = folded(text)
        guard text.range(of: #"\b(nicht|kein\w*|abbrechen|loschen|entfernen)\b"#, options: .regularExpression) == nil else { return nil }
        let creates = containsAny(text, ["hinzufug", "hinzu", "anlegen", "erstell", "eintrag", "trage", "aufnehmen", "nehme", "neues crewmitglied", "neuen termin", "neuer termin"])
        if creates && containsAny(text, ["crewmitglied", "crew-mitglied", "mitglied der crew"]) { return .crewMember }
        let plansEvent = text.range(of: #"\b(plan\w*|vereinbar\w*|ansetz\w*|organisier\w*)\b"#, options: .regularExpression) != nil
        if (creates || plansEvent) && containsAny(text, ["termin", "ereignis", "event"]) { return .event }
        return nil
    }

    static func route(_ request: NautiInferenceRequest) -> NautiInferenceResult? {
        // Explanatory questions belong to the model even when they contain
        // data keywords such as "Gezeiten" or "Wetter". Mixed requests also
        // reach the model so it can choose the appropriate structured intent.
        if let latest = request.messages.last(where: { $0.role == .user })?.text,
           asksForAdvice(latest) {
            return nil
        }

        if let latest = request.messages.last(where: { $0.role == .user })?.text,
           looksLikeTripPlanning(latest) {
            return routeTrip(latest, requestedAt: request.requestedAt)
        }

        if let latest = request.messages.last(where: { $0.role == .user })?.text,
           looksLikeWarningsRequest(latest) {
            let opens = explicitlyOpensAppSection(latest) || containsAny(folded(latest), ["offne", "zeige", "anzeigen", "offnen"])
            let kind: NautiActionKind = opens ? .showWarnings : .getWarningsSummary
            let message = opens
                ? "Ich öffne die nautischen Warnmeldungen."
                : "Ich rufe die aktuellen Seefahrer-Nachrichten und Warnungen ab."
            return NautiActionValidator.validate(
                NautiAppAction(kind: kind, message: message),
                reply: message
            )
        }

        guard let latest = request.messages.last(where: { $0.role == .user })?.text,
              let intent = dataIntent(in: latest),
              !looksLikeTripPlanning(latest) else {
            return nil
        }

        guard let harbour = resolveHarbour(in: request) else {
            let subject = intent == .weather ? "Wetter" : intent == .tides ? "Gezeiten" : "Wasserstand"
            return NautiActionValidator.clarification(
                "Für welche Insel oder welchen Hafen soll ich \(subject.lowercased()) laden?"
            )
        }

        let opensSection = explicitlyOpensAppSection(latest)
        let kind: NautiActionKind
        let message: String
        let place = shortName(for: harbour)

        switch (intent, opensSection) {
        case (.weather, false):
            kind = .getWeatherSummary
            message = "Ich lade das Wetter für \(place)."
        case (.weather, true):
            kind = .showWeather
            message = "Ich öffne den Wetterbereich für \(place)."
        case (.tides, false):
            kind = .getTideSummary
            message = "Ich lade die Gezeiten für \(place)."
        case (.tides, true):
            kind = .showTides
            message = "Ich öffne den Gezeitenbereich für \(place)."
        case (.waterLevel, false):
            kind = .getWaterLevelSummary
            message = "Ich lade den Wasserstand für \(place)."
        case (.waterLevel, true):
            kind = .showWaterLevel
            message = "Ich öffne den Wasserstandsbereich für \(place)."
        }

        return NautiActionValidator.validate(
            NautiAppAction(
                kind: kind,
                harbourID: harbour.id,
                targetDate: resolveTargetDate(in: request),
                message: message
            ),
            reply: message
        )
    }

    static func sanitize(
        _ result: NautiInferenceResult,
        for request: NautiInferenceRequest
    ) -> NautiInferenceResult {
        guard var action = result.action,
              action.kind == .planTrip,
              let latest = request.messages.last(where: { $0.role == .user })?.text else {
            return result
        }

        let mentionedIDs = Set(mentionedHarbours(in: latest).map(\.id))
        action.intermediateStopIDs = action.intermediateStopIDs.filter { mentionedIDs.contains($0) }

        if folded(latest).contains("jetzt") {
            action.departureAt = isoDateTime(request.requestedAt)
        }

        let reply = tripReply(for: action)
        return NautiActionValidator.validate(action, reply: reply)
    }

    private static func asksForAdvice(_ text: String) -> Bool {
        let text = folded(text)
        let patterns = [
            #"\b(erkl[aä]r\w*|erlaut\w*|warum|weshalb|wieso|bedeut\w*|versteh\w*)\b"#,
            #"\b(was (ist|sind)|wie (entsteh\w*|funktionier\w*|bereit\w*|plan\w*|erkenne|verhalt\w*))\b"#,
            #"\b(beacht\w*|berat\w*|rat(?:schlag|schlage)|tipps?|zusammenhang|unterschied\w*)\b"#
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private static func dataIntent(in text: String) -> DataIntent? {
        let text = folded(text)
        if containsAny(text, ["wasserstand", "pegelstand", "wasserpegel"]) {
            return .waterLevel
        }
        if containsAny(text, ["gezeit", "tide", "hochwasser", "niedrigwasser"]) {
            return .tides
        }
        if containsAny(text, ["wetter", "wind", "boe", "temperatur", "regen"]) {
            return .weather
        }
        return nil
    }

    private static func looksLikeTripPlanning(_ text: String) -> Bool {
        let text = folded(text)
        let hasTripSubject = containsAny(text, ["torn", "route", "fahrt", "gps", "navigation"])
        let hasPlanningVerb = containsAny(text, ["plan", "berechne", "starte", "navigier"])
        return hasTripSubject && hasPlanningVerb
    }

    private static func routeTrip(_ text: String, requestedAt: Date) -> NautiInferenceResult? {
        let harbours = mentionedHarbours(in: text)
        guard harbours.count >= 2 else {
            return NautiActionValidator.clarification(
                harbours.isEmpty
                    ? "Von welchem Hafen möchtest du starten?"
                    : "Welchen Zielhafen soll ich einplanen?"
            )
        }

        let start = harbours[0]
        let destination = harbours[1]
        let foldedText = folded(text)
        let stops = foldedText.contains("ohne zwischen")
            ? []
            : Array(harbours.dropFirst(2)).filter { $0.id != start.id && $0.id != destination.id }
        let departure = resolveDepartureDateTime(in: text, relativeTo: requestedAt) ?? requestedAt
        let openNavigation = containsAny(foldedText, ["gps", "navigation", "navigier", "fahrt starten", "starte"])
        let saveTrip = containsAny(foldedText, ["speicher", "sichere", "logbuch"])

        let action = NautiAppAction(
            kind: .planTrip,
            startHarbourID: start.id,
            destinationHarbourID: destination.id,
            intermediateStopIDs: stops.map(\.id),
            departureAt: isoDateTime(departure),
            message: nil,
            openNavigation: openNavigation,
            saveTrip: saveTrip
        )
        return NautiActionValidator.validate(action, reply: tripReply(for: action))
    }

    private static func explicitlyOpensAppSection(_ text: String) -> Bool {
        let text = folded(text)
        let namesSection = containsAny(text, ["tab", "reiter", "bereich", "seite"])
        let opens = containsAny(text, ["offne", "wechsel", "gehe", "springe"])
        return namesSection && opens
    }

    private static func looksLikeWarningsRequest(_ text: String) -> Bool {
        let text = folded(text)
        let keywords = [
            "warnung", "warnungen", "warnmeldung", "warnmeldungen", "warnhinweis",
            "seefahrer", "seefahrernachricht", "nwn", "bekanntmachung", "bekanntmachungen",
            "gefahr", "sperrung", "sperrgebiet", "schiessgebiet", "schiesszeiten",
            "funkwarnung", "funkwarnungen", "elwis", "notices to mariners"
        ]
        return containsAny(text, keywords)
    }

    private static func resolveHarbour(in request: NautiInferenceRequest) -> HarbourOption? {
        for message in request.messages.reversed() where message.role == .user {
            if let harbour = mentionedHarbours(in: message.text).last {
                return harbour
            }
        }
        return nil
    }

    private static func mentionedHarbours(in text: String) -> [HarbourOption] {
        let text = folded(text)
        return HarbourOption.options.compactMap { harbour -> (HarbourOption, Int)? in
            let aliases = [
                harbour.name.components(separatedBy: ",").first ?? harbour.name,
                harbour.name,
                harbour.id.replacingOccurrences(of: "_harbor", with: "")
            ].map(folded)

            let positions = aliases.compactMap { alias -> Int? in
                guard let range = text.range(of: alias) else { return nil }
                return text.distance(from: text.startIndex, to: range.lowerBound)
            }
            guard let position = positions.min() else { return nil }
            return (harbour, position)
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
    }

    private static func resolveTargetDate(in request: NautiInferenceRequest) -> String? {
        for message in request.messages.reversed() where message.role == .user {
            if let date = targetDate(in: message.text, relativeTo: request.requestedAt) {
                return dateString(date)
            }
        }
        return nil
    }

    private static func targetDate(in text: String, relativeTo now: Date) -> Date? {
        let text = folded(text)
        let calendar = AppDateFormatters.berlinCalendar
        let start = calendar.startOfDay(for: now)

        if text.contains("ubermorgen") {
            return calendar.date(byAdding: .day, value: 2, to: start)
        }
        if text.contains("morgen") {
            return calendar.date(byAdding: .day, value: 1, to: start)
        }
        if text.contains("heute") || text.contains("jetzt") {
            return start
        }

        let weekdays = [
            "sonntag": 1, "montag": 2, "dienstag": 3, "mittwoch": 4,
            "donnerstag": 5, "freitag": 6, "samstag": 7
        ]
        if let match = weekdays.first(where: { text.contains($0.key) }) {
            let current = calendar.component(.weekday, from: start)
            let offset = (match.value - current + 7) % 7
            return calendar.date(byAdding: .day, value: offset, to: start)
        }

        guard let match = text.range(
            of: #"\b(\d{1,2})\.(\d{1,2})(?:\.(\d{2,4}))?\b"#,
            options: .regularExpression
        ) else { return nil }

        let raw = String(text[match])
        let parts = raw.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        var year = parts.count > 2 ? parts[2] : calendar.component(.year, from: now)
        if year < 100 { year += 2_000 }
        return calendar.date(from: DateComponents(year: year, month: parts[1], day: parts[0]))
    }

    private static func resolveDepartureDateTime(in text: String, relativeTo now: Date) -> Date? {
        let calendar = AppDateFormatters.berlinCalendar
        let foldedText = folded(text)
        if foldedText.contains("jetzt") {
            return now
        }

        let day = targetDate(in: text, relativeTo: now) ?? calendar.startOfDay(for: now)
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        let time = timeComponents(in: foldedText) ?? calendar.dateComponents([.hour, .minute], from: now)
        return calendar.date(from: DateComponents(
            year: components.year,
            month: components.month,
            day: components.day,
            hour: time.hour,
            minute: time.minute ?? 0
        ))
    }

    private static func timeComponents(in text: String) -> DateComponents? {
        let patterns = [
            #"(?:um|ab)\s+(\d{1,2})(?::|\.| uhr\s*)?(\d{2})?\s*(?:uhr)?"#,
            #"\b(\d{1,2})(?::|\.)(\d{2})\s*(?:uhr)?\b"#
        ]

        for pattern in patterns {
            guard let match = text.range(of: pattern, options: .regularExpression) else { continue }
            let raw = String(text[match])
            let digits = raw
                .split(whereSeparator: { !$0.isNumber })
                .compactMap { Int($0) }
            guard let hour = digits.first, (0...23).contains(hour) else { continue }
            let minute = digits.dropFirst().first ?? 0
            guard (0...59).contains(minute) else { continue }
            return DateComponents(hour: hour, minute: minute)
        }
        return nil
    }

    private static func tripReply(for action: NautiAppAction) -> String {
        guard let startID = action.startHarbourID,
              let destinationID = action.destinationHarbourID,
              let start = HarbourOption.optionalByID(startID),
              let destination = HarbourOption.optionalByID(destinationID),
              let departure = action.departureDate else {
            return "Ich habe den Törn-Vorschlag vorbereitet."
        }

        let stops = action.intermediateStopIDs.compactMap(HarbourOption.optionalByID)
        let stopText = stops.isEmpty
            ? ""
            : " mit Zwischenstopp in \(stops.map(shortName).joined(separator: ", "))"
        return "Ich habe den Törn von \(shortName(for: start)) nach \(shortName(for: destination))\(stopText) für \(AppDateFormatters.dayMonthYear.string(from: departure)) um \(AppDateFormatters.hourMinute.string(from: departure)) Uhr vorbereitet."
    }

    private static func isoDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
        return formatter.string(from: date)
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func shortName(for harbour: HarbourOption) -> String {
        harbour.name.components(separatedBy: ",").first ?? harbour.name
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains(where: text.contains)
    }

    private static func folded(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "de_DE")
        ).lowercased()
    }
}
