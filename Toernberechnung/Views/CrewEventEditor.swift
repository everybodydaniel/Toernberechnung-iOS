import SwiftData
import SwiftUI

struct CrewEventDraft: Equatable {
    var title: String
    var startsAt: Date
    var endsAt: Date
    var location: String
    var notes: String
    var category: CrewEventCategory
    var isAllDay: Bool
    var attendees: [String]
}

/// Bottom sheet for creating and editing an appointment. Styled with the app's
/// own card/chip language rather than a system `Form` so it matches Crewspace.
struct CrewEventEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \CrewMemberRecord.createdAt, order: .forward) private var crewMembers: [CrewMemberRecord]

    let initialDate: Date
    var event: CrewEventRecord?
    let onSave: (CrewEventDraft) -> Void
    var dismissAfterSave = true

    @State private var title = ""
    @State private var startsAt = Date()
    @State private var endsAt = Date()
    @State private var location = ""
    @State private var notes = ""
    @State private var category = CrewEventCategory.other
    @State private var isAllDay = false
    @State private var attendees: [String] = []

    private static let durationPresets: [(label: String, minutes: Int)] = [
        ("30 min", 30),
        ("1 Std", 60),
        ("2 Std", 120),
        ("4 Std", 240)
    ]

    init(
        initialDate: Date,
        event: CrewEventRecord? = nil,
        onSave: @escaping (CrewEventDraft) -> Void
    ) {
        self.initialDate = initialDate
        self.event = event
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 18) {
                        editorHeading
                        titleCard
                        categoryPicker
                    }
                    .appCardSurface(cornerRadius: 22)
                    timeCard
                    detailsCard
                    if !crewMembers.isEmpty { crewCard }
                    saveBar
                }
                .padding(16)
                .padding(.bottom, 28)
            }
            .accessibilityIdentifier("CrewEventEditorScroll")
            .scrollDismissesKeyboard(.interactively)
            .appSheetBackground {
                Color.appBackground.ignoresSafeArea()
            }
            .navigationTitle(event == nil ? "Neuer Termin" : "Termin bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Termineditor schließen")
                }
            }
        }
        .appSheetGlassBackground()
        .environment(\.locale, Locale(identifier: "de_DE"))
        .onAppear(perform: prepare)
    }

    private var editorHeading: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(event == nil ? "Termin planen" : "Termin bearbeiten")
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(Color.appPrimary)
                Text("Zeit, Ort und Crew abstimmen")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                Text(summaryTimeText)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: category.icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(category.tint)
                .frame(width: 44, height: 44)
                .appGlassIconBackground()
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: category)
    }

    private var saveBar: some View {
        VStack(spacing: 8) {
            if trimmedTitle.isEmpty {
                Text("Bitte einen Titel eingeben.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button(action: save) {
                Label(event == nil ? "Termin hinzufügen" : "Änderungen sichern", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .appProminentButton(tint: Color.appPrimary)
            .disabled(trimmedTitle.isEmpty)
        }
        .padding(.vertical, 12)
    }

    private var summaryTimeText: String {
        let day = startsAt.formatted(
            .dateTime.locale(Locale(identifier: "de_DE")).weekday(.abbreviated).day().month(.abbreviated)
        )
        guard !isAllDay else { return "\(day) · ganztägig" }
        let start = AppDateFormatters.hourMinute.string(from: startsAt)
        let end = AppDateFormatters.hourMinute.string(from: endsAt)
        return "\(day) · \(start)–\(end) Uhr"
    }

    // MARK: Cards

    private var categoryPicker: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel("ART DES TERMINS")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CrewEventCategory.allCases) { option in
                        let isSelected = option == category
                        Button {
                            withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                                applyCategory(option)
                            }
                        } label: {
                            Label(option.rawValue, systemImage: option.icon)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(isSelected ? .white : option.tint)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 10)
                                .background(isSelected ? option.tint : option.tint.opacity(0.11), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private var titleCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel("TITEL")
            TextField("z. B. Ablegen Norderney", text: $title)
                .font(.system(size: 16, weight: .semibold))
                .textInputAutocapitalization(.sentences)
                .appFieldSurface(cornerRadius: 16)
        }
    }

    private var timeCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            cardHeading("Zeit", icon: "calendar.badge.clock")

            VStack(spacing: 12) {
                Toggle(isOn: $isAllDay.animation(.spring(response: 0.28, dampingFraction: 0.86))) {
                    Label("Ganztägig", systemImage: "sun.horizon.fill")
                        .font(.system(size: 14, weight: .bold))
                }
                .tint(category.tint)

                Divider()

                HStack {
                    Text("Beginn")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    CustomCompactDatePicker(
                        selection: $startsAt,
                        components: isAllDay ? [.date] : [.date, .hourAndMinute],
                        backgroundColor: .clear
                    )
                    .fixedSize()
                }
                .onChange(of: startsAt) { _, newValue in
                    if endsAt < newValue { endsAt = newValue.addingTimeInterval(3600) }
                }

                if !isAllDay {
                    HStack {
                        Text("Ende")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        CustomCompactDatePicker(
                            selection: $endsAt,
                            components: [.date, .hourAndMinute],
                            backgroundColor: .clear
                        )
                        .fixedSize()
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Self.durationPresets, id: \.minutes) { preset in
                                let isActive = Int(endsAt.timeIntervalSince(startsAt) / 60) == preset.minutes
                                Button {
                                    withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                                        endsAt = startsAt.addingTimeInterval(TimeInterval(preset.minutes * 60))
                                    }
                                } label: {
                                    Text(preset.label)
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(isActive ? .white : Color.appPrimary)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(
                                            isActive ? Color.appPrimary : Color.appPrimary.opacity(0.11),
                                            in: Capsule()
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
            }
        }
        .appCardSurface(cornerRadius: 22)
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            cardHeading("Details", icon: "text.bubble.fill")
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.appPrimary)
                        .frame(width: 26)
                    TextField("Ort", text: $location)
                        .textInputAutocapitalization(.words)
                }
                .font(.system(size: 15, weight: .medium))

                Divider()

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.appPrimary)
                        .frame(width: 26)
                        .padding(.top, 2)
                    TextField("Notizen", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                        .textInputAutocapitalization(.sentences)
                }
                .font(.system(size: 15, weight: .medium))
            }
        }
        .appCardSurface(cornerRadius: 22)
    }

    private var crewCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                cardHeading("Wer ist dabei?", icon: "person.2.fill")
                Spacer()
                if !attendees.isEmpty {
                    Text("\(attendees.count) ausgewählt")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(crewMembers, id: \.persistentModelID) { member in
                    let role = CrewRoleOption.option(for: member.role)
                    let isSelected = attendees.contains(member.name)
                    Button {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                            toggleAttendee(member.name)
                        }
                    } label: {
                        HStack(spacing: 11) {
                            SkipperAvatarView(urlString: nil, name: member.name, diameter: 34)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(member.name)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(Color.primary)
                                Text(role.rawValue)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(role.tint)
                            }
                            Spacer()
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(isSelected ? category.tint : Color.secondary.opacity(0.4))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .appCardSurface(cornerRadius: 22)
    }

    private func cardHeading(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 17, weight: .heavy))
            .foregroundStyle(Color.appPrimary)
            .padding(.bottom, 4)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(Color.secondary)
    }

    // MARK: Behaviour

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func toggleAttendee(_ name: String) {
        if let index = attendees.firstIndex(of: name) {
            attendees.remove(at: index)
        } else {
            attendees.append(name)
        }
    }

    /// Switching the category also fills an empty title with its name, so the
    /// common "Törnstart at 14:00" case needs a single tap.
    private func applyCategory(_ option: CrewEventCategory) {
        if trimmedTitle.isEmpty || trimmedTitle == category.rawValue, option != .other {
            title = option.rawValue
        }
        category = option
    }

    private func prepare() {
        if let event {
            title = event.title
            startsAt = event.startsAt
            endsAt = event.endsAt
            location = event.location
            notes = event.notes
            category = event.resolvedCategory
            isAllDay = event.isAllDay
            attendees = event.attendees
        } else {
            // Default to the next full hour on the selected day so the picker
            // never opens on an awkward "now + seconds" value.
            let calendar = AppDateFormatters.berlinCalendar
            let hour = calendar.component(.hour, from: .now) + 1
            let start = calendar.date(
                bySettingHour: min(hour, 23),
                minute: 0,
                second: 0,
                of: initialDate
            ) ?? initialDate
            startsAt = start
            endsAt = start.addingTimeInterval(3600)
        }
    }

    private func save() {
        let calendar = AppDateFormatters.berlinCalendar
        let start = isAllDay ? calendar.startOfDay(for: startsAt) : startsAt
        let end: Date
        if isAllDay {
            end = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: start) ?? start
        } else {
            end = max(endsAt, start)
        }

        onSave(CrewEventDraft(
            title: trimmedTitle,
            startsAt: start,
            endsAt: end,
            location: location.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category,
            isAllDay: isAllDay,
            attendees: attendees
        ))
        if dismissAfterSave { dismiss() }
    }
}
