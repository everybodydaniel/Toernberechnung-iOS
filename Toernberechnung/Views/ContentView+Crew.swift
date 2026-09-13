import SwiftData
import SwiftUI
import UIKit

private extension View {
    func crewManagementListRow(bottom: CGFloat = 14) -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: bottom, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

enum CrewRoleOption: String, CaseIterable, Identifiable, Codable, Sendable {
    case skipper = "Skipper"
    case coSkipper = "Co-Skipper"
    case navigation = "Navigation"
    case watchLead = "Wachführung"
    case deck = "Deck"
    case safetyMedic = "Sicherheit/Medizin"
    case crew = "Crew"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .skipper: return "star.fill"
        case .coSkipper: return "person.badge.shield.checkmark.fill"
        case .navigation: return "location.north.line.fill"
        case .watchLead: return "clock.badge.checkmark.fill"
        case .deck: return "figure.sailing"
        case .safetyMedic: return "cross.case.fill"
        case .crew: return "person.2.fill"
        }
    }

    var tint: Color {
        switch self {
        case .skipper: return Color.appPrimary
        case .coSkipper: return Color(hex: 0x3C82FF)
        case .navigation: return Color(hex: 0x0D9488)
        case .watchLead: return Color(hex: 0x7C3AED)
        case .deck: return Color(hex: 0xF59E0B)
        case .safetyMedic: return Color(hex: 0xE11D48)
        case .crew: return Color(hex: 0x64748B)
        }
    }

    var shortLabel: String {
        switch self {
        case .safetyMedic: return "Medizin"
        case .watchLead: return "Wache"
        default: return rawValue
        }
    }

    static func option(for role: String) -> CrewRoleOption {
        allCases.first { $0.rawValue == role } ?? .crew
    }

    static func normalizedRole(_ role: String) -> String {
        option(for: role).rawValue
    }
}

extension ContentView {
    func crewTab() -> some View {
        CrewspaceView(topContentInset: isPad ? 94 : 78, headerVisible: $crewHeaderVisible)
    }

    func crewSummaryText() -> String {
        crewMembers
            .filter(\.isOnBoard)
            .map { "\($0.name) (\(CrewRoleOption.normalizedRole($0.role)))" }
            .joined(separator: ", ")
    }
}

enum CrewspaceSection: String, CaseIterable, Identifiable {
    case crew = "Crew"
    case planning = "Planung"

    var id: Self { self }

    var icon: String {
        switch self {
        case .crew: return "person.3.fill"
        case .planning: return "calendar"
        }
    }
}

/// Crewspace is fully local: the crew roster and the appointments both live in
/// SwiftData on this device. There is no account and nothing leaves the phone.
struct CrewspaceView: View {
    let topContentInset: CGFloat
    @Binding var headerVisible: Bool
    @State private var section: CrewspaceSection = .crew

    var body: some View {
        Group {
            switch section {
            case .crew:
                CrewspaceCrewView(section: $section, headerVisible: $headerVisible, topContentInset: topContentInset)
            case .planning:
                CrewPlanningView(section: $section, headerVisible: $headerVisible, topContentInset: topContentInset)
            }
        }
        .background(Color.appBackground.ignoresSafeArea())
        .environment(\.locale, Locale(identifier: "de_DE"))
    }

}

/// A normal list row, so the title and section control scroll with the content.
struct CrewspaceScrollingHeader: View {
    @Binding var section: CrewspaceSection

    var body: some View {
        VStack(spacing: 0) {
            crewspaceHeader
            sectionPicker
        }
    }

    private var crewspaceHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Crewspace")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(Color.appPrimary)
                Text("Crew und Termine an einem Ort")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.secondary)
            }
            Spacer()
        }
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var sectionPicker: some View {
        HStack(spacing: 6) {
            ForEach(CrewspaceSection.allCases) { item in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { section = item }
                } label: {
                    Label(item.rawValue, systemImage: item.icon)
                        .font(.system(size: 12, weight: .heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(section == item ? .white : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(section == item ? Color.appPrimary : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("CrewspaceSection\(item.rawValue)")
            }
        }
        .padding(5)
        .appFloatingOverlay(cornerRadius: 24)
        .padding(.bottom, 10)
    }
}

struct CrewspaceCrewView: View {
    @Binding var section: CrewspaceSection
    @Binding var headerVisible: Bool
    let topContentInset: CGFloat
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CrewMemberRecord.createdAt, order: .forward) private var crewMembers: [CrewMemberRecord]

    @State private var deleteErrorMessage: String?

    var body: some View {
        List {
            CrewspaceScrollingHeader(section: $section)
                .crewManagementListRow(bottom: 0)

            crewOverviewCard
                .crewManagementListRow()

            CrewMemberForm()
                .crewManagementListRow()

            memberListHeader
                .crewManagementListRow(bottom: 8)

            if crewMembers.isEmpty {
                memberListEmptyState
                    .crewManagementListRow()
            } else {
                ForEach(crewMembers, id: \.persistentModelID) { member in
                    localMemberRow(member)
                        .padding(18)
                        .appFloatingOverlay(cornerRadius: 26)
                        .crewManagementListRow(bottom: 10)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                    _ = deleteCrewMember(member)
                                }
                            } label: {
                                Label("Löschen", systemImage: "trash.fill")
                            }
                            .tint(.red)
                        }
                }
            }
        }
        .tracksAppHeaderVisibility($headerVisible)
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, topContentInset, for: .scrollContent)
        .contentMargins(.bottom, 28, for: .scrollContent)
        .alert(
            "Löschen fehlgeschlagen",
            isPresented: Binding(
                get: { deleteErrorMessage != nil },
                set: { isPresented in
                    if !isPresented { deleteErrorMessage = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                deleteErrorMessage = nil
            }
        } message: {
            Text(deleteErrorMessage ?? "Das Crewmitglied konnte nicht gelöscht werden.")
        }
    }

    private var onboardMembers: [CrewMemberRecord] {
        crewMembers.filter(\.isOnBoard)
    }

    private var crewOverviewCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(onboardMembers.count) an Bord")
                        .font(.system(size: 28, weight: .heavy))
                        .foregroundStyle(Color.appPrimary)
                        .contentTransition(.numericText())
                    Text("\(crewMembers.count) \(crewMembers.count == 1 ? "Crewmitglied" : "Crewmitglieder")")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }
                Spacer()
                Image(systemName: onboardMembers.isEmpty ? "person.slash.fill" : "checkmark.seal.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(onboardMembers.isEmpty ? Color.secondary : Color.green)
            }

            if onboardMembers.isEmpty {
                Text("Aktuell ist niemand an Bord.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(CrewRoleOption.allCases) { role in
                            let count = onboardMembers.filter { CrewRoleOption.option(for: $0.role) == role }.count
                            if count > 0 {
                                Label("\(role.shortLabel) \(count)", systemImage: role.icon)
                                    .font(.system(size: 12, weight: .heavy))
                                    .foregroundStyle(role.tint)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 8)
                                    .background(role.tint.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
        .appFloatingOverlay(cornerRadius: 26)
        .animation(.spring(response: 0.32, dampingFraction: 0.84), value: onboardMembers.count)
    }

    private var memberListHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Crew")
                .font(.system(size: 19, weight: .heavy))
            Spacer()
            Text("\(crewMembers.count)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.secondary)
        }
        .padding(.horizontal, 4)
    }

    private var memberListEmptyState: some View {
        Text("Noch keine Crewmitglieder hinzugefügt.")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .appFloatingOverlay(cornerRadius: 26)
    }

    private func localMemberRow(_ member: CrewMemberRecord) -> some View {
        let role = CrewRoleOption.option(for: member.role)
        return HStack(spacing: 12) {
            SkipperAvatarView(urlString: nil, name: member.name, diameter: 46)

            VStack(alignment: .leading, spacing: 5) {
                Text(member.name)
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Color.primary)
                Menu {
                    ForEach(CrewRoleOption.allCases) { option in
                        Button {
                            member.role = option.rawValue
                            try? modelContext.save()
                        } label: {
                            if option == role {
                                Label(option.rawValue, systemImage: "checkmark")
                            } else {
                                Text(option.rawValue)
                            }
                        }
                    }
                } label: {
                    Label(role.rawValue, systemImage: role.icon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(role.tint)
                }
            }

            Spacer()

            onboardIndicator(for: member)
        }
    }

    private func onboardIndicator(for member: CrewMemberRecord) -> some View {
        let tint: Color = member.isOnBoard ? .green : .red

        return Button {
            member.isOnBoard.toggle()
            try? modelContext.save()
        } label: {
            Circle()
                .fill(tint.gradient)
                .frame(width: 26, height: 26)
                .overlay {
                    Circle()
                        .strokeBorder(.white.opacity(0.65), lineWidth: 2)
                }
                .shadow(color: tint.opacity(0.45), radius: 6)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.10), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Bordstatus von \(member.name)")
        .accessibilityValue(member.isOnBoard ? "An Bord" : "Nicht an Bord")
        .accessibilityHint(member.isOnBoard ? "Als nicht an Bord markieren" : "Als an Bord markieren")
    }

    @MainActor
    private func deleteCrewMember(_ member: CrewMemberRecord) -> Bool {
        let name = member.name
        do {
            modelContext.delete(member)
            modelContext.insert(AuditLog(
                action: "DELETE",
                source: "crew",
                statement: "DELETE FROM crew WHERE name = '\(name)'",
                status: "ok"
            ))
            try modelContext.save()
            deleteErrorMessage = nil
            return true
        } catch {
            modelContext.rollback()
            deleteErrorMessage = "Crewmitglied konnte nicht gelöscht werden: \(error.localizedDescription)"
            return false
        }
    }
}

/// Shared by Crewspace and Nauti so fields, defaults and validation stay identical.
struct CrewMemberForm: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CrewMemberRecord.createdAt) private var crewMembers: [CrewMemberRecord]
    var onSave: (String) -> Void = { _ in }
    @State private var name = ""
    @State private var selectedRole = CrewRoleOption.deck
    @State private var emergencyContact = ""
    @State private var emergencyPhone = ""
    @State private var notes = ""
    @State private var errorMessage: String?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.appPrimary)
                    .frame(width: 38, height: 38)
                    .background(Color.appPrimary.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Crewmitglied hinzufügen")
                        .font(.system(size: 18, weight: .heavy))
                    Text("Name, Rolle und Hinweise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("NAME")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(Color.secondary)
                crewTextField("Name", text: $name, capitalization: .words)
            }

            Text("ROLLE")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(Color.secondary)
            roleSelector(selection: $selectedRole)

            crewTextField("Notfallkontakt", text: $emergencyContact, capitalization: .words)
            crewTextField("Telefon", text: $emergencyPhone, keyboard: .phonePad)
            crewTextField("Medizinische Hinweise / Notizen", text: $notes, capitalization: .sentences)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.orange)
            }

            Button {
                addCrewMember()
            } label: {
                Label("Hinzufügen", systemImage: "plus")
                    .font(.system(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(.vertical, 14)
            .background(
                Color.appPrimary.opacity(trimmedName.isEmpty ? 0.45 : 1),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .disabled(trimmedName.isEmpty)
        }
        .padding(18)
        .appFloatingOverlay(cornerRadius: 26)
    }

    private func roleSelector(selection: Binding<CrewRoleOption>) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CrewRoleOption.allCases) { option in
                    let isSelected = selection.wrappedValue == option
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                            selection.wrappedValue = option
                        }
                    } label: {
                        Label(option.shortLabel, systemImage: option.icon)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(isSelected ? .white : option.tint)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(isSelected ? option.tint : option.tint.opacity(0.11), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func crewTextField(
        _ title: String,
        text: Binding<String>,
        keyboard: UIKeyboardType = .default,
        capitalization: TextInputAutocapitalization = .sentences
    ) -> some View {
        TextField(title, text: text)
            .keyboardType(keyboard)
            .textInputAutocapitalization(capitalization)
            .font(.system(size: 15, weight: .medium))
            .appFieldSurface(cornerRadius: 16)
    }

    @MainActor
    private func addCrewMember() {
        let name = trimmedName
        guard !name.isEmpty else { return }
        guard !crewMembers.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            errorMessage = "Ein Crewmitglied mit diesem Namen gibt es bereits."
            return
        }

        let record = CrewMemberRecord(
            name: name,
            role: selectedRole.rawValue,
            emergencyContact: emergencyContact.trimmingCharacters(in: .whitespacesAndNewlines),
            emergencyPhone: emergencyPhone.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            isOnBoard: true
        )
        modelContext.insert(record)
        let audit = AuditLog(
            action: "INSERT",
            source: "crew",
            statement: "INSERT INTO crew(name, role, is_on_board) VALUES ('\(name)', '\(selectedRole.rawValue)', true)",
            status: "ok"
        )
        modelContext.insert(audit)
        do {
            try modelContext.save()
        } catch {
            modelContext.delete(record)
            modelContext.delete(audit)
            errorMessage = "Das Crewmitglied konnte nicht gespeichert werden. Bitte versuche es erneut."
            return
        }
        onSave(name)

        self.name = ""
        selectedRole = .deck
        emergencyContact = ""
        emergencyPhone = ""
        notes = ""
        errorMessage = nil
    }

}
