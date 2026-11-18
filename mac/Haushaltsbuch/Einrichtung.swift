import SwiftUI

/// Der Einrichtungsassistent beim ersten Start, vier überspringbare Schritte,
/// aufgebaut wie ui/einrichtung.py, mit denselben Texten und Vorschlägen.
///
/// Geschrieben wird erst am Schluss, siehe Einrichtungsdaten. Zurück nimmt den
/// Plan des verlassenen Schritts wieder weg, es steht also nie etwas halb in
/// der Datenbank.
struct Einrichtungsansicht: View {
    let speicher: Speicher
    /// Wird gerufen, wenn der Assistent durch ist oder übersprungen wurde.
    let fertig: () -> Void

    @State private var schritt = 0
    @State private var daten: Einrichtungsdaten
    @State private var hinweis: String?
    @FocusState private var fokus: Marke?
    @State private var offenes: Marke?

    /// Ein Glied der Kette, Zeile und Spalte. Die Schritte bauen ihre Ketten
    /// daraus, siehe kette.
    enum Marke: Hashable {
        case feld(Int, Int)
        /// Die Knöpfe unter den Zeilen, etwa Weitere Einnahme.
        case aktion(Int)
    }

    init(speicher: Speicher, fertig: @escaping () -> Void) {
        self.speicher = speicher
        self.fertig = fertig
        let vormonat = Monat.plus(speicher.heuteMonat, -1)
        _daten = State(initialValue: Einrichtungsdaten(
            vorhandeneKategorien: Set(speicher.kategorien.map(\.name)),
            heuteMonat: speicher.heuteMonat,
            vormonatEnde: String(format: "%@-%02d", vormonat, Monat.tage(vormonat))))
    }

    private var kategorienamen: [String] { speicher.kategorien.map(\.name) }
    private var gruppen: [String] { Gruppenwahl.auswahl(speicher.gruppen) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    kopf
                    inhalt
                    if let hinweis {
                        Text(hinweis).font(.callout).foregroundStyle(.orange)
                    }
                }
                .padding(24)
                .frame(maxWidth: 1000, alignment: .leading)
            }
            Divider()
            knopfleiste
        }
        .frame(minWidth: 620, minHeight: 540)
        .dialogtasten(fokus: $fokus, kette: kette, listen: listen, ausloesen: ausloesen)
        .task {
            try? await Task.sleep(for: .milliseconds(200))
            fokus = kette.first
        }
    }

    // MARK: Kopf und Fuß

    private var kopf: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Einrichtung").font(.title).fontWeight(.semibold)
            HStack(spacing: 6) {
                ForEach(Array(schrittNamen.enumerated()), id: \.offset) { i, name in
                    Text("\(i + 1). \(name)")
                        .font(.caption)
                        .fontWeight(i == schritt ? .semibold : .regular)
                        .foregroundStyle(i == schritt ? Color.accentColor
                                         : (i < schritt ? Color.primary : Color.secondary))
                    if i < schrittNamen.count - 1 {
                        Image(systemName: "chevron.right").font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text(schrittNamen[schritt]).font(.title3).fontWeight(.semibold)
        }
    }

    private var knopfleiste: some View {
        HStack(spacing: 10) {
            Button("Zurück") { zurueck() }
                .disabled(schritt == 0)
            Button("Diesen Schritt überspringen") { ueberspringen() }
            Spacer()
            Button("Einrichtung überspringen") { abschliessen(alles: false) }
            Button(schritt == schrittNamen.count - 1 ? "Fertig" : "Weiter") { weiter() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: Ablauf

    private func weiter() {
        switch daten.auftraege(schritt: schritt, heuteMonat: speicher.heuteMonat) {
        case .failure(let fehler):
            hinweis = fehler.text
        case .success(let auftraege):
            hinweis = nil
            daten.plaene[schritt] = auftraege
            if schritt < schrittNamen.count - 1 {
                schritt += 1
                fokus = kette.first
            } else {
                abschliessen(alles: true)
            }
        }
    }

    private func zurueck() {
        guard schritt > 0 else { return }
        hinweis = nil
        // Der Plan des verlassenen Schritts wird verworfen, er entsteht beim
        // nächsten Weiter neu aus den Feldern.
        daten.plaene[schritt] = nil
        schritt -= 1
        daten.plaene[schritt] = nil
        fokus = kette.first
    }

    private func ueberspringen() {
        hinweis = nil
        daten.plaene[schritt] = []
        if schritt < schrittNamen.count - 1 {
            schritt += 1
            fokus = kette.first
        } else {
            abschliessen(alles: true)
        }
    }

    /// Schreibt alle bestätigten Schritte in ihrer Reihenfolge, der Kontostand
    /// also vor den Posten.
    private func abschliessen(alles: Bool) {
        let plaene = alles ? daten.plaene : [:]
        if !speicher.einrichtungSchreiben(plaene.sorted { $0.key < $1.key }.flatMap(\.value)) {
            hinweis = speicher.meldung
            return
        }
        fertig()
    }

    // MARK: Die Kette

    /// Die Glieder des aktuellen Schritts, Zeile für Zeile. Sie wird bei jedem
    /// Tastendruck frisch gebildet, die Zeilen wachsen ja.
    private var kette: [Marke] {
        var glieder: [Marke] = []
        for (zeile, spalten) in spaltenJeZeile.enumerated() {
            for spalte in 0..<spalten { glieder.append(.feld(zeile, spalte)) }
        }
        // Die Knöpfe unter den Zeilen gehören dazu, sonst kommt man mit der
        // Tastatur nie an Weitere Einnahme oder Eigener Posten (2026-09-24).
        glieder += (0..<aktionen).map { Marke.aktion($0) }
        return glieder
    }

    /// Wie viele Knöpfe der Schritt unter seinen Zeilen hat.
    private var aktionen: Int {
        switch schritt {
        case 0: return 0
        case 3: return 2
        default: return 1
        }
    }

    /// Was die Leertaste auf einem Glied tut. Dieselbe Regel wie überall,
    /// Leertaste löst aus, Enter gehört dem Standardknopf, hier also Weiter.
    private func ausloesen(_ glied: Marke) -> Bool {
        switch glied {
        case .aktion(let nummer):
            zeileHinzufuegen(nummer)
            return true
        case .feld(let zeile, let spalte):
            // Der Haken einer Zeile in Schritt 3
            if schritt == 2, spalte == 0, daten.fixposten.indices.contains(zeile) {
                daten.fixposten[zeile].aktiv.toggle()
                return true
            }
            guard listen.contains(glied) else { return false }
            offenes = glied
            return true
        }
    }

    /// Die Glieder, die eine Auswahlliste aufklappen, also Kategorie,
    /// Gruppenauslöser und Intervall.
    private var listen: Set<Marke> {
        var raus: Set<Marke> = []
        switch schritt {
        case 2:
            for zeile in daten.fixposten.indices {
                raus.insert(.feld(zeile, 4))
                raus.insert(.feld(zeile, 6))
            }
        case 3:
            for zeile in daten.periodisch.indices {
                raus.insert(.feld(zeile, 3))
                raus.insert(.feld(zeile, 5))
                raus.insert(.feld(zeile, 7))
            }
            let versatz = daten.periodisch.count
            for zeile in daten.toepfe.indices {
                raus.insert(.feld(versatz + zeile, 5))
                raus.insert(.feld(versatz + zeile, 7))
            }
        default:
            break
        }
        return raus
    }

    private func zeileHinzufuegen(_ nummer: Int) {
        switch schritt {
        case 1:
            daten.einnahmen.append(Einrichtungsdaten.Einnahme())
        case 2:
            daten.fixposten.append(Einrichtungsdaten.Fixposten(aktiv: true))
        case 3:
            if nummer == 0 {
                daten.periodisch.append(Einrichtungsdaten.Periodisch(
                    faelligkeit: Monat.plus(speicher.heuteMonat, 12)))
            } else {
                daten.toepfe.append(Einrichtungsdaten.EigenerTopf())
            }
        default:
            break
        }
    }

    /// Wie viele Felder jede Zeile des Schritts hat.
    private var spaltenJeZeile: [Int] {
        switch schritt {
        case 0: return [2]
        case 1: return daten.einnahmen.map { _ in 3 }
        case 2: return daten.fixposten.map { _ in 7 }
        default: return daten.periodisch.map { _ in 10 } + daten.toepfe.map { _ in 9 }
        }
    }

    // MARK: Die vier Schritte

    @ViewBuilder
    private var inhalt: some View {
        switch schritt {
        case 0: schrittKontostand
        case 1: schrittEinnahmen
        case 2: schrittFixkosten
        default: schrittRuecklagen
        }
    }

    private var schrittKontostand: some View {
        VStack(alignment: .leading, spacing: 16) {
            Hilfetext("Das Programm rechnet deinen Kontostand selbst weiter und braucht dafür "
                      + "einen Ausgangswert.")
            Hilfetext("Nimm am besten den Stand vom **letzten Tag des Vormonats**, bevor Gehalt "
                      + "oder Miete für diesen Monat gebucht wurden. Diese Buchungen trägt das "
                      + "Programm aus den nächsten Schritten selbst ein, sie würden sonst "
                      + "doppelt zählen.")
            Fliesslayout(abstand: 10) {
                TextField("Kontostand in Euro", text: $daten.kontostand)
                    .frame(width: 200)
                    .focused($fokus, equals: .feld(0, 0))
                DatePicker("", selection: $daten.kontodatum, displayedComponents: .date)
                    .datePickerStyle(.stepperField)
                    .labelsHidden()
                    .focusable()
                    .focused($fokus, equals: .feld(0, 1))
            }
            Hilfetext("Den Wert kannst du später in den Einstellungen jederzeit korrigieren.")
        }
    }

    private var schrittEinnahmen: some View {
        VStack(alignment: .leading, spacing: 16) {
            Hilfetext("Hier trägst du Einnahmen ein, die **jeden Monat** kommen, meist das "
                      + "Gehalt. Das Programm bucht sie ab diesem Monat an dem angegebenen Tag "
                      + "automatisch.")
            VStack(spacing: 8) {
                ForEach(Array(daten.einnahmen.enumerated()), id: \.element.id) { i, _ in
                    Eintragskasten {
                        TextField("Bezeichnung", text: $daten.einnahmen[i].name)
                            .frame(width: 170)
                            .focused($fokus, equals: .feld(i, 0))
                        TextField("Betrag in Euro", text: $daten.einnahmen[i].betrag)
                            .frame(width: 140)
                            .focused($fokus, equals: .feld(i, 1))
                        TextField("Tag im Monat", text: $daten.einnahmen[i].tag)
                            .frame(width: 110)
                            .focused($fokus, equals: .feld(i, 2))
                    }
                }
            }
            Button("Weitere Einnahme", systemImage: "plus") { zeileHinzufuegen(0) }
                .buttonStyle(.link)
                .focusable()
                .focused($fokus, equals: .aktion(0))
            Hilfetext("Einmalige Einnahmen wie eine Steuererstattung gehören nicht hierher, die "
                      + "trägst du später einfach in der Schnelleingabe ein.")
        }
    }

    private var schrittFixkosten: some View {
        VStack(alignment: .leading, spacing: 16) {
            Hilfetext("Hier kommen nur Ausgaben hin, die **jeden Monat** abgebucht werden, etwa "
                      + "Miete, Strom oder Handy. Hake an, was bei dir anfällt, und trag Betrag "
                      + "und Tag der Abbuchung ein.")
            Hilfetext("Die **Gruppe** fasst für die Auswertung zusammen, am besten nach "
                      + "Lebensbereich, etwa Wohnen oder Auto. Sie ist schon vorgeschlagen, du "
                      + "kannst sie ändern oder leeren.")
            Hilfetext("Denk auch an das, was die **Bank selbst abbucht**, etwa die Kontoführung. "
                      + "Solche Buchungen stehen nur auf dem Kontoauszug und werden leicht "
                      + "vergessen, dann stimmt der Kontostand im Programm nicht mehr.")
            Hilfetext("Periodische Ausgaben, die nur alle paar Monate fällig sind, etwa die Kfz "
                      + "Versicherung einmal im Jahr, trägst du **im nächsten Schritt** ein. "
                      + "Dort legt das Programm dafür jeden Monat etwas zurück.")
            VStack(spacing: 8) {
                ForEach(Array(daten.fixposten.enumerated()), id: \.element.id) { i, eintrag in
                    Eintragskasten {
                        Toggle("", isOn: $daten.fixposten[i].aktiv)
                            .labelsHidden()
                            .focusable()
                            .focused($fokus, equals: .feld(i, 0))
                        // Die Felder einer nicht angehakten Zeile sind grau,
                        // der Haken selbst bleibt bedienbar
                        Group {
                            TextField("Bezeichnung", text: $daten.fixposten[i].name)
                                .frame(width: 150)
                                .focused($fokus, equals: .feld(i, 1))
                            TextField("Betrag in Euro", text: $daten.fixposten[i].betrag)
                                .frame(width: 120)
                                .focused($fokus, equals: .feld(i, 2))
                            TextField("Tag", text: $daten.fixposten[i].tag)
                                .frame(width: 60)
                                .focused($fokus, equals: .feld(i, 3))
                            Auswahlknopf(wert: eintrag.kategorie.isEmpty ? "Kategorie"
                                             : eintrag.kategorie,
                                         namen: kategorienamen, fokus: $fokus,
                                         marke: .feld(i, 4), offenes: $offenes) {
                                daten.fixposten[i].kategorie = $0
                            }
                            .frame(width: 150)
                            Gruppenzeile(text: $daten.fixposten[i].gruppe, vorhanden: gruppen,
                                         fokus: $fokus, feldMarke: .feld(i, 5),
                                         knopfMarke: .feld(i, 6), offenes: $offenes)
                                .frame(width: 170)
                        }
                        .disabled(!eintrag.aktiv)
                    }
                }
            }
            Button("Eigener Posten", systemImage: "plus") { zeileHinzufuegen(0) }
                .buttonStyle(.link)
                .focusable()
                .focused($fokus, equals: .aktion(0))
        }
    }

    private var schrittRuecklagen: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Periodische Ausgaben").font(.headline)
            Hilfetext("Ausgaben, die regelmäßig, aber **nicht jeden Monat** fällig sind, sondern "
                      + "vierteljährlich, halbjährlich oder jährlich, etwa Kfz Versicherung oder "
                      + "Kfz Steuer. Trag den **vollen Betrag** ein und den Monat, in dem er "
                      + "**das nächste Mal** abgebucht wird.")
            Hilfetext("Als **Gruppe** trägst du den Lebensbereich ein, bei der Kfz Versicherung "
                      + "und der Kfz Steuer also Auto. Versicherungen und Steuern haben bewusst "
                      + "keine Vorgabe, sie gehören je nach Posten in ganz verschiedene Bereiche.")
            Hilfetext("Das Programm legt dafür jeden Monat einen Teil in einen Topf zurück. So "
                      + "ist das Geld da, wenn die Rechnung kommt, und dein Monatsbudget springt "
                      + "in diesem Monat nicht ins Minus. Hast du schon etwas beiseitegelegt, "
                      + "trag es unter Schon zurückgelegt ein.")
            ForEach(Array(daten.periodisch.enumerated()), id: \.element.id) { i, eintrag in
                periodischeZeile(i, eintrag)
            }
            Button("Weitere periodische Ausgabe", systemImage: "plus") { zeileHinzufuegen(0) }
                .buttonStyle(.link)
                .focusable()
                .focused($fokus, equals: .aktion(0))

            Divider()
            Text("Eigene Töpfe").font(.headline)
            Hilfetext("Für ein Sparziel ohne feste Rechnung, etwa den Urlaub im nächsten Sommer. "
                      + "Gib entweder eine **monatliche Rate** an oder ein **Ziel mit Monat**, "
                      + "dann rechnet das Programm die Rate selbst aus. Ein Topf ohne Ziel eignet "
                      + "sich auch als Puffer für größere Anschaffungen.")
            ForEach(Array(daten.toepfe.enumerated()), id: \.element.id) { i, eintrag in
                topfZeile(i, eintrag, versatz: daten.periodisch.count)
            }
            Button("Topf hinzufügen", systemImage: "plus") { zeileHinzufuegen(1) }
                .buttonStyle(.link)
                .focusable()
                .focused($fokus, equals: .aktion(1))
        }
    }

    private func periodischeZeile(_ i: Int, _ eintrag: Einrichtungsdaten.Periodisch) -> some View {
        Eintragskasten {
            TextField("Name", text: $daten.periodisch[i].name)
                .frame(width: 140)
                .focused($fokus, equals: .feld(i, 0))
            TextField("Betrag in Euro", text: $daten.periodisch[i].betrag)
                .frame(width: 120)
                .focused($fokus, equals: .feld(i, 1))
            TextField("Tag", text: $daten.periodisch[i].tag)
                .frame(width: 60)
                .focused($fokus, equals: .feld(i, 2))
            Auswahlknopf(wert: intervallName(eintrag.intervall),
                         namen: intervalle.map(\.name), fokus: $fokus,
                         marke: .feld(i, 3), offenes: $offenes) { name in
                guard let zahl = intervalle.first(where: { $0.name == name })?.zahl else { return }
                let alterVorschlag = Monat.plus(speicher.heuteMonat,
                                                daten.periodisch[i].intervall)
                daten.periodisch[i].intervall = zahl
                // Nur nachziehen, solange die Vorgabe unangetastet ist
                if daten.periodisch[i].faelligkeit == alterVorschlag {
                    daten.periodisch[i].faelligkeit = Monat.plus(speicher.heuteMonat, zahl)
                }
            }
            .frame(width: 150)
            TextField("Fällig JJJJ-MM", text: $daten.periodisch[i].faelligkeit)
                .frame(width: 130)
                .focused($fokus, equals: .feld(i, 4))
            Auswahlknopf(wert: eintrag.kategorie.isEmpty ? "Kategorie" : eintrag.kategorie,
                         namen: kategorienamen, fokus: $fokus,
                         marke: .feld(i, 5), offenes: $offenes) {
                daten.periodisch[i].kategorie = $0
            }
            .frame(width: 150)
            Gruppenzeile(text: $daten.periodisch[i].gruppe, vorhanden: gruppen, fokus: $fokus,
                         feldMarke: .feld(i, 6), knopfMarke: .feld(i, 7),
                         offenes: $offenes)
                .frame(width: 160)
            TextField("Schon zurückgelegt", text: $daten.periodisch[i].vorhanden)
                .frame(width: 140)
                .focused($fokus, equals: .feld(i, 8))
        }
    }

    private func topfZeile(_ i: Int, _ eintrag: Einrichtungsdaten.EigenerTopf,
                           versatz: Int) -> some View {
        Eintragskasten {
            TextField("Name", text: $daten.toepfe[i].name)
                .frame(width: 140)
                .focused($fokus, equals: .feld(versatz + i, 0))
            TextField("Ziel in Euro", text: $daten.toepfe[i].ziel)
                .frame(width: 120)
                .focused($fokus, equals: .feld(versatz + i, 1))
            TextField("Rate im Monat", text: $daten.toepfe[i].rate)
                .frame(width: 120)
                .focused($fokus, equals: .feld(versatz + i, 2))
            TextField("Voll bis JJJJ-MM", text: $daten.toepfe[i].zielmonat)
                .frame(width: 130)
                .focused($fokus, equals: .feld(versatz + i, 3))
            TextField("Schon vorhanden", text: $daten.toepfe[i].vorhanden)
                .frame(width: 130)
                .focused($fokus, equals: .feld(versatz + i, 4))
            Auswahlknopf(wert: eintrag.kategorie.isEmpty ? "Kategorie" : eintrag.kategorie,
                         namen: kategorienamen, fokus: $fokus,
                         marke: .feld(versatz + i, 5), offenes: $offenes) {
                daten.toepfe[i].kategorie = $0
            }
            .frame(width: 150)
            Gruppenzeile(text: $daten.toepfe[i].gruppe, vorhanden: gruppen, fokus: $fokus,
                         feldMarke: .feld(versatz + i, 6),
                         knopfMarke: .feld(versatz + i, 7), offenes: $offenes)
                .frame(width: 160)
        }
    }

    private let intervalle: [(zahl: Int, name: String)] = [
        (3, "vierteljährlich"), (6, "halbjährlich"), (12, "jährlich"),
    ]

    private func intervallName(_ zahl: Int) -> String {
        intervalle.first { $0.zahl == zahl }?.name ?? "jährlich"
    }
}

/// Hilfetext eines Schritts. Was zwischen zwei Sternchenpaaren steht, wird fett
/// und farbig hervorgehoben, wie in Markdown und wie in ui/einrichtung.py.
struct Hilfetext: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(attribut)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Ein Text aus Stücken, die fett und rot sein dürfen. Als AttributedString
    /// und nicht mehr mit + zusammengesetzt, das ist ab macOS 26 veraltet
    /// (2026-10-05).
    private var attribut: AttributedString {
        var raus = AttributedString()
        for teil in teile {
            var stueck = AttributedString(teil.text)
            if teil.hervor {
                stueck.inlinePresentationIntent = .stronglyEmphasized
                stueck.foregroundColor = .red
            }
            raus.append(stueck)
        }
        return raus
    }

    private var teile: [(text: String, hervor: Bool)] {
        text.components(separatedBy: "**").enumerated().map { ($0.element, $0.offset % 2 == 1) }
    }
}
