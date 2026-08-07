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
        CrewspaceView(onOpenSettings: { settingsShown = true })
    }

    func crewSummaryText() -> String {
        crewMembers
            .filter { $0.conversationID.isEmpty && $0.isOnBoard }
            .map { "\($0.name) (\(CrewRoleOption.normalizedRole($0.role)))" }
            .joined(separator: ", ")
    }
}

struct CrewspaceCrewView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CrewMemberRecord.createdAt, order: .forward) private var cachedMembers: [CrewMemberRecord]

    let groups: [CrewspaceConversationDTO]
    let api: CrewspaceAPI
    let onCreateGroup: () -> Void
    let onGroupChanged: () -> Void

    @State private var skipperID = ""
    @State private var foundSkipper: CrewspaceSkipperDTO?
    @State private var selectedRole = CrewRoleOption.deck
    @State private var emergencyContact = ""
    @State private var emergencyPhone = ""
    @State private var notes = ""
    @State private var isFinding = false
    @State private var errorMessage: String?
    @State private var deleteErrorMessage: String?

    var body: some View {
        List {
            crewOverviewCard
                .crewManagementListRow()

            addCrewMemberCard
                .crewManagementListRow()

            memberListHeader
                .crewManagementListRow(bottom: 8)

            if localCrewMembers.isEmpty {
                memberListEmptyState
                    .crewManagementListRow()
            } else {
                ForEach(localCrewMembers, id: \.persistentModelID) { member in
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
                        }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 6, for: .scrollContent)
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

    private var localCrewMembers: [CrewMemberRecord] {
        cachedMembers.filter(\.conversationID.isEmpty)
    }

    private var onboardMembers: [CrewMemberRecord] {
        localCrewMembers.filter(\.isOnBoard)
    }

    private var crewOverviewCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(onboardMembers.count) an Bord")
                        .font(.system(size: 28, weight: .heavy))
                        .foregroundStyle(Color.appPrimary)
                        .contentTransition(.numericText())
                    Text("\(localCrewMembers.count) Crewmitglieder")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }
                Spacer()
                Image(systemName: onboardMembers.isEmpty ? "person.slash.fill" : "checkmark.seal.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(onboardMembers.isEmpty ? Color.secondary : Color.green)
            }

            if onboardMembers.isEmpty {
                Text("Aktuell ist niemand als an Bord markiert.")
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

    private var addCrewMemberCard: some View {
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
                    Text("Skipper-ID, Rolle und Hinweise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("SKIPPER-ID")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(Color.secondary)
                HStack(spacing: 9) {
                    TextField("Skipper-ID", text: $skipperID)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button { Task { await findSkipper() } } label: {
                        if isFinding {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 38, height: 38)
                        } else {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Color.appPrimary)
                                .frame(width: 38, height: 38)
                        }
                    }
                    .disabled(isFinding)
                    .buttonStyle(.plain)
                }
                .appFieldSurface(cornerRadius: 17)
            }

            if let foundSkipper {
                HStack(spacing: 12) {
                    SkipperAvatarView(urlString: foundSkipper.profileImageURL, name: foundSkipper.name, diameter: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(foundSkipper.name)
                            .font(.system(size: 16, weight: .heavy))
                        Text(foundSkipper.homeHarbour?.nilIfEmpty ?? "Über Skipper-ID gefunden")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(Color.fieldBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
            .background(Color.appPrimary.opacity(foundSkipper == nil ? 0.45 : 1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .disabled(foundSkipper == nil)
        }
        .padding(18)
        .appFloatingOverlay(cornerRadius: 26)
    }

    private var memberListHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Crew")
                .font(.system(size: 19, weight: .heavy))
            Spacer()
            Text("\(localCrewMembers.count)")
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

            Toggle("An Bord", isOn: Binding(
                get: { member.isOnBoard },
                set: {
                    member.isOnBoard = $0
                    try? modelContext.save()
                }
            ))
            .labelsHidden()
            .tint(role.tint)
        }
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
    private func findSkipper() async {
        let id = skipperID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        if localCrewMembers.contains(where: { $0.skipperID == id }) {
            errorMessage = "Diese Skipper-ID ist bereits in der Crew."
            foundSkipper = nil
            return
        }
        isFinding = true
        defer { isFinding = false }
        do {
            foundSkipper = try await api.skipper(id: id)
            errorMessage = nil
        } catch {
            foundSkipper = nil
            errorMessage = "Unter dieser Skipper-ID wurde kein Profil gefunden."
        }
    }

    @MainActor
    private func addCrewMember() {
        guard let foundSkipper else { return }
        let record = CrewMemberRecord(
            skipperID: foundSkipper.id,
            conversationID: "",
            name: foundSkipper.name,
            role: selectedRole.rawValue,
            emergencyContact: emergencyContact.trimmingCharacters(in: .whitespacesAndNewlines),
            emergencyPhone: emergencyPhone.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            isOnBoard: false
        )
        modelContext.insert(record)
        modelContext.insert(AuditLog(
            action: "INSERT",
            source: "crew",
            statement: "INSERT INTO crew(skipper_id, role, is_on_board) VALUES ('\(foundSkipper.id)', '\(selectedRole.rawValue)', false)",
            status: "ok"
        ))
        try? modelContext.save()

        skipperID = ""
        self.foundSkipper = nil
        selectedRole = .deck
        emergencyContact = ""
        emergencyPhone = ""
        notes = ""
        errorMessage = nil
    }

    @MainActor
    private func deleteCrewMember(_ member: CrewMemberRecord) -> Bool {
        let id = member.skipperID
        do {
            modelContext.delete(member)
            modelContext.insert(AuditLog(
                action: "DELETE",
                source: "crew",
                statement: "DELETE FROM crew WHERE skipper_id = '\(id)'",
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

struct CrewspaceGroupInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SocialAuthViewModel.self) private var auth

    let conversationID: String
    let api: CrewspaceAPI
    let onChanged: (CrewspaceGroupInfoDTO) -> Void

    @State private var group: CrewspaceGroupInfoDTO?
    @State private var title = ""
    @State private var infoText = ""
    @State private var isEditing = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var addMemberShown = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let group {
                        groupHeader(group)
                        groupMembers(group)
                    } else if isWorking {
                        ProgressView("Gruppeninfo wird geladen …")
                            .frame(maxWidth: .infinity, minHeight: 260)
                    }

                    if let errorMessage {
                        CrewspaceGroupLoadFailure(message: errorMessage) {
                            Task { await load() }
                        }
                    }
                }
                .padding(16)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Gruppeninfo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                        .appGlassButton(tint: Color.appPrimary)
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $addMemberShown) {
            CrewspaceAddMemberSheet(api: api, conversationID: conversationID) { updated in
                apply(updated)
                addMemberShown = false
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(Color.white)
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(30)
        }
    }

    private func groupHeader(_ group: CrewspaceGroupInfoDTO) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.appPrimary.opacity(0.13))
                Image(systemName: "person.3.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Color.appPrimary)
            }
            .frame(width: 78, height: 78)

            if isEditing {
                TextField("Gruppenname", text: $title)
                    .font(.system(size: 20, weight: .heavy))
                    .multilineTextAlignment(.center)
                    .appFieldSurface(cornerRadius: 16)
                TextField("Info zur Gruppe", text: $infoText, axis: .vertical)
                    .lineLimit(2...5)
                    .appFieldSurface(cornerRadius: 16)
                HStack {
                    Button("Abbrechen") {
                        title = group.title
                        infoText = group.info
                        isEditing = false
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button("Speichern") { Task { await save() } }
                        .buttonStyle(.plain)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.appPrimary)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                }
            } else {
                Text(group.title)
                    .font(.system(size: 25, weight: .heavy))
                    .multilineTextAlignment(.center)
                Text(group.info.isEmpty ? "Keine Gruppeninfo hinterlegt" : group.info)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
                if group.canManage {
                    Button {
                        title = group.title
                        infoText = group.info
                        isEditing = true
                    } label: {
                        Label("Gruppeninfo bearbeiten", systemImage: "pencil")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.appPrimary)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .appFloatingOverlay(cornerRadius: 28)
    }

    private func groupMembers(_ group: CrewspaceGroupInfoDTO) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(group.members.count) Mitglieder")
                    .font(.system(size: 18, weight: .heavy))
                Spacer()
                if group.canManage {
                    Button { addMemberShown = true } label: {
                        Image(systemName: "person.badge.plus")
                            .foregroundStyle(Color.appPrimary)
                            .appCircularGlass(diameter: 40)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 8)

            ForEach(Array(group.members.enumerated()), id: \.element.id) { index, member in
                if index > 0 { Divider().opacity(0.45) }
                HStack(spacing: 12) {
                    SkipperAvatarView(urlString: member.profileImageURL, name: member.name, diameter: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(member.name)
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundStyle(Color.primary)
                        Text("\(member.crewRole) · \(member.isOnBoard ? "An Bord" : "Nicht an Bord")")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.secondary)
                    }
                    Spacer()
                    if member.isOwner {
                        Text("Admin")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.appPrimary)
                    }
                }
                .padding(.vertical, 11)
            }
        }
        .padding(18)
        .appFloatingOverlay(cornerRadius: 26)
    }

    @MainActor
    private func load() async {
        isWorking = true
        defer { isWorking = false }
        do {
            apply(try await api.groupInfo(conversationID: conversationID))
            errorMessage = nil
        } catch {
            errorMessage = crewspaceGroupErrorText(error)
        }
    }

    @MainActor
    private func save() async {
        isWorking = true
        defer { isWorking = false }
        do {
            apply(try await api.updateGroupInfo(
                conversationID: conversationID,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                info: infoText.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            isEditing = false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func apply(_ updated: CrewspaceGroupInfoDTO) {
        group = updated
        title = updated.title
        infoText = updated.info
        onChanged(updated)
    }
}

private struct CrewspaceGroupLoadFailure: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.3.sequence.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.orange)
            Text("Gruppeninfo nicht verfügbar")
                .font(.system(size: 17, weight: .heavy))
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
            Button(action: retry) {
                Label("Erneut versuchen", systemImage: "arrow.clockwise")
                    .font(.system(size: 13, weight: .bold))
            }
            .appGlassButton(tint: Color.appPrimary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 190)
        .appFloatingOverlay(cornerRadius: 24)
    }
}

private func crewspaceGroupErrorText(_ error: Error) -> String {
    guard let apiError = error as? SocialFeedAPIError,
          apiError.httpStatusCode == 404 else {
        return error.localizedDescription
    }
    let message = apiError.responseMessage?.lowercased() ?? ""
    if message.contains("gruppe nicht gefunden") || message.contains("kein zugriff") {
        return "Diese Gruppe ist nicht mehr verfügbar oder du bist kein Mitglied mehr. Crewspace wird aktualisiert."
    }
    return "Die Gruppenfunktionen fehlen auf der aktuell installierten Serverversion. Aktualisiere den TideNode-Server und versuche es erneut."
}

private struct CrewspaceAddMemberSheet: View {
    @Environment(\.dismiss) private var dismiss

    let api: CrewspaceAPI
    let conversationID: String
    let onSaved: (CrewspaceGroupInfoDTO) -> Void

    @State private var skipperID = ""
    @State private var foundSkipper: CrewspaceSkipperDTO?
    @State private var selectedRole = CrewRoleOption.crew
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Crewmitglied über Skipper-ID")
                        .font(.system(size: 23, weight: .heavy))
                    Text("Die ID wird nur zur eindeutigen Zuordnung genutzt. Im Crewspace erscheint anschließend der aktuelle Profilname.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.secondary)

                    HStack(spacing: 9) {
                        TextField("Skipper-ID", text: $skipperID)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button { Task { await find() } } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Color.appPrimary)
                                .frame(width: 38, height: 38)
                        }
                        .buttonStyle(.plain)
                    }
                    .appFieldSurface(cornerRadius: 17)

                    if let foundSkipper {
                        HStack(spacing: 12) {
                            SkipperAvatarView(
                                urlString: foundSkipper.profileImageURL,
                                name: foundSkipper.name,
                                diameter: 52
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(foundSkipper.name)
                                    .font(.system(size: 17, weight: .heavy))
                                Text(foundSkipper.homeHarbour?.nilIfEmpty ?? "Crewspace-Profil")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.secondary)
                            }
                        }
                        .padding(15)
                        .appFloatingOverlay(cornerRadius: 22)

                        Text("ROLLE AN BORD")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(Color.secondary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(CrewRoleOption.allCases) { role in
                                    Button {
                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                            selectedRole = role
                                        }
                                    } label: {
                                        Label(role.shortLabel, systemImage: role.icon)
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(selectedRole == role ? .white : role.tint)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 10)
                                            .background(
                                                selectedRole == role ? role.tint : role.tint.opacity(0.11),
                                                in: Capsule()
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        Button { Task { await save() } } label: {
                            if isWorking {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Zur Crewgruppe hinzufügen", systemImage: "person.badge.plus")
                            }
                        }
                        .disabled(isWorking)
                        .appProminentButton(tint: Color.appPrimary)
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.orange)
                    }
                }
                .padding(18)
            }
            .background(Color.white.ignoresSafeArea())
            .toolbarBackground(Color.white, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                        .appGlassButton(tint: Color.appPrimary)
                }
            }
        }
        .background(Color.white.ignoresSafeArea())
        .preferredColorScheme(.light)
    }

    @MainActor
    private func find() async {
        let id = skipperID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            foundSkipper = try await api.skipper(id: id)
            errorMessage = nil
        } catch {
            foundSkipper = nil
            errorMessage = "Unter dieser Skipper-ID wurde kein Profil gefunden."
        }
    }

    @MainActor
    private func save() async {
        guard let foundSkipper else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            onSaved(try await api.addGroupMember(
                conversationID: conversationID,
                skipperID: foundSkipper.id,
                crewRole: selectedRole.rawValue,
                isOnBoard: false
            ))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
