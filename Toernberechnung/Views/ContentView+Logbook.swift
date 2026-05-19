import SwiftUI
import UIKit

// MARK: - Logbuch-Tab: Verlauf gespeicherter Berechnungen und PDF-Export

extension ContentView {
    func logbookTab() -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if calculations.isEmpty {
                placeholderCard(icon: "book.closed.fill", title: "Noch kein Logbuch-Eintrag", text: "Sobald eine Berechnung gespeichert wird, erscheint hier ein kompakter Törn.")
            } else {
                ForEach(calculations, id: \.createdAt) { record in
                    SwipeDeleteRow(deleteAction: { deleteCalculation(record) }) {
                        logbookGlassCard {
                            logbookCard(record)
                        }
                    }
                }
            }
        }
    }

    func logbookCard(_ record: CalculationRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color(hex: 0x3C82FF).opacity(0.14))
                    Image(systemName: "book.pages.fill")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(Color(hex: 0x3C82FF))
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 5) {
                    Text(logbookTitle(for: record))
                        .font(.system(size: 21, weight: .heavy))
                        .foregroundStyle(Color.appPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                    Text("\(record.startName) → \(record.destinationName)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }

                Spacer()
            }

            HStack(spacing: 8) {
                logbookMetricChip(String(format: "%.1f nm", record.distanceNM), icon: "ruler")
                logbookMetricChip(durationText(record.arrivalAt.timeIntervalSince(record.departureAt) / 3600), icon: "clock")
                logbookMetricChip(record.status, icon: record.status.localizedCaseInsensitiveContains("nicht") ? "xmark.circle.fill" : "checkmark.circle.fill")
            }

            DisclosureGroup {
                logbookReadOnlyDetails(record)
                .padding(.top, 12)
            } label: {
                Label("Logbuchdaten anzeigen", systemImage: "doc.text.magnifyingglass")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.appPrimary)
            }
            .tint(Color.appPrimary)

            Button {
                exportCalculation(record)
            } label: {
                Label("PDF erstellen", systemImage: "doc.richtext")
                    .font(.system(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(.vertical, 13)
            .background(
                LinearGradient(
                    colors: [Color.appPrimary, Color(hex: 0x3C82FF)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: Color(hex: 0x3C82FF).opacity(0.22), radius: 14, y: 8)
        }
    }

    func logbookGlassCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

        return content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: shape)
            .overlay { shape.stroke(.white.opacity(0.68), lineWidth: 1) }
            .shadow(color: Color.appPrimary.opacity(0.08), radius: 18, y: 10)
    }

    func logbookMetricChip(_ value: String, icon: String) -> some View {
        Label(value, systemImage: icon)
            .font(.system(size: 12, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .foregroundStyle(Color.appPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.fieldBackground.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(hex: 0x3C82FF).opacity(0.14), lineWidth: 1)
            }
    }

    func logbookReadOnlyDetails(_ record: CalculationRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: compactColumns, spacing: 10) {
                logbookInfoTile("Abfahrt", Self.displayDateTimeFormatter.string(from: record.departureAt))
                logbookInfoTile("Ankunft", Self.displayDateTimeFormatter.string(from: record.arrivalAt))
                logbookInfoTile("Distanz", String(format: "%.1f nm", record.distanceNM))
                logbookInfoTile("WT", String(format: "%.2f m", record.wt))
                logbookInfoTile("UKC", String(format: "%.2f m", record.wuk))
                logbookInfoTile("FMW", String(format: "%.2f m", record.fmw))
            }

            logbookInfoBlock("Wetter", record.weatherSummary.isEmpty ? "Kein Wetter-Snapshot gespeichert" : record.weatherSummary)
            logbookInfoBlock("Gezeiten", record.tideSummary.isEmpty ? "Kein BSH-Snapshot gespeichert" : record.tideSummary)
            logbookInfoBlock("Crew", record.crewSummary.isEmpty ? "Keine Crew erfasst" : record.crewSummary)
            if !record.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logbookInfoBlock("Notizen / Ereignisse", record.notes)
            }
        }
    }

    func logbookInfoTile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.appPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .padding(10)
        .background(Color.fieldBackground.opacity(0.78), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(hex: 0x3C82FF).opacity(0.12), lineWidth: 1)
        }
    }

    func logbookInfoBlock(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.secondary)
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.appPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.fieldBackground.opacity(0.78), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(hex: 0x3C82FF).opacity(0.12), lineWidth: 1)
        }
    }

    func logbookTitle(for record: CalculationRecord) -> String {
        "Törn · \(Self.dateFormatter.string(from: record.createdAt)) · \(Self.timeFormatter.string(from: record.createdAt))"
    }

    @MainActor
    func deleteCalculation(_ record: CalculationRecord) {
        let routeTitle = record.routeTitle
        modelContext.delete(record)
        writeAudit(action: "DELETE", source: "logbook", statement: "DELETE FROM calculations WHERE route_title = '\(routeTitle)'", status: "ok")
        try? modelContext.save()
    }

    @MainActor
    func exportCalculation(_ record: CalculationRecord) {
        do {
            exportedPDFURL = try ToernPDFExporter.export(record: record)
            shareSheetPresented = true
            writeAudit(action: "EXPORT", source: "logbook", statement: "EXPORT PDF route='\(record.routeTitle)'", status: "ok")
        } catch {
            writeAudit(action: "EXPORT", source: "logbook", statement: "EXPORT PDF route='\(record.routeTitle)'", status: "error")
        }
    }

    private static let displayDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()
}

enum ToernPDFExporter {
    static func export(record: CalculationRecord) throws -> URL {
        let fileName = "Toern-\(Self.slug(Self.routeText(record)))-\(Self.fileDate.string(from: record.createdAt)).pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: page)

        try renderer.writePDF(to: url) { context in
            context.beginPage()
            guard let cg = UIGraphicsGetCurrentContext() else { return }

            drawLogbookPage(record: record, page: page, cg: cg)
        }

        return url
    }

    private static func drawLogbookPage(record: CalculationRecord, page: CGRect, cg: CGContext) {
        let margin: CGFloat = 36
        let width = page.width - margin * 2
        let blue = UIColor.appPrimary
        let line = UIColor(hex: 0xB9C1CE)
        let light = UIColor(hex: 0xF6F8FC)
        var y: CGFloat = 34

        draw("Schiffstagebuch (Törnverlauf)", at: CGPoint(x: margin, y: y), font: .italicSystemFont(ofSize: 24), color: .black)
        draw("Datum: \(displayDate.string(from: record.createdAt))", at: CGPoint(x: page.width - margin - 128, y: y + 8), font: .boldSystemFont(ofSize: 12), color: .black)
        y += 42

        let fieldH: CGFloat = 34
        drawCell("Törn von/nach:", value: routeText(record), rect: CGRect(x: margin, y: y, width: width * 0.62, height: fieldH), line: line, fill: light)
        drawCell("Startzeit:", value: displayTime.string(from: record.departureAt), rect: CGRect(x: margin + width * 0.62, y: y, width: width * 0.19, height: fieldH), line: line, fill: .white)
        drawCell("Ankunft:", value: displayTime.string(from: record.arrivalAt), rect: CGRect(x: margin + width * 0.81, y: y, width: width * 0.19, height: fieldH), line: line, fill: .white)
        y += fieldH

        drawCell("Schiffsführer:", value: skipperName(from: record.crewSummary), rect: CGRect(x: margin, y: y, width: width * 0.38, height: fieldH), line: line, fill: .white)
        drawCell("Crew:", value: emptyFallback(record.crewSummary, "Keine Crew erfasst"), rect: CGRect(x: margin + width * 0.38, y: y, width: width * 0.42, height: fieldH), line: line, fill: .white)
        drawCell("Zeitzone:", value: "UTC + 1 Std.", rect: CGRect(x: margin + width * 0.80, y: y, width: width * 0.20, height: fieldH), line: line, fill: .white)
        y += fieldH

        drawCell("Wetter / Wind:", value: emptyFallback(record.weatherSummary, "-"), rect: CGRect(x: margin, y: y, width: width * 0.38, height: 48), line: line, fill: .white)
        drawCell("Gezeiten:", value: emptyFallback(record.tideSummary, "-"), rect: CGRect(x: margin + width * 0.38, y: y, width: width * 0.42, height: 48), line: line, fill: .white)
        drawCell("Betriebsstd.:", value: "bei Abfahrt:", rect: CGRect(x: margin + width * 0.80, y: y, width: width * 0.20, height: 48), line: line, fill: .white)
        y += 48

        drawCell("Wasserst.-Vorhers. (+/- m)", value: "", rect: CGRect(x: margin, y: y, width: width * 0.26, height: 36), line: line, fill: .white)
        drawCell("Tiefgang d. Bootes (m)", value: "", rect: CGRect(x: margin + width * 0.26, y: y, width: width * 0.24, height: 36), line: line, fill: .white)
        drawCell("Wassertiefe WT", value: String(format: "%.2f m", record.wt), rect: CGRect(x: margin + width * 0.50, y: y, width: width * 0.25, height: 36), line: line, fill: .white)
        drawCell("UKC", value: String(format: "%.2f m", record.wuk), rect: CGRect(x: margin + width * 0.75, y: y, width: width * 0.25, height: 36), line: line, fill: .white)
        y += 50

        drawSectionTitle("Checkliste vor Abfahrt", at: CGPoint(x: margin, y: y), color: blue)
        y += 24
        drawChecklist(origin: CGPoint(x: margin, y: y), width: width, line: line)
        y += 148

        drawSectionTitle("Törnverlauf", at: CGPoint(x: margin + width * 0.40, y: y - 2), color: blue)
        draw("Distanz: \(String(format: "%.1f nm", record.distanceNM))", at: CGPoint(x: margin, y: y + 2), font: .boldSystemFont(ofSize: 12), color: .black)
        draw("Status: \(record.status)", at: CGPoint(x: margin + width * 0.74, y: y + 2), font: .boldSystemFont(ofSize: 12), color: .black)
        y += 24
        drawRouteTable(record: record, origin: CGPoint(x: margin, y: y), width: width, line: line)
        y += 190

        drawSectionTitle("Ereignisse / Notizen", at: CGPoint(x: margin, y: y), color: blue)
        y += 22
        let notesRect = CGRect(x: margin, y: y, width: width, height: 130)
        stroke(notesRect, color: line, cg: cg)
        drawRuledLines(in: notesRect, every: 26, color: line, cg: cg)
        drawMultiline(emptyFallback(record.notes, ""), rect: notesRect.insetBy(dx: 10, dy: 9), font: .italicSystemFont(ofSize: 13), color: .darkGray)
        y += 146

        drawSignatureLine(label: "Datum", rect: CGRect(x: margin + width * 0.12, y: y + 48, width: width * 0.24, height: 24), line: line, cg: cg)
        drawSignatureLine(label: "Unterschrift Schiffsführer", rect: CGRect(x: margin + width * 0.50, y: y + 48, width: width * 0.38, height: 24), line: line, cg: cg)
    }

    private static func drawChecklist(origin: CGPoint, width: CGFloat, line: UIColor) {
        let columns = [
            ["Einweisung der Crew", "Sicherheitsmittel", "Revierkunde", "Lagemeldung", "UKW-Funkgerät", "Handy geladen?"],
            ["Kraftstoff", "Ölstand", "Seeventil", "Beleuchtung", "Signalhorn", "Scheibenwischer"],
            ["Ankerfunktion", "Leinen klar", "Navigation geprüft", "Wetter geprüft", "Crew an Bord", "Logbuch bereit"]
        ]
        let colW = width / 3
        let rowH: CGFloat = 20

        for (columnIndex, items) in columns.enumerated() {
            let x = origin.x + CGFloat(columnIndex) * colW
            for (rowIndex, item) in items.enumerated() {
                let rect = CGRect(x: x, y: origin.y + CGFloat(rowIndex) * rowH, width: colW, height: rowH)
                stroke(rect, color: line)
                drawCheckbox(at: CGPoint(x: rect.minX + 8, y: rect.minY + 5))
                draw(item, at: CGPoint(x: rect.minX + 28, y: rect.minY + 4), font: .systemFont(ofSize: 10), color: .black)
            }
        }
    }

    private static func drawRouteTable(record: CalculationRecord, origin: CGPoint, width: CGFloat, line: UIColor) {
        let headers = ["Wegpunkte (WP)", "Nr.", "WuK", "UKW", "Entf. nm", "Kurs", "Geschw. kn", "Uhrz. am WP", "Fahrzeit"]
        let ratios: [CGFloat] = [0.26, 0.06, 0.07, 0.07, 0.10, 0.10, 0.13, 0.12, 0.09]
        let headerH: CGFloat = 30
        let rowH: CGFloat = 30
        var x = origin.x

        for (index, header) in headers.enumerated() {
            let colW = width * ratios[index]
            drawCell(header, value: "", rect: CGRect(x: x, y: origin.y, width: colW, height: headerH), line: line, fill: UIColor(hex: 0xF6F8FC), valueFont: .boldSystemFont(ofSize: 9))
            x += colW
        }

        let rows: [[String]] = [
            [record.startName, "1", String(format: "%.2f", record.wuk), "", "", "", "", displayTime.string(from: record.departureAt), ""],
            [record.destinationName, "2", "", "", String(format: "%.1f", record.distanceNM), "", "", displayTime.string(from: record.arrivalAt), travelDuration(record)],
            ["nach", "3", "", "", "", "", "", "", ""],
            ["nach", "4", "", "", "", "", "", "", ""],
            ["Gesamt (kumuliert)", "", "", "", String(format: "%.1f", record.distanceNM), "", "", "", travelDuration(record)]
        ]

        for (rowIndex, row) in rows.enumerated() {
            x = origin.x
            for (columnIndex, value) in row.enumerated() {
                let colW = width * ratios[columnIndex]
                drawCell("", value: value, rect: CGRect(x: x, y: origin.y + headerH + CGFloat(rowIndex) * rowH, width: colW, height: rowH), line: line, fill: .white, valueFont: .systemFont(ofSize: 9))
                x += colW
            }
        }
    }

    private static func drawCell(_ title: String, value: String, rect: CGRect, line: UIColor, fill: UIColor, valueFont: UIFont = .systemFont(ofSize: 11)) {
        fill.setFill()
        UIRectFill(rect)
        stroke(rect, color: line)
        if !title.isEmpty {
            draw(title, at: CGPoint(x: rect.minX + 6, y: rect.minY + 5), font: .boldSystemFont(ofSize: 9), color: .black)
        }
        if !value.isEmpty {
            let y = title.isEmpty ? rect.minY + 8 : rect.minY + 18
            drawMultiline(value, rect: CGRect(x: rect.minX + 6, y: y, width: rect.width - 12, height: rect.height - (y - rect.minY) - 2), font: valueFont, color: .darkGray)
        }
    }

    private static func drawSignatureLine(label: String, rect: CGRect, line: UIColor, cg: CGContext) {
        cg.setStrokeColor(line.cgColor)
        cg.setLineWidth(1)
        cg.move(to: CGPoint(x: rect.minX, y: rect.minY))
        cg.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        cg.strokePath()
        draw("(\(label))", at: CGPoint(x: rect.minX + 8, y: rect.minY + 8), font: .systemFont(ofSize: 10), color: .darkGray)
    }

    private static func drawRuledLines(in rect: CGRect, every spacing: CGFloat, color: UIColor, cg: CGContext) {
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(0.6)
        var y = rect.minY + spacing
        while y < rect.maxY {
            cg.move(to: CGPoint(x: rect.minX, y: y))
            cg.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += spacing
        }
        cg.strokePath()
    }

    private static func drawCheckbox(at point: CGPoint) {
        let rect = CGRect(x: point.x, y: point.y, width: 10, height: 10)
        UIColor(hex: 0xB9C1CE).setStroke()
        UIRectFrame(rect)
    }

    private static func drawSectionTitle(_ title: String, at point: CGPoint, color: UIColor) {
        draw(title, at: point, font: .boldSystemFont(ofSize: 16), color: color)
    }

    private static func stroke(_ rect: CGRect, color: UIColor, cg: CGContext? = UIGraphicsGetCurrentContext()) {
        guard let cg else { return }
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(0.8)
        cg.stroke(rect)
    }

    private static func draw(_ text: String, at point: CGPoint, font: UIFont, color: UIColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        text.draw(at: point, withAttributes: attributes)
    }

    @discardableResult
    private static func drawMultiline(_ text: String, rect: CGRect, font: UIFont, color: UIColor) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let bounding = text.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
        return ceil(bounding.height)
    }

    private static func routeText(_ record: CalculationRecord) -> String {
        "\(record.startName) → \(record.destinationName)"
    }

    private static func emptyFallback(_ value: String, _ fallback: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : value
    }

    private static func skipperName(from crew: String) -> String {
        crew.split(separator: ",").first { $0.contains("(Skipper)") }
            .map { String($0).components(separatedBy: " (").first ?? "" } ?? ""
    }

    private static func travelDuration(_ record: CalculationRecord) -> String {
        let minutes = max(Int(record.arrivalAt.timeIntervalSince(record.departureAt) / 60), 0)
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private static func slug(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return value.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
            .replacingOccurrences(of: "--", with: "-")
    }

    private static let fileDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter
    }()

    private static let displayDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter
    }()

    private static let displayTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
