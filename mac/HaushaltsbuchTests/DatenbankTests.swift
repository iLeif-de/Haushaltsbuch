import XCTest

/// Migrationen und Sicherung, der Nachbau der letzten Abschnitte von
/// test_kern.py, dazu die Sicherung mit WAL Inhalt, die in Python nur von Hand
/// geprüft wurde.
final class DatenbankTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        if let pfad = Bundle(for: DatenbankTests.self).path(forResource: "schema", ofType: "sql") {
            setenv("HAUSHALT_SCHEMA", pfad, 1)
        }
    }

    /// Ein Pfad im Zwischenordner, samt Nebendateien und Sicherung vorher und
    /// nachher weggeräumt.
    private func pfad(_ name: String) -> String {
        let pfad = FileManager.default.temporaryDirectory.appendingPathComponent(name).path
        wegraeumen(pfad)
        addTeardownBlock { self.wegraeumen(pfad) }
        return pfad
    }

    private func wegraeumen(_ pfad: String) {
        let sicherung = "\(pfad).vor-v\(Datenbank.schemaFassung)"
        for datei in [pfad, sicherung, pfad + ".teil"] {
            for rest in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: datei + rest)
            }
        }
    }

    private func anzahl(_ db: Datenbank, _ sql: String) throws -> Int {
        try db.zeilen(sql).first?["c"]?.alsGanz ?? -1
    }

    /// Migration 9, Kategorien nach Art und Gruppen nach Lebensbereich. Aus
    /// einer frischen Datenbank wird der Stand von Fassung 8 nachgebaut, mit
    /// den alten Namen und Vorgaben und ein paar eigenen Änderungen eines
    /// Nutzers. Danach muss die Migration genau die Werksvorgaben umstellen und
    /// sonst nichts.
    func testMigration9() throws {
        let alt = pfad("haushalt_migration9_test.sqlite")
        var handy: Int64 = 0
        do {
            let db = try Datenbank(pfad: alt)
            let h = Kern(db: db, heute: Pruefung.tag("2026-09-18"))
            try db.ausfuehren("""
                DELETE FROM kategorien WHERE name IN ('Körperpflege', 'Sport', 'Kinder', 'Möbel und Geräte',
                    'Gebühren', 'Kredite und Raten', 'Spenden', 'Haustier');
                UPDATE kategorien SET name='Wohnen'     WHERE name='Miete';
                UPDATE kategorien SET name='Mobilität'  WHERE name='Fahrkarten';
                UPDATE kategorien SET name='Gesundheit' WHERE name='Arzt und Apotheke';
                UPDATE kategorien SET name='Freizeit'   WHERE name='Hobbys';
                UPDATE kategorien SET name='Bildung'    WHERE name='Kurse';
                UPDATE kategorien SET gruppe=NULL;
                UPDATE kategorien SET gruppe='Fixkosten' WHERE name IN ('Wohnen', 'Energie', 'Versicherungen', 'Kommunikation');
                UPDATE kategorien SET gruppe='Auto'      WHERE name IN ('Tanken', 'Werkstatt');
                UPDATE kategorien SET gruppe='Einnahmen' WHERE name='Gehalt';
                -- Was der Nutzer selbst getan hat
                UPDATE kategorien SET gruppe='Garderobe' WHERE name='Kleidung';
                UPDATE kategorien SET favorit=1 WHERE name='Mobilität';
                INSERT INTO kategorien (name, gruppe) VALUES ('Hobbys', NULL);
                DELETE FROM kategorien WHERE name='Bildung';
                UPDATE einstellungen SET wert='8' WHERE schluessel='schema_version';
                """)
            try h.posten("Miete", -80000, 1, "2026-09", "Wohnen")
            handy = try h.posten("Handy", -2000, 5, "2026-09", "Kommunikation", gruppe: "Fixkosten")
            try h.fortschreiben("2026-09")
        }

        let db = try Datenbank(pfad: alt)
        let h = Kern(db: db, heute: Pruefung.tag("2026-09-18"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: "\(alt).vor-v\(Datenbank.schemaFassung)"),
            "vor der Migration muss eine Kopie entstehen")
        let kat = Dictionary(uniqueKeysWithValues: h.kategorien().map { ($0.name, $0) })
        // Umbenannt, und die Buchungen folgen, weil sie an der id hängen
        XCTAssertNotNil(kat["Miete"])
        XCTAssertNil(kat["Wohnen"])
        XCTAssertEqual(kat["Fahrkarten"]?.favorit, true, "der Stern wandert mit")
        XCTAssertNotNil(kat["Arzt und Apotheke"])
        XCTAssertNil(kat["Gesundheit"])
        XCTAssertEqual(Set(h.buchungen("2026-09").filter { $0.posten == "Miete" }.map(\.kategorie)),
                       ["Miete"])
        // Nicht umbenannt, weil der neue Name schon vergeben war, und nicht
        // wieder angelegt, weil der Nutzer die Kategorie gelöscht hatte
        XCTAssertNotNil(kat["Freizeit"])
        XCTAssertNil(try XCTUnwrap(kat["Hobbys"]).gruppe)
        XCTAssertNil(kat["Kurse"])
        XCTAssertNil(kat["Bildung"])
        // Werksvorgaben umgestellt, eigene Vorgaben unberührt
        XCTAssertEqual(kat["Miete"]?.gruppe, "Wohnen")
        XCTAssertEqual(kat["Energie"]?.gruppe, "Wohnen")
        XCTAssertNil(try XCTUnwrap(kat["Versicherungen"]).gruppe)
        XCTAssertNil(try XCTUnwrap(kat["Kommunikation"]).gruppe)
        XCTAssertEqual(kat["Lebensmittel"]?.gruppe, "Essen und Trinken")
        XCTAssertEqual(kat["Kleidung"]?.gruppe, "Garderobe")
        // Die neuen Kategorien sind da
        XCTAssertTrue(Set(kat.keys).isSuperset(of: ["Körperpflege", "Gebühren",
                                                     "Kredite und Raten", "Haustier"]))
        // Posten fasst die Migration nie an, auch nicht mit Fixkosten
        XCTAssertEqual(h.regeln().first { $0.id == handy }?.gruppe, "Fixkosten")
        XCTAssertTrue(h.gruppen().contains("Fixkosten"), "wer sie noch trägt, sieht sie weiter")
        XCTAssertEqual(try db.einstellung("schema_version"), String(Datenbank.schemaFassung))
    }

    /// Eine scheiternde Migration lässt die Datei auf der Fassung davor, ohne
    /// Reste. Früher wurde die Fassung erst nach allen Migrationen geschrieben,
    /// und eine halb gelaufene Reihe ließ sich beim nächsten Start nie mehr
    /// öffnen.
    func testAbbruchEinerMigrationOhneReste() throws {
        let datei = pfad("haushalt_abbruch_test.sqlite")
        _ = try Datenbank(pfad: datei)
        let kaputt = Datenbank.schemaFassung + 1
        Datenbank.migrationen[kaputt] = "CREATE TABLE probe (a); SELECT kaputt FROM gibt_es_nicht;"
        XCTAssertThrowsError(try Datenbank(pfad: datei), "die kaputte Migration hätte scheitern müssen")
        Datenbank.migrationen[kaputt] = nil

        let db = try Datenbank(pfad: datei)
        XCTAssertEqual(try db.einstellung("schema_version"), String(Datenbank.schemaFassung))
        XCTAssertTrue(try db.zeilen("SELECT 1 FROM sqlite_master WHERE name='probe'").isEmpty)
        // Die Sicherung davor ist eine vollständige Datei ohne Nebendateien
        let sicherung = "\(datei).vor-v\(Datenbank.schemaFassung)"
        XCTAssertTrue(FileManager.default.fileExists(atPath: sicherung))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sicherung + "-wal"))
    }

    /// Eine Datenbank aus einer Fassung vor der aktuellen wird beim Öffnen
    /// migriert, auch wenn sie mehrere Fassungen zurückliegt. Die Gruppe an
    /// Posten, Topf und Buchung kam mit Fassung 5, der Schalter außerplanmäßig
    /// mit 6, die Aufstockungen mit 8. Weiter zurück als bis 4 lässt sich eine
    /// Datenbank aus dem heutigen Schema nicht nachbauen, die Kategorie am Topf
    /// aus Fassung 3 hängt an einem Fremdschlüssel und lässt sich nicht löschen.
    func testMigrationVonFassung4() throws {
        let alt = pfad("haushalt_fassung4_test.sqlite")
        do {
            let db = try Datenbank(pfad: alt)
            // Fassung 4 nachbauen, also zurücknehmen, was 5 bis 10 bringen.
            // Erst die Sichten, sie hängen an den Spalten.
            try db.ausfuehren("""
                DROP VIEW v_kategorie_monat;
                DROP VIEW v_topf_bewegungen;
                DROP TABLE topf_einlagen;
                ALTER TABLE buchungen DROP COLUMN ausserplanmaessig;
                ALTER TABLE buchungen DROP COLUMN gruppe;
                ALTER TABLE toepfe DROP COLUMN gruppe;
                ALTER TABLE regeln DROP COLUMN gruppe;
                UPDATE einstellungen SET wert='4' WHERE schluessel='schema_version';
                """)
        }
        let db = try Datenbank(pfad: alt)
        XCTAssertEqual(try db.einstellung("schema_version"), String(Datenbank.schemaFassung))
        // Was die Migrationen gebracht haben, ist wieder da und benutzbar
        let h = Kern(db: db, heute: Pruefung.tag("2026-09-20"))
        let topf = try h.topf("Probe", rate: 1000, kategorie: "Reisen", gruppe: "Urlaub")
        try h.topfAufstocken(topf, betrag: 500)
        try h.buchen(-2000, "Steuern", datum: "2026-09-20", gruppe: "Finanzen",
                     ausserplanmaessig: true)
        XCTAssertEqual(h.toepfe().first?.wirksameGruppe, "Urlaub")
        XCTAssertEqual(h.einlagen().first?.betragCent, 500)
        XCTAssertEqual(h.buchungen("2026-09").first?.gruppe, "Finanzen")
        XCTAssertEqual(try anzahl(db, "SELECT COUNT(*) AS c FROM v_kategorie_monat"), 1)
        XCTAssertEqual(try anzahl(db, "SELECT COUNT(*) AS c FROM v_topf_bewegungen"), 1)
    }

    /// Schließen räumt -wal und -shm weg, danach liegt nur die eine Datei da,
    /// und die Buchungen stehen darin. Vorher blieben beide nach dem Beenden
    /// liegen, weil nur deinit schloss und macOS das beim Beenden nicht ruft
    /// (2026-09-26). Ein Zugriff danach scheitert mit einem Fehler, nicht mit
    /// einem Absturz.
    func testSchliessenRaeumtDieNebendateienAuf() throws {
        let datei = pfad("haushalt_schliessen_test.sqlite")
        let db = try Datenbank(pfad: datei)
        try db.ausfuehren("PRAGMA journal_mode = WAL")
        let h = Kern(db: db, heute: Pruefung.tag("2026-09-20"))
        for i in 0..<10 { try h.buchen(-100 - i, "Lebensmittel", datum: "2026-09-20") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: datei + "-wal"))
        db.schliessen()
        XCTAssertFalse(FileManager.default.fileExists(atPath: datei + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: datei + "-shm"))
        XCTAssertThrowsError(try db.zeilen("SELECT 1"))
        XCTAssertEqual(try anzahl(try Datenbank(pfad: datei),
                                  "SELECT COUNT(*) AS c FROM buchungen"), 10)
    }

    /// Die Sicherung nimmt mit, was im WAL Modus noch in der Nebendatei steht.
    /// Eine Dateikopie ließ genau das weg, im Test damals alle dreißig gerade
    /// geschriebenen Buchungen, siehe CLAUDE.md, Entscheidungen. Die Kopie ist
    /// danach eine einzelne Datei im Journalmodus DELETE.
    func testSicherungNimmtDenWalInhaltMit() throws {
        let quelle = pfad("haushalt_sicherung_quelle.sqlite")
        let ziel = pfad("haushalt_sicherung_ziel.sqlite")
        let dateikopie = pfad("haushalt_sicherung_dateikopie.sqlite")
        let db = try Datenbank(pfad: quelle)
        try db.ausfuehren("PRAGMA journal_mode = WAL")
        let h = Kern(db: db, heute: Pruefung.tag("2026-09-20"))
        for i in 0..<30 { try h.buchen(-100 - i, "Lebensmittel", datum: "2026-09-20") }

        // Zum Vergleich, was eine Dateikopie bei offener Verbindung liefert
        try FileManager.default.copyItem(atPath: quelle, toPath: dateikopie)
        let falsch = try anzahl(try Datenbank(pfad: dateikopie),
                                "SELECT COUNT(*) AS c FROM buchungen")
        XCTAssertLessThan(falsch, 30, "die Dateikopie lässt den WAL Inhalt weg")

        try db.sicherungSchreiben(nach: ziel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ziel + ".teil"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ziel + "-wal"))
        let kopie = try Datenbank(pfad: ziel)
        XCTAssertEqual(try anzahl(kopie, "SELECT COUNT(*) AS c FROM buchungen"), 30)
        XCTAssertEqual(try kopie.zeilen("PRAGMA journal_mode").first?["journal_mode"]?.alsText,
                       "delete")
    }
}
