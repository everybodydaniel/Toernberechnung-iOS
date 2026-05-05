import SwiftUI
import UIKit

enum CrewRoleOption: String, CaseIterable, Identifiable {
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

    var description: String {
        switch self {
        case .skipper: return "Entscheidung"
        case .coSkipper: return "Vertretung"
        case .navigation: return "Route"
        case .watchLead: return "Wache"
        case .deck: return "Manöver"
        case .safetyMedic: return "Notfall"
        case .crew: return "An Bord"
        }
    }

    static func option(for role: String) -> CrewRoleOption {
        allCases.first { $0.rawValue == role } ?? {
            switch role {
            case "Maschine", "Fahrer", "Gast":
                return .crew
            case "Medizin":
                return .safetyMedic
            default:
                return .crew
            }
        }()
    }

    static func normalizedRole(_ role: String) -> String {
        option(for: role).rawValue
    }
}

extension ContentView {
    func crewTab() -> some View {
        let onboardCount = crewMembers.filter(\.isOnBoard).count

        return VStack(alignment: .leading, spacing: 12) {
            crewOverviewCard(onboardCount: onboardCount)

            crewGlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x3C82FF))
                            .frame(width: 36, height: 36)
                            .background(Color(hex: 0x3C82FF).opacity(0.12))
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Crewmitglied hinzufügen")
                                .font(.system(size: 18, weight: .bold))
                            Text("Rolle, Notfallkontakt und Hinweise")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.secondary)
                        }
                    }

                    crewTextField("Name", text: $newCrewName, capitalization: .words)

                    crewRoleSelector(selection: $newCrewRole)

                    LazyVGrid(columns: compactColumns, spacing: 10) {
                        crewTextField("Notfallkontakt", text: $newCrewEmergencyContact, capitalization: .words)
                        crewTextField("Telefon", text: $newCrewEmergencyPhone, keyboard: .phonePad)
                    }

                    crewTextField("Medizinische Hinweise / Notizen", text: $newCrewNotes, capitalization: .sentences)

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
                        LinearGradient(
                            colors: [Color.appPrimary, Color(hex: 0x3C82FF)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: Color(hex: 0x3C82FF).opacity(0.22), radius: 14, y: 8)
                    .opacity(newCrewName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)
                    .disabled(newCrewName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            ForEach(crewMembers) { member in
                SwipeDeleteRow(deleteAction: { deleteCrewMember(member) }) {
                    crewGlassCard {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 14) {
                                let roleOption = CrewRoleOption.option(for: member.role)
                                ZStack {
                                    Circle()
                                        .fill(roleOption.tint.opacity(member.isOnBoard ? 0.18 : 0.08))
                                    Image(systemName: roleOption.icon)
                                        .font(.system(size: 21, weight: .bold))
                                        .foregroundStyle(member.isOnBoard ? roleOption.tint : Color.secondary)
                                }
                                .frame(width: 52, height: 52)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(member.name)
                                        .font(.system(size: 20, weight: .bold))
                                    HStack(spacing: 6) {
                                        Text(roleOption.rawValue)
                                            .font(.system(size: 15, weight: .semibold))
                                        Text(member.isOnBoard ? "An Bord" : "Nicht an Bord")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(member.isOnBoard ? Color(hex: 0x0D9488) : Color.secondary)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background((member.isOnBoard ? Color(hex: 0x0D9488) : Color.gray).opacity(0.12))
                                            .clipShape(Capsule())
                                    }
                                    .foregroundStyle(Color.secondary)
                                }
                                Spacer()
                                Toggle("An Bord", isOn: Binding(
                                    get: { member.isOnBoard },
                                    set: { member.isOnBoard = $0; try? modelContext.save() }
                                ))
                                .labelsHidden()
                                .tint(roleOption.tint)
                            }

                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 12) {
                                    crewRoleSelector(selection: Binding(
                                        get: { CrewRoleOption.normalizedRole(member.role) },
                                        set: { member.role = $0; try? modelContext.save() }
                                    ))

                                    LazyVGrid(columns: compactColumns, spacing: 10) {
                                        crewDetailField("Notfallkontakt", text: Binding(
                                            get: { member.emergencyContact },
                                            set: { member.emergencyContact = $0; try? modelContext.save() }
                                        ))
                                        crewDetailField("Telefon", text: Binding(
                                            get: { member.emergencyPhone },
                                            set: { member.emergencyPhone = $0; try? modelContext.save() }
                                        ), keyboard: .phonePad)
                                    }

                                    crewDetailField("Notizen", text: Binding(
                                        get: { member.notes },
                                        set: { member.notes = $0; try? modelContext.save() }
                                    ))
                                }
                                .padding(.top, 10)
                            } label: {
                                Label("Details bearbeiten", systemImage: "slider.horizontal.3")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(Color.appPrimary)
                            }
                            .tint(Color.appPrimary)
                        }
                    }
                }
            }
        }
    }

    func crewOverviewCard(onboardCount: Int) -> some View {
        let roleCounts = crewOnboardRoleCounts()

        return crewGlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("\(onboardCount) von \(crewMembers.count) an Bord")
                        .font(.system(size: 24, weight: .heavy))
                        .foregroundStyle(Color.appPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .contentTransition(.numericText())

                    Spacer()
                }

                if roleCounts.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "person.slash.fill")
                            .font(.system(size: 16, weight: .bold))
                        Text("Keine Crew an Bord")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(roleCounts, id: \.role.id) { item in
                                crewRoleCountChip(role: item.role, count: item.count)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: onboardCount)
        }
    }

    func crewOnboardRoleCounts() -> [(role: CrewRoleOption, count: Int)] {
        CrewRoleOption.allCases.compactMap { role in
            let count = crewMembers.filter {
                $0.isOnBoard && CrewRoleOption.option(for: $0.role) == role
            }.count
            return count > 0 ? (role, count) : nil
        }
    }

    func crewRoleCountChip(role: CrewRoleOption, count: Int) -> some View {
        HStack(spacing: 9) {
            Image(systemName: role.icon)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 28, height: 28)
                .background(role.tint.opacity(0.14))
                .clipShape(Circle())

            Text(role.shortLabel)
                .font(.system(size: 13, weight: .bold))

            Text("\(count)")
                .font(.system(size: 13, weight: .heavy))
                .contentTransition(.numericText())
                .foregroundStyle(.white)
                .frame(minWidth: 25, minHeight: 25)
                .background(role.tint)
                .clipShape(Circle())
        }
        .foregroundStyle(role.tint)
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background(Color.fieldBackground.opacity(0.78), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(role.tint.opacity(0.18), lineWidth: 1)
        }
    }

    func crewGlassCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

        return Group {
            if #available(iOS 26.0, *) {
                content()
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular.tint(Color.glassTint.opacity(0.3)).interactive(), in: shape)
                    .overlay {
                        shape.stroke(.white.opacity(0.5), lineWidth: 1)
                    }
                    .shadow(color: Color.appPrimary.opacity(0.08), radius: 18, y: 10)
            } else {
                content()
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial, in: shape)
                    .overlay {
                        shape.stroke(.white.opacity(0.68), lineWidth: 1)
                    }
                    .shadow(color: Color.appPrimary.opacity(0.08), radius: 18, y: 10)
            }
        }
    }

    func crewTextField(
        _ placeholder: String,
        text: Binding<String>,
        capitalization: TextInputAutocapitalization = .never,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        TextField(placeholder, text: text)
            .textInputAutocapitalization(capitalization)
            .keyboardType(keyboard)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.62), lineWidth: 1)
            }
    }

    func crewRoleSelector(selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ROLLE")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CrewRoleOption.allCases) { option in
                        crewRoleChip(option: option, selection: selection)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    func crewRoleChip(option: CrewRoleOption, selection: Binding<String>) -> some View {
        let isSelected = CrewRoleOption.option(for: selection.wrappedValue) == option

        return Button {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                selection.wrappedValue = option.rawValue
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: option.icon)
                    .font(.system(size: 13, weight: .bold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.shortLabel)
                        .font(.system(size: 13, weight: .bold))
                    Text(option.description)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : Color.secondary)
                }
            }
            .foregroundStyle(isSelected ? .white : option.tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                if isSelected {
                    option.tint
                } else {
                    Color.fieldBackground.opacity(0.78)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? option.tint.opacity(0.2) : Color.white.opacity(0.72), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    func crewDetailField(
        _ title: String,
        text: Binding<String>,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.secondary)
            TextField(title, text: text)
                .keyboardType(keyboard)
                .font(.system(size: 14, weight: .medium))
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.62), lineWidth: 1)
                }
        }
    }

    @MainActor
    func addCrewMember() {
        let name = newCrewName.trimmingCharacters(in: .whitespacesAndNewlines)
        let role = newCrewRole.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let emergencyContact = newCrewEmergencyContact.trimmingCharacters(in: .whitespacesAndNewlines)
        let emergencyPhone = newCrewEmergencyPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = newCrewNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        modelContext.insert(
            CrewMemberRecord(
                name: name,
                role: role.isEmpty ? CrewRoleOption.deck.rawValue : CrewRoleOption.normalizedRole(role),
                emergencyContact: emergencyContact,
                emergencyPhone: emergencyPhone,
                notes: notes,
                isOnBoard: true
            )
        )
        newCrewName = ""
        newCrewRole = CrewRoleOption.deck.rawValue
        newCrewEmergencyContact = ""
        newCrewEmergencyPhone = ""
        newCrewNotes = ""
        writeAudit(action: "INSERT", source: "crew", statement: "INSERT INTO crew(name, role, is_on_board) VALUES ('\(name)', '\(role)', true)", status: "ok")
        try? modelContext.save()
    }

    @MainActor
    func deleteCrewMember(_ member: CrewMemberRecord) {
        let name = member.name
        modelContext.delete(member)
        writeAudit(action: "DELETE", source: "crew", statement: "DELETE FROM crew WHERE name = '\(name)'", status: "ok")
        try? modelContext.save()
    }

    func crewSummaryText() -> String {
        // Das Logbuch speichert eine Textfassung der aktuellen Crew, damit ältere Törns unverändert lesbar bleiben.
        crewMembers.filter(\.isOnBoard).map { member in
            var parts = ["\(member.name) (\(CrewRoleOption.normalizedRole(member.role)))"]
            if !member.emergencyContact.isEmpty {
                parts.append("Notfall: \(member.emergencyContact)")
            }
            if !member.emergencyPhone.isEmpty {
                parts.append(member.emergencyPhone)
            }
            return parts.joined(separator: " · ")
        }
        .joined(separator: ", ")
    }
}
