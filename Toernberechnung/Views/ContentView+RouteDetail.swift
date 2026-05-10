import SwiftUI

// MARK: - Route Detail View

/// Expandable per-waypoint calculation result display.
/// Shows all tidal calculation fields from the Excel sheet.
struct RouteDetailView: View {
    let result: RouteCalculationResult
    let boatSettings: BoatSettings

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Safety disclaimer
            disclaimerBanner

            // Per-waypoint results
            ForEach(result.waypointResults) { wpResult in
                waypointCard(wpResult)
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

    // MARK: - Waypoint Card

    private func waypointCard(_ wpResult: WaypointCalculationResult) -> some View {
        DisclosureGroup {
            waypointDetails(wpResult)
                .padding(.top, 8)
        } label: {
            waypointHeader(wpResult)
        }
        .tint(Color.appPrimary)
        .padding(14)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(statusBorderColor(wpResult.status).opacity(0.3), lineWidth: 1.5)
        }
    }

    private func waypointHeader(_ wpResult: WaypointCalculationResult) -> some View {
        HStack(spacing: 10) {
            statusBadge(wpResult.status)

            VStack(alignment: .leading, spacing: 3) {
                Text(wpResult.waypoint.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.appPrimary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text("ETA \(Self.timeFormatter.string(from: wpResult.arrivalTime))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.secondary)

                    if let wuK = wpResult.clearanceUnderKeelWuKMeters {
                        Text("WuK \(String(format: "%.2f m", wuK))")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(statusColor(wpResult.status))
                    }
                }
            }

            Spacer()
        }
    }

    private func waypointDetails(_ wpResult: WaypointCalculationResult) -> some View {
        let rows: [(String, String)] = buildDetailRows(wpResult)

        return LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ], spacing: 8) {
            ForEach(rows, id: \.0) { row in
                detailTile(row.0, row.1)
            }
        }
    }

    private func buildDetailRows(_ wp: WaypointCalculationResult) -> [(String, String)] {
        var rows: [(String, String)] = [
            ("Bezugsort (BO)", wp.waypoint.tidalReferenceStation),
            ("ETA", Self.timeFormatter.string(from: wp.arrivalTime))
        ]

        if let hw = wp.relevantHighWaterTime {
            rows.append(("HW", Self.timeFormatter.string(from: hw)))
        }

        if wp.waypoint.highWaterOffsetMinutes != 0 {
            let sign = wp.waypoint.highWaterOffsetMinutes > 0 ? "+" : ""
            rows.append(("HW-Offset", "\(sign)\(wp.waypoint.highWaterOffsetMinutes) min"))
        }

        if let dev = wp.deviationHours {
            rows.append(("Δ HW", String(format: "%.2f h", dev)))
        }

        if let mth = wp.waypoint.meanTidalRangeMeters?.value {
            rows.append(("MTH", String(format: "%.1f m", mth)))
        }

        if let twelfth = wp.oneTwelfthMeters {
            rows.append(("1/12", String(format: "%.4f m", twelfth)))
        }

        if let fmw = wp.missingWaterFmWMeters {
            rows.append(("FmW", fmw == 0 ? "keine Fehlmenge" : String(format: "%.2f m", fmw)))
        }

        switch wp.waypoint.calculationMode {
        case .meanHighWater:
            if let mhw = wp.waypoint.meanHighWaterMeters?.value {
                rows.append(("MHW", String(format: "%.1f m", mhw)))
            }
        case .lottiefe:
            if let lt = wp.waypoint.lottiefeMeters?.value {
                rows.append(("Lottiefe", String(format: "%.1f m", lt)))
            }
        }

        rows.append(("BSH ±m", String(format: "%+.2f m", wp.bshWaterLevelCorrectionMeters)))

        if let cd = wp.chartDepthMetersApplied {
            rows.append(("Kartentiefe", String(format: "%+.1f m", cd)))
        } else if wp.waypoint.calculationMode == .lottiefe {
            rows.append(("Kartentiefe", "– (Lottiefe)"))
        }

        if let hg = wp.tideHeightHGMeters {
            rows.append(("HG", String(format: "%.2f m", hg)))
        } else if wp.waypoint.calculationMode == .lottiefe {
            rows.append(("HG", "leer (Lottiefe)"))
        }

        if let wt = wp.availableWaterDepthWTMeters {
            rows.append(("WT", String(format: "%.2f m", wt)))
        }

        rows.append(("Tiefgang", String(format: "%.2f m", wp.boatDraftMeters)))

        if let wuK = wp.clearanceUnderKeelWuKMeters {
            rows.append(("WuK", String(format: "%.2f m", wuK)))
        }

        rows.append(("Modus", wp.waypoint.calculationMode.displayName))

        if !wp.messages.isEmpty {
            rows.append(("Hinweise", wp.messages.joined(separator: "; ")))
        }

        return rows
    }

    // MARK: - UI Helpers

    private func statusBadge(_ status: WaypointStatus) -> some View {
        Image(systemName: statusIcon(status))
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(statusColor(status))
            .frame(width: 32, height: 32)
            .background(statusColor(status).opacity(0.12))
            .clipShape(Circle())
    }

    private func detailTile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.appPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(8)
        .background(Color.fieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

}

// MARK: - Status Styling Helpers

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
