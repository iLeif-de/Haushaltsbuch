import Foundation

/// Das Ändern fester Posten, eins zu eins nach haushalt/kern.py.
///
/// **Ein Posten wird nie überschrieben.** Eine Betragsänderung schließt die alte
/// Regel mit `gilt_bis` und legt eine neue mit `ersetzt_regel_id` an, damit
/// vergangene Monate ihren alten Betrag behalten. Name, Kategorie und Gruppe
/// gehören dagegen dem Posten als Ganzem und gelten für die ganze Kette.
extension Kern {
    /// Alle Regelnummern einer Änderungskette, die Regel selbst eingeschlossen.
    func regelkette(_ regelId: Int64) -> [Int64] {
        var ids = [regelId]
        var aktuell = regelId
        // rückwärts, über ersetzt_regel_id
        while true {
            guard let zeile = try? db.zeilen(
                "SELECT ersetzt_regel_id FROM regeln WHERE id=?", [.zahl(aktuell)]).first,
                let vorher = zeile["ersetzt_regel_id"]?.alsZahl else { break }
            aktuell = vorher
            ids.append(aktuell)
        }
        aktuell = regelId
        // vorwärts, wer ersetzt diese Regel
        while true {
            guard let zeile = try? db.zeilen(
                "SELECT id FROM regeln WHERE ersetzt_regel_id=?", [.zahl(aktuell)]).first,
                let danach = zeile["id"]?.alsZahl else { break }
            aktuell = danach
            ids.append(aktuell)
        }
        return ids
    }

    func platzhalter(_ anzahl: Int) -> String {
        Array(repeating: "?", count: anzahl).joined(separator: ",")
    }

    /// Abgerundete Ganzzahldivision, wie `//` in Python. Swift schneidet zur Null
    /// hin ab, das ist bei negativen Zahlen etwas anderes.
    func abgerundet(_ a: Int, _ b: Int) -> Int {
        guard b != 0 else { return 0 }
        let ganz = a / b
        return (a % b != 0 && ((a < 0) != (b < 0))) ? ganz - 1 : ganz
    }

    /// Benennt einen Posten um. Der Name gehört dem Posten als Ganzem, deshalb
    /// bekommt ihn die ganze Kette, und ein automatischer Topf zieht mit.
    func regelUmbenennen(_ regelId: Int64, name: String) throws {
        let sauber = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sauber.isEmpty else { throw DbFehler(text: "Name fehlt") }
        let kette = regelkette(regelId)
        let werte: [Wert] = [.text(sauber)] + kette.map { Wert.zahl($0) }
        try db.schreiben("UPDATE regeln SET name=? WHERE id IN (\(platzhalter(kette.count)))", werte)
        try db.schreiben("UPDATE toepfe SET name=? WHERE regel_id IN (\(platzhalter(kette.count)))",
                         werte)
    }

    /// Setzt die Gruppe des Postens. Nil heißt nicht gesetzt, dann gilt die der
    /// Kategorie, ein leerer Text heißt bewusst gelöscht. Die Gruppe gehört dem
    /// Posten als Ganzem, ein automatischer Topf zieht mit.
    func regelGruppeSetzen(_ regelId: Int64, gruppe: String?) throws {
        let kette = regelkette(regelId)
        let wert: Wert = gruppe.map { .text($0.trimmingCharacters(in: .whitespaces)) } ?? .leer
        let werte: [Wert] = [wert] + kette.map { Wert.zahl($0) }
        try db.schreiben("UPDATE regeln SET gruppe=? WHERE id IN (\(platzhalter(kette.count)))",
                         werte)
        try db.schreiben("UPDATE toepfe SET gruppe=? WHERE regel_id IN (\(platzhalter(kette.count)))",
                         werte)
    }

    /// Setzt die Kategorie des Postens für die ganze Kette.
    ///
    /// Abschläge und Korrekturen tragen ihre Kategorie als eigene Kopie in
    /// buchung_kategorien, sie muss also mitgezogen werden, sonst zeigten
    /// Übersicht und Auswertung weiter die alte. Mitgezogen wird nur, was noch
    /// die alte Kategorie des Postens trägt, eine von Hand anders eingeordnete
    /// Buchung bleibt, wie sie ist.
    func regelKategorieSetzen(_ regelId: Int64, kategorieId: Int64) throws {
        let kette = regelkette(regelId)
        let platz = platzhalter(kette.count)
        let kettenWerte = kette.map { Wert.zahl($0) }
        let alte = (try db.zeilen(
            "SELECT DISTINCT kategorie_id FROM regel_kategorien WHERE regel_id IN (\(platz))",
            kettenWerte)).compactMap { $0["kategorie_id"]?.alsZahl }
        if !alte.isEmpty {
            let altPlatz = platzhalter(alte.count)
            let buchungen = (try db.zeilen("""
                SELECT DISTINCT b.id FROM buchungen b
                JOIN buchung_kategorien bk ON bk.buchung_id=b.id
                WHERE b.regel_id IN (\(platz)) AND bk.kategorie_id IN (\(altPlatz))
                """, kettenWerte + alte.map { Wert.zahl($0) })).compactMap { $0["id"]?.alsZahl }
            for bid in buchungen {
                try db.schreiben("DELETE FROM buchung_kategorien WHERE buchung_id=?", [.zahl(bid)])
                try db.schreiben("INSERT INTO buchung_kategorien VALUES (?,?)",
                                 [.zahl(bid), .zahl(kategorieId)])
            }
        }
        try db.schreiben("DELETE FROM regel_kategorien WHERE regel_id IN (\(platz))", kettenWerte)
        for rid in kette {
            try db.schreiben("INSERT INTO regel_kategorien VALUES (?,?)",
                             [.zahl(rid), .zahl(kategorieId)])
        }
        // Ein automatischer Topf am Posten zieht mit
        try db.schreiben("UPDATE toepfe SET kategorie_id=? WHERE regel_id IN (\(platz))",
                         [.zahl(kategorieId)] + kettenWerte)
    }

    /// Ändert den Betrag ab einem Monat. Schließt die alte Regel zum Vormonat und
    /// legt eine neue an. Liegt der Monat vor dem Beginn der Regel selbst, gibt
    /// es nichts zu schützen, dann ändert sich der Betrag an derselben Regel,
    /// sonst landete gilt_bis vor gilt_ab. Liefert die Nummer der Regel, die
    /// danach gilt.
    @discardableResult
    func regelAendern(_ regelId: Int64, neuerBetrag: Int, abMonat: String) throws -> Int64 {
        guard let alt = try db.zeilen("SELECT * FROM regeln WHERE id=?", [.zahl(regelId)]).first,
              let giltAb = alt["gilt_ab"]?.alsText else {
            throw DbFehler(text: "Diesen Posten gibt es nicht.")
        }
        let intervall = alt["intervall_monate"]?.alsGanz ?? 1

        if abMonat <= giltAb {
            try db.schreiben("UPDATE regeln SET betrag_cent=? WHERE id=?",
                             [.zahl(Int64(neuerBetrag)), .zahl(regelId)])
            if let topf = try db.zeilen("SELECT * FROM toepfe WHERE regel_id=?",
                                        [.zahl(regelId)]).first {
                let faellig = naechsteFaelligkeit(giltAb: giltAb, intervall: intervall,
                                                  abMonat: Monat.von(heute))
                let monate = max(1, Monat.zwischen(Monat.von(heute), faellig))
                let startstand = topf["startstand_cent"]?.alsGanz ?? 0
                let rate = max(0, abgerundet(-neuerBetrag - startstand + monate - 1, monate))
                try db.schreiben("UPDATE toepfe SET ziel_cent=?, rate_cent=? WHERE id=?",
                                 [.zahl(Int64(-neuerBetrag)), .zahl(Int64(rate)),
                                  .zahl(topf["id"]?.alsZahl ?? 0)])
            }
            try db.schreiben(
                "DELETE FROM buchungen WHERE regel_id=? AND status='geplant' AND soll_monat>=?",
                [.zahl(regelId), .text(abMonat)])
            try db.schreiben("""
                UPDATE buchungen SET betrag_cent=? WHERE regel_id=? AND art='abschlag'
                AND status='gebucht' AND soll_monat>=?
                """, [.zahl(Int64(neuerBetrag)), .zahl(regelId), .text(abMonat)])
            return regelId
        }

        try db.schreiben("UPDATE regeln SET gilt_bis=? WHERE id=?",
                         [.text(Monat.plus(abMonat, -1)), .zahl(regelId)])
        let neu = try db.schreiben("""
            INSERT INTO regeln (name, betrag_cent, tag_im_monat, intervall_monate, gilt_ab,
            ersetzt_regel_id, gruppe) VALUES (?,?,?,?,?,?,?)
            """, [.text(alt["name"]?.alsText ?? ""), .zahl(Int64(neuerBetrag)),
                  .zahl(alt["tag_im_monat"]?.alsZahl ?? 1), .zahl(Int64(intervall)),
                  .text(abMonat), .zahl(regelId),
                  alt["gruppe"]?.alsText.map { Wert.text($0) } ?? .leer])
        try db.schreiben(
            "INSERT INTO regel_kategorien SELECT ?, kategorie_id FROM regel_kategorien WHERE regel_id=?",
            [.zahl(neu), .zahl(regelId)])

        // Topf mitnehmen, Rate an die verbleibende Zeit bis zur nächsten
        // Fälligkeit anpassen, nicht einfach an das Intervall
        if let topf = try db.zeilen("SELECT * FROM toepfe WHERE regel_id=?",
                                    [.zahl(regelId)]).first {
            let faellig = naechsteFaelligkeit(giltAb: abMonat, intervall: intervall,
                                              abMonat: abMonat)
            let monate = max(1, Monat.zwischen(abMonat, faellig))
            let startstand = topf["startstand_cent"]?.alsGanz ?? 0
            let rate = max(0, abgerundet(-neuerBetrag - startstand + monate - 1, monate))
            try db.schreiben("UPDATE toepfe SET regel_id=?, ziel_cent=?, rate_cent=? WHERE id=?",
                             [.zahl(neu), .zahl(Int64(-neuerBetrag)), .zahl(Int64(rate)),
                              .zahl(topf["id"]?.alsZahl ?? 0)])
        }

        let kette = regelkette(regelId)
        let platz = platzhalter(kette.count)
        let kettenWerte = kette.map { Wert.zahl($0) }
        // noch nicht bestätigte Abschläge ab dem Änderungsmonat fallen weg
        try db.schreiben("""
            DELETE FROM buchungen WHERE regel_id IN (\(platz))
            AND status='geplant' AND soll_monat>=?
            """, kettenWerte + [.text(abMonat)])
        // gebuchte Abschläge ab dem Änderungsmonat bekommen den neuen Betrag und
        // hängen an der neuen Regel, damit die Fortschreibung nichts doppelt anlegt
        try db.schreiben("""
            UPDATE buchungen SET regel_id=?, betrag_cent=?
            WHERE regel_id IN (\(platz)) AND art='abschlag'
            AND status='gebucht' AND soll_monat>=?
            """, [.zahl(neu), .zahl(Int64(neuerBetrag))] + kettenWerte + [.text(abMonat)])
        return neu
    }

    /// Verschiebt die Fälligkeit eines Postens, also den Zyklus selbst.
    ///
    /// `gilt_ab` ist laut schema.sql der erste Fälligkeitsmonat, und alles
    /// Weitere wird daraus gerechnet, die nächste Fälligkeit ebenso wie der
    /// Termin des automatischen Topfs und damit dessen Rate. Es genügt deshalb,
    /// diesen Monat zu setzen (2026-09-24).
    ///
    /// Geändert wird nur diese Regel, nicht die ganze Kette. Die älteren Regeln
    /// beschreiben die Vergangenheit, sie behalten ihren Zyklus. Noch nicht
    /// bestätigte Abschläge ab dem laufenden Monat fallen weg, sie gehören zum
    /// alten Zyklus. Die Fortschreibung legt sie nach dem neuen wieder an.
    func regelFaelligkeitSetzen(_ regelId: Int64, monat: String) throws {
        guard Monat.gueltig(monat) else {
            throw DbFehler(text: "Den Monat bitte als JJJJ-MM eintragen.")
        }
        guard let regel = try db.zeilen("SELECT * FROM regeln WHERE id=?",
                                        [.zahl(regelId)]).first else {
            throw DbFehler(text: "Diesen Posten gibt es nicht.")
        }
        if let ende = regel["gilt_bis"]?.alsText, monat > ende {
            throw DbFehler(text: "Der Posten endet mit \(ende), die Fälligkeit kann nicht "
                           + "danach liegen.")
        }
        try db.schreiben("UPDATE regeln SET gilt_ab=? WHERE id=?",
                         [.text(monat), .zahl(regelId)])
        let kette = regelkette(regelId)
        try db.schreiben("""
            DELETE FROM buchungen WHERE regel_id IN (\(platzhalter(kette.count)))
            AND status='geplant' AND soll_monat>=?
            """, kette.map { Wert.zahl($0) } + [.text(Monat.von(heute))])
    }

    /// Setzt den Tag im Monat, an dem abgebucht wird. Er gehört dem Posten als
    /// Ganzem, wie der Name, deshalb bekommt ihn die ganze Kette. Schon
    /// gebuchte Abschläge behalten ihr Datum.
    func regelSolltagSetzen(_ regelId: Int64, tag: Int) throws {
        guard (1...31).contains(tag) else {
            throw DbFehler(text: "Der Tag liegt nicht zwischen 1 und 31.")
        }
        let kette = regelkette(regelId)
        try db.schreiben("UPDATE regeln SET tag_im_monat=? WHERE id IN (\(platzhalter(kette.count)))",
                         [.zahl(Int64(tag))] + kette.map { Wert.zahl($0) })
    }

    /// Beendet den Posten mit diesem Monat. Geplante Abschläge danach fallen weg.
    func regelBeenden(_ regelId: Int64, letzterMonat: String) throws {
        try db.schreiben("UPDATE regeln SET gilt_bis=? WHERE id=?",
                         [.text(letzterMonat), .zahl(regelId)])
        try db.schreiben(
            "DELETE FROM buchungen WHERE regel_id=? AND status='geplant' AND soll_monat>?",
            [.zahl(regelId), .text(letzterMonat)])
    }

    /// Löscht einen Posten vollständig, samt Buchungen und automatischem Topf.
    /// Nur für einen Posten gedacht, der erst diesen Monat gilt, sonst würde
    /// gilt_bis vor gilt_ab landen. Ein Posten mit Geschichte wird beendet.
    func regelLoeschen(_ regelId: Int64) throws {
        try db.schreiben("DELETE FROM buchungen WHERE regel_id=?", [.zahl(regelId)])
        try db.schreiben("DELETE FROM regeln WHERE id=?", [.zahl(regelId)])
    }

    /// Legt einen festen Posten an, wie `Haushalt.regel_anlegen`.
    ///
    /// Ein nicht monatlicher Posten bekommt einen Topf, dessen Rate sich aus der
    /// Zeit bis zur nächsten Fälligkeit ergibt und nicht aus Betrag durch
    /// Intervall. `giltAb` ist der Monat, in dem der Posten laut seinem Zyklus
    /// fällig ist oder wäre, er darf also in der Vergangenheit liegen, etwa der
    /// Mai einer jährlichen Police, auch wenn heute September ist.
    @discardableResult
    func regelAnlegen(name: String, betrag: Int, tag: Int, giltAb: String, kategorieId: Int64?,
                      intervall: Int = 1, zuruecklegen: Bool = true, schonVorhanden: Int = 0,
                      gruppe: String?) throws -> Int64 {
        let rid = try db.schreiben("""
            INSERT INTO regeln (name, betrag_cent, tag_im_monat, intervall_monate, gilt_ab, gruppe)
            VALUES (?,?,?,?,?,?)
            """, [.text(name), .zahl(Int64(betrag)), .zahl(Int64(tag)), .zahl(Int64(intervall)),
                  .text(giltAb), gruppe.map { Wert.text($0) } ?? .leer])
        if let kategorieId {
            try db.schreiben("INSERT INTO regel_kategorien VALUES (?,?)",
                             [.zahl(rid), .zahl(kategorieId)])
        }
        if intervall > 1, betrag < 0, zuruecklegen {
            let ziel = -betrag
            let faellig = naechsteFaelligkeit(giltAb: giltAb, intervall: intervall,
                                              abMonat: Monat.von(heute))
            let monate = max(1, Monat.zwischen(Monat.von(heute), faellig))
            let rate = max(0, abgerundet(ziel - schonVorhanden + monate - 1, monate))
            // Der Topf übernimmt die Kategorie des Postens zur Einordnung
            try db.schreiben("""
                INSERT INTO toepfe (name, regel_id, kategorie_id, gruppe, ziel_cent, rate_cent,
                startstand_cent, start_monat) VALUES (?,?,?,?,?,?,?,?)
                """, [.text(name), .zahl(rid),
                      kategorieId.map { Wert.zahl($0) } ?? .leer,
                      gruppe.map { Wert.text($0) } ?? .leer,
                      .zahl(Int64(ziel)), .zahl(Int64(rate)), .zahl(Int64(schonVorhanden)),
                      .text(Monat.von(heute))])
        }
        return rid
    }

    /// Nachzahlung, Betrag negativ, oder Rückzahlung, Betrag positiv. Die Art
    /// ergibt sich aus dem Vorzeichen, die Kategorie kommt vom Posten.
    @discardableResult
    func korrektur(_ regelId: Int64, betrag: Int, datum: String) throws -> Int64 {
        let art = betrag > 0 ? "rueckzahlung" : "nachzahlung"
        let id = try db.schreiben("""
            INSERT INTO buchungen (datum, betrag_cent, regel_id, art, quelle)
            VALUES (?,?,?,?,'manuell')
            """, [.text(datum), .zahl(Int64(betrag)), .zahl(regelId), .text(art)])
        try db.schreiben(
            "INSERT INTO buchung_kategorien SELECT ?, kategorie_id FROM regel_kategorien WHERE regel_id=?",
            [.zahl(id), .zahl(regelId)])
        return id
    }
}

/// Ein anstehender Termin eines nicht monatlichen Postens.
struct Termin: Identifiable {
    let posten: Posten
    /// Der Tag, an dem abgebucht wird, JJJJ-MM-TT.
    let datum: String

    var id: Int64 { posten.id }
    var betragCent: Int { posten.betragCent }
    var name: String { posten.name }
}

extension Kern {
    /// Der Monat, in dem dieser Posten das nächste Mal fällig ist, vom
    /// angegebenen Monat an gerechnet. Bei einem monatlichen Posten ist das
    /// dieser Monat selbst.
    func naechsteFaelligkeit(_ posten: Posten, ab monat: String? = nil) -> String {
        let ab = monat ?? Monat.von(heute)
        guard posten.intervallMonate > 1 else { return max(ab, posten.giltAb) }
        return naechsteFaelligkeit(giltAb: posten.giltAb, intervall: posten.intervallMonate,
                                   abMonat: max(ab, posten.giltAb))
    }

    /// Der nächste Termin als Tag, der 31. wird im Februar zum 28. oder 29.,
    /// wie tag_im_monat in Python.
    func naechsterTermin(_ posten: Posten, ab monat: String? = nil) -> String {
        let faellig = naechsteFaelligkeit(posten, ab: monat)
        return String(format: "%@-%02d", faellig,
                      min(posten.tagImMonat, Monat.tage(faellig)))
    }

    /// Die anstehenden Termine der nicht monatlichen Posten, nach Datum
    /// sortiert. Monatliche bleiben draußen, sie kommen ohnehin jeden Monat und
    /// stehen als Abschlag in der Liste. Beendete Posten zählen nur bis zu
    /// ihrem letzten Monat.
    func anstehendeTermine(ab monat: String? = nil, monate: Int = 6) -> [Termin] {
        let ab = monat ?? Monat.von(heute)
        let bis = Monat.plus(ab, monate)
        return regeln(ab)
            .filter { $0.intervallMonate > 1 }
            .compactMap { posten in
                let faellig = naechsteFaelligkeit(posten, ab: ab)
                guard faellig <= bis else { return nil }
                if let ende = posten.giltBis, faellig > ende { return nil }
                return Termin(posten: posten, datum: naechsterTermin(posten, ab: ab))
            }
            .sorted { $0.datum < $1.datum }
    }
}

extension Kern {
    /// Die Regeln, die in diesem Monat schon gelten, also mit `nur_gueltige`
    /// wie in Python. Die Fortschreibung braucht das, damit nichts vor seinem
    /// Start bucht. Die Verwaltung nimmt dagegen alle, siehe `regeln`.
    func gueltigeRegeln(_ monat: String) -> [Posten] {
        regeln(monat).filter { $0.giltAb <= monat }
    }

    private func faellig(_ posten: Posten, _ monat: String) -> Bool {
        if posten.giltAb > monat { return false }
        if let ende = posten.giltBis, ende < monat { return false }
        return Monat.zwischen(posten.giltAb, monat) % posten.intervallMonate == 0
    }

    /// Legt für den Monat alle fälligen Abschläge als geplante Buchungen an,
    /// wie `Haushalt.fortschreiben`. Mehrfach aufgerufen entsteht nichts
    /// doppelt. Steht auto_bestaetigen auf 1, werden Buchungen bis heute
    /// gleich bestätigt.
    @discardableResult
    func fortschreiben(_ monat: String? = nil) throws -> Int {
        let monat = monat ?? Monat.von(heute)
        var neue = 0
        for posten in gueltigeRegeln(monat) where faellig(posten, monat) {
            // Hat schon eine Regel derselben Änderungskette einen Abschlag im
            // Monat, etwa gebucht vor einer rückwirkenden Änderung, entsteht
            // kein zweiter.
            let kette = regelkette(posten.id)
            let vorhanden = try db.zeilen("""
                SELECT 1 AS da FROM buchungen WHERE art='abschlag' AND soll_monat=?
                AND regel_id IN (\(platzhalter(kette.count)))
                """, [.text(monat)] + kette.map { Wert.zahl($0) })
            if !vorhanden.isEmpty { continue }

            let topfId = try db.zeilen("SELECT id FROM toepfe WHERE regel_id=?",
                                       [.zahl(posten.id)]).first?["id"]?.alsZahl
            let tag = min(posten.tagImMonat, Monat.tage(monat))
            let id = try db.schreiben("""
                INSERT OR IGNORE INTO buchungen
                (datum, betrag_cent, regel_id, topf_id, art, status, soll_monat, quelle)
                VALUES (?,?,?,?,'abschlag','geplant',?,'regel')
                """, [.text(String(format: "%@-%02d", monat, tag)),
                      .zahl(Int64(posten.betragCent)), .zahl(posten.id),
                      topfId.map { Wert.zahl($0) } ?? .leer, .text(monat)])
            neue += 1
            for zeile in try db.zeilen("SELECT kategorie_id FROM regel_kategorien WHERE regel_id=?",
                                       [.zahl(posten.id)]) {
                guard let kid = zeile["kategorie_id"]?.alsZahl else { continue }
                try db.schreiben("INSERT INTO buchung_kategorien VALUES (?,?)",
                                 [.zahl(id), .zahl(kid)])
            }
        }
        if (try? db.einstellung("auto_bestaetigen")) == "1" {
            try db.schreiben("""
                UPDATE buchungen SET status='gebucht' WHERE status='geplant' AND datum<=?
                """, [.text(Datumsformat.iso.string(from: heute))])
        }
        return neue
    }

    /// Die Favoriten beim allerersten Start, wie `Haushalt.favoriten_vorbelegen`.
    /// Läuft nur einmal, danach gehört die Auswahl dem Nutzer.
    func favoritenVorbelegen() throws {
        if (try? db.einstellung("favoriten_vorbelegt")) == "1" { return }
        let schonFavorit = try db.zeilen("SELECT 1 AS da FROM kategorien WHERE favorit=1")
        if schonFavorit.isEmpty {
            var vorhanden: [String] = []
            for name in Kern.standardFavoriten {
                let treffer = try db.zeilen("SELECT 1 AS da FROM kategorien WHERE name=?",
                                            [.text(name)])
                if !treffer.isEmpty { vorhanden.append(name) }
            }
            for name in vorhanden {
                try db.schreiben("UPDATE kategorien SET favorit=1 WHERE name=?", [.text(name)])
            }
            try kategorienOrdnen(vorhanden)
        }
        try einstellungSetzen("favoriten_vorbelegt", "1")
    }

    /// Vorbelegte Favoriten beim allerersten Start, in dieser Reihenfolge.
    static let standardFavoriten = ["Lebensmittel", "Haushalt", "Gastronomie", "Tanken",
                                    "Fahrkarten", "Kleidung", "Arzt und Apotheke", "Sonstiges"]
}
