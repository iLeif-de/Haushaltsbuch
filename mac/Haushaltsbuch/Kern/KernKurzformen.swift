import Foundation

/// Kurzformen mit den Namen der Kategorien statt ihrer Nummern, für die
/// Prüfungen und die Demodaten, damit beide so lesbar bleiben wie test_kern.py.
extension Kern {
    @discardableResult
    func posten(_ name: String, _ betrag: Int, _ tag: Int, _ giltAb: String, _ kategorie: String,
                intervall: Int = 1, schonVorhanden: Int = 0, gruppe: String? = nil) throws -> Int64 {
        try regelAnlegen(name: name, betrag: betrag, tag: tag, giltAb: giltAb,
                         kategorieId: try kategorieId(kategorie), intervall: intervall,
                         schonVorhanden: schonVorhanden, gruppe: gruppe)
    }

    @discardableResult
    func topf(_ name: String, rate: Int? = nil, ziel: Int? = nil, zielMonat: String? = nil,
              schonVorhanden: Int = 0, kategorie: String? = nil,
              gruppe: String? = nil) throws -> Int64 {
        try topfAnlegen(name: name, rate: rate, ziel: ziel, zielMonat: zielMonat,
                        schonVorhanden: schonVorhanden,
                        kategorieId: try kategorie.map { try kategorieId($0) }, gruppe: gruppe)
    }
}
