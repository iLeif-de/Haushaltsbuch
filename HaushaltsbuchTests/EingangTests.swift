import XCTest

/// Buchungen vom iPhone über den Ordner Eingang, siehe Eingang.swift.
final class EingangTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        if let pfad = Bundle(for: EingangTests.self).path(forResource: "schema", ofType: "sql") {
            setenv("HAUSHALT_SCHEMA", pfad, 1)
        }
    }

    private func ordner(_ name: String) throws -> URL {
        let ordner = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: ordner)
        try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: ordner) }
        return ordner
    }

    private func frisch() throws -> Kern {
        Kern(db: try Datenbank(pfad: ":memory:"), heute: Pruefung.tag("2026-09-27"))
    }

    private func ablegen(_ text: String, _ name: String, in ordner: URL) {
        FileManager.default.createFile(atPath: ordner.appendingPathComponent(name).path,
                                       contents: Data(text.utf8))
    }

    private func namen(_ ordner: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: ordner.path)) ?? []).sorted()
    }

    func testAusgabeUndEinnahme() throws {
        let h = try frisch()
        let eingang = try ordner("haushalt_eingang_gut")
        ablegen(#"{"art":"ausgabe","betrag":42.8,"kategorie":"lebensmittel","datum":"2026-09-26","notiz":"Wochenmarkt"}"#,
                "buchung-1.json", in: eingang)
        // Betrag als Text mit Komma, Datum als Zeitstempel, wie Kurzbefehle es schreibt
        ablegen(#"{"art":"einnahme","betrag":"1.234,50","kategorie":"Gehalt","datum":"2026-09-25T10:15:00+02:00","ausserplanmaessig":true}"#,
                "buchung-2.json", in: eingang)

        let ergebnis = Eingang.einlesen(h, ordner: eingang)
        XCTAssertEqual(ergebnis, Eingang.Ergebnis(uebernommen: 2))
        XCTAssertEqual(ergebnis.satz, "2 Buchungen vom iPhone übernommen.")

        let alle = h.alleBuchungen()
        let ausgabe = try XCTUnwrap(alle.first { $0.notiz == "Wochenmarkt" })
        XCTAssertEqual(ausgabe.betragCent, -4280)
        XCTAssertEqual(ausgabe.kategorie, "Lebensmittel")
        XCTAssertEqual(ausgabe.datum, "2026-09-26")
        let einnahme = try XCTUnwrap(alle.first { $0.betragCent == 123450 })
        XCTAssertEqual(einnahme.datum, "2026-09-25")
        XCTAssertTrue(einnahme.ausserplanmaessig)
        XCTAssertEqual(try h.db.zeilen("SELECT COUNT(*) AS n FROM buchungen WHERE quelle='import'")
            .first?["n"]?.alsGanz, 2)

        // Gebucht heißt verschoben, gelöscht wird nichts
        XCTAssertEqual(namen(eingang), [Eingang.uebernommenOrdner])
        XCTAssertEqual(namen(eingang.appendingPathComponent(Eingang.uebernommenOrdner)),
                       ["buchung-1.json", "buchung-2.json"])
    }

    /// Dieselbe Datei ein zweites Mal, etwa nach einem Absturz zwischen Buchen
    /// und Verschieben, wird nicht noch einmal gebucht. Eine Kopie behält ihre
    /// Änderungszeit, genau wie die liegen gebliebene Datei.
    func testNieZweimal() throws {
        let h = try frisch()
        let eingang = try ordner("haushalt_eingang_zweimal")
        let inhalt = #"{"betrag":10,"kategorie":"Lebensmittel","datum":"2026-09-26"}"#
        ablegen(inhalt, "buchung-a.json", in: eingang)
        XCTAssertEqual(Eingang.einlesen(h, ordner: eingang).uebernommen, 1)
        try FileManager.default.copyItem(
            at: eingang.appendingPathComponent(Eingang.uebernommenOrdner)
                .appendingPathComponent("buchung-a.json"),
            to: eingang.appendingPathComponent("buchung-a.json"))
        let zweites = Eingang.einlesen(h, ordner: eingang)
        XCTAssertEqual(zweites.uebernommen, 0)
        XCTAssertTrue(zweites.fehler.isEmpty)
        XCTAssertEqual(h.alleBuchungen().count, 1)
        XCTAssertEqual(namen(eingang.appendingPathComponent(Eingang.uebernommenOrdner)),
                       ["buchung-a 2.json", "buchung-a.json"])

        // Neu geschrieben, mit gleichem Namen und Inhalt, ist es ein zweiter
        // Kaffee und wird gebucht
        ablegen(inhalt, "buchung-a.json", in: eingang)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 5)],
            ofItemAtPath: eingang.appendingPathComponent("buchung-a.json").path)
        XCTAssertEqual(Eingang.einlesen(h, ordner: eingang).uebernommen, 1)
        XCTAssertEqual(h.alleBuchungen().count, 2)
    }

    /// Derselbe Name mit anderem Inhalt ist eine neue Buchung. Zuerst galt
    /// sie als schon gebucht, und die Buchung ging verloren (2026-09-27).
    func testGleicherNameAndererInhalt() throws {
        let h = try frisch()
        let eingang = try ordner("haushalt_eingang_gleicher_name")
        ablegen(#"{"text":"Tanken 37,45 €","datum":"2026-09-27"}"#, "Buchung-2026-09-27.json",
                in: eingang)
        XCTAssertEqual(Eingang.einlesen(h, ordner: eingang).uebernommen, 1)
        ablegen(#"{"text":"Lebensmittel 1,50 €","datum":"2026-09-27"}"#,
                "Buchung-2026-09-27.json", in: eingang)
        XCTAssertEqual(Eingang.einlesen(h, ordner: eingang).uebernommen, 1)
        XCTAssertEqual(Set(h.alleBuchungen().map(\.betragCent)), [-3745, -150])
    }

    func testFehlerLandenInFehler() throws {
        let h = try frisch()
        try h.topf("Urlaub", rate: 5000)
        let eingang = try ordner("haushalt_eingang_fehler")
        ablegen(#"{"betrag":10,"kategorie":"Gibtsnicht"}"#, "a.json", in: eingang)
        ablegen(#"{"betrag":0,"kategorie":"Lebensmittel"}"#, "b.json", in: eingang)
        ablegen(#"{"art":"einnahme","betrag":5,"kategorie":"Gehalt","topf":"Urlaub"}"#,
                "c.json", in: eingang)
        ablegen("kein json", "d.json", in: eingang)
        // Älter als zehn Sekunden, sonst gälte sie als noch im Schreiben
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60)],
            ofItemAtPath: eingang.appendingPathComponent("d.json").path)
        ablegen(#"{"betrag":5,"kategorie":"Lebensmittel","datum":"27.09.2026"}"#, "e.json",
                in: eingang)
        // Aus einem Topf, über seinen Namen
        ablegen(#"{"betrag":240,"kategorie":"Reisen","topf":"urlaub","datum":"2026-09-20"}"#,
                "f.json", in: eingang)

        let ergebnis = Eingang.einlesen(h, ordner: eingang)
        XCTAssertEqual(ergebnis.uebernommen, 1)
        XCTAssertEqual(ergebnis.fehler.count, 5)
        XCTAssertEqual(ergebnis.fehler.first, "a.json, Die Kategorie Gibtsnicht gibt es nicht.")
        XCTAssertTrue(ergebnis.satz?.hasPrefix("Eine Buchung vom iPhone übernommen. 5 Dateien") ?? false,
                      ergebnis.satz ?? "")
        XCTAssertEqual(namen(eingang.appendingPathComponent(Eingang.fehlerOrdner)),
                       ["a.json", "b.json", "c.json", "d.json", "e.json"])
        XCTAssertNotNil(h.alleBuchungen().first { $0.topfId != nil && $0.betragCent == -24000 })
    }

    /// Eine frische, unlesbare Datei schreibt iCloud vielleicht noch. Sie
    /// bleibt eine Runde liegen, statt gleich unter Fehler zu landen.
    func testHalbGeschriebenWartet() throws {
        let h = try frisch()
        let eingang = try ordner("haushalt_eingang_halb")
        ablegen(#"{"betrag":10,"kateg"#, "a.json", in: eingang)
        XCTAssertEqual(Eingang.einlesen(h, ordner: eingang), Eingang.Ergebnis(wartend: 1))
        XCTAssertEqual(namen(eingang), ["a.json"])
    }

    /// Was iCloud noch nicht geladen hat, bleibt liegen und wird angefordert.
    func testPlatzhalterWarten() throws {
        let h = try frisch()
        let eingang = try ordner("haushalt_eingang_platzhalter")
        ablegen("", ".buchung-x.json.icloud", in: eingang)
        let ergebnis = Eingang.einlesen(h, ordner: eingang)
        XCTAssertEqual(ergebnis, Eingang.Ergebnis(wartend: 1))
        XCTAssertNil(ergebnis.satz)
        XCTAssertEqual(namen(eingang), [".buchung-x.json.icloud"])
    }

    /// Ohne Datum gilt der Tag, an dem die Datei entstand, nicht der, an dem
    /// der Mac sie liest.
    func testOhneDatumGiltDerTagDerDatei() throws {
        let h = try frisch()
        let eingang = try ordner("haushalt_eingang_ohne_datum")
        ablegen(#"{"betrag":3,"kategorie":"Lebensmittel"}"#, "a.json", in: eingang)
        try FileManager.default.setAttributes(
            [.creationDate: Pruefung.tag("2026-09-21")],
            ofItemAtPath: eingang.appendingPathComponent("a.json").path)
        _ = Eingang.einlesen(h, ordner: eingang)
        XCTAssertEqual(h.alleBuchungen().first?.datum, "2026-09-21")
    }

    func testBetraege() {
        XCTAssertEqual(Eingang.betrag(42.8), 4280)
        XCTAssertEqual(Eingang.betrag("42,80"), 4280)
        XCTAssertEqual(Eingang.betrag("42.80"), 4280)
        XCTAssertEqual(Eingang.betrag("1.234,50 €"), 123450)
        XCTAssertEqual(Eingang.betrag(12), 1200)
        XCTAssertEqual(Eingang.betrag("3.200"), 320000)
        XCTAssertNil(Eingang.betrag("zwölf"))
        XCTAssertNil(Eingang.betrag(true))
        // Genau ein Euro ist keine Wahrheit, JSON true schon
        XCTAssertEqual(Eingang.betrag(1), 100)
        XCTAssertEqual(Eingang.betrag(NSDecimalNumber(decimal: 1)), 100)
        XCTAssertNil(Eingang.betrag(NSNumber(value: true)))
        // So kommt ein true aus einer echten Datei an
        let json = try? JSONSerialization.jsonObject(with: Data(#"{"a":true,"b":1}"#.utf8))
            as? [String: Any]
        XCTAssertNil(Eingang.betrag(json?["a"]))
        XCTAssertEqual(Eingang.betrag(json?["b"]), 100)
        XCTAssertNil(Eingang.betrag(nil))
    }

    /// Ein gesprochener Satz, wie Siri ihn über den Kurzbefehl schickt.
    func testSaetze() {
        let namen = ["Tanken", "Lebensmittel", "Haushalt", "Arzt und Apotheke", "Arzt", "Gehalt"]
        func lies(_ satz: String) -> String {
            let g = Eingang.satzLesen(satz, kategorien: namen)
            return "\(g.kategorie ?? "-") \(g.cent.map(String.init) ?? "-")\(g.einnahme ? " ein" : "")"
        }
        XCTAssertEqual(lies("Tanken 50 Euro"), "Tanken 5000")
        XCTAssertEqual(lies("mache eine Buchung mit tanken und 50€"), "Tanken 5000")
        XCTAssertEqual(lies("12,40 € für Lebensmittel"), "Lebensmittel 1240")
        XCTAssertEqual(lies("Lebensmittel 12 Euro 40"), "Lebensmittel 1240")
        XCTAssertEqual(lies("Arzt und Apotheke 8,95"), "Arzt und Apotheke 895")
        XCTAssertEqual(lies("Einnahme Gehalt 3.200 Euro"), "Gehalt 320000 ein")
        // Nur ganze Wörter, Haushaltsbuch ist nicht Haushalt
        XCTAssertEqual(lies("im Haushaltsbuch 20 Euro"), "- 2000")
        XCTAssertEqual(lies("Tanken"), "Tanken -")
    }

    /// Siri schreibt Zahlen bis zwölf aus, Lebensmittel eins euro statt 1
    /// (2026-10-05). Ab dreizehn kommen Ziffern, die Wörter gehen trotzdem.
    func testZahlwoerter() {
        let namen = ["Tanken", "Lebensmittel", "Gehalt"]
        func lies(_ satz: String) -> String {
            let g = Eingang.satzLesen(satz, kategorien: namen)
            return "\(g.kategorie ?? "-") \(g.cent.map(String.init) ?? "-")\(g.einnahme ? " ein" : "")"
        }
        XCTAssertEqual(lies("Lebensmittel eins euro"), "Lebensmittel 100")
        XCTAssertEqual(lies("Lebensmittel zwei Euro"), "Lebensmittel 200")
        XCTAssertEqual(lies("Tanken zwölf Euro"), "Tanken 1200")
        XCTAssertEqual(lies("Tanken zwölf Euro vierzig"), "Tanken 1240")
        XCTAssertEqual(lies("Tanken zwölf Euro und vierzig Cent"), "Tanken 1240")
        XCTAssertEqual(lies("Tanken zwölf Euro 40"), "Tanken 1240")
        XCTAssertEqual(lies("Lebensmittel fünfzig Cent"), "Lebensmittel 50")
        XCTAssertEqual(lies("Lebensmittel 50 Cent"), "Lebensmittel 50")
        XCTAssertEqual(lies("Tanken einundzwanzig Euro"), "Tanken 2100")
        XCTAssertEqual(lies("Tanken dreihundertfünfzig Euro"), "Tanken 35000")
        XCTAssertEqual(lies("Tanken hundert Euro"), "Tanken 10000")
        XCTAssertEqual(lies("Tanken tausendzweihundert Euro"), "Tanken 120000")
        XCTAssertEqual(lies("Einnahme Gehalt dreitausendzweihundert Euro"), "Gehalt 320000 ein")
        XCTAssertEqual(lies("Tanken einen Euro"), "Tanken 100")
        XCTAssertEqual(lies("Tanken ein Euro"), "Tanken 100")
        // Ein ist immer eine Zahl, auch ohne Euro dahinter
        XCTAssertEqual(lies("Lebensmittel ein"), "Lebensmittel 100")
        XCTAssertEqual(lies("Lebensmittel ein Euro fünfzig"), "Lebensmittel 150")
        // Die Zahl vor Euro gewinnt gegen ein Ein weiter vorn
        XCTAssertEqual(lies("ein Wocheneinkauf Lebensmittel fünfzig Euro"), "Lebensmittel 5000")
        // Der Artikel bleibt der Artikel
        XCTAssertEqual(lies("mache eine Buchung mit Tanken und fünfzig Euro"), "Tanken 5000")
        XCTAssertEqual(lies("eine Buchung Tanken"), "Tanken -")
        // Wörter, die nur eine Zahl enthalten
        XCTAssertEqual(Eingang.zahlwort("Jahrhundert"), nil)
        XCTAssertEqual(Eingang.zahlwort("Hund"), nil)
        XCTAssertEqual(Eingang.zahlwort("Einnahme"), nil)
        XCTAssertEqual(Eingang.zahlwoerterZuZiffern("Achtung, acht Euro"), "Achtung, 8 Euro")
        XCTAssertEqual(Eingang.zahlwoerterZuZiffern("ein Brot"), "1 Brot")
        XCTAssertEqual(Eingang.zahlwoerterZuZiffern("eine Buchung"), "eine Buchung")
    }

    func testSatzImEingang() throws {
        let h = try frisch()
        let eingang = try ordner("haushalt_eingang_satz")
        ablegen(#"{"text":"Tanken 50 Euro","datum":"2026-09-26"}"#, "a.json", in: eingang)
        ablegen(#"{"text":"irgendwas 50 Euro","datum":"2026-09-26"}"#, "b.json", in: eingang)
        // Bis zum Buchen und nicht nur bis zum Lesen des Satzes. Genau ein
        // Euro scheiterte erst dort (2026-10-05)
        ablegen(#"{"text":"Eins Euro Lebensmittel","datum":"2026-09-26"}"#, "c.json", in: eingang)
        ablegen(#"{"text":"Lebensmittel ein Euro","datum":"2026-09-26"}"#, "d.json", in: eingang)
        ablegen(#"{"betrag":1,"kategorie":"Lebensmittel","datum":"2026-09-26"}"#, "e.json",
                in: eingang)
        let ergebnis = Eingang.einlesen(h, ordner: eingang)
        XCTAssertEqual(ergebnis.uebernommen, 4)
        XCTAssertEqual(h.alleBuchungen().filter { $0.betragCent == -100 }.count, 3)
        XCTAssertEqual(ergebnis.fehler, ["b.json, Im Satz irgendwas 50 Euro steht keine Kategorie."])
        let buchung = try XCTUnwrap(h.alleBuchungen().first)
        XCTAssertEqual(buchung.kategorie, "Tanken")
        XCTAssertEqual(buchung.betragCent, -5000)
    }

    /// kategorien.json und stand.json für den Kurzbefehl, nur bei Änderung.
    func testAuskunftFuerDasIphone() throws {
        let h = try frisch()
        try h.startsaldoSetzen(betragCent: 100000, datum: "2026-09-01")
        let ordner = try ordner("haushalt_auskunft")
        let db = ordner.appendingPathComponent("haushaltsbuch.sqlite").path
        XCTAssertTrue(Eingang.auskunft(h, neben: db))
        XCTAssertFalse(Eingang.auskunft(h, neben: db), "unverändert wird nicht neu geschrieben")

        let liste = try JSONSerialization.jsonObject(
            with: Data(contentsOf: ordner.appendingPathComponent("kategorien.json")))
            as? [String: Any]
        let kategorien = try XCTUnwrap(liste?["kategorien"] as? [String])
        XCTAssertTrue(kategorien.contains("Lebensmittel"))
        let favoriten = try XCTUnwrap(liste?["favoriten"] as? [String])
        XCTAssertLessThanOrEqual(favoriten.count, 8)

        let text = try String(contentsOf: ordner.appendingPathComponent("stand.json"),
                              encoding: .utf8)
        XCTAssertTrue(text.contains(#""kontostand" : 1000"#), text)
        XCTAssertTrue(text.contains(#""monat" : "2026-09""#), text)

        try h.buchen(-1234, "Lebensmittel", datum: "2026-09-27")
        XCTAssertTrue(Eingang.auskunft(h, neben: db), "nach einer Buchung neu")
    }
}
