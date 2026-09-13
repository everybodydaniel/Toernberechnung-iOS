import Charts
import SwiftUI

extension ContentView {
    var islandHarbours: [HarbourOption] {
        harbours.filter { $0.id != "emden_harbor" }
    }

    private var selectedTideReading: TideReading? {
        islandTides[tideStationID]
    }

    func tidesTab() -> some View {
        VStack(alignment: .leading, spacing: 16) {
            tideHero
            astronomicalEventsCard
            tideReferenceValuesCard
            waterLevelForecastCard
        }
    }

    private var tideHero: some View {
        Button {
            tideStationPickerShown = true
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(tideStation.name)
                                .font(.system(size: 29, weight: .heavy))
                                .multilineTextAlignment(.leading)
                            Image(systemName: "chevron.down.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .symbolRenderingMode(.hierarchical)
                        }
                        Text("BSH \(tideStation.id) · \(tideStation.kind.label)")
                            .font(.system(size: 12, weight: .semibold))
                            .opacity(0.72)
                    }
                    Spacer()
                    if tideLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: selectedTideReading?.movement(at: .now).symbol ?? "water.waves")
                            .font(.system(size: 24, weight: .bold))
                            .frame(width: 48, height: 48)
                            .background(Color.white.opacity(0.12), in: Circle())
                    }
                }

                if let reading = selectedTideReading, let next = reading.nextEvent {
                    HStack(alignment: .lastTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reading.movement(at: .now).label)
                                .font(.system(size: 15, weight: .bold))
                            Text("Nächstes \(next.type == "HW" ? "Hochwasser" : "Niedrigwasser")")
                                .font(.system(size: 12, weight: .medium))
                                .opacity(0.7)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(AppDateFormatters.hourMinute.string(from: next.time))
                                .font(.system(size: 30, weight: .heavy, design: .rounded))
                            Text(tideCountdown(to: next.time))
                                .font(.system(size: 12, weight: .semibold))
                                .opacity(0.72)
                        }
                    }
                } else if let tideError {
                    Label(tideError, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.yellow)
                } else {
                    Text("Gezeitendaten werden vorbereitet …")
                        .font(.system(size: 14, weight: .semibold))
                        .opacity(0.72)
                }
            }
            .foregroundStyle(.white)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(.plain)
        .appWeatherLiquidGlass(cornerRadius: 28, interactive: true)
        .accessibilityLabel("\(tideStation.name), Pegel ändern")
    }

    private var astronomicalEventsCard: some View {
        tideGlassCard {
            VStack(alignment: .leading, spacing: 14) {
                tideSectionHeader("Astronomische Gezeiten", icon: "clock.arrow.2.circlepath")
                if let reading = selectedTideReading {
                    tideEventStrip(Array(reading.events.prefix(6)))
                    if !reading.reference.hasEventHeights {
                        Label(
                            "Das BSH veröffentlicht für diesen interpolierten Pegel lokale HW-/NW-Zeiten, aber keine einzelnen Ereignishöhen.",
                            systemImage: "info.circle.fill"
                        )
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.76))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } else if tideLoading {
                    loadingRow("Gezeiten werden geladen …")
                } else {
                    errorRow(tideError ?? "Noch keine astronomischen Gezeiten geladen.")
                }
            }
        }
    }

    private var tideReferenceValuesCard: some View {
        tideGlassCard {
            VStack(alignment: .leading, spacing: 14) {
                tideSectionHeader("Gezeitengrundwerte", icon: "ruler")
                if let reference = selectedTideReading?.reference {
                    HStack(spacing: 0) {
                        tideReferenceMetric("MHW", value: tideMeters(reference.meanHighWaterAboveSknMeters))
                        tideReferenceMetric("MNW", value: tideMeters(reference.meanLowWaterAboveSknMeters))
                        tideReferenceMetric("MTH", value: tideMeters(reference.meanTidalRangeMeters))
                    }

                    ForEach(reference.notices, id: \.self) { notice in
                        Label(notice, systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.yellow.opacity(0.95))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    loadingRow("Grundwerte werden geladen …")
                }
            }
        }
    }

    private var waterLevelForecastCard: some View {
        tideGlassCard {
            VStack(alignment: .leading, spacing: 14) {
                tideSectionHeader("Wasserstandsvorhersage", icon: "waveform.path.ecg")

                if tideStation.hasLocalWaterLevelForecast {
                    localWaterLevelForecastContent
                } else {
                    missingLocalForecastContent
                }
            }
        }
    }

    @ViewBuilder
    private var localWaterLevelForecastContent: some View {
        if let forecast = waterLevelForecasts[tideStationID] {
            forecastStatusRow(forecast)
            waterLevelEventStrip(Array(forecast.events.prefix(6)))
            if !forecast.curve.isEmpty {
                WaterLevelChartView(forecast: forecast)
            } else {
                Label(
                    "Für diesen Pegel veröffentlicht das BSH Scheitelwerte, aber keine lokale Modellkurve.",
                    systemImage: "chart.xyaxis.line"
                )
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
            }
        } else if waterLevelLoading {
            loadingRow("Vorhersage wird geladen …")
        } else {
            errorRow(waterLevelError ?? "Noch keine BSH-Wasserstandsvorhersage geladen.")
        }
    }

    @ViewBuilder
    private var missingLocalForecastContent: some View {
        Label(
            "Das BSH führt für \(tideStation.name) keine eigene Wasserstandsmodellstation. Die lokalen Gezeitenzeiten bleiben davon unberührt.",
            systemImage: "location.slash.fill"
        )
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white.opacity(0.82))
        .fixedSize(horizontal: false, vertical: true)

        if let comparisonID = viewModel.confirmedComparisonGaugeIDs[tideStationID],
           let comparison = BSHTideStationCatalog.station(id: comparisonID) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("BESTÄTIGTER VERGLEICHSPEGEL")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white.opacity(0.92))
                        Text(comparison.name)
                            .font(.system(size: 16, weight: .bold))
                        Text("\(String(format: "%.1f", tideStation.distanceKilometers(to: comparison))) km entfernt · nicht lokaler Pegel")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.66))
                    }
                    Spacer()
                    Button {
                        viewModel.clearComparisonGauge(localStationID: tideStationID)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Vergleichspegel entfernen")
                }

                if let forecast = waterLevelForecasts[comparison.id] {
                    forecastStatusRow(forecast, comparison: true)
                    waterLevelEventStrip(Array(forecast.events.prefix(4)))
                } else {
                    Button("Vergleichsdaten laden") {
                        Task { await loadWaterLevelForecast(for: comparison.id, force: false) }
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
            }
            .padding(13)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.32), lineWidth: 0.8)
            }
        } else {
            Menu {
                ForEach(BSHTideStationCatalog.comparisonCandidates(for: tideStationID)) { candidate in
                    Button {
                        viewModel.confirmComparisonGauge(
                            localStationID: tideStationID,
                            comparisonStationID: candidate.id
                        )
                        Task { await loadWaterLevelForecast(for: candidate.id, force: false) }
                    } label: {
                        Text("\(candidate.name) · \(String(format: "%.1f", tideStation.distanceKilometers(to: candidate))) km")
                    }
                }
            } label: {
                Label("Vergleichspegel für diesen Törn bestätigen", systemImage: "checkmark.shield.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: 0x2B63B8))

            Text("Ein Vergleichspegel überträgt nur die meteorologische Abweichung. Ein rechnerisch sicheres Ergebnis bleibt gelb und wird nie als lokaler Messwert dargestellt.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tideGlassCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .foregroundStyle(.white)
            .padding(17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appWeatherLiquidGlass(cornerRadius: 24)
    }

    private func tideSectionHeader(_ title: String, icon: String) -> some View {
        Label(title.uppercased(), systemImage: icon)
            .font(.system(size: 12, weight: .heavy))
            .foregroundStyle(.white.opacity(0.78))
    }

    private func tideReferenceMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white.opacity(0.6))
            Text(value)
                .font(.system(size: 19, weight: .heavy, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tideEventStrip(_ events: [TideEvent]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(events) { event in
                    VStack(alignment: .leading, spacing: 7) {
                        Image(systemName: event.symbol)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(event.type == "HW" ? Color.cyan : Color.indigo.opacity(0.9))
                        Text(event.type)
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(AppDateFormatters.hourMinute.string(from: event.time))
                            .font(.system(size: 17, weight: .heavy, design: .rounded))
                        Text(event.heightText)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(2)
                    }
                    .frame(width: 112, height: 112, alignment: .leading)
                    .padding(12)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func waterLevelEventStrip(_ events: [WaterLevelEvent]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(events) { event in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: event.symbol)
                                .foregroundStyle(event.type == "HW" ? Color.cyan : Color.indigo.opacity(0.9))
                            Text(event.type)
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundStyle(.white.opacity(0.62))
                        }
                        Text(AppDateFormatters.hourMinute.string(from: event.time))
                            .font(.system(size: 17, weight: .heavy, design: .rounded))
                        Text(event.sknHeightText)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                        Text(event.forecastText)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .frame(width: 118, height: 105, alignment: .leading)
                    .padding(12)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func forecastStatusRow(_ forecast: WaterLevelForecast, comparison: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: forecast.isStale ? "clock.badge.exclamationmark.fill" : "checkmark.circle.fill")
                .foregroundStyle(forecast.isStale ? Color.yellow : Color.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(comparison ? "Vergleich: \(forecast.stationName)" : forecast.stationName)
                    .font(.system(size: 13, weight: .bold))
                Text("Ausgegeben \(Self.forecastIssueFormatter.string(from: forecast.issuedAt))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
            }
            Spacer()
            if forecast.isStale {
                Text("VERALTET")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color.yellow)
            }
        }
    }

    private func loadingRow(_ text: String) -> some View {
        HStack(spacing: 9) {
            ProgressView().tint(.white)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
        }
    }

    private func errorRow(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.yellow)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func tideMeters(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%.2f m", value)
    }

    private func tideCountdown(to date: Date) -> String {
        let seconds = max(date.timeIntervalSinceNow, 0)
        let hours = Int(seconds) / 3_600
        let minutes = (Int(seconds) % 3_600) / 60
        return hours > 0 ? "in \(hours) Std. \(minutes) Min." : "in \(minutes) Min."
    }

    private static let forecastIssueFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppDateFormatters.germanLocale
        formatter.timeZone = AppDateFormatters.berlinTimeZone
        formatter.dateFormat = "dd.MM. · HH:mm 'Uhr'"
        return formatter
    }()

    @MainActor
    func loadTides(force: Bool) async {
        let stationID = tideStationID
        tideLoading = true
        tideError = nil
        do {
            let reading = try await BSHTideService.shared.fetch(
                stationID: stationID,
                around: viewModel.departure,
                force: force
            )
            tideReading = reading
            islandTides[stationID] = reading
            tideLoading = false
            writeAudit(action: "READ", source: "bsh_tides", statement: "SELECT next_hw_nw FROM bsh_tides WHERE station_id = '\(stationID)'", status: "ok")
        } catch {
            tideLoading = false
            tideError = error.localizedDescription
            writeAudit(action: "FETCH", source: "bsh_tides", statement: "FETCH BSH station='\(stationID)'", status: "error")
        }
    }

    @MainActor
    func loadIslandTides(force: Bool) async {
        tideLoading = true
        tideError = nil
        var loaded: [String: TideReading] = [:]
        var failures: [String] = []

        await withTaskGroup(of: (String, Result<TideReading, Error>).self) { group in
            for station in BSHTideStationCatalog.islands {
                group.addTask {
                    do {
                        let reading = try await BSHTideService.shared.fetch(
                            stationID: station.id,
                            around: viewModel.departure,
                            force: force
                        )
                        return (station.id, .success(reading))
                    } catch {
                        return (station.id, .failure(error))
                    }
                }
            }

            for await (stationID, result) in group {
                switch result {
                case .success(let reading): loaded[stationID] = reading
                case .failure(let error): failures.append(error.localizedDescription)
                }
            }
        }

        islandTides.merge(loaded) { _, new in new }
        if let selected = loaded[tideStationID] {
            tideReading = selected
        }
        tideLoading = false
        tideError = loaded.isEmpty ? failures.first ?? "Keine BSH-Gezeiten verfügbar." : nil
    }

    @MainActor
    func loadAstronomicalTide(for stationID: String) async {
        if islandTides[stationID] != nil { return }
        tideLoading = true
        do {
            let reading = try await BSHTideService.shared.fetch(
                stationID: stationID,
                around: viewModel.departure,
                force: false
            )
            islandTides[stationID] = reading
            if stationID == tideStationID { tideReading = reading }
            tideLoading = false
            tideError = nil
        } catch {
            tideLoading = false
            tideError = error.localizedDescription
        }
    }

    func loadAstronomicalTide(for harbour: HarbourOption) async {
        await loadAstronomicalTide(for: harbour.tideStationID)
    }

    @MainActor
    func loadWaterLevelForecast(for stationID: String, force: Bool) async {
        guard let station = BSHTideStationCatalog.station(id: stationID) else { return }
        guard station.hasLocalWaterLevelForecast else {
            waterLevelForecasts.removeValue(forKey: stationID)
            waterLevelLoading = false
            waterLevelError = nil
            return
        }

        waterLevelLoading = true
        if force { waterLevelError = nil }
        do {
            let forecast = try await BSHWaterLevelForecastService.shared.fetch(
                station: station,
                force: force
            )
            waterLevelForecasts[stationID] = forecast
            waterLevelLoading = false
            waterLevelError = nil
            writeAudit(action: "READ", source: "bsh_water_level", statement: "FETCH OGC feature='\(station.forecastFeatureID ?? "")'", status: "ok")
        } catch {
            waterLevelLoading = false
            waterLevelError = error.localizedDescription
            writeAudit(action: "FETCH", source: "bsh_water_level", statement: "FETCH OGC station='\(stationID)'", status: "error")
        }
    }

    func loadWaterLevelForecast(for harbour: HarbourOption, force: Bool) async {
        await loadWaterLevelForecast(for: harbour.tideStationID, force: force)
    }
}

struct TideStationPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: String
    @State private var searchText = ""

    private var matchingStations: [BSHTideStation] {
        guard !searchText.isEmpty else { return BSHTideStationCatalog.stations }
        return BSHTideStationCatalog.stations.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.id.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()

                Color.glassTint
                    .opacity(colorScheme == .dark ? 0.72 : 0.84)
                    .ignoresSafeArea()

                List {
                    ForEach(BSHTideStationArea.allCasesForDisplay, id: \.rawValue) { area in
                        let stations = matchingStations.filter { $0.area == area }
                        if !stations.isEmpty {
                            Section {
                                ForEach(stations) { station in
                                    Button {
                                        selection = station.id
                                        dismiss()
                                    } label: {
                                        HStack(spacing: 13) {
                                            Image(systemName: station.kind == .gauge ? "dot.radiowaves.left.and.right" : "point.3.connected.trianglepath.dotted")
                                                .font(.system(size: 17, weight: .bold))
                                                .foregroundStyle(Color.appPrimary)
                                                .frame(width: 32)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(station.name)
                                                    .font(.system(size: 15, weight: .bold))
                                                Text("BSH \(station.id) · \(station.kind.label)")
                                                    .font(.system(size: 11, weight: .semibold))
                                                    .foregroundStyle(Color.secondary)
                                            }
                                            Spacer()
                                            if station.hasLocalWaterLevelForecast {
                                                Image(systemName: "waveform.path.ecg")
                                                    .font(.system(size: 12, weight: .bold))
                                                    .foregroundStyle(Color.green)
                                            }
                                            if station.id == selection {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundStyle(Color.appPrimary)
                                            }
                                        }
                                        .foregroundStyle(Color.primary)
                                        .padding(.vertical, 5)
                                    }
                                    .buttonStyle(.plain)
                                    .listRowBackground(
                                        station.id == selection
                                            ? Color.appPrimary.opacity(colorScheme == .dark ? 0.18 : 0.12)
                                            : Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.035)
                                    )
                                }
                            } header: {
                                Text(area.label)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Color.primary.opacity(0.82))
                                    .textCase(nil)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Pegel auswählen")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Ort oder BSH-ID")
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { dismiss() }
                        .fontWeight(.bold)
                        .foregroundStyle(Color.appPrimary)
                }
            }
        }
    }
}

private extension BSHTideStationArea {
    static var allCasesForDisplay: [BSHTideStationArea] { [.island, .mainland] }
}

struct TideAtmosphereView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    let reading: TideReading?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(hex: 0x183B4D), Color(hex: 0x102A38), Color(hex: 0x091720)]
                    : [Color(hex: 0x527F91), Color(hex: 0x315D70), Color(hex: 0x183746)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) { timeline in
                Canvas { context, size in
                    let now = Date()
                    let movement = reading?.movement(at: now) ?? .unknown
                    let progress = reading?.progressToNextEvent(at: now) ?? 0.5
                    let normalizedLevel: Double
                    switch movement {
                    case .rising: normalizedLevel = progress
                    case .falling: normalizedLevel = 1 - progress
                    case .unknown: normalizedLevel = 0.5
                    }

                    let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                    let baseY = size.height * (0.72 - CGFloat(normalizedLevel) * 0.16)
                    drawWave(in: &context, size: size, baseY: baseY, amplitude: 18, phase: time * 0.42, color: .cyan.opacity(0.17))
                    drawWave(in: &context, size: size, baseY: baseY + 34, amplitude: 24, phase: time * -0.28 + 1.7, color: .blue.opacity(0.14))
                    drawWave(in: &context, size: size, baseY: baseY + 72, amplitude: 30, phase: time * 0.20 + 3.1, color: .white.opacity(0.07))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawWave(
        in context: inout GraphicsContext,
        size: CGSize,
        baseY: CGFloat,
        amplitude: CGFloat,
        phase: Double,
        color: Color
    ) {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: baseY))
        let wavelength = max(size.width * 0.72, 180)
        for x in stride(from: CGFloat.zero, through: size.width, by: 4) {
            let angle = (x / wavelength) * 2 * CGFloat.pi + CGFloat(phase)
            path.addLine(to: CGPoint(x: x, y: baseY + sin(angle) * amplitude))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        context.fill(path, with: .color(color))
    }
}

struct WaterLevelChartView: View {
    let forecast: WaterLevelForecast

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LOKALER WASSERSTANDSVERLAUF · SKN")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white.opacity(0.65))

            Chart {
                if let mhw = forecast.mhwAboveSknMeters {
                    RuleMark(y: .value("MHW", mhw * 100))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(Color.cyan.opacity(0.65))
                }
                if let mnw = forecast.mnwAboveSknMeters {
                    RuleMark(y: .value("MNW", mnw * 100))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(Color.indigo.opacity(0.7))
                }
                RuleMark(x: .value("Jetzt", Date()))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .foregroundStyle(Color.white.opacity(0.62))

                ForEach(forecast.curve) { point in
                    if let value = point.astroMetersSkn {
                        LineMark(
                            x: .value("Zeit", point.time),
                            y: .value("Astronomisch", value * 100),
                            series: .value("Serie", "Astronomisch")
                        )
                        .foregroundStyle(Color.cyan)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    if let value = point.forecastMetersSkn {
                        LineMark(
                            x: .value("Zeit", point.time),
                            y: .value("Vorhersage", value * 100),
                            series: .value("Serie", "Vorhersage")
                        )
                        .foregroundStyle(Color.yellow)
                        .lineStyle(StrokeStyle(lineWidth: 2.2))
                    }
                    if let value = point.measurementMetersSkn {
                        LineMark(
                            x: .value("Zeit", point.time),
                            y: .value("Messung", value * 100),
                            series: .value("Serie", "Messung")
                        )
                        .foregroundStyle(Color.red.opacity(0.9))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 1)) { value in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.12))
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(AppDateFormatters.weekdayDay.string(from: date))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.68))
                                .fixedSize()
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.12))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text("\(Int(number)) cm")
                                .foregroundStyle(.white.opacity(0.68))
                        }
                    }
                }
            }
            .frame(height: 230)

            HStack(spacing: 14) {
                chartLegend("Astronomisch", color: .cyan)
                chartLegend("Vorhersage", color: .yellow)
                chartLegend("Messung", color: .red)
            }
        }
        .padding(.top, 4)
    }

    private func chartLegend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 15, height: 3)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.66))
        }
    }
}
