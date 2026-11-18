import Foundation

/// Buchungen vom iPhone, ohne eigenes Programm dort (2026-09-27). Ein
/// Kurzbefehl auf dem iPhone legt je Buchung eine kleine JSON Datei in den
/// Ordner Eingang neben der Datenbank, iCloud bringt sie auf den Mac, und das
/// Programm bucht sie beim Start und immer, wenn es in den Vordergrund kommt.
/// Die Datenbank selbst fasst das iPhone nie an.
///
///     {"art": "ausgabe", "betrag": 42.80, "kategorie": "Lebensmittel",
///      "datum": "2026-09-27", "notiz": "Wochenmarkt"}
///
/// Pflicht sind Betrag und Kategorie, die Kategorie über ihren Namen, das
/// iPhone kennt keine IDs. Der Betrag darf eine Zahl oder ein Text mit Komma
/// sein, positiv, das Vorzeichen setzt art. Ohne Datum gilt der Tag, an dem
/// die Datei geschrieben wurde, und nicht der, an dem der Mac sie liest.
/// Wahlweise dazu gruppe, topf über seinen Namen und ausserplanmaessig.
///
/// Gebuchte Dateien wandern nach Eingang/Übernommen, unlesbare nach
/// Eingang/Fehler, gelöscht wird nichts. Jede Buchung trägt quelle import und
/// als import_hash Name, Inhalt und Änderungszeit der Datei, siehe schluessel. Dieselbe Datei wird so
/// nie zweimal gebucht, auch nicht nach einem Absturz zwischen Buchen und
/// Verschieben oder wenn zwei Macs gleichzeitig lesen. Am Schema ändert das
/// nichts, quelle und import_hash waren für den Bankimport schon da.
///
/// Zurück zum iPhone schreibt das Programm kategorien.json und stand.json
/// neben die Datenbank, siehe Eingang.auskunft. Daraus baut der Kurzbefehl
/// seine Auswahl und zeigt, was diesen Monat bleibt.
enum Eingang {
    struct Ergebnis: Equatable {
        var uebernommen = 0
        /// Dateien, die iCloud noch nicht auf den Mac gebracht hat. Sie sind
        /// angefordert und kommen beim nächsten Mal dran.
        var wartend = 0
        /// Je unlesbarer Datei ein Satz, was nicht stimmte.
        var fehler: [String] = []

        /// Ein Satz für die Übersicht, nil wenn es nichts zu sagen gibt.
        var satz: String? {
            var teile: [String] = []
            if uebernommen == 1 { teile.append("Eine Buchung vom iPhone übernommen.") }
            if uebernommen > 1 { teile.append("\(uebernommen) Buchungen vom iPhone übernommen.") }
            if fehler.count == 1 {
                teile.append("Eine Datei vom iPhone ließ sich nicht buchen, sie liegt in "
                    + "Eingang/Fehler. \(fehler[0])")
            } else if fehler.count > 1 {
                teile.append("\(fehler.count) Dateien vom iPhone ließen sich nicht buchen, sie "
                    + "liegen in Eingang/Fehler. \(fehler[0])")
            }
            return teile.isEmpty ? nil : teile.joined(separator: " ")
        }
    }

    static let uebernommenOrdner = "Übernommen"
    static let fehlerOrdner = "Fehler"

    /// Der Ordner Eingang zu einer Datenbank, immer neben ihr. Für die echte
    /// liegt er damit in iCloud Drive, wo das iPhone hinkommt, für eine Kopie
    /// über HAUSHALT_DB neben der Kopie.
    static func ordner(fuer datenbank: String) -> URL {
        URL(fileURLWithPath: datenbank).deletingLastPathComponent()
            .appendingPathComponent("Eingang")
    }

    /// Bucht alle Dateien im Eingang. Jede in einem eigenen Stück, eine
    /// kaputte hält die übrigen nicht auf.
    static func einlesen(_ kern: Kern, ordner: URL) -> Ergebnis {
        let dateien = FileManager.default
        var ergebnis = Ergebnis()
        try? dateien.createDirectory(at: ordner, withIntermediateDirectories: true)
        let namen = ((try? dateien.contentsOfDirectory(atPath: ordner.path)) ?? []).sorted()
        for name in namen {
            let url = ordner.appendingPathComponent(name)
            // Noch nicht geladen liegt nur ein Platzhalter .name.json.icloud da
            if name.hasPrefix("."), name.hasSuffix(".json.icloud") {
                let echt = ordner.appendingPathComponent(
                    String(name.dropFirst().dropLast(".icloud".count)))
                try? dateien.startDownloadingUbiquitousItem(at: echt)
                ergebnis.wartend += 1
                continue
            }
            guard name.lowercased().hasSuffix(".json"), !name.hasPrefix(".") else { continue }
            do {
                let daten = try Data(contentsOf: url)
                let merkmale = try? dateien.attributesOfItem(atPath: url.path)
                let geschrieben = merkmale?[.creationDate] as? Date
                try buchen(kern, daten: daten,
                           schluessel: schluessel(name: name, daten: daten,
                                                  geaendert: merkmale?[.modificationDate] as? Date),
                           geschrieben: geschrieben ?? kern.heute)
                ergebnis.uebernommen += 1
                verschieben(url, nach: ordner.appendingPathComponent(uebernommenOrdner))
            } catch let fehler as Fehler where fehler.schonGebucht {
                // Schon einmal gebucht, nur das Verschieben fehlte noch
                verschieben(url, nach: ordner.appendingPathComponent(uebernommenOrdner))
            } catch let fehler as Fehler where fehler.unlesbar && frisch(url) {
                // Vielleicht schreibt iCloud noch daran, beim nächsten Mal wieder
                ergebnis.wartend += 1
            } catch {
                ergebnis.fehler.append("\(name), \(error.localizedDescription)")
                verschieben(url, nach: ordner.appendingPathComponent(fehlerOrdner))
            }
        }
        return ergebnis
    }

    /// Woran eine Datei als schon gebucht erkannt wird. Name, Inhalt und
    /// Zeitpunkt der letzten Änderung zusammen, das bleibt beim Verschieben
    /// gleich. Nur am Namen, wie zuerst (verworfen 2026-09-27), ging eine
    /// Buchung verloren, sobald der Kurzbefehl einen Namen zweimal vergab, etwa
    /// nur mit dem Datum darin. Die zweite Datei galt dann als schon gebucht.
    static func schluessel(name: String, daten: Data, geaendert: Date?) -> String {
        var pruef: UInt64 = 0xcbf2_9ce4_8422_2325
        let zeit = geaendert.map { String(Int($0.timeIntervalSince1970 * 1000)) } ?? ""
        // FNV-1a über Inhalt und Zeit, als Erkennungszeichen reicht das, und
        // der Kern kommt ohne weiteres Framework aus
        for byte in daten + Data(zeit.utf8) {
            pruef ^= UInt64(byte)
            pruef = pruef &* 0x0000_0100_0000_01b3
        }
        return "eingang:\(name):" + String(pruef, radix: 16)
    }

    /// Eine Datei, die sich in den letzten zehn Sekunden geändert hat. Ist sie
    /// unlesbar, wird sie gerade vielleicht noch geschrieben.
    private static func frisch(_ datei: URL) -> Bool {
        guard let geaendert = (try? FileManager.default.attributesOfItem(atPath: datei.path))?[
            .modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(geaendert) < 10
    }

    struct Fehler: LocalizedError {
        let text: String
        var schonGebucht = false
        var unlesbar = false
        var errorDescription: String? { text }
    }

    /// Eine Datei als Buchung, in einem Stück mit dem Merker import_hash.
    static func buchen(_ kern: Kern, daten: Data, schluessel: String, geschrieben: Date) throws {
        guard var feld = (try? JSONSerialization.jsonObject(with: daten)) as? [String: Any] else {
            throw Fehler(text: "Der Inhalt ist kein JSON Objekt.", unlesbar: true)
        }
        let db = kern.db
        if try !db.zeilen("SELECT 1 FROM buchungen WHERE import_hash=?", [.text(schluessel)])
            .isEmpty {
            throw Fehler(text: "Schon gebucht.", schonGebucht: true)
        }
        // Ein gesprochener Satz statt einzelner Felder, etwa Tanken 50 Euro,
        // wie ihn Siri über den Kurzbefehl schickt (2026-09-27). Was einzeln
        // angegeben ist, gilt vor dem Satz.
        if let satz = (feld["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !satz.isEmpty {
            let namen = try db.zeilen("SELECT name FROM kategorien WHERE aktiv=1")
                .compactMap { $0["name"]?.alsText }
            let gelesen = satzLesen(satz, kategorien: namen)
            if feld["kategorie"] == nil {
                guard let kategorie = gelesen.kategorie else {
                    throw Fehler(text: "Im Satz \(satz) steht keine Kategorie.")
                }
                feld["kategorie"] = kategorie
            }
            if feld["betrag"] == nil {
                guard let cent = gelesen.cent else {
                    throw Fehler(text: "Im Satz \(satz) steht kein Betrag.")
                }
                feld["betrag"] = NSDecimalNumber(decimal: Decimal(cent) / 100)
            }
            if feld["art"] == nil, gelesen.einnahme { feld["art"] = "einnahme" }
        }
        let art = (feld["art"] as? String)?.lowercased() ?? "ausgabe"
        guard art == "ausgabe" || art == "einnahme" else {
            throw Fehler(text: "Die Art \(art) gibt es nicht, nur ausgabe oder einnahme.")
        }
        guard let cent = betrag(feld["betrag"]), cent > 0 else {
            throw Fehler(text: "Der Betrag fehlt oder ist nicht größer als null.")
        }
        guard let kategorieName = (feld["kategorie"] as? String)?
            .trimmingCharacters(in: .whitespaces), !kategorieName.isEmpty else {
            throw Fehler(text: "Die Kategorie fehlt.")
        }
        guard let kategorieId = try db.zeilen(
            "SELECT id FROM kategorien WHERE name=? COLLATE NOCASE AND aktiv=1",
            [.text(kategorieName)]).first?["id"]?.alsZahl else {
            throw Fehler(text: "Die Kategorie \(kategorieName) gibt es nicht.")
        }
        var topfId: Int64?
        if let topf = (feld["topf"] as? String)?.trimmingCharacters(in: .whitespaces),
           !topf.isEmpty {
            guard art == "ausgabe" else { throw Fehler(text: "Eine Einnahme kommt aus keinem Topf.") }
            guard let id = try db.zeilen(
                "SELECT id FROM toepfe WHERE name=? COLLATE NOCASE AND aufgeloest_am IS NULL",
                [.text(topf)]).first?["id"]?.alsZahl else {
                throw Fehler(text: "Den Topf \(topf) gibt es nicht.")
            }
            topfId = id
        }
        let datum: String
        if let text = feld["datum"] as? String, !text.isEmpty {
            guard let tag = tag(text) else {
                throw Fehler(text: "Das Datum \(text) ist nicht als JJJJ-MM-TT lesbar.")
            }
            datum = tag
        } else {
            datum = Datumsformat.iso.string(from: geschrieben)
        }
        let gruppe = (feld["gruppe"] as? String)?.trimmingCharacters(in: .whitespaces)
        try db.inEinemStueck {
            let id = try kern.buchen(art == "ausgabe" ? -cent : cent, kategorieId: kategorieId,
                                     datum: datum, notiz: feld["notiz"] as? String,
                                     topfId: topfId,
                                     gruppe: gruppe?.isEmpty == false ? gruppe : nil,
                                     ausserplanmaessig: wahr(feld["ausserplanmaessig"]))
            try db.schreiben("UPDATE buchungen SET quelle='import', import_hash=? WHERE id=?",
                             [.text(schluessel), .zahl(id)])
        }
    }

    /// Kategorie, Betrag und Art aus einem gesprochenen Satz wie Tanken 50
    /// Euro, 12,40 € für Lebensmittel oder Einnahme Gehalt 3200. Eine Kategorie
    /// zählt nur als ganzes Wort, sonst fände sich Haushalt in Haushaltsbuch.
    /// Bei mehreren gewinnt der längste Name, Arzt und Apotheke vor Arzt.
    static func satzLesen(_ satz: String, kategorien: [String])
        -> (kategorie: String?, cent: Int?, einnahme: Bool) {
        let kategorie = kategorien.sorted { $0.count > $1.count }.first { name in
            let muster = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: name)
                + "(?![\\p{L}\\p{N}])"
            return satz.range(of: muster, options: [.regularExpression, .caseInsensitive]) != nil
        }
        // Siri schreibt Zahlen bis zwölf aus, eins statt 1 (2026-10-05). Die
        // Kategorie wird am Original gesucht, die Zahl am umgewandelten Satz.
        let satz = zahlwoerterZuZiffern(satz)
        var cent: Int?
        // 12 Euro 40, 12 Euro und 40 Cent, so spricht man es. 12 Euro 40 sind
        // 12,40 €, 12 Euro 5 sind 12,05 €
        for muster in [#"(\d+)\s*(?:euro|€)\s*und\s*(\d{1,2})\s*cent"#,
                       #"(\d+)\s*(?:euro|€)\s*(\d{1,2})(?!\d)(?:\s*cent)?"#] where cent == nil {
            if let treffer = satz.range(of: muster, options: [.regularExpression, .caseInsensitive]) {
                let zahlen = satz[treffer].split { !$0.isNumber }.compactMap { Int($0) }
                if zahlen.count == 2 { cent = zahlen[0] * 100 + zahlen[1] }
            }
        }
        // Nur Cent, fünfzig Cent
        if cent == nil,
           let treffer = satz.range(of: #"(?<![\d.,])\d{1,3}\s*cent"#,
                                    options: [.regularExpression, .caseInsensitive]) {
            cent = satz[treffer].split { !$0.isNumber }.compactMap { Int($0) }.first
        }
        // Die Zahl direkt vor Euro gewinnt, ein Wocheneinkauf fünfzig Euro ist
        // 50 und nicht das ein davor
        if cent == nil,
           let treffer = satz.range(of: #"\d+(?:[.,]\d+)*(?=\s*(?:euro|€))"#,
                                    options: [.regularExpression, .caseInsensitive]) {
            cent = betrag(String(satz[treffer]))
        }
        if cent == nil,
           let treffer = satz.range(of: #"\d+(?:[.,]\d+)*"#, options: .regularExpression) {
            cent = betrag(String(satz[treffer]))
        }
        let einnahme = satz.range(of: #"(?<!\p{L})(einnahme|eingenommen)(?!\p{L})"#,
                                  options: [.regularExpression, .caseInsensitive]) != nil
        return (kategorie, cent, einnahme)
    }

    private static let einer: [String: Int] = [
        "null": 0, "ein": 1, "eins": 1, "eine": 1, "einen": 1, "einem": 1, "zwei": 2, "zwo": 2,
        "drei": 3, "vier": 4, "fünf": 5, "sechs": 6, "sieben": 7, "acht": 8, "neun": 9,
        "zehn": 10, "elf": 11, "zwölf": 12, "dreizehn": 13, "vierzehn": 14, "fünfzehn": 15,
        "sechzehn": 16, "siebzehn": 17, "achtzehn": 18, "neunzehn": 19,
    ]
    private static let zehner: [String: Int] = [
        "zwanzig": 20, "dreißig": 30, "dreissig": 30, "vierzig": 40, "fünfzig": 50,
        "sechzig": 60, "siebzig": 70, "achtzig": 80, "neunzig": 90,
    ]

    /// Eine Zahl, die als ein Wort geschrieben ist, bis 9999. Eins, zwölf,
    /// einundzwanzig, dreihundertfünfzig, tausendzweihundert. Mehrere Wörter
    /// mit Leerzeichen dazwischen zählen nicht, Siri schreibt ab dreizehn
    /// ohnehin Ziffern.
    static func zahlwort(_ wort: String) -> Int? {
        let w = wort.lowercased()
        if let zahl = einer[w] ?? zehner[w] { return zahl }
        for (teiler, faktor, grenze) in [("tausend", 1000, 100), ("hundert", 100, 10)] {
            guard let stelle = w.range(of: teiler) else { continue }
            let links = String(w[..<stelle.lowerBound])
            var rechts = String(w[stelle.upperBound...])
            if rechts.hasPrefix("und") { rechts.removeFirst(3) }
            let davor = links.isEmpty ? 1 : zahlwort(links)
            let danach = rechts.isEmpty ? 0 : zahlwort(rechts)
            guard let davor, let danach, davor >= 1, davor < grenze, danach < faktor else {
                return nil
            }
            return davor * faktor + danach
        }
        // einundzwanzig, fünfundvierzig
        let teile = w.components(separatedBy: "und")
        if teile.count == 2, let a = einer[teile[0]], (1...9).contains(a), let b = zehner[teile[1]] {
            return a + b
        }
        return nil
    }

    /// Ersetzt Zahlwörter im Satz durch Ziffern. Ein zählt immer als Zahl, in
    /// diesem Zusammenhang gibt es kein anderes (2026-10-05). Eine, einen und
    /// einem zählen nur vor Euro oder Cent, sonst sind sie der Artikel, wie in
    /// mache eine Buchung.
    static func zahlwoerterZuZiffern(_ satz: String) -> String {
        guard let wort = try? NSRegularExpression(pattern: #"\p{L}+"#) else { return satz }
        let text = satz as NSString
        var raus = satz as NSString
        // Von hinten nach vorn, damit die Bereiche davor stimmen bleiben
        for treffer in wort.matches(in: satz, range: NSRange(location: 0, length: text.length))
            .reversed() {
            let w = text.substring(with: treffer.range)
            guard let zahl = zahlwort(w) else { continue }
            if ["eine", "einen", "einem"].contains(w.lowercased()) {
                let rest = text.substring(from: NSMaxRange(treffer.range))
                guard rest.range(of: #"^\s*(euro|cent|€)"#,
                                 options: [.regularExpression, .caseInsensitive]) != nil else {
                    continue
                }
            }
            raus = raus.replacingCharacters(in: treffer.range, with: String(zahl)) as NSString
        }
        return raus as String
    }

    /// Cent aus einer Zahl oder einem Text wie 42,80 oder 42.80 oder 1.234,50.
    static func betrag(_ wert: Any?) -> Int? {
        // Ein JSON true ist keine Zahl. Gefragt wird nach dem Typ und nicht mit
        // is Bool, denn Swift hält auch die Zahl 1 für true, und genau ein Euro
        // wurde so abgelehnt (2026-10-05).
        if let zahl = wert as? NSNumber, CFGetTypeID(zahl) != CFBooleanGetTypeID() {
            return Int((zahl.doubleValue * 100).rounded())
        }
        guard var text = (wert as? String)?.trimmingCharacters(in: .whitespaces) else { return nil }
        text = text.replacingOccurrences(of: "€", with: "")
            .trimmingCharacters(in: .whitespaces)
        // 3.200 ist dreitausendzweihundert, Cent haben nie drei Stellen
        if !text.contains(","),
           text.range(of: #"^\d{1,3}(\.\d{3})+$"#, options: .regularExpression) != nil {
            text = text.replacingOccurrences(of: ".", with: "")
        }
        if text.contains(",") {
            // Deutsch, Punkte gliedern Tausender, das Komma trennt die Cent
            text = text.replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: ",", with: ".")
        }
        guard let zahl = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        return NSDecimalNumber(decimal: zahl * 100).rounding(accordingToBehavior: nil).intValue
    }

    /// Die ersten zehn Zeichen, wenn sie ein Tag sind. So geht auch ein
    /// Zeitstempel wie 2026-09-27T10:15:00+02:00 durch.
    static func tag(_ text: String) -> String? {
        let kopf = String(text.prefix(10))
        guard Datumsformat.iso.date(from: kopf) != nil,
              Datumsformat.iso.string(from: Datumsformat.iso.date(from: kopf)!) == kopf else {
            return nil
        }
        return kopf
    }

    static func wahr(_ wert: Any?) -> Bool {
        if let schalter = wert as? Bool { return schalter }
        if let zahl = wert as? NSNumber { return zahl.intValue != 0 }
        if let text = (wert as? String)?.lowercased() { return ["ja", "true", "1"].contains(text) }
        return false
    }

    /// Verschiebt eine Datei in einen Unterordner, bei gleichem Namen mit Zähler.
    private static func verschieben(_ datei: URL, nach ziel: URL) {
        let dateien = FileManager.default
        try? dateien.createDirectory(at: ziel, withIntermediateDirectories: true)
        var neu = ziel.appendingPathComponent(datei.lastPathComponent)
        var zaehler = 2
        while dateien.fileExists(atPath: neu.path) {
            let stamm = datei.deletingPathExtension().lastPathComponent
            neu = ziel.appendingPathComponent("\(stamm) \(zaehler).json")
            zaehler += 1
        }
        try? dateien.moveItem(at: datei, to: neu)
    }

    // MARK: - Auskunft für das iPhone

    /// kategorien.json und stand.json neben der Datenbank. Geschrieben wird
    /// nur, was sich geändert hat, sonst lüde iCloud bei jedem Blättern neu.
    /// Liefert true, wenn etwas geschrieben wurde.
    @discardableResult
    static func auskunft(_ kern: Kern, neben datenbank: String) -> Bool {
        let ordner = URL(fileURLWithPath: datenbank).deletingLastPathComponent()
        let monat = Monat.von(kern.heute)
        let bild = kern.uebersicht(monat)

        let kategorien = ((try? kern.db.zeilen(
            "SELECT name FROM kategorien WHERE aktiv=1 ORDER BY favorit DESC, sortierung, name"))
            ?? []).compactMap { $0["name"]?.alsText }
        let toepfe = kern.toepfe(monat).map(\.zeile.name)

        var satz = "Diesen Monat bleiben \(Geld.euro(bild.verfuegbarCent))."
        let frei = kern.freiVerfuegbar()
        if let frei { satz += " Frei verfügbar sind \(Geld.euro(frei))." }
        if let warnung = bild.warnung { satz += " " + warnung }
        var stand: [String: Any] = [
            "monat": monat,
            "bleibt": euro(bild.verfuegbarCent),
            "satz": satz,
            "budget_ausgegeben_prozent": Int((bild.ausgabenAnteil * 100).rounded()),
            "monat_vorbei_prozent": Int((bild.monatAnteil * 100).rounded()),
        ]
        if let frei { stand["frei_verfuegbar"] = euro(frei) }
        if let konto = kern.kontostand() { stand["kontostand"] = euro(konto) }
        if let warnung = bild.warnung { stand["warnung"] = warnung }

        // Die Favoriten extra, die ganze Liste ist für eine Auswahl auf dem
        // iPhone zu lang
        let favoriten = ((try? kern.db.zeilen(
            "SELECT name FROM kategorien WHERE aktiv=1 AND favorit=1 ORDER BY sortierung, name "
            + "LIMIT 8")) ?? []).compactMap { $0["name"]?.alsText }
        let eins = schreiben(["kategorien": kategorien, "favoriten": favoriten, "toepfe": toepfe],
                             nach: ordner.appendingPathComponent("kategorien.json"))
        let zwei = schreiben(stand, nach: ordner.appendingPathComponent("stand.json"))
        return eins || zwei
    }

    /// Euro als Zahl mit zwei Stellen, über Decimal, damit 168.26 dasteht und
    /// nicht 168.25999999999999.
    private static func euro(_ cent: Int) -> NSDecimalNumber {
        NSDecimalNumber(decimal: Decimal(cent) / 100)
    }

    private static func schreiben(_ inhalt: [String: Any], nach ziel: URL) -> Bool {
        guard let daten = try? JSONSerialization.data(
            withJSONObject: inhalt, options: [.prettyPrinted, .sortedKeys]) else { return false }
        if (try? Data(contentsOf: ziel)) == daten { return false }
        return (try? daten.write(to: ziel, options: .atomic)) != nil
    }
}
