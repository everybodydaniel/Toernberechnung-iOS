import SwiftData
import SwiftUI

// MARK: - Category

enum CrewEventCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case departure = "Törnstart"
    case harbour = "Hafenmanöver"
    case meeting = "Crewtreffen"
    case briefing = "Sicherheit"
    case supplies = "Proviant"
    case maintenance = "Wartung"
    case other = "Sonstiges"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .departure: return "sailboat.fill"
        case .harbour: return "ferry.fill"
        case .meeting: return "person.3.fill"
        case .briefing: return "cross.case.fill"
        case .supplies: return "bag.fill"
        case .maintenance: return "wrench.and.screwdriver.fill"
        case .other: return "calendar"
        }
    }

    var tint: Color {
        switch self {
        case .departure: return Color.appPrimary
        case .harbour: return Color(hex: 0x0EA5E9)
        case .meeting: return Color(hex: 0x0D9488)
        case .briefing: return Color(hex: 0xE11D48)
        case .supplies: return Color(hex: 0xF59E0B)
        case .maintenance: return Color(hex: 0x7C3AED)
        case .other: return Color(hex: 0x64748B)
        }
    }

    static func resolved(_ rawValue: String) -> CrewEventCategory {
        CrewEventCategory(rawValue: rawValue) ?? .other
    }
}

extension CrewEventRecord {
    var resolvedCategory: CrewEventCategory {
        CrewEventCategory.resolved(category)
    }

    /// Plain-text representation used by the share sheet. Deliberately readable
    /// in any target app — mail, messages or a notes app all get the same text.
    var shareText: String {
        var lines = [title]
        lines.append(CrewEventFormat.timeRange(self))
        if !location.isEmpty { lines.append("Ort: \(location)") }
        if !attendees.isEmpty { lines.append("Crew: \(attendees.joined(separator: ", "))") }
        if !notes.isEmpty { lines.append("") ; lines.append(notes) }
        lines.append("")
        lines.append("Geplant mit TideNode")
        return lines.joined(separator: "\n")
    }
}

enum CrewEventFormat {
    static func timeRange(_ event: CrewEventRecord) -> String {
        let day = event.startsAt.formatted(
            .dateTime.locale(Locale(identifier: "de_DE")).weekday(.wide).day().month(.wide).year()
        )
        guard !event.isAllDay else { return "\(day) · ganztägig" }
        let start = AppDateFormatters.hourMinute.string(from: event.startsAt)
        let end = AppDateFormatters.hourMinute.string(from: event.endsAt)
        return "\(day) · \(start)–\(end) Uhr"
    }
}

private extension View {
    func crewPlanningListRow() -> some View {
        listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

// MARK: - Planning

/// Local appointment planning for the crew. Everything is stored in SwiftData
/// on this device — no account, no sync.
struct CrewPlanningView: View {
    @Binding var section: CrewspaceSection
    @Binding var headerVisible: Bool
    let topContentInset: CGFloat
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CrewEventRecord.startsAt, order: .forward) private var events: [CrewEventRecord]

    @State private var selectedDate = Date()
    @State private var newEventShown = false
    @State private var eventToEdit: CrewEventRecord?

    var body: some View {
        List {
            CrewspaceScrollingHeader(section: $section)
                .crewPlanningListRow()

            CrewMonthCalendar(selectedDate: $selectedDate, markedDays: markedDays)
                .crewPlanningListRow()

            HStack {
                Text(dayTitle)
                    .font(.system(size: 20, weight: .heavy))
                Spacer()
                Button { newEventShown = true } label: {
                    Label("Termin", systemImage: "plus")
                        .font(.system(size: 13, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.appPrimary)
            }
            .crewPlanningListRow()

            if eventsForSelectedDay.isEmpty {
                emptyDayCard
                    .crewPlanningListRow()
            } else {
                ForEach(eventsForSelectedDay, id: \.persistentModelID) { event in
                    eventRow(event)
                        .crewPlanningListRow()
                        .contextMenu {
                            Button { eventToEdit = event } label: {
                                Label("Bearbeiten", systemImage: "pencil")
                            }
                            ShareLink(item: event.shareText) {
                                Label("Termin teilen", systemImage: "square.and.arrow.up")
                            }
                            Button(role: .destructive) {
                                delete(event)
                            } label: {
                                Label("Löschen", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                    delete(event)
                                }
                            } label: {
                                Label("Löschen", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            ShareLink(item: event.shareText) {
                                Label("Teilen", systemImage: "square.and.arrow.up")
                            }
                            .tint(Color.appPrimary)
                        }
                }
            }

            if let next = upcomingEvent {
                upcomingEventBanner(next)
                    .crewPlanningListRow()
            }
        }
        .tracksAppHeaderVisibility($headerVisible)
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .contentMargins(.top, topContentInset, for: .scrollContent)
        .contentMargins(.bottom, 28, for: .scrollContent)
        .sheet(isPresented: $newEventShown) {
            CrewEventEditor(initialDate: selectedDate) { draft in
                insert(draft)
                newEventShown = false
            }
            .presentationDetents([.fraction(0.68), .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(30)
            .appSheetGlassBackground()
        }
        .sheet(item: $eventToEdit) { event in
            CrewEventEditor(initialDate: event.startsAt, event: event) { draft in
                apply(draft, to: event)
                eventToEdit = nil
            }
            .presentationDetents([.fraction(0.68), .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(30)
            .appSheetGlassBackground()
        }
    }

    private var calendar: Calendar { AppDateFormatters.berlinCalendar }

    /// Days that carry at least one appointment — drives the dot in the grid.
    private var markedDays: Set<Date> {
        Set(events.map { calendar.startOfDay(for: $0.startsAt) })
    }

    private var eventsForSelectedDay: [CrewEventRecord] {
        events.filter { calendar.isDate($0.startsAt, inSameDayAs: selectedDate) }
    }

    private var upcomingEvent: CrewEventRecord? {
        events.first { $0.startsAt >= .now }
    }

    private var dayTitle: String {
        selectedDate.formatted(
            .dateTime.locale(Locale(identifier: "de_DE")).weekday(.wide).day().month(.wide)
        )
    }

    private var emptyDayCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.appPrimary)
            Text("Noch nichts geplant")
                .font(.system(size: 16, weight: .heavy))
            Text("Lege Törnstart, Hafenmanöver oder Crewtreffen für diesen Tag an.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .appCardSurface(cornerRadius: 24)
    }

    private func eventRow(_ event: CrewEventRecord) -> some View {
        let category = event.resolvedCategory
        return HStack(alignment: .top, spacing: 13) {
            VStack(spacing: 2) {
                if event.isAllDay {
                    Image(systemName: "sun.horizon.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(category.tint)
                    Text("ganztags")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.secondary)
                } else {
                    Text(event.startsAt, style: .time)
                        .font(.system(size: 14, weight: .heavy))
                    Text(event.endsAt, style: .time)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.secondary)
                }
            }
            .frame(width: 54)

            Capsule()
                .fill(category.tint)
                .frame(width: 4, height: 56)

            VStack(alignment: .leading, spacing: 5) {
                Text(event.title)
                    .font(.system(size: 16, weight: .heavy))
                Label(category.rawValue, systemImage: category.icon)
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(category.tint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(category.tint.opacity(0.12), in: Capsule())
                if !event.location.isEmpty {
                    Label(event.location, systemImage: "mappin.and.ellipse")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.appPrimary)
                }
                if !event.attendees.isEmpty {
                    Label(event.attendees.joined(separator: ", "), systemImage: "person.2.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
                if !event.notes.isEmpty {
                    Text(event.notes)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()

            VStack(spacing: 4) {
                Button {
                    eventToEdit = event
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Termin bearbeiten")

                ShareLink(item: event.shareText) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Termin teilen")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.appPrimary)
        }
        .padding(14)
        .appCardSurface(cornerRadius: 20)
    }

    private func upcomingEventBanner(_ event: CrewEventRecord) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                selectedDate = event.startsAt
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.appPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nächster Termin")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(Color.secondary)
                    Text("\(event.title) · \(event.startsAt.formatted(.dateTime.locale(Locale(identifier: "de_DE")).day().month().hour().minute()))")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.secondary)
            }
            .padding(13)
            .background(Color.appPrimary.opacity(0.09), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Persistence

    @MainActor
    private func insert(_ draft: CrewEventDraft) {
        modelContext.insert(CrewEventRecord(
            title: draft.title,
            startsAt: draft.startsAt,
            endsAt: draft.endsAt,
            location: draft.location,
            notes: draft.notes,
            category: draft.category.rawValue,
            isAllDay: draft.isAllDay,
            attendees: draft.attendees
        ))
        try? modelContext.save()
    }

    @MainActor
    private func apply(_ draft: CrewEventDraft, to event: CrewEventRecord) {
        event.title = draft.title
        event.startsAt = draft.startsAt
        event.endsAt = draft.endsAt
        event.location = draft.location
        event.notes = draft.notes
        event.category = draft.category.rawValue
        event.isAllDay = draft.isAllDay
        event.attendees = draft.attendees
        try? modelContext.save()
    }

    @MainActor
    private func delete(_ event: CrewEventRecord) {
        modelContext.delete(event)
        try? modelContext.save()
    }
}

// MARK: - Month calendar

/// Month grid with a dot on every day that carries an appointment. SwiftUI's
/// graphical `DatePicker` cannot annotate days, so the grid is drawn here.
struct CrewMonthCalendar: View {
    @Binding var selectedDate: Date
    let markedDays: Set<Date>

    @State private var visibleMonth = Date()

    private var calendar: Calendar { AppDateFormatters.berlinCalendar }

    var body: some View {
        VStack(spacing: 14) {
            header
            weekdayRow
            grid
        }
        .padding(16)
        .appCardSurface(cornerRadius: 24)
        .onAppear { visibleMonth = selectedDate }
        .onChange(of: selectedDate) { _, newValue in
            guard !calendar.isDate(newValue, equalTo: visibleMonth, toGranularity: .month) else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                visibleMonth = newValue
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(monthTitle)
                .font(.system(size: 19, weight: .heavy))
                .foregroundStyle(Color.primary)
                .contentTransition(.numericText())
            Spacer()

            if !calendar.isDate(selectedDate, inSameDayAs: .now) {
                Button("Heute") { select(.now) }
                    .font(.system(size: 12, weight: .heavy))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.appPrimary)
                    .padding(.trailing, 4)
            }

            monthStepButton("chevron.left", offset: -1)
            monthStepButton("chevron.right", offset: 1)
        }
    }

    private func monthStepButton(_ icon: String, offset: Int) -> some View {
        Button {
            guard let next = calendar.date(byAdding: .month, value: offset, to: visibleMonth) else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                visibleMonth = next
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(Color.appPrimary)
                .frame(width: 34, height: 34)
                .background(Color.appPrimary.opacity(0.10), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(offset < 0 ? "Vorheriger Monat" : "Nächster Monat")
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 6) {
            ForEach(Array(gridDays.enumerated()), id: \.offset) { _, day in
                if let day {
                    dayCell(day)
                } else {
                    Color.clear.frame(height: 44)
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(day)
        let hasEvent = markedDays.contains(calendar.startOfDay(for: day))

        return Button {
            select(day)
        } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 16, weight: isSelected || isToday ? .heavy : .medium))
                    .foregroundStyle(dayColor(isSelected: isSelected, isToday: isToday))
                    .frame(width: 34, height: 34)
                    .background {
                        if isSelected {
                            Circle().fill(Color.appPrimary)
                        } else if isToday {
                            Circle().stroke(Color.appPrimary.opacity(0.45), lineWidth: 1.5)
                        }
                    }

                Circle()
                    .fill(isSelected ? Color.appPrimary : Color(hex: 0x0EA5E9))
                    .frame(width: 5, height: 5)
                    .opacity(hasEvent ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: day, hasEvent: hasEvent))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func dayColor(isSelected: Bool, isToday: Bool) -> Color {
        if isSelected { return .white }
        if isToday { return .appPrimary }
        return .primary
    }

    private func accessibilityLabel(for day: Date, hasEvent: Bool) -> String {
        let date = day.formatted(
            .dateTime.locale(Locale(identifier: "de_DE")).weekday(.wide).day().month(.wide)
        )
        return hasEvent ? "\(date), Termin vorhanden" : date
    }

    private func select(_ day: Date) {
        withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
            selectedDate = day
            visibleMonth = day
        }
    }

    private var monthTitle: String {
        visibleMonth.formatted(.dateTime.locale(Locale(identifier: "de_DE")).month(.wide).year())
    }

    private var weekdaySymbols: [String] {
        // `veryShortWeekdaySymbols` starts on Sunday; rotate to the calendar's
        // own first weekday so the columns match the grid below.
        var symbols = calendar.shortWeekdaySymbols.map { String($0.prefix(2)).uppercased() }
        let shift = calendar.firstWeekday - 1
        if shift > 0 {
            symbols = Array(symbols[shift...] + symbols[..<shift])
        }
        return symbols
    }

    /// One entry per grid slot; `nil` pads the days before the 1st.
    private var gridDays: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: visibleMonth),
              let dayCount = calendar.range(of: .day, in: .month, for: visibleMonth)?.count else {
            return []
        }
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        let days: [Date?] = (0..<dayCount).map {
            calendar.date(byAdding: .day, value: $0, to: interval.start)
        }
        return Array(repeating: nil, count: leading) + days
    }
}
