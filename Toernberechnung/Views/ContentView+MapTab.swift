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
                        intermediateStopsSection
                        harbourPicker(title: "Ziel", selection: $viewModel.destinationHarbourID, embedded: true)
                        DatePicker("Abfahrt", selection: $viewModel.departure, displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.compact)
                            .environment(\.locale, AppDateFormatters.germanLocale)
                            .environment(\.timeZone, AppDateFormatters.berlinTimeZone)
                    }

                    ZStack(alignment: .topTrailing) {
                        CompactMapView(
                            zoomLevel: 8.0,
                            start: viewModel.startHarbour,
                            destination: viewModel.destinationHarbour,
                            routePlan: viewModel.routePlan,
                            waypointResults: viewModel.calculationResult?.waypointResults,
                            voyageActive: voyageManager.isVoyageActive,
                            breadcrumbCoordinates: voyageManager.breadcrumbs.map(\.coordinate)
                        )
                        .frame(height: voyageManager.isVoyageActive ? 320 : 240)

                        Button {
                            if voyageManager.isVoyageActive {
                                navigationFullScreenShown = true
                            } else {
                                mapFullScreenShown = true
                            }
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(Color.black.opacity(0.6))
                                .clipShape(Circle())
                        }
                        .padding(10)
                        .buttonStyle(.plain)
                        .accessibilityLabel("Karte im Vollbildmodus anzeigen")
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }

            // Status and results — extracted into a dedicated View struct
            // so SwiftUI evaluates a shallower generic type tree per body,
            // preventing the stack overflow that manifested as
            // EXC_BAD_ACCESS(code=2) at voyageActionButtons.
            CalculatorResultsSection(
                viewModel: viewModel,
                voyageManager: voyageManager,
                locationService: locationService,
                navigationTracker: navigationTracker,
                dieselLiters: dieselLiters,
                saveAction: { saveCalculation() },
                stopVoyageAlertShown: $stopVoyageAlertShown,
                voyageDisclaimerShown: $voyageDisclaimerShown,
                navigationFullScreenShown: $navigationFullScreenShown
            )

            tidesPreviewCard(title: "NÄCHSTE GEZEITEN AM ZIEL")

            windfinderCard()
        }
    }

    // MARK: - Intermediate Stops (Zwischenstopps)

    private var intermediateStopsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ZWISCHENSTOPPS")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.secondary)
                Spacer()
                Button {
                    viewModel.addIntermediateStop()
                } label: {
                    Label("Hinzufügen", systemImage: "plus.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x3C82FF))
                }
                .buttonStyle(.plain)
            }

            ForEach(viewModel.intermediateStops) { stop in
                intermediateStopRow(stop: stop)
            }
        }
    }

    /// Single intermediate-stop row. Receives the `IntermediateStop` by
    /// value so the closures capture its UUID, never its index — that's
    /// the guarantee against "Index out of range" when SwiftUI re-diffs
    /// during deletion.
    @ViewBuilder
    private func intermediateStopRow(stop: IntermediateStop) -> some View {
        let stopID = stop.id
        let positionLabel: String = {
            if let idx = viewModel.intermediateStops.firstIndex(where: { $0.id == stopID }) {
                return "Stopp \(idx + 1)"
            }
            return "Stopp"
        }()

        HStack(spacing: 8) {
            Picker(positionLabel, selection: Binding(
                get: {
                    viewModel.intermediateStops.first(where: { $0.id == stopID })?.harbourID
                        ?? HarbourOption.options.first?.id
                        ?? ""
                },
                set: { newID in
                    viewModel.updateIntermediateStop(id: stopID, to: newID)
                }
            )) {
                ForEach(HarbourOption.options) { harbour in
                    Text(harbour.name).tag(harbour.id)
                }
            }
            .pickerStyle(.menu)
            .tint(Color(hex: 0x3C82FF))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.fieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                viewModel.removeIntermediateStop(id: stopID)
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.red)
                    .frame(width: 36, height: 36)
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(positionLabel) entfernen")
        }
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

    // MARK: - Voyage lifecycle (called from disclaimer alert)

    /// Save the planned route as a logbook entry AND start live GPS
    /// tracking. Triggered only after the user accepts the safety
    /// disclaimer.
    @MainActor
    func startActiveVoyage() {
        guard let plan = viewModel.routePlan else { return }
        saveCalculation()
        voyageManager.startVoyage(
            route: plan,
            userWaypointIDs: viewModel.userWaypointIDs,
            plannedSpeedKnots: viewModel.speedKnots
        )
    }

    /// Stop tracking, persist the actual voyage as a second logbook entry.
    @MainActor
    func finishActiveVoyage() {
        let weather = weatherSnapshots.first(where: { $0.regionID == viewModel.destinationHarbourID })?.currentSummary
            ?? weatherReading?.current.condition ?? ""
        let tide = tideReading?.summary ?? ""
        let crew = crewSummaryText()
        _ = voyageManager.stopVoyageAndSaveLogbook(
            modelContext: modelContext,
            weatherSummary: weather,
            tideSummary: tide,
            crewSummary: crew
        )
    }
}
