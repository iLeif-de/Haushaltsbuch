import Foundation

/// Das Ändern von Töpfen, eins zu eins nach haushalt/kern.py.
///
/// Automatische Töpfe gehören ihrem festen Posten und werden hier nicht
/// angefasst, sie ändern sich über den Posten. Alles hier gilt für eigene Töpfe.
extension Kern {
    /// Ein eigener Topf. Entweder die Rate angeben oder Ziel und Zielmonat, dann
    /// wird die Rate daraus gerechnet.
    @discardableResult
    func topfAnlegen(name: String, rate: Int?, ziel: Int?, zielMonat: String?,
                     schonVorhanden: Int = 0, kategorieId: Int64?, gruppe: String?) throws -> Int64 {
        let start = Monat.von(heute)
        var echteRate = rate
        if echteRate == nil {
            guard let ziel, let zielMonat else {
                throw DbFehler(text: "Entweder eine Rate angeben oder Ziel und Monat.")
            }
            let monate = max(1, Monat.zwischen(start, zielMonat))
            echteRate = max(0, abgerundet(ziel - schonVorhanden + monate - 1, monate))
        }
        return try db.schreiben("""
            INSERT INTO toepfe (name, kategorie_id, gruppe, ziel_cent, rate_cent, ziel_monat,
            startstand_cent, start_monat) VALUES (?,?,?,?,?,?,?,?)
            """, [.text(name),
                  kategorieId.map { Wert.zahl($0) } ?? .leer,
                  gruppe.map { Wert.text($0.trimmingCharacters(in: .whitespaces)) } ?? .leer,
                  ziel.map { Wert.zahl(Int64($0)) } ?? .leer,
                  .zahl(Int64(echteRate ?? 0)),
                  zielMonat.map { Wert.text($0) } ?? .leer,
                  .zahl(Int64(schonVorhanden)), .text(start)])
    }

    /// Ändert einen eigenen Topf. Der Dialog setzt immer alle fünf Werte, das ist
    /// dasselbe, was ui/toepfe.py an `topf_aendern` übergibt. Kategorie, Gruppe
    /// und Ziel nehmen nil an, um sie zu entfernen.
    func topfAendern(_ topfId: Int64, name: String, kategorieId: Int64?, gruppe: String?,
                     rate: Int, ziel: Int?) throws {
        try db.schreiben("UPDATE toepfe SET name=? WHERE id=?", [.text(name), .zahl(topfId)])
        try db.schreiben("UPDATE toepfe SET kategorie_id=? WHERE id=?",
                         [kategorieId.map { Wert.zahl($0) } ?? .leer, .zahl(topfId)])
        try db.schreiben("UPDATE toepfe SET gruppe=? WHERE id=?",
                         [gruppe.map { Wert.text($0.trimmingCharacters(in: .whitespaces)) } ?? .leer,
                          .zahl(topfId)])
        try db.schreiben("UPDATE toepfe SET rate_cent=? WHERE id=?",
                         [.zahl(Int64(rate)), .zahl(topfId)])
        try db.schreiben("UPDATE toepfe SET ziel_cent=? WHERE id=?",
                         [ziel.map { Wert.zahl(Int64($0)) } ?? .leer, .zahl(topfId)])
    }

    func topfPausieren(_ topfId: Int64, pausiert: Bool) throws {
        try db.schreiben("UPDATE toepfe SET pausiert=? WHERE id=?",
                         [.zahl(pausiert ? 1 : 0), .zahl(topfId)])
    }

    /// Beendet einen Topf, der Rest fließt rechnerisch ins freie Budget.
    func topfAufloesen(_ topfId: Int64) throws {
        try db.schreiben("UPDATE toepfe SET aufgeloest_am=? WHERE id=?",
                         [.text(Datumsformat.iso.string(from: heute)), .zahl(topfId)])
    }

    /// Legt Geld außerhalb der Rate in einen Topf.
    ///
    /// Es entsteht keine Buchung, das Geld liegt schon auf dem Konto und ist ab
    /// diesem Monat nur nicht mehr frei verfügbar. Die Aufstockung steht als
    /// Ereignis in ihrem Monat und wirkt wie eine Entnahme, nur andersherum.
    /// Was nicht mehr ins Ziel passt, wird abgelehnt und nicht stillschweigend
    /// geschluckt, denn der Stand wird aufs Ziel gedeckelt.
    func topfAufstocken(_ topfId: Int64, betrag: Int) throws {
        let betrag = abs(betrag)
        guard let zeile = try db.zeilen("SELECT * FROM toepfe WHERE id=?",
                                        [.zahl(topfId)]).first else {
            throw DbFehler(text: "Topf nicht gefunden")
        }
        let topf = TopfZeile(zeile: zeile)
        if let ziel = topf.zielCent, ziel != 0 {
            let passt = ziel - topfLauf(topf, Monat.von(heute)).stand
            if passt <= 0 {
                throw DbFehler(text: "\(topf.name) ist schon voll. Erhöhe erst das Ziel.")
            }
            if betrag > passt {
                throw DbFehler(text: "In \(topf.name) passen nur noch \(Geld.euro(passt)). "
                               + "Erhöhe erst das Ziel.")
            }
        }
        try db.schreiben("INSERT INTO topf_einlagen (topf_id, monat, betrag_cent) VALUES (?,?,?)",
                         [.zahl(topfId), .text(Monat.von(heute)), .zahl(Int64(betrag))])
    }

    /// Nimmt eine Aufstockung zurück. Der Stand sinkt wieder um ihren Betrag, bei
    /// einem Topf mit Termin steigen die folgenden Raten, denn es fehlt mehr.
    func topfEinlageLoeschen(_ einlageId: Int64) throws {
        try db.schreiben("DELETE FROM topf_einlagen WHERE id=?", [.zahl(einlageId)])
    }

    /// Die Aufstockungen eines Monats mit dem Namen ihres Topfs. Sie sind keine
    /// Buchungen und tauchen deshalb nicht in der Buchungsliste auf, sollen aber
    /// zu sehen sein, sonst wäre nicht nachvollziehbar, wo das Geld geblieben ist.
    func einlagen(_ monat: String? = nil) -> [Einlage] {
        let monat = monat ?? Monat.von(heute)
        let zeilen = (try? db.zeilen("""
            SELECT e.*, t.name AS topf FROM topf_einlagen e
            JOIN toepfe t ON t.id = e.topf_id
            WHERE e.monat=? AND t.aufgeloest_am IS NULL ORDER BY e.id
            """, [.text(monat)])) ?? []
        return zeilen.map(Einlage.init)
    }
}
