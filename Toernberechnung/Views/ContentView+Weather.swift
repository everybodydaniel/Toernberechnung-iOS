import SwiftUI

extension ContentView {
    func weatherTab() -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DWD-WETTER OSTFRIESISCHE INSELN")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.secondary)

            weatherIslandSelector()

            if weatherLoading && islandWeather.isEmpty {
                weatherPlaceholder(icon: "cloud.sun.fill", title: "DWD-Wetter wird geladen", text: "Die aktuellen MOSMIX-Daten der ostfriesischen Inseln werden abgerufen.")
            } else if let weatherError, islandWeather.isEmpty {
                weatherPlaceholder(icon: "wifi.slash", title: "Wetter konnte nicht geladen werden", text: weatherError)
            } else if let reading = islandWeather[weatherRegionID] ?? weatherReading {
                weatherHeroCard(reading)
                weatherHourlyCard(reading)
                weatherMetricsGrid(reading)
                weatherDailyCard(reading)
            } else {
                weatherPlaceholder(icon: "cloud.sun.fill", title: "Insel auswählen", text: "Wähle eine ostfriesische Insel, um die DWD-Prognose zu sehen.")
            }
        }
    }

    func weatherIslandSelector() -> some View {
        card {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(islandHarbours) { harbour in
                        let reading = islandWeather[harbour.id]
                        let selected = weatherRegionID == harbour.id
                        Button {
                            weatherRegionID = harbour.id
                            weatherReading = reading
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: reading?.current.icon ?? "cloud.sun.fill")
                                    .font(.system(size: 16, weight: .bold))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(weatherAccent(for: reading), Color(hex: 0x6EA8D8))
                                    .frame(width: 30, height: 30)
                                    .background(selected ? Color(hex: 0xD8F0FF) : Color.fieldBackground, in: Circle())

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(shortIslandName(harbour.name))
                                        .font(.system(size: 13, weight: .heavy))
                                        .foregroundStyle(selected ? Color.appPrimary : Color.primary)
                                        .lineLimit(1)
                                    Text(reading.map { String(format: "%.0f° · %@", $0.current.temperatureC, $0.current.condition) } ?? "lädt")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Color.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .frame(minWidth: 132, alignment: .leading)
                            .background(selected ? Color(hex: 0xEEF8FF) : Color.fieldBackground, in: Capsule())
                            .overlay {
                                Capsule()
                                    .stroke(selected ? Color(hex: 0x6EA8D8).opacity(0.65) : Color.clear, lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    func weatherHeroCard(_ reading: WeatherReading) -> some View {
        weatherGlassCard(style: .hero) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(shortIslandName(reading.regionName))
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }

                    Spacer()

                    Image(systemName: reading.current.icon)
                        .font(.system(size: 56, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(weatherAccent(for: reading), .white.opacity(0.9))
                }

                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text(String(format: "%.0f°", reading.current.temperatureC))
                        .font(.system(size: 68, weight: .thin))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(reading.current.condition)
                            .font(.system(size: 22, weight: .heavy))
                            .foregroundStyle(.white)
                        if let today = reading.daily.first {
                            Text(String(format: "H: %.0f°  T: %.0f°", today.maxTemperatureC, today.minTemperatureC))
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white.opacity(0.78))
                        }
                    }
                }

            }
        }
    }

    func weatherHourlyCard(_ reading: WeatherReading) -> some View {
        weatherGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("STÜNDLICHE VORHERSAGE", systemImage: "clock.fill")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(Color.secondary)

                Divider()

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(reading.upcoming) { slot in
                            VStack(spacing: 10) {
                                Text(hourLabel(slot.time, current: slot.id == reading.upcoming.first?.id))
                                    .font(.system(size: 14, weight: .heavy))
                                    .foregroundStyle(Color.primary)
                                    .frame(height: 18)
                                Image(systemName: slot.icon)
                                    .font(.system(size: 24, weight: .semibold))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(weatherAccent(for: slot), .white.opacity(0.85))
                                    .frame(height: 28)
                                Text(String(format: "%.0f°", slot.temperatureC))
                                    .font(.system(size: 20, weight: .heavy))
                                    .foregroundStyle(Color.primary)
                                Text("\(Int(slot.windKnots.rounded())) kn")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Color.secondary)
                            }
                            .frame(width: 54)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    func weatherMetricsGrid(_ reading: WeatherReading) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: compactColumns.count > 1 ? 4 : 2), spacing: 12) {
            weatherMetricCard(icon: "wind", title: "Wind", value: "\(Int(reading.current.windKnots.rounded())) kn")
            weatherMetricCard(icon: "wind.circle.fill", title: "Böen", value: reading.current.windGustKnots.map { "\(Int($0.rounded())) kn" } ?? "-")
            weatherMetricCard(icon: "drop.fill", title: "Niederschlag", value: String(format: "%.1f mm", reading.current.precipitationMM))
            weatherMetricCard(icon: "humidity.fill", title: "Feuchtigkeit", value: reading.current.humidityPercent.map { "\($0)%" } ?? "-")
            weatherMetricCard(icon: "thermometer.medium", title: "Gefühlt", value: String(format: "%.0f°", reading.current.feelsLikeC))
            weatherMetricCard(icon: "barometer", title: "Luftdruck", value: reading.current.pressureHPA.map { String(format: "%.0f hPa", $0) } ?? "-")
            weatherMetricCard(icon: "eye.fill", title: "Sichtweite", value: reading.current.visibilityKM.map { String(format: "%.0f km", $0) } ?? "-")
            weatherMetricCard(icon: "cloud.fill", title: "Bewölkung", value: reading.current.cloudCoverPercent.map { "\($0)%" } ?? "-")
        }
    }

    func weatherDailyCard(_ reading: WeatherReading) -> some View {
        weatherGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("7-TAGE-VORHERSAGE", systemImage: "calendar")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(Color.secondary)

                Divider()

                ForEach(reading.daily) { day in
                    HStack(spacing: 12) {
                        Text(dayLabel(day.date))
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .frame(width: 68, alignment: .leading)
                        Image(systemName: day.icon)
                            .font(.system(size: 21, weight: .bold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(weatherAccent(for: day), .white.opacity(0.82))
                            .frame(width: 30)
                        Text("\(day.precipitationChance)%")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(day.precipitationChance > 20 ? Color(hex: 0x0077B6) : Color.secondary)
                            .frame(width: 38, alignment: .leading)
                        Text(String(format: "%.0f°", day.minTemperatureC))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.secondary)
                            .frame(width: 36, alignment: .trailing)
                        GeometryReader { proxy in
                            let range = max((reading.daily.map(\.maxTemperatureC).max() ?? 1) - (reading.daily.map(\.minTemperatureC).min() ?? 0), 1)
                            let globalMin = reading.daily.map(\.minTemperatureC).min() ?? day.minTemperatureC
                            let leading = CGFloat((day.minTemperatureC - globalMin) / range) * proxy.size.width
                            let width = max(CGFloat((day.maxTemperatureC - day.minTemperatureC) / range) * proxy.size.width, 26)

                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.fieldBackground).frame(height: 5)
                                Capsule()
                                    .fill(LinearGradient(colors: [Color(hex: 0x75E0D0), Color(hex: 0xFFE16A)], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: width, height: 5)
                                    .offset(x: min(leading, max(proxy.size.width - width, 0)))
                            }
                        }
                        .frame(height: 16)
                        Text(String(format: "%.0f°", day.maxTemperatureC))
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundStyle(Color.primary)
                            .frame(width: 38, alignment: .trailing)
                    }
                    .frame(minHeight: 38)
                }
            }
        }
    }

    func weatherMetricCard(icon: String, title: String, value: String) -> some View {
        weatherGlassCard(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Label(title.uppercased(), systemImage: icon)
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(value)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.appPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        }
    }

    func weatherPlaceholder(icon: String, title: String, text: String) -> some View {
        weatherGlassCard {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(Color(hex: 0x3C82FF))
                Text(title)
                    .font(.system(size: 24, weight: .heavy))
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.center)
                Text(text)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        }
    }

    enum WeatherCardStyle {
        case plain, hero
    }

    func weatherGlassCard<Content: View>(cornerRadius: CGFloat = 22, style: WeatherCardStyle = .plain, @ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return Group {
            if style == .hero {
                content()
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        weatherSkyBackground()
                            .clipShape(shape)
                    }
                    .overlay {
                        LinearGradient(
                            colors: [.white.opacity(0.24), .white.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .clipShape(shape)
                    }
                    .overlay { shape.stroke(.white.opacity(0.42), lineWidth: 1) }
            } else {
                content()
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.cardBackground, in: shape)
                    .overlay { shape.stroke(Color.primary.opacity(0.06), lineWidth: 1) }
            }
        }
        .shadow(color: style == .hero ? Color.appPrimary.opacity(0.06) : .clear, radius: style == .hero ? 12 : 0, y: style == .hero ? 8 : 0)
    }

    func weatherSkyBackground() -> some View {
        LinearGradient(
            colors: [
                Color(hex: 0x72B8EA),
                Color(hex: 0x2581C3),
                Color(hex: 0x0F69B0),
                Color(hex: 0x2E9AA1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    func weatherAccent(for reading: WeatherReading?) -> Color {
        guard let reading else { return Color(hex: 0xFFE16A) }
        return weatherAccent(for: reading.current)
    }

    func weatherAccent(for slot: WeatherSlot) -> Color {
        if slot.icon.contains("rain") || slot.icon.contains("bolt") { return Color(hex: 0x0077B6) }
        if slot.icon.contains("snow") { return .white }
        if slot.icon.contains("cloud") { return Color(hex: 0x79BDE8) }
        return Color(hex: 0xF7C948)
    }

    func weatherAccent(for day: DailyWeatherSummary) -> Color {
        if day.icon.contains("rain") || day.icon.contains("bolt") { return Color(hex: 0x0077B6) }
        if day.icon.contains("snow") { return .white }
        if day.icon.contains("cloud") { return Color(hex: 0x79BDE8) }
        return Color(hex: 0xF7C948)
    }

    func shortIslandName(_ name: String) -> String {
        name
            .replacingOccurrences(of: ", Hafen", with: "")
            .replacingOccurrences(of: ", Fischerbalje", with: "")
    }

    func weatherNarrative(_ reading: WeatherReading) -> String {
        let slot = reading.current
        let gust = slot.windGustKnots.map { ", Böen bis \(Int($0.rounded())) kn" } ?? ""
        let rain = slot.precipitationChance > 20 ? ", \(slot.precipitationChance)% Regenwahrscheinlichkeit" : ""
        return "\(slot.condition) bei \(Int(slot.windKnots.rounded())) kn aus \(windDirectionText(slot.windDirection))\(gust)\(rain)."
    }

    func freshnessText(_ reading: WeatherReading) -> String {
        let timestamp = reading.dataTimestamp
        let age = relativeAgeText(since: timestamp)
        let sourceTime = Self.timeFormatter.string(from: timestamp)
        return "\(reading.isFresh ? "aktuell" : "veraltet") · Quelle \(sourceTime), \(age)"
    }

    func relativeAgeText(since date: Date) -> String {
        let minutes = max(Int(Date().timeIntervalSince(date) / 60), 0)
        if minutes < 1 { return "gerade eben" }
        if minutes < 60 { return "vor \(minutes) Min." }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "vor \(hours) Std." : "vor \(hours) Std. \(rest) Min."
    }

    func hourLabel(_ date: Date, current: Bool) -> String {
        current ? "Jetzt" : Self.slotFormatter.string(from: date)
    }

    func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Heute" }
        if Calendar.current.isDateInTomorrow(date) { return "Morgen" }
        return Self.weatherDayFormatter.string(from: date)
    }

    func windDirectionText(_ degrees: Int) -> String {
        let directions = ["N", "NO", "O", "SO", "S", "SW", "W", "NW"]
        let index = Int((Double(degrees).truncatingRemainder(dividingBy: 360) / 45).rounded()) % directions.count
        return directions[index]
    }

    static let weatherDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "E"
        return formatter
    }()

    func loadWeather(force: Bool) async {
        let islands = islandHarbours
        let selectedID = islands.contains(where: { $0.id == weatherRegionID }) ? weatherRegionID : islands[0].id

        await MainActor.run {
            if weatherRegionID != selectedID {
                weatherRegionID = selectedID
            }
            weatherLoading = true
            weatherError = nil
            writeAudit(
                action: "FETCH",
                source: "weather",
                statement: "FETCH DWD MOSMIX_L island_bundle='\(islands.map(\.weatherStationID).joined(separator: ","))' day='\(Self.isoFormatter.string(from: .now))'",
                status: "pending"
            )
        }

        if !force, !islandWeather.isEmpty {
            await MainActor.run {
                weatherReading = islandWeather[selectedID]
                weatherLoading = false
            }
            return
        }

        var loadedCount = 0
        var failures: [String] = []

        for harbour in islands {
            if !force, let cached = islandWeather[harbour.id] {
                loadedCount += 1
                await MainActor.run {
                    if harbour.id == selectedID { weatherReading = cached }
                }
                continue
            }

            do {
                let reading = try await DWDCompactService.shared.fetch(for: harbour, force: force)
                loadedCount += 1
                await MainActor.run {
                    islandWeather[harbour.id] = reading
                    if harbour.id == selectedID { weatherReading = reading }
                    upsertWeatherSnapshot(reading, for: harbour)
                    try? modelContext.save()
                }
            } catch {
                failures.append("\(harbour.name): \(error.localizedDescription)")
            }
        }

        await MainActor.run {
            weatherLoading = false
            weatherReading = islandWeather[selectedID] ?? weatherReading
            if loadedCount == 0 {
                weatherError = failures.first ?? "Für die ostfriesischen Inseln konnten keine DWD-Daten geladen werden."
                writeAudit(action: "FETCH", source: "weather", statement: "FETCH DWD MOSMIX_L island weather bundle", status: "error")
            } else {
                weatherError = failures.isEmpty ? nil : failures.joined(separator: " | ")
                writeAudit(action: "READ", source: "weather", statement: "SELECT island, current_summary, data_age FROM weather_snapshots WHERE area = 'ostfriesische_inseln'", status: "ok")
            }
        }
    }

    @MainActor
    func upsertWeatherSnapshot(_ reading: WeatherReading, for region: HarbourOption) {
        // Pro Region bleibt ein aktueller Snapshot erhalten, damit das Logbuch später kompakte Wetterdaten übernehmen kann.
        let summary = String(format: "%.0f°C · %.0f kn · %@ · %@", reading.current.temperatureC, reading.current.windKnots, reading.current.condition, freshnessText(reading))
        let slots = reading.upcoming.map {
            "\(Self.slotFormatter.string(from: $0.time)) \(Int($0.temperatureC.rounded()))°/\(Int($0.windKnots.rounded()))kn/\($0.precipitationChance)%"
        }.joined(separator: " | ")

        if let existing = weatherSnapshots.first(where: { $0.regionID == region.id }) {
            existing.regionName = region.name
            existing.stationID = reading.stationID
            existing.stationName = reading.stationName
            existing.currentSummary = summary
            existing.slotSummary = slots
            existing.fetchedAt = reading.fetchedAt
        } else {
            modelContext.insert(
                WeatherSnapshot(
                    regionID: region.id,
                    regionName: region.name,
                    stationID: reading.stationID,
                    stationName: reading.stationName,
                    currentSummary: summary,
                    slotSummary: slots,
                    fetchedAt: reading.fetchedAt
                )
            )
        }

        writeAudit(
            action: "INSERT",
            source: "weather",
            statement: """
            INSERT INTO weather_snapshots(region_id, station_id, fetched_at, current_summary) VALUES ('\(region.id)', '\(reading.stationID)', '\(Self.isoFormatter.string(from: reading.fetchedAt))', '\(summary)');
            """,
            status: "ok"
        )
    }
}
