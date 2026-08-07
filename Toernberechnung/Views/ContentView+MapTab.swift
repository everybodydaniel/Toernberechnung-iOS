// swiftlint:disable file_length
import SwiftUI

// MARK: - Dashboard Snap Positions

enum DashboardDetent: CaseIterable {
    case nautiOnly  // Compact assistant launcher (~58pt)
    case summary    // Status + Nauti + passage window + metrics (~440pt)
    case full       // Everything including voyage actions (~540pt)

    var height: CGFloat {
        switch self {
        case .nautiOnly: return 58
        case .summary: return 440
        case .full: return 540
        }
    }

    /// Returns the next detent when dragging upward.
    var expandedNeighbour: DashboardDetent {
        switch self {
        case .nautiOnly: return .summary
        case .summary: return .full
        case .full: return .full
        }
    }

    /// Returns the next detent when dragging downward.
    var collapsedNeighbour: DashboardDetent {
        switch self {
        case .nautiOnly: return .nautiOnly
        case .summary: return .nautiOnly
        case .full: return .summary
        }
    }
}

struct IntermediateStopPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let harbours: [HarbourOption]
    let unavailableReasons: [String: String]
    let onAdd: ([String]) -> Void

    @State private var searchText = ""
    @State private var selectedHarbourIDs: [String] = []

    private var matchingHarbours: [HarbourOption] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return harbours }
        return harbours.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.tideStationName.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectableHarbours: [HarbourOption] {
        harbours.filter { unavailableReasons[$0.id] == nil }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(matchingHarbours) { harbour in
                        harbourRow(harbour)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .scrollIndicators(.hidden)
            .overlay {
                if matchingHarbours.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else if selectableHarbours.isEmpty, searchText.isEmpty {
                    ContentUnavailableView(
                        "Alle Häfen eingeplant",
                        systemImage: "checkmark.circle.fill",
                        description: Text("Start, Ziel und vorhandene Zwischenstopps belegen bereits alle verfügbaren Häfen.")
                    )
                }
            }
            .appSheetBackground {
                Color.appBackground.ignoresSafeArea()
            }
            .navigationTitle("Zwischenstopps")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Hafen suchen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onAdd(selectedHarbourIDs)
                    dismiss()
                } label: {
                    Label(addButtonTitle, systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .appProminentButton(tint: Color.appPrimary)
                .disabled(selectedHarbourIDs.isEmpty)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .background(.ultraThinMaterial)
            }
        }
        .accessibilityIdentifier("IntermediateStopPicker")
    }

    private var addButtonTitle: String {
        switch selectedHarbourIDs.count {
        case 1: return "1 Zwischenstopp hinzufügen"
        default: return "\(selectedHarbourIDs.count) Zwischenstopps hinzufügen"
        }
    }

    private func harbourRow(_ harbour: HarbourOption) -> some View {
        let unavailableReason = unavailableReasons[harbour.id]
        let selectionNumber = selectedHarbourIDs.firstIndex(of: harbour.id).map { $0 + 1 }

        return Button {
            toggleSelection(harbour.id)
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    Circle()
                        .fill(selectionNumber == nil ? Color.appPrimary.opacity(0.10) : Color.appPrimary)
                        .frame(width: 42, height: 42)

                    if let selectionNumber {
                        Text("\(selectionNumber)")
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(unavailableReason == nil ? Color.appPrimary : Color.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(harbour.name)
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(Color.primary)
                    Text(unavailableReason ?? harbour.tideStationName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(unavailableReason == nil ? Color.secondary : Color.orange)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: selectionNumber == nil ? "circle" : "checkmark.circle.fill")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(selectionNumber == nil ? Color.secondary.opacity(0.45) : Color.appPrimary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                selectionNumber == nil ? Color.fieldBackground : Color.appPrimary.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(unavailableReason != nil)
        .opacity(unavailableReason == nil ? 1 : 0.62)
        .accessibilityLabel(harbour.name)
        .accessibilityValue(accessibilityValue(reason: unavailableReason, selectionNumber: selectionNumber))
        .accessibilityIdentifier("IntermediateStop-\(harbour.id)")
    }

    private func toggleSelection(_ harbourID: String) {
        if let index = selectedHarbourIDs.firstIndex(of: harbourID) {
            selectedHarbourIDs.remove(at: index)
        } else {
            selectedHarbourIDs.append(harbourID)
        }
    }

    private func accessibilityValue(reason: String?, selectionNumber: Int?) -> String {
        if let reason { return "Nicht auswählbar, \(reason)" }
        if let selectionNumber { return "Ausgewählt als Stopp \(selectionNumber)" }
        return "Nicht ausgewählt"
    }
}

extension ContentView {

    // MARK: - Route Display Properties

    var displayStartHarbourName: String { viewModel.selectedStartHarbour?.name ?? "Start wählen" }
    var displayDestinationHarbourName: String { viewModel.selectedDestinationHarbour?.name ?? "Ziel wählen" }
    var routeTitle: String { viewModel.routeTitle }
    var startHarbour: HarbourOption { viewModel.startHarbour }
    var destinationHarbour: HarbourOption { viewModel.destinationHarbour }

    var mapGlassPrimary: Color {
        if #available(iOS 26.0, *) { return .primary }
        return .white
    }

    var mapGlassSecondary: Color {
        if #available(iOS 26.0, *) { return .primary.opacity(0.62) }
        return .white.opacity(0.62)
    }

    var mapGlassInsetFill: Color {
        if #available(iOS 26.0, *) { return .primary.opacity(0.08) }
        return .white.opacity(0.10)
    }

    var dieselLiters: Double {
        max((viewModel.calculationResult?.totalDistanceNm ?? 0) * 0.35, 0)
    }

    // MARK: - Calculator Tab

    func calculatorTab() -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                CompactMapView(
                    zoomLevel: 8.0,
                    start: viewModel.selectedStartHarbour,
                    destination: viewModel.selectedDestinationHarbour,
                    routePlan: viewModel.routePlan,
                    waypointResults: viewModel.calculationResult?.waypointResults,
                    voyageActive: voyageManager.isVoyageActive,
                    breadcrumbCoordinates: voyageManager.breadcrumbs.map(\.coordinate)
                )
                .ignoresSafeArea()

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.36),
                        Color.black.opacity(0.02),
                        Color.black.opacity(0.54)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                VStack(spacing: 0) {
                    mapRouteControls
                        .padding(.top, 148) // Increased from 88 to avoid overlapping with AppHeader
                        .padding(.horizontal, 16)
                        .opacity(nautiDashboardMode.isExpanded ? 0 : (mapHeaderHidden ? 0.96 : 1))
                        .allowsHitTesting(!nautiDashboardMode.isExpanded)

                    Spacer(minLength: 20)
                }

                // MARK: Draggable Bottom Dashboard
                mapDraggableBottomPanel(availableHeight: geometry.size.height)
                    .frame(
                        maxWidth: !nautiDashboardMode.isExpanded && dashboardDetent == .nautiOnly
                            ? min(geometry.size.width - 80, 300)
                            : .infinity
                    )
                    .padding(
                        .horizontal,
                        nautiDashboardMode.isExpanded
                            ? 12
                            : (dashboardDetent == .nautiOnly ? 0 : 14)
                    )
                    .padding(.bottom, dashboardDetent == .nautiOnly ? 104 : 86)
            }
        }
    }

    private var mapRouteControls: some View {
        Button {
            mapPlanningShown = true
        } label: {
            mapPlanningSummaryPill
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Törnplanung bearbeiten")
    }

    /// One graphite Glass surface with three inline modes: route dashboard,
    /// Nauti chat, and Nauti history.
    private func mapDraggableBottomPanel(availableHeight: CGFloat) -> some View {
        let dashboardHeight = max(
            dashboardDetent.height - dashboardDragOffset,
            DashboardDetent.nautiOnly.height
        )
        let panelHeight = nautiDashboardMode.isExpanded
            ? NautiDashboardGeometry.panelHeight(availableHeight: availableHeight)
            : dashboardHeight

        return Group {
            if nautiDashboardMode.isExpanded {
                NautiInlineDashboardHost(
                    mode: $nautiDashboardMode,
                    viewModel: nautiViewModel,
                    speechController: nautiSpeechController,
                    focusDismissTrigger: nautiFocusDismissTrigger,
                    onCollapse: closeNautiChat,
                    onAction: handleNautiAction,
                    onPayloadAction: openNautiPayload,
                    accessState: aiAccess.state,
                    onRetryAvailability: {
                        Task { await aiAccess.refresh() }
                    }
                )
                .accessibilityIdentifier("NautiInlinePanel")
            } else {
                mapDashboardContent
                    .padding(dashboardDetent == .nautiOnly ? 8 : 14)
                    .transition(.opacity)
            }
        }
        .frame(height: panelHeight, alignment: .top)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .appGraphiteMapOverlay(cornerRadius: 30)
        .simultaneousGesture(
            dashboardDragGesture,
            including: hasCalculatedRouteDashboard ? .all : .none
        )
        .animation(
            reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.46, dampingFraction: 0.84),
            value: dashboardDetent
        )
        .animation(
            NautiDashboardGeometry.animation(reduceMotion: reduceMotion),
            value: nautiDashboardMode
        )
    }

    private var mapDashboardContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if dashboardDetent != .nautiOnly {
                Capsule()
                    .fill(mapGlassSecondary.opacity(0.56))
                    .frame(width: 42, height: 5)
                    .frame(maxWidth: .infinity)
                    .frame(height: 20)
                    .contentShape(Rectangle())

                mapStatusRow
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            nautiDashboardLauncher

            if hasCalculatedRouteDashboard,
               dashboardDetent != .nautiOnly || dashboardDragOffset < -40 {
                mapPassageWindowRow
                    .transition(.opacity.combined(with: .move(edge: .bottom)))

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    mapDashboardMetric("Reisezeit", value: viewModel.totalTravelTimeText, icon: "hourglass")
                    mapDashboardMetric("Ankunft", value: viewModel.arrivalTimeText, icon: "flag.checkered")
                    mapDashboardMetric("Distanz", value: viewModel.totalDistanceText, icon: "ruler")
                    mapDashboardMetric("WuK", value: viewModel.worstWuKText, icon: "water.waves")
                    mapDashboardMetric("Diesel", value: String(format: "%.1f l", dieselLiters), icon: "fuelpump.fill")
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if hasCalculatedRouteDashboard,
               dashboardDetent == .full || dashboardDragOffset < -80 {
                mapVoyageActions
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    private var nautiDashboardLauncher: some View {
        HStack(spacing: 8) {
            Button(action: openNautiChat) {
                HStack(spacing: 10) {
                    if nautiViewModel.isSending {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.cyan)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.cyan)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text("Nauti KI")
                                .font(.system(size: 13, weight: .heavy))
                                .foregroundStyle(mapGlassPrimary)
                            if nautiViewModel.isSending {
                                Circle()
                                    .fill(Color.cyan)
                                    .frame(width: 7, height: 7)
                                    .shadow(color: Color.cyan.opacity(0.7), radius: 4)
                                    .accessibilityHidden(true)
                            } else if let issue = visibleNautiProactiveIssue {
                                Circle()
                                    .fill(issueColor(for: issue))
                                    .frame(width: 8, height: 8)
                            }
                        }
                        Text(nautiViewModel.isSending ? "Antwort wird erstellt…" : "Törn, Wetter oder Gezeiten")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(mapGlassSecondary)
                    }

                    Spacer()

                    Image(systemName: dashboardDetent == .nautiOnly ? "chevron.right" : "chevron.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.cyan)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, dashboardDetent == .nautiOnly ? 5 : 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    dashboardDetent == .nautiOnly ? Color.clear : Color.white.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Nauti Chat öffnen")
            .accessibilityValue(nautiViewModel.isSending ? "Antwort wird erstellt" : "Bereit")
            .accessibilityIdentifier("NautiInlineLauncher")

            if nautiViewModel.isSending {
                Button {
                    nautiViewModel.cancelCurrentInference()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Color.red.opacity(0.88), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Nauti-Antwort stoppen")
            }
        }
    }

    /// Drag gesture for the bottom dashboard panel that snaps between detents.
    private var dashboardDragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !nautiDashboardMode.isExpanded else { return }
                guard hasCalculatedRouteDashboard else {
                    dashboardDragOffset = 0
                    return
                }
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                // Positive = drag down (shrink), negative = drag up (expand)
                dashboardDragOffset = value.translation.height
            }
            .onEnded { value in
                guard !nautiDashboardMode.isExpanded else { return }
                guard hasCalculatedRouteDashboard else {
                    dashboardDragOffset = 0
                    return
                }
                let translation = value.translation.height
                let velocity = value.predictedEndTranslation.height - value.translation.height

                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    if translation < -50 || velocity < -300 {
                        dashboardDetent = dashboardDetent.expandedNeighbour
                    } else if translation > 50 || velocity > 300 {
                        // Drag down → collapse
                        dashboardDetent = dashboardDetent.collapsedNeighbour
                    }
                    dashboardDragOffset = 0
                }
            }
    }

    private var mapStatusRow: some View {
        let status = viewModel.combinedStatus ?? .incomplete
        let weatherProgress: RouteWeatherProgress? = {
            guard case .loading(let completed, let total) = viewModel.routeWeatherValidationState else {
                return nil
            }
            return RouteWeatherProgress(completed: completed, total: total)
        }()
        let icon = status == .go ? "checkmark.circle.fill"
            : status == .warning ? "exclamationmark.triangle.fill"
            : status == .noGo ? "xmark.circle.fill"
            : "questionmark.circle.fill"
        let accent = status == .go ? Color.green
            : status == .warning ? Color.orange
            : status == .noGo ? Color.red
            : mapGlassSecondary

        return HStack(spacing: 11) {
            if viewModel.isCalculating || weatherProgress != nil {
                ProgressView()
                    .tint(mapGlassPrimary)
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(accent)
                    .frame(width: 32, height: 32)
                    .background(mapGlassInsetFill, in: Circle())
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Route")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(mapGlassSecondary)
                Text(viewModel.statusText)
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(mapGlassPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                if let weatherProgress, weatherProgress.total > 0 {
                    ProgressView(
                        value: Double(weatherProgress.completed),
                        total: Double(weatherProgress.total)
                    )
                    .tint(Color.appPrimary)
                    .frame(maxWidth: 160)
                    .accessibilityLabel("Wetterprüfung")
                    .accessibilityValue("\(weatherProgress.completed) von \(weatherProgress.total) Seegebieten")
                } else if case .unavailable(let message) = viewModel.routeWeatherValidationState {
                    Text(message)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(mapGlassSecondary)
                        .lineLimit(2)
                }
            }

            Spacer()
        }
    }

    private var mapPassageWindowRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.appPrimary)
                .frame(width: 30, height: 30)
                .background(mapGlassInsetFill, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Sicheres Abfahrtsfenster")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(mapGlassSecondary)
                if let window = viewModel.passageWindow {
                    Text(window.displayString)
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(window.contains(viewModel.departure) ? mapGlassPrimary : Color.orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                } else {
                    Text(viewModel.isSearchingWindow ? "Wird berechnet…" : (viewModel.passageWindowMessage ?? "Noch nicht berechnet"))
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(mapGlassPrimary.opacity(0.78))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }

            Spacer()

            Button {
                viewModel.refreshPassageWindow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.appPrimary)
                    .frame(width: 34, height: 34)
                    .background(mapGlassInsetFill, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Passagefenster aktualisieren")
        }
        .padding(10)
        .appMapDashboardInset(cornerRadius: 20)
    }

    private func mapDashboardMetric(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.appPrimary)
                .frame(width: 25, height: 25)
                .background(mapGlassInsetFill, in: Circle())
            Text(title.uppercased())
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(mapGlassSecondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(mapGlassPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .appMapDashboardInset(cornerRadius: 20)
    }

    @ViewBuilder
    private var mapVoyageActions: some View {
        if voyageManager.isVoyageActive {
            HStack(spacing: 9) {
                Button {
                    navigationFullScreenShown = true
                } label: {
                    Label("Navigation", systemImage: "location.fill")
                        .lineLimit(1)
                }
                .appProminentButton(tint: Color(hex: 0x14B8A6))

                Button {
                    stopVoyageAlertShown = true
                } label: {
                    Label("Beenden", systemImage: "stop.circle.fill")
                        .lineLimit(1)
                }
                .appProminentButton(tint: .red)
            }
        } else {
            HStack(spacing: 9) {
                Button {
                    saveCalculation()
                } label: {
                    Label("Speichern", systemImage: "square.and.arrow.down")
                        .lineLimit(1)
                }
                .appProminentButton(tint: Color.appPrimary)

                Button {
                    voyageDisclaimerShown = true
                } label: {
                    Label("Fahrt starten", systemImage: "location.fill.viewfinder")
                        .lineLimit(1)
                }
                .appProminentButton(tint: Color(hex: 0x14B8A6))
            }
        }
    }

    private var mapPlanningSummaryPill: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.appPrimary)
                .frame(width: 36, height: 36)
                .background(mapGlassInsetFill, in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                if viewModel.hasCompleteRouteInput {
                    HStack(spacing: 5) {
                        Text(displayStartHarbourName)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold))
                        Text(displayDestinationHarbourName)
                    }
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(mapGlassPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)

                    Label(
                        "\(AppDateFormatters.dayMonthYear.string(from: viewModel.departure)) · \(AppDateFormatters.hourMinute.string(from: viewModel.departure)) Uhr",
                        systemImage: "calendar.badge.clock"
                    )
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(mapGlassSecondary)
                } else {
                    Text("Törn planen")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(mapGlassPrimary)
                    Text("Start, Ziel und Abfahrt auswählen")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(mapGlassSecondary)
                }
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.appPrimary)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appDarkFloatingOverlay(cornerRadius: 22)
    }

    private var routeControlPanel: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Törn planen")
                            .font(.system(size: 28, weight: .heavy))
                            .foregroundStyle(Color.appPrimary)
                        Text("Route, Abfahrt und Zwischenstopps")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.secondary)
                    }
                    Spacer()
                    Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color(hex: 0x3C82FF))
                        .frame(width: 44, height: 44)
                        .background(Color(hex: 0x3C82FF).opacity(0.12), in: Circle())
                }

                VStack(spacing: 12) {
                    routePickerPill(title: "Start", icon: "sailboat.fill", selection: $viewModel.startHarbourID)
                    intermediateStopsSection
                    routePickerPill(title: "Ziel", icon: "flag.checkered", selection: $viewModel.destinationHarbourID)
                    routeDatePicker
                }
            }
        }
    }

    var manualPlanningSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    routeControlPanel
                    planningWaterLevelSourcesCard
                    planningPassageWindowCard
                }
                .padding(16)
            }
            .appSheetBackground {
                Color.appBackground.ignoresSafeArea()
            }
            .navigationTitle("Törn planen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        mapPlanningShown = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Törnplanung schließen")
                }
            }
        }
        .sheet(isPresented: $intermediateStopPickerShown) {
            IntermediateStopPickerSheet(
                harbours: HarbourOption.options,
                unavailableReasons: intermediateStopUnavailableReasons,
                onAdd: { harbourIDs in
                    viewModel.addIntermediateStops(harbourIDs: harbourIDs)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.ultraThinMaterial)
            .presentationCornerRadius(30)
        }
    }

    private var routeStationsNeedingComparison: [BSHTideStation] {
        let identifiers = viewModel.routePlan?.waypoints.map(\.tidalReferenceStationID) ?? []
        return Array(Set(identifiers))
            .compactMap(BSHTideStationCatalog.station(id:))
            .filter { !$0.hasLocalWaterLevelForecast }
            .sorted { $0.name < $1.name }
    }

    @ViewBuilder
    private var planningWaterLevelSourcesCard: some View {
        if !routeStationsNeedingComparison.isEmpty {
            card {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Wasserstandsquelle", systemImage: "checkmark.shield")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(Color.appPrimary)

                    Text("Für diese lokalen Gezeitenpegel veröffentlicht das BSH keine eigene Modellprognose. Astronomische Zeiten bleiben lokal; ein Vergleichspegel überträgt ausschließlich den meteorologischen Restwasserstand.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(routeStationsNeedingComparison) { station in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(station.name)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(Color.appPrimary)
                                    Text("BSH \(station.id) · keine lokale Modellprognose")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Color.secondary)
                                }
                                Spacer()
                                if viewModel.confirmedComparisonGaugeIDs[station.id] != nil {
                                    Button {
                                        viewModel.clearComparisonGauge(localStationID: station.id)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 20, weight: .semibold))
                                            .foregroundStyle(Color.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Vergleichspegel entfernen")
                                }
                            }

                            if let comparisonID = viewModel.confirmedComparisonGaugeIDs[station.id],
                               let comparison = BSHTideStationCatalog.station(id: comparisonID) {
                                Label(
                                    "Bestätigt: \(comparison.name) · \(String(format: "%.1f", station.distanceKilometers(to: comparison))) km",
                                    systemImage: "exclamationmark.shield.fill"
                                )
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color(hex: 0xD97706))
                            } else {
                                Menu {
                                    ForEach(BSHTideStationCatalog.comparisonCandidates(for: station.id)) { candidate in
                                        Button {
                                            viewModel.confirmComparisonGauge(
                                                localStationID: station.id,
                                                comparisonStationID: candidate.id
                                            )
                                        } label: {
                                            Text("\(candidate.name) · \(String(format: "%.1f", station.distanceKilometers(to: candidate))) km")
                                        }
                                    }
                                } label: {
                                    Label("Vergleichspegel ausdrücklich bestätigen", systemImage: "checkmark.circle")
                                        .font(.system(size: 12, weight: .bold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                }
                                .buttonStyle(.bordered)
                                .tint(Color(hex: 0xD97706))
                            }
                        }
                        .padding(12)
                        .background(Color.fieldBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    Text("Mit Vergleichspegel kann ein rechnerisch sicheres Ergebnis höchstens gelb sein. No-Go bleibt No-Go.")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }
            }
        }
    }

    private var planningPassageWindowCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Sicheres Abfahrtsfenster", systemImage: "clock.badge.checkmark")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(Color.appPrimary)
                    Spacer()
                    Button {
                        viewModel.refreshPassageWindow()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Passagefenster aktualisieren")
                }

                if let window = viewModel.passageWindow {
                    Text(window.displayString)
                        .font(.system(size: 24, weight: .heavy))
                        .foregroundStyle(Color.appPrimary)
                    Text(window.contains(viewModel.departure)
                         ? "Die gewählte Abfahrt liegt innerhalb des sicheren Fensters."
                         : "Die gewählte Abfahrt liegt außerhalb des sicheren Fensters.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(window.contains(viewModel.departure) ? Color.secondary : Color(hex: 0xD97706))
                    if window.waterLevelQuality != .localOfficial {
                        Label(
                            window.waterLevelDetail ?? "Das Passagefenster basiert nicht auf einer aktuellen lokalen BSH-Prognose.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xD97706))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } else if viewModel.isSearchingWindow {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Passagefenster wird berechnet…")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.secondary)
                    }
                } else {
                    Text(viewModel.passageWindowMessage ?? "Für diese Route liegt noch kein Passagefenster vor.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var tideNodeEnvironmentPanel: some View {
        if viewModel.weatherStatus == .noGo {
            tideNodeWindPanel
        } else if let window = viewModel.passageWindow,
                  !window.contains(viewModel.departure) {
            tideNodePassagePanel(window)
        } else {
            tideNodeTidePanel
        }
    }

    private var tideNodeTidePanel: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Gezeiten am Ziel", systemImage: "water.waves")
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(Color.appPrimary)
                    Spacer()
                    Text("BSH")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(Color(hex: 0x0077B6))
                        .appChipSurface(tint: Color(hex: 0x0077B6))
                }

                if let forecast = waterLevelForecasts[destinationHarbour.tideStationID], !forecast.curve.isEmpty {
                    WaterLevelChartView(forecast: forecast)
                } else if let tideReading {
                    Text("\(tideReading.stationName) · BSH \(tideReading.stationID)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                    tideEventsRow(Array(tideReading.events.prefix(4)))
                } else if tideLoading || waterLevelLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Gezeitendaten werden geladen…")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.secondary)
                    }
                } else {
                    Text(tideError ?? "Gezeitendaten sind momentan nicht verfügbar.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.secondary)
                }
            }
        }
    }

    private var tideNodeWindPanel: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Wetterlage für die Route", systemImage: "wind.warning")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(Color(hex: 0xC2410C))

                Text("Die aktuelle Wetterbewertung ist kritisch. Prüfe Wind, Böen und Sicht vor einer neuen Berechnung.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.secondary)

                if let report = islandWeatherReports[viewModel.destinationHarbourID] ?? weatherReport,
                   !report.hourly.isEmpty {
                    let departureSlots = report.hourly.filter { $0.date >= viewModel.departure.addingTimeInterval(-30 * 60) }
                    let slots = departureSlots.isEmpty ? Array(report.hourly.prefix(4)) : Array(departureSlots.prefix(4))
                    HStack(spacing: 8) {
                        ForEach(slots) { slot in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(AppDateFormatters.hourMinute.string(from: slot.date))
                                    .font(.system(size: 11, weight: .heavy))
                                    .foregroundStyle(Color.secondary)
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(Color(hex: 0xC2410C))
                                    .rotationEffect(.degrees(slot.wind.flowArrowRotationDegrees))
                                Text("\(Int(slot.wind.speedKnots.rounded())) kn")
                                    .font(.system(size: 15, weight: .heavy))
                                    .foregroundStyle(Color.appPrimary)
                                Text("Böen \(Int(slot.wind.effectiveGustKnots.rounded()))")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color(hex: 0xC2410C))
                            }
                            .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
                            .padding(10)
                            .background(Color.fieldBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                } else {
                    Text("Apple-Weather-Winddaten werden geladen oder sind derzeit nicht verfügbar.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.secondary)
                }
            }
        }
    }

    private func tideNodePassagePanel(_ window: PassageWindowScanner.Window) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Abfahrt neu abstimmen", systemImage: "clock.badge.exclamationmark")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(Color(hex: 0xB45309))
                Text("Sicheres Zeitfenster: \(window.displayString)")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(Color.appPrimary)
                Text("Die gewählte Abfahrt liegt außerhalb des Fensters. Öffne die Planung oder frage Nauti nach einem Vorschlag.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.secondary)
                Button("Planung öffnen") {
                    mapPlanningShown = true
                }
                .appGlassButton(tint: Color(hex: 0xB45309))
            }
        }
    }

    private func routePickerPill(title: String, icon: String, selection: Binding<String>) -> some View {
        Picker(selection: selection) {
            Text("Nicht gewählt").tag("")
            ForEach(HarbourOption.options) { harbour in
                Text(harbour.name).tag(harbour.id)
            }
        } label: {
            routePillLabel(
                title: title,
                value: HarbourOption.optionalByID(selection.wrappedValue)?.name ?? "Bitte auswählen",
                icon: icon
            )
        }
        .pickerStyle(.menu)
        .tint(Color(hex: 0x0077B6))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.fieldBackground, in: Capsule(style: .continuous))
    }

    private func routePillLabel(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(
                    LinearGradient(
                        colors: [Color(hex: 0x38BDF8), Color(hex: 0x0077B6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(Color.secondary)
                Text(value)
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Color.appPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }

            Spacer()

            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(Color.secondary)
                .frame(width: 32, height: 32)
                .background(Color.cardBackground.opacity(0.78), in: Circle())
        }
    }

    private var routeDatePicker: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color(hex: 0x14B8A6), in: Circle())

            DatePicker("Abfahrt", selection: $viewModel.departure, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)
                .environment(\.locale, AppDateFormatters.germanLocale)
                .environment(\.timeZone, AppDateFormatters.berlinTimeZone)
                .font(.system(size: 15, weight: .semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.fieldBackground, in: Capsule(style: .continuous))
    }

    // MARK: - Intermediate Stops (Zwischenstopps)

    private var intermediateStopsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Zwischenstopps", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(Color.secondary)
                Spacer()
                Button {
                    intermediateStopPickerShown = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color(hex: 0x0077B6), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zwischenstopps auswählen")
                .accessibilityIdentifier("IntermediateStopPickerButton")
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
                ForEach(intermediateStopChoices(for: stopID)) { harbour in
                    Text(harbour.name).tag(harbour.id)
                }
            }
            .pickerStyle(.menu)
            .tint(Color(hex: 0x0077B6))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.fieldBackground, in: Capsule(style: .continuous))

            Button {
                viewModel.removeIntermediateStop(id: stopID)
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.red)
                    .frame(width: 44, height: 44)
                    .background(Color.red.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(positionLabel) entfernen")
        }
    }

    private var intermediateStopUnavailableReasons: [String: String] {
        var reasons: [String: String] = [:]
        if !viewModel.startHarbourID.isEmpty {
            reasons[viewModel.startHarbourID] = "Start"
        }
        if !viewModel.destinationHarbourID.isEmpty {
            reasons[viewModel.destinationHarbourID] = "Ziel"
        }
        for stop in viewModel.intermediateStops where reasons[stop.harbourID] == nil {
            reasons[stop.harbourID] = "Bereits eingeplant"
        }
        return reasons
    }

    private func intermediateStopChoices(for stopID: IntermediateStop.ID) -> [HarbourOption] {
        let currentHarbourID = viewModel.intermediateStops.first(where: { $0.id == stopID })?.harbourID
        var unavailable = Set(intermediateStopUnavailableReasons.keys)
        if let currentHarbourID {
            unavailable.remove(currentHarbourID)
        }
        return HarbourOption.options.filter { !unavailable.contains($0.id) }
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
        guard viewModel.hasCompleteRouteInput, viewModel.routePlan != nil else { return }
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
            weatherSummary: weatherSnapshots.first(where: { $0.regionID == viewModel.destinationHarbourID })?.currentSummary ?? weatherReport?.current.condition ?? "",
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
        guard let destination = viewModel.selectedDestinationHarbour else { return }
        weatherRegionID = destination.id
        tideStationID = destination.tideStationID
    }

    @MainActor
    func handleRoutePresentationChange(routeID: UUID?) {
        guard routeID != nil else {
            routeDashboardRevealPending = false
            withAnimation(reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.42, dampingFraction: 0.86)) {
                dashboardDetent = .nautiOnly
                dashboardDragOffset = 0
            }
            return
        }

        routeDashboardRevealPending = true
        if dashboardDetent != .nautiOnly {
            withAnimation(reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.42, dampingFraction: 0.86)) {
                dashboardDetent = .nautiOnly
                dashboardDragOffset = 0
            }
        }
    }

    @MainActor
    func handleRouteCalculationStateChange(isCalculating: Bool) {
        guard viewModel.routePlan != nil else { return }

        if isCalculating {
            routeDashboardRevealPending = true
            if dashboardDetent != .nautiOnly {
                withAnimation(reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.42, dampingFraction: 0.86)) {
                    dashboardDetent = .nautiOnly
                    dashboardDragOffset = 0
                }
            }
            return
        }

        guard hasCalculatedRouteDashboard else { return }
        if mapPlanningShown || nautiDashboardMode.isExpanded {
            routeDashboardRevealPending = true
        } else {
            revealRouteDashboard()
        }
    }

    @MainActor
    func revealRouteDashboardIfPending() {
        guard routeDashboardRevealPending, hasCalculatedRouteDashboard else { return }
        revealRouteDashboard()
    }

    private var hasCalculatedRouteDashboard: Bool {
        viewModel.routePlan != nil
            && viewModel.calculationResult != nil
            && !viewModel.isCalculating
    }

    @MainActor
    private func revealRouteDashboard() {
        routeDashboardRevealPending = false
        withAnimation(reduceMotion ? .easeOut(duration: 0.20) : .spring(response: 0.50, dampingFraction: 0.82)) {
            dashboardDetent = .summary
            dashboardDragOffset = 0
        }
    }

    // MARK: - Voyage lifecycle (called from disclaimer alert)

    /// Start live GPS tracking. The logbook entry is created only when
    /// the user ends the voyage, so starting GPS does not create a fake
    /// completed trip.
    @MainActor
    func startActiveVoyage() {
        guard let plan = viewModel.routePlan else { return }
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
            ?? weatherReport?.current.condition ?? ""
        let tide = tideReading?.summary ?? ""
        let crew = crewSummaryText()
        _ = voyageManager.stopVoyageAndSaveLogbook(
            modelContext: modelContext,
            weatherSummary: weather,
            tideSummary: tide,
            crewSummary: crew
        )
    }

    private func issueColor(for issue: NautiProactiveIssue) -> Color {
        switch issue.accent {
        case .cyan: return Color(hex: 0x0891B2)
        case .amber: return Color(hex: 0xD97706)
        case .red: return Color(hex: 0xDC2626)
        }
    }
}
