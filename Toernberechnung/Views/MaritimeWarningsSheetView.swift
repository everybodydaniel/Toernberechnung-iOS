import SwiftUI
import CoreLocation
import SafariServices

public struct MaritimeWarningsSheetView: View {
    var service: MaritimeWarningsService
    var onSelectCoordinate: ((CLLocationCoordinate2D) -> Void)?
    var onSelectWarning: ((MaritimeWarning) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedFilter: WarningFilter = .all
    @State private var presentedWebURL: URL?
    @State private var expandedWarningID: String?

    public init(
        service: MaritimeWarningsService = .shared,
        onSelectCoordinate: ((CLLocationCoordinate2D) -> Void)? = nil,
        onSelectWarning: ((MaritimeWarning) -> Void)? = nil
    ) {
        self.service = service
        self.onSelectCoordinate = onSelectCoordinate
        self.onSelectWarning = onSelectWarning
    }

    enum WarningFilter: String, CaseIterable, Identifiable {
        case all = "Alle Nordsee"
        case hazards = "Gefahr / Sperrung"
        case warnings = "Warnung / Tonnen"
        case notices = "Hinweise"

        var id: Self { self }
    }

    private var filteredWarnings: [MaritimeWarning] {
        switch selectedFilter {
        case .all:
            return service.warnings
        case .hazards:
            return service.warnings.filter { $0.severity == .hazard }
        case .warnings:
            return service.warnings.filter { $0.severity == .warning }
        case .notices:
            return service.warnings.filter { $0.severity == .notice }
        }
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // MARK: Official Bulletins Header Section
                    officialBulletinsSection

                    // MARK: Filter Bar
                    filterSection

                    // MARK: Warnings List
                    warningsListSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Nordsee Warnmeldungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if service.unreadCount > 0 {
                        Button {
                            withAnimation {
                                service.markAllAsRead()
                            }
                        } label: {
                            Label("Gelesen", systemImage: "checkmark.circle")
                                .font(.system(size: 14, weight: .medium))
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") {
                        dismiss()
                    }
                    .font(.system(size: 15, weight: .semibold))
                }
            }
            .refreshable {
                await service.refresh()
            }
            .sheet(item: $presentedWebURL) { url in
                SafariSheetView(url: url)
            }
        }
    }

    // MARK: - Official Bulletins Section

    private var officialBulletinsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Amtliche Berichte & Seefunk")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("BSH & WSV")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.appPrimary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(service.officialBulletins) { bulletin in
                        Button {
                            presentedWebURL = bulletin.url
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: bulletin.icon)
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundStyle(Color.appPrimary)
                                        .frame(width: 32, height: 32)
                                        .appGlassIconBackground()

                                    Spacer()

                                    if bulletin.isPDF {
                                        Text("PDF")
                                            .font(.system(size: 9, weight: .heavy))
                                            .foregroundStyle(Color.white)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.red.opacity(0.85), in: Capsule())
                                    } else {
                                        Text("WEB")
                                            .font(.system(size: 9, weight: .heavy))
                                            .foregroundStyle(Color.white)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.appPrimary.opacity(0.85), in: Capsule())
                                    }
                                }

                                Text(bulletin.title)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Color.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)

                                Text(bulletin.subtitle)
                                    .font(.system(size: 11, weight: .regular))
                                    .foregroundStyle(Color.secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)

                                Spacer(minLength: 0)

                                HStack {
                                    Text(bulletin.authority)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Color.secondary)
                                    Spacer()
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.appPrimary)
                                }
                            }
                            .padding(12)
                            .frame(width: 220, height: 148)
                            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Filter Bar

    private var filterSection: some View {
        Picker("Filter", selection: $selectedFilter) {
            ForEach(WarningFilter.allCases) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Warnings List

    private var warningsListSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Aktive Meldungen (\(filteredWarnings.count))")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.secondary)
                    .textCase(.uppercase)

                Spacer()

                if service.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if let last = service.lastRefreshDate {
                    Text("Stand: \(AppDateFormatters.hourMinute.string(from: last)) Uhr")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Color.secondary)
                }
            }

            if filteredWarnings.isEmpty {
                emptyStateView
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(filteredWarnings) { warning in
                        warningCard(warning)
                    }
                }
            }
        }
    }

    // MARK: - Warning Card

    @ViewBuilder
    private func warningCard(_ warning: MaritimeWarning) -> some View {
        let isExpanded = expandedWarningID == warning.id
        let isUnread = !service.isRead(id: warning.id)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                // Severity Badge Icon
                Image(systemName: warning.severity.systemImage)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(severityColor(warning.severity))
                    .frame(width: 36, height: 36)
                    .background(severityColor(warning.severity).opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(warning.areaName)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.appPrimary)
                            .lineLimit(1)

                        Spacer()

                        if isUnread {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                        }

                        Text(AppDateFormatters.dayMonthYear.string(from: warning.publishDate))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.secondary)
                    }

                    Text(warning.title)
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(Color.primary)
                        .lineLimit(isExpanded ? nil : 2)
                }
            }

            // Description
            Text(warning.details)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.secondary)
                .lineLimit(isExpanded ? nil : 3)
                .lineSpacing(2)

            // Actions & Coordinates
            HStack(spacing: 8) {
                if let coord = warning.coordinate {
                    Button {
                        service.markAsRead(id: warning.id)
                        if let onSelectWarning {
                            onSelectWarning(warning)
                        } else {
                            onSelectCoordinate?(coord)
                        }
                        dismiss()
                    } label: {
                        Label("Auf Seekarte", systemImage: "map.fill")
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.appPrimary.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.appPrimary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("WarningActionSeekarte")
                }

                if let url = warning.webUrl {
                    Button {
                        service.markAsRead(id: warning.id)
                        presentedWebURL = url
                    } label: {
                        Label("Quelle", systemImage: "arrow.up.right")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.06), in: Capsule())
                            .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        if expandedWarningID == warning.id {
                            expandedWarningID = nil
                        } else {
                            expandedWarningID = warning.id
                            service.markAsRead(id: warning.id)
                        }
                    }
                } label: {
                    Text(isExpanded ? "Weniger" : "Mehr")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.appPrimary)
                }
            }
        }
        .padding(14)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isUnread ? Color.red.opacity(0.35) : Color.white.opacity(0.08), lineWidth: isUnread ? 1.2 : 0.8)
        )
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                if expandedWarningID == warning.id {
                    expandedWarningID = nil
                } else {
                    expandedWarningID = warning.id
                    service.markAsRead(id: warning.id)
                }
            }
        }
    }

    private func severityColor(_ severity: MaritimeWarningSeverity) -> Color {
        severity.displayColor
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.green.opacity(0.8))
                .padding(.top, 24)

            Text("Keine aktiven Warnungen")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.primary)

            Text("Für den ausgewählten Filter liegen aktuell keine Gefahren- oder Warnmeldungen vor.")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Safari Sheet View

struct SafariSheetView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let safari = SFSafariViewController(url: url)
        safari.preferredControlTintColor = UIColor.appPrimary
        return safari
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
