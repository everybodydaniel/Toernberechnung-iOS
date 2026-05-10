import SwiftUI

extension ContentView {
    var islandHarbours: [HarbourOption] {
        harbours.filter { $0.id != "emden_harbor" }
    }

    func tidesTab() -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("BSH-GEZEITEN OSTFRIESISCHE INSELN")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.secondary)

            if tideLoading && islandTides.isEmpty {
                placeholderCard(icon: "water.waves", title: "BSH-Gezeiten werden geladen", text: "Die App ruft die offiziellen Pegeldaten der ostfriesischen Inseln ab.")
            } else if let tideError, islandTides.isEmpty {
                placeholderCard(icon: "wifi.slash", title: "Gezeiten konnten nicht geladen werden", text: tideError)
            } else {
                ForEach(islandHarbours) { harbour in
                    let reading = islandTides[harbour.id]
                    card {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(harbour.name)
                                        .font(.system(size: 20, weight: .bold))
                                    Text("BSH \(harbour.tideStationName) · \(harbour.tideStationID)")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.secondary)
                                }
                                Spacer()
                                if tideHarbourID == harbour.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color(hex: 0x3C82FF))
                                }
                            }
                            if let reading {
                                tideEventsRow(reading.events.prefix(4).map { $0 })
                            } else {
                                Text("Noch keine Daten geladen.")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Color.secondary)
                            }
                        }
                    }
                    .onTapGesture {
                        tideHarbourID = harbour.id
                        tideReading = reading
                    }
                }
            }
        }
    }

    func tidesPreviewCard(title: String) -> some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                    Spacer()
                    if tideLoading {
                        ProgressView()
                    }
                }
                if let tideReading {
                    Text("\(tideReading.stationName) · BSH \(tideReading.stationID)")
                        .font(.system(size: 16, weight: .bold))
                    tideEventsRow(Array(tideReading.events.prefix(4)))
                } else {
                    Text(tideError ?? "Gezeiten werden aus den BSH-Daten geladen.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.secondary)
                }
            }
        }
    }

    func tideEventsRow(_ events: [TideEvent]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(events) { event in
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: event.symbol)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(event.type == "HW" ? Color.blue : Color.teal)
                    Text(Self.slotFormatter.string(from: event.time))
                        .font(.system(size: 16, weight: .bold))
                    Text(event.heightText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
                .padding(10)
                .background(Color.fieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    func loadTides(force: Bool) async {
        let harbour = destinationHarbour
        await MainActor.run {
            tideLoading = true
            tideError = nil
            tideHarbourID = harbour.id
            writeAudit(action: "FETCH", source: "bsh_tides", statement: "FETCH BSH station='\(harbour.tideStationID)' harbour='\(harbour.name)'", status: "pending")
        }

        do {
            let reading = try await BSHTideService.shared.fetch(for: harbour, around: viewModel.departure, force: force)
            await MainActor.run {
                tideReading = reading
                islandTides[harbour.id] = reading
                tideLoading = false
                writeAudit(action: "READ", source: "bsh_tides", statement: "SELECT next_hw_nw FROM bsh_tides WHERE station_id = '\(harbour.tideStationID)' LIMIT 8", status: "ok")
            }
        } catch {
            await MainActor.run {
                tideLoading = false
                tideError = error.localizedDescription
                writeAudit(action: "FETCH", source: "bsh_tides", statement: "FETCH BSH station='\(harbour.tideStationID)'", status: "error")
            }
        }
    }

    func loadIslandTides(force: Bool) async {
        await MainActor.run {
            tideLoading = true
            tideError = nil
        }

        var loadedCount = 0
        var failures: [String] = []

        // Die Inselpegel werden nacheinander geladen, damit Teilerfolge angezeigt und einzelne Fehler gesammelt werden können.
        for harbour in islandHarbours {
            do {
                let reading = try await BSHTideService.shared.fetch(for: harbour, around: viewModel.departure, force: force)
                loadedCount += 1
                await MainActor.run {
                    islandTides[harbour.id] = reading
                    if harbour.id == tideHarbourID { tideReading = reading }
                }
            } catch {
                failures.append("\(harbour.name): \(error.localizedDescription)")
            }
        }

        await MainActor.run {
            tideLoading = false
            if loadedCount == 0 {
                tideError = failures.first ?? "Für die Inselpegel konnten keine Gezeiten geladen werden."
                writeAudit(action: "FETCH", source: "bsh_tides", statement: "FETCH BSH island tide bundle", status: "error")
            } else {
                tideError = failures.isEmpty ? nil : failures.joined(separator: " | ")
                writeAudit(action: "READ", source: "bsh_tides", statement: "SELECT island, next_hw_nw FROM bsh_tides WHERE area = 'ostfriesische_inseln'", status: "ok")
            }
        }
    }
}
