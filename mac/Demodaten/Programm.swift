import Foundation

/// Legt eine Demodatenbank an, der Nachfolger von demo_daten.py.
///
///     Demodaten [--ersetzen] <pfad>
///
/// Eine vorhandene Datei wird nur mit --ersetzen überschrieben. Die echte
/// Datenbank, am Ort von 2.0 wie von 1.2, fasst das Werkzeug nie an. Der
/// bequeme Weg ist mac/demo.sh, das baut, anlegt und das Programm damit
/// startet.
@main
struct Programm {
    static func main() {
        var teile = Array(CommandLine.arguments.dropFirst())
        let ersetzen = teile.contains("--ersetzen")
        teile.removeAll { $0 == "--ersetzen" }
        guard let pfad = teile.first else {
            fehler("Aufruf: Demodaten [--ersetzen] <pfad zur neuen Datenbank>")
        }
        let voll = URL(fileURLWithPath: pfad).standardizedFileURL.path
        guard voll != Pfade.standard, voll != Pfade.alt else {
            fehler("Das ist die echte Datenbank, dort wird keine Demo angelegt.")
        }
        let dateien = FileManager.default
        if dateien.fileExists(atPath: voll) {
            guard ersetzen else {
                fehler("\(voll) gibt es schon. Mit --ersetzen wird sie überschrieben.")
            }
            for rest in ["", "-wal", "-shm"] { try? dateien.removeItem(atPath: voll + rest) }
        }
        do {
            let bericht = try Demodaten.anlegen(in: try Datenbank(pfad: voll), heute: Date())
            ausgeben(bericht, pfad: voll)
        } catch {
            fehler("Die Demodaten ließen sich nicht anlegen. \(error.localizedDescription)")
        }
    }

    private static func ausgeben(_ b: Demodaten.Bericht, pfad: String) {
        print("Demodatenbank liegt unter \(pfad)")
        print("  Monat \(b.monat), bleiben \(Geld.euro(b.bild.verfuegbarCent)), "
              + "variabel \(Geld.euro(-b.bild.variabelCent))")
        print("  Warnung \(b.bild.warnung ?? "keine")")
        if let fehlt = b.bisZurWarnung {
            print("  Ab etwa \(Geld.euro(fehlt)) weiterer Ausgabe im Monatsbudget, etwa als "
                  + "Lebensmittel, warnt die Übersicht.")
        }
    }

    private static func fehler(_ text: String) -> Never {
        FileHandle.standardError.write(Data((text + "\n").utf8))
        exit(1)
    }
}
