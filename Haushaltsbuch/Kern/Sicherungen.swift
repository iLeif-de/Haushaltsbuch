import Foundation

/// Sicherungen der Datenbank, wie `monatssicherung_anlegen` in app.py und der
/// Knopf in ui/einstellungen.py. Geschrieben wird immer über
/// `Datenbank.sicherungSchreiben`, also über die Sicherungsschnittstelle von
/// SQLite und nie als Dateikopie, siehe dort.
///
/// Wiederhergestellt wird von Hand im Finder, bei beendetem Programm. Einen
/// Knopf dafür gibt es bewusst nicht, auch keinen, der den Ordner öffnet. Wer
/// dorthin will, will meist wiederherstellen, und ein Knopf im laufenden
/// Programm lockte genau in die falsche Reihenfolge.
enum Sicherungen {
    /// So viele Sicherungen bleiben im Ordner, die ältesten gehen zuerst.
    static let behalten = 12

    /// Der Anfang jedes Dateinamens. Fassung 1.2 schrieb haushalt-, ihre
    /// Sicherungen bleiben in ihrem eigenen Ordner liegen.
    static let vorsilbe = "haushaltsbuch-"

    /// Einmal im Monat eine Sicherung, haushaltsbuch-JJJJ-MM.sqlite. Eine leere
    /// Datei gilt als nicht vorhanden, sonst wiese ein einmal misslungener
    /// Versuch den Monat für immer als gesichert aus. Liefert die neue Datei,
    /// oder nil, wenn der Monat schon gesichert war.
    @discardableResult
    static func monatlich(_ db: Datenbank, heute: Date, ordner: URL) throws -> URL? {
        let ziel = ordner.appendingPathComponent("\(vorsilbe)\(Monat.von(heute)).sqlite")
        var geschrieben: URL?
        if groesse(ziel) == 0 {
            try db.sicherungSchreiben(nach: ziel.path)
            geschrieben = ziel
        }
        try aufraeumen(ordner)
        return geschrieben
    }

    /// Eine Sicherung sofort, haushaltsbuch-JJJJ-MM-TT.sqlite. Eine vom selben Tag
    /// wird ersetzt.
    static func jetzt(_ db: Datenbank, heute: Date, ordner: URL) throws -> URL {
        let ziel = ordner.appendingPathComponent(
            "\(vorsilbe)\(Datumsformat.iso.string(from: heute)).sqlite")
        try db.sicherungSchreiben(nach: ziel.path)
        try aufraeumen(ordner)
        return ziel
    }

    /// Behält die jüngsten zwölf, nach Namen sortiert, wie app.py. Die
    /// Sicherungen von Hand zählen mit, beide Sorten liegen im selben Ordner.
    static func aufraeumen(_ ordner: URL) throws {
        let namen = (try? FileManager.default.contentsOfDirectory(atPath: ordner.path)) ?? []
        let sicherungen = namen.filter { $0.hasPrefix(vorsilbe) && $0.hasSuffix(".sqlite") }
            .sorted()
        for veraltet in sicherungen.dropLast(behalten) {
            try FileManager.default.removeItem(at: ordner.appendingPathComponent(veraltet))
        }
    }

    private static func groesse(_ datei: URL) -> Int {
        let werte = try? FileManager.default.attributesOfItem(atPath: datei.path)
        return (werte?[.size] as? NSNumber)?.intValue ?? 0
    }
}
