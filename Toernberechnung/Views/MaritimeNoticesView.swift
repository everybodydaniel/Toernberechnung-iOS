import SwiftUI

private enum MaritimeNoticeViewFilter: String, CaseIterable, Identifiable {
    case unread = "Ungelesen"
    case current = "Aktuell"
    case archive = "Archiv"

    var id: Self { self }
}

enum MaritimeNoticePreviewPolicy {
    static func select(
        from notices: [MaritimeNoticeSummary],
        unreadIDs: Set<String>,
        now: Date = .now,
        limit: Int = 3
    ) -> [MaritimeNoticeSummary] {
        guard limit > 0 else { return [] }
        return Array(
            notices
                .filter { unreadIDs.contains($0.id) || $0.isCurrent(at: now) }
                .sorted { lhs, rhs in
                    let lhsUnread = unreadIDs.contains(lhs.id)
                    let rhsUnread = unreadIDs.contains(rhs.id)
                    if lhsUnread != rhsUnread { return lhsUnread }
                    return lhs.updatedAt > rhs.updatedAt
                }
                .prefix(limit)
        )
    }
}

struct MaritimeNoticeQuickLook: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(MaritimeNoticeCenter.self) private var center

    let onOpenNotice: (MaritimeNoticeSummary) -> Void
    let onShowAll: () -> Void

    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            quickLookHeader

            Divider()

            quickLookContent

            if hasMoreNotices {
                Button(action: onShowAll) {
                    HStack {
                        Text("Mehr anzeigen")
                        Spacer()
                        Text("\(center.notices.count)")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.appPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.appPrimary.opacity(0.09), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Öffnet die vollständige Meldungsübersicht")
            }
        }
        .padding(15)
        .frame(minWidth: 290, idealWidth: 340, maxWidth: 360, alignment: .leading)
        .appNoticeGlass(cornerRadius: 26)
        .scaleEffect(reduceMotion ? 1 : (appeared ? 1 : 0.92), anchor: .topTrailing)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.38, dampingFraction: 0.82)) {
                appeared = true
            }
            Task { await center.refresh(force: false) }
        }
        .onDisappear { appeared = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Seefahrer-Nachrichten")
    }

    private var quickLookHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: center.unreadCount > 0 ? "bell.badge.fill" : "bell.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.appPrimary)

            VStack(alignment: .leading, spacing: 1) {
                Text("Seefahrer-Nachrichten")
                    .font(.system(size: 16, weight: .bold))
                Text(center.unreadCount == 0 ? "Keine ungelesenen Meldungen" : "\(center.unreadCount) ungelesen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if center.unreadCount > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        center.markAllRead()
                    }
                } label: {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Alle Meldungen als gelesen markieren")
            }
        }
    }

    @ViewBuilder
    private var quickLookContent: some View {
        if center.isLoading && center.notices.isEmpty {
            HStack(spacing: 10) {
                ProgressView()
                Text("Meldungen werden geladen …")
                    .font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 18)
        } else if let error = center.errorMessage, center.notices.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Meldungen nicht erreichbar", systemImage: "wifi.slash")
                    .font(.subheadline.weight(.bold))
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Erneut versuchen") {
                    Task { await center.refresh(force: true) }
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.appPrimary)
            }
            .padding(.vertical, 8)
        } else if previewNotices.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Alles im Blick")
                        .font(.subheadline.weight(.bold))
                    Text("Neue amtliche BfS erscheinen hier automatisch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 12)
        } else {
            VStack(spacing: 4) {
                ForEach(previewNotices) { notice in
                    Button {
                        onOpenNotice(notice)
                    } label: {
                        MaritimeNoticeCompactRow(
                            notice: notice,
                            isUnread: center.isUnread(notice)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Öffnet die vollständige Meldung")

                    if notice.id != previewNotices.last?.id {
                        Divider()
                            .padding(.leading, 43)
                    }
                }
            }
        }
    }

    private var previewNotices: [MaritimeNoticeSummary] {
        let unreadIDs = Set(center.notices.filter(center.isUnread).map(\.id))
        return MaritimeNoticePreviewPolicy.select(
            from: center.notices,
            unreadIDs: unreadIDs
        )
    }

    private var hasMoreNotices: Bool {
        center.notices.count > previewNotices.count
    }
}

struct MaritimeNoticesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MaritimeNoticeCenter.self) private var center

    @State private var filter: MaritimeNoticeViewFilter = .unread
    @State private var query = ""
    @State private var path: [MaritimeNoticeSummary]

    init(initialNotice: MaritimeNoticeSummary? = nil) {
        _path = State(initialValue: initialNotice.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.appPrimary.opacity(0.055)
                    .ignoresSafeArea()

                noticeOverview
            }
            .navigationTitle("Seefahrer-Nachrichten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        center.markAllRead()
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .disabled(center.unreadCount == 0)
                    .accessibilityLabel("Alle Meldungen als gelesen markieren")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .navigationDestination(for: MaritimeNoticeSummary.self) { notice in
                MaritimeNoticeDetailView(notice: notice)
            }
        }
    }

    private var noticeOverview: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                noticeControls

                if center.isStale {
                    Label("Offline-Daten. Der Stand kann veraltet sein.", systemImage: "wifi.slash")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 4)
                }

                if center.isLoading && center.notices.isEmpty {
                    compactStatusPanel(
                        title: "Meldungen werden geladen",
                        message: "Die amtlichen BfS werden synchronisiert.",
                        icon: "arrow.triangle.2.circlepath"
                    )
                } else if let error = center.errorMessage, center.notices.isEmpty {
                    errorPanel(error)
                } else if filteredNotices.isEmpty {
                    compactStatusPanel(title: emptyTitle, message: emptyDescription, icon: emptyIcon)
                } else {
                    if let lastIngestedAt = center.lastIngestedAt {
                        Text("Stand: \(lastIngestedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }

                    ForEach(filteredNotices) { notice in
                        NavigationLink(value: notice) {
                            MaritimeNoticeRow(
                                notice: notice,
                                isUnread: center.isUnread(notice)
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if center.isUnread(notice) {
                                Button {
                                    center.markRead(notice)
                                } label: {
                                    Label("Als gelesen markieren", systemImage: "checkmark.circle")
                                }
                            }
                        }
                    }

                    Text("Amtliche BfS sind eine Informationsquelle. Prüfe vor der Fahrt zusätzlich die gültigen Bekanntmachungen und nautischen Unterlagen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .refreshable { await center.refresh(force: true) }
    }

    private var noticeControls: some View {
        VStack(spacing: 12) {
            Picker("Meldungsfilter", selection: $filter) {
                ForEach(MaritimeNoticeViewFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Meldung, Ort oder BfS-Nummer", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Suche löschen")
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .padding(12)
        .appNoticeGlass(cornerRadius: 22)
    }

    private func compactStatusPanel(title: String, message: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Color.appPrimary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 18)
        .appNoticeGlass(cornerRadius: 24)
    }

    private func errorPanel(_ error: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("Meldungen nicht erreichbar")
                .font(.headline)
            Text(error)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Erneut versuchen") {
                Task { await center.refresh(force: true) }
            }
            .appGlassButton(tint: .appPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .appNoticeGlass(cornerRadius: 24)
    }

    private var filteredNotices: [MaritimeNoticeSummary] {
        let now = Date()
        return center.notices.filter { notice in
            let included: Bool
            switch filter {
            case .unread:
                included = center.isUnread(notice)
            case .current:
                included = notice.isCurrent(at: now)
            case .archive:
                included = !notice.isCurrent(at: now)
            }
            guard included else { return false }
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { return true }
            return [notice.title, notice.location, notice.publisher, notice.bfsNumber, notice.regionPath]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .unread: return "Alles gelesen"
        case .current: return "Keine aktuellen Meldungen"
        case .archive: return "Archiv ist leer"
        }
    }

    private var emptyIcon: String {
        filter == .unread ? "checkmark.circle" : "bell.slash"
    }

    private var emptyDescription: String {
        query.isEmpty ? "Neue amtliche BfS erscheinen hier automatisch." : "Für diese Suche wurde keine Meldung gefunden."
    }
}

private struct MaritimeNoticeCompactRow: View {
    let notice: MaritimeNoticeSummary
    let isUnread: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.isTemporary ? "exclamationmark.triangle.fill" : "megaphone.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(maritimeNoticeStateColor(notice))
                .frame(width: 32, height: 32)
                .background(maritimeNoticeStateColor(notice).opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(notice.bfsNumber)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(maritimeNoticeStateColor(notice))
                        .lineLimit(1)
                    Spacer()
                    Text(notice.updatedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(notice.displayTitle)
                    .font(.subheadline.weight(isUnread ? .bold : .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let location = notice.location, !location.isEmpty {
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if isUnread {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .padding(.top, 3)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private struct MaritimeNoticeRow: View {
    let notice: MaritimeNoticeSummary
    let isUnread: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(maritimeNoticeStateColor(notice).opacity(0.14))
                    .frame(width: 42, height: 42)
                Image(systemName: notice.isTemporary ? "exclamationmark.triangle.fill" : "megaphone.fill")
                    .foregroundStyle(maritimeNoticeStateColor(notice))
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(notice.bfsNumber)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(maritimeNoticeStateColor(notice))
                    Spacer()
                    Text(notice.updatedAt, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(notice.displayTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                if let location = notice.location, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(notice.publicationState.label)
                    if notice.revision > 1 { Text("Revision \(notice.revision)") }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }

            if isUnread {
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
                    .accessibilityLabel("Ungelesen")
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
        }
        .padding(14)
        .background(
            Color(uiColor: .secondarySystemBackground).opacity(0.76),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 0.7)
        }
    }
}

private struct MaritimeNoticeDetailView: View {
    @Environment(MaritimeNoticeCenter.self) private var center
    let notice: MaritimeNoticeSummary
    @State private var detail: MaritimeNoticeDetail?
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                if loading {
                    ProgressView("Meldung wird geladen …")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 50)
                } else if let detail {
                    detailContent(detail)
                } else {
                    summaryFallback
                }
            }
            .padding(16)
        }
        .background(Color.appPrimary.opacity(0.055).ignoresSafeArea())
        .navigationTitle(notice.bfsNumber)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            center.markRead(notice)
            detail = await center.detail(for: notice)
            loading = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(notice.publicationState.label.uppercased())
                .font(.caption.weight(.heavy))
                .foregroundStyle(notice.publicationState == .updated ? .orange : Color.appPrimary)
            Text(notice.displayTitle)
                .font(.system(size: 22, weight: .bold))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(notice.publisher)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .appCardSurface(cornerRadius: 24)
    }

    private var summaryFallback: some View {
        Group {
            VStack(alignment: .leading, spacing: 12) {
                detailLine("Gebiet", value: readableRegionPath, icon: "map")
                if let location = notice.location {
                    detailLine("Ort", value: location, icon: "mappin")
                }
                if let validFrom = notice.validFrom {
                    detailLine(
                        "Gültig ab",
                        value: validFrom.formatted(date: .abbreviated, time: .shortened),
                        icon: "calendar"
                    )
                }
                if let validUntil = notice.validUntil {
                    detailLine(
                        "Gültig bis",
                        value: validUntil.formatted(date: .abbreviated, time: .shortened),
                        icon: "calendar.badge.clock"
                    )
                }
            }
            .appCardSurface(cornerRadius: 24)

            if let sourceURL = notice.sourceURL {
                Link(destination: sourceURL) {
                    Label("Offizielle ELWIS-Seite öffnen", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity)
                }
                .appProminentButton(tint: .appPrimary)
            }
        }
    }

    private var readableRegionPath: String {
        notice.regionPath.replacingOccurrences(of: ".", with: " · ")
    }

    @MainActor
    private func retryDetail() async {
        loading = true
        detail = await center.detail(for: notice)
        loading = false
    }

    @ViewBuilder
    private func detailContent(_ detail: MaritimeNoticeDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            detailLine("Gebiet", value: detail.regionPath, icon: "map")
            if let location = detail.location { detailLine("Ort", value: location, icon: "mappin") }
            if let validFrom = detail.validFrom {
                detailLine("Gültig ab", value: validFrom.formatted(date: .abbreviated, time: .shortened), icon: "calendar")
            }
            if let validUntil = detail.validUntil {
                detailLine("Gültig bis", value: validUntil.formatted(date: .abbreviated, time: .shortened), icon: "calendar.badge.clock")
            }
        }
        .appCardSurface(cornerRadius: 24)

        VStack(alignment: .leading, spacing: 10) {
            Text("Meldung")
                .font(.headline)
            Text(detail.body)
                .font(.body)
                .textSelection(.enabled)
        }
        .appCardSurface(cornerRadius: 24)

        if !detail.chartReferences.isEmpty || !detail.previousNotices.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if !detail.chartReferences.isEmpty {
                    detailLine("Karten", value: detail.chartReferences.joined(separator: ", "), icon: "map.fill")
                }
                if !detail.previousNotices.isEmpty {
                    detailLine("Bezug", value: detail.previousNotices.joined(separator: ", "), icon: "link")
                }
            }
            .appCardSurface(cornerRadius: 24)
        }

        if let sourceURL = detail.sourceURL {
            Link(destination: sourceURL) {
                Label("Offizielle ELWIS-Seite öffnen", systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity)
            }
            .appProminentButton(tint: .appPrimary)
        }
    }

    private func detailLine(_ label: String, value: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Color.appPrimary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
            }
        }
    }
}

private func maritimeNoticeStateColor(_ notice: MaritimeNoticeSummary) -> Color {
    switch notice.publicationState {
    case .current: return .appPrimary
    case .updated: return .orange
    case .revoked, .expired: return .secondary
    }
}
