import AppKit
import SwiftUI

/// Die Rückfrage beim ersten Start von 2.0, wenn es am neuen Ort noch keine
/// Datenbank gibt, am alten aber eine von Fassung 1.2 (2026-09-26). Entweder
/// wird sie übernommen, oder es geht neu los. Sie nennt beide Orte, damit
/// niemand später suchen muss, wo die Daten geblieben sind. Enter übernimmt,
/// Escape beendet.
struct Umzugsansicht: View {
    let speicher: Speicher
    /// Wird gerufen, wenn übernommen oder neu angefangen wurde.
    let fertig: () -> Void

    /// Tab geht im Ring durch die drei Knöpfe, die Leertaste löst aus, wie in
    /// jedem Dialog, siehe Auswahl.swift.
    private enum Knopf: Hashable { case beenden, neu, uebernehmen }
    private let kette: [Knopf] = [.beenden, .neu, .uebernehmen]
    @FocusState private var fokus: Knopf?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Daten von Fassung 1.2 übernehmen")
                .font(.title2).fontWeight(.semibold)

            Text("Das Haushaltsbuch legt seine Daten ab Fassung 2.0 in eigenen Ordnern ab. "
                 + "Beim Übernehmen wird deine bisherige Datenbank dorthin kopiert, danach "
                 + "heißt die alte haushalt.sqlite.umgezogen. Gelöscht wird nichts. Beim "
                 + "Neu anfangen bleibt die alte, wie sie ist, und die Einrichtung beginnt.")
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Datenbank bisher").foregroundStyle(.secondary)
                    pfad(Pfade.alt)
                }
                GridRow {
                    Text("Datenbank neu").foregroundStyle(.secondary)
                    pfad(Pfade.standard)
                }
                GridRow {
                    Text("Sicherungen neu").foregroundStyle(.secondary)
                    pfad(Pfade.sicherungen(fuer: Pfade.standard).path)
                }
            }

            Text("Beende vor dem Übernehmen Fassung 1.2, falls sie noch läuft. Sie findet "
                 + "ihre Datenbank danach nicht mehr und kann gelöscht werden.")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            if let meldung = speicher.meldung {
                Text(meldung).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Beenden", role: .cancel) { beenden() }
                    .keyboardShortcut(.cancelAction)
                    .focusable()
                    .focused($fokus, equals: .beenden)
                Button("Neu anfangen") { neuAnfangen() }
                    .focusable()
                    .focused($fokus, equals: .neu)
                Button("Übernehmen") { uebernehmen() }
                    .keyboardShortcut(.defaultAction)
                    .focusable()
                    .focused($fokus, equals: .uebernehmen)
            }
        }
        .padding(24)
        .frame(minWidth: 560, maxWidth: 720, alignment: .leading)
        .dialogtasten(fokus: $fokus, kette: kette) { knopf in
            switch knopf {
            case .beenden: beenden()
            case .neu: neuAnfangen()
            case .uebernehmen: uebernehmen()
            }
            return true
        }
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            fokus = .uebernehmen
        }
    }

    private func beenden() { NSApp.terminate(nil) }

    private func neuAnfangen() {
        speicher.neuAnfangen()
        fertig()
    }

    private func uebernehmen() {
        speicher.umziehen()
        if !speicher.umzugOffen { fertig() }
    }

    /// Ein Pfad so, wie ihn der Finder zeigt. iCloud Drive heißt dort iCloud
    /// Drive und nicht Library/Mobile Documents, der Heimordner wird zur Tilde.
    private func pfad(_ voll: String) -> some View {
        let icloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").path + "/"
        let lesbar = voll.hasPrefix(icloud)
            ? "iCloud Drive/" + voll.dropFirst(icloud.count)
            : (voll as NSString).abbreviatingWithTildeInPath
        return Text(lesbar)
            .font(.callout.monospaced())
            .lineLimit(2)
            .textSelection(.enabled)
    }
}
