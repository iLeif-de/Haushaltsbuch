import SwiftUI

/// Eine Kategorie anlegen oder bearbeiten, wie `kategorie_formular` in
/// ui/einstellungen.py. Name, Gruppe als Vorgabe und ein Symbol.
///
/// Die Symbolsuche ist hier kürzer als in Flet. Dort wird über alle Material
/// Iconnamen gesucht, hier stehen die Namen zur Auswahl, die `Symbole` kennt,
/// denn nur die lassen sich auch anzeigen.
struct Kategoriedialog: View {
    let speicher: Speicher
    /// Nil heißt, es wird eine neue angelegt.
    let kategorie: Kategorie?
    let fertig: () -> Void

    @State private var name: String
    @State private var gruppentext: String
    @State private var icon: String?
    @State private var suche = ""
    @State private var hinweis: String?

    private let angezeigteGruppe: String

    private enum Feld: Hashable { case name, gruppe, gruppenmenue, suche }

    private let kette: [Feld] = [.name, .gruppe, .gruppenmenue, .suche]

    @FocusState private var fokus: Feld?
    @State private var offenes: Feld?

    init(speicher: Speicher, kategorie: Kategorie?, fertig: @escaping () -> Void) {
        self.speicher = speicher
        self.kategorie = kategorie
        self.fertig = fertig
        _name = State(initialValue: kategorie?.name ?? "")
        angezeigteGruppe = kategorie?.gruppe ?? ""
        _gruppentext = State(initialValue: kategorie?.gruppe ?? "")
        _icon = State(initialValue: kategorie?.icon)
    }

    private var treffer: [String] {
        let text = suche.trimmingCharacters(in: .whitespaces).lowercased()
        let alle = Symbole.bekannteNamen
        guard !text.isEmpty else { return alle }
        return alle.filter { $0.contains(text) || Symbole.sfSymbol($0).contains(text) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kategorie == nil ? "Neue Kategorie" : "\(kategorie!.name) bearbeiten")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Name")
                    TextField("etwa Lebensmittel", text: $name)
                        .focused($fokus, equals: .name)
                }
                GridRow {
                    Text("Gruppe")
                    Gruppenzeile(text: $gruppentext,
                                 vorhanden: Gruppenwahl.auswahl(speicher.gruppen),
                                 fokus: $fokus, feldMarke: .gruppe, knopfMarke: .gruppenmenue,
                                 offenes: $offenes)
                }
            }

            Text("Die Gruppe ist nur die Vorgabe. Ein fester Posten oder eine einzelne Buchung "
                 + "kann eine eigene Gruppe tragen und übersteuert sie damit.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack(spacing: 10) {
                Image(systemName: Symbole.sfSymbol(icon))
                    .font(.system(size: 22))
                    .frame(width: 30)
                TextField("Symbol suchen", text: $suche).focused($fokus, equals: .suche)
            }

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34)), count: 9), spacing: 6) {
                    ForEach(treffer, id: \.self) { name in
                        Button {
                            icon = name
                        } label: {
                            Image(systemName: Symbole.sfSymbol(name))
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.bordered)
                        .tint(icon == name ? .accentColor : .secondary)
                        .help(name)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 120)

            if let hinweis {
                Text(hinweis).font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { fertig() }
                    .keyboardShortcut(.cancelAction)
                Button(kategorie == nil ? "Anlegen" : "Speichern") { sichern() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
        .dialogtasten(fokus: $fokus, kette: kette, listen: [.gruppenmenue]) { glied in
            guard glied == .gruppenmenue else { return false }
            offenes = glied
            return true
        }
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            fokus = .name
        }
    }

    private func sichern() {
        let sauberName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sauberName.isEmpty else {
            hinweis = "Der Name fehlt."
            return
        }
        if speicher.kategorien.contains(where: {
            $0.name.lowercased() == sauberName.lowercased() && $0.id != kategorie?.id
        }) {
            hinweis = "Eine Kategorie mit diesem Namen gibt es schon."
            return
        }
        let gruppe = Gruppenwahl.gespeichertWert(
            getippt: gruppentext, angezeigt: angezeigteGruppe,
            gespeichert: kategorie?.gruppe, vorhanden: speicher.gruppen)

        let erfolg: Bool
        if let kategorie {
            erfolg = speicher.kategorieAendern(
                kategorie,
                neuerName: sauberName == kategorie.name ? nil : sauberName,
                // Die Gruppe wird immer mitgesetzt, leer löscht sie
                gruppe: gruppe ?? "",
                icon: icon)
        } else {
            erfolg = speicher.kategorieAnlegen(name: sauberName,
                                               gruppe: (gruppe?.isEmpty ?? true) ? nil : gruppe,
                                               icon: icon)
        }
        if erfolg {
            fertig()
        } else {
            hinweis = speicher.meldung
        }
    }
}
