import SwiftUI
import UIKit
import CoreLocation

extension ContentView {
    func conditionsTab() -> some View {
        ZStack {
            conditionsBackground
                .ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    conditionsSectionPicker

                    switch selectedConditionsSection {
                    case .weather:
                        weatherTab()
                            .transition(.opacity)
                    case .tides:
                        tidesTab()
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 84)
                .padding(.bottom, 124)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                await loadSelectedConditionsSection(userInitiated: true)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: selectedConditionsSection)
        .sensoryFeedback(.success, trigger: weatherRefreshFeedbackTrigger)
        .overlay(alignment: .top) {
            if let weatherRefreshToast {
                Text(weatherRefreshToast)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.72), in: Capsule())
                    .padding(.top, 132)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityAddTraits(.isStaticText)
            }
        }
    }

    private var conditionsSectionPicker: some View {
        HStack(spacing: 5) {
            ForEach(ConditionsSection.allCases) { section in
                let selected = section == selectedConditionsSection
                Button {
                    withAnimation(.easeInOut(duration: 0.24)) {
                        selectedConditionsSection = section
                    }
                } label: {
                    Label(section.label, systemImage: section.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(conditionsControlColor.opacity(selected ? 1 : 0.65))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(conditionsControlColor.opacity(selected ? 0.12 : 0), in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(conditionsControlColor.opacity(selected ? 0.28 : 0), lineWidth: 0.8)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(5)
        .appWeatherLiquidGlass(cornerRadius: 22, interactive: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Wetter oder Gezeiten anzeigen")
    }

    private var conditionsControlColor: Color {
        .white
    }

    @ViewBuilder
    private var conditionsBackground: some View {
        if selectedConditionsSection == .weather {
            ZStack {
                weatherGradient(for: selectedWeatherReport?.current)
                WeatherAtmosphereView(
                    current: selectedWeatherReport?.current,
                    isPaused: selectedTab != .conditions
                        || selectedConditionsSection != .weather
                        || selectedWeatherDay != nil
                        || scenePhase != .active
                )
                    .transition(.opacity)
            }
        } else {
            TideAtmosphereView(reading: islandTides[tideStationID] ?? tideReading)
        }
    }

    @ViewBuilder
    func weatherTab() -> some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            if weatherLoading && islandWeatherReports.isEmpty {
                weatherLoadingPanel()
            } else if let report = selectedWeatherReport {
                weatherHero(report)

                if report.isStale {
                    Label("Offline-Daten vom \(relativeAgeText(since: report.sourceUpdatedAt))", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.orange.opacity(0.75), in: Capsule())
                }

                weatherHourlyPanel(report)
                weatherWindPanel(report)
                weatherWindMapPanel(report)
                weatherWindChartPanel(report)
                weatherDailyPanel(report)

                if let attribution = weatherAttribution {
                    WeatherAttributionView(attribution: attribution)
                }
            } else if let weatherError {
                weatherErrorPanel(weatherError)
            } else {
                weatherErrorPanel("Wähle eine Insel, um die Vorhersage von Apple Weather zu laden.")
            }
        }
    }

    private var selectedWeatherReport: MarineWeatherReport? {
        if let selected = islandWeatherReports[weatherRegionID] {
            return selected
        }
        guard weatherReport?.regionID == weatherRegionID else { return nil }
        return weatherReport
    }

    func weatherHero(_ report: MarineWeatherReport) -> some View {
        VStack(spacing: 5) {
            Button {
                weatherLocationPickerShown = true
            } label: {
                HStack(spacing: 7) {
                    Text(shortIslandName(report.regionName))
                        .font(.system(size: 34, weight: .semibold))
                    Image(systemName: "chevron.down.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .opacity(0.75)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("weather-location-selector")
            .accessibilityLabel(
                "\(shortIslandName(report.regionName)), \(Int(report.current.temperatureC.rounded())) Grad. Standort ändern"
            )
            .accessibilityHint("Öffnet die Auswahl der ostfriesischen Inseln")
            .popover(
                isPresented: $weatherLocationPickerShown,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .top
            ) {
                WeatherRegionContextPopover(
                    selection: weatherRegionID,
                    harbours: islandHarbours,
                    currentWeather: islandCurrentWeather,
                    isLoading: islandCurrentWeatherLoading || windMapLoading,
                    onSelect: { harbour in
                        selectWeatherLocation(
                            harbour,
                            report: islandWeatherReports[harbour.id]
                        )
                    }
                )
                .presentationCompactAdaptation(.popover)
                .presentationBackground(Color.clear)
            }

            Text("\(Int(report.current.temperatureC.rounded()))°")
                .font(.system(size: 88, weight: .thin))
                .contentTransition(.numericText())
            Text(report.current.condition)
                .font(.system(size: 21, weight: .semibold))
            if let today = report.daily.first {
                Text("H: \(Int(today.highTemperatureC.rounded()))°  T: \(Int(today.lowTemperatureC.rounded()))°")
                    .font(.system(size: 16, weight: .semibold))
            }
            Text("Gefühlt \(Int(report.current.apparentTemperatureC.rounded()))° · Aktualisiert \(relativeAgeText(since: report.sourceUpdatedAt))")
                .font(.system(size: 12, weight: .medium))
                .opacity(0.76)
                .padding(.top, 3)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .appWeatherLiquidGlass(cornerRadius: 28)
        .accessibilityElement(children: .contain)
        .task(id: report.fetchedAt) {
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled,
                  selectedTab == .conditions,
                  selectedConditionsSection == .weather else {
                return
            }
            await loadIslandCurrentWeatherIfNeeded()
        }
    }

    func selectWeatherLocation(_ harbour: HarbourOption, report: MarineWeatherReport?) {
        withAnimation(.easeInOut(duration: 0.35)) {
            weatherRegionID = harbour.id
            weatherReport = report
            selectedWindMapHour = report?.hourly.first?.date
        }
    }

    func weatherHourlyPanel(_ report: MarineWeatherReport) -> some View {
        WeatherGlassPanel(title: "48-STUNDEN-VORHERSAGE", icon: "clock.fill") {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(report.hourly.prefix(48).enumerated()), id: \.element.id) { index, hour in
                        VStack(spacing: 9) {
                            Text(index == 0 ? "Jetzt" : weatherHourLabel(hour.date))
                                .font(.system(size: 12, weight: .bold))
                            MarineWeatherConditionSymbol(
                                symbolName: hour.symbolName,
                                pointSize: 23,
                                accessibilityLabel: hour.condition
                            )
                                .frame(height: 26)
                            Text("\(Int(hour.temperatureC.rounded()))°")
                                .font(.system(size: 18, weight: .semibold))
                            if hour.precipitationChance > 0 {
                                precipitationBadge(hour.precipitationChance)
                            } else {
                                Color.clear
                                    .frame(width: 42, height: 18)
                            }
                            VStack(spacing: 1) {
                                Text("\(Int(hour.wind.speedKnots.rounded())) kn")
                                Text("B \(Int(hour.wind.effectiveGustKnots.rounded()))")
                                    .opacity(0.68)
                            }
                            .font(.system(size: 10, weight: .bold))
                        }
                        .frame(width: 68)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    func weatherWindPanel(_ report: MarineWeatherReport) -> some View {
        WeatherGlassPanel(title: "WIND IM REVIER", icon: "wind") {
            HStack(spacing: 16) {
                WindCompassRose(wind: report.current.wind)
                    .frame(width: 138, height: 138)

                VStack(alignment: .leading, spacing: 11) {
                    windValueRow("Grundwind", value: "\(Int(report.current.wind.speedKnots.rounded())) kn")
                    windValueRow("Böen", value: "\(Int(report.current.wind.effectiveGustKnots.rounded())) kn")
                    windValueRow("Richtung", value: "\(report.current.wind.compassDirection) · \(report.current.wind.directionDegrees)°")
                    Divider().overlay(Color.white.opacity(0.25))
                    Text("Wind aus \(report.current.wind.compassDescription)")
                        .font(.system(size: 12, weight: .semibold))
                        .opacity(0.74)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func windValueRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .opacity(0.72)
            Spacer()
            Text(value)
                .font(.system(size: 16, weight: .bold))
        }
    }

    func weatherWindMapPanel(_ report: MarineWeatherReport) -> some View {
        let selectedDate = selectedWindMapHour ?? report.hourly.first?.date ?? .now
        return WeatherGlassPanel(title: "WINDKARTE OSTFRIESLAND", icon: "map.fill") {
            VStack(spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(Array(report.hourly.prefix(24))) { hour in
                            let selected = abs(hour.date.timeIntervalSince(selectedDate)) < 1
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedWindMapHour = hour.date
                                }
                            } label: {
                                VStack(spacing: 2) {
                                    Text(weatherMapDayLabel(hour.date))
                                        .font(.system(size: 9, weight: .bold))
                                        .opacity(0.7)
                                    Text(weatherHourLabel(hour.date))
                                        .font(.system(size: 12, weight: .bold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(selected ? Color.cyan.opacity(0.26) : Color.white.opacity(0.08), in: Capsule())
                                .overlay(Capsule().stroke(Color.white.opacity(selected ? 0.42 : 0.12), lineWidth: 0.7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                IslandWindMapView(
                    harbours: islandHarbours,
                    forecasts: islandWindForecasts,
                    selectedDate: selectedDate
                )
                .frame(height: 310)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                if windMapLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(.white)
                        Text("Weitere Inselpunkte werden geladen…")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.78))
                }

            }
        }
        .task(id: report.fetchedAt) {
            await loadWindMapWeatherIfNeeded()
        }
    }

    func weatherWindChartPanel(_ report: MarineWeatherReport) -> some View {
        WeatherGlassPanel(title: "WIND UND BÖEN", icon: "chart.xyaxis.line") {
            WindSpeedChart(hours: report.hourly)
                .frame(height: 300)
        }
    }

    func weatherDailyPanel(_ report: MarineWeatherReport) -> some View {
        WeatherGlassPanel(title: "7-TAGE-VORHERSAGE", icon: "calendar") {
            VStack(spacing: 0) {
                ForEach(Array(report.daily.prefix(7).enumerated()), id: \.element.id) { index, day in
                    Button {
                        let hours = report.hourly.filter {
                            AppDateFormatters.berlinCalendar.isDate($0.date, inSameDayAs: day.date)
                        }
                        selectedWeatherDay = WeatherDaySelection(day: day, harbour: weatherHarbour, initialHours: hours)
                    } label: {
                        HStack(spacing: 12) {
                            Text(weatherDayLabel(day.date, index: index))
                                .font(.system(size: 15, weight: .bold))
                                .frame(width: 82, alignment: .leading)
                            MarineWeatherConditionSymbol(
                                symbolName: day.symbolName,
                                pointSize: 21,
                                accessibilityLabel: day.condition
                            )
                                .frame(width: 32)
                            if day.precipitationChance > 0 {
                                precipitationBadge(day.precipitationChance)
                                    .frame(width: 46)
                            } else {
                                Spacer().frame(width: 46)
                            }
                            Spacer()
                            Text("\(Int(day.lowTemperatureC.rounded()))°")
                                .opacity(0.65)
                            TemperatureRangeBar(day: day, allDays: report.daily)
                                .frame(width: 70, height: 5)
                            Text("\(Int(day.highTemperatureC.rounded()))°")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                                .opacity(0.55)
                        }
                        .foregroundStyle(.white)
                        .padding(.vertical, 13)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("weather-day-\(index)")

                    if index < min(report.daily.count, 7) - 1 {
                        Divider().overlay(Color.white.opacity(0.18))
                    }
                }
            }
        }
    }

    private func precipitationBadge(_ chance: Int) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "drop.fill")
                .font(.system(size: 8, weight: .bold))
            Text("\(chance)%")
                .font(.system(size: 10, weight: .heavy))
        }
        .foregroundStyle(Color(hex: 0xA6EAFF))
        .padding(.horizontal, 5)
        .frame(height: 18)
        .background(Color.black.opacity(0.3), in: Capsule())
        .overlay(Capsule().stroke(Color.cyan.opacity(0.38), lineWidth: 0.6))
        .accessibilityLabel("Niederschlagswahrscheinlichkeit \(chance) Prozent")
    }

    func weatherLoadingPanel() -> some View {
        WeatherGlassPanel(title: "APPLE WEATHER", icon: "cloud.sun.fill") {
            HStack(spacing: 14) {
                ProgressView()
                    .tint(.white)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Revierdaten werden geladen")
                        .font(.system(size: 17, weight: .bold))
                    Text("Wind, Böen und die 7-Tage-Prognose werden abgerufen.")
                        .font(.system(size: 12, weight: .medium))
                        .opacity(0.72)
                }
            }
        }
    }

    func weatherErrorPanel(_ message: String) -> some View {
        WeatherGlassPanel(title: "WETTER NICHT VERFÜGBAR", icon: "exclamationmark.icloud.fill") {
            VStack(alignment: .leading, spacing: 14) {
                Text(message)
                    .font(.system(size: 14, weight: .medium))
                Button {
                    Task { await loadWeather(userInitiated: true) }
                } label: {
                    Label("Erneut versuchen", systemImage: "arrow.clockwise")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    func weatherGradient(for current: MarineCurrentWeather?) -> LinearGradient {
        let colors: [Color]
        guard let current else {
            return LinearGradient(colors: [Color(hex: 0x355C7D), Color(hex: 0x203A56)], startPoint: .top, endPoint: .bottom)
        }

        let condition = current.condition.lowercased()
        if condition.contains("gewitter") || condition.contains("sturm") {
            colors = [Color(hex: 0x303A52), Color(hex: 0x151B2A), Color(hex: 0x33465C)]
        } else if condition.contains("regen") || condition.contains("niesel") {
            colors = [Color(hex: 0x537895), Color(hex: 0x2F4C63), Color(hex: 0x182D3D)]
        } else if condition.contains("nebel") || condition.contains("dunst") {
            colors = [Color(hex: 0x8EA4B2), Color(hex: 0x5E788A), Color(hex: 0x324A5A)]
        } else if !current.isDaylight {
            colors = [Color(hex: 0x162545), Color(hex: 0x10182E), Color(hex: 0x26345C)]
        } else if current.cloudCoverPercent > 65 {
            colors = [Color(hex: 0x6D8FA7), Color(hex: 0x496A83), Color(hex: 0x2D4B63)]
        } else {
            colors = [Color(hex: 0x3B8FCC), Color(hex: 0x2B6FA8), Color(hex: 0x17486F)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    func shortIslandName(_ name: String) -> String {
        name.components(separatedBy: ",").first ?? name
    }

    func relativeAgeText(since date: Date) -> String {
        let seconds = max(Date().timeIntervalSince(date), 0)
        if seconds < 60 { return "gerade eben" }
        if seconds < 3_600 { return "vor \(Int(seconds / 60)) Min." }
        return "vor \(Int(seconds / 3_600)) Std."
    }

    private func weatherHourLabel(_ date: Date) -> String {
        AppDateFormatters.hourMinute.string(from: date)
    }

    private func weatherMapDayLabel(_ date: Date) -> String {
        AppDateFormatters.weekdayShort.string(from: date)
    }

    private func weatherDayLabel(_ date: Date, index: Int) -> String {
        if index == 0 { return "Heute" }
        return AppDateFormatters.weekdayShort.string(from: date)
    }

    @MainActor
    func loadWeather(userInitiated: Bool) async {
        let islands = islandHarbours
        guard !islands.isEmpty else { return }
        let selectedID = islands.contains(where: { $0.id == weatherRegionID }) ? weatherRegionID : islands[0].id
        let harbour = HarbourOption.byID(selectedID)

        weatherRegionID = selectedID
        weatherLoading = true
        weatherError = nil
        writeAudit(
            action: "FETCH",
            source: "weatherkit",
            statement: "FETCH Apple Weather area='\(harbour.id)' hours=48 days=7 policy='\(userInitiated ? "manualRetry" : "revalidateExpired")'",
            status: "pending"
        )

        async let attributionResult = loadWeatherAttributionIfNeeded()
        defer { weatherLoading = false }

        do {
            let result = try await maritimeWeatherService.report(
                for: harbour,
                policy: userInitiated ? .manualRetry : .revalidateExpired
            )
            let report = result.report
            islandWeatherReports[harbour.id] = report
            islandCurrentWeather[harbour.id] = report.current
            islandWindForecasts[harbour.id] = report.hourly
            weatherReport = report
            upsertWeatherSnapshot(report, for: harbour)
            weatherError = nil
            if selectedWindMapHour == nil {
                selectedWindMapHour = report.hourly.first?.date
            }

            switch result.outcome {
            case .cacheHit(let validUntil):
                writeAudit(action: "READ", source: "weather-cache", statement: "SELECT fresh weather area='\(report.regionID)'", status: "ok")
                if userInitiated {
                    showWeatherCacheFeedback(validUntil: validUntil)
                }
            case .refreshed(let datasets):
                let products = datasets.map(\.kind.rawValue).sorted().joined(separator: ",")
                writeAudit(action: "FETCH", source: "weatherkit", statement: "FETCH refreshed products='\(products)' area='\(report.regionID)'", status: "ok")
            case .retryBlocked(let until):
                showWeatherToast("Nächster Wetterabruf ab \(AppDateFormatters.hourMinute.string(from: until))")
                writeAudit(action: "READ", source: "weather-cache", statement: "SELECT stale weather during retry cooldown", status: "blocked")
            }
            _ = await attributionResult
            try? modelContext.save()
        } catch {
            _ = await attributionResult
            weatherError = error.localizedDescription
            if weatherReport == nil {
                weatherReport = islandWeatherReports[selectedID]
            }
            writeAudit(action: "FETCH", source: "weatherkit", statement: "FETCH Apple Weather area='\(harbour.id)'", status: "error")
        }
    }

    @MainActor
    private func loadWeatherAttributionIfNeeded() async {
        guard weatherAttribution == nil else { return }
        weatherAttribution = (try? await maritimeWeatherService.attribution()) ?? .fallback
    }

    @MainActor
    func loadIslandCurrentWeatherIfNeeded() async {
        guard !islandCurrentWeatherLoading else { return }
        let missingHarbours = islandHarbours.filter { islandCurrentWeather[$0.id] == nil }
        guard !missingHarbours.isEmpty else { return }

        islandCurrentWeatherLoading = true
        defer { islandCurrentWeatherLoading = false }

        let coordinates = missingHarbours.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        let results = await maritimeWeatherService.weatherForLocations(
            coordinates,
            datasets: [.current],
            policy: .revalidateExpired
        )

        var updatedWeather = islandCurrentWeather
        for harbour in missingHarbours {
            guard let area = CLLocationCoordinate2D(
                latitude: harbour.latitude,
                longitude: harbour.longitude
            ).maritimeWeatherArea(),
            case .success(let snapshot) = results[area],
            let current = snapshot.current else {
                continue
            }
            updatedWeather[harbour.id] = current
        }
        islandCurrentWeather = updatedWeather
    }

    @MainActor
    func loadWindMapWeatherIfNeeded() async {
        guard !windMapLoading else { return }
        let missingHarbours = islandHarbours.filter {
            islandWindForecasts[$0.id]?.isEmpty != false
        }
        guard !missingHarbours.isEmpty else { return }

        let now = Date()
        let calendar = AppDateFormatters.berlinCalendar
        let start = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let end = calendar.date(byAdding: .hour, value: 48, to: start)
            ?? start.addingTimeInterval(48 * 3_600)
        let coordinates = missingHarbours.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }

        windMapLoading = true
        defer { windMapLoading = false }
        let results = await maritimeWeatherService.weatherForLocations(
            coordinates,
            datasets: [.current, .hourly(DateInterval(start: start, end: end))],
            policy: .revalidateExpired
        )
        var updatedCurrentWeather = islandCurrentWeather
        var updatedForecasts = islandWindForecasts
        for harbour in missingHarbours {
            guard let area = CLLocationCoordinate2D(
                latitude: harbour.latitude,
                longitude: harbour.longitude
            ).maritimeWeatherArea(),
            case .success(let snapshot) = results[area] else {
                continue
            }
            if let current = snapshot.current {
                updatedCurrentWeather[harbour.id] = current
            }
            updatedForecasts[harbour.id] = snapshot.hourly
        }
        islandCurrentWeather = updatedCurrentWeather
        islandWindForecasts = updatedForecasts
    }

    var routeWeatherRequestKey: String {
        guard let plan = viewModel.routePlan else { return "route-weather:none" }
        let points = plan.waypoints.map {
            "\($0.latitude ?? 999),\($0.longitude ?? 999)"
        }.joined(separator: "|")
        let resultStamp = viewModel.calculationResult?.waypointResults.last?.arrivalTime.timeIntervalSince1970 ?? -1
        return "\(plan.id.uuidString):\(plan.plannedStartTime.timeIntervalSince1970):\(resultStamp):\(points)"
    }

    @MainActor
    func validateCurrentRouteWeather() async {
        guard !viewModel.isCalculating,
              let plan = viewModel.routePlan,
              let calculationResult = viewModel.calculationResult,
              calculationResult.waypointResults.count == plan.waypoints.count else {
            return
        }

        let coordinates = plan.waypoints.compactMap { waypoint -> CLLocationCoordinate2D? in
            guard let latitude = waypoint.latitude, let longitude = waypoint.longitude else { return nil }
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        let total = Set(coordinates.compactMap { $0.maritimeWeatherArea() }).count
        let validationID = viewModel.beginRouteWeatherValidation(total: total)
        guard coordinates.count == plan.waypoints.count, total > 0 else {
            viewModel.failRouteWeatherValidation(
                MarineWeatherError.invalidCoordinate.localizedDescription,
                id: validationID
            )
            return
        }

        do {
            let batch = try await maritimeWeatherService.weatherForRoute(
                waypoints: coordinates,
                departure: plan.plannedStartTime
            ) { progress in
                await MainActor.run {
                    viewModel.updateRouteWeatherProgress(progress, id: validationID)
                }
            }
            guard !Task.isCancelled else { return }
            viewModel.finishRouteWeatherValidation(batch, id: validationID)
        } catch {
            guard !Task.isCancelled else { return }
            viewModel.failRouteWeatherValidation(error.localizedDescription, id: validationID)
        }
    }

    @MainActor
    private func showWeatherCacheFeedback(validUntil: Date) {
        weatherRefreshFeedbackTrigger += 1
        let message = "Wetterdaten sind aktuell bis \(AppDateFormatters.hourMinute.string(from: validUntil))"
        showWeatherToast(message)
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    @MainActor
    private func showWeatherToast(_ message: String) {
        let id = UUID()
        weatherRefreshToastID = id
        withAnimation(.easeOut(duration: 0.2)) {
            weatherRefreshToast = message
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard weatherRefreshToastID == id else { return }
            withAnimation(.easeIn(duration: 0.2)) {
                weatherRefreshToast = nil
            }
        }
    }

    @MainActor
    func upsertWeatherSnapshot(_ report: MarineWeatherReport, for region: HarbourOption) {
        let summary = String(
            format: "%.0f°C · %.0f kn · Böen %.0f kn · %@",
            report.current.temperatureC,
            report.current.wind.speedKnots,
            report.current.wind.effectiveGustKnots,
            report.current.condition
        )
        let slots = report.hourly.prefix(12).map {
            "\(Self.slotFormatter.string(from: $0.date)) \(Int($0.temperatureC.rounded()))°/\(Int($0.wind.speedKnots.rounded()))kn/B\(Int($0.wind.effectiveGustKnots.rounded()))"
        }.joined(separator: " | ")

        if let existing = weatherSnapshots.first(where: { $0.regionID == region.id }) {
            existing.regionName = region.name
            existing.stationID = "weatherkit"
            existing.stationName = "Apple Weather"
            existing.currentSummary = summary
            existing.slotSummary = slots
            existing.fetchedAt = report.fetchedAt
        } else {
            modelContext.insert(
                WeatherSnapshot(
                    regionID: region.id,
                    regionName: region.name,
                    stationID: "weatherkit",
                    stationName: "Apple Weather",
                    currentSummary: summary,
                    slotSummary: slots,
                    fetchedAt: report.fetchedAt
                )
            )
        }

        writeAudit(
            action: "INSERT",
            source: "weatherkit",
            statement: "UPSERT weather_snapshot provider='Apple Weather' region='\(region.id)' fetched_at='\(Self.isoFormatter.string(from: report.fetchedAt))'",
            status: "ok"
        )
    }
}

private struct WeatherRegionContextPopover: View {
    @Environment(\.dismiss) private var dismiss

    let selection: String
    let harbours: [HarbourOption]
    let currentWeather: [String: MarineCurrentWeather]
    let isLoading: Bool
    let onSelect: (HarbourOption) -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Revier auswählen")
                        .font(.system(size: 16, weight: .bold))
                    Text("Ostfriesische Inseln")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.68))
                }

                Spacer(minLength: 8)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .accessibilityLabel("Temperaturen werden aktualisiert")
                }

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Standortauswahl schließen")
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 5)

            ForEach(harbours) { harbour in
                locationRow(harbour)
            }
        }
        .foregroundStyle(.white)
        .padding(6)
        .frame(width: 278)
        .background(
            Color(hex: 0x153B54).opacity(0.18),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .appFloatingOverlay(
            cornerRadius: 22,
            tint: Color(hex: 0x173F5A).opacity(0.38)
        )
        .padding(7)
    }

    private func locationRow(_ harbour: HarbourOption) -> some View {
        let current = currentWeather[harbour.id]
        let selected = harbour.id == selection

        return Button {
            onSelect(harbour)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Text(shortName(harbour.name))
                    .font(.system(size: 14, weight: selected ? .bold : .semibold))
                    .lineLimit(1)

                Spacer(minLength: 10)

                Text(current.map { "\(Int($0.temperatureC.rounded()))°" } ?? "–°")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                    .monospacedDigit()
            }
            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.84))
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(
                selected ? Color.white.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(alignment: .leading) {
                if selected {
                    Capsule()
                        .fill(Color.cyan.opacity(0.95))
                        .frame(width: 3, height: 18)
                        .padding(.leading, 4)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(shortName(harbour.name)), "
                + (current.map { "\(Int($0.temperatureC.rounded())) Grad" } ?? "Temperatur wird geladen")
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func shortName(_ name: String) -> String {
        name.split(separator: ",", maxSplits: 1).first.map(String.init) ?? name
    }
}

struct MarineWeatherConditionSymbol: View {
    let symbolName: String
    let pointSize: CGFloat
    let accessibilityLabel: String

    var body: some View {
        let colors = palette
        Image(systemName: symbolName)
            .font(.system(size: pointSize, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(colors.primary, colors.secondary, colors.tertiary)
            .shadow(color: colors.shadow, radius: 1.5, y: 1)
            .accessibilityLabel(accessibilityLabel)
    }

    private var palette: WeatherSymbolPalette {
        let name = symbolName.lowercased()
        let cloud = Color(red: 0.58, green: 0.80, blue: 1.00)
        let cloudShade = Color(red: 0.26, green: 0.57, blue: 0.95)
        let rain = Color(red: 0.15, green: 0.82, blue: 0.96)
        let sun = Color(red: 1.00, green: 0.78, blue: 0.16)
        let warmSun = Color(red: 1.00, green: 0.52, blue: 0.12)
        let moon = Color(red: 0.86, green: 0.89, blue: 1.00)
        let night = Color(red: 0.48, green: 0.56, blue: 0.96)

        if name.contains("bolt") || name.contains("thunder") {
            return WeatherSymbolPalette(primary: sun, secondary: rain, tertiary: cloud)
        }
        if name.contains("snow") || name.contains("sleet") || name.contains("hail") {
            return WeatherSymbolPalette(primary: .white, secondary: rain, tertiary: cloudShade)
        }
        if name.contains("rain") || name.contains("drizzle") || name.contains("showers") {
            return WeatherSymbolPalette(primary: rain, secondary: cloud, tertiary: cloudShade)
        }
        if name.contains("fog") || name.contains("haze") || name.contains("smoke") {
            return WeatherSymbolPalette(primary: cloud, secondary: cloudShade, tertiary: rain)
        }
        if name.contains("wind") || name.contains("tropicalstorm") || name.contains("hurricane") {
            return WeatherSymbolPalette(primary: rain, secondary: cloud, tertiary: night)
        }
        if name.contains("sun") && name.contains("cloud") {
            return WeatherSymbolPalette(primary: cloud, secondary: sun, tertiary: warmSun)
        }
        if name.contains("moon") && name.contains("cloud") {
            return WeatherSymbolPalette(primary: moon, secondary: cloud, tertiary: night)
        }
        if name.contains("sun") {
            return WeatherSymbolPalette(primary: sun, secondary: warmSun, tertiary: cloud)
        }
        if name.contains("moon") || name.contains("star") {
            return WeatherSymbolPalette(primary: moon, secondary: night, tertiary: .white)
        }
        return WeatherSymbolPalette(primary: cloud, secondary: cloudShade, tertiary: rain)
    }
}

private struct WeatherSymbolPalette {
    let primary: Color
    let secondary: Color
    let tertiary: Color

    var shadow: Color {
        Color.black.opacity(0.24)
    }
}
