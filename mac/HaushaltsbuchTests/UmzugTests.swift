import XCTest

/// Der Umzug der Datenbank von Fassung 1.2 an den Ort von 2.0 beim ersten
/// Start, siehe Umzug.swift.
final class UmzugTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        if let pfad = Bundle(for: UmzugTests.self).path(forResource: "schema", ofType: "sql") {
            setenv("HAUSHALT_SCHEMA", pfad, 1)
        }
    }

    /// Zwei Ordner wie iCloud Drive, der alte und der neue.
    private func ordner() throws -> (alt: String, neu: String) {
        let wurzel = FileManager.default.temporaryDirectory.appendingPathComponent("haushalt_umzug")
        try? FileManager.default.removeItem(at: wurzel)
        addTeardownBlock { try? FileManager.default.removeItem(at: wurzel) }
        return (wurzel.appendingPathComponent("Haushaltbuch/haushalt.sqlite").path,
                wurzel.appendingPathComponent("Haushaltsbuch/haushaltsbuch.sqlite").path)
    }

    func testUmzugNimmtAllesMit() throws {
        let (alt, neu) = try ordner()
        do {
            // Wie Fassung 1.2 sie hinterlässt, im WAL Modus mit frischen Buchungen
            let db = try Datenbank(pfad: alt)
            try db.ausfuehren("PRAGMA journal_mode = WAL")
            let h = Kern(db: db, heute: Pruefung.tag("2026-09-20"))
            try h.posten("Miete", -80000, 1, "2026-09", "Miete")
            for i in 0..<30 { try h.buchen(-100 - i, "Lebensmittel", datum: "2026-09-20") }
            XCTAssertTrue(try Umzug.wennNoetig(von: alt, nach: neu),
                          "bei offener Verbindung der alten Fassung")
        }
        let db = try Datenbank(pfad: neu)
        let h = Kern(db: db, heute: Pruefung.tag("2026-09-20"))
        XCTAssertEqual(h.buchungen("2026-09").count, 30)
        XCTAssertEqual(h.regeln().map(\.name), ["Miete"])
        // Die alte liegt noch da, aber unter einem Namen, den 1.2 nicht findet
        XCTAssertFalse(FileManager.default.fileExists(atPath: alt))
        XCTAssertTrue(FileManager.default.fileExists(atPath: alt + ".umgezogen"))
    }

    /// Gibt es am neuen Ort schon eine, wird nichts angefasst, auch wenn die
    /// alte noch daliegt. Sonst überschriebe ein zweiter Start die Buchungen,
    /// die inzwischen in 2.0 dazugekommen sind.
    func testKeinZweiterUmzug() throws {
        let (alt, neu) = try ordner()
        do {
            let h = Kern(db: try Datenbank(pfad: alt), heute: Pruefung.tag("2026-09-20"))
            try h.buchen(-100, "Lebensmittel", datum: "2026-09-20")
        }
        do {
            let h = Kern(db: try Datenbank(pfad: neu), heute: Pruefung.tag("2026-09-20"))
            try h.buchen(-200, "Tanken", datum: "2026-09-21")
        }
        XCTAssertFalse(try Umzug.wennNoetig(von: alt, nach: neu))
        XCTAssertTrue(FileManager.default.fileExists(atPath: alt), "die alte bleibt, wie sie ist")
        let h = Kern(db: try Datenbank(pfad: neu), heute: Pruefung.tag("2026-09-21"))
        XCTAssertEqual(h.buchungen("2026-09").map(\.betragCent), [-200])
    }

    /// Ohne alte Datenbank gibt es nichts umzuziehen, 2.0 fängt frisch an.
    func testOhneAlteNichts() throws {
        let (alt, neu) = try ordner()
        XCTAssertFalse(try Umzug.wennNoetig(von: alt, nach: neu))
        XCTAssertFalse(FileManager.default.fileExists(atPath: neu))
    }
}
