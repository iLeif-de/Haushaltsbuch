import Foundation

/// Beträge werden überall gleich geschrieben, wie kern.euro in Python.
/// Cent als Ganzzahl hinein, "1.234,56 €" heraus.
enum Geld {
    /// Von Hand gesetzt und nicht über einen NumberFormatter. Foundation
    /// schreibt ein geschütztes Leerzeichen vor das Eurozeichen, kern.euro ein
    /// gewöhnliches. Dann stimmen zwei Texte, die gleich aussehen, nicht
    /// überein, und der Vergleich mit dem Orakel in Python meldet Unterschiede,
    /// die keine sind (2026-09-24). Also genau dieselbe Regel wie dort.
    static func euro(_ cent: Int) -> String {
        let vorzeichen = cent < 0 ? "-" : ""
        let betrag = abs(cent)
        var ganze = String(betrag / 100)
        // Tausenderpunkte von rechts nach links
        var stelle = ganze.count - 3
        while stelle > 0 {
            ganze.insert(".", at: ganze.index(ganze.startIndex, offsetBy: stelle))
            stelle -= 3
        }
        return vorzeichen + ganze + String(format: ",%02d €", betrag % 100)
    }

    /// Wie euro, aber ohne Währungszeichen, für ein Feld, in das getippt wird.
    static func ohneEuro(_ cent: Int) -> String {
        euro(cent).replacingOccurrences(of: " €", with: "")
    }

    /// Liest eine getippte Zahl, mit Komma oder Punkt, und liefert Cent.
    /// Leerer Text oder Unsinn ergibt nil, dann wird nichts gebucht.
    static func cent(aus text: String) -> Int? {
        let sauber = text
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard !sauber.isEmpty, let betrag = Double(sauber), betrag != 0 else { return nil }
        // Runden statt abschneiden, 0,1 + 0,2 ist in Gleitkomma nicht 0,3
        return Int((betrag * 100).rounded())
    }
}

/// Datumsformate der Datenbank, ISO, und der Anzeige, deutsch.
enum Datumsformat {
    static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func monat(_ datum: Date) -> String {
        String(iso.string(from: datum).prefix(7))
    }

    /// "2026-09-04" wird zu "04.09.2026". Von Hand gesetzt und nicht über einen
    /// Formatierer, der lässt die führende Null am Tag weg, datum_zeigen in
    /// ui/hilfen.py füllt sie auf (2026-09-24).
    static func lesbar(_ isoDatum: String) -> String {
        let teile = isoDatum.split(separator: "-")
        guard teile.count == 3 else { return isoDatum }
        return "\(teile[2]).\(teile[1]).\(teile[0])"
    }

    /// Nur der Monatsname, ohne Jahr, etwa "Oktober".
    static func monatName(_ monat: String) -> String {
        guard let d = iso.date(from: monat + "-01") else { return monat }
        return d.formatted(.dateTime.month(.wide))
    }

    /// Nur Tag und Monat, wie in der Buchungsliste, etwa "24.09.".
    static func tagUndMonat(_ isoDatum: String) -> String {
        let teile = isoDatum.split(separator: "-")
        guard teile.count == 3 else { return isoDatum }
        return "\(teile[2]).\(teile[1])."
    }

    static func monatsname(_ monat: String) -> String {
        guard let d = iso.date(from: monat + "-01") else { return monat }
        return d.formatted(.dateTime.month(.wide).year())
    }
}
