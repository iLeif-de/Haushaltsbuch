import Charts
import SwiftUI

/// Die Auswertung, aufgebaut wie ui/auswertung.py. Oben Woche, Monat oder Jahr
/// mit zwei Pfeilen, dann die Vergleichskarten, der Verlauf als Balken, die
/// Legende und zuletzt die Aufteilung nach Kategorie oder Gruppe. Ein Klick auf
/// eine Zeile zeigt die Buchungen dahinter, ein Klick auf einen Balken springt
/// zu dessen Zeitraum.
struct Auswertungsansicht: View {
    let speicher: Speicher
    let lenkung: Fokuslenkung

    private enum Feld: Hashable { case art, zurueck, vor, monat, jahrwahl, gruppieren, liste }

    @State private var art: Zeitraumart = .monat
    /// Der Stichtag bleibt beim Umschalten stehen, aus dem September wird also
    /// seine Woche oder sein Jahr und nicht wieder heute.
    @State private var stichtag: String
    @State private var nachGruppe = false
    @State private var auswahl: String?
    @State private var offeneZeile: String?
    @State private var meldung: String?
    @State private var offenes: Feld?
    @State private var breite: CGFloat = 0
    @FocusState private var fokus: Feld?

    /// Die Monatswahl steht nur im Monat in der Kette, die Jahreswahl im Monat
    /// und im Jahr. Im Woche bleibt es bei den zwei Pfeilen (2026-09-25).
    private var kette: [Feld] {
        var glieder: [Feld] = [.art, .zurueck, .vor]
        if art == .monat { glieder.append(.monat) }
        if art != .woche { glieder.append(.jahrwahl) }
        glieder += [.gruppieren, .liste]
        return glieder
    }

    init(speicher: Speicher, lenkung: Fokuslenkung) {
        self.speicher = speicher
        self.lenkung = lenkung
        _stichtag = State(initialValue: Datumsformat.iso.string(from: Date()))
    }

    private var kern: Kern? { speicher.kern }

    /// Der Kopf steht fest, nur die Liste rollt, genau wie in der Übersicht.
    /// Vorher lag alles in einer ScrollView und die Liste hatte ihre eigene,
    /// also zwei Rollbalken übereinander (2026-09-25).
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            kopf
            karten
            Divider()
            diagrammbereich
            if let satz = erklaerung {
                Text(satz).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Divider()
            aufteilungskopf
            zeilen
            if let meldung {
                Text(meldung).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(minWidth: 470, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .breiteMessen(in: $breite)
        .focusSection()
        .onKeyPress(phases: .down) { druck in taste(druck) }
        // Im Monat zeigt die Auswertung denselben Monat wie die Übersicht. Wer
        // dort blättert, findet ihn hier wieder und umgekehrt (2026-09-25).
        .task {
            if art == .monat { stichtag = speicher.monat + "-01" }
        }
        .onChange(of: stichtag) { _, neu in
            if art == .monat, String(neu.prefix(7)) != speicher.monat {
                speicher.monat = String(neu.prefix(7))
            }
        }
        .onChange(of: speicher.monat) { _, neu in
            if art == .monat, String(stichtag.prefix(7)) != neu { stichtag = neu + "-01" }
        }
        .onChange(of: art) { _, neu in
            if neu == .monat, String(stichtag.prefix(7)) != speicher.monat {
                speicher.monat = String(stichtag.prefix(7))
            }
        }
        .onChange(of: lenkung.wunsch) {
            if lenkung.zone == .inhalt { fokus = .liste }
        }
        .onChange(of: fokus) { _, neu in
            if neu != nil { lenkung.meldet(.inhalt) }
        }
        .sheet(item: $offeneZeile) { name in
            Zeilenbuchungen(speicher: speicher, art: art, stichtag: stichtag,
                            name: name, nachGruppe: nachGruppe) { gemeldet in
                offeneZeile = nil
                meldung = gemeldet
            }
        }
    }

    // MARK: Kopf

    private var kopf: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Auswertung").font(.title2).fontWeight(.semibold)
                Spacer()
                Picker("", selection: $art) {
                    ForEach(Zeitraumart.allCases) { Text($0.titel).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .focusable()
                .focused($fokus, equals: .art)
            }
            HStack(spacing: 6) {
                Button { blaettern(-1) } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .help(zurueckHinweis)
                    .focusable()
                    .focused($fokus, equals: .zurueck)
                if art == .woche {
                    Text(Texte.zeitraumName(art, stichtag)).font(.title3)
                } else {
                    // Dieselbe Wahl wie in der Übersicht, damit man nicht in
                    // zwei Bildschirmen zwei verschiedene Bedienungen lernt
                    // (2026-09-25).
                    if art == .monat {
                        Auswahlknopf(wert: Datumsformat.monatName(String(stichtag.prefix(7))),
                                     namen: monatsnamen, fokus: $fokus,
                                     marke: .monat, offenes: $offenes) { name in
                            if let nummer = monatsnamen.firstIndex(of: name) {
                                monatSetzen(monatImJahr: nummer + 1)
                            }
                        }
                        .frame(width: 130)
                        .help("Monat wählen")
                    }
                    Auswahlknopf(wert: String(stichtag.prefix(4)),
                                 namen: jahreswahl, fokus: $fokus,
                                 marke: .jahrwahl, offenes: $offenes) { name in
                        if let gewaehlt = Int(name) { monatSetzen(jahr: gewaehlt) }
                    }
                    .frame(width: 90)
                    .help("Jahr wählen")
                }
                Button { blaettern(1) } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .help(vorHinweis)
                    .focusable()
                    .focused($fokus, equals: .vor)
                Spacer()
                Button("Heute") { stichtag = Datumsformat.iso.string(from: Date()) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private var monatsnamen: [String] {
        (1...12).map { Datumsformat.monatName(String(format: "2000-%02d", $0)) }
    }

    /// Die Jahre aus den Daten, dazu das gerade gezeigte, falls es fehlt.
    private var jahreswahl: [String] {
        var alle = Set(speicher.jahre)
        alle.insert(jahr)
        return alle.sorted().map(String.init)
    }

    /// Setzt Monat oder Jahr des Stichtags, wie die Wahl in der Übersicht.
    private func monatSetzen(jahr neuesJahr: Int? = nil, monatImJahr: Int? = nil) {
        let j = neuesJahr ?? (Int(stichtag.prefix(4)) ?? 2026)
        let m = monatImJahr ?? (Int(stichtag.dropFirst(5).prefix(2)) ?? 1)
        stichtag = String(format: "%04d-%02d-01", j, m)
    }

    private var zurueckHinweis: String {
        switch art {
        case .woche: return "Vorige Woche"
        case .monat: return "Voriger Monat"
        case .jahr: return "Voriges Jahr"
        }
    }

    private var vorHinweis: String {
        switch art {
        case .woche: return "Nächste Woche"
        case .monat: return "Nächster Monat"
        case .jahr: return "Nächstes Jahr"
        }
    }

    private func blaettern(_ schritt: Int) {
        guard let kern else { return }
        stichtag = kern.zeitraumPlus(art, stichtag, schritt)
    }

    // MARK: Vergleichskarten

    private var vergleich: Vergleich? {
        kern?.vergleichZeitraum(art, stichtag)
    }

    private var jahr: Int { Int(stichtag.prefix(4)) ?? 2026 }

    /// Läuft das Jahr noch, also zählt es nicht bis Dezember?
    private var jahrLaeuft: Bool {
        guard art == .jahr, let bis = kern?.jahrBisMonat(jahr) else { return false }
        return bis < "\(jahr)-12"
    }

    @ViewBuilder
    private var karten: some View {
        if let v = vergleich {
            HStack(spacing: 10) {
                switch art {
                case .woche:
                    let vorjahrWoche = kern?.zeitraumPlus(.woche, stichtag, -52) ?? stichtag
                    karte("Gegen die Vorwoche", v.vorher, "in der Vorwoche")
                    karte("Gegen dieselbe Woche im Vorjahr", v.vorjahr,
                          "in KW \(Texte.kalenderwoche(vorjahrWoche)) \(vorjahrWoche.prefix(4))")
                case .monat:
                    let vormonat = kern?.zeitraumPlus(.monat, stichtag, -1) ?? stichtag
                    karte("Gegen den Vormonat", v.vorher,
                          "im " + Datumsformat.monatName(String(vormonat.prefix(7))))
                    karte("Gegen das Vorjahr", v.vorjahr,
                          Datumsformat.monatsname("\(jahr - 1)-\(stichtag.dropFirst(5).prefix(2))"))
                case .jahr:
                    if v.vorher == nil {
                        kartenrahmen("Gegen das Vorjahr") {
                            Text("Noch kein Vergleich, \(jahr - 1) hat keine Buchungen")
                                .font(.callout).fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        karte("Gegen das Vorjahr", v.vorher, jahresbezug(v.vergleichMonate))
                    }
                }
            }
        }
    }

    /// Der Bezug in der Jahreskarte nennt die Spanne, wenn sie kürzer ist als
    /// das Jahr selbst, wie in ui/auswertung.py.
    private func jahresbezug(_ monate: [String]) -> String {
        guard let erstes = monate.first, let letztes = monate.last else { return "\(jahr - 1)" }
        let erster = Datumsformat.monatName(erstes)
        let letzter = Datumsformat.monatName(letztes)
        if erstes.hasSuffix("-01") {
            return "\(jahr - 1)" + (jahrLaeuft ? " bis \(letzter)" : "")
        }
        if erster == letzter { return "\(erster) \(jahr - 1)" }
        return "\(jahr - 1) von \(erster) bis \(letzter)"
    }

    @ViewBuilder
    private func karte(_ ueberschrift: String, _ diff: Int?, _ bezug: String) -> some View {
        if let diff {
            kartenrahmen(ueberschrift) {
                Text(satz(diff, bezug))
                    .font(.callout).fontWeight(.semibold)
                    .foregroundStyle(diff > 0 ? Color.red : Color.green)
            }
        }
    }

    private func kartenrahmen<Inhalt: View>(_ ueberschrift: String,
                                            @ViewBuilder inhalt: () -> Inhalt) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ueberschrift).font(.caption).foregroundStyle(.secondary)
            inhalt()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func satz(_ diff: Int, _ bezug: String) -> String {
        if diff > 0 { return "\(Geld.euro(diff)) mehr als \(bezug)" }
        if diff < 0 { return "\(Geld.euro(-diff)) weniger als \(bezug)" }
        return "gleich viel wie \(bezug)"
    }

    // MARK: Verlauf

    private var verlauf: [Verlaufsbalken] {
        kern?.verlaufZeitraum(art, stichtag) ?? []
    }

    /// Balken und Ring nebeneinander, solange Platz ist. Der Balken zeigt den
    /// Verlauf, der Ring den einen Zeitraum, und rechts war vorher nichts
    /// (2026-09-25).
    /// Wie groß Ring und Balken sein dürfen. Beides wächst mit der Breite,
    /// statt an einer Schwelle zu springen, und hat eine Ober und eine
    /// Untergrenze (2026-09-25).
    /// Die Grafikzeile ist immer gleich hoch, nämlich so hoch wie sie im
    /// schmalsten Fenster sein darf, und zeigt immer beides, Verlauf und Ring
    /// (2026-09-25). Vorher wuchs sie mit dem Fenster, dann sprang beim
    /// Schieben die ganze Seite, und unter einer Schwelle verschwand der Ring.
    private static let grafikhoehe: CGFloat = 180

    /// Die Spalte des Rings. Sie muss die Legende tragen, sonst quetscht die
    /// den Ring zusammen, deshalb ist sie breiter als er (2026-09-25). In der
    /// Breite darf sie mitwachsen, in der Höhe nicht.
    private var ringspalte: CGFloat {
        min(max(breite * 0.28, 150), 300)
    }

    /// Was neben dem Ring für die Balken bleibt, ohne Rand und Zwischenraum.
    private var balkenspalte: CGFloat {
        max(breite - 32 - 16 - ringspalte, 120)
    }

    /// Wie breit ein Balken samt seinem Platz sein darf. Fest 26 Punkte waren
    /// im schmalen Fenster zu viel, die Balken schoben den Ring hinaus
    /// (2026-09-25).
    private func zellbreite(_ anzahl: Int) -> CGFloat {
        guard anzahl > 0 else { return 26 }
        return max((balkenspalte - CGFloat(anzahl - 1) * 4) / CGFloat(anzahl), 8)
    }

    /// Was von der Zeile für die Balken bleibt, ohne Beschriftung und Legende.
    private var balkenhoehe: CGFloat { Self.grafikhoehe - 40 }

    private var diagrammbereich: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                diagramm
                legende
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ring.frame(width: ringspalte)
        }
        .frame(height: Self.grafikhoehe)
    }

    /// Der Ring zeigt denselben Zeitraum wie die Liste darunter und folgt
    /// deshalb auch dem Schalter Kategorie oder Gruppe.
    @ViewBuilder
    private var ring: some View {
        let stuecke = ringdaten
        if stuecke.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(nachGruppe ? "Nach Gruppe" : "Nach Kategorie")
                    .font(.caption).foregroundStyle(.secondary)
                Chart(stuecke) { stueck in
                    SectorMark(angle: .value("Betrag", stueck.betrag),
                               innerRadius: .ratio(0.58),
                               angularInset: 1.5)
                        .cornerRadius(3)
                        .foregroundStyle(by: .value("Name", stueck.name))
                }
                .chartLegend(position: .bottom, alignment: .leading, spacing: 4)
                // Die Mitte des Rings ist nicht die Mitte der Ansicht, die
                // Legende sitzt mit darin. Deshalb über plotFrame, sonst hängt
                // die Summe zu hoch und zu weit links (2026-09-25).
                .chartBackground { flaeche in
                    GeometryReader { raum in
                        if let anker = flaeche.plotFrame {
                            let feld = raum[anker]
                            VStack(spacing: 0) {
                                Text(Geld.euro(stuecke.reduce(0) { $0 + $1.betrag }))
                                    .font(.caption).fontWeight(.semibold).monospacedDigit()
                                    .lineLimit(1).minimumScaleFactor(0.5)
                                Text("Ausgaben").font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).minimumScaleFactor(0.7)
                            }
                            // Das Loch ist schmaler als der Ring, sonst
                            // schreibt sich die Summe über die Stücke
                            // (2026-09-25).
                            .frame(width: min(feld.width, feld.height) * 0.5)
                            .position(x: feld.midX, y: feld.midY)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    /// Die größten sechs, alles Weitere zusammengefasst. Mehr Stücke kann man
    /// im Ring ohnehin nicht auseinanderhalten.
    private var ringdaten: [Ringstueck] {
        let ausgaben = aufteilung.filter { $0.betrag > 0 }
        guard !ausgaben.isEmpty else { return [] }
        // In einer schmalen Spalte bräuchte die Legende vier Zeilen und ließe
        // vom Ring nichts übrig, dann lieber weniger Stücke (2026-09-25).
        var stuecke = ausgaben.prefix(anzahlStuecke)
            .map { Ringstueck(name: $0.kategorie, betrag: $0.betrag) }
        let uebrige = ausgaben.dropFirst(anzahlStuecke).reduce(0) { $0 + $1.betrag }
        if uebrige > 0 { stuecke.append(Ringstueck(name: "Übrige", betrag: uebrige)) }
        return stuecke
    }

    private var anzahlStuecke: Int { ringspalte < 240 ? 4 : 6 }

    struct Ringstueck: Identifiable {
        let name: String
        let betrag: Int
        var id: String { name }
    }

    private var diagramm: some View {
        let balken = verlauf
        let hoechste = max(balken.map(\.gesamt).max() ?? 0, 1)
        let hoehe = balkenhoehe
        let zelle = zellbreite(balken.count)
        let strich = min(26, max(6, zelle - 6))
        let jetzt = kern?.zeitraum(art, stichtag).von
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(balken) { b in
                let gezeigt = b.von == jetzt
                Button {
                    stichtag = b.von
                } label: {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: strich,
                                   height: hoehe * CGFloat(b.variabel) / CGFloat(hoechste))
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.35))
                            .frame(width: strich,
                                   height: hoehe * CGFloat(b.fix) / CGFloat(hoechste))
                        // Der gezeigte Zeitraum bekommt einen Strich und eine
                        // halbfette Beschriftung. Ohne das war nicht zu sehen,
                        // wo man gerade steht (2026-09-25).
                        Rectangle()
                            .fill(gezeigt ? Color.accentColor : Color.clear)
                            .frame(width: strich, height: 2)
                        Text(Texte.zeitraumKurz(art, b.von))
                            .font(.caption2)
                            .fontWeight(gezeigt ? .semibold : .regular)
                            .foregroundStyle(gezeigt ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(width: zelle)
                            // Unter 18 Punkten je Balken steht da nur noch Brei
                            .opacity(zelle >= 18 ? 1 : 0)
                    }
                    .frame(width: zelle, height: hoehe + 20)
                    .background(gezeigt ? Color.accentColor.opacity(0.10) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .zeigefinger()
                .help(balkenhinweis(b))
            }
            Spacer(minLength: 0)
        }
        .frame(height: hoehe + 22)
    }

    private func balkenhinweis(_ b: Verlaufsbalken) -> String {
        let name = Texte.zeitraumName(art, b.von)
        if art == .woche { return "\(name), variabel \(Geld.euro(b.variabel))" }
        return "\(name), gesamt \(Geld.euro(b.gesamt)), fix \(Geld.euro(b.fix)), "
            + "variabel \(Geld.euro(b.variabel))"
    }

    /// Legende und der Hinweis zum Klick in einer Zeile, das spart im Kopf
    /// eine ganze Zeile, und die Liste darunter braucht sie (2026-09-25).
    private var legende: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 10, height: 10)
            Text("Variabel").font(.caption).foregroundStyle(.secondary)
            if art != .woche {
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.35))
                    .frame(width: 10, height: 10)
                Text("Fix und Topfraten").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text("Ein Klick auf einen Balken zeigt dessen Zeitraum")
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var erklaerung: String? {
        if art == .woche {
            return "Feste Posten sind in der Wochenansicht ausgeblendet, eine Miete am Ersten "
                + "würde sonst jede erste Woche des Monats verzerren."
        }
        guard art == .jahr, let v = vergleich else { return nil }
        let unvollstaendig = !(v.vergleichMonate.first?.hasSuffix("-01") ?? true)
        guard jahrLaeuft || unvollstaendig else { return nil }
        var teile: [String] = []
        if jahrLaeuft, let bis = kern?.jahrBisMonat(jahr) {
            teile.append("\(jahr) läuft noch und zählt bis einschließlich "
                         + "\(Datumsformat.monatName(bis)).")
        }
        teile.append("Verglichen wird nur mit Monaten, für die es in \(jahr - 1) schon "
                     + "Buchungen gibt.")
        return teile.joined(separator: " ")
    }

    // MARK: Aufteilung

    private var aufteilungskopf: some View {
        HStack {
            Text("Größte zuerst, ein Klick zeigt die Buchungen")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: $nachGruppe) {
                Text("Nach Kategorie").tag(false)
                Text("Nach Gruppe").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .focusable()
            .focused($fokus, equals: .gruppieren)
        }
    }

    private var aufteilung: [Auswertungszeile] {
        kern?.nachKategorieZeitraum(art, stichtag, nachGruppe: nachGruppe) ?? []
    }

    @ViewBuilder
    private var zeilen: some View {
        let liste = aufteilung
        if liste.isEmpty {
            Text("Noch keine Ausgaben in diesem Zeitraum.").foregroundStyle(.secondary)
        } else {
            let breiteste = max(liste.map { max($0.betrag, $0.vorher) }.max() ?? 0, 1)
            List(selection: $auswahl) {
                ForEach(liste) { zeile in
                    zeilenansicht(zeile, breiteste: breiteste)
                        .tag(zeile.kategorie)
                }
            }
            .listStyle(.inset)
            // Die Liste bekommt, was unter dem Kopf übrig ist, und rollt
            // darin. Die feste Höhe von vorher passte zu keinem Fenster
            // (2026-09-25).
            .frame(maxHeight: .infinity)
            .focused($fokus, equals: .liste)
        }
    }

    private func zeilenansicht(_ zeile: Auswertungszeile, breiteste: Int) -> some View {
        HStack(spacing: 10) {
            Text(zeile.kategorie)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 130, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                balkenstueck(zeile.betrag, breiteste, Color.accentColor)
                    .help("\(Texte.zeitraumName(art, stichtag)), \(Geld.euro(zeile.betrag))")
                balkenstueck(zeile.vorher, breiteste, Color.accentColor.opacity(0.35))
                    .help("\(vorherName), \(Geld.euro(zeile.vorher))")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 0) {
                Text(beschreibung(zeile))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let hinweis = ausreisser(zeile) {
                    Text(hinweis.text)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(hinweis.mehr ? Color.orange : Color.green)
                        .lineLimit(1)
                }
            }
            .frame(width: 210, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture { offeneZeile = zeile.kategorie }
    }

    private func balkenstueck(_ betrag: Int, _ breiteste: Int, _ farbe: Color) -> some View {
        GeometryReader { raum in
            RoundedRectangle(cornerRadius: 3)
                .fill(farbe)
                .frame(width: max(2, raum.size.width * CGFloat(betrag) / CGFloat(breiteste)),
                       height: 10)
        }
        .frame(height: 10)
    }

    private var vorherName: String {
        switch art {
        case .woche: return "Vorwoche"
        case .monat: return "Vormonat"
        case .jahr: return "Vorjahr"
        }
    }

    private func beschreibung(_ zeile: Auswertungszeile) -> String {
        var text = Geld.euro(zeile.betrag)
        if let ueblich = zeile.ueblich, ueblich != 0 {
            text += ", sonst meist um \(Geld.euro(ueblich))"
        }
        return text
    }

    /// Der Ausreißerhinweis, nur im Monat und nur auf dem variablen Teil. Die
    /// Schwellen sind dieselben wie in ui/auswertung.py.
    private func ausreisser(_ zeile: Auswertungszeile) -> (text: String, mehr: Bool)? {
        guard let erwartet = zeile.erwartet, erwartet != 0,
              let anteil = zeile.abweichungAnteil,
              abs(anteil) >= Kern.ausreisserAnteil,
              abs(zeile.abweichungCent) >= Kern.ausreisserCent else { return nil }
        let mehr = zeile.abweichungCent > 0
        return ("\(Geld.euro(abs(zeile.abweichungCent))) \(mehr ? "mehr" : "weniger") als zu "
                + "diesem Zeitpunkt üblich", mehr)
    }

    // MARK: Tasten

    private func taste(_ druck: KeyPress) -> KeyPress.Result {
        if Bereichstasten.tab(druck, ring: { weiter($0) }, wechsel: lenkung.wechseln) {
            return .handled
        }
        if druck.key == .space {
            switch fokus {
            case .zurueck: blaettern(-1); return .handled
            case .vor: blaettern(1); return .handled
            default: break
            }
        }
        // Die beiden Segmentwahlen bedienen sich mit der Leertaste und mit Pfeil
        // links und rechts. Eine aufklappende Liste wäre hier falsch, die
        // Segmente stehen schon sichtbar nebeneinander (2026-09-25).
        if fokus == .monat || fokus == .jahrwahl,
           druck.key == .space || druck.key == .upArrow || druck.key == .downArrow {
            offenes = fokus
            return .handled
        }
        if fokus == .art || fokus == .gruppieren {
            let schritt: Int
            switch druck.key {
            case .space, .rightArrow: schritt = 1
            case .leftArrow: schritt = -1
            default: schritt = 0
            }
            if schritt != 0 {
                if fokus == .art {
                    let alle = Array(Zeitraumart.allCases)
                    let jetzt = alle.firstIndex(of: art) ?? 0
                    art = alle[((jetzt + schritt) % alle.count + alle.count) % alle.count]
                } else {
                    nachGruppe.toggle()
                }
                return .handled
            }
        }
        if fokus == .liste, let name = auswahl, druck.key == .space {
            offeneZeile = name
            return .handled
        }
        return .ignored
    }

    private func weiter(_ schritt: Int, versuche: Int = 0) {
        guard versuche < kette.count else { return }
        let ziel: Feld
        if let jetzt = fokus, let stelle = kette.firstIndex(of: jetzt) {
            ziel = kette[((stelle + schritt) % kette.count + kette.count) % kette.count]
        } else {
            ziel = .liste
        }
        fokus = ziel
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            // Siehe Auswahl.swift, der Fokus bleibt stehen statt zu
            // verschwinden (2026-09-25, gemessen).
            if fokus != ziel {
                weiter(schritt, versuche: versuche + 1)
            }
        }
    }
}

/// Die Buchungen hinter einer Zeile, mit Summe und Export als CSV. Spanne und
/// Filter sind genau die der Zeile, die Summe ergibt also ihren Betrag.
struct Zeilenbuchungen: View {
    let speicher: Speicher
    let art: Zeitraumart
    let stichtag: String
    let name: String
    let nachGruppe: Bool
    /// Meldet zurück, was in der Auswertung stehen soll, etwa der Exportpfad.
    let fertig: (String?) -> Void

    @State private var hinweis: String?

    private var spanne: Spanne? {
        speicher.kern?.auswertungSpanne(art, stichtag)
    }

    private var liste: [Buchung] {
        guard let kern = speicher.kern, let spanne else { return [] }
        return kern.alleBuchungen(von: spanne.von, bis: spanne.bis,
                                  kategorie: nachGruppe ? nil : name,
                                  gruppe: nachGruppe ? name : nil,
                                  nurAusgaben: true, ohneFix: art == .woche)
    }

    var body: some View {
        let buchungen = liste
        let summe = -buchungen.reduce(0) { $0 + $1.betragCent }
        VStack(alignment: .leading, spacing: 8) {
            Text("\(name), \(Texte.zeitraumName(art, stichtag))").font(.headline)
            Text(kopfzeile(buchungen.count, summe))
                .font(.caption)
                .foregroundStyle(.secondary)
            if art == .woche {
                Text("Ohne feste Posten, wie in der Wochenansicht.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            List(buchungen.reversed()) { b in
                HStack(spacing: 8) {
                    Text(Datumsformat.lesbar(b.datum))
                        .frame(width: 84, alignment: .leading)
                    Text(beschreibung(b))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(b.geplant ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Geld.euro(-b.betragCent))
                        .monospacedDigit()
                        .frame(width: 96, alignment: .trailing)
                }
            }
            .listStyle(.inset)
            if let hinweis {
                Text(hinweis).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Als CSV", systemImage: "square.and.arrow.down") {
                    exportieren(buchungen)
                }
                .disabled(buchungen.isEmpty)
                Spacer()
                Button("Schließen") { fertig(nil) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520, height: 440)
        .onExitCommand { fertig(nil) }
    }

    private func kopfzeile(_ anzahl: Int, _ summe: Int) -> String {
        var text = (anzahl == 1 ? "1 Buchung" : "\(anzahl) Buchungen")
            + ", zusammen \(Geld.euro(summe))"
        if art == .jahr, let spanne {
            text += ", vom \(Datumsformat.lesbar(spanne.von)) bis \(Datumsformat.lesbar(spanne.bis))"
        }
        return text
    }

    /// In der Gruppensicht steht dabei, aus welcher Kategorie es kam.
    private func beschreibung(_ b: Buchung) -> String {
        var teile = [b.notiz ?? b.posten ?? ""]
        if nachGruppe { teile.insert(b.kategorie, at: 0) }
        return teile.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private func exportieren(_ buchungen: [Buchung]) {
        guard let spanne else { return }
        let ziel = Ausfuhr.ziel(name: name, von: spanne.von, bis: spanne.bis)
        do {
            try Ausfuhr.csv(buchungen, nach: ziel)
            fertig("Export liegt unter \(ziel.path)")
        } catch {
            hinweis = error.localizedDescription
        }
    }
}

/// Damit sheet(item:) einen Text führen kann.
extension String: @retroactive Identifiable {
    public var id: String { self }
}
