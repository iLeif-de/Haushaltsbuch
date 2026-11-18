import SwiftUI

/// Das Gruppenfeld, wie `gruppen_feld` in ui/hilfen.py. Ein Textfeld mit einem
/// Menü der vorhandenen Gruppen daneben, kein aufklappendes Auswahlfeld.
///
/// **Leer ist leer.** Nil heißt nicht gesetzt, dann gilt die Stufe darüber, also
/// Posten, Topf oder Kategorie. Ein leerer Text heißt bewusst gelöscht und
/// beendet die Vererbung. Das Feld zeigt die Gruppe, die gilt, dieselbe wie die
/// Listen. Unverändert gespeichert bleibt alles, wie es war, eine geerbte Gruppe
/// bleibt also geerbt, siehe die Entscheidungen in CLAUDE.md.
struct Gruppenfeld: View {
    /// Was im Feld steht. Anfangs die Gruppe, die gilt.
    @Binding var text: String
    /// Die vorhandenen Gruppen zur Auswahl, veraltete sind schon heraus.
    let vorhanden: [String]

    var body: some View {
        HStack(spacing: 4) {
            TextField("Gruppe, optional", text: $text)
            Menu {
                Button("Keine Gruppe") { text = "" }
                Divider()
                ForEach(vorhanden, id: \.self) { gruppe in
                    Button(gruppe) { text = gruppe }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
            .help("Vorhandene Gruppen")
        }
    }
}

enum Gruppenwahl {
    /// Gruppen, die nicht mehr angeboten werden. Sie bleiben sichtbar, wo Daten
    /// sie noch tragen, wie kern.VERALTETE_GRUPPEN.
    static let veraltet = ["Fixkosten"]

    static func auswahl(_ alle: [String]) -> [String] {
        alle.filter { !veraltet.contains($0) }
    }

    /// Was gespeichert wird.
    ///
    /// - unverändert gegenüber dem Angezeigten, dann das Gespeicherte, eine
    ///   geerbte Gruppe bleibt damit geerbt
    /// - geleert, dann ein leerer Text, also keine Gruppe, hier und für alles,
    ///   was von hier erbt
    /// - sonst der Name, in der Schreibweise einer vorhandenen Gruppe
    static func gespeichertWert(getippt: String, angezeigt: String, gespeichert: String?,
                                vorhanden: [String]) -> String? {
        let sauber = getippt.trimmingCharacters(in: .whitespaces)
        let gezeigt = angezeigt.trimmingCharacters(in: .whitespaces)
        // Unverändert heißt unverändert, auch bei anderer Schreibweise
        if sauber.lowercased() == gezeigt.lowercased() { return gespeichert }
        if sauber.isEmpty { return "" }
        // Eine veraltete Gruppe wird nicht neu vergeben, das Bearbeitete behält,
        // was es hatte. Wie in ui/hilfen.py, Funktion hole.
        if veraltet.contains(where: { $0.lowercased() == sauber.lowercased() }) {
            return gespeichert
        }
        // Groß und Kleinschreibung einer vorhandenen Gruppe übernehmen, damit
        // nicht Auto und auto als zwei Gruppen nebeneinander stehen
        if let treffer = vorhanden.first(where: { $0.lowercased() == sauber.lowercased() }) {
            return treffer
        }
        return sauber
    }
}
