import SwiftUI

/// Ein neuer fester Posten, wie `neu` in ui/posten.py.
///
/// Bei einem nicht monatlichen Posten wird als Fälligkeitsmonat ein volles
/// Intervall ab heute vorgeschlagen, als wäre gerade gezahlt worden. Der
/// aktuelle Monat wäre dort der schlechteste Wert, er bucht sofort die ganze
/// Summe. Solange der Vorschlag unangetastet ist, zieht er beim Wechsel der
/// Wiederkehr mit.
struct NeuerPostendialog: View {
    let speicher: Speicher
    let fertig: () -> Void

    private enum Feld: Hashable {
        case name, betrag, einnahme, tag, wiederkehr, abMonat, kategorie, gruppe,
             gruppenmenue, vorhanden, keinTopf
    }

    private var kette: [Feld] {
        var glieder: [Feld] = [.name, .betrag, .einnahme, .tag, .wiederkehr, .abMonat,
                               .kategorie, .gruppe, .gruppenmenue]
        if selten { glieder += [.vorhanden, .keinTopf] }
        return glieder
    }

    @FocusState private var fokus: Feld?
    @State private var offenes: Feld?

    @State private var name = ""
    @State private var betragText = ""
    @State private var einnahme = false
    @State private var tagText = "1"
    @State private var intervall = 1
    @State private var abMonat: String
    @State private var kategorieName = ""
    @State private var gruppentext = ""
    @State private var vorhandenText = "0"
    @State private var keinTopf = false
    @State private var hinweis: String?
    /// Der letzte selbst gesetzte Vorschlag, damit nur er nachzieht.
    @State private var vorschlag: String

    init(speicher: Speicher, fertig: @escaping () -> Void) {
        self.speicher = speicher
        self.fertig = fertig
        _abMonat = State(initialValue: speicher.heuteMonat)
        _vorschlag = State(initialValue: speicher.heuteMonat)
    }

    private var selten: Bool { intervall > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Neuer fester Posten").font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Name")
                    TextField("etwa Miete", text: $name).focused($fokus, equals: .name)
                }
                GridRow {
                    Text(einnahme ? "Einnahme" : "Betrag")
                    HStack(spacing: 8) {
                        TextField("in Euro", text: $betragText)
                            .focused($fokus, equals: .betrag)
                        Toggle("Einnahme", isOn: $einnahme)
                            .focusable()
                            .focused($fokus, equals: .einnahme)
                    }
                }
                GridRow {
                    Text("Tag im Monat")
                    TextField("1 bis 31", text: $tagText)
                        .frame(width: 70)
                        .focused($fokus, equals: .tag)
                }
                GridRow {
                    Text("Wiederkehr")
                    Auswahlknopf(wert: wiederkehrName, namen: wiederkehr.map(\.name),
                                 fokus: $fokus, marke: .wiederkehr, offenes: $offenes) { name in
                        guard let zahl = wiederkehr.first(where: { $0.name == name })?.zahl
                        else { return }
                        intervall = zahl
                        intervallGewechselt(zahl)
                    }
                    .frame(width: 160)
                }
                GridRow {
                    Text(selten ? "Fälligkeitsmonat" : "Gilt ab Monat")
                    TextField("JJJJ-MM", text: $abMonat)
                        .frame(width: 100)
                        .focused($fokus, equals: .abMonat)
                }
                GridRow {
                    Text("Kategorie")
                    Auswahlknopf(wert: kategorieName.isEmpty ? "bitte wählen" : kategorieName,
                                 namen: speicher.kategorien.map(\.name), fokus: $fokus,
                                 marke: .kategorie, offenes: $offenes) { kategorieName = $0 }
                }
                GridRow {
                    Text("Gruppe")
                    Gruppenzeile(text: $gruppentext,
                                 vorhanden: Gruppenwahl.auswahl(speicher.gruppen),
                                 fokus: $fokus, feldMarke: .gruppe, knopfMarke: .gruppenmenue,
                                 offenes: $offenes)
                }
                if selten {
                    GridRow {
                        Text("Schon zurückgelegt")
                        TextField("in Euro", text: $vorhandenText)
                            .frame(width: 100)
                            .focused($fokus, equals: .vorhanden)
                    }
                }
            }

            if selten {
                Text("Vorgeschlagen ist ein volles Intervall ab heute, als wäre gerade gezahlt "
                     + "worden. Weißt du den echten Monat der nächsten Zahlung, trag ihn ein. "
                     + "Nur den aktuellen Monat nicht, sonst wird die volle Summe sofort "
                     + "abgebucht.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Nicht zurücklegen", isOn: $keinTopf)
                    .font(.callout)
                    .focusable()
                    .focused($fokus, equals: .keinTopf)
            }

            Text("Leere Gruppe heißt, es gilt die Gruppe der Kategorie. Eine eigene Gruppe trennt "
                 + "gleiche Kategorien, etwa Haftpflicht nach Wohnen und Kfz Versicherung nach Auto.")
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
        .frame(width: 440)
        .dialogtasten(fokus: $fokus, kette: kette,
                      listen: [.wiederkehr, .kategorie, .gruppenmenue]) { glied in
            switch glied {
            case .einnahme: einnahme.toggle()
            case .keinTopf: keinTopf.toggle()
            case .wiederkehr, .kategorie, .gruppenmenue: offenes = glied
            default: return false
            }
            return true
        }
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            fokus = .name
        }
    }

    /// Die Wiederkehr, wie INTERVALL_NAMEN in ui/hilfen.py. Als Liste und nicht
    /// als Wörterbuch, die Reihenfolge soll stimmen.
    private let wiederkehr: [(zahl: Int, name: String)] = [
        (1, "monatlich"), (3, "vierteljährlich"), (6, "halbjährlich"), (12, "jährlich"),
    ]

    private var wiederkehrName: String {
        wiederkehr.first { $0.zahl == intervall }?.name ?? "monatlich"
    }

    /// Beim Wechsel der Wiederkehr den Monatsvorschlag nachziehen, aber nur,
    /// solange er unangetastet ist.
    private func intervallGewechselt(_ neu: Int) {
        let neuer = neu > 1
            ? Monat.plus(speicher.heuteMonat, neu)
            : speicher.heuteMonat
        if abMonat.trimmingCharacters(in: .whitespaces) == vorschlag {
            abMonat = neuer
        }
        vorschlag = neuer
    }

    private func sichern() {
        let sauberName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sauberName.isEmpty else {
            hinweis = "Der Name fehlt."
            return
        }
        guard let cent = Geld.cent(aus: betragText), cent != 0 else {
            hinweis = "Der Betrag fehlt oder ist nicht zu lesen."
            return
        }
        guard let tag = Int(tagText.trimmingCharacters(in: .whitespaces)), 1...31 ~= tag else {
            hinweis = "Der Tag liegt nicht zwischen 1 und 31."
            return
        }
        guard Monat.gueltig(abMonat) else {
            hinweis = "Den Monat bitte als JJJJ-MM eintragen."
            return
        }
        guard let kategorie = speicher.kategorie(nach: kategorieName) else {
            hinweis = "Bitte eine Kategorie wählen."
            return
        }
        let betrag = einnahme ? abs(cent) : -abs(cent)
        let vorhanden = selten ? abs(Geld.cent(aus: vorhandenText) ?? 0) : 0
        let gruppe = Gruppenwahl.gespeichertWert(
            getippt: gruppentext, angezeigt: "", gespeichert: nil, vorhanden: speicher.gruppen)

        if speicher.postenAnlegen(name: sauberName, betragCent: betrag, tag: tag,
                                  giltAb: abMonat.trimmingCharacters(in: .whitespaces),
                                  kategorieId: kategorie.id, intervall: intervall,
                                  zuruecklegen: !keinTopf, schonVorhanden: vorhanden,
                                  gruppe: gruppe) {
            fertig()
        } else {
            hinweis = speicher.meldung
        }
    }
}
