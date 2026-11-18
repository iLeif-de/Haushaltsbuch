import Foundation

/// Kategorien und Einstellungen, eins zu eins nach haushalt/kern.py.
///
/// Die Gruppe an einer Kategorie ist nur die Vorgabe. Ein fester Posten
/// übersteuert sie, eine einzelne Buchung übersteuert auch den Posten. Deshalb
/// liegen Haftpflicht und Kfz Versicherung beide in der Kategorie
/// Versicherungen, aber in den Gruppen Wohnen und Auto.
extension Kern {
    @discardableResult
    func kategorieAnlegen(name: String, gruppe: String?, icon: String?) throws -> Int64 {
        try db.schreiben("INSERT INTO kategorien (name, gruppe, icon, farbe) VALUES (?,?,?,NULL)",
                         [.text(name),
                          gruppe.map { Wert.text($0) } ?? .leer,
                          icon.map { Wert.text($0) } ?? .leer])
    }

    /// Ändert eine Kategorie. Nur was übergeben wird, wird gesetzt. Eine leere
    /// Gruppe löscht den Eintrag, dann hat die Kategorie keine Vorgabe mehr.
    func kategorieAendern(_ id: Int64, neuerName: String? = nil, gruppe: String? = nil,
                          icon: String? = nil, favorit: Bool? = nil,
                          aktiv: Bool? = nil) throws {
        if let neuerName {
            try db.schreiben("UPDATE kategorien SET name=? WHERE id=?",
                             [.text(neuerName), .zahl(id)])
        }
        if let gruppe {
            let sauber = gruppe.trimmingCharacters(in: .whitespaces)
            try db.schreiben("UPDATE kategorien SET gruppe=? WHERE id=?",
                             [sauber.isEmpty ? .leer : .text(sauber), .zahl(id)])
        }
        if let icon {
            try db.schreiben("UPDATE kategorien SET icon=? WHERE id=?", [.text(icon), .zahl(id)])
        }
        if let favorit {
            try db.schreiben("UPDATE kategorien SET favorit=? WHERE id=?",
                             [.zahl(favorit ? 1 : 0), .zahl(id)])
        }
        if let aktiv {
            try db.schreiben("UPDATE kategorien SET aktiv=? WHERE id=?",
                             [.zahl(aktiv ? 1 : 0), .zahl(id)])
        }
    }

    /// Löscht eine Kategorie und hängt ihre Buchungen und Posten an die
    /// Ersatzkategorie. Es geht keine Buchung verloren.
    func kategorieLoeschen(_ id: Int64, ersatzId: Int64) throws {
        try db.schreiben("""
            UPDATE OR IGNORE buchung_kategorien SET kategorie_id=? WHERE kategorie_id=?
            """, [.zahl(ersatzId), .zahl(id)])
        try db.schreiben("DELETE FROM buchung_kategorien WHERE kategorie_id=?", [.zahl(id)])
        try db.schreiben("""
            UPDATE OR IGNORE regel_kategorien SET kategorie_id=? WHERE kategorie_id=?
            """, [.zahl(ersatzId), .zahl(id)])
        try db.schreiben("DELETE FROM regel_kategorien WHERE kategorie_id=?", [.zahl(id)])
        try db.schreiben("DELETE FROM kategorien WHERE id=?", [.zahl(id)])
    }

    /// Setzt die Reihenfolge, die Position in der Liste wird die Sortierung.
    func kategorienOrdnen(_ namen: [String]) throws {
        for (i, name) in namen.enumerated() {
            try db.schreiben("UPDATE kategorien SET sortierung=? WHERE name=?",
                             [.zahl(Int64(i + 1)), .text(name)])
        }
    }

    // MARK: Einstellungen

    func einstellungSetzen(_ schluessel: String, _ wert: String) throws {
        try db.schreiben("INSERT INTO einstellungen (schluessel, wert) VALUES (?,?) "
                         + "ON CONFLICT(schluessel) DO UPDATE SET wert=excluded.wert",
                         [.text(schluessel), .text(wert)])
    }

    /// Setzt oder korrigiert den Startsaldo, den Ausgangspunkt der
    /// Kontostandsrechnung. Das ist keine Buchung und rührt das Monatsbudget
    /// nicht an, es ersetzt nur den Ausgangspunkt. Ohne Datum bleibt ein schon
    /// gesetztes stehen, beim ersten Mal gilt heute.
    func startsaldoSetzen(betragCent: Int, datum: String?) throws {
        let bisher = try? db.einstellung("startsaldo_datum")
        let tag = datum ?? (bisher ?? nil) ?? Datumsformat.iso.string(from: heute)
        try einstellungSetzen("startsaldo_cent", String(betragCent))
        try einstellungSetzen("startsaldo_datum", tag)
    }
}
