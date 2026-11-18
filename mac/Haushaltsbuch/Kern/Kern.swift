import Foundation

/// Die Rechnungen, eins zu eins nach haushalt/kern.py. Alles hier ist aus der
/// Datenbank gerechnet und nichts davon gespeichert, vor allem kein Topfstand.
/// Wo eine Formel begründet ist, steht die Begründung in CLAUDE.md, Abschnitt
/// Entscheidungen, und in docs/spec.md. Hier steht nur, was der Code tut.
///
/// Geprüft wird das gegen die Fassung in Python, sie ist das Orakel. Dieselbe
/// Datenbank, dieselben Zahlen, siehe mac/README.md.

// MARK: - Monate

/// Monate sind Text im Format YYYY-MM, Daten YYYY-MM-DD, wie in der Datenbank.
enum Monat {
    static func von(_ datum: Date) -> String {
        String(Datumsformat.iso.string(from: datum).prefix(7))
    }

    static func plus(_ monat: String, _ n: Int) -> String {
        let teile = monat.split(separator: "-")
        guard teile.count >= 2, let jahr = Int(teile[0]), let mon = Int(teile[1]) else { return monat }
        let index = jahr * 12 + (mon - 1) + n
        return String(format: "%04d-%02d", index / 12, index % 12 + 1)
    }

    /// Monatsschritte von einem Monat zum anderen, darf negativ sein.
    static func zwischen(_ von: String, _ bis: String) -> Int {
        let a = von.split(separator: "-"), b = bis.split(separator: "-")
        guard a.count >= 2, b.count >= 2,
              let j1 = Int(a[0]), let m1 = Int(a[1]),
              let j2 = Int(b[0]), let m2 = Int(b[1]) else { return 0 }
        return (j2 - j1) * 12 + (m2 - m1)
    }

    /// Sieht das nach JJJJ-MM aus? Mehr prüft auch die Fassung in Python nicht.
    static func gueltig(_ monat: String) -> Bool {
        let sauber = monat.trimmingCharacters(in: .whitespaces)
        return sauber.count == 7 && Array(sauber)[4] == "-"
    }

    static func tage(_ monat: String) -> Int {
        guard let erster = Datumsformat.iso.date(from: monat + "-01"),
              let spanne = Calendar(identifier: .gregorian).range(of: .day, in: .month, for: erster)
        else { return 30 }
        return spanne.count
    }
}

/// Aufgerundete Ganzzahldivision, wie `-(-a // b)` in Python. Die Rate eines
/// Topfs wird aufgerundet, der letzte Monat gleicht den Rest genau aus.
private func aufgerundet(_ a: Int, _ b: Int) -> Int {
    guard b != 0 else { return 0 }
    let ganz = a / b
    return a % b > 0 ? ganz + 1 : ganz
}

// MARK: - Zeilen der Datenbank

struct TopfZeile {
    let id: Int64
    let name: String
    let regelId: Int64?
    let gruppe: String?
    let kategorie: String?
    let wirksameGruppe: String?
    let zielCent: Int?
    let rateCent: Int
    let zielMonat: String?
    let startstandCent: Int
    let startMonat: String
    let pausiert: Bool

    init(zeile: [String: Wert]) {
        id = zeile["id"]?.alsZahl ?? 0
        name = zeile["name"]?.alsText ?? ""
        regelId = zeile["regel_id"]?.alsZahl
        gruppe = zeile["gruppe"]?.alsText
        kategorie = zeile["kategorie"]?.alsText
        wirksameGruppe = zeile["wirksame_gruppe"]?.alsText
        zielCent = zeile["ziel_cent"]?.alsGanz
        rateCent = zeile["rate_cent"]?.alsGanz ?? 0
        zielMonat = zeile["ziel_monat"]?.alsText
        startstandCent = zeile["startstand_cent"]?.alsGanz ?? 0
        startMonat = zeile["start_monat"]?.alsText ?? "1970-01"
        pausiert = zeile["pausiert"]?.istWahr ?? false
    }
}

/// Ein Topf mit den gerechneten Werten, wie `Haushalt.toepfe` sie liefert.
struct Topf: Identifiable {
    let zeile: TopfZeile
    let stand: Int
    /// Die Rate des gezeigten Monats. Bei einem Topf mit Termin ist das nicht
    /// die gespeicherte Rate, sondern was noch fehlt, verteilt auf die Monate.
    let rateCent: Int
    /// Die Rate ab dem Folgemonat. Die des laufenden Monats ist im Budget schon
    /// abgezogen, eine Entnahme oder Aufstockung wirkt deshalb erst danach.
    let naechsteRateCent: Int
    let vollInMonaten: Int?

    var id: Int64 { zeile.id }
    /// Siehe Buchung.zeilenSchluessel.
    var zeilenSchluessel: String { "rate-\(zeile.id)" }
    var name: String { zeile.name }
    var kategorie: String? { zeile.kategorie }
    var wirksameGruppe: String? { zeile.wirksameGruppe }
    /// Die eigene Gruppe, nil heißt nicht gesetzt und erbt von der Kategorie.
    var gruppe: String? { zeile.gruppe }
    var rateGespeichertCent: Int { zeile.rateCent }
    var zielCent: Int? { zeile.zielCent }
    var pausiert: Bool { zeile.pausiert }
    var automatisch: Bool { zeile.regelId != nil }
}

/// Die Zahlen der Übersicht, wie `Haushalt.uebersicht`.
struct Monatsbild {
    let monat: String
    let einnahmenCent: Int
    let fixCent: Int
    let fixOffenCent: Int
    let ratenCent: Int
    let variabelCent: Int
    let ausserplanCent: Int
    /// Die große Zahl. Einnahmen minus Fixkosten minus Topfraten minus variable
    /// Ausgaben, denn Rücklagen stehen nicht für Sonstiges zur Verfügung.
    let verfuegbarCent: Int
    let monatAnteil: Double
    let ausgabenAnteil: Double
    let warnung: String?
    let deckung: String?
}

// MARK: - Der Kern

struct Kern {
    let db: Datenbank
    let heute: Date

    init(db: Datenbank, heute: Date = Date()) {
        self.db = db
        self.heute = heute
    }

    private var heuteMonat: String { Monat.von(heute) }

    // MARK: Töpfe

    /// Der Sparzyklus, auf dessen Termin ein Monat hinspart. Nil, wenn der Topf
    /// keinen Termin hat und mit fester Rate läuft.
    private func zyklus(_ topf: TopfZeile, _ monat: String) -> (start: String, anfang: Int, faellig: String)? {
        if let regelId = topf.regelId {
            guard let regel = try? db.zeilen(
                "SELECT gilt_ab, intervall_monate FROM regeln WHERE id=?", [.zahl(regelId)]).first,
                let giltAb = regel["gilt_ab"]?.alsText,
                let intervall = regel["intervall_monate"]?.alsGanz, intervall >= 2
            else { return nil }
            // Die Fälligkeit, auf die dieser Monat hinspart, liegt echt nach ihm
            let faellig = naechsteFaelligkeit(giltAb: giltAb, intervall: intervall,
                                              abMonat: Monat.plus(monat, 1))
            let start = max(topf.startMonat, Monat.plus(faellig, -intervall))
            // Schon Zurückgelegtes zählt nur im ersten Zyklus
            let anfang = start <= topf.startMonat ? topf.startstandCent : 0
            return (start, anfang, faellig)
        }
        if let zielMonat = topf.zielMonat, let ziel = topf.zielCent, ziel != 0 {
            return (topf.startMonat, topf.startstandCent, zielMonat)
        }
        return nil
    }

    func naechsteFaelligkeit(giltAb: String, intervall: Int, abMonat: String) -> String {
        let versatz = ((Monat.zwischen(giltAb, abMonat) % intervall) + intervall) % intervall
        return Monat.plus(abMonat, versatz == 0 ? 0 : intervall - versatz)
    }

    /// Angezeigt wird nie mehr als das Ziel und nie weniger als null. Die
    /// Rechnung läuft ungedeckelt weiter, damit sich ein zu großer Griff in den
    /// Topf über die Folgemonate ausgleicht.
    private func gedeckelt(_ stand: Int, _ ziel: Int) -> Int {
        max(0, ziel != 0 ? min(stand, ziel) : stand)
    }

    /// Stand am Ende des Monats und die Rate, die in diesem Monat fällig ist.
    /// Bei einem Topf mit Termin läuft die Rechnung Monat für Monat durch den
    /// Zyklus, denn die Rate ist dort nicht fest, sondern das, was noch fehlt.
    func topfLauf(_ topf: TopfZeile, _ monat: String) -> (stand: Int, rate: Int) {
        let ziel = topf.zielCent ?? 0

        guard let z = zyklus(topf, monat) else {
            let bewegt = summe("""
                SELECT COALESCE(SUM(betrag_cent),0) AS s FROM buchungen
                WHERE topf_id=? AND status='gebucht' AND substr(datum,1,7) BETWEEN ? AND ?
                """, [.zahl(topf.id), .text(topf.startMonat), .text(monat)])
            // Aufstockungen zählen auch bei pausiertem Topf, es ist echtes Geld
            let eingelegt = summe("""
                SELECT COALESCE(SUM(betrag_cent),0) AS s FROM topf_einlagen
                WHERE topf_id=? AND monat BETWEEN ? AND ?
                """, [.zahl(topf.id), .text(topf.startMonat), .text(monat)])
            let monate = topf.pausiert ? 0 : max(0, Monat.zwischen(topf.startMonat, monat) + 1)
            let stand = topf.startstandCent + topf.rateCent * monate + bewegt + eingelegt
            var rate = topf.pausiert ? 0 : topf.rateCent
            if ziel != 0, stand >= ziel { rate = 0 }
            return (gedeckelt(stand, ziel), rate)
        }

        if monat < z.start { return (0, 0) }

        // Abschläge bleiben außen vor, sie beenden einen Zyklus. Entnahmen von
        // Hand zählen mit, das Geld ist dann wirklich weg. Aufstockungen wirken
        // gleich, nur mit umgekehrtem Vorzeichen.
        var jeMonat: [String: Int] = [:]
        let abfragen = ["""
            SELECT substr(datum,1,7) AS m, SUM(betrag_cent) AS s FROM buchungen
            WHERE topf_id=? AND status='gebucht' AND art<>'abschlag'
            AND substr(datum,1,7) BETWEEN ? AND ? GROUP BY m
            """, """
            SELECT monat AS m, SUM(betrag_cent) AS s FROM topf_einlagen
            WHERE topf_id=? AND monat BETWEEN ? AND ? GROUP BY m
            """]
        for sql in abfragen {
            let zeilen = (try? db.zeilen(sql, [.zahl(topf.id), .text(z.start), .text(monat)])) ?? []
            for zeile in zeilen {
                guard let m = zeile["m"]?.alsText else { continue }
                jeMonat[m, default: 0] += zeile["s"]?.alsGanz ?? 0
            }
        }

        var stand = z.anfang
        var rate = 0
        var m = z.start
        while true {
            let verbleibend = Monat.zwischen(m, z.faellig)
            if topf.pausiert || verbleibend <= 0 {
                rate = 0
            } else {
                rate = max(0, aufgerundet(ziel - stand, verbleibend))
            }
            stand += rate + (jeMonat[m] ?? 0)
            if m >= monat { break }
            m = Monat.plus(m, 1)
        }
        return (gedeckelt(stand, ziel), rate)
    }

    func toepfe(_ monat: String? = nil) -> [Topf] {
        let monat = monat ?? heuteMonat
        let zeilen = (try? db.zeilen("""
            SELECT t.*, k.name AS kategorie,
                   NULLIF(COALESCE(t.gruppe, k.gruppe), '') AS wirksame_gruppe
            FROM toepfe t LEFT JOIN kategorien k ON k.id=t.kategorie_id
            WHERE t.aufgeloest_am IS NULL ORDER BY t.name
            """)) ?? []
        return zeilen.map { zeile in
            let topf = TopfZeile(zeile: zeile)
            let lauf = topfLauf(topf, monat)
            var vollIn: Int?
            if let z = zyklus(topf, monat) {
                // Mit Termin steht der Zeitpunkt fest, die Rate gleicht ja aus
                let verbleibend = Monat.zwischen(monat, z.faellig)
                vollIn = verbleibend > 0 ? verbleibend : nil
            } else if let ziel = topf.zielCent, ziel != 0, lauf.rate > 0, lauf.stand < ziel {
                vollIn = aufgerundet(ziel - lauf.stand, lauf.rate)
            }
            let naechste = topfLauf(topf, Monat.plus(monat, 1)).rate
            return Topf(zeile: topf, stand: lauf.stand, rateCent: lauf.rate,
                        naechsteRateCent: naechste, vollInMonaten: vollIn)
        }
    }

    /// Die Summe der Raten, die das Budget dieses Monats belasten.
    func topfraten(_ monat: String? = nil) -> Int {
        let monat = monat ?? heuteMonat
        var summe = 0
        for topf in toepfe(monat) {
            if topf.pausiert { continue }
            if let ziel = topf.zielCent, ziel != 0, !topf.automatisch, topf.stand >= ziel { continue }
            summe += topf.rateCent
        }
        return summe
    }

    /// Das bisher tatsächlich Angesparte.
    func ruecklagenGesamt(_ monat: String? = nil) -> Int {
        toepfe(monat).reduce(0) { $0 + $1.stand }
    }

    // MARK: Feste Posten

    /// Die Posten, die in diesem Monat noch nicht beendet sind, wie
    /// `Haushalt.regeln`. Die Verwaltung zeigt auch einen Posten, dessen
    /// Fälligkeit erst in der Zukunft liegt, sonst wäre ein gerade angelegter
    /// unsichtbar. `nurGueltige` nimmt zusätzlich nur die, deren Gültigkeit
    /// schon begonnen hat, wie es die Fortschreibung braucht. In Python ist das
    /// der Standard, hier nicht, weil die Oberfläche die Verwaltungssicht
    /// braucht. Sortiert nach Betrag, größter zuerst.
    func regeln(_ monat: String? = nil, nurGueltige: Bool = false) -> [Posten] {
        let monat = monat ?? heuteMonat
        let zeilen = (try? db.zeilen("""
            SELECT r.*,
              (SELECT group_concat(k.name, ', ') FROM regel_kategorien rk
               JOIN kategorien k ON k.id=rk.kategorie_id
               WHERE rk.regel_id=r.id) AS kategorien,
              NULLIF(COALESCE(r.gruppe,
                (SELECT k.gruppe FROM regel_kategorien rk
                 JOIN kategorien k ON k.id=rk.kategorie_id
                 WHERE rk.regel_id=r.id ORDER BY rk.kategorie_id LIMIT 1)
              ), '') AS wirksame_gruppe
            FROM regeln r WHERE (r.gilt_bis IS NULL OR r.gilt_bis>=?)
            \(nurGueltige ? "AND r.gilt_ab<=?" : "")
            ORDER BY r.betrag_cent DESC, r.tag_im_monat
            """, nurGueltige ? [.text(monat), .text(monat)] : [.text(monat)])) ?? []
        return zeilen.map(Posten.init)
    }

    /// Alle vergebenen Gruppen, alphabetisch, aus allen vier Quellen. Eine
    /// Gruppe ist kein eigener Datensatz, sie entsteht dadurch, dass etwas ihren
    /// Namen trägt, siehe Haushalt.gruppen.
    /// Der Monat der ältesten Buchung, nil ohne Buchungen, wie kern._erster_monat.
    func ersterMonat() -> String? {
        guard let datum = try? db.zeilen("SELECT MIN(datum) AS d FROM buchungen")
            .first?["d"]?.alsText else { return nil }
        return String(datum.prefix(7))
    }

    func gruppen() -> [String] {
        let zeilen = (try? db.zeilen("""
            SELECT DISTINCT gruppe FROM (
              SELECT gruppe FROM kategorien
              UNION SELECT gruppe FROM regeln
              UNION SELECT gruppe FROM toepfe
              UNION SELECT gruppe FROM buchungen
            ) WHERE gruppe IS NOT NULL AND gruppe<>'' ORDER BY gruppe
            """)) ?? []
        return zeilen.compactMap { $0["gruppe"]?.alsText }
    }

    // MARK: Konto

    /// Startsaldo plus alle gebuchten Buchungen ab dem Startsaldodatum. Der
    /// Startsaldo gilt zu Beginn seines Tages, Buchungen dieses Tages zählen
    /// also mit. Ohne Startsaldo gibt es keinen Kontostand.
    func kontostand(bis: String? = nil) -> Int? {
        // try? auf eine Funktion, die schon Optional liefert, fasst beide
        // Ebenen zusammen, hier bleibt also ein einfaches String?
        guard let start = try? db.einstellung("startsaldo_cent"),
              let startCent = Int(start) else { return nil }
        let startDatum = try? db.einstellung("startsaldo_datum")
        let bis = bis ?? Datumsformat.iso.string(from: heute)
        let summe = summe("""
            SELECT COALESCE(SUM(betrag_cent),0) AS s FROM buchungen
            WHERE status='gebucht' AND datum>=? AND datum<=?
            """, [startDatum.map { Wert.text($0) } ?? .leer, .text(bis)])
        return startCent + summe
    }

    /// Kontostand minus aller Rücklagen. Die Antwort auf die Frage, worüber
    /// außerhalb des Monatsbudgets wirklich verfügt werden kann.
    func freiVerfuegbar(bis: String? = nil) -> Int? {
        guard let stand = kontostand(bis: bis) else { return nil }
        let datum = bis ?? Datumsformat.iso.string(from: heute)
        return stand - ruecklagenGesamt(String(datum.prefix(7)))
    }

    /// Meldet sich nur, wenn der Kontostand die Rücklagen nicht mehr deckt.
    func deckung() -> String? {
        guard let frei = freiVerfuegbar(), frei < 0 else { return nil }
        return "Es fehlen \(Geld.euro(-frei)) für die Rücklagen."
    }

    // MARK: Übersicht

    /// Anteil des Monats, der vorbei ist. Vergangene Monate 1, künftige 0.
    func monatAnteil(_ monat: String? = nil) -> Double {
        let monat = monat ?? heuteMonat
        if monat == heuteMonat {
            let tag = Calendar(identifier: .gregorian).component(.day, from: heute)
            return Double(tag) / Double(Monat.tage(monat))
        }
        return monat < heuteMonat ? 1.0 : 0.0
    }

    /// Die Zahlen des Monats. Anders als in Python wird hier nicht
    /// fortgeschrieben, diese App legt keine Abschläge an, siehe mac/README.md.
    func uebersicht(_ monat: String? = nil) -> Monatsbild {
        let monat = monat ?? heuteMonat
        let zeile = (try? db.zeilen("""
            SELECT
              COALESCE(SUM(CASE WHEN betrag_cent>0 AND ausserplanmaessig=0 THEN betrag_cent END),0) AS einnahmen,
              COALESCE(SUM(CASE WHEN regel_id IS NOT NULL AND betrag_cent<0 AND topf_id IS NULL THEN betrag_cent END),0) AS fix,
              COALESCE(SUM(CASE WHEN regel_id IS NOT NULL AND betrag_cent<0 AND status='geplant' THEN betrag_cent END),0) AS fix_offen,
              COALESCE(SUM(CASE WHEN regel_id IS NULL AND betrag_cent<0 AND topf_id IS NULL
                                AND ausserplanmaessig=0 THEN betrag_cent END),0) AS variabel,
              COALESCE(SUM(CASE WHEN ausserplanmaessig=1 THEN betrag_cent END),0) AS ausserplan
            FROM buchungen WHERE substr(datum,1,7)=?
            """, [.text(monat)]).first) ?? [:]

        let einnahmen = zeile["einnahmen"]?.alsGanz ?? 0
        let fix = zeile["fix"]?.alsGanz ?? 0
        let fixOffen = zeile["fix_offen"]?.alsGanz ?? 0
        let variabel = zeile["variabel"]?.alsGanz ?? 0
        let ausserplan = zeile["ausserplan"]?.alsGanz ?? 0
        let raten = topfraten(monat)

        let verfuegbar = einnahmen + fix - raten + variabel
        let budget = einnahmen + fix - raten
        let anteilMonat = monatAnteil(monat)
        let anteilAusgaben = budget > 0 ? Double(-variabel) / Double(budget) : 1.0

        // Zwei Stufen (2026-09-26). Rot, wenn der Monat überzogen ist, orange,
        // wenn das Budget schneller weg ist als der Monat, mit einem Spielraum,
        // der zum Monatsende hin schrumpft, siehe warnSchwelle. Steht eine
        // Warnung da, nennt sie wie in Fassung 1.2 dazu die Kategorie, die am
        // weitesten über ihrem Üblichen liegt. Sie selbst löst keine aus.
        var warnung: String?
        if verfuegbar < 0 {
            warnung = "Es fehlen \(Geld.euro(-verfuegbar)), der Monat ist überzogen."
        } else if anteilAusgaben > Self.warnSchwelle(anteilMonat) {
            warnung = "\(prozent(anteilAusgaben)) des Budgets ausgegeben, "
                + "aber erst \(prozent(anteilMonat)) des Monats vorbei."
        }
        if let text = warnung, let ausreisser = groessterAusreisser(monat) {
            warnung = text + " " + ausreisser
        }

        return Monatsbild(monat: monat, einnahmenCent: einnahmen, fixCent: fix,
                          fixOffenCent: fixOffen, ratenCent: raten, variabelCent: variabel,
                          ausserplanCent: ausserplan, verfuegbarCent: verfuegbar,
                          monatAnteil: anteilMonat, ausgabenAnteil: anteilAusgaben,
                          warnung: warnung, deckung: deckung())
    }

    // MARK: Das Übliche

    /// Median der Monatsausgaben einer Kategorie oder Gruppe über die letzten
    /// Monate. Unter drei Monaten gibt es kein Übliches, dann nil.
    func uebliches(_ kategorie: String, monat: String, fenster: Int = 6,
                   gruppe: Bool = false, nurVariabel: Bool = false) -> Int? {
        let von = Monat.plus(monat, -fenster)
        let feld = gruppe ? "COALESCE(gruppe, kategorie)" : "kategorie"
        let spalte = nurVariabel ? "variabel_cent" : "betrag_cent"
        let zeilen = (try? db.zeilen("""
            SELECT SUM(\(spalte)) AS s FROM v_kategorie_monat
            WHERE \(feld)=? AND monat>=? AND monat<? GROUP BY monat
            """, [.text(kategorie), .text(von), .text(monat)])) ?? []
        let werte = zeilen.map { -($0["s"]?.alsGanz ?? 0) }.sorted()
        guard werte.count >= 3 else { return nil }
        let mitte = werte.count / 2
        if werte.count % 2 == 1 { return werte[mitte] }
        // Bei gerader Anzahl der Mittelwert der beiden mittleren, abgeschnitten
        // und nicht gerundet, genau wie int(statistics.median(...)) in Python
        return Int(Double(werte[mitte - 1] + werte[mitte]) / 2)
    }

    /// Ab wann eine Kategorie in der Auswertung als Ausreißer gilt, mindestens
    /// so viel mehr als zu diesem Zeitpunkt des Monats üblich, als Anteil und
    /// in Cent. Die Warnung der Übersicht hat eigene Schwellen, siehe warnAnteil.
    static let ausreisserAnteil = 0.25
    static let ausreisserCent = 1000

    /// Ab welchem Anteil des Budgets die Übersicht orange warnt, zu einem
    /// Anteil des Monats (2026-09-26). Der Spielraum von 15 Prozentpunkten aus
    /// Fassung 1.2 schrumpft zum Monatsende hin mit dem Rest des Monats, am
    /// 15. warnt sie ab 58 Prozent, am 26. ab 89, am letzten Tag erst bei Rot.
    /// Anders gesagt, orange wird es, wenn der Rest des Budgets für weniger als
    /// 85 Prozent der restlichen Tage reicht.
    ///
    /// Der feste Spielraum aus Fassung 1.2 ist verworfen (2026-09-26), ab etwa
    /// dem 25. lag seine Schwelle über dem ganzen Budget, und ein knapper Monat
    /// ging ohne Vorwarnung von grün nach rot. Ganz ohne Spielraum wäre es an
    /// vier von zehn Tagen orange gewesen, gemessen an den Demodaten, denn
    /// direkt nach dem Wocheneinkauf liegt man immer vor dem Monat.
    static let warnSpielraum = 0.15

    static func warnSchwelle(_ anteilMonat: Double) -> Double {
        anteilMonat + warnSpielraum * (1 - anteilMonat)
    }

    /// Die Kategorie, deren Ausgaben im Monat am weitesten über ihrem Üblichen
    /// liegen, als Satz, wie groesster_ausreisser in Fassung 1.2. Verglichen
    /// wird der ganze bisherige Monat mit dem Median ganzer Vormonate, er
    /// meldet sich also erst, wenn eine Kategorie schon mehr hat als sonst im
    /// ganzen Monat. Nil, wenn keine darüber liegt.
    ///
    /// In Fassung 2.0 warnte am selben Tag zeitweise die Übersicht selbst,
    /// wenn bis heute deutlich mehr ausgegeben war als in jedem der letzten
    /// sechs Monate bis zu diesem Tag (verworfen 2026-09-26). Zusammen mit dem
    /// Tempo ergab das zwei Regeln für dieselbe Farbe, und in einem knappen
    /// Monat lag ihre Schwelle ebenfalls hinter Rot.
    func groessterAusreisser(_ monat: String) -> String? {
        let zeilen = (try? db.zeilen(
            "SELECT kategorie, SUM(betrag_cent) AS b FROM v_kategorie_monat WHERE monat=? "
            + "GROUP BY kategorie", [.text(monat)])) ?? []
        var bester: (mehr: Int, kategorie: String, ist: Int, ueblich: Int)?
        for zeile in zeilen {
            guard let kategorie = zeile["kategorie"]?.alsText,
                  let ueblich = uebliches(kategorie, monat: monat) else { continue }
            let ist = -(zeile["b"]?.alsGanz ?? 0)
            let mehr = ist - ueblich
            if mehr > 0, mehr > (bester?.mehr ?? 0) {
                bester = (mehr, kategorie, ist, ueblich)
            }
        }
        guard let bester else { return nil }
        return "\(bester.kategorie) liegt bei \(Geld.euro(bester.ist)), "
            + "sonst meist um \(Geld.euro(bester.ueblich))."
    }

    /// Wie Pythons Formatierung mit .0%, also kaufmännisch gerundet ohne Stelle.
    func prozent(_ anteil: Double) -> String {
        // Halb auf gerade wie das Format .0% in Python, aus 12,5 wird 12
        "\(Int((anteil * 100).rounded(.toNearestOrEven)))%"
    }

    private func summe(_ sql: String, _ werte: [Wert]) -> Int {
        (try? db.zeilen(sql, werte).first?["s"]?.alsGanz) ?? 0
    }
}
