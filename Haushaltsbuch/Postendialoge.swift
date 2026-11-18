import SwiftUI

/// Einen festen Posten bearbeiten, wie der Dialog in ui/posten.py.
///
/// Name, Kategorie und Gruppe gehören dem Posten als Ganzem und gelten sofort
/// für seine ganze Geschichte. Nur der Betrag fragt, ab wann er gilt, denn nur
/// dort entsteht im Hintergrund eine neue Regel. Alle Felder zeigen, was gerade
/// gilt.
struct Postendialog: View {
    let speicher: Speicher
    let posten: Posten
    let fertig: () -> Void

    private enum Feld: Hashable {
        case name, kategorie, gruppe, gruppenmenue, termin, betrag, abMonat
    }

    private var kette: [Feld] {
        [.name, .kategorie, .gruppe, .gruppenmenue, .termin, .betrag, .abMonat]
    }

    @FocusState private var fokus: Feld?
    @State private var offenes: Feld?

    @State private var name: String
    @State private var kategorieName: String
    @State private var gruppentext: String
    @State private var betragText: String
    @State private var abMonat: String
    /// Der nächste Termin, also Fälligkeitsmonat und Tag zusammen. Ändern
    /// verschiebt den Zyklus, siehe Kern.regelFaelligkeitSetzen.
    @State private var termin: Date
    @State private var solltag: String
    @State private var hinweis: String?

    private let angezeigteGruppe: String
    private let vorzeichen: Int

    init(speicher: Speicher, posten: Posten, fertig: @escaping () -> Void) {
        self.speicher = speicher
        self.posten = posten
        self.fertig = fertig
        _name = State(initialValue: posten.name)
        _kategorieName = State(initialValue: posten.ersteKategorie ?? "")
        angezeigteGruppe = posten.wirksameGruppe ?? ""
        _gruppentext = State(initialValue: posten.wirksameGruppe ?? "")
        _betragText = State(initialValue: Geld.euro(abs(posten.betragCent))
            .replacingOccurrences(of: " €", with: ""))
        _abMonat = State(initialValue: Monat.plus(speicher.heuteMonat, 1))
        let naechster = speicher.kern?.naechsterTermin(posten)
            ?? "\(posten.giltAb)-\(String(format: "%02d", posten.tagImMonat))"
        _termin = State(initialValue: Datumsformat.iso.date(from: naechster) ?? Date())
        _solltag = State(initialValue: String(posten.tagImMonat))
        vorzeichen = posten.betragCent < 0 ? -1 : 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(posten.name) bearbeiten").font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Name")
                    TextField("", text: $name)
                        .focused($fokus, equals: .name)
                }
                GridRow {
                    Text("Kategorie")
                    Auswahlknopf(wert: kategorieName, namen: kategorienamen, fokus: $fokus,
                                 marke: .kategorie, offenes: $offenes) { kategorieName = $0 }
                }
                GridRow {
                    Text("Gruppe")
                    Gruppenzeile(text: $gruppentext,
                                 vorhanden: Gruppenwahl.auswahl(speicher.gruppen),
                                 fokus: $fokus, feldMarke: .gruppe, knopfMarke: .gruppenmenue,
                                 offenes: $offenes)
                }
                if posten.intervallMonate > 1 {
                    GridRow {
                        Text("Nächste Fälligkeit")
                        DatePicker("", selection: $termin, displayedComponents: .date)
                            .datePickerStyle(.stepperField)
                            .labelsHidden()
                            .focusable()
                            .focused($fokus, equals: .termin)
                    }
                } else {
                    GridRow {
                        Text("Tag im Monat")
                        TextField("1 bis 31", text: $solltag)
                            .frame(width: 70)
                            .focused($fokus, equals: .termin)
                    }
                }
            }

            Text("Name, Kategorie und Gruppe gelten für den ganzen Posten, auch für seine "
                 + "bisherigen Buchungen. Leere Gruppe heißt, es gilt die der Kategorie.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if posten.intervallMonate > 1 {
                Text("Der Termin verschiebt den ganzen Zyklus, \(posten.rhythmus.dropFirst(0)) "
                     + "geht es von dort aus weiter. Der Topf rechnet seine Rate danach neu, und "
                     + "noch nicht bestätigte Abschläge des alten Zyklus fallen weg.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(vorzeichen < 0 ? "Betrag" : "Einnahme")
                    TextField("in Euro", text: $betragText)
                        .focused($fokus, equals: .betrag)
                }
                GridRow {
                    Text("gilt ab")
                    TextField("JJJJ-MM", text: $abMonat)
                        .frame(width: 100)
                        .focused($fokus, equals: .abMonat)
                }
            }

            Text("Ein neuer Betrag gilt erst ab dem genannten Monat, die Monate davor behalten "
                 + "den alten. Der Posten selbst wird dabei nie überschrieben.")
                .font(.caption)
                .foregroundStyle(.secondary)


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

    private var kategorienamen: [String] {
        var namen = speicher.kategorien.map(\.name)
        if !namen.contains(kategorieName) { namen.append(kategorieName) }
        return namen
    }

    private func sichern() {
        let sauberName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sauberName.isEmpty else {
            hinweis = "Der Name fehlt."
            return
        }
        guard let kategorie = speicher.kategorie(nach: kategorieName) else {
            hinweis = "Bitte eine Kategorie wählen."
            return
        }
        guard let cent = Geld.cent(aus: betragText), cent != 0 else {
            hinweis = "Der Betrag ist nicht zu lesen."
            return
        }
        let betrag = abs(cent) * vorzeichen
        let betragNeu = betrag != posten.betragCent
        if betragNeu, !Monat.gueltig(abMonat) {
            hinweis = "Den Monat bitte als JJJJ-MM eintragen."
            return
        }
        let gruppe = Gruppenwahl.gespeichertWert(
            getippt: gruppentext, angezeigt: angezeigteGruppe,
            gespeichert: posten.gruppe, vorhanden: speicher.gruppen)

        // Erst der Termin, dann die übrigen Merkmale. Eine Betragsänderung legt
        // womöglich eine neue Regel an, die soll den neuen Zyklus schon erben.
        if posten.intervallMonate > 1 {
            let neuerTermin = Datumsformat.iso.string(from: termin)
            let monat = String(neuerTermin.prefix(7))
            let tag = Int(neuerTermin.suffix(2)) ?? posten.tagImMonat
            if monat != posten.giltAb || tag != posten.tagImMonat {
                guard speicher.postenTerminSetzen(posten, monat: monat, tag: tag) else {
                    hinweis = speicher.meldung
                    return
                }
            }
        } else if let tag = Int(solltag.trimmingCharacters(in: .whitespaces)),
                  tag != posten.tagImMonat {
            guard (1...31).contains(tag) else {
                hinweis = "Der Tag liegt nicht zwischen 1 und 31."
                return
            }
            guard speicher.postenTerminSetzen(posten, monat: posten.giltAb, tag: tag) else {
                hinweis = speicher.meldung
                return
            }
        }

        if speicher.postenAendern(posten, name: sauberName, kategorieId: kategorie.id,
                                  gruppe: gruppe,
                                  neuerBetrag: betragNeu ? betrag : nil,
                                  abMonat: abMonat) {
            fertig()
        } else {
            hinweis = speicher.meldung
        }
    }
}

/// Nachzahlung oder Rückzahlung zu einem Posten, wie `korrektur` in ui/posten.py.
struct Korrekturdialog: View {
    let speicher: Speicher
    let posten: Posten
    /// true für Nachzahlung, also Geld heraus, false für Rückzahlung.
    let nachzahlung: Bool
    let fertig: () -> Void

    @State private var betragText = ""
    @State private var datum = Date()
    @State private var hinweis: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(nachzahlung ? "Nachzahlung" : "Rückzahlung") zu \(posten.name)")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Betrag")
                    TextField("in Euro", text: $betragText)
                }
                GridRow {
                    Text("Datum")
                    DatePicker("", selection: $datum, displayedComponents: .date)
                        .datePickerStyle(.stepperField)
                        .labelsHidden()
                }
            }

            Text(nachzahlung
                 ? "Eine Nachzahlung geht vom Konto ab, etwa die Nachforderung des Versorgers."
                 : "Eine Rückzahlung kommt aufs Konto, etwa das Guthaben aus der Abrechnung.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let hinweis {
                Text(hinweis).font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { fertig() }
                    .keyboardShortcut(.cancelAction)
                Button("Buchen") { sichern() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func sichern() {
        guard let cent = Geld.cent(aus: betragText), cent != 0 else {
            hinweis = "Der Betrag fehlt oder ist nicht zu lesen."
            return
        }
        let betrag = nachzahlung ? -abs(cent) : abs(cent)
        if speicher.postenKorrektur(posten, betragCent: betrag,
                                    datum: Datumsformat.iso.string(from: datum)) {
            fertig()
        } else {
            hinweis = speicher.meldung
        }
    }
}

/// Einen Posten beenden, mit dem letzten Monat, wie `beenden` in ui/posten.py.
struct Beendendialog: View {
    let speicher: Speicher
    let posten: Posten
    let fertig: () -> Void

    @State private var letzterMonat: String
    @State private var hinweis: String?

    init(speicher: Speicher, posten: Posten, fertig: @escaping () -> Void) {
        self.speicher = speicher
        self.posten = posten
        self.fertig = fertig
        _letzterMonat = State(initialValue: speicher.heuteMonat)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(posten.name) beenden").font(.headline)
            HStack {
                Text("Letzter Monat")
                TextField("JJJJ-MM", text: $letzterMonat).frame(width: 100)
            }
            Text("Bis zu diesem Monat bucht der Posten weiter, danach nicht mehr. Was schon "
                 + "gebucht ist, bleibt stehen.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let hinweis {
                Text(hinweis).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { fertig() }
                    .keyboardShortcut(.cancelAction)
                Button("Beenden") { sichern() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func sichern() {
        guard Monat.gueltig(letzterMonat) else {
            hinweis = "Den Monat bitte als JJJJ-MM eintragen."
            return
        }
        if speicher.postenBeenden(posten, letzterMonat: letzterMonat) {
            fertig()
        } else {
            hinweis = speicher.meldung
        }
    }
}
