import SwiftUI

// MARK: - Route Detail View
//
// Leg-based summary used by the Map tab. Only user-selected harbours are
// shown; internal Dijkstra fairway WPs (`watt_dornum`, `juist_south_e`, …)
// are intentionally hidden — they contribute their depth to the leg they
// belong to, but they are not surfaced individually.
//
// Each row covers ONE leg between two consecutive user harbours and
// reports:
//   - ETA at the leg's destination harbour
//   - the worst Under-Keel Clearance (WuK) observed along the leg
//   - status indicator (.go / .warning / .noGo / .incomplete)
//   - a localized failure reason when the leg is not passable.

struct RouteDetailView: View {
    let summary: RouteSummary?
    let boatSettings: BoatSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            disclaimerBanner

            if let summary {
                if let failure = summary.failureMessage {
                    failureBanner(failure)
                }
                ForEach(summary.legs) { leg in
                    legCard(leg)
                }
            } else {
                placeholderRow
            }
        }
    }

    // MARK: - Disclaimer

    private var disclaimerBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.orange)
            Text("Diese Berechnung ist nur eine Planungshilfe und ersetzt keine amtlichen nautischen Veröffentlichungen, aktuellen Bekanntmachungen, Revierinformationen, Wetterbeurteilung oder die Verantwortung der Schiffsführung.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.secondary)
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
        }
    }

    // MARK: - Failure Banner

    private func failureBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.red)
            Text(text)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.red)
                .lineLimit(3)
            Spacer()
        }
        .padding(12)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.red.opacity(0.35), lineWidth: 1)
        }
    }

    // MARK: - Leg Card

    private func legCard(_ leg: RouteSummary.Leg) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                statusBadge(leg.status)

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(leg.fromName)  →  \(leg.toName)")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.appPrimary)
                        .lineLimit(2)
                    Text("Abfahrt \(AppDateFormatters.hourMinute.string(from: leg.departureTime))   ·   Ankunft \(AppDateFormatters.hourMinute.string(from: leg.arrivalTime))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }

                Spacer()
            }

            HStack(spacing: 8) {
                metric("DISTANZ", String(format: "%.1f sm", leg.distanceNm))
                metric("DAUER", AppDateFormatters.duration(hours: leg.travelTimeHours))
                if let wuK = leg.worstWuKMeters {
                    metric("WuK", String(format: "%.2f m", wuK),
                           tint: statusColor(leg.status))
                } else {
                    metric("WuK", "–")
                }
            }

            if let reason = leg.failureReason {
                Text(reason)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(statusColor(leg.status))
                    .padding(.top, 2)
            }
            if let bottleneck = leg.bottleneckName, leg.status != .go {
                Text("Engstelle: \(bottleneck)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(14)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(statusBorderColor(leg.status).opacity(0.3), lineWidth: 1.5)
        }
    }

    // MARK: - Placeholder

    private var placeholderRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "hourglass")
                .foregroundStyle(Color.secondary)
            Text("Berechnung läuft…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.secondary)
            Spacer()
        }
        .padding(12)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Tiles

    private func metric(_ title: String, _ value: String, tint: Color = .appPrimary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.secondary)
            Text(value)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(tint)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.fieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func statusBadge(_ status: WaypointStatus) -> some View {
        Image(systemName: statusIcon(status))
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(statusColor(status))
            .frame(width: 32, height: 32)
            .background(statusColor(status).opacity(0.12))
            .clipShape(Circle())
    }
}

// MARK: - Status Styling Helpers (shared by the Map tab UI)

func statusColor(_ status: WaypointStatus) -> Color {
    switch status {
    case .go: return .green
    case .warning: return .orange
    case .noGo: return .red
    case .incomplete: return .gray
    case .invalid: return .red
    }
}

func statusIcon(_ status: WaypointStatus) -> String {
    switch status {
    case .go: return "checkmark.circle.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .noGo: return "xmark.circle.fill"
    case .incomplete: return "questionmark.circle.fill"
    case .invalid: return "exclamationmark.octagon.fill"
    }
}

func statusBorderColor(_ status: WaypointStatus) -> Color {
    switch status {
    case .go: return .green
    case .warning: return .orange
    case .noGo: return .red
    case .incomplete: return .gray
    case .invalid: return .red
    }
}

func combinedStatusColor(_ status: CombinedRouteStatus) -> Color {
    switch status {
    case .go: return .green
    case .warning: return .orange
    case .noGo: return .red
    case .incomplete: return .gray
    }
}
