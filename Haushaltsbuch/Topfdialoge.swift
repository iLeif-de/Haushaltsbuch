import SwiftUI

/// Einen eigenen Topf bearbeiten, wie `bearbeiten` in ui/toepfe.py. Alle Felder
/// stehen mit dem Wert darin, der gerade gilt.
struct Topfdialog: View {
    let speicher: Speicher
    let topf: Topf
    let fertig: () -> Void

    private enum Feld: Hashable { case name, rate, ziel, kategorie, gruppe, gruppenmenue }

    private let kette: [Feld] = [.name, .rate, .ziel, .kategorie, .gruppe, .gruppenmenue]

    @FocusState private var fokus: Feld?
    @State private var offenes: Feld?

    @State private var name: String
    @State private var rateText: String
    @State private var zielText: String
    @State private var kategorieName: String
    @State private var gruppentext: String
    @State private var hinweis: String?

    private let angezeigteGruppe: String

    init(speicher: Speicher, topf: Topf, fertig: @escaping () -> Void) {
        self.speicher = speicher
        self.topf = topf
        self.fertig = fertig
        _name = State(initialValue: topf.name)
        _rateText = State(initialValue: Geld.ohneEuro(topf.rateGespeichertCent))
        _zielText = State(initialValue: topf.zielCent.map { Geld.ohneEuro($0) } ?? "")
        _kategorieName = State(initialValue: topf.kategorie ?? "")
        angezeigteGruppe = topf.wirksameGruppe ?? ""
        _gruppentext = State(initialValue: topf.wirksameGruppe ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(topf.name) bearbeiten").font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Name")
                    TextField("", text: $name).focused($fokus, equals: .name)
                }
                GridRow {
                    Text("Rate im Monat")
                    TextField("in Euro", text: $rateText).focused($fokus, equals: .rate)
                }
                GridRow {
                    Text("Ziel")
                    TextField("in Euro, optional", text: $zielText)
                        .focused($fokus, equals: .ziel)
                }
                GridRow {
                    Text("Kategorie")
                    Auswahlknopf(wert: kategorieName.isEmpty ? "Keine Kategorie" : kategorieName,
                                 namen: ["Keine Kategorie"] + speicher.kategorien.map(\.name),
                                 fokus: $fokus, marke: .kategorie, offenes: $offenes) { name in
                        kategorieName = name == "Keine Kategorie" ? "" : name
                    }
                }
                GridRow {
                    Text("Gruppe")
                    Gruppenzeile(text: $gruppentext,
                                 vorhanden: Gruppenwahl.auswahl(speicher.gruppen),
                                 fokus: $fokus, feldMarke: .gruppe, knopfMarke: .gruppenmenue,
                                 offenes: $offenes)
                }
            }

            if topf.zeile.zielMonat != nil {
                Text("Dieser Topf hat einen Termin. Seine Rate ergibt sich aus dem, was bis dahin "
                     + "noch fehlt, eine hier gesetzte Rate wirkt deshalb nicht.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let hinweis {
                Text(hinweis).font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { fertig() }
                    .keyboardShortcut(.cancelAction)
                Button("Speichern") { sichern() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 400)
        .dialogtasten(fokus: $fokus, kette: kette,
                      listen: [.kategorie, .gruppenmenue]) { glied in
            guard glied == .kategorie || glied == .gruppenmenue else { return false }
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
        let rate = abs(Geld.cent(aus: rateText) ?? 0)
        let ziel = zielText.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil : Geld.cent(aus: zielText).map { abs($0) }
        let gruppe = Gruppenwahl.gespeichertWert(
            getippt: gruppentext, angezeigt: angezeigteGruppe,
            gespeichert: topf.gruppe, vorhanden: speicher.gruppen)
        if speicher.topfAendern(topf, name: sauberName,
                                kategorieId: speicher.kategorie(nach: kategorieName)?.id,
                                gruppe: gruppe, rate: rate, ziel: ziel) {
            fertig()
        } else {
            hinweis = speicher.meldung
        }
    }
}

/// Ein neuer eigener Topf, wie `neu` in ui/toepfe.py. Entweder eine Rate angeben
/// oder Ziel und Monat, dann rechnet der Kern die Rate.
struct NeuerTopfdialog: View {
    let speicher: Speicher
    let fertig: () -> Void

    private enum Feld: Hashable {
        case name, ziel, rate, zielMonat, vorhanden, kategorie, gruppe, gruppenmenue
    }

    private let kette: [Feld] = [.name, .ziel, .rate, .zielMonat, .vorhanden, .kategorie,
                                 .gruppe, .gruppenmenue]

    @FocusState private var fokus: Feld?
    @State private var offenes: Feld?

    @State private var name = ""
    @State private var zielText = ""
    @State private var rateText = ""
    @State private var zielMonat = ""
    @State private var vorhandenText = "0"
    @State private var kategorieName = ""
    @State private var gruppentext = ""
    @State private var hinweis: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Neuer Topf").font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Name")
                    TextField("etwa Neue Waschmaschine", text: $name)
                        .focused($fokus, equals: .name)
                }
                GridRow {
                    Text("Ziel")
                    TextField("in Euro, optional", text: $zielText)
                        .focused($fokus, equals: .ziel)
                }
                GridRow {
                    Text("Rate im Monat")
                    TextField("in Euro", text: $rateText).focused($fokus, equals: .rate)
                }
                GridRow {
                    Text("Oder voll bis")
                    TextField("JJJJ-MM", text: $zielMonat)
                        .frame(width: 100)
                        .focused($fokus, equals: .zielMonat)
                }
                GridRow {
                    Text("Schon vorhanden")
                    TextField("in Euro", text: $vorhandenText)
                        .frame(width: 100)
                        .focused($fokus, equals: .vorhanden)
                }
                GridRow {
                    Text("Kategorie")
                    Auswahlknopf(wert: kategorieName.isEmpty ? "Keine Kategorie" : kategorieName,
                                 namen: ["Keine Kategorie"] + speicher.kategorien.map(\.name),
                                 fokus: $fokus, marke: .kategorie, offenes: $offenes) { name in
                        kategorieName = name == "Keine Kategorie" ? "" : name
                    }
                }
                GridRow {
                    Text("Gruppe")
                    Gruppenzeile(text: $gruppentext,
                                 vorhanden: Gruppenwahl.auswahl(speicher.gruppen),
                                 fokus: $fokus, feldMarke: .gruppe, knopfMarke: .gruppenmenue,
                                 offenes: $offenes)
                }
            }

            Text("Ein Topf ohne Ziel ist ein Puffer, er sammelt einfach weiter. Mit Ziel und "
                 + "Monat ergibt sich die Rate daraus, was bis dahin noch fehlt.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let hinweis {
                Text(hinweis).font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { fertig() }
                    .keyboardShortcut(.cancelAction)
                Button("Anlegen") { sichern() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
        .dialogtasten(fokus: $fokus, kette: kette,
                      listen: [.kategorie, .gruppenmenue]) { glied in
            guard glied == .kategorie || glied == .gruppenmenue else { return false }
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
        let ziel = zielText.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil : Geld.cent(aus: zielText).map { abs($0) }
        let rate = rateText.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil : Geld.cent(aus: rateText).map { abs($0) }
        let monat = zielMonat.trimmingCharacters(in: .whitespaces)
        if !monat.isEmpty, !Monat.gueltig(monat) {
            hinweis = "Den Monat bitte als JJJJ-MM eintragen."
            return
        }
        let gruppe = Gruppenwahl.gespeichertWert(
            getippt: gruppentext, angezeigt: "", gespeichert: nil, vorhanden: speicher.gruppen)
        if speicher.topfAnlegen(name: sauberName, rate: rate, ziel: ziel,
                                zielMonat: monat.isEmpty ? nil : monat,
                                schonVorhanden: abs(Geld.cent(aus: vorhandenText) ?? 0),
                                kategorieId: speicher.kategorie(nach: kategorieName)?.id,
                                gruppe: gruppe) {
            fertig()
        } else {
            hinweis = speicher.meldung
        }
    }
}

/// Einen Topf aufstocken, wie `aufstocken` in ui/toepfe.py. Was nicht mehr ins
/// Ziel passt, lehnt der Kern ab, der Dialog bleibt dann mit der Meldung stehen.
struct Aufstockdialog: View {
    let speicher: Speicher
    let topf: Topf
    let fertig: () -> Void

    @State private var betragText = ""
    @State private var hinweis: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(topf.name) aufstocken").font(.headline)

            HStack {
                Text("Betrag")
                TextField("in Euro", text: $betragText)
            }

            if let ziel = topf.zielCent, ziel != 0 {
                let passt = ziel - topf.stand
                Text(passt > 0
                     ? "Bis zum Ziel fehlen noch \(Geld.euro(passt))."
                     : "Der Topf ist schon voll. Erhöhe erst das Ziel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Das Geld liegt schon auf dem Konto und ist danach nur nicht mehr frei verfügbar.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let hinweis {
                Text(hinweis).font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { fertig() }
                    .keyboardShortcut(.cancelAction)
                Button("Hinzufügen") { sichern() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func sichern() {
        guard let cent = Geld.cent(aus: betragText), cent != 0 else {
            hinweis = "Der Betrag fehlt oder ist nicht zu lesen."
            return
        }
        // Erst aufstocken, dann schließen. Andersherum wären Dialog und Eingabe
        // schon weg, wenn der Kern etwas bemängelt.
        if speicher.topfAufstocken(topf, betragCent: abs(cent)) {
            fertig()
        } else {
            hinweis = speicher.meldung
        }
    }
}
