import EventKit
import EventKitUI
import SwiftUI

struct CrewEventShareView: View {
    @Environment(\.dismiss) private var dismiss
    let event: CrewCalendarExport
    @State private var previewImage = Image(systemName: "calendar")
    @State private var calendarEditorShown = false
    @State private var addedToCalendar = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    CrewEventInvitationCard(event: event)
                    Label("Im eigenen Kalender speichern oder als Kalendereintrag weitergeben.", systemImage: "calendar.badge.plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                }
                .padding(20)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Termin teilen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Teilenvorschau schließen")
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    Button {
                        calendarEditorShown = true
                    } label: {
                        Label(
                            addedToCalendar ? "Im Kalender gespeichert" : "Zum Kalender hinzufügen",
                            systemImage: addedToCalendar ? "checkmark.circle.fill" : "calendar.badge.plus"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .appProminentButton(tint: Color.appPrimary)
                    .disabled(addedToCalendar)

                    ShareLink(
                        item: event,
                        preview: SharePreview(event.title, image: previewImage)
                    ) {
                        Label("Kalendereintrag teilen", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .appGlassButton(tint: Color.appPrimary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.regularMaterial)
            }
        }
        .environment(\.locale, Locale(identifier: "de_DE"))
        .sheet(isPresented: $calendarEditorShown) {
            CrewNativeCalendarEditor(event: event) { saved in
                if saved { addedToCalendar = true }
                calendarEditorShown = false
            }
            .presentationDetents([.large])
        }
        .onAppear {
            let renderer = ImageRenderer(content:
                CrewEventInvitationCard(event: event)
                    .frame(width: 340)
                    .environment(\.colorScheme, .light)
            )
            renderer.scale = 2
            if let image = renderer.uiImage { previewImage = Image(uiImage: image) }
        }
    }
}

/// EventKitUI lässt den Nutzer Kalender und Speicherung wählen. Ab iOS 17
/// braucht dieser Editor keine Kalenderleseberechtigung und legt vorhandene Termine nicht offen.
private struct CrewNativeCalendarEditor: UIViewControllerRepresentable {
    let event: CrewCalendarExport
    let onComplete: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let editor = EKEventEditViewController()
        let store = context.coordinator.store
        editor.eventStore = store
        editor.editViewDelegate = context.coordinator

        let calendarEvent = EKEvent(eventStore: store)
        calendarEvent.title = event.title
        calendarEvent.location = event.location
        calendarEvent.isAllDay = event.isAllDay
        if event.isAllDay {
            let calendar = AppDateFormatters.berlinCalendar
            calendarEvent.startDate = calendar.startOfDay(for: event.startsAt)
            let lastDay = calendar.startOfDay(for: max(event.startsAt, event.endsAt))
            calendarEvent.endDate = calendar.date(byAdding: .day, value: 1, to: lastDay)
        } else {
            calendarEvent.timeZone = AppDateFormatters.berlinTimeZone
            calendarEvent.startDate = event.startsAt
            calendarEvent.endDate = event.endsAt > event.startsAt ? event.endsAt : event.startsAt.addingTimeInterval(60)
        }
        var notes = [event.category]
        if !event.notes.isEmpty { notes.append(event.notes) }
        if !event.attendees.isEmpty { notes.append("Crew: \(event.attendees.joined(separator: ", "))") }
        notes.append("Geplant mit TideNode · Crewspace")
        calendarEvent.notes = notes.joined(separator: "\n\n")
        editor.event = calendarEvent
        return editor
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let store = EKEventStore()
        let onComplete: (Bool) -> Void

        init(onComplete: @escaping (Bool) -> Void) { self.onComplete = onComplete }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            onComplete(action == .saved)
        }
    }
}

private struct CrewEventInvitationCard: View {
    let event: CrewCalendarExport

    private var category: CrewEventCategory { .resolved(event.category) }
    private var calendar: Calendar { AppDateFormatters.berlinCalendar }
    private var dateText: String {
        event.startsAt.formatted(
            Date.FormatStyle(date: .complete, time: .omitted, locale: Locale(identifier: "de_DE"),
                             calendar: calendar, timeZone: calendar.timeZone)
        )
    }
    private var timeText: String {
        if event.isAllDay { return "Ganztägig" }
        let start = AppDateFormatters.hourMinute.string(from: event.startsAt)
        let end = AppDateFormatters.hourMinute.string(from: event.endsAt)
        if calendar.isDate(event.startsAt, inSameDayAs: event.endsAt) {
            return "\(start)–\(end) Uhr"
        }
        let endDay = event.endsAt.formatted(
            Date.FormatStyle(date: .numeric, time: .omitted, locale: Locale(identifier: "de_DE"),
                             calendar: calendar, timeZone: calendar.timeZone)
        )
        return "\(start) Uhr bis \(endDay), \(end) Uhr"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TideNode")
                            .font(.system(size: 14, weight: .heavy))
                        Text("CREWSPACE · TERMIN")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(1.5)
                            .opacity(0.8)
                    }
                    Spacer()
                    Image(systemName: category.icon)
                        .font(.system(size: 25, weight: .semibold))
                        .frame(width: 54, height: 54)
                        .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 18))
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text(category.rawValue.uppercased())
                        .font(.system(size: 10, weight: .heavy))
                        .tracking(1.4)
                        .opacity(0.8)
                    Text(event.title)
                        .font(.system(size: 29, weight: .heavy))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(.white)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(
                colors: [Color(hex: 0x17386D), Color(hex: 0x0077B6)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))

            VStack(alignment: .leading, spacing: 20) {
                detail("calendar", title: dateText, subtitle: timeText)
                if !event.location.isEmpty {
                    Divider()
                    detail("mappin.and.ellipse", title: "Treffpunkt", subtitle: event.location)
                }
                if !event.attendees.isEmpty {
                    Divider()
                    detail("person.2.fill", title: "Mit dabei", subtitle: event.attendees.joined(separator: ", "))
                }
                if !event.notes.isEmpty {
                    Divider()
                    detail("text.alignleft", title: "Gut zu wissen", subtitle: event.notes)
                }
                HStack(spacing: 6) {
                    Image(systemName: "water.waves")
                    Text("Geplant mit TideNode")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(.white.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 16, y: 8)
    }

    private func detail(_ icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.appPrimary)
                .frame(width: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
