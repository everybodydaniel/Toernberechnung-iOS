import SwiftUI
import Charts


extension ContentView {
    var islandHarbours: [HarbourOption] {
        harbours.filter { $0.id != "emden_harbor" }
    }

    var selectedTideHarbour: HarbourOption { HarbourOption.byID(tideHarbourID) }

    func tidesTab() -> some View {
        VStack(alignment: .leading, spacing: 14) {
            tideHarbourPickerCard
            tideDetailCard
            waterLevelForecastCard
        }
    }

    // MARK: - Harbour Picker

    private var tideHarbourPickerCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("PEGEL AUSWÄHLEN")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                    Spacer()
                    if tideLoading || waterLevelLoading {
                        ProgressView()
                    } else {
                        Button {
                            Task {
                                await loadIslandTides(force: true)
                                await loadAstronomicalTide(for: selectedTideHarbour)
                                await loadWaterLevelForecast(for: selectedTideHarbour, force: true)
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Color(hex: 0x3C82FF))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Pegel-Daten aktualisieren")
                    }
                }

                Picker("Pegel", selection: $tideHarbourID) {
                    ForEach(harbours) { harbour in
                        Text(harbour.name).tag(harbour.id)
                    }
                }
                .pickerStyle(.menu)
                .tint(Color(hex: 0x3C82FF))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.fieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: - Astronomical (gezeiten.bsh.de)

    private var tideDetailCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("BSH-GEZEITEN (ASTRONOMISCH)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                    Spacer()
                }
                Text(selectedTideHarbour.name)
                    .font(.system(size: 20, weight: .bold))
                Text("BSH \(selectedTideHarbour.tideStationName) · \(selectedTideHarbour.tideStationID)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.secondary)

                if let reading = islandTides[selectedTideHarbour.id] ?? tideReading,
                   reading.stationID == selectedTideHarbour.tideStationID {
                    tideEventsRow(Array(reading.events.prefix(4)))
                } else if tideLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Gezeiten werden geladen…")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.secondary)
                    }
                } else if let tideError {
                    Text(tideError)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.orange)
                } else {
                    Text("Noch keine Daten geladen.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.secondary)
                }
            }
        }
    }

    // MARK: - Wasserstandsvorhersage (wasserstand-nordsee.bsh.de)

    private var waterLevelForecastCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("BSH-WASSERSTANDSVORHERSAGE")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                    Spacer()
                    Text("Bezug: SKN")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(hex: 0x3C82FF).opacity(0.12))
                        .foregroundStyle(Color(hex: 0x3C82FF))
                        .clipShape(Capsule())
                }

                if let forecast = waterLevelForecasts[selectedTideHarbour.id] {
                    waterLevelForecastBody(forecast)
                } else if waterLevelLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Vorhersage wird geladen…")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.secondary)
                    }
                } else if let waterLevelError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.orange)
                        Text(waterLevelError)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.secondary)
                    }
                } else {
                    Text("Noch keine BSH-Vorhersage geladen.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func waterLevelForecastBody(_ forecast: WaterLevelForecast) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let substitute = forecast.substituteForHarbour {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Color.orange)
                    Text("Für \(substitute) liegt keine BSH-Vorhersage vor. Es wird die Vorhersage des Nachbarpegels \(forecast.stationName) angezeigt.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 4)
            }

            if !forecast.curve.isEmpty {
                WaterLevelChartView(
                    forecast: forecast,
                    curveSubstituteName: selectedTideHarbour.curveSubstituteName
                )
            }
        }
    }

    func waterLevelEventsRow(_ events: [WaterLevelEvent]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(events) { event in
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: event.symbol)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(event.type == "HW" ? Color.blue : Color.teal)
                    Text(Self.slotFormatter.string(from: event.time))
                        .font(.system(size: 16, weight: .bold))
                    Text(event.sknHeightText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                    Text(event.forecastText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.orange)
                }
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
                .padding(10)
                .background(Color.fieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func waterLevelEventsList(_ events: [WaterLevelEvent]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(events) { event in
                HStack(spacing: 10) {
                    Image(systemName: event.symbol)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(event.type == "HW" ? Color.blue : Color.teal)
                        .frame(width: 16)
                    Text(Self.dayAndSlotFormatter.string(from: event.time))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.appPrimary)
                    Text(event.sknHeightText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.secondary)
                    Spacer()
                    Text(event.forecastText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.orange)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private static let forecastIssueFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppDateFormatters.germanLocale
        f.timeZone = AppDateFormatters.berlinTimeZone
        f.dateFormat = "dd.MM. HH:mm"
        return f
    }()

    private static let dayAndSlotFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppDateFormatters.germanLocale
        f.timeZone = AppDateFormatters.berlinTimeZone
        f.dateFormat = "EE dd.MM HH:mm"
        return f
    }()

    func tidesPreviewCard(title: String) -> some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                    Spacer()
                    if tideLoading {
                        ProgressView()
                    }
                }
                if let tideReading {
                    Text("\(tideReading.stationName) · BSH \(tideReading.stationID)")
                        .font(.system(size: 16, weight: .bold))
                    tideEventsRow(Array(tideReading.events.prefix(4)))
                } else {
                    Text(tideError ?? "Gezeiten werden aus den BSH-Daten geladen.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.secondary)
                }
            }
        }
    }

    /// BSH peak forecast for the destination harbour, slotted under the
    /// astronomical events on the map tab.
    @ViewBuilder
    private var routeWaterLevelForecastSection: some View {
        HStack {
            Text("BSH-VORHERSAGE (SKN)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.secondary)
            Spacer()
            if waterLevelLoading {
                ProgressView().scaleEffect(0.7)
            }
        }

        if let forecast = waterLevelForecasts[destinationHarbour.id] {
            if let substitute = forecast.substituteForHarbour {
                Text("Ersatzpegel \(forecast.stationName) für \(substitute)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.orange)
            } else {
                Text("\(forecast.stationName) · erstellt \(Self.compactForecastFormatter.string(from: forecast.issuedAt))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondary)
            }
            waterLevelEventsRow(Array(forecast.events.prefix(4)))
        } else if let waterLevelError {
            Text(waterLevelError)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.orange)
        } else {
            Text("Wasserstandsvorhersage wird abgerufen…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.secondary)
        }
    }

    private static let compactForecastFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppDateFormatters.germanLocale
        f.timeZone = AppDateFormatters.berlinTimeZone
        f.dateFormat = "dd.MM. HH:mm"
        return f
    }()

    func tideEventsRow(_ events: [TideEvent]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(events) { event in
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: event.symbol)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(event.type == "HW" ? Color.blue : Color.teal)
                    Text(Self.slotFormatter.string(from: event.time))
                        .font(.system(size: 16, weight: .bold))
                    Text(event.heightText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
                .padding(10)
                .background(Color.fieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    func loadTides(force: Bool) async {
        let harbour = destinationHarbour
        await MainActor.run {
            tideLoading = true
            tideError = nil
            writeAudit(action: "FETCH", source: "bsh_tides", statement: "FETCH BSH station='\(harbour.tideStationID)' harbour='\(harbour.name)'", status: "pending")
        }

        do {
            let reading = try await BSHTideService.shared.fetch(for: harbour, around: viewModel.departure, force: force)
            await MainActor.run {
                tideReading = reading
                islandTides[harbour.id] = reading
                tideLoading = false
                writeAudit(action: "READ", source: "bsh_tides", statement: "SELECT next_hw_nw FROM bsh_tides WHERE station_id = '\(harbour.tideStationID)' LIMIT 8", status: "ok")
            }
        } catch {
            await MainActor.run {
                tideLoading = false
                tideError = error.localizedDescription
                writeAudit(action: "FETCH", source: "bsh_tides", statement: "FETCH BSH station='\(harbour.tideStationID)'", status: "error")
            }
        }
    }

    func loadIslandTides(force: Bool) async {
        await MainActor.run {
            tideLoading = true
            tideError = nil
        }

        var loadedCount = 0
        var failures: [String] = []

        // Die Inselpegel werden nacheinander geladen, damit Teilerfolge angezeigt und einzelne Fehler gesammelt werden können.
        for harbour in islandHarbours {
            do {
                let reading = try await BSHTideService.shared.fetch(for: harbour, around: viewModel.departure, force: force)
                loadedCount += 1
                await MainActor.run {
                    islandTides[harbour.id] = reading
                    if harbour.id == tideHarbourID { tideReading = reading }
                }
            } catch {
                failures.append("\(harbour.name): \(error.localizedDescription)")
            }
        }

        await MainActor.run {
            tideLoading = false
            if loadedCount == 0 {
                tideError = failures.first ?? "Für die Inselpegel konnten keine Gezeiten geladen werden."
                writeAudit(action: "FETCH", source: "bsh_tides", statement: "FETCH BSH island tide bundle", status: "error")
            } else {
                tideError = failures.isEmpty ? nil : failures.joined(separator: " | ")
                writeAudit(action: "READ", source: "bsh_tides", statement: "SELECT island, next_hw_nw FROM bsh_tides WHERE area = 'ostfriesische_inseln'", status: "ok")
            }
        }
    }

    /// Load the astronomical BSH tide for any single harbour and stash it
    /// in `islandTides`. Used when the user picks a harbour that wasn't part
    /// of the island bundle (e.g. Emden).
    func loadAstronomicalTide(for harbour: HarbourOption) async {
        if islandTides[harbour.id] != nil { return }
        await MainActor.run { tideLoading = true }
        do {
            let reading = try await BSHTideService.shared.fetch(
                for: harbour, around: viewModel.departure, force: false
            )
            await MainActor.run {
                islandTides[harbour.id] = reading
                tideReading = reading
                tideLoading = false
            }
        } catch {
            await MainActor.run {
                tideLoading = false
                tideError = error.localizedDescription
            }
        }
    }

    // MARK: - BSH-Wasserstandsvorhersage

    /// Fetch the BSH peak-water-level forecast for a harbour. Skips the
    /// network when a cached value younger than the service's TTL exists.
    func loadWaterLevelForecast(for harbour: HarbourOption, force: Bool) async {
        await MainActor.run {
            waterLevelLoading = true
            if force { waterLevelError = nil }
        }
        do {
            let forecast = try await BSHWaterLevelForecastService.shared.fetch(
                bshNr: harbour.forecastBshNr,
                substituteForHarbour: harbour.forecastSubstituteName,
                force: force
            )
            
            var finalForecast = forecast
            if forecast.curve.isEmpty {
                if let curveForecast = try? await BSHWaterLevelForecastService.shared.fetch(
                    bshNr: harbour.curveBshNr,
                    substituteForHarbour: harbour.curveSubstituteName,
                    force: force
                ) {
                    finalForecast = WaterLevelForecast(
                        stationName: forecast.stationName,
                        bshNr: forecast.bshNr,
                        issuedAt: forecast.issuedAt,
                        fetchedAt: forecast.fetchedAt,
                        pnpBelowNhnMeters: forecast.pnpBelowNhnMeters,
                        sknAbovePnpMeters: forecast.sknAbovePnpMeters,
                        mhwMeters: forecast.mhwMeters,
                        mnwMeters: forecast.mnwMeters,
                        events: forecast.events,
                        curve: curveForecast.curve,
                        mhwAboveSknMeters: forecast.mhwAboveSknMeters,
                        mnwAboveSknMeters: forecast.mnwAboveSknMeters,
                        substituteForHarbour: forecast.substituteForHarbour
                    )
                }
            }
            
            await MainActor.run {
                waterLevelForecasts[harbour.id] = finalForecast
                waterLevelLoading = false
                waterLevelError = nil
                writeAudit(
                    action: "READ",
                    source: "bsh_water_level",
                    statement: "SELECT next_hwnw_skn FROM bsh_water_level WHERE bshnr = '\(harbour.forecastBshNr)' LIMIT 4",
                    status: "ok"
                )
            }
        } catch {
            await MainActor.run {
                waterLevelLoading = false
                waterLevelError = error.localizedDescription
                writeAudit(
                    action: "FETCH",
                    source: "bsh_water_level",
                    statement: "FETCH BSH water-level bshnr='\(harbour.forecastBshNr)'",
                    status: "error"
                )
            }
        }
    }
}

// MARK: - Water Level Chart View

struct WaterLevelChartView: View {
    let forecast: WaterLevelForecast
    let curveSubstituteName: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("WASSERSTANDSVERLAUF (SKN IN CM)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.secondary)
                Spacer()
                if let sub = curveSubstituteName {
                    Text("Kurve von \(sub)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.orange)
                }
            }
            
            Chart {
                // MHW Reference
                if let mhw = forecast.mhwAboveSknMeters {
                    RuleMark(
                        y: .value("MHW", mhw * 100)
                    )
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Color.blue.opacity(0.6))
                    .annotation(position: .trailing, alignment: .trailing) {
                        Text("MHW \(Int(mhw * 100)) cm")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.blue.opacity(0.8))
                    }
                }
                
                // MNW Reference
                if let mnw = forecast.mnwAboveSknMeters {
                    RuleMark(
                        y: .value("MNW", mnw * 100)
                    )
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Color.red.opacity(0.6))
                    .annotation(position: .trailing, alignment: .trailing) {
                        Text("MNW \(Int(mnw * 100)) cm")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.red.opacity(0.8))
                    }
                }
                
                // Current Time
                RuleMark(
                    x: .value("Jetzt", Date())
                )
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                .foregroundStyle(Color.orange.opacity(0.8))
                
                // Astronomical Curve (Green)
                ForEach(forecast.curve) { point in
                    if let astro = point.astroMetersSkn {
                        LineMark(
                            x: .value("Zeit", point.time),
                            y: .value("Wasserstand", astro * 100),
                            series: .value("Linie", "Astronomisch")
                        )
                        .foregroundStyle(Color.green)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
                
                // Measured Curve (Red)
                ForEach(forecast.curve) { point in
                    if let measurement = point.measurementMetersSkn {
                        LineMark(
                            x: .value("Zeit", point.time),
                            y: .value("Wasserstand", measurement * 100),
                            series: .value("Linie", "Messung")
                        )
                        .foregroundStyle(Color.red)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
                
                // Forecast Curve (Orange)
                ForEach(forecast.curve) { point in
                    if let forecastVal = point.forecastMetersSkn {
                        LineMark(
                            x: .value("Zeit", point.time),
                            y: .value("Wasserstand", forecastVal * 100),
                            series: .value("Linie", "Vorhersage")
                        )
                        .foregroundStyle(Color.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 12)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                    AxisTick()
                    if let date = value.as(Date.self) {
                        let hour = Calendar.current.component(.hour, from: date)
                        if hour == 0 {
                            AxisValueLabel {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Self.dayFormatter.string(from: date))
                                        .font(.system(size: 9, weight: .bold))
                                    Text("00:00")
                                        .font(.system(size: 8))
                                }
                            }
                        } else {
                            AxisValueLabel {
                                Text(String(format: "%02d", hour))
                                    .font(.system(size: 8))
                            }
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel()
                }
            }
            .frame(height: 220)
            .padding(.top, 8)
            .padding(.trailing, 55)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    legendItem(title: "Astronomisch", color: .green)
                    legendItem(title: "Vorhersage", color: .orange)
                    legendItem(title: "Messung", color: .red)
                }
                HStack(spacing: 12) {
                    legendItem(title: "MHW (Mittl. Hochwasser)", color: .blue, dashed: true)
                    legendItem(title: "MNW (Mittl. Niedrigwasser)", color: .red, dashed: true)
                }
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.secondary)
            .padding(.top, 6)
        }
    }
    
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppDateFormatters.germanLocale
        f.timeZone = AppDateFormatters.berlinTimeZone
        f.dateFormat = "EE dd.MM."
        return f
    }()
    
    private func legendItem(title: String, color: Color, dashed: Bool = false) -> some View {
        HStack(spacing: 5) {
            if dashed {
                Text("- - -")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(color)
            } else {
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 14, height: 3)
            }
            Text(title)
        }
    }
}

