import Foundation

/// Export als CSV, wie `csv_schreiben` in ui/hilfen.py. Semikolon als Trenner,
/// wie Numbers und Excel es in Deutschland erwarten. Die Gruppe ist die
/// wirksame, also die, unter der die Auswertung zählt.
enum Ausfuhr {
    static let spalten = ["Datum", "Betrag in Euro", "Kategorien", "Gruppe", "Notiz",
                          "Posten", "Art", "Status"]

    /// Schreibt die Buchungen und liefert den Pfad zurück. `zusatz` sind
    /// fertige Zeilen, die unten angehängt werden, etwa Kontostand und
    /// Rücklagen, siehe kontoZeilen.
    @discardableResult
    static func csv(_ buchungen: [Buchung], nach ziel: URL, zusatz: [[String]] = []) throws -> URL {
        var zeilen = [reihe(spalten)]
        for b in buchungen {
            zeilen.append(reihe([
                b.datum,
                Geld.ohneEuro(b.betragCent),
                b.kategorie,
                b.gruppe ?? "",
                b.notiz ?? "",
                b.posten ?? "",
                b.art,
                b.status,
            ]))
        }
        zeilen += zusatz.map(reihe)
        let text = zeilen.joined(separator: "\r\n") + "\r\n"
        try text.write(to: ziel, atomically: true, encoding: .utf8)
        return ziel
    }

    /// Ein Feld wird eingefasst, wenn es Semikolon, Anführungszeichen oder einen
    /// Zeilenumbruch enthält, genau wie csv.writer es macht.
    private static func reihe(_ felder: [String]) -> String {
        felder.map { feld in
            if feld.contains(";") || feld.contains("\"") || feld.contains("\n")
                || feld.contains("\r") {
                return "\"" + feld.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return feld
        }.joined(separator: ";")
    }

    /// Kontostand und Rücklagen zum Ende des Zeitraums, als Zeilen für den
    /// großen Export, wie in ui/einstellungen.py. Ein Blick auf einen
    /// vergangenen Monat zeigt so auch dessen damaligen Stand. Ohne Bis gilt
    /// der heutige Tag. Die Spalten sind dieselben, der Name steht unter Notiz.
    static func kontoZeilen(_ kern: Kern, bis: String?) -> [[String]] {
        let stichtag = bis ?? Datumsformat.iso.string(from: kern.heute)
        var zeilen: [[String]] = []
        if let stand = kern.kontostand(bis: stichtag) {
            zeilen.append([stichtag, Geld.ohneEuro(stand), "", "", "Kontostand", "",
                           "kontostand", ""])
        }
        for topf in kern.toepfe(String(stichtag.prefix(7))) {
            zeilen.append([stichtag, Geld.ohneEuro(topf.stand), "", "", topf.name, "",
                           "ruecklage", ""])
        }
        return zeilen
    }

    /// Der Dateiname für den großen Export, wie in ui/einstellungen.py.
    /// Ohne Eingrenzung das heutige Datum, sonst die Grenzen, eine offene
    /// Grenze heißt anfang oder heute.
    static func gesamtZiel(von: String?, bis: String?, heute: Date) -> URL {
        let zusatz = (von != nil || bis != nil)
            ? "\(von ?? "anfang")-bis-\(bis ?? "heute")"
            : Datumsformat.iso.string(from: heute)
        return downloads.appendingPathComponent("haushaltsbuch-buchungen-\(zusatz).csv")
    }

    private static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    /// Wohin exportiert wird, in den Ordner Downloads, wie in der Fassung mit Flet.
    static func ziel(name: String, von: String, bis: String) -> URL {
        let sauber = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .components(separatedBy: CharacterSet(charactersIn:
                "abcdefghijklmnopqrstuvwxyz0123456789-äöüß").inverted)
            .joined()
        let datei = "haushaltsbuch-\(sauber.isEmpty ? "auswahl" : sauber)-\(von)-bis-\(bis).csv"
        return downloads.appendingPathComponent(datei)
    }
}
