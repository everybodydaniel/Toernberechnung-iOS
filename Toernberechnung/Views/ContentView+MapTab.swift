// swiftlint:disable file_length
import SwiftUI

// MARK: - Dashboard Snap Positions

enum DashboardDetent: CaseIterable {
    case nautiOnly  // Compact assistant launcher (~58pt)
    case summary    // Status + Nauti + passage window + metrics
    case full       // Everything including voyage actions

    var height: CGFloat {
        switch self {
        case .nautiOnly: return 58
        case .summary: return 485
        case .full: return 530
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

    var dieselLiters: Double {
        max((viewModel.calculationResult?.totalDistanceNm ?? 0) * 0.35, 0)
    }

    // MARK: - Calculator Tab

    func calculatorTab() -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                CompactMapView(
                    start: viewModel.selectedStartHarbour,
                    destination: viewModel.selectedDestinationHarbour,
                    routePlan: viewModel.routePlan,
                    waypointResults: viewModel.calculationResult?.waypointResults,
                    voyageActive: voyageManager.isVoyageActive,
                    breadcrumbCoordinates: voyageManager.breadcrumbs.map(\.coordinate),
                    focusCoordinate: mapFocusCoordinate,
                    focusWarning: selectedMapWarning,
                    onSelectWarning: { warning in
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            selectedMapWarning = warning
                        }
                    }
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
                .ignoresSafeArea()
                .allowsHitTesting(false)

                VStack(spacing: 0) {
                    if !isPad {
                        mapRouteControls
                            .padding(.top, 148)
                            .padding(.horizontal, 16)
                            .opacity(nautiDashboardMode.isExpanded ? 0 : 1)
                            .allowsHitTesting(!nautiDashboardMode.isExpanded)
                    }

                    Spacer(minLength: 20)
                }

                // MARK: Floating Warning Callout Card
                if let warning = selectedMapWarning, !nautiDashboardMode.isExpanded {
                    warningMapCalloutCard(warning: warning)
                        .frame(maxWidth: min(geometry.size.width - 32, 440))
                        .padding(.horizontal, 16)
                        .padding(
                            .bottom,
                            dashboardBottomInset + (dashboardDetent == .nautiOnly ? (hasCalculatedRouteDashboard ? 80 : 66) : (dashboardDetent.height + 16))
                        )
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.95)),
                            removal: .opacity.combined(with: .scale(scale: 0.95))
                        ))
                        .zIndex(15)
                }

                // MARK: Draggable Bottom Dashboard
                mapDraggableBottomPanel(availableHeight: geometry.size.height)
                    .frame(
                        maxWidth: !nautiDashboardMode.isExpanded && dashboardDetent == .nautiOnly && !hasCalculatedRouteDashboard
                            ? min(geometry.size.width - 48, 332)
                            : .infinity
                    )
                    .padding(
                        .horizontal,
                        nautiDashboardMode.isExpanded
                            ? 12
                            : (dashboardDetent == .nautiOnly && !hasCalculatedRouteDashboard ? 0 : 14)
                    )
                    // With the keyboard up the tab bar is hidden anyway, so the
                    // 86/104pt reserved for it would only push the chat input
                    // back behind the keyboard.
                    .padding(.bottom, dashboardBottomInset)
            }
        }
    }

    var mapRouteControls: some View {
        Button {
            mapPlanningShown = true
        } label: {
            mapPlanningSummaryPill
        }
        .buttonStyle(.plain)
        // Glass outside the button, `.contentShape` inside the label — with
        // the interactive glass inside, only the leading icon (which carries
        // its own glass circle) was hit-testable.
        .appDarkFloatingOverlay(cornerRadius: 22)
        .accessibilityLabel("Törnplanung bearbeiten")
        .accessibilityIdentifier("MapPlanningPill")
    }

    // MARK: - Maritime Warning Map Callout Card

    private func warningMapCalloutCard(warning: MaritimeWarning) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            warningCalloutHeader(warning: warning)

            // Description Details
            Text(warning.details)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.secondary)
                .lineLimit(4)
                .lineSpacing(2)

            warningCalloutMetaRow(warning: warning)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(warning.severity.displayColor.opacity(0.35), lineWidth: 1.2)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 16, x: 0, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MaritimeWarningMapCallout")
    }

    private func warningCalloutHeader(warning: MaritimeWarning) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: warning.severity.systemImage)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(warning.severity.displayColor)
                .frame(width: 32, height: 32)
                .background(warning.severity.displayColor.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(warning.areaName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.appPrimary)
                        .lineLimit(1)

                    Text("•")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondary)

                    Text(warning.severity.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(warning.severity.displayColor)
                        .lineLimit(1)
                }

                Text(warning.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    selectedMapWarning = nil
                    mapFocusCoordinate = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Warnung schließen")
        }
    }

    private func warningCalloutMetaRow(warning: MaritimeWarning) -> some View {
        HStack(spacing: 8) {
            if let coords = warning.formattedCoordinates {
                HStack(spacing: 4) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 9, weight: .semibold))
                    Text(coords)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                }
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.06), in: Capsule())
            }

            Text(warning.source.shortName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

            Spacer()

            if let url = warning.webUrl {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Text("Quelle")
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.appPrimary.opacity(0.14), in: Capsule())
                    .foregroundStyle(Color.appPrimary)
                }
            }
        }
    }

    /// Space reserved under the map dashboard. Normally that is the floating
    /// tab bar; while the keyboard is open the tab bar is gone and the panel
    /// should sit right on top of the keyboard instead.
    var dashboardBottomInset: CGFloat {
        if keyboardVisible, nautiDashboardMode.isExpanded { return 8 }
        if isPad { return 120 }
        if hasCalculatedRouteDashboard {
            return dashboardDetent == .nautiOnly ? 108 : 90
        }
        return dashboardDetent == .nautiOnly ? 104 : 86
    }

    /// One graphite Glass surface with three inline modes: route dashboard,
    /// Nauti chat, and Nauti history.
    private func mapDraggableBottomPanel(availableHeight: CGFloat) -> some View {
        let dashboardHeight: CGFloat = {
            if dashboardDetent == .nautiOnly {
                return hasCalculatedRouteDashboard ? 72 : 58
            }
            return dashboardDetent.height
        }()
        let panelHeight = nautiDashboardMode.isExpanded
            ? NautiDashboardGeometry.panelHeight(
                availableHeight: availableHeight,
                bottomInset: dashboardBottomInset
            )
            : (isPad
                ? min(dashboardHeight, max(58, availableHeight - dashboardBottomInset - 190))
                : dashboardHeight)

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
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("NautiInlinePanel")
                .frame(height: panelHeight, alignment: .top)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                .appGraphiteMapOverlay(cornerRadius: 30)
            } else if hasCalculatedRouteDashboard {
                Group {
                    if isPad, dashboardDetent != .nautiOnly {
                        ScrollView {
                            mapDashboardContent
                                .padding(14)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                    } else {
                        mapDashboardContent
                            .padding(dashboardDetent == .nautiOnly ? 10 : 14)
                            .transition(.opacity)
                    }
                }
                .frame(height: panelHeight, alignment: .top)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                .appGraphiteMapOverlay(cornerRadius: 30)
                .simultaneousGesture(
                    dashboardDragGesture,
                    including: .all
                )
            } else {
                NautiHeroPillLauncher(
                    action: openNautiChat,
                    isSending: nautiViewModel.isSending,
                    issueColor: visibleNautiProactiveIssue.map(issueColor)
                )
            }
        }
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
        Group {
            if hasCalculatedRouteDashboard && dashboardDetent == .nautiOnly {
                collapsedRouteDashboardBar
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if dashboardDetent != .nautiOnly {
                        Capsule()
                            .fill(mapGlassSecondary.opacity(0.56))
                            .frame(width: 42, height: 5)
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                                    dashboardDetent = .nautiOnly
                                }
                            }

                        mapStatusRow
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    nautiDashboardLauncher

                    if hasCalculatedRouteDashboard,
                       dashboardDetent != .nautiOnly {
                        mapPassageWindowRow
                            .transition(.opacity.combined(with: .move(edge: .bottom)))

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                            mapDashboardMetric("Reisezeit", value: viewModel.totalTravelTimeText, icon: "hourglass")
                            mapDashboardMetric("Ankunft", value: viewModel.arrivalTimeText, icon: "flag.checkered")
                            mapDashboardMetric("Distanz", value: viewModel.totalDistanceText, icon: "ruler")
                            mapDashboardMetric("WuK", value: viewModel.worstWuKText, icon: "water.waves")
                            mapDashboardWindMetric
                            mapDashboardMetric("Speed", value: String(format: "%.1f kn", viewModel.speedKnots), icon: "speedometer")
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    if hasCalculatedRouteDashboard,
                       dashboardDetent == .full {
                        mapVoyageActions
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
            }
        }
    }

    private var collapsedRouteDashboardBar: some View {
        VStack(spacing: 5) {
            Capsule()
                .fill(mapGlassSecondary.opacity(0.56))
                .frame(width: 36, height: 4)

            HStack(spacing: 8) {
                routeStatusIcon(size: 18)

                HStack(spacing: 8) {
                    Text(viewModel.statusText)
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(mapGlassPrimary)

                    HStack(spacing: 3) {
                        Image(systemName: "hourglass")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.appPrimary)
                        Text(viewModel.totalTravelTimeText)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(mapGlassPrimary)
                    }

                    HStack(spacing: 3) {
                        Image(systemName: "ruler")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.appPrimary)
                        Text(viewModel.totalDistanceText)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(mapGlassPrimary)
                    }

                    HStack(spacing: 3) {
                        Image(systemName: "water.waves")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.appPrimary)
                        Text(viewModel.worstWuKText)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(mapGlassPrimary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.70)

                Spacer(minLength: 2)

                NautiAnimatedPillButton(action: openNautiChat)
            }
            .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                dashboardDetent = .full
            }
        }
        .accessibilityElement(children: .contain)
    }

    private struct NautiAnimatedOrbView: View {
        var size: CGFloat = 38

        @State private var isPulsing = false
        @State private var rotationAngle: Double = 0

        var body: some View {
            ZStack {
                // Glass icon background matching the top pill
                Circle()
                    .frame(width: size, height: size)
                    .appGlassIconBackground()

                // Rotating ocean gradient aura ring
                Circle()
                    .strokeBorder(
                        AngularGradient(
                            colors: [
                                Color.cyan.opacity(0.85),
                                Color(hex: 0x38BDF8).opacity(0.40),
                                Color(hex: 0x0077B6).opacity(0.80),
                                Color.cyan.opacity(0.85)
                            ],
                            center: .center
                        ),
                        lineWidth: max(1.0, size * 0.04)
                    )
                    .rotationEffect(.degrees(rotationAngle))
                    .frame(width: size, height: size)

                // Breathing marine background glow
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.cyan.opacity(isPulsing ? 0.22 : 0.10),
                                Color.appPrimary.opacity(isPulsing ? 0.18 : 0.06)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: size, height: size)
                    .shadow(
                        color: Color.cyan.opacity(isPulsing ? 0.35 : 0.15),
                        radius: isPulsing ? (size * 0.16) : 2
                    )

                // Animated sparkles icon
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.44, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.appPrimary, Color.cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .symbolEffect(.pulse, options: .repeating)
            }
            .scaleEffect(isPulsing ? 1.04 : 0.98)
            .contentShape(Circle())
            .onAppear {
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
                withAnimation(.linear(duration: 8.0).repeatForever(autoreverses: false)) {
                    rotationAngle = 360
                }
            }
        }
    }

    private struct NautiAnimatedPillButton: View {
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                NautiAnimatedOrbView(size: 38)
            }
            .buttonStyle(NautiSpringScaleButtonStyle())
            .accessibilityLabel("Nauti KI öffnen")
        }
    }

    private struct NautiHeroPillLauncher: View {
        let action: () -> Void
        let isSending: Bool
        let issueColor: Color?

        private var primaryTextColor: Color {
            if #available(iOS 26.0, *) { return .primary }
            return .white
        }

        private var secondaryTextColor: Color {
            if #available(iOS 26.0, *) { return .primary.opacity(0.62) }
            return .white.opacity(0.62)
        }

        var body: some View {
            Button(action: action) {
                HStack(spacing: 12) {
                    if isSending {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.appPrimary)
                            .frame(width: 36, height: 36)
                    } else {
                        NautiAnimatedOrbView(size: 36)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Nauti KI")
                                .font(.system(size: 14, weight: .heavy))
                                .foregroundStyle(primaryTextColor)

                            if let issueColor {
                                Circle()
                                    .fill(issueColor)
                                    .frame(width: 7, height: 7)
                            }
                        }

                        Text(isSending ? "Antwort wird erstellt…" : "Törn, Wetter oder Gezeiten")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(secondaryTextColor)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.appPrimary)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(.plain)
            .appDarkFloatingOverlay(cornerRadius: 22)
            .accessibilityLabel("Nauti KI öffnen")
            .accessibilityIdentifier("NautiHeroLauncher")
        }
    }

    private struct NautiSpringScaleButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
                .animation(.spring(response: 0.28, dampingFraction: 0.65), value: configuration.isPressed)
        }
    }

    private func routeStatusIcon(size: CGFloat = 20) -> some View {
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

        return Group {
            if viewModel.isCalculating || weatherProgress != nil {
                ProgressView()
                    .tint(mapGlassPrimary)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: icon)
                    .font(.system(size: size, weight: .bold))
                    .foregroundStyle(accent)
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
                            .frame(width: 30, height: 30)
                    } else {
                        NautiAnimatedOrbView(size: 30)
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
                .padding(.horizontal, 10)
                .padding(.vertical, dashboardDetent == .nautiOnly ? 5 : 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    dashboardDetent == .nautiOnly ? Color.clear : Color.white.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(NautiSpringScaleButtonStyle())
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
    /// No real-time offset tracking — just detect direction on end and animate.
    private var dashboardDragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { _ in
                // Intentionally empty — no real-time offset tracking to avoid
                // visual glitches. The snap happens entirely in onEnded.
            }
            .onEnded { value in
                guard !nautiDashboardMode.isExpanded else { return }
                guard hasCalculatedRouteDashboard else { return }
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                let translation = value.translation.height
                let velocity = value.predictedEndTranslation.height - value.translation.height

                withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                    if translation < -20 || velocity < -120 {
                        // Drag up → expand to full
                        dashboardDetent = .full
                    } else if translation > 20 || velocity > 120 {
                        // Drag down → collapse to nautiOnly
                        dashboardDetent = .nautiOnly
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
                    .appGlassIconBackground()
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
                .appGlassIconBackground()

            VStack(alignment: .leading, spacing: 2) {
                Text("Abfahrtsfenster")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(mapGlassSecondary)
                if let window = viewModel.passageWindow {
                    Text(window.displayString)
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(window.contains(viewModel.departure) ? mapGlassPrimary : Color.orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text("Empfohlene Abfahrt: \(AppDateFormatters.hourMinute.string(from: window.recommendedDeparture)) Uhr")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(mapGlassSecondary)
                } else {
                    Text(viewModel.isSearchingWindow ? "Wird berechnet…" : (viewModel.passageWindowMessage ?? "Noch nicht berechnet"))
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(mapGlassPrimary.opacity(0.78))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }

            Spacer()
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
                .appGlassIconBackground()
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

    private var mapDashboardWindMetric: some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: "wind")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.appPrimary)
                .frame(width: 25, height: 25)
                .appGlassIconBackground()
            Text("WIND")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(mapGlassSecondary)
            Text(viewModel.routeWindSummaryText ?? (viewModel.weatherStatus == .incomplete ? "Wird geladen…" : "–"))
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(mapGlassPrimary)
                .fixedSize(horizontal: false, vertical: true)
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
                .appGlassIconBackground()

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
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
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
                        .appGlassIconBackground()
                }

                VStack(spacing: 12) {
                    routePickerPill(title: "Start", icon: "sailboat.fill", selection: $viewModel.startHarbourID)
                    intermediateStopsSection
                    routePickerPill(title: "Ziel", icon: "flag.checkered", selection: $viewModel.destinationHarbourID)
                    routeDatePicker
                    routeSpeedControl
                }
            }
        }
    }

    var manualPlanningSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    routeControlPanel
                    planningPassageWindowCard
                    mapWaypointDepthsCard
                }
                .padding(16)
                .padding(.bottom, 28)
            }
            .appSheetBackground {
                Color.appBackground.ignoresSafeArea()
            }
            .navigationTitle("Törn planen")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if !viewModel.hasCompleteRouteInput {
                        Text("Bitte Start und Ziel auswählen.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        // Input changes already calculate live so passage windows
                        // remain visible while planning. Reuse that calculation.
                        if !viewModel.isCalculating, viewModel.calculationResult == nil {
                            if let plan = viewModel.routePlan {
                                viewModel.runCalculation(plan: plan)
                            } else {
                                viewModel.onRouteChanged()
                            }
                        }
                        routeDashboardRevealPending = true
                        mapPlanningShown = false
                    } label: {
                        Label("Törn berechnen", systemImage: "arrow.right.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .appProminentButton(tint: Color.appPrimary)
                    .disabled(!viewModel.hasCompleteRouteInput)
                    .accessibilityIdentifier("CalculateVoyageButton")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.clear)
            }
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



    private var planningPassageWindowCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Abfahrtsfenster", systemImage: "clock.badge.checkmark")
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

                if let window = viewModel.passageWindow ?? viewModel.passageWindows.first {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("MÖGLICHE ABFAHRT")
                                    .font(.system(size: 10, weight: .heavy))
                                    .foregroundStyle(.secondary)
                                Text(window.displayString)
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(Color.primary)
                            }
                            Spacer()
                            if let hw = window.anchoredHighWater {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("HW-REFERENZ")
                                        .font(.system(size: 8, weight: .heavy))
                                        .foregroundStyle(.secondary)
                                    Text("\(AppDateFormatters.hourMinute.string(from: hw)) Uhr")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(Color.appPrimary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.appPrimary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }

                        HStack(spacing: 8) {
                            Image(systemName: "sailboat.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color.appPrimary)
                            Text("Empfohlene Abfahrt:")
                                .font(.subheadline.weight(.medium))
                            Text("\(AppDateFormatters.hourMinute.string(from: window.recommendedDeparture)) Uhr")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Color.appPrimary)
                        }

                        Divider()

                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("GERINGSTER WUK")
                                    .font(.system(size: 9, weight: .heavy))
                                    .foregroundStyle(.secondary)
                                Text(String(format: "%.2f m", window.recommendedClearanceMeters))
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(
                                        window.recommendedClearanceMeters >= viewModel.boatSettings.safetyMarginMeters
                                            ? Color(hex: 0x16A34A) : Color.orange
                                    )
                            }
                            if let name = window.bottleneckName {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("ENGSTELLE")
                                        .font(.system(size: 9, weight: .heavy))
                                        .foregroundStyle(.secondary)
                                    Text(
                                        window.bottleneckArrival.map {
                                            "\(SurveyedDepthCatalog.displayName(for: name)) · \(AppDateFormatters.hourMinute.string(from: $0)) Uhr"
                                        } ?? SurveyedDepthCatalog.displayName(for: name)
                                    )
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Color.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        if let depthDetail = window.bottleneckDepthDetail {
                            Label(depthDetail, systemImage: "ruler")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(14)
                    .background(Color.fieldBackground, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.appPrimary.opacity(0.35), lineWidth: 1.5)
                    )

                    if viewModel.passageWindows.count > 1 {
                        ForEach(Array(viewModel.passageWindows.enumerated()), id: \.offset) { _, alternative in
                            Button {
                                viewModel.selectDepartureWindow(alternative)
                            } label: {
                                HStack {
                                    Text(alternative.displayString)
                                    Spacer()
                                    if alternative == viewModel.passageWindow {
                                        Image(systemName: "checkmark.circle.fill")
                                    }
                                }
                            }
                        }
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
    private var mapWaypointDepthsCard: some View {
        if let result = viewModel.calculationResult, !result.waypointResults.isEmpty {
            let selectedWaypointIDs = Set(viewModel.userWaypointIDs)
            let harbourResults = result.waypointResults.filter { selectedWaypointIDs.contains($0.waypoint.id) }
            card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Engstellen (WuK)", systemImage: "water.waves")
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundStyle(Color.appPrimary)
                        Spacer()
                    }

                    if harbourResults.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                            Text("Für die gewählten Häfen liegen noch keine Tiefenwerte vor.")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(harbourResults) { wpResult in
                                HStack(alignment: .center, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(wpResult.waypoint.name)
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(Color.primary)
                                            .lineLimit(1)
                                        HStack(spacing: 5) {
                                            Text("ETA: \(AppDateFormatters.hourMinute.string(from: wpResult.arrivalTime)) Uhr")
                                            if let depth = wpResult.availableWaterDepthWTMeters {
                                                Text("· Tiefe: \(String(format: "%.2f", depth)) m")
                                            }
                                        }
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.secondary)
                                    }

                                    Spacer()

                                    if let wuk = wpResult.clearanceUnderKeelWuKMeters {
                                        Text(String(format: "%+.2f m WuK", wuk))
                                            .font(.system(size: 12, weight: .heavy))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(
                                                wuk >= viewModel.boatSettings.safetyMarginMeters
                                                    ? Color.green.opacity(0.18)
                                                    : (wuk >= 0 ? Color.orange.opacity(0.18) : Color.red.opacity(0.18)),
                                                in: Capsule()
                                            )
                                            .foregroundStyle(
                                                wuk >= viewModel.boatSettings.safetyMarginMeters
                                                    ? Color.green
                                                    : (wuk >= 0 ? Color.orange : Color.red)
                                            )
                                    }
                                }
                                if wpResult.id != harbourResults.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }
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

    // The compact date picker plus the label is wider than a 402pt phone can
    // fit, which used to wrap "Abfahrt" onto a second line. `fixedSize` keeps
    // the label on one line and the tighter metrics buy back the space it
    // needs.
    private var routeDatePicker: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color(hex: 0x14B8A6), in: Circle())

            Text("Abfahrtstag")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .fixedSize()

            Spacer(minLength: 6)

            CustomCompactDatePicker(selection: $viewModel.planningDay, components: [.date], backgroundColor: .clear)
                .fixedSize()
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background(Color.fieldBackground, in: Capsule(style: .continuous))
    }

    private var routeSpeedControl: some View {
        HStack(spacing: 8) {
            Image(systemName: "speedometer")
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color(hex: 0x0284C7), in: Circle())

            Text("Reisegeschwindigkeit")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .fixedSize()

            Spacer(minLength: 6)

            HStack(spacing: 4) {
                Button {
                    let next = max(1.0, ((viewModel.speedKnots - 0.5) * 10).rounded() / 10)
                    viewModel.speedKnots = next
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Color.appPrimary)
                        .frame(width: 30, height: 30)
                        .background(Color.cardBackground, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Geschwindigkeit verringern")

                Text(String(format: "%.1f kn", viewModel.speedKnots))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .frame(minWidth: 52)
                    .multilineTextAlignment(.center)

                Button {
                    let next = min(30.0, ((viewModel.speedKnots + 0.5) * 10).rounded() / 10)
                    viewModel.speedKnots = next
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Color.appPrimary)
                        .frame(width: 30, height: 30)
                        .background(Color.cardBackground, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Geschwindigkeit erhöhen")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
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
            // `.full` rather than `.summary`: the voyage actions ("Speichern",
            // "Fahrt starten") live in the bottom section, and having to drag
            // the sheet up once more to reach them was a needless step.
            dashboardDetent = .full
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
