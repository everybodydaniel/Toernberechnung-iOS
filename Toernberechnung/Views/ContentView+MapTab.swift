import SwiftUI

extension ContentView {

    // MARK: - Route Display Properties

    var displayStartHarbourName: String { viewModel.startHarbour.name }
    var displayDestinationHarbourName: String { viewModel.destinationHarbour.name }
    var routeTitle: String { viewModel.routeTitle }
    var startHarbour: HarbourOption { viewModel.startHarbour }
    var destinationHarbour: HarbourOption { viewModel.destinationHarbour }

    var dieselLiters: Double {
        max((viewModel.calculationResult?.totalDistanceNm ?? 0) * 0.35, 0)
    }

    // MARK: - Calculator Tab

    func calculatorTab() -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ROUTE & PASSAGE")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.secondary)

            // Route selection card.
            card {
                VStack(alignment: .leading, spacing: 14) {
                    Text("ROUTE")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.secondary)

                    VStack(spacing: 10) {
                        harbourPicker(title: "Start", selection: $viewModel.startHarbourID, embedded: true)
                        harbourPicker(title: "Ziel", selection: $viewModel.destinationHarbourID, embedded: true)
                        DatePicker("Abfahrt", selection: $viewModel.departure, displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.compact)
                    }

                    // Route template selector (when multiple templates available).
                    if viewModel.showTemplateSelector, !viewModel.availableTemplates.isEmpty {
                        routeTemplateSelector
                    }

                    CompactMapView(
                        zoomLevel: 8.0,
                        start: viewModel.startHarbour,
                        destination: viewModel.destinationHarbour,
                        routePlan: viewModel.routePlan,
                        waypointResults: viewModel.calculationResult?.waypointResults
                    )
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }

            // Status and results.
            VStack(alignment: .leading, spacing: 14) {
                routeStatusBanner
                passageWindowCard

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    metricCard("REISEZEIT", text: viewModel.totalTravelTimeText, caption: "Dauer")
                    metricCard("ANKUNFT", text: viewModel.arrivalTimeText, caption: "Uhr")
                    metricCard("DISTANZ", text: viewModel.totalDistanceText, caption: "NM")
                    metricCard("WuK", text: viewModel.worstWuKText, caption: viewModel.statusText)
                    metricCard("DIESEL", text: String(format: "%.1f l", dieselLiters), caption: "Richtwert")
                }

                // Per-waypoint calculation details.
                if let result = viewModel.calculationResult {
                    RouteDetailView(result: result, boatSettings: viewModel.boatSettings)
                }

                Button("Törn berechnen & Logbuch anlegen") { saveCalculation() }
                    .font(.system(size: 15, weight: .bold))
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

    // MARK: - Route Status Banner

    private var routeStatusBanner: some View {
        let status = viewModel.combinedStatus ?? .incomplete
        let accent = combinedStatusColor(status)
        let icon = status == .go ? "checkmark.circle.fill"
            : status == .warning ? "exclamationmark.triangle.fill"
            : status == .noGo ? "xmark.circle.fill"
            : "questionmark.circle.fill"

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if viewModel.isCalculating {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 28, weight: .bold))
                }
                Text(viewModel.statusText)
                    .font(.system(size: 28, weight: .bold))
            }

            if let error = viewModel.calculationError {
                Text(error)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(3)
            }
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

    // MARK: - Route Template Selector

    private var routeTemplateSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ROUTENVORSCHLAG")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.secondary)

            ForEach(viewModel.availableTemplates) { template in
                let isSelected = viewModel.selectedTemplateID == template.id
                Button {
                    viewModel.selectTemplate(template.id)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? Color(hex: 0x3C82FF) : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.name)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Color.appPrimary)
                            Text(template.description)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(isSelected ? Color(hex: 0x3C82FF).opacity(0.08) : Color.fieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Passage Window Card

    private var passageWindowCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("SICHERES ABFAHRTSFENSTER")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                    Spacer()
                    if viewModel.isSearchingWindow {
                        ProgressView()
                    } else {
                        Button {
                            viewModel.refreshPassageWindow()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Color(hex: 0x3C82FF))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Passagefenster aktualisieren")
                    }
                }

                if let window = viewModel.passageWindow {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.badge.checkmark.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Color.green)
                        Text(window.displayString)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Color.appPrimary)
                    }

                    if window.contains(viewModel.departure) {
                        Text("Die aktuelle Abfahrt liegt innerhalb des sicheren Fensters.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.secondary)
                    } else {
                        Text("Die aktuelle Abfahrt liegt nicht im sicheren Fenster.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.orange)
                    }
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: viewModel.isSearchingWindow ? "clock.arrow.circlepath" : "clock.badge.exclamationmark.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(viewModel.isSearchingWindow ? Color(hex: 0x3C82FF) : Color.orange)
                        Text(viewModel.isSearchingWindow ? "Fenster wird berechnet…" : (viewModel.passageWindowMessage ?? "Kein Passagefenster berechnet."))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Save Calculation (Logbook)

    @MainActor
    func saveCalculation() {
        let result = viewModel.calculationResult

        writeAudit(
            action: "READ", source: "calculation",
            statement: "SELECT route, departure_at, distance_nm FROM route_calculation LIMIT 1;",
            status: "ok"
        )

        let record = CalculationRecord(
            routeTitle: viewModel.routeTitle,
            startName: displayStartHarbourName,
            destinationName: displayDestinationHarbourName,
            departureAt: viewModel.departure,
            arrivalAt: result?.waypointResults.last?.arrivalTime ?? viewModel.departure,
            distanceNM: result?.totalDistanceNm ?? 0,
            status: viewModel.statusText,
            fmw: result?.waypointResults.compactMap(\.missingWaterFmWMeters).max() ?? 0,
            wt: result?.waypointResults.compactMap(\.availableWaterDepthWTMeters).min() ?? 0,
            wuk: result?.worstClearanceUnderKeel ?? 0,
            weatherSummary: weatherSnapshots.first(where: { $0.regionID == viewModel.destinationHarbourID })?.currentSummary ?? weatherReading?.current.condition ?? "",
            tideSummary: tideReading?.summary ?? "",
            crewSummary: crewSummaryText()
        )
        modelContext.insert(record)
        try? modelContext.save()

        writeAudit(
            action: "INSERT", source: "calculation",
            statement: "INSERT INTO calculations(route, status, wuk) VALUES ('\(record.routeTitle)', '\(record.status)', \(String(format: "%.2f", record.wuk)));",
            status: "ok"
        )
    }

    @MainActor
    func syncRouteDefaults() {
        weatherRegionID = viewModel.destinationHarbourID
        tideHarbourID = viewModel.destinationHarbourID
    }
}
