import XCTest

/// Die Demodatenbank, siehe Demodaten.swift. Sie soll jede Besonderheit des
/// Programms zeigen und dabei einen gewöhnlichen Monat, also keine Warnung.
final class DemodatenTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        if let pfad = Bundle(for: DemodatenTests.self).path(forResource: "schema", ofType: "sql") {
            setenv("HAUSHALT_SCHEMA", pfad, 1)
        }
    }

    private func demo(_ tag: String) throws -> (Kern, Demodaten.Bericht) {
        let db = try Datenbank(pfad: ":memory:")
        let bericht = try Demodaten.anlegen(in: db, heute: Pruefung.tag(tag))
        return (Kern(db: db, heute: Pruefung.tag(tag)), bericht)
    }

    /// Der laufende Monat warnt in jeder Demo (2026-09-26), sonst sähe man die
    /// Warnung beim Prüfen von Hand nie. Die Vormonate dürfen auch überzogen
    /// sein, ein knapper Haushalt hat solche Monate.
    func testDerLaufendeMonatWarnt() throws {
        // Früh, mitten und spät im Monat, im Dezember mit Weihnachten und im
        // Februar mit kurzem Monat
        for tag in ["2026-09-26", "2026-09-02", "2026-09-05", "2026-09-16", "2026-12-20",
                    "2027-02-27"] {
            let (h, bericht) = try demo(tag)
            XCTAssertNotNil(bericht.bild.warnung, tag)
            XCTAssertNil(bericht.bisZurWarnung, tag)
            // Ein Kauf, kein Auffüllen, und nicht mehr als nötig
            let fahrrad = h.buchungen(bericht.monat).filter { $0.notiz == "Fahrrad" }
            XCTAssertLessThanOrEqual(fahrrad.count, 1, tag)
            XCTAssertLessThan(-(fahrrad.first?.betragCent ?? 0), 80000, tag)
        }
    }

    func testJedeBesonderheitKommtVor() throws {
        let (h, bericht) = try demo("2026-09-26")
        let monat = bericht.monat
        XCTAssertEqual(h.regeln().count, 14)
        XCTAssertEqual(h.toepfe().count, 5)
        // Geplante Zeile für Haken und Stift, die Kontoführung am Dreißigsten
        XCTAssertTrue(h.buchungen(monat).contains { $0.posten == "Kontoführung" && $0.geplant })
        // Außerplanmäßig in beide Richtungen, im laufenden Monat die Einnahme
        XCTAssertEqual(bericht.bild.ausserplanCent, 63500)
        XCTAssertTrue(h.alleBuchungen().contains { $0.notiz == "Neuer Herd" && $0.ausserplanmaessig })
        // Aus dem Topf bezahlt, eine Aufstockung, eine eigene Gruppe an einer Buchung
        XCTAssertTrue(h.buchungen(monat).contains { $0.notiz == "Anzahlung Ferienwohnung" && $0.topfId != nil })
        XCTAssertEqual(h.einlagen(monat).count, 1)
        XCTAssertTrue(h.alleBuchungen().contains { $0.eigeneGruppe == "Arbeit" })
        // Umbenannt, umgeordnet, teurer geworden
        XCTAssertTrue(h.buchungen(monat).contains { $0.posten == "Streaming" && $0.kategorie == "Medien" })
        // Demnächst fällig und ein Kontostand
        XCTAssertFalse(h.anstehendeTermine(ab: monat).isEmpty)
        // Ein Haushalt, der ausgibt, was er hat, legt nicht über tausend Euro
        // im Monat zurück. Vorher stand der Kontostand nach gut einem Jahr bei
        // über 20.000 € (2026-09-26).
        let konto = try XCTUnwrap(h.kontostand())
        XCTAssertLessThan(konto, 1_200_000)
        XCTAssertGreaterThan(konto, 500_000)
        // Zwölf Balken mit Daten und ein Vorjahr zum Vergleichen
        XCTAssertTrue(h.verlaufZeitraum(.monat, "2026-09-26").allSatisfy { $0.gesamt > 0 })
        XCTAssertNotNil(h.vergleichZeitraum(.monat, "2026-09-26").vorjahr)
    }

    /// Am selben Tag dieselbe Datenbank, sonst sähe jeder Lauf anders aus.
    func testGleicherTagGleicheDaten() throws {
        let (a, _) = try demo("2026-09-26")
        let (b, _) = try demo("2026-09-26")
        XCTAssertEqual(a.alleBuchungen().map(\.betragCent), b.alleBuchungen().map(\.betragCent))
    }
}
