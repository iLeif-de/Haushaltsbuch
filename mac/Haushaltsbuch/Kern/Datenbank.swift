import Foundation
import SQLite3

/// Schmale Hülle um SQLite, ohne Fremdpaket, damit das Programm ohne
/// Paketverwaltung baut.
///
/// Das Schema gehört seit dem 26. September 2026 diesem Programm, es liegt als
/// schema.sql neben dieser Datei. Eine Änderung daran braucht einen Eintrag in
/// `Migrationen.alle` und die angehobene Zahl in `schemaFassung`, im Kopf von
/// schema.sql und in dessen INSERT auf schema_version. Die Migrationen 3 bis 10
/// kommen unverändert aus haushalt/db.py, damit sich jede Datenbank öffnen
/// lässt, die je ein Programm in Python angelegt hat.
enum Wert {
    case text(String)
    case zahl(Int64)
    case komma(Double)
    case leer

    var alsText: String? {
        if case .text(let t) = self { return t }
        return nil
    }

    var alsZahl: Int64? {
        switch self {
        case .zahl(let z): return z
        case .komma(let k): return Int64(k)
        case .text(let t): return Int64(t)
        case .leer: return nil
        }
    }

    var alsGanz: Int? {
        guard let z = alsZahl else { return nil }
        return Int(z)
    }

    var istWahr: Bool { (alsZahl ?? 0) != 0 }
}

struct DbFehler: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

final class Datenbank {
    /// Die Schemafassung, für die der Code geschrieben ist, dieselbe Zahl wie im
    /// Kopf von schema.sql und in dessen INSERT auf schema_version.
    static let schemaFassung = 10

    /// Siehe Migrationen.alle. Veränderlich nur, damit die Prüfungen eine
    /// kaputte Migration unterschieben können.
    nonisolated(unsafe) static var migrationen: [Int: String] = Migrationen.alle

    private let zeiger: OpaquePointer
    /// SQLite soll den übergebenen Text selbst kopieren.
    private static let fluechtig = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Öffnet die Datenbank und legt sie an, falls es sie noch nicht gibt, wie
    /// `verbinden` in haushalt/db.py. Das Schema kommt aus schema.sql, das im
    /// Bündel liegt und dieselbe Datei ist wie im Projekt. Eine vorhandene
    /// Datenbank wird nie angefasst, migriert wird hier nichts, das bleibt beim
    /// Programm in Python.
    init(pfad: String) throws {
        let ordner = (pfad as NSString).deletingLastPathComponent
        if !ordner.isEmpty, !FileManager.default.fileExists(atPath: ordner) {
            try? FileManager.default.createDirectory(atPath: ordner,
                                                     withIntermediateDirectories: true)
        }
        var offen: OpaquePointer?
        let ergebnis = sqlite3_open_v2(
            pfad, &offen, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard ergebnis == SQLITE_OK, let offen else {
            let grund = offen.map { String(cString: sqlite3_errmsg($0)) } ?? "nicht lesbar"
            sqlite3_close(offen)
            throw DbFehler(text: "Die Datenbank \(pfad) lässt sich nicht öffnen. \(grund)")
        }
        zeiger = offen
        // Fremdschlüssel gelten je Verbindung und müssen jedes Mal an
        sqlite3_exec(zeiger, "PRAGMA foreign_keys = ON", nil, nil, nil)
        // Das SQLite von macOS behält -wal und -shm nach dem Schließen, Apple
        // hat das dort ab Werk eingeschaltet. Das SQLite in Python tut es nicht,
        // deshalb fiel es erst in Swift auf. Hier aus, sonst lägen neben der
        // Datenbank in iCloud immer drei Dateien (2026-09-26).
        var dauerhaft: Int32 = 0
        sqlite3_file_control(zeiger, "main", SQLITE_FCNTL_PERSIST_WAL, &dauerhaft)
        if try leer() {
            try schemaAnlegen()
            // schema.sql trägt die Fassung selbst ein, sie wird danach trotzdem
            // noch einmal geschrieben. Sonst hängt alles daran, dass beim
            // Anheben von schemaFassung auch die Zahl im Skript mitwandert.
            // Wird sie vergessen, legt schema.sql schon den neuen Stand an,
            // meldet aber den alten, und beim nächsten Öffnen läuft die
            // Migration darüber und scheitert an einer Tabelle, die es gibt.
            try schreiben("UPDATE einstellungen SET wert=? WHERE schluessel='schema_version'",
                          [.text(String(Self.schemaFassung))])
        } else {
            try migrieren(pfad: pfad)
        }
    }

    /// Steht die Datenbank noch ohne Tabellen da?
    private func leer() throws -> Bool {
        try zeilen("SELECT 1 AS da FROM sqlite_master WHERE type='table' AND name='buchungen'")
            .isEmpty
    }

    private func schemaAnlegen() throws {
        // Im Bündel liegt schema.sql als Beigabe. HAUSHALT_SCHEMA gibt es für
        // Läufe ohne Bündel, also für die Prüfungen ohne Fenster.
        let url = Bundle.main.url(forResource: "schema", withExtension: "sql")
            ?? ProcessInfo.processInfo.environment["HAUSHALT_SCHEMA"].map {
                URL(fileURLWithPath: $0)
            }
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw DbFehler(text: "Das Schema fehlt im Programm, die Datenbank kann nicht "
                           + "angelegt werden.")
        }
        var fehler: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(zeiger, text, nil, nil, &fehler) != SQLITE_OK {
            let grund = fehler.map { String(cString: $0) } ?? "unbekannt"
            sqlite3_free(fehler)
            throw DbFehler(text: "Die Datenbank ließ sich nicht anlegen. \(grund)")
        }
    }

    private var geschlossen = false

    /// Schließt die Verbindung. Ist es die letzte auf die Datei, überträgt
    /// SQLite dabei den Inhalt der WAL Nebendatei in die Hauptdatei und löscht
    /// -wal und -shm. Danach liegt nur noch eine Datei da, genau das braucht
    /// iCloud und die Anleitung zum Wiederherstellen.
    ///
    /// Muss beim Beenden des Programms ausdrücklich gerufen werden. deinit
    /// allein genügt nicht, macOS beendet den Prozess, ohne die Objekte
    /// aufzuräumen, und die Nebendateien blieben liegen (2026-09-26).
    func schliessen() {
        guard !geschlossen else { return }
        geschlossen = true
        sqlite3_close(zeiger)
    }

    deinit { schliessen() }

    /// Nach dem Schließen scheitert jeder Zugriff mit einem Fehler statt mit
    /// einem Absturz. Eine Ansicht, die beim Beenden noch einmal zeichnet,
    /// bekommt dann einfach keine Zahlen mehr.
    private func offen() throws {
        if geschlossen { throw DbFehler(text: "Die Datenbank ist geschlossen.") }
    }

    private func vorbereiten(_ sql: String, _ werte: [Wert]) throws -> OpaquePointer {
        try offen()
        var satz: OpaquePointer?
        guard sqlite3_prepare_v2(zeiger, sql, -1, &satz, nil) == SQLITE_OK, let satz else {
            throw DbFehler(text: fehlertext(sql))
        }
        for (i, wert) in werte.enumerated() {
            let stelle = Int32(i + 1)
            switch wert {
            case .text(let t): sqlite3_bind_text(satz, stelle, t, -1, Self.fluechtig)
            case .zahl(let z): sqlite3_bind_int64(satz, stelle, z)
            case .komma(let k): sqlite3_bind_double(satz, stelle, k)
            case .leer: sqlite3_bind_null(satz, stelle)
            }
        }
        return satz
    }

    private func fehlertext(_ sql: String) -> String {
        "\(String(cString: sqlite3_errmsg(zeiger)))\nSQL: \(sql)"
    }

    /// Liest Zeilen als Wörterbuch, Spaltenname auf Wert.
    func zeilen(_ sql: String, _ werte: [Wert] = []) throws -> [[String: Wert]] {
        let satz = try vorbereiten(sql, werte)
        defer { sqlite3_finalize(satz) }
        var raus: [[String: Wert]] = []
        while sqlite3_step(satz) == SQLITE_ROW {
            var zeile: [String: Wert] = [:]
            for spalte in 0..<sqlite3_column_count(satz) {
                let name = String(cString: sqlite3_column_name(satz, spalte))
                switch sqlite3_column_type(satz, spalte) {
                case SQLITE_INTEGER:
                    zeile[name] = .zahl(sqlite3_column_int64(satz, spalte))
                case SQLITE_FLOAT:
                    zeile[name] = .komma(sqlite3_column_double(satz, spalte))
                case SQLITE_NULL:
                    zeile[name] = .leer
                default:
                    if let roh = sqlite3_column_text(satz, spalte) {
                        zeile[name] = .text(String(cString: roh))
                    } else {
                        zeile[name] = .leer
                    }
                }
            }
            raus.append(zeile)
        }
        return raus
    }

    /// Schreibt und liefert die vergebene Zeilennummer.
    @discardableResult
    func schreiben(_ sql: String, _ werte: [Wert] = []) throws -> Int64 {
        let satz = try vorbereiten(sql, werte)
        defer { sqlite3_finalize(satz) }
        let ergebnis = sqlite3_step(satz)
        guard ergebnis == SQLITE_DONE || ergebnis == SQLITE_ROW else {
            throw DbFehler(text: fehlertext(sql))
        }
        return sqlite3_last_insert_rowid(zeiger)
    }

    /// Alles oder nichts. Bricht die Arbeit ab, bleibt keine halbe Buchung stehen.
    @discardableResult
    func inEinemStueck<E>(_ arbeit: () throws -> E) throws -> E {
        try schreiben("BEGIN")
        do {
            let ergebnis = try arbeit()
            try schreiben("COMMIT")
            return ergebnis
        } catch {
            _ = try? schreiben("ROLLBACK")
            throw error
        }
    }

    /// Führt ein Skript aus mehreren Anweisungen aus, wie executescript.
    func ausfuehren(_ skript: String) throws {
        try offen()
        var fehler: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(zeiger, skript, nil, nil, &fehler) != SQLITE_OK {
            let grund = fehler.map { String(cString: $0) } ?? fehlertext(skript)
            sqlite3_free(fehler)
            throw DbFehler(text: grund)
        }
    }

    // MARK: Sicherung

    /// Schreibt eine vollständige Kopie der offenen Datenbank nach `ziel`.
    ///
    /// Bewusst nicht als Dateikopie. Die Datenbank läuft im WAL Modus, die
    /// jüngsten Änderungen stehen dann in der Nebendatei und noch nicht in der
    /// Hauptdatei. Eine Dateikopie lässt sie weg, im Test fehlten so alle
    /// dreißig gerade geschriebenen Buchungen. Die Sicherungsschnittstelle von
    /// SQLite nimmt den WAL Inhalt mit und arbeitet auch bei offener
    /// Verbindung sauber.
    func sicherungSchreiben(nach ziel: String) throws {
        try offen()
        let dateien = FileManager.default
        try dateien.createDirectory(atPath: (ziel as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
        // Erst unter einem Zwischennamen schreiben, dann umbenennen. Bräche die
        // Sicherung ab, bliebe sonst eine leere Datei stehen, die wie eine
        // Sicherung aussieht. Genau das ist in Python einmal passiert.
        let zwischen = ziel + ".teil"
        for rest in ["", "-wal", "-shm"] { try? dateien.removeItem(atPath: zwischen + rest) }
        var kopie: OpaquePointer?
        guard sqlite3_open_v2(zwischen, &kopie, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                              nil) == SQLITE_OK, let kopie else {
            sqlite3_close(kopie)
            throw DbFehler(text: "Die Sicherung \(ziel) lässt sich nicht anlegen.")
        }
        guard let lauf = sqlite3_backup_init(kopie, "main", zeiger, "main") else {
            let grund = String(cString: sqlite3_errmsg(kopie))
            sqlite3_close(kopie)
            throw DbFehler(text: "Die Sicherung ist gescheitert. \(grund)")
        }
        let ergebnis = sqlite3_backup_step(lauf, -1)
        sqlite3_backup_finish(lauf)
        guard ergebnis == SQLITE_DONE else {
            let grund = String(cString: sqlite3_errmsg(kopie))
            sqlite3_close(kopie)
            try? dateien.removeItem(atPath: zwischen)
            throw DbFehler(text: "Die Sicherung ist gescheitert. \(grund)")
        }
        // Die Kopie erbt den WAL Modus der Quelle. Eine Sicherung soll aber eine
        // einzelne, für sich vollständige Datei sein, die man wegtragen kann.
        sqlite3_exec(kopie, "PRAGMA journal_mode = DELETE", nil, nil, nil)
        sqlite3_close(kopie)
        for rest in ["-wal", "-shm"] { try? dateien.removeItem(atPath: zwischen + rest) }
        // rename ersetzt ein vorhandenes Ziel in einem Schritt
        guard rename(zwischen, ziel) == 0 else {
            throw DbFehler(text: "Die Sicherung ließ sich nicht nach \(ziel) legen.")
        }
    }

    // MARK: Migrationen

    /// Führt alle fehlenden Migrationen der Reihe nach aus, von jeder älteren
    /// Fassung an.
    ///
    /// Vorher entsteht eine Sicherung über `sicherungSchreiben`, nicht als
    /// Dateikopie, siehe dort. Jede Migration läuft in einer eigenen
    /// Transaktion zusammen mit dem Anheben von schema_version. Scheitert eine,
    /// bleibt die Datei vollständig auf der Fassung davor. In Python wurde die
    /// Fassung früher erst nach allen Migrationen geschrieben (verworfen
    /// 2026-09-18), eine halb gelaufene Reihe ließ sich dann nie mehr öffnen.
    private func migrieren(pfad: String) throws {
        let fassung = Int(try einstellung("schema_version") ?? "0") ?? 0
        let fehlende = Self.migrationen.keys.filter { $0 > fassung }.sorted()
        guard !fehlende.isEmpty else { return }
        if pfad != ":memory:" {
            let sicherung = "\(pfad).vor-v\(Self.schemaFassung)"
            if !FileManager.default.fileExists(atPath: sicherung) {
                try sicherungSchreiben(nach: sicherung)
            }
        }
        for nummer in fehlende {
            guard let skript = Self.migrationen[nummer] else { continue }
            do {
                try ausfuehren("BEGIN;\n" + skript + "\n"
                    + "UPDATE einstellungen SET wert='\(nummer)' WHERE schluessel='schema_version';\n"
                    + "COMMIT;")
            } catch {
                // Noch in der Transaktion, also zurück auf die Fassung davor
                if sqlite3_get_autocommit(zeiger) == 0 {
                    sqlite3_exec(zeiger, "ROLLBACK", nil, nil, nil)
                }
                throw error
            }
        }
    }

    func einstellung(_ schluessel: String) throws -> String? {
        try zeilen("SELECT wert FROM einstellungen WHERE schluessel = ?",
                   [.text(schluessel)]).first?["wert"]?.alsText
    }
}
