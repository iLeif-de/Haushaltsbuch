import Foundation

/// Die Auswertung nach Woche, Monat und Jahr, eins zu eins nach haushalt/kern.py.
///
/// Die Woche blendet feste Posten aus und vergleicht mit der Woche 52 Wochen
/// zuvor. Ein laufendes Jahr vergleicht nur mit demselben Stück des Vorjahres
/// und nur über Monate, für die es dort schon Buchungen gibt. Das Übliche und
/// den Ausreißerhinweis gibt es nur im Monat.

enum Zeitraumart: String, CaseIterable, Identifiable {
    case woche, monat, jahr

    var id: String { rawValue }

    var titel: String {
        switch self {
        case .woche: return "Woche"
        case .monat: return "Monat"
        case .jahr: return "Jahr"
        }
    }
}

/// Ein Zeitraum als Tage, beide Enden eingeschlossen.
struct Spanne {
    let von: String
    let bis: String
}

/// Eine Zeile der Kategorieliste, wie nach_kategorie_zeitraum sie liefert.
struct Auswertungszeile: Identifiable {
    let kategorie: String
    let betrag: Int
    let variabel: Int
    let vorher: Int
    let ueblich: Int?
    let erwartet: Int?
    let abweichungCent: Int
    let abweichungAnteil: Double?

    var id: String { kategorie }
}

/// Ein Balken des Verlaufs.
struct Verlaufsbalken: Identifiable {
    let von: String
    let bis: String
    let fix: Int
    let variabel: Int

    var id: String { von }
    var gesamt: Int { fix + variabel }
}

/// Die Vergleichszahlen eines Zeitraums.
struct Vergleich {
    let art: Zeitraumart
    let ausgaben: Int
    /// Differenz zum Zeitraum davor, positiv heißt mehr ausgegeben. Nil beim
    /// Jahr, wenn es im Vorjahr keine vergleichbaren Monate gibt.
    let vorher: Int?
    /// Differenz zum selben Zeitraum ein Jahr zuvor. Beim Jahr fällt das mit
    /// vorher zusammen und bleibt deshalb nil.
    let vorjahr: Int?
    /// Die Monate, über die beim Jahr verglichen wird.
    let vergleichMonate: [String]
}

extension Kern {
    // MARK: Zeiträume

    /// Von und bis des Zeitraums, der den Stichtag enthält. Eine Woche beginnt
    /// am Montag, wie im Kalender üblich.
    func zeitraum(_ art: Zeitraumart, _ stichtag: String) -> Spanne {
        switch art {
        case .woche:
            let von = Tage.plus(stichtag, -Tage.wochentag(stichtag))
            return Spanne(von: von, bis: Tage.plus(von, 6))
        case .monat:
            let monat = String(stichtag.prefix(7))
            return Spanne(von: monat + "-01",
                          bis: String(format: "%@-%02d", monat, Monat.tage(monat)))
        case .jahr:
            let jahr = String(stichtag.prefix(4))
            return Spanne(von: jahr + "-01-01", bis: jahr + "-12-31")
        }
    }

    /// Der Stichtag n Zeiträume später. Der Tag im Monat bleibt stehen, soweit
    /// es ihn gibt, der 31. wird im Februar zum 28. oder 29.
    func zeitraumPlus(_ art: Zeitraumart, _ stichtag: String, _ n: Int) -> String {
        let tag = Int(stichtag.suffix(2)) ?? 1
        switch art {
        case .woche:
            return Tage.plus(stichtag, 7 * n)
        case .monat:
            return tagImMonat(Monat.plus(String(stichtag.prefix(7)), n), tag)
        case .jahr:
            let jahr = (Int(stichtag.prefix(4)) ?? 2026) + n
            let monatImJahr = String(stichtag.dropFirst(5).prefix(2))
            return tagImMonat(String(format: "%04d-%@", jahr, monatImJahr), tag)
        }
    }

    /// Ein gültiges Datum im Monat, der 31. wird im Februar zum 28. oder 29.
    private func tagImMonat(_ monat: String, _ tag: Int) -> String {
        String(format: "%@-%02d", monat, min(tag, Monat.tage(monat)))
    }

    // MARK: Summen

    /// Ausgaben eines Monats, wie der Vergleich sie zählt. Alle negativen
    /// Buchungen ohne Topfbuchungen, plus die Topfraten. Die glätten nicht
    /// monatliche Posten, eine Topfbuchung ist über die Rate schon gezählt.
    func ausgabenMonat(_ m: String) -> Int {
        let summe = zahl("""
            SELECT COALESCE(SUM(betrag_cent),0) AS s FROM buchungen
            WHERE substr(datum,1,7)=? AND betrag_cent<0 AND topf_id IS NULL
            """, [.text(m)])
        return -summe + topfraten(m)
    }

    /// Fix und variabel eines Monats als positive Cent. Fix enthält die Topfraten.
    func fixVariabelMonat(_ m: String) -> (fix: Int, variabel: Int) {
        let zeile = (try? db.zeilen("""
            SELECT COALESCE(SUM(CASE WHEN regel_id IS NOT NULL AND topf_id IS NULL THEN betrag_cent END),0) AS fix,
                   COALESCE(SUM(CASE WHEN regel_id IS NULL AND topf_id IS NULL THEN betrag_cent END),0) AS variabel
            FROM buchungen WHERE substr(datum,1,7)=? AND betrag_cent<0
            """, [.text(m)]).first) ?? [:]
        return (-(zeile["fix"]?.alsGanz ?? 0) + topfraten(m), -(zeile["variabel"]?.alsGanz ?? 0))
    }

    /// Variable Ausgaben zwischen von und bis. Feste Posten bleiben in der
    /// Woche draußen, eine Miete am Ersten würde sonst jede erste Woche des
    /// Monats verzerren. Topfbuchungen auch.
    func ausgabenWoche(_ von: String, _ bis: String) -> Int {
        -zahl("""
            SELECT COALESCE(SUM(betrag_cent),0) AS s FROM buchungen
            WHERE datum>=? AND datum<=? AND betrag_cent<0
            AND regel_id IS NULL AND topf_id IS NULL
            """, [.text(von), .text(bis)])
    }

    /// Die Monate eines Jahres, die schon begonnen haben. Ein künftiger Monat
    /// hat keine Buchungen, wohl aber Topfraten, und würde das Jahr schief machen.
    func monateImJahr(_ jahr: Int) -> [String] {
        let letzter = min(String(format: "%04d-12", jahr), Monat.von(heute))
        return (1...12).map { String(format: "%04d-%02d", jahr, $0) }.filter { $0 <= letzter }
    }

    /// Der letzte gezählte Monat eines Jahres, nil für ein künftiges Jahr.
    func jahrBisMonat(_ jahr: Int) -> String? {
        monateImJahr(jahr).last
    }

    // MARK: Vergleich

    func vergleichZeitraum(_ art: Zeitraumart, _ stichtag: String) -> Vergleich {
        switch art {
        case .monat:
            let m = String(stichtag.prefix(7))
            let ist = ausgabenMonat(m)
            return Vergleich(art: art, ausgaben: ist,
                             vorher: ist - ausgabenMonat(Monat.plus(m, -1)),
                             vorjahr: ist - ausgabenMonat(Monat.plus(m, -12)),
                             vergleichMonate: [])
        case .woche:
            func woche(_ tag: String) -> Int {
                let s = zeitraum(.woche, tag)
                return ausgabenWoche(s.von, s.bis)
            }
            // 52 Wochen zuvor, damit dieselben Wochentage gegenüberstehen
            let ist = woche(stichtag)
            return Vergleich(art: art, ausgaben: ist,
                             vorher: ist - woche(Tage.plus(stichtag, -7)),
                             vorjahr: ist - woche(Tage.plus(stichtag, -7 * 52)),
                             vergleichMonate: [])
        case .jahr:
            let jahr = Int(stichtag.prefix(4)) ?? 2026
            let monate = monateImJahr(jahr)
            let ist = monate.reduce(0) { $0 + ausgabenMonat($1) }
            // Nur Monate vergleichen, für die es im Vorjahr schon Buchungen
            // gibt. Wer im Juli angefangen hat, hätte sonst ein Vorjahr mit
            // sechs leeren Monaten, und das Jahr darauf sähe viel teurer aus.
            let erster = ersterMonat()
            let vergleichbar = monate.filter { m in
                guard let erster else { return false }
                return Monat.plus(m, -12) >= erster
            }
            var vorher: Int?
            if !vergleichbar.isEmpty {
                let jetzt = vergleichbar.reduce(0) { $0 + ausgabenMonat($1) }
                let davor = vergleichbar.reduce(0) { $0 + ausgabenMonat(Monat.plus($1, -12)) }
                vorher = jetzt - davor
            }
            return Vergleich(art: art, ausgaben: ist, vorher: vorher, vorjahr: nil,
                             vergleichMonate: vergleichbar)
        }
    }

    // MARK: Verlauf

    /// Die Reihe endet mit dem Zeitraum des Stichtags. In der Woche ist fix
    /// immer null, feste Posten sind dort ausgeblendet. Beim Jahr beginnt die
    /// Reihe mit dem ersten Jahr, in dem es Buchungen gibt.
    func verlaufZeitraum(_ art: Zeitraumart, _ stichtag: String, anzahl: Int = 12) -> [Verlaufsbalken] {
        switch art {
        case .monat:
            let bis = String(stichtag.prefix(7))
            return (0..<anzahl).reversed().map { i in
                let m = Monat.plus(bis, -i)
                let s = zeitraum(.monat, m + "-01")
                let werte = fixVariabelMonat(m)
                return Verlaufsbalken(von: s.von, bis: s.bis, fix: werte.fix,
                                      variabel: werte.variabel)
            }
        case .woche:
            return (0..<anzahl).reversed().map { i in
                let s = zeitraum(.woche, Tage.plus(stichtag, -7 * i))
                return Verlaufsbalken(von: s.von, bis: s.bis, fix: 0,
                                      variabel: ausgabenWoche(s.von, s.bis))
            }
        case .jahr:
            let dieses = Int(stichtag.prefix(4)) ?? 2026
            let erstes = Int(ersterMonat()?.prefix(4) ?? "") ?? dieses
            let start = min(max(erstes, dieses - anzahl + 1), dieses)
            return (start...dieses).map { jahr in
                var fix = 0, variabel = 0
                for m in monateImJahr(jahr) {
                    let werte = fixVariabelMonat(m)
                    fix += werte.fix
                    variabel += werte.variabel
                }
                let s = zeitraum(.jahr, String(format: "%04d-01-01", jahr))
                return Verlaufsbalken(von: s.von, bis: s.bis, fix: fix, variabel: variabel)
            }
        }
    }

    // MARK: Nach Kategorie

    /// Ausgaben je Kategorie oder Gruppe zwischen von und bis, als Name auf
    /// Betrag und variablen Teil, in positiven Cent. Dieselbe Rechnung wie
    /// v_kategorie_monat, nur über beliebige Tage.
    private func summenNachKategorie(_ von: String, _ bis: String, nachGruppe: Bool,
                                     ohneFix: Bool = false) -> [String: (Int, Int)] {
        let feld = nachGruppe
            ? "COALESCE(NULLIF(COALESCE(b.gruppe, r.gruppe, t.gruppe, k.gruppe), ''), k.name)"
            : "k.name"
        var sql = """
            SELECT \(feld) AS bezeichnung, SUM(b.betrag_cent) AS s,
                   SUM(CASE WHEN b.regel_id IS NULL THEN b.betrag_cent ELSE 0 END) AS v
            FROM buchungen b
            JOIN buchung_kategorien bk ON bk.buchung_id = b.id
            JOIN kategorien k          ON k.id = bk.kategorie_id
            LEFT JOIN regeln r         ON r.id = b.regel_id
            LEFT JOIN toepfe t         ON t.id = b.topf_id
            WHERE b.betrag_cent < 0 AND b.datum >= ? AND b.datum <= ?
            """
        if ohneFix { sql += " AND b.regel_id IS NULL" }
        // Nach der ersten Spalte gruppieren, name wäre mehrdeutig
        sql += " GROUP BY 1"
        var raus: [String: (Int, Int)] = [:]
        for zeile in (try? db.zeilen(sql, [.text(von), .text(bis)])) ?? [] {
            guard let name = zeile["bezeichnung"]?.alsText else { continue }
            raus[name] = (-(zeile["s"]?.alsGanz ?? 0), -(zeile["v"]?.alsGanz ?? 0))
        }
        return raus
    }

    /// Die Tage, über die die Kategorieliste zählt. Ein Jahr zählt nur bis zum
    /// Ende des aktuellen Monats, ein künftiges Jahr liefert nil. Die Liste der
    /// Buchungen hinter einer Zeile nimmt dieselbe Spanne, so ergibt sie immer
    /// genau den Betrag der Zeile.
    func auswertungSpanne(_ art: Zeitraumart, _ stichtag: String) -> Spanne? {
        guard art == .jahr else { return zeitraum(art, stichtag) }
        let monate = monateImJahr(Int(stichtag.prefix(4)) ?? 2026)
        guard let erster = monate.first, let letzter = monate.last else { return nil }
        return Spanne(von: erster + "-01", bis: zeitraum(.monat, letzter + "-01").bis)
    }

    /// Die Aufteilung nach Kategorien oder Gruppen im Monat, mit dem Üblichen
    /// und dem Ausreißerhinweis. Der betrachtet nur den variablen Teil, denn
    /// anteilig zum Monat lässt sich nur erwarten, was sich über den Monat
    /// verteilt. Eine Miete geht am Ersten in einer Summe ab.
    func nachKategorie(_ monat: String, nachGruppe: Bool) -> [Auswertungszeile] {
        let vor = Monat.plus(monat, -1)
        let feld = nachGruppe ? "COALESCE(gruppe, kategorie)" : "kategorie"
        var betrag: [String: Int] = [:], vormonat: [String: Int] = [:], variabel: [String: Int] = [:]
        // Die Reihenfolge des ersten Auftretens wird gemerkt. Python baut hier
        // ein Wörterbuch und sortiert danach stabil, bei gleichem Betrag bleibt
        // also diese Reihenfolge stehen (2026-09-24).
        var reihenfolge: [String] = []
        for zeile in (try? db.zeilen("""
            SELECT monat, \(feld) AS name, betrag_cent, variabel_cent FROM v_kategorie_monat
            WHERE monat IN (?,?)
            """, [.text(monat), .text(vor)])) ?? [] {
            guard let name = zeile["name"]?.alsText else { continue }
            if !reihenfolge.contains(name) { reihenfolge.append(name) }
            let wert = -(zeile["betrag_cent"]?.alsGanz ?? 0)
            if zeile["monat"]?.alsText == monat {
                betrag[name, default: 0] += wert
                variabel[name, default: 0] += -(zeile["variabel_cent"]?.alsGanz ?? 0)
            } else {
                vormonat[name, default: 0] += wert
            }
        }
        let anteil = monatAnteil(monat)
        var zeilen: [Auswertungszeile] = []
        for name in reihenfolge {
            let ueblich = uebliches(name, monat: monat, gruppe: nachGruppe)
            let ueblichVariabel = uebliches(name, monat: monat, gruppe: nachGruppe,
                                            nurVariabel: true)
            var erwartet: Int?
            if let ueblichVariabel, ueblichVariabel != 0, anteil >= 0.1 {
                // Halb auf gerade, wie round() in Python, sonst liegt ein
                // Wert auf genau ,5 um einen Cent daneben (2026-09-26)
                erwartet = Int((Double(ueblichVariabel) * anteil).rounded(.toNearestOrEven))
            }
            let varTeil = variabel[name] ?? 0
            let abweichung = erwartet.map { $0 != 0 ? varTeil - $0 : 0 } ?? 0
            zeilen.append(Auswertungszeile(
                kategorie: name, betrag: betrag[name] ?? 0, variabel: varTeil,
                vorher: vormonat[name] ?? 0, ueblich: ueblich, erwartet: erwartet,
                abweichungCent: abweichung,
                abweichungAnteil: (erwartet ?? 0) != 0
                    ? Double(abweichung) / Double(erwartet!) : nil))
        }
        // Größte zuerst, und bei gleichem Betrag bleibt die Reihenfolge, wie sie
        // ist. Swifts sorted ist nicht stabil, deshalb der Vergleich über die
        // Stelle in der Liste.
        return zeilen.enumerated()
            .sorted { $0.element.betrag != $1.element.betrag
                ? $0.element.betrag > $1.element.betrag
                : $0.offset < $1.offset }
            .map(\.element)
    }

    /// Wie nachKategorie, für Woche, Monat oder Jahr. Das Übliche und der
    /// Ausreißerhinweis gibt es nur im Monat.
    func nachKategorieZeitraum(_ art: Zeitraumart, _ stichtag: String,
                               nachGruppe: Bool) -> [Auswertungszeile] {
        if art == .monat {
            return nachKategorie(String(stichtag.prefix(7)), nachGruppe: nachGruppe)
        }
        var jetzt: [String: (Int, Int)] = [:], davor: [String: (Int, Int)] = [:]
        if art == .woche {
            let s = zeitraum(.woche, stichtag)
            let vorige = zeitraumPlus(.woche, stichtag, -1)
            let v = zeitraum(.woche, vorige)
            jetzt = summenNachKategorie(s.von, s.bis, nachGruppe: nachGruppe, ohneFix: true)
            davor = summenNachKategorie(v.von, v.bis, nachGruppe: nachGruppe, ohneFix: true)
        } else {
            guard let spanne = auswertungSpanne(.jahr, stichtag) else { return [] }
            let vvon = zeitraumPlus(.jahr, spanne.von, -1)
            let vbis = zeitraum(.monat, zeitraumPlus(.jahr, spanne.bis, -1)).bis
            jetzt = summenNachKategorie(spanne.von, spanne.bis, nachGruppe: nachGruppe)
            davor = summenNachKategorie(vvon, vbis, nachGruppe: nachGruppe)
        }
        var zeilen: [Auswertungszeile] = []
        for name in Set(jetzt.keys).union(davor.keys) {
            let (betrag, variabel) = jetzt[name] ?? (0, 0)
            zeilen.append(Auswertungszeile(kategorie: name, betrag: betrag, variabel: variabel,
                                           vorher: davor[name]?.0 ?? 0, ueblich: nil,
                                           erwartet: nil, abweichungCent: 0,
                                           abweichungAnteil: nil))
        }
        // Größte zuerst, dann der Vormonat, dann der Name. Das ist ein
        // vollständiger Vergleich, also eindeutig ohne Rücksicht auf Stabilität.
        return zeilen.sorted { a, b in
            if a.betrag != b.betrag { return a.betrag > b.betrag }
            if a.vorher != b.vorher { return a.vorher > b.vorher }
            return a.kategorie < b.kategorie
        }
    }

    // MARK: Buchungen hinter einer Zeile

    /// Alle Buchungen im Zeitraum, mit denselben Filtern wie
    /// `Haushalt.alle_buchungen`. Gruppe heißt hier die wirksame Gruppe, und
    /// bei einer Kategorie ohne Gruppe deren eigener Name.
    func alleBuchungen(von: String? = nil, bis: String? = nil, kategorie: String? = nil,
                       gruppe: String? = nil, nurAusgaben: Bool = false,
                       ohneFix: Bool = false) -> [Buchung] {
        var sql = """
            SELECT b.id, b.datum, b.betrag_cent, b.notiz, b.ausserplanmaessig, b.regel_id,
                   b.gruppe, b.topf_id, b.status, b.art, k.name AS kategorie, r.name AS posten,
                   NULLIF(COALESCE(b.gruppe, r.gruppe, t.gruppe, k.gruppe), '') AS wirksame_gruppe
            FROM buchungen b
            LEFT JOIN buchung_kategorien bk ON bk.buchung_id = b.id
            LEFT JOIN kategorien k ON k.id = bk.kategorie_id
            LEFT JOIN regeln r ON r.id = b.regel_id
            LEFT JOIN toepfe t ON t.id = b.topf_id
            WHERE 1=1
            """
        // Ohne von und bis alle Buchungen, für den großen Export
        var werte: [Wert] = []
        if let von {
            sql += " AND b.datum >= ?"
            werte.append(.text(von))
        }
        if let bis {
            sql += " AND b.datum <= ?"
            werte.append(.text(bis))
        }
        if let kategorie {
            sql += " AND k.name = ?"
            werte.append(.text(kategorie))
        }
        if let gruppe {
            sql += " AND COALESCE(NULLIF(COALESCE(b.gruppe, r.gruppe, t.gruppe, k.gruppe), ''),"
                + " k.name) = ?"
            werte.append(.text(gruppe))
        }
        if nurAusgaben { sql += " AND b.betrag_cent < 0" }
        if ohneFix { sql += " AND b.regel_id IS NULL" }
        sql += " ORDER BY b.datum, b.id"
        return ((try? db.zeilen(sql, werte)) ?? []).map(Buchung.init)
    }

    private func zahl(_ sql: String, _ werte: [Wert]) -> Int {
        (try? db.zeilen(sql, werte).first?["s"]?.alsGanz) ?? 0
    }
}
