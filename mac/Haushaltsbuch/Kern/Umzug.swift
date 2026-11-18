import Foundation

/// Der Umzug der Datenbank von Fassung 1.2 an den Ort von Fassung 2.0, beim
/// ersten Start nach einer Rückfrage und nur dann, wenn es am neuen Ort noch
/// keine gibt (2026-09-26). Ohne ihn säße, wer auf 2.0 wechselt, vor einem leeren
/// Programm und dem Einrichtungsassistenten.
///
/// Kopiert wird über die Sicherungsschnittstelle von SQLite und nicht als
/// Datei, siehe Datenbank.sicherungSchreiben. Die alte Datei bekommt danach
/// den Zusatz .umgezogen. Fassung 1.2 findet sie dann nicht mehr und fängt
/// leer an, statt unbemerkt auf dem alten Stand weiterzuarbeiten, während die
/// Buchungen in 2.0 landen. Gelöscht wird nichts.
enum Umzug {
    /// Steht ein Umzug an? Am neuen Ort noch nichts, am alten eine Datenbank.
    static func steht(von alt: String, nach neu: String) -> Bool {
        !FileManager.default.fileExists(atPath: neu) && FileManager.default.fileExists(atPath: alt)
    }

    /// Liefert true, wenn umgezogen wurde.
    @discardableResult
    static func wennNoetig(von alt: String, nach neu: String) throws -> Bool {
        let dateien = FileManager.default
        guard steht(von: alt, nach: neu) else { return false }
        do {
            // Öffnen migriert eine ältere Fassung gleich mit
            let quelle = try Datenbank(pfad: alt)
            try quelle.sicherungSchreiben(nach: neu)
        }
        let umgezogen = alt + ".umgezogen"
        for rest in ["", "-wal", "-shm"] where dateien.fileExists(atPath: alt + rest) {
            try? dateien.removeItem(atPath: umgezogen + rest)
            try dateien.moveItem(atPath: alt + rest, toPath: umgezogen + rest)
        }
        return true
    }
}
