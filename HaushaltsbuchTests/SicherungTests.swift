import XCTest

/// Monatssicherung, Sicherung von Hand und der große Export, wie
/// `monatssicherung_anlegen` in app.py und der Abschnitt Daten in
/// ui/einstellungen.py.
final class SicherungTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        if let pfad = Bundle(for: SicherungTests.self).path(forResource: "schema", ofType: "sql") {
            setenv("HAUSHALT_SCHEMA", pfad, 1)
        }
    }

    /// Ein frischer Ordner im Zwischenordner, danach wieder weg.
    private func ordner(_ name: String) throws -> URL {
        let ordner = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: ordner)
        try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: ordner) }
        return ordner
    }

    private func namen(_ ordner: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: ordner.path)) ?? []).sorted()
    }

    func testMonatssicherungEinmalImMonat() throws {
        let ordner = try ordner("haushalt_monatssicherung")
        let db = try Datenbank(pfad: ":memory:")
        let h = Kern(db: db, heute: Pruefung.tag("2026-09-20"))
        try h.buchen(-1234, "Lebensmittel", datum: "2026-09-20")

        let erste = try Sicherungen.monatlich(db, heute: h.heute, ordner: ordner)
        XCTAssertEqual(erste?.lastPathComponent, "haushaltsbuch-2026-09.sqlite")
        let kopie = try Datenbank(pfad: try XCTUnwrap(erste).path)
        XCTAssertEqual(Kern(db: kopie, heute: h.heute).buchungen("2026-09").first?.betragCent,
                       -1234)
        // Im selben Monat entsteht keine zweite
        XCTAssertNil(try Sicherungen.monatlich(db, heute: h.heute, ordner: ordner))
        XCTAssertEqual(namen(ordner), ["haushaltsbuch-2026-09.sqlite"])
    }

    /// Eine leere Datei gilt als nicht vorhanden. Sonst wiese ein einmal
    /// misslungener Versuch den Monat für immer als gesichert aus.
    func testLeereSicherungGiltAlsNichtVorhanden() throws {
        let ordner = try ordner("haushalt_leere_sicherung")
        let leer = ordner.appendingPathComponent("haushaltsbuch-2026-09.sqlite")
        FileManager.default.createFile(atPath: leer.path, contents: Data())
        let db = try Datenbank(pfad: ":memory:")
        XCTAssertNotNil(try Sicherungen.monatlich(db, heute: Pruefung.tag("2026-09-20"),
                                                  ordner: ordner))
        let groesse = try FileManager.default.attributesOfItem(atPath: leer.path)[.size] as? Int
        XCTAssertGreaterThan(groesse ?? 0, 0)
    }

    /// Die jüngsten zwölf bleiben, nach Namen sortiert, die von Hand zählen mit.
    func testZwoelfBleiben() throws {
        let ordner = try ordner("haushalt_zwoelf")
        for i in 0..<14 {
            let name = "haushaltsbuch-\(Monat.plus("2025-06", i)).sqlite"
            FileManager.default.createFile(atPath: ordner.appendingPathComponent(name).path,
                                           contents: Data("x".utf8))
        }
        // Sicherungen von Fassung 1.2 hießen haushalt-, sie zählen nicht mit
        let alt = ordner.appendingPathComponent("haushalt-2024-01.sqlite")
        FileManager.default.createFile(atPath: alt.path, contents: Data("x".utf8))
        let fremd = ordner.appendingPathComponent("notizen.txt")
        FileManager.default.createFile(atPath: fremd.path, contents: Data())
        let db = try Datenbank(pfad: ":memory:")
        let ziel = try Sicherungen.jetzt(db, heute: Pruefung.tag("2026-09-26"), ordner: ordner)
        XCTAssertEqual(ziel.lastPathComponent, "haushaltsbuch-2026-09-26.sqlite")
        let sicherungen = namen(ordner).filter { $0.hasPrefix(Sicherungen.vorsilbe) }
        XCTAssertEqual(sicherungen.count, Sicherungen.behalten)
        XCTAssertEqual(sicherungen.first, "haushaltsbuch-2025-09.sqlite")
        XCTAssertTrue(sicherungen.contains("haushaltsbuch-2026-09-26.sqlite"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fremd.path),
                      "was keine Sicherung ist, bleibt liegen")
        XCTAssertTrue(FileManager.default.fileExists(atPath: alt.path))
    }

    /// Für die echte Datenbank ein eigener Ordner im normalen Dateisystem, für
    /// jede Kopie einer neben ihr. Sonst landete die Monatssicherung einer
    /// Kopie im echten Ordner, und die echte bekäme diesen Monat keine mehr.
    func testOrdnerDerSicherungen() {
        XCTAssertTrue(Pfade.sicherungen(fuer: Pfade.standard).path
            .hasSuffix("Library/Application Support/Haushaltsbuch/backup"))
        XCTAssertEqual(Pfade.sicherungen(fuer: "/tmp/probe/haushalt.sqlite").path,
                       "/tmp/probe/backup")
    }

    /// Der große Export, alle Buchungen, auf Wunsch mit Kontostand und
    /// Rücklagen zum Ende des Zeitraums, Spalten wie CSV_SPALTEN.
    func testExportMitKontoUndRuecklagen() throws {
        let ordner = try ordner("haushalt_export")
        let h = Kern(db: try Datenbank(pfad: ":memory:"), heute: Pruefung.tag("2026-09-20"))
        try h.startsaldoSetzen(betragCent: 100000, datum: "2026-09-01")
        try h.buchen(-4820, "Lebensmittel", datum: "2026-09-05", notiz: "Brot; Butter")
        try h.buchen(-1500, "Tanken", datum: "2026-08-30")
        try h.topf("Urlaub", rate: 0, schonVorhanden: 30000)

        let ziel = ordner.appendingPathComponent("export.csv")
        try Ausfuhr.csv(h.alleBuchungen(von: "2026-09-01", bis: "2026-09-30"), nach: ziel,
                        zusatz: Ausfuhr.kontoZeilen(h, bis: "2026-09-30"))
        let zeilen = try String(contentsOf: ziel, encoding: .utf8)
            .components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(zeilen, [
            "Datum;Betrag in Euro;Kategorien;Gruppe;Notiz;Posten;Art;Status",
            // Ein Semikolon in der Notiz wird eingefasst, wie csv.writer es macht
            "2026-09-05;-48,20;Lebensmittel;Essen und Trinken;\"Brot; Butter\";;variabel;gebucht",
            "2026-09-30;951,80;;;Kontostand;;kontostand;",
            "2026-09-30;300,00;;;Urlaub;;ruecklage;",
        ])
        // Der Dateiname nennt den Zeitraum, ohne Eingrenzung das Datum
        XCTAssertEqual(Ausfuhr.gesamtZiel(von: "2026-09-01", bis: nil, heute: h.heute)
            .lastPathComponent, "haushaltsbuch-buchungen-2026-09-01-bis-heute.csv")
        XCTAssertEqual(Ausfuhr.gesamtZiel(von: nil, bis: nil, heute: h.heute)
            .lastPathComponent, "haushaltsbuch-buchungen-2026-09-20.csv")
    }
}
