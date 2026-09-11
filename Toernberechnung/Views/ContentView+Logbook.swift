// swiftlint:disable file_length
import MapKit
import SwiftUI
import UIKit

private extension View {
    func logbookListRow() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 14, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

extension ContentView {
    func logbookTab() -> some View {
        List {
            Text(AppTab.logbook.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .logbookListRow()

            logbookActionBar
                .logbookListRow()

            if voyageManager.isVoyageActive {
                liveVoyageBanner
                    .logbookListRow()
            }

            if calculations.isEmpty {
                logbookEmptyState
                    .logbookListRow()
            } else {
                ForEach(calculations, id: \.persistentModelID) { record in
                    logbookGlassCard {
                        logbookCard(record)
                    }
                    .logbookListRow()
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                _ = deleteCalculation(record)
                            }
                        } label: {
                            Label("Löschen", systemImage: "trash.fill")
                        }
                    }
                }
            }
        }
        .tracksAppHeaderVisibility($logbookHeaderVisible)
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, isPad ? 92 : 76, for: .scrollContent)
        .contentMargins(.bottom, 118, for: .scrollContent)
        .sheet(item: $selectedLogbookRecord) { record in
            LogbookDetailSheet(
                record: record,
                makePDF: { prepareCalculationPDF(record) }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.appBackground)
            .presentationCornerRadius(30)
        }
        .alert(
            "Löschen fehlgeschlagen",
            isPresented: Binding(
                get: { logbookDeleteError != nil },
                set: { isPresented in
                    if !isPresented { logbookDeleteError = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                logbookDeleteError = nil
            }
        } message: {
            Text(logbookDeleteError ?? "Der Törn konnte nicht gelöscht werden.")
        }
    }

    private var logbookActionBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(calculations.count == 1 ? "1 Törn" : "\(calculations.count) Törns")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(Color.appPrimary)
                Text("Planungen und aufgezeichnete Fahrten")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondary)
            }
            Spacer()
            Button {
                exportBlankLogbookTemplate()
            } label: {
                if logbookExportInProgress {
                    HStack(spacing: 7) {
                        ProgressView()
                        Text("PDF wird erstellt")
                    }
                    .font(.system(size: 13, weight: .bold))
                } else {
                    Label("Leerer Törnverlauf", systemImage: "doc.badge.plus")
                        .font(.system(size: 13, weight: .bold))
                }
            }
            .appGlassButton(tint: Color.appPrimary)
            .disabled(logbookExportInProgress)
        }
        .padding(14)
        .appFloatingOverlay(cornerRadius: 22)
    }

    private var logbookEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(Color.appPrimary)
            Text("Dein Logbuch ist bereit")
                .font(.system(size: 23, weight: .heavy))
            Text("Speichere eine Planung, zeichne eine Fahrt auf oder erstelle eine leere PDF-Vorlage.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
            Button {
                exportBlankLogbookTemplate()
            } label: {
                if logbookExportInProgress {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("PDF wird erstellt")
                    }
                } else {
                    Label("Leere PDF erstellen", systemImage: "doc.badge.plus")
                }
            }
            .appProminentButton(tint: Color.appPrimary)
            .disabled(logbookExportInProgress)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 280)
        .appFloatingOverlay(cornerRadius: 28)
    }

    private var liveVoyageBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.green)
                .frame(width: 44, height: 44)
                .background(Color.green.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("LIVE-AUFZEICHNUNG")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(Color.secondary)
                Text(voyageManager.activeRoute?.routeName ?? "Aktive Fahrt")
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = Date().timeIntervalSince(voyageManager.voyageStartTime ?? context.date)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Self.formatHMS(elapsed))
                        .font(.system(size: 15, weight: .heavy, design: .monospaced))
                    Text(String(format: "%.1f kn · %.2f nm", locationService.speedKnots, voyageManager.totalDistanceNm))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.secondary)
                }
            }
        }
        .padding(14)
        .appFloatingOverlay(cornerRadius: 20, tint: Color.green.opacity(0.08))
    }

    private func logbookCard(_ record: CalculationRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(logbookAccent(for: record).opacity(0.14))
                    Image(systemName: record.isActualVoyage ? "location.fill.viewfinder" : "book.pages.fill")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(logbookAccent(for: record))
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 5) {
                    Text(logbookTitle(for: record))
                        .font(.system(size: 21, weight: .heavy))
                        .foregroundStyle(Color.appPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                    Text(logbookRoute(for: record))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                logbookMetricChip(
                    String(format: "%.1f nm", logbookDistance(for: record)),
                    icon: "ruler"
                )
                logbookMetricChip(
                    durationText(logbookDurationSeconds(for: record) / 3600),
                    icon: "clock"
                )
                logbookMetricChip(
                    logbookStatus(for: record),
                    icon: logbookStatusIcon(for: record)
                )
            }

            Button {
                selectedLogbookRecord = record
            } label: {
                HStack(spacing: 10) {
                    Label("Logbuchdaten anzeigen", systemImage: "chart.xyaxis.line")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .heavy))
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.appPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background(
                    Color.fieldBackground.opacity(0.78),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color(hex: 0x3C82FF).opacity(0.14), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)

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

    private func logbookGlassCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

        return content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: shape)
            .overlay { shape.stroke(.white.opacity(0.68), lineWidth: 1) }
            .shadow(color: Color.appPrimary.opacity(0.08), radius: 18, y: 10)
    }

    private func logbookMetricChip(_ value: String, icon: String) -> some View {
        Label(value, systemImage: icon)
            .font(.system(size: 12, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.64)
            .foregroundStyle(Color.appPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                Color.fieldBackground.opacity(0.78),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(hex: 0x3C82FF).opacity(0.14), lineWidth: 1)
            }
    }

    private func logbookTitle(for record: CalculationRecord) -> String {
        "Törn · \(Self.dateFormatter.string(from: record.createdAt)) · \(Self.timeFormatter.string(from: record.createdAt))"
    }

    private func logbookRoute(for record: CalculationRecord) -> String {
        let start = record.startName.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = record.destinationName.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(start.isEmpty ? "Start" : start) → \(destination.isEmpty ? "Ziel" : destination)"
    }

    private func logbookDistance(for record: CalculationRecord) -> Double {
        record.isActualVoyage && record.actualDistanceNM > 0
            ? record.actualDistanceNM
            : record.distanceNM
    }

    private func logbookDurationSeconds(for record: CalculationRecord) -> TimeInterval {
        if record.isActualVoyage, record.voyageDurationSeconds > 0 {
            return record.voyageDurationSeconds
        }
        return max(0, record.arrivalAt.timeIntervalSince(record.departureAt))
    }

    private func logbookStatus(for record: CalculationRecord) -> String {
        let status = record.status.trimmingCharacters(in: .whitespacesAndNewlines)
        if !status.isEmpty { return status }
        return record.isActualVoyage ? "Aufgezeichnet" : "Entwurf"
    }

    private func logbookStatusIcon(for record: CalculationRecord) -> String {
        if record.isActualVoyage { return "location.fill.viewfinder" }
        let status = record.status
        if status.localizedCaseInsensitiveContains("nicht") { return "xmark.circle.fill" }
        if status.localizedCaseInsensitiveContains("einschr") { return "exclamationmark.circle.fill" }
        return "checkmark.circle.fill"
    }

    private func logbookAccent(for record: CalculationRecord) -> Color {
        record.isActualVoyage ? Color(hex: 0x0D9488) : Color(hex: 0x3C82FF)
    }

    private static func formatHMS(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    @MainActor
    private func saveLogbookDraft(_ draft: LogbookEntryDraft, into record: CalculationRecord?) {
        let target = record ?? CalculationRecord(
            routeTitle: draft.routeTitle,
            startName: draft.startName,
            destinationName: draft.destinationName,
            departureAt: draft.departureAt,
            arrivalAt: draft.arrivalAt,
            distanceNM: draft.distanceNM,
            status: draft.status,
            fmw: draft.fmw,
            wt: draft.wt,
            wuk: draft.wuk
        )
        target.routeTitle = draft.routeTitle
        target.startName = draft.startName
        target.destinationName = draft.destinationName
        target.departureAt = draft.departureAt
        target.arrivalAt = draft.arrivalAt
        target.distanceNM = draft.distanceNM
        target.status = draft.status
        target.fmw = draft.fmw
        target.wt = draft.wt
        target.wuk = draft.wuk
        target.weatherSummary = draft.weatherSummary
        target.tideSummary = draft.tideSummary
        target.crewSummary = draft.crewSummary
        target.notes = draft.notes
        if record == nil { modelContext.insert(target) }
        try? modelContext.save()
        writeAudit(
            action: record == nil ? "INSERT" : "UPDATE",
            source: "logbook",
            statement: "\(record == nil ? "INSERT INTO" : "UPDATE") calculations route='\(draft.routeTitle)'",
            status: "ok"
        )
    }

    @MainActor
    func deleteCalculation(_ record: CalculationRecord) -> Bool {
        let routeTitle = record.routeTitle
        let statement = "DELETE FROM calculations WHERE persistent_model_id = '\(record.persistentModelID)'"

        do {
            try modelContext.transaction {
                modelContext.delete(record)
                writeAudit(
                    action: "DELETE",
                    source: "logbook",
                    statement: statement,
                    status: "ok"
                )
                try modelContext.save()
            }
            logbookDeleteError = nil
            return true
        } catch {
            modelContext.rollback()
            writeAudit(
                action: "DELETE",
                source: "logbook",
                statement: "\(statement) -- route='\(routeTitle)' error='\(error.localizedDescription)'",
                status: "error"
            )
            try? modelContext.save()
            logbookDeleteError = "„\(routeTitle.isEmpty ? "Dieser Törn" : routeTitle)“ konnte nicht gelöscht werden. Bitte versuche es erneut."
            return false
        }
    }

    @MainActor
    private func prepareCalculationPDF(_ record: CalculationRecord) -> URL? {
        do {
            let url = try ToernPDFExporter.export(record: record)
            writeAudit(action: "EXPORT", source: "logbook", statement: "EXPORT PDF route='\(record.routeTitle)'", status: "ok")
            return url
        } catch {
            writeAudit(action: "EXPORT", source: "logbook", statement: "EXPORT PDF route='\(record.routeTitle)'", status: "error")
            return nil
        }
    }

    @MainActor
    func exportCalculation(_ record: CalculationRecord) {
        guard let url = prepareCalculationPDF(record) else { return }
        activityShareItem = ActivityShareItem(url: url)
    }

    @MainActor
    private func exportBlankLogbookTemplate() {
        guard !logbookExportInProgress else { return }
        logbookExportInProgress = true

        Task {
            defer { logbookExportInProgress = false }
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try ToernPDFExporter.exportBlankTemplate()
                }.value
                activityShareItem = ActivityShareItem(url: url)
                writeAudit(action: "EXPORT", source: "logbook", statement: "EXPORT blank logbook template", status: "ok")
            } catch {
                writeAudit(action: "EXPORT", source: "logbook", statement: "EXPORT blank logbook template", status: "error")
            }
        }
    }

    private static let displayDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppDateFormatters.germanLocale
        formatter.timeZone = AppDateFormatters.berlinTimeZone
        formatter.dateFormat = "dd.MM.yyyy · HH:mm"
        return formatter
    }()
}

struct LogbookEntryDraft {
    var routeTitle: String
    var startName: String
    var destinationName: String
    var departureAt: Date
    var arrivalAt: Date
    var distanceNM: Double
    var status: String
    var fmw: Double
    var wt: Double
    var wuk: Double
    var weatherSummary: String
    var tideSummary: String
    var crewSummary: String
    var notes: String

    init(record: CalculationRecord? = nil) {
        let now = Date()
        routeTitle = record?.routeTitle ?? "Manueller Törn"
        startName = record?.startName ?? ""
        destinationName = record?.destinationName ?? ""
        departureAt = record?.departureAt ?? now
        arrivalAt = record?.arrivalAt ?? now.addingTimeInterval(3600)
        distanceNM = record?.distanceNM ?? 0
        status = record?.status ?? "Entwurf"
        fmw = record?.fmw ?? 0
        wt = record?.wt ?? 0
        wuk = record?.wuk ?? 0
        weatherSummary = record?.weatherSummary ?? ""
        tideSummary = record?.tideSummary ?? ""
        crewSummary = record?.crewSummary ?? ""
        notes = record?.notes ?? ""
    }

    var isValid: Bool {
        !startName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !destinationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && arrivalAt >= departureAt
            && distanceNM >= 0 && fmw >= 0 && wt >= 0 && wuk >= 0
    }
}

private struct LogbookEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let record: CalculationRecord?
    let onSave: (LogbookEntryDraft) -> Void
    @State private var draft: LogbookEntryDraft

    init(record: CalculationRecord?, onSave: @escaping (LogbookEntryDraft) -> Void) {
        self.record = record
        self.onSave = onSave
        _draft = State(initialValue: LogbookEntryDraft(record: record))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    editorSection("Route", icon: "point.topleft.down.to.point.bottomright.curvepath") {
                        editorField("Start", text: $draft.startName, icon: "mappin.and.ellipse")
                        editorField("Ziel", text: $draft.destinationName, icon: "flag.checkered")
                        editorField("Bezeichnung", text: $draft.routeTitle, icon: "tag")
                    }
                    editorSection("Zeiten", icon: "clock") {
                        DatePicker("Abfahrt", selection: $draft.departureAt)
                        Divider()
                        DatePicker("Ankunft", selection: $draft.arrivalAt)
                        if draft.arrivalAt < draft.departureAt {
                            Label("Die Ankunft muss nach der Abfahrt liegen.", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.orange)
                        }
                    }
                    editorSection("Messwerte", icon: "gauge.with.dots.needle.67percent") {
                        numericField("Distanz", suffix: "nm", value: $draft.distanceNM)
                        numericField("Wassertiefe", suffix: "m", value: $draft.wt)
                        numericField("UKC", suffix: "m", value: $draft.wuk)
                        numericField("Fehlendes Wasser", suffix: "m", value: $draft.fmw)
                        Picker("Status", selection: $draft.status) {
                            ForEach(statusOptions, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    editorSection("Bordbuch", icon: "book.pages") {
                        editorField("Wetter", text: $draft.weatherSummary, icon: "cloud.sun", axis: .vertical)
                        editorField("Gezeiten", text: $draft.tideSummary, icon: "water.waves", axis: .vertical)
                        editorField("Crew", text: $draft.crewSummary, icon: "person.3", axis: .vertical)
                        editorField("Notizen und Ereignisse", text: $draft.notes, icon: "square.and.pencil", axis: .vertical)
                    }
                    if record?.isActualVoyage == true {
                        Label("GPS-Spur und tatsächlich gemessene Fahrtdaten bleiben unverändert.", systemImage: "lock.shield.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.secondary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .appFloatingOverlay(cornerRadius: 18)
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(record == nil ? "Törn eintragen" : "Törn bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        onSave(normalizedDraft)
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .disabled(!draft.isValid)
                }
            }
        }
    }

    private var normalizedDraft: LogbookEntryDraft {
        var result = draft
        result.startName = result.startName.trimmingCharacters(in: .whitespacesAndNewlines)
        result.destinationName = result.destinationName.trimmingCharacters(in: .whitespacesAndNewlines)
        result.routeTitle = result.routeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.routeTitle.isEmpty { result.routeTitle = "\(result.startName) – \(result.destinationName)" }
        return result
    }

    private var statusOptions: [String] {
        Array(Set(["Entwurf", "Geplant", "Fahrt abgeschlossen", "Abgebrochen", draft.status])).sorted()
    }

    private func editorSection<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title.uppercased(), systemImage: icon)
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(Color.appPrimary)
            content()
        }
        .appCardSurface(cornerRadius: 24)
    }

    private func editorField(_ title: String, text: Binding<String>, icon: String, axis: Axis = .horizontal) -> some View {
        HStack(alignment: axis == .vertical ? .top : .center, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Color.appPrimary)
                .frame(width: 22)
            TextField(title, text: text, axis: axis)
                .lineLimit(axis == .vertical ? 2...5 : 1...1)
        }
        .appFieldSurface(cornerRadius: 15)
    }

    private func numericField(_ title: String, suffix: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 86)
            Text(suffix).foregroundStyle(Color.secondary)
        }
        .font(.system(size: 14, weight: .semibold))
        .appFieldSurface(cornerRadius: 15)
    }
}

private enum LogbookDetailSection: String, CaseIterable, Identifiable {
    case overview = "Übersicht"
    case conditions = "Bedingungen"
    case notes = "Verlauf"
    var id: Self { self }
}

private struct LogbookDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let record: CalculationRecord
    let makePDF: () -> URL?
    @State private var section = LogbookDetailSection.overview
    @State private var shareItem: ActivityShareItem?

    private var breadcrumbs: [LogbookBreadcrumbPoint] { LogbookBreadcrumbPoint.decode(record.breadcrumbJSON) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    routeHero
                    Picker("Bereich", selection: $section) {
                        ForEach(LogbookDetailSection.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Group {
                        switch section {
                        case .overview: overview
                        case .conditions: conditions
                        case .notes: voyageDetails
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                .padding(16)
            }
            .navigationTitle("Törnverlauf")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        guard let url = makePDF() else { return }
                        shareItem = ActivityShareItem(url: url)
                    } label: { Image(systemName: "square.and.arrow.up") }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(activityItems: [item.url])
        }
        .animation(.easeInOut(duration: 0.22), value: section)
    }

    private var routeHero: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label(record.isActualVoyage ? "AUFGEZEICHNETE FAHRT" : "TÖRNVERLAUF", systemImage: record.isActualVoyage ? "location.fill.viewfinder" : "book.pages.fill")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(record.isActualVoyage ? Color.green : Color.appPrimary)
                Spacer()
                Text(record.status.isEmpty ? "Entwurf" : record.status)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.secondary)
            }
            LogbookRouteGraphic(start: record.startName, destination: record.destinationName)
            HStack {
                Label(Self.dateTime.string(from: record.departureAt), systemImage: "arrow.up.circle.fill")
                Spacer()
                Label(Self.dateTime.string(from: record.arrivalAt), systemImage: "flag.circle.fill")
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.secondary)
        }
        .padding(18)
        .appFloatingOverlay(cornerRadius: 26)
    }

    private var overview: some View {
        VStack(spacing: 14) {
            if record.isActualVoyage, breadcrumbs.count > 1 {
                LogbookTrackMap(points: breadcrumbs)
                    .frame(height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                metric("Distanz", value: distanceText, icon: "ruler", tint: Color.appPrimary)
                metric("Dauer", value: durationText, icon: "clock.fill", tint: Color(hex: 0x0D9488))
                metric("Wassertiefe", value: metres(record.wt), icon: "water.waves", tint: Color(hex: 0x0284C7))
                metric("UKC", value: metres(record.wuk), icon: "arrow.down.to.line", tint: record.wuk > 0 ? Color.green : Color.orange)
                if record.isActualVoyage {
                    metric("Ø SOG", value: knots(record.averageSOGKnots), icon: "speedometer", tint: Color(hex: 0x7C3AED))
                    metric("Max. SOG", value: knots(record.maxSOGKnots), icon: "gauge.open.with.lines.needle.67percent.and.arrowtriangle", tint: Color.orange)
                }
            }
        }
    }

    private var conditions: some View {
        VStack(spacing: 10) {
            textPanel("Wetter", value: record.weatherSummary, fallback: "Kein Wetter-Snapshot gespeichert", icon: "cloud.sun.fill", tint: Color.orange)
            textPanel("Gezeiten", value: record.tideSummary, fallback: "Kein BSH-Snapshot gespeichert", icon: "water.waves", tint: Color(hex: 0x0284C7))
            textPanel("Crew", value: record.crewSummary, fallback: "Keine Crew erfasst", icon: "person.3.fill", tint: Color(hex: 0x0D9488))
            textPanel("Fehlendes Wasser", value: metres(record.fmw), fallback: "–", icon: "exclamationmark.water.waves", tint: Color.orange)
        }
    }

    private var voyageDetails: some View {
        VStack(spacing: 10) {
            textPanel("Notizen und Ereignisse", value: record.notes, fallback: "Noch keine Notizen vorhanden", icon: "square.and.pencil", tint: Color.appPrimary)
            if record.isActualVoyage {
                textPanel("GPS-Aufzeichnung", value: "\(breadcrumbs.count) Wegpunkte · Messwerte sind schreibgeschützt", fallback: "Keine GPS-Punkte gespeichert", icon: "location.fill.viewfinder", tint: Color.green)
            }
        }
    }

    private func metric(_ title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(title.uppercased()).font(.system(size: 9, weight: .heavy)).foregroundStyle(Color.secondary)
            Text(value).font(.system(size: 20, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .padding(14)
        .background(Color.fieldBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func textPanel(_ title: String, value: String, fallback: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(title.uppercased()).font(.system(size: 10, weight: .heavy)).foregroundStyle(Color.secondary)
                Text(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : value)
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(15)
        .background(Color.fieldBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var distanceText: String {
        String(format: "%.1f nm", record.isActualVoyage && record.actualDistanceNM > 0 ? record.actualDistanceNM : record.distanceNM)
    }
    private var durationText: String {
        let seconds = record.isActualVoyage && record.voyageDurationSeconds > 0
            ? record.voyageDurationSeconds
            : record.arrivalAt.timeIntervalSince(record.departureAt)
        let minutes = max(0, Int(seconds / 60))
        return "\(minutes / 60)h \(minutes % 60)m"
    }
    private func metres(_ value: Double) -> String { value > 0 ? String(format: "%.2f m", value) : "–" }
    private func knots(_ value: Double) -> String { value > 0 ? String(format: "%.1f kn", value) : "–" }

    private static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppDateFormatters.germanLocale
        formatter.timeZone = AppDateFormatters.berlinTimeZone
        formatter.dateFormat = "dd.MM. · HH:mm"
        return formatter
    }()
}

private struct LogbookRouteGraphic: View {
    let start: String
    let destination: String

    var body: some View {
        HStack(spacing: 10) {
            endpoint(start.isEmpty ? "Start" : start, icon: "mappin.circle.fill", isLeading: true)
            HStack(spacing: 0) {
                Rectangle().fill(Color.appPrimary.opacity(0.32)).frame(height: 2)
                Image(systemName: "sailboat.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.appPrimary)
                    .padding(7)
                    .background(Color.appPrimary.opacity(0.12), in: Circle())
                Rectangle().fill(Color.appPrimary.opacity(0.32)).frame(height: 2)
            }
            endpoint(destination.isEmpty ? "Ziel" : destination, icon: "flag.checkered.circle.fill", isLeading: false)
        }
    }

    private func endpoint(_ label: String, icon: String, isLeading: Bool) -> some View {
        VStack(alignment: isLeading ? .leading : .trailing, spacing: 4) {
            Image(systemName: icon).foregroundStyle(Color.appPrimary)
            Text(label).font(.system(size: 12, weight: .heavy)).lineLimit(2).minimumScaleFactor(0.7)
        }
        .frame(width: 92, alignment: isLeading ? .leading : .trailing)
    }
}

private struct LogbookBreadcrumbPoint: Decodable {
    let lat: Double
    let lon: Double
    let ts: Double

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }

    static func decode(_ json: String) -> [LogbookBreadcrumbPoint] {
        guard let data = json.data(using: .utf8),
              let points = try? JSONDecoder().decode([LogbookBreadcrumbPoint].self, from: data) else { return [] }
        return points.filter { CLLocationCoordinate2DIsValid($0.coordinate) }
    }
}

private struct LogbookTrackMap: View {
    let points: [LogbookBreadcrumbPoint]
    private var coordinates: [CLLocationCoordinate2D] { points.map(\.coordinate) }

    var body: some View {
        Map(initialPosition: .region(region), interactionModes: [.pan, .zoom]) {
            if coordinates.count > 1 {
                MapPolyline(coordinates: coordinates)
                    .stroke(Color.appPrimary, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if let first = coordinates.first { Marker("Start", systemImage: "mappin", coordinate: first).tint(Color.green) }
            if let last = coordinates.last { Marker("Ziel", systemImage: "flag.checkered", coordinate: last).tint(Color.appPrimary) }
        }
        .mapStyle(.standard(elevation: .flat))
        .overlay(alignment: .topLeading) {
            Label("GPS-VERLAUF", systemImage: "location.fill.viewfinder")
                .font(.system(size: 10, weight: .heavy))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(10)
        }
    }

    private var region: MKCoordinateRegion {
        guard let first = coordinates.first else {
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 53.7, longitude: 7.4), span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5))
        }
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        let minLat = latitudes.min() ?? first.latitude
        let maxLat = latitudes.max() ?? first.latitude
        let minLon = longitudes.min() ?? first.longitude
        let maxLon = longitudes.max() ?? first.longitude
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(0.02, (maxLat - minLat) * 1.35), longitudeDelta: max(0.02, (maxLon - minLon) * 1.35))
        )
    }
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

    static func exportBlankTemplate() throws -> URL {
        let fileName = "TideNode-Leerer-Toernverlauf-\(Self.fileDate.string(from: Date())).pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: page)

        try renderer.writePDF(to: url) { context in
            context.beginPage()
            guard let cg = UIGraphicsGetCurrentContext() else { return }
            drawBlankLogbookPage(page: page, cg: cg)
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
        draw("Distanz: \(String(format: "%.1f nm", voyageDistance(record)))", at: CGPoint(x: margin, y: y + 2), font: .boldSystemFont(ofSize: 12), color: .black)
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

    private static func drawBlankLogbookPage(page: CGRect, cg: CGContext) {
        let margin: CGFloat = 36
        let width = page.width - margin * 2
        let blue = UIColor.appPrimary
        let line = UIColor(hex: 0xB9C1CE)
        let light = UIColor(hex: 0xF6F8FC)
        var y: CGFloat = 34

        draw("Schiffstagebuch (Törnverlauf)", at: CGPoint(x: margin, y: y), font: .italicSystemFont(ofSize: 24), color: .black)
        draw("Datum:", at: CGPoint(x: page.width - margin - 92, y: y + 8), font: .boldSystemFont(ofSize: 12), color: .black)
        y += 42

        let fieldH: CGFloat = 34
        drawCell("Törn von/nach:", value: "", rect: CGRect(x: margin, y: y, width: width * 0.62, height: fieldH), line: line, fill: light)
        drawCell("Startzeit:", value: "", rect: CGRect(x: margin + width * 0.62, y: y, width: width * 0.19, height: fieldH), line: line, fill: .white)
        drawCell("Ankunft:", value: "", rect: CGRect(x: margin + width * 0.81, y: y, width: width * 0.19, height: fieldH), line: line, fill: .white)
        y += fieldH

        drawCell("Schiffsführer:", value: "", rect: CGRect(x: margin, y: y, width: width * 0.38, height: fieldH), line: line, fill: .white)
        drawCell("Crew:", value: "", rect: CGRect(x: margin + width * 0.38, y: y, width: width * 0.42, height: fieldH), line: line, fill: .white)
        drawCell("Zeitzone:", value: "", rect: CGRect(x: margin + width * 0.80, y: y, width: width * 0.20, height: fieldH), line: line, fill: .white)
        y += fieldH

        drawCell("Wetter / Wind:", value: "", rect: CGRect(x: margin, y: y, width: width * 0.38, height: 48), line: line, fill: .white)
        drawCell("Gezeiten:", value: "", rect: CGRect(x: margin + width * 0.38, y: y, width: width * 0.42, height: 48), line: line, fill: .white)
        drawCell("Betriebsstd.:", value: "", rect: CGRect(x: margin + width * 0.80, y: y, width: width * 0.20, height: 48), line: line, fill: .white)
        y += 48

        drawCell("Wasserst.-Vorhers. (+/- m)", value: "", rect: CGRect(x: margin, y: y, width: width * 0.26, height: 36), line: line, fill: .white)
        drawCell("Tiefgang d. Bootes (m)", value: "", rect: CGRect(x: margin + width * 0.26, y: y, width: width * 0.24, height: 36), line: line, fill: .white)
        drawCell("Wassertiefe WT", value: "", rect: CGRect(x: margin + width * 0.50, y: y, width: width * 0.25, height: 36), line: line, fill: .white)
        drawCell("UKC", value: "", rect: CGRect(x: margin + width * 0.75, y: y, width: width * 0.25, height: 36), line: line, fill: .white)
        y += 50

        drawSectionTitle("Checkliste vor Abfahrt", at: CGPoint(x: margin, y: y), color: blue)
        y += 24
        drawChecklist(origin: CGPoint(x: margin, y: y), width: width, line: line)
        y += 148

        drawSectionTitle("Törnverlauf", at: CGPoint(x: margin + width * 0.40, y: y - 2), color: blue)
        draw("Distanz:", at: CGPoint(x: margin, y: y + 2), font: .boldSystemFont(ofSize: 12), color: .black)
        draw("Status:", at: CGPoint(x: margin + width * 0.74, y: y + 2), font: .boldSystemFont(ofSize: 12), color: .black)
        y += 24
        drawBlankRouteTable(origin: CGPoint(x: margin, y: y), width: width, line: line)
        y += 190

        drawSectionTitle("Ereignisse / Notizen", at: CGPoint(x: margin, y: y), color: blue)
        y += 22
        let notesRect = CGRect(x: margin, y: y, width: width, height: 130)
        stroke(notesRect, color: line, cg: cg)
        drawRuledLines(in: notesRect, every: 26, color: line, cg: cg)
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
            [record.destinationName, "2", "", "", String(format: "%.1f", voyageDistance(record)), "", "", displayTime.string(from: record.arrivalAt), travelDuration(record)],
            ["nach", "3", "", "", "", "", "", "", ""],
            ["nach", "4", "", "", "", "", "", "", ""],
            ["Gesamt (kumuliert)", "", "", "", String(format: "%.1f", voyageDistance(record)), "", "", "", travelDuration(record)]
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

    private static func drawBlankRouteTable(origin: CGPoint, width: CGFloat, line: UIColor) {
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

        for rowIndex in 0..<5 {
            x = origin.x
            for columnIndex in headers.indices {
                let colW = width * ratios[columnIndex]
                drawCell("", value: "", rect: CGRect(x: x, y: origin.y + headerH + CGFloat(rowIndex) * rowH, width: colW, height: rowH), line: line, fill: .white, valueFont: .systemFont(ofSize: 9))
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
        let duration = record.isActualVoyage && record.voyageDurationSeconds > 0
            ? record.voyageDurationSeconds
            : record.arrivalAt.timeIntervalSince(record.departureAt)
        let minutes = max(Int(duration / 60), 0)
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private static func voyageDistance(_ record: CalculationRecord) -> Double {
        record.isActualVoyage && record.actualDistanceNM > 0
            ? record.actualDistanceNM
            : record.distanceNM
    }

    private static func slug(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return value.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
            .replacingOccurrences(of: "--", with: "-")
    }

    private static let fileDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppDateFormatters.germanLocale
        formatter.timeZone = AppDateFormatters.berlinTimeZone
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter
    }()

    private static let displayDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppDateFormatters.germanLocale
        formatter.timeZone = AppDateFormatters.berlinTimeZone
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter
    }()

    private static let displayTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppDateFormatters.germanLocale
        formatter.timeZone = AppDateFormatters.berlinTimeZone
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
