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
    @State private var appeared = false
    let onStopVoyage: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            CompactMapView(
                start: start,
                destination: destination,
                routePlan: routePlan,
                waypointResults: waypointResults,
                voyageActive: true,
                breadcrumbCoordinates: voyageManager.breadcrumbs.map(\.coordinate)
            )
            .ignoresSafeArea()

            LinearGradient(
                colors: [
                    .black.opacity(0.30),
                    .clear,
                    .black.opacity(0.36)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

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
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.965)
        .onAppear {
            withAnimation(.spring(response: 0.46, dampingFraction: 0.88)) {
                appeared = true
            }
        }
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
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .appCircularGlass(diameter: 40)
            .accessibilityLabel("Vollbild minimieren")

            VStack(alignment: .leading, spacing: 1) {
                Text("NAVIGATION")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.68))
                Text(voyageManager.activeRoute?.routeName ?? "")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appMarineDashboardGlass(cornerRadius: 16, tint: Color(hex: 0x1F2937))

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.formatHMS(
                    Date().timeIntervalSince(voyageManager.voyageStartTime ?? context.date)
                ))
                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .appMarineDashboardGlass(cornerRadius: 16, tint: Color(hex: 0x1F2937))
            }
        }
    }

    // MARK: - Bottom Dashboard
    //
    // Outer panel = Liquid Glass (the floating overlay). Inner tiles stay
    // on Color.fieldBackground because they sit INSIDE the glass panel
    // and glass-on-glass is forbidden.
    private var bottomDashboard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Capsule()
                .fill(Color.white.opacity(0.32))
                .frame(width: 44, height: 5)
                .frame(maxWidth: .infinity)

            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color(hex: 0x14B8A6).opacity(0.20))
                    Image(systemName: "location.north.line.fill")
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundStyle(Color(hex: 0x14B8A6))
                }
                .frame(width: 50, height: 50)

                VStack(alignment: .leading, spacing: 3) {
                    Text(navigationTracker.activeWaypointName ?? "Route folgen")
                        .font(.system(size: 23, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(routeInstructionText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.70))
                        .lineLimit(1)
                }
                Spacer()
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

            HStack(spacing: 10) {
                tile("SOG", String(format: "%.1f kn", locationService.speedKnots), icon: "speedometer")
                tile("DTW", navigationTracker.distanceToWaypointNm.map { String(format: "%.2f nm", $0) } ?? "–", icon: "ruler")
                tile("ETA", navigationTracker.dynamicETA.map(AppDateFormatters.hourMinute.string(from:)) ?? "–", icon: "clock.fill")
            }

            HStack(spacing: 10) {
                compactInfo("Kurs", locationService.courseDegrees.map { String(format: "%03.0f°", $0) } ?? "–")
                compactInfo("Gefahren", String(format: "%.2f nm", voyageManager.totalDistanceNm))
            }

            Button {
                stopAlertShown = true
            } label: {
                Label("Fahrt beenden", systemImage: "stop.circle.fill")
            }
            .appProminentButton(tint: .red)
        }
        .padding(16)
        .appMarineDashboardGlass(cornerRadius: 30, tint: Color(hex: 0x111827))
    }

    private var routeInstructionText: String {
        if let distance = navigationTracker.distanceToWaypointNm {
            return String(format: "%.2f nm bis zum nächsten Wegpunkt", distance)
        }
        return "Geplante Route ist auf der Karte eingeblendet"
    }

    private func tile(_ title: String, _ value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hex: 0x93C5FD))
            Text(title.uppercased())
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.white.opacity(0.55))
            Text(value)
                .font(.system(size: 16, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private func compactInfo(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white.opacity(0.54))
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.08), in: Capsule())
    }

    private static func formatHMS(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
