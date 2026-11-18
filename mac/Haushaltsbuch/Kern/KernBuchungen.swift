import Foundation

/// Buchungen schreiben, ändern, löschen und bestätigen, eins zu eins nach
/// haushalt/kern.py. Bis zum 26. September 2026 stand das im Speicher der
/// Oberfläche. Es gehört in den Kern, damit die Tests es ohne Fenster prüfen
/// können, siehe HaushaltsbuchTests.
///
/// Eine Buchung trägt genau eine Kategorie. `buchung_kategorien` bleibt als
/// Zwischentabelle, `regel_kategorien` braucht sie ohnehin, aber je Buchung
/// steht dort nur eine Zeile.
extension Kern {
    /// Was ein Wert beim Ändern tun soll. Topf und Gruppe nehmen auch nil an,
    /// um sie zu entfernen, deshalb reicht ein Optional allein nicht, um
    /// "nicht anfassen" auszudrücken. In Python ist das `_NICHT_GESETZT`.
    enum Aenderung<T> {
        case bleibt
        case setzen(T)
    }

    /// Wie eine Gruppe gespeichert wird, wie `kern._gruppe`. Nil heißt nicht
    /// gesetzt, die Stufe darüber gilt. Ein leerer Text heißt bewusst gelöscht
    /// und beendet die Vererbung.
    static func gruppenwert(_ gruppe: String?) -> Wert {
        guard let gruppe else { return .leer }
        return .text(gruppe.trimmingCharacters(in: .whitespaces))
    }

    /// Eine Notiz ohne Inhalt ist keine Notiz, sie wird NULL.
    static func notizwert(_ notiz: String?) -> Wert {
        let sauber = notiz?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return sauber.isEmpty ? .leer : .text(sauber)
    }

    func kategorieId(_ name: String) throws -> Int64 {
        guard let id = try db.zeilen("SELECT id FROM kategorien WHERE name=?", [.text(name)])
            .first?["id"]?.alsZahl else {
            throw DbFehler(text: "Kategorie \(name) gibt es nicht")
        }
        return id
    }

    /// Eine variable Ausgabe oder Einnahme. Ohne Datum gilt heute.
    ///
    /// `ausserplanmaessig` hält eine Buchung aus dem Monatsbudget heraus, in
    /// beide Richtungen, siehe CLAUDE.md, Entscheidungen. Den Nutzungszähler
    /// der Kategorie erhöht der Auslöser trg_kategorie_nutzung.
    @discardableResult
    func buchen(_ betrag: Int, kategorieId: Int64, datum: String? = nil, notiz: String? = nil,
                topfId: Int64? = nil, gruppe: String? = nil,
                ausserplanmaessig: Bool = false) throws -> Int64 {
        let id = try db.schreiben("""
            INSERT INTO buchungen (datum, betrag_cent, notiz, topf_id, gruppe, ausserplanmaessig)
            VALUES (?,?,?,?,?,?)
            """, [.text(datum ?? Datumsformat.iso.string(from: heute)),
                  .zahl(Int64(betrag)), Self.notizwert(notiz),
                  topfId.map { Wert.zahl($0) } ?? .leer,
                  Self.gruppenwert(gruppe),
                  .zahl(ausserplanmaessig ? 1 : 0)])
        try db.schreiben("INSERT OR IGNORE INTO buchung_kategorien VALUES (?,?)",
                         [.zahl(id), .zahl(kategorieId)])
        return id
    }

    /// Dasselbe mit dem Namen der Kategorie, wie `Haushalt.buchen`.
    @discardableResult
    func buchen(_ betrag: Int, _ kategorie: String, datum: String? = nil, notiz: String? = nil,
                topfId: Int64? = nil, gruppe: String? = nil,
                ausserplanmaessig: Bool = false) throws -> Int64 {
        try buchen(betrag, kategorieId: try kategorieId(kategorie), datum: datum, notiz: notiz,
                   topfId: topfId, gruppe: gruppe, ausserplanmaessig: ausserplanmaessig)
    }

    /// Ändert eine Buchung. Was nicht übergeben wird, bleibt, wie es ist.
    /// Eine neue Kategorie ersetzt die alte, eine Buchung trägt genau eine.
    /// Eine leere Notiz löscht die Notiz.
    func buchungAendern(_ id: Int64, betrag: Int? = nil, datum: String? = nil,
                        notiz: String? = nil, kategorieId: Int64? = nil,
                        topf: Aenderung<Int64?> = .bleibt,
                        gruppe: Aenderung<String?> = .bleibt,
                        ausserplanmaessig: Bool? = nil) throws {
        if let betrag {
            try db.schreiben("UPDATE buchungen SET betrag_cent=? WHERE id=?",
                             [.zahl(Int64(betrag)), .zahl(id)])
        }
        if let datum {
            try db.schreiben("UPDATE buchungen SET datum=? WHERE id=?", [.text(datum), .zahl(id)])
        }
        if let notiz {
            try db.schreiben("UPDATE buchungen SET notiz=? WHERE id=?",
                             [Self.notizwert(notiz), .zahl(id)])
        }
        if let kategorieId {
            try db.schreiben("DELETE FROM buchung_kategorien WHERE buchung_id=?", [.zahl(id)])
            try db.schreiben("INSERT OR IGNORE INTO buchung_kategorien VALUES (?,?)",
                             [.zahl(id), .zahl(kategorieId)])
        }
        if case .setzen(let topfId) = topf {
            try db.schreiben("UPDATE buchungen SET topf_id=? WHERE id=?",
                             [topfId.map { Wert.zahl($0) } ?? .leer, .zahl(id)])
        }
        if case .setzen(let neu) = gruppe {
            try db.schreiben("UPDATE buchungen SET gruppe=? WHERE id=?",
                             [Self.gruppenwert(neu), .zahl(id)])
        }
        if let ausserplanmaessig {
            try db.schreiben("UPDATE buchungen SET ausserplanmaessig=? WHERE id=?",
                             [.zahl(ausserplanmaessig ? 1 : 0), .zahl(id)])
        }
    }

    /// Dasselbe mit dem Namen der Kategorie.
    func buchungAendern(_ id: Int64, kategorie: String) throws {
        try buchungAendern(id, kategorieId: try kategorieId(kategorie))
    }

    func buchungLoeschen(_ id: Int64) throws {
        try db.schreiben("DELETE FROM buchungen WHERE id=?", [.zahl(id)])
    }

    /// Ein geplanter Abschlag wird zur echten Buchung, auf Wunsch mit anderem
    /// Betrag oder Datum, etwa wenn der Strom diesen Monat anders abging.
    func bestaetigen(_ id: Int64, betrag: Int? = nil, datum: String? = nil) throws {
        try db.schreiben("UPDATE buchungen SET status='gebucht' WHERE id=?", [.zahl(id)])
        try buchungAendern(id, betrag: betrag, datum: datum)
    }

    /// Die Buchungen eines Monats, neueste zuerst, wie `Haushalt.buchungen`.
    /// Die wirksame Gruppe ist die der Buchung, sonst die des Postens, sonst
    /// die des Topfs, sonst die der Kategorie. Leerer Text heißt bewusst
    /// gelöscht und beendet die Vererbung.
    func buchungen(_ monat: String) -> [Buchung] {
        let zeilen = (try? db.zeilen("""
            SELECT b.id, b.datum, b.betrag_cent, b.notiz, b.ausserplanmaessig, b.regel_id,
                   b.gruppe, b.topf_id, b.status, b.art, b.soll_monat,
                   k.name AS kategorie, r.name AS posten,
                   NULLIF(COALESCE(b.gruppe, r.gruppe, t.gruppe, k.gruppe), '') AS wirksame_gruppe
            FROM buchungen b
            LEFT JOIN buchung_kategorien bk ON bk.buchung_id = b.id
            LEFT JOIN kategorien k ON k.id = bk.kategorie_id
            LEFT JOIN regeln r ON r.id = b.regel_id
            LEFT JOIN toepfe t ON t.id = b.topf_id
            WHERE substr(b.datum, 1, 7) = ?
            ORDER BY b.datum DESC, b.id DESC
            """, [.text(monat)])) ?? []
        return zeilen.map(Buchung.init)
    }

    // MARK: Lesen, was die Oberfläche bisher selbst las

    func einstellung(_ schluessel: String) -> String? {
        (try? db.einstellung(schluessel)) ?? nil
    }

    /// Die Kategorien, Favoriten zuerst in fester Reihenfolge, der Rest nach
    /// Nutzung, wie `Haushalt.kategorien`.
    func kategorien(nurAktive: Bool = true) -> [Kategorie] {
        let zeilen = (try? db.zeilen("""
            SELECT id, name, icon, gruppe, favorit, sortierung, aktiv FROM kategorien
            \(nurAktive ? "WHERE aktiv=1" : "")
            ORDER BY favorit DESC, CASE WHEN favorit=1 THEN sortierung END,
                     nutzungen DESC, sortierung
            """)) ?? []
        return zeilen.map(Kategorie.init)
    }

    /// Füllstand eines Topfs zum Monatsende. Nie gespeichert, immer gerechnet.
    func topfStand(_ topfId: Int64, _ monat: String? = nil) -> Int {
        guard let zeile = try? db.zeilen("SELECT * FROM toepfe WHERE id=?", [.zahl(topfId)]).first
        else { return 0 }
        return topfLauf(TopfZeile(zeile: zeile), monat ?? Monat.von(heute)).stand
    }

    /// Setzt die Gruppe eines Topfs. Nil heißt nicht gesetzt und erbt, leer
    /// heißt bewusst keine.
    func topfGruppeSetzen(_ topfId: Int64, gruppe: String?) throws {
        try db.schreiben("UPDATE toepfe SET gruppe=? WHERE id=?",
                         [Self.gruppenwert(gruppe), .zahl(topfId)])
    }
}
