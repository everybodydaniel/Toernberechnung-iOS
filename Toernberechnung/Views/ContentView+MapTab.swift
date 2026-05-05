import SwiftUI

enum DepthMode: String, CaseIterable, Identifiable {
    case mhw = "MHW"
    case sounding = "Lottiefe"
    var id: String { rawValue }
}

extension ContentView {
    var calculatorInput: ManualPassageInput {
        ManualPassageInput(
            departureTime: departure,
            highWaterTime: bshHighWaterTime ?? highWater,
            distanceNM: distanceNM,
            speedKnots: speedKnots,
            offsetMinutes: offsetMinutes,
            meanTidalRangeMeters: mth,
            referenceDepthMeters: referenceDepth,
            bshWaterLevelCorrectionMeters: bshWaterLevel,
            chartDepthMeters: chartDepth,
            boatDraftMeters: boatDraft,
            depthMode: depthMode == .mhw ? .mhw : .sounding
        )
    }

    var result: ManualPassageResult { ManualPassageCalculator.calculate(input: calculatorInput) }

    var bshHighWaterTime: Date? {
        tideReading?.events.first { $0.type == "HW" && $0.time >= departure }?.time
    }

    var dieselLiters: Double {
        max(result.distanceNM * 0.35, 0)
    }

    var displayStartHarbourName: String {
        startHarbour.name
    }

    var displayDestinationHarbourName: String {
        destinationHarbour.name
    }

    var routeTitle: String {
        "\(displayStartHarbourName) → \(displayDestinationHarbourName)"
    }

    func calculatorTab() -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ROUTE & PASSAGE")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.secondary)

            card {
                VStack(alignment: .leading, spacing: 14) {
                    Text("ROUTE")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.secondary)

                    VStack(spacing: 10) {
                        harbourPicker(title: "Start", selection: $startHarbourID, embedded: true)
                        harbourPicker(title: "Ziel", selection: $destinationHarbourID, embedded: true)
                        DatePicker("Abfahrt", selection: $departure, displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.compact)
                    }

                    CompactMapView(zoomLevel: 8.0, start: startHarbour, destination: destinationHarbour)
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                statusCard(result)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    metricCard("REISEZEIT", text: durationText(result.travelHours), caption: "Dauer")
                    metricCard("ANKUNFT", text: Self.timeFormatter.string(from: result.arrivalAtPassage), caption: "Uhr")
                    metricCard("DISTANZ", text: String(format: "%.1f nm", result.distanceNM), caption: "NM")
                    metricCard("UKC", text: String(format: "%.2f m", result.ukc), caption: result.statusText)
                    metricCard("WASSERTIEFE", text: String(format: "%.2f m", result.wt), caption: "Tiefe")
                    metricCard("DIESEL", text: String(format: "%.1f l", dieselLiters), caption: "Richtwert")
                }

                Button("Törn berechnen & Logbuch anlegen") { saveCalculation() }
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color.appPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding(16)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 12, y: 8)

            tidesPreviewCard(title: "NÄCHSTE GEZEITEN AM ZIEL")
        }
    }

    func statusCard(_ result: ManualPassageResult) -> some View {
        let accent = result.isPassable ? Color.green : Color.red
        let subtitle = result.isPassable
            ? "Die Passage ist befahrbar."
            : "Die Passage ist nicht befahrbar."

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: result.isPassable ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 28, weight: .bold))
                Text(result.statusText)
                    .font(.system(size: 28, weight: .bold))
            }

            Text(subtitle)
                .font(.system(size: 15, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [accent.opacity(0.92), accent.opacity(0.72)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: accent.opacity(0.35), radius: 18, y: 10)
    }

    func normalizedHarbourName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    @MainActor
    func saveCalculation() {
        // Der Logbucheintrag bekommt Momentaufnahmen von Route, Wetter, Gezeiten und Crew, nicht nur die reinen Rechenwerte.
        writeAudit(
            action: "READ",
            source: "calculation",
            statement: """
            SELECT start_hafen, ziel_hafen, departure_at, distance_nm, speed_knots, offset_minutes FROM manual_passage_input LIMIT 1;
            """,
            status: "ok"
        )
        let record = CalculationRecord(
            routeTitle: routeTitle,
            startName: displayStartHarbourName,
            destinationName: displayDestinationHarbourName,
            departureAt: departure,
            arrivalAt: result.arrivalAtPassage,
            distanceNM: result.distanceNM,
            status: result.statusText,
            fmw: result.fmw,
            wt: result.wt,
            wuk: result.ukc,
            weatherSummary: weatherSnapshots.first(where: { $0.regionID == destinationHarbour.id })?.currentSummary ?? weatherReading?.current.condition ?? "",
            tideSummary: tideReading?.summary ?? "",
            crewSummary: crewSummaryText()
        )
        modelContext.insert(record)
        writeAudit(
            action: "INSERT",
            source: "calculation",
            statement: """
            INSERT INTO calculations(route, departure_at, arrival_at, distance_nm, status, wuk) VALUES ('\(record.routeTitle)', '\(Self.isoFormatter.string(from: departure))', '\(Self.isoFormatter.string(from: result.arrivalAtPassage))', \(String(format: "%.1f", result.distanceNM)), '\(result.statusText)', \(String(format: "%.2f", result.ukc)));
            """,
            status: "ok"
        )
        writeAudit(
            action: "READ",
            source: "calculation",
            statement: "SELECT route_title, arrival_at, wuk FROM calculations ORDER BY created_at DESC LIMIT 1;",
            status: "ok"
        )
        try? modelContext.save()
    }

    @MainActor
    func syncRouteDefaults() {
        // Die Route steuert mehrere Eingabewerte: Distanz, Kartentiefe, Wetterregion und Pegel sollen synchron bleiben.
        let distance = SeaRoutePlanner.distanceNM(from: startHarbour, to: destinationHarbour)
        if distance > 0.1 {
            distanceNM = (distance * 10).rounded() / 10
        }
        chartDepth = destinationHarbour.chartDepth
        weatherRegionID = destinationHarbour.id
        tideHarbourID = destinationHarbour.id
    }
}
