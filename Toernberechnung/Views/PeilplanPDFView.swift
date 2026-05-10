import SwiftUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - Peilplan PDF View

/// Offline PDF viewer for Peilplan (survey plan) documents using PDFKit.
///
/// Bundled PDFs are loaded from app resources.
/// Supports zoom, scroll, and page navigation (PDFKit defaults).
///
/// The user manually looks up and enters chart-depth / Peilplan values
/// after consulting this PDF. The app does not automatically extract depths.
struct PeilplanPDFView: View {
    /// Name of the bundled PDF resource (without extension).
    let resourceName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                disclaimerBar

                if let url = Bundle.main.url(forResource: resourceName, withExtension: "pdf") {
                    PDFKitView(url: url)
                } else {
                    noPDFPlaceholder
                }
            }
            .navigationTitle("Peilplan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
            }
        }
    }

    private var disclaimerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.orange)
            Text("Peilpläne können sich ändern. Bitte prüfen Sie, ob diese Offline-Version aktuell ist, bevor Sie sich darauf verlassen.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
    }

    private var noPDFPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(Color.secondary)
            Text("Kein Peilplan verfügbar")
                .font(.system(size: 20, weight: .bold))
            Text("Die Datei \"\(resourceName).pdf\" wurde nicht im App-Bundle gefunden.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - PDFKit UIViewRepresentable

/// Wraps `PDFView` from PDFKit for use in SwiftUI.
struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.document = PDFDocument(url: url)
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        if pdfView.document?.documentURL != url {
            pdfView.document = PDFDocument(url: url)
        }
    }
}

// MARK: - Peilplan Entry Sheet

struct PeilplanEntrySheet: View {
    let viewModel: RoutePlannerViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("peilplanPDFPath") private var peilplanPDFPath = ""
    @State private var selectedPane = 0
    @State private var showPDFImporter = false
    @State private var peilplanError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Ansicht", selection: $selectedPane) {
                    Text("Werte").tag(0)
                    Text("Peilplan").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(16)

                if selectedPane == 0 {
                    valuesPane
                } else {
                    pdfPane
                }
            }
            .background(Color.appBackground)
            .navigationTitle("Wassertiefen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showPDFImporter, allowedContentTypes: [.pdf]) { result in
                importPeilplanPDF(result)
            }
        }
    }

    private var valuesPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let plan = viewModel.routePlan {
                    ForEach(plan.waypoints) { waypoint in
                        peilplanValueRow(waypoint)
                    }
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 42, weight: .bold))
                            .foregroundStyle(Color.secondary)
                        Text("Keine Route geladen")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Color.appPrimary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var pdfPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    showPDFImporter = true
                } label: {
                    Label("PDF auswählen", systemImage: "doc.badge.plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(hex: 0x0D9488), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                if !peilplanPDFPath.isEmpty {
                    Button {
                        peilplanPDFPath = ""
                    } label: {
                        Label("Zurücksetzen", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color(hex: 0x3C82FF))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color(hex: 0x3C82FF).opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            if let peilplanError {
                Text(peilplanError)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let url = bundledOrStoredPDFURL {
                PDFKitView(url: url)
                    .id(url)
            } else {
                noPDFPlaceholder
            }
        }
    }

    private var bundledOrStoredPDFURL: URL? {
        if !peilplanPDFPath.isEmpty {
            let storedURL = URL(fileURLWithPath: peilplanPDFPath)
            if FileManager.default.fileExists(atPath: storedURL.path) {
                return storedURL
            }
        }

        return Bundle.main.url(forResource: "peilplan_emden", withExtension: "pdf")
    }

    private var noPDFPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 46, weight: .bold))
                .foregroundStyle(Color.secondary)
            Text("Kein Peilplan-PDF hinterlegt")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.appPrimary)
            Text("Wähle ein PDF aus der Dateien-App, dann wird es hier in der App angezeigt.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func importPeilplanPDF(_ result: Result<URL, Error>) {
        do {
            let sourceURL = try result.get()
            let hasAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let documentsURL = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let destinationURL = documentsURL.appendingPathComponent("peilplan.pdf")

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            peilplanPDFPath = destinationURL.path
            peilplanError = nil
        } catch {
            peilplanError = "Peilplan konnte nicht geöffnet werden: \(error.localizedDescription)"
        }
    }

    private func peilplanValueRow(_ waypoint: RouteWaypoint) -> some View {
        let isLottiefe = waypoint.calculationMode == .lottiefe
        let title = isLottiefe ? "Lottiefe" : "Peilplanwert"
        let unit = isLottiefe ? "m" : "±m"

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isLottiefe ? "water.waves" : "ruler.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color(hex: 0x0D9488))
                    .frame(width: 32, height: 32)
                    .background(Color(hex: 0x0D9488).opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(waypoint.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.appPrimary)
                        .lineLimit(2)
                    Text(viewModel.planningDepthSourceText(for: waypoint.id))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }

                Spacer()
            }

            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                Spacer()
                TextField(
                    title,
                    value: planningDepthBinding(for: waypoint.id),
                    format: .number.precision(.fractionLength(1))
                )
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 18, weight: .bold))
                .frame(width: 96)
                Text(unit)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.secondary)
            }
            .padding(12)
            .background(Color.fieldBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private func planningDepthBinding(for waypointID: UUID) -> Binding<Double> {
        Binding(
            get: { viewModel.planningDepthValue(for: waypointID) ?? 0 },
            set: { viewModel.updatePlanningDepth(for: waypointID, value: $0) }
        )
    }
}
