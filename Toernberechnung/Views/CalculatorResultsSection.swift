import SwiftUI

// MARK: - Calculator Results Section
//
// Extracted from `ContentView.calculatorTab()` so SwiftUI evaluates
// a shallower generic type tree per `body`. The original monolithic
// body produced such a deeply nested type that the runtime stack
// overflowed during layout — manifesting as:
//   Thread 1: EXC_BAD_ACCESS (code=2, address=0x16d3b3670)
//
// By giving this section its own `View.body`, each SwiftUI body
// evaluation gets its own manageable stack frame.

struct CalculatorResultsSection: View {
    let viewModel: RoutePlannerViewModel
    let voyageManager: ActiveVoyageManager
    let locationService: LocationService
    let navigationTracker: NavigationTracker
    let dieselLiters: Double
    let saveAction: () -> Void
    @Binding var stopVoyageAlertShown: Bool
    @Binding var voyageDisclaimerShown: Bool
    @Binding var navigationFullScreenShown: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            routeStatusBanner
            passageWindowCard

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                metricCard("REISEZEIT", icon: "hourglass", text: viewModel.totalTravelTimeText, caption: "Dauer")
                metricCard("ANKUNFT", icon: "flag.checkered", text: viewModel.arrivalTimeText, caption: "Uhr")
                metricCard("DISTANZ", icon: "ruler", text: viewModel.totalDistanceText, caption: "NM")
                metricCard("WuK", icon: "water.waves", text: viewModel.worstWuKText, caption: viewModel.statusText)
                metricCard("DIESEL", icon: "fuelpump.fill", text: String(format: "%.1f l", dieselLiters), caption: "Richtwert")
            }

            // Leg-based route summary (only user-selected harbours).
            RouteDetailView(
                summary: viewModel.routeSummary,
                boatSettings: viewModel.boatSettings
            )

            voyageActionButtons
        }
    }

    // MARK: - Route Status Banner

    private var routeStatusBanner: some View {
        let status = viewModel.combinedStatus ?? .incomplete
        let weatherProgress: RouteWeatherProgress? = {
            guard case .loading(let completed, let total) = viewModel.routeWeatherValidationState else {
                return nil
            }
            return RouteWeatherProgress(completed: completed, total: total)
        }()
        let accent = combinedStatusColor(status)
        let icon = status == .go ? "checkmark.circle.fill"
            : status == .warning ? "exclamationmark.triangle.fill"
            : status == .noGo ? "xmark.circle.fill"
            : "questionmark.circle.fill"

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if viewModel.isCalculating || weatherProgress != nil {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 28, weight: .bold))
                }
                Text(viewModel.statusText)
                    .font(.system(size: 28, weight: .bold))
            }

            if let weatherProgress, weatherProgress.total > 0 {
                ProgressView(
                    value: Double(weatherProgress.completed),
                    total: Double(weatherProgress.total)
                )
                .tint(.white)
                Text("Alle Seegebiete werden geprüft. Bis zum Abschluss wird kein Sicherheitsstatus angezeigt.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
            } else if case .unavailable(let message) = viewModel.routeWeatherValidationState {
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
            }

            if let error = viewModel.calculationError {
                Text(error)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(3)
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appMarineDashboardGlass(cornerRadius: 30, tint: accent)
    }

    // MARK: - Passage Window Card

    private var passageWindowCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SICHERES ABFAHRTSFENSTER")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                if viewModel.isSearchingWindow {
                    ProgressView()
                } else {
                    Button {
                        viewModel.refreshPassageWindow()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
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
                        .foregroundStyle(.white)
                }

                if window.contains(viewModel.departure) {
                    Text("Die aktuelle Abfahrt liegt innerhalb des sicheren Fensters.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
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
                        .foregroundStyle(.white.opacity(0.78))
                }
            }
        }
        .padding(16)
        .appMarineDashboardGlass(cornerRadius: 28, tint: Color(hex: 0x075985))
    }

    // MARK: - Metric Card

    private func metricCard(_ title: String, icon: String, text: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: 0x7DD3FC))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.12), in: Circle())
                Spacer(minLength: 0)
            }
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.70))
            Text(text)
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text(caption)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.70))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .appMarineDashboardGlass(cornerRadius: 28, tint: Color(hex: 0x0A4C70))
    }

    // MARK: - Voyage Action Buttons

    @ViewBuilder
    private var voyageActionButtons: some View {
        if voyageManager.isVoyageActive {
            activeVoyageDashboard
            VStack(spacing: 10) {
                Button {
                    navigationFullScreenShown = true
                } label: {
                    Label("Zur Navigation", systemImage: "location.fill")
                }
                .appProminentButton(tint: Color(hex: 0x14B8A6))

                Button {
                    stopVoyageAlertShown = true
                } label: {
                    Label("Fahrt beenden & Logbuch speichern", systemImage: "stop.circle.fill")
                }
                .appProminentButton(tint: .red)
            }
        } else {
            // Stacked vertically so each prominent CTA gets the full row
            // width — side by side, "Berechnen und speichern" was too long
            // for half the row and truncated ("Berechnen und speic…").
            VStack(spacing: 10) {
                Button {
                    saveAction()
                } label: {
                    Label("Berechnen und speichern", systemImage: "square.and.arrow.down")
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                .appProminentButton(tint: .appPrimary)

                Button {
                    voyageDisclaimerShown = true
                } label: {
                    Label("Fahrt starten", systemImage: "location.fill.viewfinder")
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                .appProminentButton(tint: Color(hex: 0x14B8A6))
            }
        }
    }

    // MARK: - Active Voyage Dashboard

    @ViewBuilder
    private var activeVoyageDashboard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.green)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("AKTIVE FAHRT")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.secondary)
                    Text(voyageManager.activeRoute?.routeName ?? "")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.appPrimary)
                        .lineLimit(2)
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.formatHMS(
                        Date().timeIntervalSince(voyageManager.voyageStartTime ?? context.date)
                    ))
                    .font(.system(size: 17, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Color.appPrimary)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                dashboardTile(
                    title: "SOG",
                    value: String(format: "%.1f kn", locationService.speedKnots)
                )
                dashboardTile(
                    title: "COG",
                    value: locationService.courseDegrees.map { String(format: "%03.0f°", $0) } ?? "–"
                )
                dashboardTile(
                    title: "DTW",
                    value: navigationTracker.distanceToWaypointNm
                        .map { String(format: "%.2f sm", $0) } ?? "–"
                )
                dashboardTile(
                    title: "NÄCHSTER WP",
                    value: navigationTracker.activeWaypointName ?? "–"
                )
                dashboardTile(
                    title: "ETA",
                    value: navigationTracker.dynamicETA
                        .map(AppDateFormatters.hourMinute.string(from:)) ?? "–"
                )
                dashboardTile(
                    title: "STRECKE",
                    value: String(format: "%.2f sm", voyageManager.totalDistanceNm)
                )
            }

            if navigationTracker.isOffCourse, let xte = navigationTracker.crossTrackErrorMeters {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.white)
                    Text("Off Course – \(Int(xte)) m abseits der Route")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(16)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.green.opacity(0.35), lineWidth: 1.5)
        }
    }

    private func dashboardTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.secondary)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.appPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.fieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private static func formatHMS(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
