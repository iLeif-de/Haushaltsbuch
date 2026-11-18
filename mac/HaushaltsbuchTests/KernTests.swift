import XCTest

/// Der Nachbau von test_kern.py, Abschnitt für Abschnitt und mit denselben
/// Zahlen. Solange es das Programm in Python gibt, ist dessen Kern das Orakel,
/// danach sind es diese Prüfungen (2026-09-26).
///
/// Die Kommentare über den Abschnitten sind die aus test_kern.py, sie sagen,
/// warum etwas so sein muss. Ein Abschnitt, der auf dem vorigen aufbaut, steht
/// mit ihm in derselben Prüfung, wie dort alles auf `h` aufbaut.
///
/// Was es in Swift noch nicht gibt, fehlt hier noch, die Migrationen samt
/// Migration 9 und dem Abbruch einer Migration. Sie kommen mit Schritt 2 des
/// Fahrplans, siehe CLAUDE.md.
final class KernTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        // Das Schema liegt im Prüfbündel. Datenbank sucht es im Hauptbündel,
        // das hier xctest selbst ist, und fällt dann auf HAUSHALT_SCHEMA zurück.
        if let pfad = Bundle(for: KernTests.self).path(forResource: "schema", ofType: "sql") {
            setenv("HAUSHALT_SCHEMA", pfad, 1)
        }
    }

    /// Eine frische Datenbank im Speicher, wie `verbinden()` in Python.
    private func frisch(_ heute: String) throws -> Kern {
        Kern(db: try Datenbank(pfad: ":memory:"), heute: Pruefung.tag(heute))
    }

    // MARK: - Das große Szenario auf h

    func testHauptszenario() throws {
        let h = try frisch("2026-09-10")

        // Einrichtung
        try h.posten("Gehalt", 320000, 1, "2026-01", "Gehalt")
        try h.posten("Miete", -95000, 1, "2026-01", "Miete")
        try h.posten("Strom", -8500, 15, "2026-01", "Energie")
        try h.posten("Internet", -3999, 3, "2026-01", "Kommunikation")
        try h.posten("Kfz Versicherung", -48000, 5, "2026-05", "Versicherungen",
                     intervall: 12, schonVorhanden: 16000)
        try h.startsaldoSetzen(betragCent: 412000, datum: nil)

        // Geschichte für das Übliche, sechs Monate Lebensmittel und Gastronomie
        for (i, m) in ["03", "04", "05", "06", "07", "08"].enumerated() {
            try h.buchen(-42000 - i * 500, "Lebensmittel", datum: "2026-\(m)-20")
            try h.buchen(-18000, "Gastronomie", datum: "2026-\(m)-22")
            try h.fortschreiben("2026-\(m)")
            for b in h.buchungen("2026-\(m)") where b.status == "geplant" {
                try h.bestaetigen(b.id)
            }
        }

        // September, laufender Monat
        try h.buchen(-4820, "Lebensmittel", notiz: "Wochenendeinkauf")
        try h.buchen(-3600, "Gastronomie", datum: "2026-09-07")
        try h.buchen(-27400, "Gastronomie", datum: "2026-09-05", notiz: "Geburtstag")
        try h.buchen(-6000, "Tanken", datum: "2026-09-02")
        _ = try h.bild("2026-09")

        // Gehaltserhöhung ab Oktober, Vergangenheit bleibt
        let gehalt = try XCTUnwrap(h.regeln(nurGueltige: true).first { $0.name == "Gehalt" })
        try h.regelAendern(gehalt.id, neuerBetrag: 335000, abMonat: "2026-10")
        try h.fortschreiben("2026-10")
        let sep = try XCTUnwrap(h.buchungen("2026-09").first { $0.posten == "Gehalt" })
        let okt = try XCTUnwrap(h.buchungen("2026-10").first { $0.posten == "Gehalt" })
        XCTAssertEqual(sep.betragCent, 320000)
        XCTAssertEqual(okt.betragCent, 335000)

        // Fortschreibung ist idempotent
        let vorher = h.buchungen("2026-10").count
        try h.fortschreiben("2026-10")
        XCTAssertEqual(h.buchungen("2026-10").count, vorher)

        // Nachzahlung Strom
        let strom = try XCTUnwrap(h.regeln(nurGueltige: true).first { $0.name == "Strom" })
        try h.korrektur(strom.id, betrag: -12000, datum: "2026-08-30")

        // Kfz im Mai 2027 fällig, Topf muss dann voll sein
        try h.fortschreiben("2027-05")
        let mai = h.buchungen("2027-05").filter { $0.posten == "Kfz Versicherung" }
        XCTAssertFalse(mai.isEmpty)
        XCTAssertNotNil(mai.first?.topfId)

        // Warnung auslösen
        try h.buchen(-90000, "Kultur", datum: "2026-09-09", notiz: "Konzertkarten")
        let u = try h.bild("2026-09")
        // Wie in Python nennt die Warnung den größten Ausreißer, Gastronomie.
        // Zwischendurch nannte 2.0 keine Kategorie (verworfen 2026-09-26).
        XCTAssertTrue(u.warnung?.contains("des Budgets ausgegeben") ?? false,
                      u.warnung ?? "keine Warnung")
        XCTAssertTrue(u.warnung?.contains("Gastronomie") ?? false, u.warnung ?? "keine Warnung")

        // Ohne Auffälligkeit meldet die Deckungsprüfung nichts, Kontostand und
        // Rücklagen stehen für sich in der Übersicht, siehe ruecklagen_gesamt
        XCTAssertNil(u.deckung)

        // Sinkt der Kontostand unter die Rücklagen, warnt sie
        try h.startsaldoSetzen(betragCent: 1000, datum: nil)
        XCTAssertTrue(try h.bild("2026-09").deckung?.contains("fehlen") ?? false)
        try h.startsaldoSetzen(betragCent: 412000, datum: nil)

        // Topf pausieren und auflösen
        let urlaub = try h.topf("Urlaub", rate: 10000)
        let ratenMit = h.topfraten()
        try h.topfPausieren(urlaub, pausiert: true)
        XCTAssertEqual(h.topfraten(), ratenMit - 10000)
        try h.topfPausieren(urlaub, pausiert: false)
        XCTAssertEqual(h.topfraten(), ratenMit)
        try h.topfAufloesen(urlaub)
        XCTAssertFalse(h.toepfe().contains { $0.name == "Urlaub" })

        // Kategorien ändern und löschen mit Ersatz, auch an Regeln
        let zinsen = try h.kategorieAnlegen(name: "Zinsen", gruppe: "Einnahmen", icon: "SAVINGS")
        try h.kategorieAendern(zinsen, neuerName: "Kapital", icon: "TRENDING_UP", favorit: true)
        let kapital = try XCTUnwrap(h.kategorien().first { $0.name == "Kapital" })
        XCTAssertEqual(kapital.icon, "TRENDING_UP")
        XCTAssertTrue(kapital.favorit)
        let testregel = try h.posten("Testposten", -1000, 1, "2026-09", "Kapital")
        try h.buchen(500, "Kapital", datum: "2026-09-11")
        try h.kategorieLoeschen(kapital.id, ersatzId: try h.kategorieId("Sonstiges"))
        XCTAssertFalse(h.kategorien().contains { $0.name == "Kapital" })
        let ersatz = try h.db.zeilen("""
            SELECT k.name FROM regel_kategorien rk JOIN kategorien k ON k.id=rk.kategorie_id
            WHERE rk.regel_id=?
            """, [.zahl(testregel)]).first?["name"]?.alsText
        XCTAssertEqual(ersatz, "Sonstiges")
        try h.regelBeenden(testregel, letzterMonat: "2026-09")

        // Favoriten in fester Reihenfolge, Rest nach Nutzung, Ausblenden über aktiv
        try h.kategorieAendern(try h.kategorieId("Lebensmittel"), favorit: true)
        try h.kategorieAendern(try h.kategorieId("Tanken"), favorit: true)
        try h.kategorienOrdnen(["Tanken", "Lebensmittel"])
        XCTAssertEqual(Array(h.kategorien().map(\.name).prefix(2)), ["Tanken", "Lebensmittel"])
        try h.kategorienOrdnen(["Lebensmittel", "Tanken"])
        XCTAssertEqual(Array(h.kategorien().map(\.name).prefix(2)), ["Lebensmittel", "Tanken"])
        let werkstatt = try h.kategorieId("Werkstatt")
        try h.kategorieAendern(werkstatt, aktiv: false)
        XCTAssertFalse(h.kategorien().contains { $0.name == "Werkstatt" })
        XCTAssertTrue(h.kategorien(nurAktive: false).contains { $0.name == "Werkstatt" })
        try h.kategorieAendern(werkstatt, aktiv: true)
        try h.kategorieAendern(try h.kategorieId("Lebensmittel"), favorit: false)
        try h.kategorieAendern(try h.kategorieId("Tanken"), favorit: false)

        // Eigener Topf ohne Ziel, Aufstocken für Überschuss, und Abbuchen wie bei jedem Topf
        let frei = try h.topf("Freies Vermögen", rate: 0, schonVorhanden: 200000)
        XCTAssertEqual(h.topfStand(frei), 200000)
        try h.topfAufstocken(frei, betrag: 30000)
        XCTAssertEqual(h.topfStand(frei), 230000)
        // Die Aufstockung wirkt ab ihrem Monat, frühere bleiben unberührt
        XCTAssertEqual(h.topfStand(frei, "2026-08"), 200000)
        let waschmaschine = try h.buchen(-45000, "Haushalt", datum: "2026-09-12", topfId: frei)
        XCTAssertEqual(h.topfStand(frei), 185000)
        try h.buchungLoeschen(waschmaschine)
        try h.topfAufloesen(frei)

        // Aufstocken bei Topf mit Termin. Der Stand steigt um genau den Betrag, die
        // Rate dieses Monats zählt nicht doppelt, die folgenden Raten sinken dafür.
        let termin = try h.topf("Aufstocken mit Termin", ziel: 120000, zielMonat: "2027-09")
        let standVorher = h.topfStand(termin)
        let rateVorher = try XCTUnwrap(h.toepfe().first { $0.id == termin }).rateCent
        try h.topfAufstocken(termin, betrag: 50000)
        XCTAssertEqual(h.topfStand(termin), standVorher + 50000)
        XCTAssertLessThan(try XCTUnwrap(h.toepfe("2026-10").first { $0.id == termin }).rateCent,
                          rateVorher)
        // Zum Termin steht das Ziel trotzdem, die Aufstockung hat es nur billiger gemacht
        XCTAssertEqual(h.topfStand(termin, "2027-09"), 120000)
        // Die Rate des laufenden Monats bleibt, sie steckt im Budget dieses Monats
        // schon drin. Die Liste nennt deshalb zusätzlich die des Folgemonats.
        let t = try XCTUnwrap(h.toepfe().first { $0.id == termin })
        XCTAssertEqual(t.rateCent, rateVorher)
        XCTAssertLessThan(t.naechsteRateCent, rateVorher)

        // Die Aufstockung steht in der Liste des Monats und lässt sich zurücknehmen
        let e = h.einlagen().filter { $0.topfId == termin }
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e.first?.betragCent, 50000)
        XCTAssertEqual(e.first?.topf, "Aufstocken mit Termin")
        XCTAssertTrue(h.einlagen("2026-08").isEmpty)
        try h.topfEinlageLoeschen(try XCTUnwrap(e.first).id)
        XCTAssertEqual(h.topfStand(termin), standVorher)
        XCTAssertEqual(try XCTUnwrap(h.toepfe().first { $0.id == termin }).naechsteRateCent,
                       rateVorher)
        XCTAssertTrue(h.einlagen().isEmpty)
        try h.topfAufloesen(termin)

        // Ein voller Topf nimmt nichts mehr an, statt das Geld stillschweigend zu
        // schlucken. Früher schrieb Aufstocken den Startstand um, der Stand wird aber
        // aufs Ziel gedeckelt, und der Betrag war spurlos weg.
        let voll = try h.topf("Voller Topf", rate: 0, ziel: 50000, schonVorhanden: 50000)
        XCTAssertEqual(h.topfStand(voll), 50000)
        XCTAssertThrowsError(try h.topfAufstocken(voll, betrag: 10000),
                             "Aufstocken über das Ziel hinaus muss abgelehnt werden")
        XCTAssertEqual(h.topfStand(voll), 50000)
        // Was noch fehlt, geht dagegen genau hinein
        try h.topfAendern(voll, name: "Voller Topf", kategorieId: nil, gruppe: nil,
                          rate: 0, ziel: 70000)
        try h.topfAufstocken(voll, betrag: 20000)
        XCTAssertEqual(h.topfStand(voll), 70000)
        try h.topfAufloesen(voll)

        // Eigener Topf mit Kategorie, rein zur Einordnung, ohne Buchungen einzuschränken
        let urlaubstopf = try h.topf("Urlaub", rate: 10000, ziel: 120000, kategorie: "Reisen")
        XCTAssertEqual(h.toepfe().first { $0.id == urlaubstopf }?.kategorie, "Reisen")
        try h.topfAufloesen(urlaubstopf)

        // Der automatische Topf eines Postens übernimmt dessen erste Kategorie
        let kfzKat = try h.posten("Kfz Test", -48000, 5, "2026-05", "Versicherungen", intervall: 12)
        XCTAssertEqual(h.toepfe().first { $0.zeile.regelId == kfzKat }?.kategorie,
                       "Versicherungen")
        try h.regelLoeschen(kfzKat)

        // Topf einer Buchung setzen und wieder entfernen
        let kurztrip = try h.topf("Kurztrip", rate: 5000, ziel: 60000)
        let hobby = try h.buchen(-3000, "Hobbys", datum: "2026-09-11")
        try h.buchungAendern(hobby, topf: .setzen(kurztrip))
        XCTAssertEqual(try h.topfVon(hobby), kurztrip)
        try h.buchungAendern(hobby, topf: .setzen(nil))
        XCTAssertNil(try h.topfVon(hobby))
        try h.buchungLoeschen(hobby)
        try h.topfAufloesen(kurztrip)

        // Auswertung nach Gruppen fasst Kategorien einer Gruppe zusammen,
        // Tanken und Werkstatt liegen laut schema.sql beide unter Auto
        try h.buchen(-5000, "Tanken", datum: "2026-09-10")
        try h.buchen(-3000, "Werkstatt", datum: "2026-09-10")
        let auto = try XCTUnwrap(h.nachKategorie("2026-09", nachGruppe: true)
            .first { $0.kategorie == "Auto" })
        XCTAssertGreaterThanOrEqual(auto.betrag, 8000)
        let einzeln = h.nachKategorie("2026-09", nachGruppe: false).map(\.kategorie)
        XCTAssertTrue(einzeln.contains("Tanken") && einzeln.contains("Werkstatt"))
        XCTAssertFalse(einzeln.contains("Auto"))

        // Abweichung vom Üblichen unabhängig von der Monatswarnung, auf halbem Weg
        // durch den Monat sollte etwa die Hälfte des Üblichen erwartet sein
        let anteil = h.monatAnteil("2026-09")
        let lebensmittel = try XCTUnwrap(h.nachKategorie("2026-09", nachGruppe: false)
            .first { $0.kategorie == "Lebensmittel" })
        let ueblich = try XCTUnwrap(lebensmittel.ueblich)
        let erwartet = try XCTUnwrap(lebensmittel.erwartet)
        XCTAssertEqual(erwartet, Pruefung.rundePython(Double(ueblich) * anteil))
        let erwarteteAbweichung = Double(lebensmittel.betrag - erwartet) / Double(erwartet)
        XCTAssertEqual(try XCTUnwrap(lebensmittel.abweichungAnteil), erwarteteAbweichung,
                       accuracy: 0.001)
        // ein Monat ohne Geschichte liefert kein Übliches und keine Abweichung
        try h.kategorieAnlegen(name: "Neuland", gruppe: nil, icon: nil)
        try h.buchen(-1000, "Neuland", datum: "2026-09-05")
        let neuland = try XCTUnwrap(h.nachKategorie("2026-09", nachGruppe: false)
            .first { $0.kategorie == "Neuland" })
        XCTAssertNil(neuland.ueblich)
        XCTAssertNil(neuland.erwartet)
        XCTAssertNil(neuland.abweichungAnteil)

        // Einen Posten löschen heißt regel_beenden zum Vormonat, kein zukünftiger
        // Abschlag entsteht, der geplante dieses Monats verschwindet, Vergangenes bleibt
        let zeitschrift = try h.posten("Zeitschrift", -1200, 10, "2026-06", "Medien")
        try h.fortschreiben("2026-09")
        for b in h.buchungen("2026-09") where b.posten == "Zeitschrift" && b.status == "geplant" {
            try h.bestaetigen(b.id)
        }
        XCTAssertEqual(h.buchungen("2026-09").first { $0.posten == "Zeitschrift" }?.status,
                       "gebucht")
        try h.regelBeenden(zeitschrift, letzterMonat: "2026-08")
        XCTAssertFalse(h.regeln(nurGueltige: true).contains { $0.name == "Zeitschrift" })
        try h.fortschreiben("2026-10")
        XCTAssertFalse(h.buchungen("2026-10").contains { $0.posten == "Zeitschrift" })
        XCTAssertEqual(h.buchungen("2026-09").first { $0.posten == "Zeitschrift" }?.status,
                       "gebucht")

        // Ein Posten, der erst diesen Monat gilt, hat keinen gültigen Vormonat zum
        // Beenden, regel_beenden dorthin muss also fehlschlagen, regel_loeschen greift
        let testabo = try h.posten("Testabo", -999, 10, "2026-09", "Sonstiges")
        XCTAssertThrowsError(try h.regelBeenden(testabo, letzterMonat: "2026-08"),
                             "hätte an der CHECK Bedingung scheitern müssen")
        try h.regelLoeschen(testabo)
        XCTAssertFalse(h.regeln(nurGueltige: true).contains { $0.name == "Testabo" })
        XCTAssertTrue(try h.db.zeilen("SELECT 1 FROM buchungen WHERE regel_id=?",
                                      [.zahl(testabo)]).isEmpty)

        // Rückwirkende Änderung eines Postens passt gebuchte Abschläge an, ohne Duplikate
        let miete = try XCTUnwrap(h.regeln(nurGueltige: true).first { $0.name == "Miete" })
        for b in h.buchungen("2026-09") where b.posten == "Miete" && b.status == "geplant" {
            try h.bestaetigen(b.id)
        }
        try h.regelAendern(miete.id, neuerBetrag: -99000, abMonat: "2026-08")
        try h.fortschreiben("2026-09")
        XCTAssertEqual(h.mieten(h, "2026-09"), [-99000])
        XCTAssertEqual(h.mieten(h, "2026-08"), [-99000])
        XCTAssertEqual(h.mieten(h, "2026-07").first, -95000)
        // gleich noch einmal ändern, die Kette bleibt sauber
        let miete2 = try XCTUnwrap(h.regeln(nurGueltige: true).first { $0.name == "Miete" })
        try h.regelAendern(miete2.id, neuerBetrag: -97000, abMonat: "2026-09")
        try h.fortschreiben("2026-09")
        XCTAssertEqual(h.mieten(h, "2026-09"), [-97000])
        XCTAssertEqual(h.mieten(h, "2026-08"), [-99000])

        // Vorbelegte Favoriten beim ersten Start, nur einmal
        try h.favoritenVorbelegen()
        XCTAssertEqual(h.kategorien().filter(\.favorit).map(\.name),
                       ["Lebensmittel", "Haushalt", "Gastronomie", "Tanken",
                        "Fahrkarten", "Kleidung", "Arzt und Apotheke", "Sonstiges"])
        try h.kategorieAendern(try h.kategorieId("Sonstiges"), favorit: false)
        try h.favoritenVorbelegen()
        XCTAssertEqual(h.kategorien().filter(\.favorit).count, 7)

        // Export liefert alle Buchungen, älteste zuerst, oder nur einen Zeitraum
        let alle = h.alleBuchungen()
        XCTAssertGreaterThanOrEqual(alle.count, h.buchungen("2026-09").count)
        XCTAssertTrue(zip(alle, alle.dropFirst()).allSatisfy { $0.datum <= $1.datum })
        let august = h.alleBuchungen(von: "2026-08-01", bis: "2026-08-31")
        XCTAssertFalse(august.isEmpty)
        XCTAssertTrue(august.allSatisfy { $0.datum.hasPrefix("2026-08") })
        XCTAssertLessThan(august.count, alle.count)
    }

    // MARK: - Startsaldo

    /// Startsaldo rückwirkend setzen, das Datum der Eingabe darf keine Rolle
    /// spielen, und er bucht nie eine Korrektur, die das Monatsbudget
    /// verfälschen würde.
    func testStartsaldo() throws {
        let h2 = try frisch("2026-09-13")
        try h2.posten("Gehalt", 300000, 1, "2026-09", "Gehalt")
        try h2.fortschreiben("2026-09")
        for b in h2.buchungen("2026-09") { try h2.bestaetigen(b.id) }
        // Am 13. eingerichtet, aber der Kontostand galt schon am 31.8., vor dem Gehalt
        try h2.startsaldoSetzen(betragCent: 500000, datum: "2026-08-31")
        XCTAssertEqual(h2.einstellung("startsaldo_datum"), "2026-08-31")
        XCTAssertEqual(h2.kontostand(bis: "2026-08-31"), 500000)
        XCTAssertEqual(h2.kontostand(), 800000)  // Startsaldo plus das schon gebuchte Gehalt
        XCTAssertEqual(try h2.bild("2026-09").verfuegbarCent, 300000)  // unberührt vom Startsaldo
        // Eine spätere Korrektur ohne Datum ändert nur den Betrag, das Datum bleibt
        try h2.startsaldoSetzen(betragCent: 750000, datum: nil)
        XCTAssertEqual(h2.einstellung("startsaldo_datum"), "2026-08-31")
        XCTAssertEqual(h2.kontostand(), 1050000)
        XCTAssertFalse(h2.alleBuchungen().contains { $0.art == "korrektur" })
    }

    // MARK: - Warnung

    /// Orange, wenn das Budget schneller weg ist als der Monat, mit einem
    /// Spielraum, der zum Monatsende hin schrumpft (2026-09-26). Mit dem
    /// festen Spielraum aus 1.2 kam ab etwa dem 25. nur noch Rot.
    func testWarnungGegenMonatsende() throws {
        // Einnahmen 1.000 Euro, sonst nichts, das Budget ist also 1.000 Euro
        func szenario(_ ausgabe: Int, heute: String) throws -> Monatsbild {
            let h = try frisch(heute)
            try h.posten("Gehalt", 100000, 1, "2026-09", "Gehalt")
            try h.buchen(-ausgabe, "Lebensmittel", datum: "2026-09-01")
            return try h.bild("2026-09")
        }
        XCTAssertEqual(Kern.warnSchwelle(0), 0.15, accuracy: 1e-9)
        XCTAssertEqual(Kern.warnSchwelle(0.5), 0.575, accuracy: 1e-9)
        XCTAssertEqual(Kern.warnSchwelle(1), 1, accuracy: 1e-9)
        // Am 26. September sind 26 von 30 Tagen vorbei, die Schwelle liegt
        // bei 88,7 Prozent. 900 Euro warnen orange, 880 noch nicht.
        let knapp = try szenario(90000, heute: "2026-09-26")
        XCTAssertEqual(knapp.warnung, "90% des Budgets ausgegeben, aber erst 87% des Monats vorbei.")
        XCTAssertGreaterThan(knapp.verfuegbarCent, 0)
        XCTAssertNil(try szenario(88000, heute: "2026-09-26").warnung)
        // Mitte des Monats ab 57,5 Prozent
        XCTAssertNotNil(try szenario(58000, heute: "2026-09-15").warnung)
        XCTAssertNil(try szenario(57000, heute: "2026-09-15").warnung)
        // Überzogen ist rot, auch am letzten Tag
        XCTAssertEqual(try szenario(101000, heute: "2026-09-30").warnung,
                       "Es fehlen 10,00 €, der Monat ist überzogen.")
        XCTAssertNil(try szenario(99000, heute: "2026-09-30").warnung)
    }

    /// Der Ausreißer steht nur an einer Warnung, selbst löst er keine aus, wie
    /// in Fassung 1.2 (2026-09-26).
    func testAusreisserNurAnEinerWarnung() throws {
        func szenario(kultur: Int) throws -> Monatsbild {
            let h = try frisch("2026-09-16")
            try h.posten("Gehalt", 200000, 1, "2026-05", "Gehalt")
            for m in ["05", "06", "07", "08"] {
                try h.fortschreiben("2026-\(m)")
                try h.buchen(-30000, "Lebensmittel", datum: "2026-\(m)-10")
                try h.buchen(-3000, "Kultur", datum: "2026-\(m)-12")
            }
            try h.buchen(-kultur, "Kultur", datum: "2026-09-12")
            return try h.bild("2026-09")
        }
        // 90 statt 30 Euro Kultur, aber das Budget ist erst zu 4,5 Prozent weg
        XCTAssertNil(try szenario(kultur: 9000).warnung)
        // Mit einer Warnung nennt sie Kultur
        XCTAssertEqual(try szenario(kultur: 150000).warnung,
                       "75% des Budgets ausgegeben, aber erst 53% des Monats vorbei. "
                       + "Kultur liegt bei 1.500,00 €, sonst meist um 30,00 €.")
    }

    // MARK: - Bestätigen

    /// Ein geplanter Abschlag zählt erst für den Kontostand, wenn er bestätigt
    /// ist, auf Wunsch mit anderem Datum und Betrag, wie
    /// anpassen_und_bestaetigen in ui/uebersicht.py. Der Posten selbst bleibt.
    func testBestaetigenMitAnpassung() throws {
        let h = try frisch("2026-09-20")
        try h.startsaldoSetzen(betragCent: 100000, datum: "2026-09-01")
        let strom = try h.posten("Strom", -8500, 15, "2026-09", "Energie")
        try h.einstellungSetzen("auto_bestaetigen", "0")
        try h.fortschreiben("2026-09")
        let abschlag = try XCTUnwrap(h.buchungen("2026-09").first { $0.posten == "Strom" })
        XCTAssertEqual(abschlag.status, "geplant")
        XCTAssertEqual(h.kontostand(), 100000, "geplant zählt nicht für den Kontostand")

        try h.bestaetigen(abschlag.id, betrag: -9120, datum: "2026-09-17")
        let gebucht = try XCTUnwrap(h.buchungen("2026-09").first { $0.id == abschlag.id })
        XCTAssertEqual(gebucht.status, "gebucht")
        XCTAssertEqual(gebucht.betragCent, -9120)
        XCTAssertEqual(gebucht.datum, "2026-09-17")
        XCTAssertEqual(h.kontostand(), 100000 - 9120)
        XCTAssertEqual(h.regeln().first { $0.id == strom }?.betragCent, -8500,
                       "der Posten bleibt, wie er ist")
        // Ein zweites Fortschreiben legt den Abschlag nicht noch einmal an
        try h.fortschreiben("2026-09")
        XCTAssertEqual(h.buchungen("2026-09").filter { $0.posten == "Strom" }.count, 1)
    }

    // MARK: - Schema

    /// Eine frisch angelegte Datenbank muss sich als aktuelle Fassung melden
    /// und beim zweiten Öffnen ohne Migration auskommen. Ohne diese Prüfung
    /// fällt es erst beim Nutzer auf, wenn beim Anheben der Fassung die Zahl in
    /// schema.sql vergessen wurde.
    func testFrischeDatenbankMeldetIhreFassung() throws {
        let pfad = FileManager.default.temporaryDirectory
            .appendingPathComponent("haushalt_fassung_test.sqlite").path
        try? FileManager.default.removeItem(atPath: pfad)
        defer { try? FileManager.default.removeItem(atPath: pfad) }
        do {
            let db = try Datenbank(pfad: pfad)
            XCTAssertEqual(try db.einstellung("schema_version"), String(Datenbank.schemaFassung))
        }
        let wieder = try Datenbank(pfad: pfad)
        XCTAssertEqual(try wieder.einstellung("schema_version"), String(Datenbank.schemaFassung))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: pfad + ".vor-v\(Datenbank.schemaFassung)"))
    }

    // MARK: - Fälligkeit nicht monatlicher Posten

    /// Ein nicht monatlicher Posten, dessen Fälligkeitsmonat schon eine Weile
    /// her ist, bucht nicht sofort den vollen Betrag, die Rate ergibt sich aus
    /// der Zeit bis zur nächsten Fälligkeit und dem, was schon zurückgelegt ist.
    func testFaelligkeitsmonatInDerVergangenheit() throws {
        let h3 = try frisch("2026-09-14")
        try h3.posten("Kfz Versicherung", -48000, 5, "2026-05", "Versicherungen",
                      intervall: 12, schonVorhanden: 16000)
        try h3.fortschreiben("2026-09")
        XCTAssertTrue(h3.buchungen("2026-09").isEmpty)
        XCTAssertEqual(h3.toepfe().first?.rateCent, 4000)  // (480 - 160) / 8 Monate bis Mai
        // Ist es dagegen wirklich diesen Monat fällig, wird sofort gebucht
        let h4 = try frisch("2026-09-14")
        try h4.posten("Sofort fällig", -48000, 5, "2026-09", "Sonstiges", intervall: 12)
        try h4.fortschreiben("2026-09")
        XCTAssertEqual(h4.buchungen("2026-09").first?.betragCent, -48000)
    }

    /// Ein Posten mit Fälligkeitsmonat in der Zukunft bleibt für die
    /// Fortschreibung unsichtbar, aber sichtbar für die Verwaltung, sonst könnte
    /// man ihn nirgends mehr bearbeiten oder löschen. Löschen entfernt auch
    /// seinen Topf.
    func testFaelligkeitsmonatInDerZukunft() throws {
        let h5 = try frisch("2026-09-14")
        let kfz5 = try h5.posten("kfz", -100000, 1, "2027-07", "Versicherungen", intervall: 12)
        XCTAssertFalse(h5.regeln(nurGueltige: true).map(\.id).contains(kfz5))
        XCTAssertTrue(h5.regeln().map(\.id).contains(kfz5))
        try h5.fortschreiben("2026-09")
        XCTAssertTrue(h5.buchungen("2026-09").isEmpty)
        XCTAssertEqual(h5.toepfe().count, 1)
        try h5.regelLoeschen(kfz5)
        XCTAssertTrue(h5.toepfe().isEmpty)
    }

    /// Einen Posten mit künftigem Fälligkeitsmonat ändern darf nicht an der
    /// CHECK Bedingung gilt_bis >= gilt_ab scheitern, es gibt ja noch keine
    /// Vergangenheit zu schützen, der Betrag wird direkt an derselben Regel
    /// geändert.
    func testKuenftigenPostenAendern() throws {
        let h6 = try frisch("2026-09-14")
        let kfz6 = try h6.posten("kfz", -100000, 1, "2027-07", "Versicherungen", intervall: 12)
        let neu6 = try h6.regelAendern(kfz6, neuerBetrag: -120000, abMonat: "2026-10")
        XCTAssertEqual(neu6, kfz6)  // keine neue Kette, dieselbe Regel
        XCTAssertEqual(h6.regeln().first?.betragCent, -120000)
        let topf6 = try XCTUnwrap(h6.toepfe().first)
        XCTAssertEqual(topf6.zielCent, 120000)
        XCTAssertEqual(topf6.rateCent, 120000 / 10)  // 10 Monate von September bis Juli
        try h6.regelLoeschen(neu6)  // darf keinen FOREIGN KEY Fehler auslösen
        XCTAssertTrue(h6.regeln().isEmpty)
        XCTAssertTrue(h6.toepfe().isEmpty)
    }

    // MARK: - Töpfe über die Zeit

    /// Ein automatischer Topf läuft über mehrere Zyklen, ohne aufzulaufen. Die
    /// Rate des ersten, verkürzten Zyklus ist eine Aufholrate und muss danach auf
    /// Betrag durch Intervall zurückfallen, sonst spart der Topf Jahr für Jahr
    /// zu viel.
    func testAutomatischerTopfUeberMehrereZyklen() throws {
        let h4 = try frisch("2026-09-14")
        try h4.posten("Kfz", -60000, 1, "2027-05", "Fahrkarten", intervall: 12)
        let kfz4 = try XCTUnwrap(h4.toepfe().first).id

        func standUndRate(_ monat: String) throws -> [Int] {
            let k = h4.mitHeute(monat + "-28")
            try k.fortschreiben(monat)
            let t = try XCTUnwrap(k.toepfe(monat).first { $0.id == kfz4 })
            return [t.stand, t.rateCent]
        }

        // erster Zyklus, acht Monate von September bis zur Fälligkeit im Mai
        XCTAssertEqual(try standUndRate("2026-09"), [7500, 7500])
        XCTAssertEqual(try standUndRate("2027-04"), [60000, 7500])
        // im Fälligkeitsmonat leert der Abschlag den Topf, der nächste Zyklus
        // beginnt mit der Dauerrate von 600 durch 12
        XCTAssertEqual(try standUndRate("2027-05"), [5000, 5000])
        XCTAssertEqual(try standUndRate("2028-04"), [60000, 5000])
        XCTAssertEqual(try standUndRate("2028-05"), [5000, 5000])
        // auch nach drei Durchläufen kein Auflaufen über das Ziel hinaus
        XCTAssertEqual(try standUndRate("2029-04"), [60000, 5000])
        XCTAssertEqual(h4.topfraten("2029-04"), 5000)
        // und immer noch genau ein Topf, es entsteht nie ein zweiter
        XCTAssertEqual(try h4.db.zeilen("SELECT COUNT(*) AS c FROM toepfe").first?["c"]?.alsGanz, 1)
        // Wer sich etwas aus dem Topf leiht, hebt damit die folgenden Raten. Im
        // Juni stehen zwei Raten von 50 Euro drin, die Entnahme von 100 Euro leert ihn.
        try h4.mitHeute("2029-06-15").buchen(-10000, "Fahrkarten", datum: "2029-06-15",
                                             topfId: kfz4)
        XCTAssertEqual(try standUndRate("2029-06"), [0, 5000])
        // Ab dem Folgemonat verteilt sich das Fehlende auf die restlichen zehn Monate
        XCTAssertEqual(try standUndRate("2029-07"), [6000, 6000])
        // und zur Fälligkeit im April steht der volle Betrag wieder bereit
        XCTAssertEqual(try standUndRate("2030-04"), [60000, 6000])
        // Danach fällt die Rate von selbst wieder auf die Dauerrate zurück
        XCTAssertEqual(try standUndRate("2030-05"), [5000, 5000])
    }

    /// Ein eigener Topf mit Zielmonat verhält sich genauso, die Rate ergibt sich
    /// aus Ziel und Termin und gleicht eine Entnahme wieder aus.
    func testEigenerTopfMitZielmonat() throws {
        let h10 = try frisch("2026-09-20")
        let sofa = try h10.topf("Sofa", ziel: 120000, zielMonat: "2027-09")
        func zeigen(_ monat: String) throws -> Topf {
            try XCTUnwrap(h10.toepfe(monat).first { $0.id == sofa })
        }
        let start = try zeigen("2026-09")   // 1200 auf zwölf Monate
        XCTAssertEqual([start.stand, start.rateCent, start.vollInMonaten], [10000, 10000, 12])
        try h10.buchen(-40000, "Haushalt", datum: "2026-09-18", topfId: sofa)
        let danach = try zeigen("2026-09")
        XCTAssertEqual(danach.stand, 0)
        XCTAssertEqual(danach.vollInMonaten, 12)
        XCTAssertGreaterThan(try zeigen("2026-10").rateCent, 10000)
        // Zum Zielmonat ist das Ziel trotzdem erreicht
        let august = try zeigen("2027-08")
        XCTAssertEqual(august.stand, 120000)
        XCTAssertEqual(august.vollInMonaten, 1)
        // Danach keine Rate mehr, der Topf ist fertig
        XCTAssertEqual(try zeigen("2027-09").rateCent, 0)
    }

    // MARK: - Gruppen

    /// Gruppe und Kategorie sind zwei unabhängige Merkmale. Die Gruppe der
    /// Kategorie ist nur die Vorgabe, der Posten übersteuert sie, die Buchung
    /// übersteuert auch den Posten. Damit liegen Haftpflicht und Kfz
    /// Versicherung beide in der Kategorie Versicherungen, aber in
    /// verschiedenen Gruppen.
    func testGruppeAnPostenTopfUndBuchung() throws {
        let h5 = try frisch("2026-09-20")
        try h5.posten("Haftpflicht", -1200, 5, "2026-09", "Versicherungen", gruppe: "Wohnkosten")
        try h5.posten("Kfz Versicherung", -4800, 5, "2026-09", "Versicherungen", gruppe: "Auto")
        try h5.fortschreiben("2026-09")
        try h5.buchen(-6000, "Tanken", datum: "2026-09-10")          // Kategorie trägt Auto
        try h5.buchen(-9000, "Kleidung", datum: "2026-09-11")        // Kategorie trägt Persönliches
        try h5.buchen(-5000, "Kleidung", datum: "2026-09-12", gruppe: "Arbeitskosten")
        try h5.buchen(-2000, "Sonstiges", datum: "2026-09-13")       // ohne Gruppe

        var nachGruppe = h5.summen("2026-09", nachGruppe: true)
        XCTAssertEqual(nachGruppe["Auto"], 4800 + 6000)
        XCTAssertEqual(nachGruppe["Wohnkosten"], 1200)
        XCTAssertEqual(nachGruppe["Arbeitskosten"], 5000)
        XCTAssertEqual(nachGruppe["Persönliches"], 9000)
        XCTAssertEqual(nachGruppe["Sonstiges"], 2000)  // ohne Gruppe unter eigenem Namen
        XCTAssertNil(nachGruppe["Fixkosten"], "Fixkosten gibt es seit Fassung 9 nicht mehr")

        // Nach Kategorie bleibt alles beim Alten, beide Versicherungen zusammen
        let nachKat = h5.summen("2026-09", nachGruppe: false)
        XCTAssertEqual(nachKat["Versicherungen"], 6000)
        XCTAssertEqual(nachKat["Kleidung"], 14000)

        // Gruppe nachträglich ändern und wieder entfernen
        let kfz5 = try XCTUnwrap(h5.regeln(nurGueltige: true)
            .first { $0.name == "Kfz Versicherung" }).id
        try h5.regelGruppeSetzen(kfz5, gruppe: "Fahrzeug")
        XCTAssertNotNil(h5.summen("2026-09", nachGruppe: true)["Fahrzeug"])
        try h5.regelGruppeSetzen(kfz5, gruppe: "")
        nachGruppe = h5.summen("2026-09", nachGruppe: true)
        // Jetzt gilt keine Gruppe, und die Buchung zählt unter dem Namen der Kategorie
        XCTAssertEqual(nachGruppe["Versicherungen"], 4800)

        // Alle vergebenen Gruppen aus allen vier Quellen. Die Vorgaben der
        // Kategorien zählen mit, dazu die selbst vergebenen
        try h5.topf("Reifen", rate: 2000, gruppe: "Auto")
        XCTAssertEqual(h5.gruppen(),
                       ["Arbeitskosten", "Auto", "Einnahmen", "Essen und Trinken",
                        "Familie und Freunde", "Finanzen", "Freizeit", "Gesundheit",
                        "Persönliches", "Unterwegs", "Urlaub", "Weiterbildung",
                        "Wohnen", "Wohnkosten"])
    }

    /// Löschen heißt keine Gruppe, auf der Ebene, auf der gelöscht wird, und
    /// für alles darunter. Nil heißt nicht gesetzt und erbt, ein leerer Text
    /// heißt bewusst gelöscht. Der Topf steht in der Kette.
    func testGeloeschteGruppe() throws {
        let h16 = try frisch("2026-09-18")
        func gruppeVon(_ id: Int64) -> String? {
            h16.buchungen("2026-09").first { $0.id == id }?.gruppe
        }
        func nachGruppe() -> [String: Int] {
            Dictionary(uniqueKeysWithValues: h16.nachKategorieZeitraum(
                .monat, "2026-09-18", nachGruppe: true).map { ($0.kategorie, $0.betrag) })
        }

        // Buchung, Tanken erbt Auto, gelöscht gilt keine Gruppe
        let tanken = try h16.buchen(-5000, "Tanken", datum: "2026-09-10")
        XCTAssertEqual(gruppeVon(tanken), "Auto")
        try h16.buchungAendern(tanken, gruppe: .setzen(""))
        XCTAssertNil(gruppeVon(tanken))
        XCTAssertEqual(nachGruppe()["Tanken"], 5000)
        XCTAssertNil(nachGruppe()["Auto"])
        try h16.buchungAendern(tanken, gruppe: .setzen(nil))  // wieder erben
        XCTAssertEqual(gruppeVon(tanken), "Auto")

        // Posten, Miete erbt Wohnen, gelöscht haben alle seine Buchungen keine Gruppe
        let miete16 = try h16.posten("Miete", -80000, 1, "2026-09", "Miete")
        try h16.fortschreiben("2026-09")
        let abschlag = try XCTUnwrap(h16.buchungen("2026-09").first { $0.posten == "Miete" }).id
        XCTAssertEqual(gruppeVon(abschlag), "Wohnen")
        try h16.regelGruppeSetzen(miete16, gruppe: "")
        XCTAssertNil(gruppeVon(abschlag))
        XCTAssertNil(h16.regeln(nurGueltige: true).first { $0.name == "Miete" }?.wirksameGruppe)
        XCTAssertEqual(nachGruppe()["Miete"], 80000)

        // Topf, seine Gruppe gilt für Buchungen daraus, die eigene der Buchung geht vor
        let reise = try h16.topf("Reise", rate: 5000, gruppe: "Urlaub")
        let essen = try h16.buchen(-3000, "Gastronomie", datum: "2026-09-12", topfId: reise)
        XCTAssertEqual(gruppeVon(essen), "Urlaub")               // statt Essen und Trinken
        try h16.topfGruppeSetzen(reise, gruppe: "")
        XCTAssertNil(gruppeVon(essen))                           // gelöscht, keine Gruppe
        try h16.topfGruppeSetzen(reise, gruppe: nil)
        XCTAssertEqual(gruppeVon(essen), "Essen und Trinken")    // nicht gesetzt, die Kategorie gilt
        try h16.buchungAendern(essen, gruppe: .setzen("Feier"))
        XCTAssertEqual(gruppeVon(essen), "Feier")

        // Kategorie, gelöscht hat sie überall keine Gruppe mehr
        try h16.kategorieAendern(try h16.kategorieId("Tanken"), gruppe: "")
        XCTAssertNil(gruppeVon(tanken))

        // Liste und Summe passen weiter zusammen
        for z in h16.nachKategorieZeitraum(.monat, "2026-09-18", nachGruppe: true) {
            let liste = h16.alleBuchungen(von: "2026-09-01", bis: "2026-09-30",
                                          gruppe: z.kategorie, nurAusgaben: true)
            XCTAssertEqual(-liste.reduce(0) { $0 + $1.betragCent }, z.betrag, z.kategorie)
        }
        XCTAssertFalse(h16.gruppen().contains(""))
    }

    // MARK: - Posten ändern

    /// Umbenennen gilt für den ganzen Posten, über die Änderungskette hinweg,
    /// und ein automatischer Topf zieht mit. Auch alte Abschläge zeigen den
    /// neuen Namen.
    func testUmbenennenUeberDieKette() throws {
        let h12 = try frisch("2026-09-10")
        let alt12 = try h12.posten("Autoversicherung", -60000, 5, "2026-03", "Versicherungen",
                                   intervall: 6)
        try h12.fortschreiben("2026-03")
        let neu12 = try h12.regelAendern(alt12, neuerBetrag: -66000, abMonat: "2026-09")
        try h12.regelUmbenennen(alt12, name: "  Kfz Haftpflicht ")
        XCTAssertEqual(Set(try h12.db.zeilen("SELECT name FROM regeln").compactMap {
            $0["name"]?.alsText }), ["Kfz Haftpflicht"])
        XCTAssertEqual(h12.toepfe().map(\.name), ["Kfz Haftpflicht"])
        XCTAssertEqual(Set(try h12.db.zeilen("""
            SELECT r.name AS posten FROM buchungen b JOIN regeln r ON r.id=b.regel_id
            """).compactMap { $0["posten"]?.alsText }), ["Kfz Haftpflicht"])
        // Eine spätere Betragsänderung übernimmt den neuen Namen
        try h12.regelAendern(neu12, neuerBetrag: -67000, abMonat: "2026-10")
        XCTAssertEqual(Set(h12.regeln().map(\.name)), ["Kfz Haftpflicht"])
        XCTAssertThrowsError(try h12.regelUmbenennen(alt12, name: "  "),
                             "Leerer Name muss abgelehnt werden")
    }

    /// Eine neue Kategorie am Posten erreicht auch seine Buchungen, sie tragen
    /// eine eigene Kopie. Vorher zeigten Übersicht und Auswertung weiter die alte.
    func testKategoriewechselAmPosten() throws {
        let h13 = try frisch("2026-09-17")
        let miete13 = try h13.posten("Miete", -80000, 1, "2026-06", "Miete")
        for m in ["2026-06", "2026-07", "2026-08"] { try h13.fortschreiben(m) }
        let neu13 = try h13.regelAendern(miete13, neuerBetrag: -85000, abMonat: "2026-08")
        try h13.fortschreiben("2026-09")
        try h13.korrektur(neu13, betrag: -12000, datum: "2026-09-05")
        // Ein Abschlag, den jemand bewusst anders eingeordnet hat, bleibt so
        let juli = try XCTUnwrap(try h13.db.zeilen(
            "SELECT id FROM buchungen WHERE soll_monat='2026-07'").first?["id"]?.alsZahl)
        try h13.buchungAendern(juli, kategorie: "Haushalt")
        try h13.regelKategorieSetzen(miete13, kategorieId: try h13.kategorieId("Energie"))
        var kats: [Int64: String] = [:]
        for z in try h13.db.zeilen("""
            SELECT b.id, k.name FROM buchungen b
            JOIN buchung_kategorien bk ON bk.buchung_id=b.id
            JOIN kategorien k ON k.id=bk.kategorie_id
            """) {
            kats[z["id"]?.alsZahl ?? 0] = z["name"]?.alsText
        }
        XCTAssertEqual(kats.removeValue(forKey: juli), "Haushalt",
                       "Eigene Einordnung einer Buchung bleibt")
        XCTAssertEqual(Set(kats.values), ["Energie"])
        XCTAssertEqual(kats.count, 4)
        XCTAssertEqual(Set(h13.nachKategorie("2026-09", nachGruppe: false).map(\.kategorie)),
                       ["Energie"])
    }

    /// Eine Buchung trägt genau eine Kategorie. Mehrere anzubieten war
    /// irreführend, das Bearbeiten zeigte ohnehin nur die erste und warf die
    /// übrigen weg. Was mehrere Kategorien leisten sollten, leisten die Gruppen.
    func testGenauEineKategorieJeBuchung() throws {
        let h6 = try frisch("2026-09-20")
        let b6 = try h6.buchen(-2000, "Gastronomie", datum: "2026-09-05", notiz: "Geburtstag")
        func kategorienVon(_ id: Int64) throws -> [String] {
            try h6.db.zeilen("""
                SELECT k.name FROM buchung_kategorien bk JOIN kategorien k ON k.id=bk.kategorie_id
                WHERE bk.buchung_id=?
                """, [.zahl(id)]).compactMap { $0["name"]?.alsText }
        }
        XCTAssertEqual(try kategorienVon(b6), ["Gastronomie"])
        try h6.buchungAendern(b6, kategorie: "Hobbys")
        XCTAssertEqual(try kategorienVon(b6), ["Hobbys"])
        XCTAssertEqual(h6.buchungen("2026-09").first?.kategorie, "Hobbys")
    }

    // MARK: - Außerplanmäßig und frei verfügbar

    /// Bewusste größere Ausgabe aus dem Konto. Sie senkt den Kontostand wie
    /// jede andere Buchung und zählt in der Auswertung mit, trifft aber die
    /// große Zahl und die Warnung nicht und steht in der Übersicht als eigene
    /// Zeile.
    func testAusserplanmaessigeAusgabe() throws {
        let h7 = try frisch("2026-09-20")
        try h7.posten("Gehalt", 300000, 1, "2026-09", "Gehalt")
        try h7.fortschreiben("2026-09")
        try h7.startsaldoSetzen(betragCent: 500000, datum: "2026-08-31")
        try h7.buchen(-20000, "Lebensmittel", datum: "2026-09-05")
        let vorher = try h7.bild("2026-09")
        let standVorher = try XCTUnwrap(h7.kontostand())

        // Dieselben 450 Euro einmal normal und einmal außerplanmäßig
        let normal = try h7.buchen(-45000, "Haushalt", datum: "2026-09-10")
        XCTAssertEqual(try h7.bild("2026-09").verfuegbarCent, vorher.verfuegbarCent - 45000)
        try h7.buchungLoeschen(normal)

        let wasch = try h7.buchen(-45000, "Haushalt", datum: "2026-09-10", notiz: "Waschmaschine",
                                  ausserplanmaessig: true)
        let nachher = try h7.bild("2026-09")
        XCTAssertEqual(nachher.verfuegbarCent, vorher.verfuegbarCent,
                       "darf das Monatsbudget nicht treffen")
        XCTAssertEqual(nachher.variabelCent, vorher.variabelCent,
                       "zählt nicht zu den variablen Ausgaben")
        XCTAssertEqual(nachher.ausserplanCent, -45000)
        XCTAssertNil(nachher.warnung, "darf keine Warnung auslösen")
        // Der Kontostand sinkt trotzdem, das Geld ist wirklich weg
        XCTAssertEqual(h7.kontostand(), standVorher - 45000)
        // Und in der Auswertung taucht sie auf, ausgegeben wurde sie ja
        XCTAssertEqual(h7.summen("2026-09", nachGruppe: false)["Haushalt"], 45000)
        // Nachträglich umschaltbar
        try h7.buchungAendern(wasch, ausserplanmaessig: false)
        XCTAssertEqual(try h7.bild("2026-09").verfuegbarCent, vorher.verfuegbarCent - 45000)
        try h7.buchungAendern(wasch, ausserplanmaessig: true)
        XCTAssertEqual(try h7.bild("2026-09").verfuegbarCent, vorher.verfuegbarCent)
    }

    /// Frei verfügbar, das Geld außerhalb des Monatsbudgets. Kontostand minus
    /// aller Rücklagen. Eine außerplanmäßige Ausgabe senkt es sofort, das
    /// Auflösen eines Topfs hebt es. Buchungen am Tag des Startsaldos zählen
    /// mit, früher fielen sie heraus und verschwanden stillschweigend.
    func testFreiVerfuegbar() throws {
        let h8 = try frisch("2026-09-15")
        try h8.startsaldoSetzen(betragCent: 524000, datum: "2026-09-15")
        XCTAssertEqual(h8.kontostand(), 524000)
        XCTAssertEqual(h8.freiVerfuegbar(), 524000)

        // Buchung am selben Tag wie der Startsaldo
        try h8.buchen(-20000, "Haushalt", datum: "2026-09-15", ausserplanmaessig: true)
        XCTAssertEqual(h8.kontostand(), 504000, "Buchung am Tag des Startsaldos muss zählen")
        XCTAssertEqual(h8.freiVerfuegbar(), 504000)
        // und sie trifft das Monatsbudget trotzdem nicht
        XCTAssertEqual(try h8.bild("2026-09").variabelCent, 0)

        // Rücklagen mindern das frei Verfügbare
        let urlaub8 = try h8.topf("Urlaub", rate: 15000, schonVorhanden: 60000)
        XCTAssertEqual(h8.freiVerfuegbar(), 504000 - h8.ruecklagenGesamt())
        // Wer an die Rücklage will, löst den Topf auf
        let vorher8 = try XCTUnwrap(h8.freiVerfuegbar())
        let stand8 = h8.ruecklagenGesamt()
        try h8.topfAufloesen(urlaub8)
        XCTAssertEqual(h8.freiVerfuegbar(), vorher8 + stand8)
        XCTAssertEqual(h8.freiVerfuegbar(), 504000)

        // Unterschreitet der Kontostand die Rücklagen, wird frei negativ und die
        // Deckungszeile meldet sich, sonst bleibt sie stumm
        XCTAssertNil(h8.deckung())
        try h8.topf("Zu groß", rate: 0, schonVorhanden: 600000)
        XCTAssertLessThan(try XCTUnwrap(h8.freiVerfuegbar()), 0)
        XCTAssertTrue(h8.deckung()?.contains("fehlen") ?? false)
    }

    /// Der Schalter außerplanmäßig wirkt in beide Richtungen. Eine einmalige
    /// Einnahme wie eine Steuererstattung landet auf dem Konto, statt das
    /// Budget dieses Monats aufzublähen. Löschen nimmt beides sauber zurück.
    func testAusserplanmaessigInBeideRichtungen() throws {
        let h9 = try frisch("2026-09-20")
        try h9.posten("Gehalt", 300000, 1, "2026-09", "Gehalt")
        try h9.fortschreiben("2026-09")
        try h9.startsaldoSetzen(betragCent: 500000, datum: "2026-09-01")
        let u0 = try h9.bild("2026-09")
        let konto0 = try XCTUnwrap(h9.kontostand())
        let frei0 = try XCTUnwrap(h9.freiVerfuegbar())

        // Einnahme normal, das Budget steigt
        let normal9 = try h9.buchen(90000, "Sonstiges", datum: "2026-09-12")
        XCTAssertEqual(try h9.bild("2026-09").einnahmenCent, u0.einnahmenCent + 90000)
        XCTAssertEqual(try h9.bild("2026-09").verfuegbarCent, u0.verfuegbarCent + 90000)
        try h9.buchungLoeschen(normal9)

        // Dieselbe Einnahme außerplanmäßig, das Budget bleibt, das Konto steigt
        let steuer = try h9.buchen(90000, "Sonstiges", datum: "2026-09-12",
                                   notiz: "Steuererstattung", ausserplanmaessig: true)
        let u1 = try h9.bild("2026-09")
        XCTAssertEqual(u1.einnahmenCent, u0.einnahmenCent,
                       "darf die Einnahmen des Monats nicht erhöhen")
        XCTAssertEqual(u1.verfuegbarCent, u0.verfuegbarCent, "darf das Monatsbudget nicht erhöhen")
        XCTAssertEqual(u1.ausserplanCent, 90000)
        XCTAssertEqual(h9.kontostand(), konto0 + 90000)
        XCTAssertEqual(h9.freiVerfuegbar(), frei0 + 90000)

        // Ausgabe und Einnahme zusammen ergeben den Saldo in der Zeile
        try h9.buchen(-45000, "Haushalt", datum: "2026-09-13", ausserplanmaessig: true)
        XCTAssertEqual(try h9.bild("2026-09").ausserplanCent, 45000)

        // Löschen schreibt nur dem Konto gut, nicht dem Monatsbudget
        try h9.buchungLoeschen(steuer)
        XCTAssertEqual(try h9.bild("2026-09").verfuegbarCent, u0.verfuegbarCent,
                       "Löschen darf das Budget nicht anfassen")
        XCTAssertEqual(h9.kontostand(), konto0 - 45000)
    }

    // MARK: - Auswertung

    /// Der Ausreißerhinweis der Auswertung betrachtet nur den variablen Teil.
    /// Das Übliche anteilig zum verstrichenen Monat zu erwarten ergibt bei einem
    /// festen Posten keinen Sinn, die Miete geht am Ersten in einer Summe ab.
    func testAusreisserNurImVariablenTeil() throws {
        let h11 = try frisch("2026-09-16")
        try h11.posten("Miete", -80000, 1, "2026-03", "Miete")
        for m in ["03", "04", "05", "06", "07", "08", "09"] {
            try h11.fortschreiben("2026-\(m)")
            try h11.buchen(-20000, "Lebensmittel", datum: "2026-\(m)-10")
        }
        let wohnen = try XCTUnwrap(h11.nachKategorie("2026-09", nachGruppe: false)
            .first { $0.kategorie == "Miete" })
        XCTAssertEqual(wohnen.betrag, 80000)
        XCTAssertEqual(wohnen.ueblich, 80000)      // die volle Summe, für die Anzeige
        XCTAssertEqual(wohnen.variabel, 0)         // nichts davon ist variabel
        XCTAssertNil(wohnen.erwartet)              // also keine Erwartung
        XCTAssertEqual(wohnen.abweichungCent, 0)   // und kein Ausreißer
        // Ein echter Ausreißer wird weiterhin erkannt
        try h11.buchen(-30000, "Lebensmittel", datum: "2026-09-14")
        let lm = try XCTUnwrap(h11.nachKategorie("2026-09", nachGruppe: false)
            .first { $0.kategorie == "Lebensmittel" })
        XCTAssertGreaterThan(lm.abweichungCent, 20000)
        XCTAssertGreaterThan(try XCTUnwrap(lm.abweichungAnteil), 0.25)
    }

    func testZeitraeume() throws {
        let k = try frisch("2026-09-16")
        func spanne(_ art: Zeitraumart, _ tag: String) -> [String] {
            let s = k.zeitraum(art, tag)
            return [s.von, s.bis]
        }
        XCTAssertEqual(spanne(.woche, "2026-09-16"), ["2026-09-14", "2026-09-20"])  // Montag bis Sonntag
        XCTAssertEqual(spanne(.monat, "2026-02-10"), ["2026-02-01", "2026-02-28"])
        XCTAssertEqual(spanne(.jahr, "2026-09-16"), ["2026-01-01", "2026-12-31"])
        XCTAssertEqual(k.zeitraumPlus(.monat, "2026-01-31", 1), "2026-02-28")
        XCTAssertEqual(k.zeitraumPlus(.jahr, "2024-02-29", 1), "2025-02-28")
        XCTAssertEqual(k.zeitraumPlus(.woche, "2026-09-16", -1), "2026-09-09")
    }

    /// Auswertung nach Woche, Monat und Jahr. Die Woche lässt feste Posten weg
    /// und vergleicht mit der Woche 52 Wochen zuvor, das laufende Jahr nur mit
    /// demselben Stück des Vorjahres. Danach ergeben die Buchungen hinter jeder
    /// Zeile genau deren Betrag.
    func testAuswertungNachWocheMonatUndJahr() throws {
        let h14 = try frisch("2026-09-16")
        try h14.posten("Miete", -80000, 1, "2025-01", "Miete")
        try h14.posten("Strom", -9000, 15, "2025-01", "Energie")   // fällt in die laufende Woche
        for i in 0..<21 { try h14.fortschreiben(Monat.plus("2025-01", i)) }  // 2025-01 bis 2026-09
        try h14.buchen(-3000, "Lebensmittel", datum: "2026-09-14")
        try h14.buchen(-2000, "Lebensmittel", datum: "2026-09-16")
        try h14.buchen(-4000, "Lebensmittel", datum: "2026-09-10")       // Vorwoche
        try h14.buchen(-2500, "Lebensmittel", datum: "2025-09-17")       // 52 Wochen zuvor

        let w = h14.vergleichZeitraum(.woche, "2026-09-16")
        XCTAssertEqual(w.ausgaben, 5000)             // Strom am 15. zählt in der Woche nicht
        XCTAssertEqual(w.vorher, 1000)
        XCTAssertEqual(w.vorjahr, 2500)
        let wv = h14.verlaufZeitraum(.woche, "2026-09-16")
        XCTAssertEqual(wv.count, 12)
        XCTAssertEqual(wv.last?.von, "2026-09-14")
        XCTAssertEqual(wv.last?.variabel, 5000)
        XCTAssertTrue(wv.allSatisfy { $0.fix == 0 })
        let wk = h14.zeilen(.woche, "2026-09-16", nachGruppe: false)
        XCTAssertEqual(Set(wk.keys), ["Lebensmittel"])  // feste Posten ausgeblendet
        XCTAssertEqual(wk["Lebensmittel"]?.betrag, 5000)
        XCTAssertEqual(wk["Lebensmittel"]?.vorher, 4000)

        let j = h14.vergleichZeitraum(.jahr, "2026-09-16")
        let fixMonat = 80000 + 9000
        XCTAssertEqual(j.ausgaben, 9 * fixMonat + 9000)       // Januar bis September
        XCTAssertEqual(j.vorher, 9000 - 2500)                 // gegen Januar bis September 2025
        XCTAssertNil(j.vorjahr)
        XCTAssertEqual(h14.jahrBisMonat(2026), "2026-09")
        XCTAssertEqual(h14.jahrBisMonat(2025), "2025-12")
        XCTAssertNil(h14.jahrBisMonat(2027))
        let jv = h14.verlaufZeitraum(.jahr, "2026-09-16")
        XCTAssertEqual(jv.map { String($0.von.prefix(4)) }, ["2025", "2026"])  // ab dem ersten Jahr mit Buchungen
        XCTAssertEqual(jv.first?.fix, 12 * fixMonat)
        XCTAssertEqual(jv.first?.variabel, 2500)
        XCTAssertEqual(jv.last?.fix, 9 * fixMonat)
        XCTAssertEqual(jv.last?.variabel, 9000)
        let jk = h14.zeilen(.jahr, "2026-09-16", nachGruppe: false)
        XCTAssertEqual(jk["Lebensmittel"]?.betrag, 9000)
        XCTAssertEqual(jk["Lebensmittel"]?.vorher, 2500)
        XCTAssertEqual(jk["Miete"]?.betrag, 9 * 80000)
        XCTAssertEqual(jk["Miete"]?.vorher, 9 * 80000)
        XCTAssertNil(jk["Lebensmittel"]?.ueblich)          // das Übliche gibt es nur im Monat
        // Nach Gruppe fassen Miete und Energie zu Wohnen zusammen, Lebensmittel
        // zählt unter Essen und Trinken
        XCTAssertEqual(h14.zeilen(.jahr, "2026-09-16", nachGruppe: true).mapValues(\.betrag),
                       ["Wohnen": 9 * fixMonat, "Essen und Trinken": 9000])
        XCTAssertEqual(h14.vergleichZeitraum(.jahr, "2027-03-01").ausgaben, 0)

        // Der Monat reicht an die Monatsfunktion durch, beide liefern dasselbe
        let mz = h14.nachKategorieZeitraum(.monat, "2026-09-16", nachGruppe: false)
        let mm = h14.nachKategorie("2026-09", nachGruppe: false)
        XCTAssertEqual(mz.map(\.kategorie), mm.map(\.kategorie))
        XCTAssertEqual(mz.map(\.vorher), mm.map(\.vorher))

        // Die Buchungen hinter jeder Zeile der Auswertung ergeben genau deren
        // Betrag, in jeder Art und nach Kategorie wie nach Gruppe. Eine Buchung
        // mit eigener Gruppe und ein Posten mit eigener Gruppe prüfen die
        // Rangfolge der Gruppen mit.
        try h14.buchen(-1500, "Lebensmittel", datum: "2026-09-15", gruppe: "Feier")
        try h14.posten("Hausrat", -1200, 5, "2026-01", "Versicherungen", gruppe: "Wohnen")
        for i in 0..<9 { try h14.fortschreiben(Monat.plus("2026-01", i)) }
        for art in Zeitraumart.allCases {
            let s = try XCTUnwrap(h14.auswertungSpanne(art, "2026-09-16"))
            for gruppiert in [false, true] {
                for zeile in h14.nachKategorieZeitraum(art, "2026-09-16", nachGruppe: gruppiert) {
                    let liste = h14.alleBuchungen(
                        von: s.von, bis: s.bis,
                        kategorie: gruppiert ? nil : zeile.kategorie,
                        gruppe: gruppiert ? zeile.kategorie : nil,
                        nurAusgaben: true, ohneFix: art == .woche)
                    XCTAssertEqual(-liste.reduce(0) { $0 + $1.betragCent }, zeile.betrag,
                                   "\(art) \(gruppiert) \(zeile.kategorie)")
                }
            }
        }
        let gruppen = Set(h14.nachKategorieZeitraum(.monat, "2026-09-16", nachGruppe: true)
            .map(\.kategorie))
        XCTAssertTrue(gruppen.isSuperset(of: ["Feier", "Wohnen", "Essen und Trinken"]))
        let jahr = try XCTUnwrap(h14.auswertungSpanne(.jahr, "2026-09-16"))
        XCTAssertEqual([jahr.von, jahr.bis], ["2026-01-01", "2026-09-30"])
        XCTAssertNil(h14.auswertungSpanne(.jahr, "2027-01-01"))
        let feier = h14.alleBuchungen(kategorie: "Lebensmittel", gruppe: "Feier")
        XCTAssertEqual(feier.count, 1)
        XCTAssertEqual(feier.first?.gruppe, "Feier")
    }

    /// Wer mitten im Jahr anfängt, vergleicht im Folgejahr nur die Monate, die
    /// es im Vorjahr schon gab, sonst sähe das neue Jahr viel teurer aus.
    func testJahresvergleichNachSpaetemStart() throws {
        let h15 = try frisch("2026-09-16")
        try h15.posten("Miete", -80000, 1, "2025-07", "Miete")
        for i in 0..<15 { try h15.fortschreiben(Monat.plus("2025-07", i)) }  // 2025-07 bis 2026-09
        let j15 = h15.vergleichZeitraum(.jahr, "2026-09-16")
        XCTAssertEqual(j15.vergleichMonate, ["2026-07", "2026-08", "2026-09"])
        XCTAssertEqual(j15.vorher, 0)             // gleiche Miete, also kein Unterschied
        XCTAssertEqual(j15.ausgaben, 9 * 80000)   // das Jahr selbst zählt trotzdem voll
        XCTAssertNil(h15.vergleichZeitraum(.jahr, "2025-09-16").vorher)   // 2024 ist leer
    }
}

// MARK: - Hilfen

enum Pruefung {
    static func tag(_ iso: String) -> Date {
        guard let datum = Datumsformat.iso.date(from: iso) else {
            fatalError("kein Datum \(iso)")
        }
        return datum
    }

    /// round() aus Python, halb auf gerade.
    static func rundePython(_ wert: Double) -> Int {
        Int(wert.rounded(.toNearestOrEven))
    }
}

/// Weitere Kurzformen nur für die Prüfungen. posten und topf stehen in
/// Kern/KernKurzformen.swift, die Demodaten brauchen sie auch.
extension Kern {
    /// Wie `Haushalt.uebersicht`, das vorher fortschreibt. Die Übersicht des
    /// Kerns in Swift liest nur, fortgeschrieben wird beim Laden.
    func bild(_ monat: String) throws -> Monatsbild {
        try fortschreiben(monat)
        return uebersicht(monat)
    }

    /// Derselbe Kern an einem anderen Tag, wie `h.heute = ...` in Python.
    func mitHeute(_ iso: String) -> Kern {
        Kern(db: db, heute: Pruefung.tag(iso))
    }

    func topfVon(_ buchung: Int64) throws -> Int64? {
        try db.zeilen("SELECT topf_id FROM buchungen WHERE id=?", [.zahl(buchung)])
            .first?["topf_id"]?.alsZahl
    }

    func mieten(_ k: Kern, _ monat: String) -> [Int] {
        k.buchungen(monat).filter { $0.posten == "Miete" }.map(\.betragCent)
    }

    func summen(_ monat: String, nachGruppe: Bool) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: nachKategorie(monat, nachGruppe: nachGruppe)
            .map { ($0.kategorie, $0.betrag) })
    }

    func zeilen(_ art: Zeitraumart, _ tag: String, nachGruppe: Bool) -> [String: Auswertungszeile] {
        Dictionary(uniqueKeysWithValues: nachKategorieZeitraum(art, tag, nachGruppe: nachGruppe)
            .map { ($0.kategorie, $0) })
    }
}
