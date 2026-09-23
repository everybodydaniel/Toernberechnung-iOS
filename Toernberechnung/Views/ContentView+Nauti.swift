import SwiftUI
import CoreLocation

extension ContentView {
    // MARK: - TideNode proactive assistance

    /// These states deliberately come from the deterministic route and weather
    /// calculation. Nauti only explains them; it does not decide seaworthiness.
    var proactiveNautiIssue: NautiProactiveIssue? {
        NautiProactiveIssueResolver.resolve(
            routeStatus: viewModel.combinedStatus,
            weatherStatus: viewModel.weatherStatus,
            routeTitle: viewModel.routeTitle,
            departure: viewModel.departure,
            passageWindow: viewModel.passageWindow
        )
    }

    var visibleNautiProactiveIssue: NautiProactiveIssue? {
        guard let issue = proactiveNautiIssue,
              dismissedNautiIssueID != issue.id else {
            return nil
        }
        return issue
    }

    func openNautiChat() {
        if !nautiDashboardMode.isExpanded {
            dashboardDetentBeforeNauti = dashboardDetent
        }
        withAnimation(NautiDashboardGeometry.animation(reduceMotion: reduceMotion)) {
            nautiDashboardMode = .chat
            dashboardDragOffset = 0
        }
    }

    @MainActor
    func handleNautiAction(_ dispatch: NautiActionDispatch) {
        let action = dispatch.action
        let conversationID = dispatch.conversationID

        switch action.kind {
        case .planTrip:
            pendingNautiConversationID = conversationID
            pendingNautiAction = .tripPlan(action)
        case .saveTrip:
            pendingNautiConversationID = conversationID
            pendingNautiAction = .saveTrip
        case .openNavigation:
            pendingNautiConversationID = conversationID
            pendingNautiAction = .openNavigation
        case .getWeatherSummary:
            Task { await answerNautiWeather(action, conversationID: conversationID) }
        case .getTideSummary:
            Task { await answerNautiTides(action, conversationID: conversationID) }
        case .getWaterLevelSummary:
            Task { await answerNautiWaterLevel(action, conversationID: conversationID) }
        case .showWeather:
            openNautiWeather(action)
        case .showTides, .showWaterLevel:
            openNautiTides(action)
        case .showWarnings:
            openNautiWarnings()
        case .getWarningsSummary:
            Task { await answerNautiWarnings(conversationID: conversationID) }
        }
    }

    @MainActor
    func confirmNautiAction(_ pendingAction: NautiPendingAction) {
        let conversationID = pendingNautiConversationID
        pendingNautiAction = nil
        pendingNautiConversationID = nil

        switch pendingAction {
        case .tripPlan(let action):
            applyNautiTripPlan(action, conversationID: conversationID)
        case .saveTrip:
            saveNautiTripPlan(conversationID: conversationID)
        case .openNavigation:
            openNautiNavigation(conversationID: conversationID)
        case .suggestedDeparture(let date):
            viewModel.departure = date
            syncRouteDefaults()
            viewModel.onRouteChanged()
            Task {
                await loadTides(force: true)
                await loadWaterLevelForecast(for: destinationHarbour, force: false)
            }
            nautiViewModel.appendAssistantMessage(
                "Ich habe die vorgeschlagene Abfahrt gesetzt. Du kannst den Törn weiterhin manuell anpassen.",
                conversationID: conversationID
            )
        }
    }

    @MainActor
    func answerNautiWeather(_ action: NautiAppAction, conversationID: UUID) async {
        guard let harbourID = preferredHarbourID(from: action) else {
            nautiViewModel.appendAssistantMessage(
                "Für welche Insel soll ich das Wetter laden?",
                conversationID: conversationID
            )
            return
        }

        let harbour = HarbourOption.byID(harbourID)
        let initialLoadingText = action.message ?? "Ich lade das Wetter von Apple Weather."
        let loadingText = action.message ?? "Ich lade das Wetter von Apple Weather für \(shortHarbourName(harbour))."
        nautiViewModel.replaceLastAssistantMessage(
            matching: initialLoadingText,
            with: loadingText,
            conversationID: conversationID
        )

        do {
            let target = action.targetDay ?? .now
            let calendar = AppDateFormatters.berlinCalendar
            let dayStart = calendar.startOfDay(for: target)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
                ?? dayStart.addingTimeInterval(86_400)
            let snapshot = try await maritimeWeatherService.weather(
                at: CLLocationCoordinate2D(latitude: harbour.latitude, longitude: harbour.longitude),
                datasets: [.daily, .hourly(DateInterval(start: dayStart, end: dayEnd))],
                policy: .revalidateExpired
            )
            let targetHours = snapshot.hourly.filter {
                calendar.isDate($0.date, inSameDayAs: target)
            }
            let sourceText = nautiWeatherSummary(
                days: snapshot.daily,
                harbour: harbour,
                target: target,
                targetHours: targetHours
            )
            let card = nautiWeatherCard(
                days: snapshot.daily,
                harbour: harbour,
                target: target,
                targetHours: targetHours,
                sourceText: sourceText
            )
            nautiViewModel.replaceLastAssistantMessage(
                matching: loadingText,
                with: "Wetter-Widget für \(shortHarbourName(harbour))",
                payload: card.map { .weather($0) },
                conversationID: conversationID
            )
        } catch {
            nautiViewModel.replaceLastAssistantMessage(
                matching: loadingText,
                with: "Ich konnte Apple Weather für \(shortHarbourName(harbour)) gerade nicht laden: \(error.localizedDescription)",
                conversationID: conversationID
            )
        }
    }

    @MainActor
    func answerNautiTides(_ action: NautiAppAction, conversationID: UUID) async {
        guard let harbourID = preferredHarbourID(from: action) else {
            nautiViewModel.appendAssistantMessage(
                "Für welchen Pegel soll ich die BSH-Gezeiten laden?",
                conversationID: conversationID
            )
            return
        }

        let harbour = HarbourOption.byID(harbourID)
        let target = action.targetDay ?? .now
        let initialLoadingText = action.message ?? "Ich lade die BSH-Gezeiten."
        let loadingText = action.message ?? "Ich lade die BSH-Gezeiten für \(shortHarbourName(harbour))."
        nautiViewModel.replaceLastAssistantMessage(
            matching: initialLoadingText,
            with: loadingText,
            conversationID: conversationID
        )

        do {
            let reading = try await BSHTideService.shared.fetch(
                for: harbour,
                around: AppDateFormatters.berlinCalendar.startOfDay(for: target),
                force: false
            )
            islandTides[harbour.tideStationID] = reading
            if tideStationID == harbour.tideStationID {
                tideReading = reading
            }

            let sourceText = nautiTideSummary(reading, harbour: harbour, target: target)
            let card = nautiTideCard(reading, harbour: harbour, target: target, sourceText: sourceText)
            nautiViewModel.replaceLastAssistantMessage(
                matching: loadingText,
                with: "Gezeiten-Widget für \(shortHarbourName(harbour))",
                payload: card.map { .tide($0) },
                conversationID: conversationID
            )
        } catch {
            nautiViewModel.replaceLastAssistantMessage(
                matching: loadingText,
                with: "Ich konnte die BSH-Gezeiten für \(shortHarbourName(harbour)) gerade nicht laden: \(error.localizedDescription)",
                conversationID: conversationID
            )
        }
    }

    @MainActor
    func answerNautiWaterLevel(_ action: NautiAppAction, conversationID: UUID) async {
        guard let harbourID = preferredHarbourID(from: action) else {
            nautiViewModel.appendAssistantMessage(
                "Für welchen Pegel soll ich die BSH-Wasserstandsvorhersage laden?",
                conversationID: conversationID
            )
            return
        }

        let harbour = HarbourOption.byID(harbourID)
        let target = action.targetDay ?? .now
        let initialLoadingText = action.message ?? "Ich lade die BSH-Wasserstandsvorhersage."
        let loadingText = action.message ?? "Ich lade die BSH-Wasserstandsvorhersage für \(shortHarbourName(harbour))."
        nautiViewModel.replaceLastAssistantMessage(
            matching: initialLoadingText,
            with: loadingText,
            conversationID: conversationID
        )

        let station = BSHTideStationCatalog.station(for: harbour)
        guard station.hasLocalWaterLevelForecast else {
            let text = "Für \(shortHarbourName(harbour)) veröffentlicht das BSH keine eigene lokale Wasserstandsvorhersage. Die astronomischen HW-/NW-Zeiten kann ich trotzdem anzeigen. Einen Vergleichspegel verwende ich nur nach deiner ausdrücklichen Bestätigung in der Törnplanung."
            nautiViewModel.replaceLastAssistantMessage(
                matching: loadingText,
                with: text,
                conversationID: conversationID
            )
            return
        }

        do {
            let forecast = try await nautiWaterLevelForecast(for: harbour)
            waterLevelForecasts[station.id] = forecast
            let text = await nautiWaterLevelAnswer(forecast, harbour: harbour, target: target)
            nautiViewModel.replaceLastAssistantMessage(
                matching: loadingText,
                with: text,
                conversationID: conversationID
            )
        } catch {
            nautiViewModel.replaceLastAssistantMessage(
                matching: loadingText,
                with: "Ich konnte die BSH-Wasserstandsvorhersage für \(shortHarbourName(harbour)) gerade nicht laden: \(error.localizedDescription)",
                conversationID: conversationID
            )
        }
    }

    @MainActor
    func applyNautiTripPlan(_ action: NautiAppAction, conversationID: UUID?) {
        selectedTab = .map

        if let startID = resolveHarbourID(from: action.startHarbourID) {
            viewModel.startHarbourID = startID
        }
        if let destinationID = resolveHarbourID(from: action.destinationHarbourID) {
            viewModel.destinationHarbourID = destinationID
        }

        let stopIDs = action.intermediateStopIDs.compactMap { resolveHarbourID(from: $0) }
        viewModel.intermediateStops = stopIDs.map { IntermediateStop(harbourID: $0) }

        if let departure = action.departureDate {
            viewModel.departure = departure
        }

        syncRouteDefaults()
        viewModel.onRouteChanged()

        if action.saveTrip {
            saveCalculation()
            nautiViewModel.appendAssistantMessage(
                "Ich habe den Törn im Logbuch gespeichert.",
                conversationID: conversationID
            )
        }

        closeNautiChat()

        Task {
            await loadTides(force: true)
            await loadWaterLevelForecast(for: destinationHarbour, force: false)
            await loadWeather(userInitiated: false)
        }

        if action.openNavigation {
            voyageDisclaimerShown = true
        }
    }

    @MainActor
    func saveNautiTripPlan(conversationID: UUID?) {
        selectedTab = .map
        guard viewModel.hasCompleteRouteInput, viewModel.routePlan != nil else {
            nautiViewModel.appendAssistantMessage(
                "Plane zuerst einen vollständigen Törn mit Start, Ziel und Abfahrt.",
                conversationID: conversationID
            )
            return
        }

        saveCalculation()
        closeNautiChat()
        nautiViewModel.appendAssistantMessage(
            "Ich habe den Törn im Logbuch gespeichert.",
            conversationID: conversationID
        )
    }

    @MainActor
    func openNautiNavigation(conversationID: UUID?) {
        selectedTab = .map
        guard viewModel.hasCompleteRouteInput, viewModel.routePlan != nil else {
            nautiViewModel.appendAssistantMessage(
                "Plane zuerst einen vollständigen Törn, bevor du GPS startest.",
                conversationID: conversationID
            )
            return
        }
        closeNautiChat()

        if voyageManager.isVoyageActive {
            navigationFullScreenShown = true
        } else {
            voyageDisclaimerShown = true
        }
    }

    @MainActor
    func openNautiWeather(_ action: NautiAppAction) {
        let harbourID = preferredHarbourID(from: action) ?? weatherRegionID
        weatherRegionID = harbourID
        weatherReport = islandWeatherReports[harbourID]
        selectedConditionsSection = .weather
        selectedTab = .conditions
        closeNautiChat()

        Task {
            await loadWeather(userInitiated: false)
        }
    }

    @MainActor
    func openNautiTides(_ action: NautiAppAction) {
        let harbourID = preferredHarbourID(from: action) ?? tideHarbour.id
        let harbour = HarbourOption.byID(harbourID)
        tideStationID = harbour.tideStationID
        selectedConditionsSection = .tides
        selectedTab = .conditions
        closeNautiChat()

        Task {
            await loadAstronomicalTide(for: harbour)
            await loadWaterLevelForecast(for: harbour, force: false)
        }
    }

    @MainActor
    func openNautiPayload(_ payload: NautiChatPayload) {
        switch payload {
        case .weather(let card):
            guard let harbourID = card.harbourID else { return }
            weatherRegionID = harbourID
            weatherReport = islandWeatherReports[harbourID]
            selectedConditionsSection = .weather
            selectedTab = .conditions
            closeNautiChat()

            Task {
                await loadWeather(userInitiated: false)
                guard let target = card.targetDate,
                      let report = weatherReport,
                      let day = report.daily.first(where: {
                          AppDateFormatters.berlinCalendar.isDate($0.date, inSameDayAs: target)
                      }) else { return }
                let hours = report.hourly.filter {
                    AppDateFormatters.berlinCalendar.isDate($0.date, inSameDayAs: target)
                }
                selectedWeatherDay = WeatherDaySelection(
                    day: day,
                    harbour: HarbourOption.byID(harbourID),
                    initialHours: hours
                )
            }
        case .tide(let card):
            guard let harbourID = card.harbourID else { return }
            let harbour = HarbourOption.byID(harbourID)
            tideStationID = harbour.tideStationID
            selectedConditionsSection = .tides
            selectedTab = .conditions
            closeNautiChat()
            Task {
                await loadAstronomicalTide(for: harbour)
                await loadWaterLevelForecast(for: harbour, force: false)
            }
        }
    }

    func closeNautiChat() {
        guard nautiDashboardMode.isExpanded else { return }
        nautiFocusDismissTrigger &+= 1
        withAnimation(NautiDashboardGeometry.animation(reduceMotion: reduceMotion)) {
            nautiDashboardMode = .dashboard
            dashboardDetent = dashboardDetentBeforeNauti
            dashboardDragOffset = 0
        }
    }

    func preferredHarbourID(from action: NautiAppAction) -> String? {
        resolveHarbourID(from: action.harbourID)
            ?? resolveHarbourID(from: action.destinationHarbourID)
            ?? resolveHarbourID(from: action.startHarbourID)
    }

    func resolveHarbourID(from rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let exact = HarbourOption.options.first(where: { $0.id.caseInsensitiveCompare(value) == .orderedSame }) {
            return exact.id
        }

        let normalized = normalizedHarbourText(value.replacingOccurrences(of: "_harbor", with: ""))
        return HarbourOption.options.first { harbour in
            let normalizedID = normalizedHarbourText(harbour.id.replacingOccurrences(of: "_harbor", with: ""))
            let normalizedName = normalizedHarbourText(harbour.name)
            let shortName = normalizedHarbourText(harbour.name.components(separatedBy: ",").first ?? harbour.name)

            return normalized == normalizedID
                || normalized == shortName
                || normalizedName.contains(normalized)
                || normalized.contains(shortName)
                || normalized.contains(normalizedID)
        }?.id
    }

    func normalizedHarbourText(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func nautiWeatherSummary(
        days: [MarineDailyForecast],
        harbour: HarbourOption,
        target: Date,
        targetHours: [MarineHourlyForecast]
    ) -> String {
        let calendar = AppDateFormatters.berlinCalendar
        let dayStart = calendar.startOfDay(for: target)
        let daily = days.first { calendar.isDate($0.date, inSameDayAs: dayStart) }

        if let daily {
            let wind = targetHours.map(\.wind.speedKnots).max() ?? daily.daytimeWind.speedKnots
            let gust = targetHours.map(\.wind.effectiveGustKnots).max()
                ?? daily.highWindKnots
                ?? daily.daytimeWind.effectiveGustKnots
            return """
            Apple Weather für \(shortHarbourName(harbour)) am \(AppDateFormatters.weekdayLong.string(from: dayStart)): \(daily.condition), \(Int(daily.lowTemperatureC.rounded())) bis \(Int(daily.highTemperatureC.rounded())) °C, Wind bis \(Int(wind.rounded())) kn, Böen bis \(Int(gust.rounded())) kn aus \(daily.daytimeWind.compassDirection). Niederschlagschance \(daily.precipitationChance) %, Menge ca. \(String(format: "%.1f", daily.precipitation.totalMM)) mm.
            """
        }

        if let first = days.first?.date,
           let last = days.last?.date {
            return """
            Apple Weather liefert in TideNode aktuell Vorhersagen von \(AppDateFormatters.weekdayLong.string(from: first)) bis \(AppDateFormatters.weekdayLong.string(from: last)). Für \(AppDateFormatters.weekdayLong.string(from: dayStart)) liegt keine Prognose vor.
            """
        }

        return "Apple Weather hat gerade keine auswertbaren Wetterdaten für \(shortHarbourName(harbour)) geliefert."
    }

    func nautiWeatherCard(
        days: [MarineDailyForecast],
        harbour: HarbourOption,
        target: Date,
        targetHours: [MarineHourlyForecast],
        sourceText: String
    ) -> NautiWeatherCard? {
        let calendar = AppDateFormatters.berlinCalendar
        let dayStart = calendar.startOfDay(for: target)
        let daily = days.first { calendar.isDate($0.date, inSameDayAs: dayStart) }

        guard let daily else { return nil }

        let slots = targetHours
            .prefix(6)
            .map {
                NautiWeatherSlot(
                    timeLabel: AppDateFormatters.hourMinute.string(from: $0.date),
                    temperatureC: $0.temperatureC,
                    windKnots: $0.wind.speedKnots,
                    windDirection: $0.wind.directionDegrees,
                    precipitationChance: $0.precipitationChance,
                    icon: $0.symbolName
                )
            }

        return NautiWeatherCard(
            harbourName: shortHarbourName(harbour),
            dayTitle: AppDateFormatters.weekdayLong.string(from: dayStart),
            condition: daily.condition,
            icon: daily.symbolName,
            minTemperatureC: daily.lowTemperatureC,
            maxTemperatureC: daily.highTemperatureC,
            maxWindKnots: targetHours.map(\.wind.speedKnots).max() ?? daily.daytimeWind.speedKnots,
            maxGustKnots: targetHours.map(\.wind.effectiveGustKnots).max() ?? daily.highWindKnots,
            precipitationChance: daily.precipitationChance,
            precipitationMM: daily.precipitation.totalMM,
            slots: slots,
            sourceText: sourceText,
            harbourID: harbour.id,
            targetDate: dayStart
        )
    }

    func nautiTideSummary(_ reading: TideReading, harbour: HarbourOption, target: Date) -> String {
        let calendar = AppDateFormatters.berlinCalendar
        let dayStart = calendar.startOfDay(for: target)
        let events = reading.events.filter { calendar.isDate($0.time, inSameDayAs: dayStart) }
        guard !events.isEmpty else {
            return "Ich habe BSH-Gezeitendaten für \(shortHarbourName(harbour)), aber keine Ereignisse am \(AppDateFormatters.weekdayLong.string(from: dayStart)) gefunden."
        }

        let summary = events.prefix(6).map {
            "\($0.type) \(AppDateFormatters.hourMinute.string(from: $0.time)) \($0.heightText)"
        }.joined(separator: ", ")
        return "BSH-Gezeiten für \(shortHarbourName(harbour)) am \(AppDateFormatters.weekdayLong.string(from: dayStart)): \(summary)."
    }

    func nautiTideCard(_ reading: TideReading, harbour: HarbourOption, target: Date, sourceText: String) -> NautiTideCard? {
        let calendar = AppDateFormatters.berlinCalendar
        let dayStart = calendar.startOfDay(for: target)
        let events = reading.events.filter { calendar.isDate($0.time, inSameDayAs: dayStart) }
        guard !events.isEmpty else { return nil }

        return NautiTideCard(
            harbourName: shortHarbourName(harbour),
            stationName: reading.stationName,
            dayTitle: AppDateFormatters.weekdayLong.string(from: dayStart),
            events: events.prefix(6).map {
                NautiTideCardEvent(
                    type: $0.type,
                    timeLabel: AppDateFormatters.hourMinute.string(from: $0.time),
                    heightMeters: $0.heightMeters,
                    heightText: $0.heightText
                )
            },
            sourceText: sourceText,
            harbourID: harbour.id,
            targetDate: dayStart
        )
    }

    func nautiWaterLevelSummary(_ forecast: WaterLevelForecast, harbour: HarbourOption, target: Date) -> String {
        let calendar = AppDateFormatters.berlinCalendar
        let dayStart = calendar.startOfDay(for: target)
        let events = forecast.events.filter { calendar.isDate($0.time, inSameDayAs: dayStart) }
        guard !events.isEmpty else {
            return "Ich habe eine BSH-Wasserstandsvorhersage für \(shortHarbourName(harbour)), aber keine Scheitelwerte am \(AppDateFormatters.weekdayLong.string(from: dayStart)) gefunden."
        }

        let summary = events.prefix(6).map {
            "\($0.type) \(AppDateFormatters.hourMinute.string(from: $0.time)) \($0.sknHeightText) (\($0.forecastText))"
        }.joined(separator: ", ")
        let issued = AppDateFormatters.shortWeekdayDateTime.string(from: forecast.issuedAt)
        return """
        BSH-Wasserstand für \(shortHarbourName(harbour)) am \(AppDateFormatters.weekdayLong.string(from: dayStart)): \(summary). Lokaler Pegel: \(forecast.stationName). Vorhersage ausgegeben: \(issued).
        """
    }

    func nautiWaterLevelAnswer(_ forecast: WaterLevelForecast, harbour: HarbourOption, target: Date) async -> String {
        let calendar = AppDateFormatters.berlinCalendar
        let dayStart = calendar.startOfDay(for: target)
        let hasForecast = forecast.events.contains { calendar.isDate($0.time, inSameDayAs: dayStart) }

        guard !hasForecast else {
            return nautiWaterLevelSummary(forecast, harbour: harbour, target: target)
        }

        let rangeText: String
        if let first = forecast.events.first?.time, let last = forecast.events.last?.time {
            rangeText = " Die aktuelle BSH-Wasserstandsvorhersage reicht von \(AppDateFormatters.shortWeekdayDateTime.string(from: first)) bis \(AppDateFormatters.shortWeekdayDateTime.string(from: last))."
        } else {
            rangeText = ""
        }

        do {
            let tide = try await BSHTideService.shared.fetch(
                for: harbour,
                around: dayStart,
                force: false
            )
            let tideText = nautiTideSummary(tide, harbour: harbour, target: target)
            return """
            Für \(AppDateFormatters.weekdayLong.string(from: dayStart)) gibt es keine BSH-Wasserstandsvorhersage mit Wind-/Stauanteil.\(rangeText) Für die langfristige Planung kann ich die astronomischen BSH-Gezeiten nutzen: \(tideText)
            """
        } catch {
            return "Für \(AppDateFormatters.weekdayLong.string(from: dayStart)) gibt es keine BSH-Wasserstandsvorhersage.\(rangeText)"
        }
    }

    func nautiWaterLevelForecast(for harbour: HarbourOption) async throws -> WaterLevelForecast {
        let station = BSHTideStationCatalog.station(for: harbour)
        guard station.hasLocalWaterLevelForecast else {
            throw BSHWaterLevelForecastError.notAvailable
        }
        return try await BSHWaterLevelForecastService.shared.fetch(station: station, force: false)
    }

    func shortHarbourName(_ harbour: HarbourOption) -> String {
        harbour.name.components(separatedBy: ",").first ?? harbour.name
    }

    @MainActor
    func openNautiWarnings() {
        closeNautiChat()
        warningsSheetShown = true
    }

    @MainActor
    func answerNautiWarnings(conversationID: UUID) async {
        if maritimeWarningsService.warnings.isEmpty && !maritimeWarningsService.isLoading {
            await maritimeWarningsService.refresh()
        }
        let unread = maritimeWarningsService.unreadCount
        let total = maritimeWarningsService.warnings.count
        let hazards = maritimeWarningsService.warnings.filter { $0.severity == .hazard }.count
        let response: String
        if total == 0 {
            response = "Aktuell liegen keine aktiven nautischen Warnmeldungen vor. Alle erfassten Schifffahrtswege in der Deutschen Bucht und Ostsee sind frei von akuten Sperrungen."
        } else {
            let hazardText = hazards > 0 ? " (\(hazards) dringende Gefahren/Sperrungen)" : ""
            response = "Es liegen aktuell \(total) amtliche nautische Warnmeldungen\(hazardText) vor, davon \(unread) ungelesen. Du kannst die Warnungen über das Glocken-Symbol im Header oder direkt in der Übersicht ansehen."
        }
        nautiViewModel.appendAssistantMessage(response, conversationID: conversationID)
    }
}
