import SwiftUI
import CoreLocation

// MARK: - FullScreenNavigationView
//
// Edge-to-edge nautical chart with a heading-up follow-me trace, presented
// as a `fullScreenCover` while an `ActiveVoyageManager` voyage is recording.
//
// Two ways to exit:
//   • "Minimieren" (chevron) closes the cover but the voyage keeps running
//     in the background — the user goes back to the planner with the live
//     dashboard there.
//   • "Fahrt beenden" stops the voyage and writes the logbook entry; the
//     cover dismisses itself when `voyageManager.isVoyageActive` flips.

struct FullScreenNavigationView: View {

    let start: HarbourOption
    let destination: HarbourOption
    let routePlan: RoutePlan?
    let waypointResults: [WaypointCalculationResult]?

    @Environment(LocationService.self) private var locationService
    @Environment(NavigationTracker.self) private var navigationTracker
    @Environment(ActiveVoyageManager.self) private var voyageManager
    @Environment(\.dismiss) private var dismiss

    @State private var stopAlertShown = false
    let onStopVoyage: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            CompactMapView(
                zoomLevel: 14,
                start: start,
                destination: destination,
                routePlan: routePlan,
                waypointResults: waypointResults,
                voyageActive: true,
                breadcrumbCoordinates: voyageManager.breadcrumbs.map(\.coordinate)
            )
            .ignoresSafeArea()

            topBar
                .padding(.horizontal, 14)
                .padding(.top, 8)

            VStack {
                Spacer()
                bottomDashboard
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
        }
        .background(Color.black)
        .alert("Aktive Fahrt beenden?", isPresented: $stopAlertShown) {
            Button("Fahrt beenden", role: .destructive) {
                onStopVoyage()
            }
            Button("Weiter aufzeichnen", role: .cancel) { }
        } message: {
            Text("Die aufgezeichnete Strecke wird ins Logbuch übernommen und das GPS-Tracking gestoppt.")
        }
        .onChange(of: voyageManager.isVoyageActive) { _, active in
            if !active { dismiss() }
        }
    }

    // MARK: - Top Bar
    //
    // Three pills that float over the map. We wrap them in a
    // GlassEffectContainer so the iOS 26 morphing animation treats them
    // as one group (Apple HIG: "group multiple glass elements within a
    // GlassEffectContainer to ensure consistent visual results").
    @ViewBuilder
    private var topBar: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 10) {
                topBarContent
            }
        } else {
            topBarContent
        }
    }

    private var topBarContent: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)
                    .appCircularGlass(diameter: 40)
            }
            .accessibilityLabel("Vollbild minimieren")

            VStack(alignment: .leading, spacing: 1) {
                Text("AKTIVE FAHRT")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(voyageManager.activeRoute?.routeName ?? "")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appFloatingOverlay(cornerRadius: 14)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.formatHMS(
                    Date().timeIntervalSince(voyageManager.voyageStartTime ?? context.date)
                ))
                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .appFloatingOverlay(cornerRadius: 14)
            }
        }
    }

    // MARK: - Bottom Dashboard
    //
    // Outer panel = Liquid Glass (the floating overlay). Inner tiles stay
    // on Color.fieldBackground because they sit INSIDE the glass panel
    // and glass-on-glass is forbidden.
    private var bottomDashboard: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                tile("SOG", String(format: "%.1f kn", locationService.speedKnots))
                tile("COG", locationService.courseDegrees.map { String(format: "%03.0f°", $0) } ?? "–")
                tile("DTW", navigationTracker.distanceToWaypointNm.map { String(format: "%.2f sm", $0) } ?? "–")
                tile("NÄCHSTER WP", navigationTracker.activeWaypointName ?? "–")
                tile("ETA", navigationTracker.dynamicETA.map(AppDateFormatters.hourMinute.string(from:)) ?? "–")
                tile("STRECKE", String(format: "%.2f sm", voyageManager.totalDistanceNm))
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
                .background(Color.orange, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Button {
                stopAlertShown = true
            } label: {
                Label("Fahrt beenden", systemImage: "stop.circle.fill")
            }
            .appProminentButton(tint: .red)
        }
        .padding(12)
        .appFloatingOverlay(cornerRadius: 20)
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.fieldBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private static func formatHMS(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
