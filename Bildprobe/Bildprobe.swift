import AppKit
import SwiftUI

/// Wegwerfprogramm, das eine Ansicht des Haushaltsbuchs in eine PNG Datei malt,
/// ohne dass jemand hinsieht. Damit lässt sich eine Änderung am Aufbau prüfen,
/// ohne sie von Hand aufzurufen (2026-09-25).
///
///     HAUSHALT_DB=<kopie> Bildprobe auswertung /tmp/bild.png [breite] [hoehe]
///
/// Ansichten sind uebersicht, auswertung, posten, toepfe, mehr, eingabe, umzug
/// und einrichtung.
///
/// Gemalt wird über ein Fenster weit außerhalb des Bildschirms und
/// cacheDisplay, nicht über ImageRenderer. Der malt eine ScrollView leer, und
/// fast jede Ansicht hier steckt in einer (2026-09-25).
@main
struct Bildprobe {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let teile = Array(CommandLine.arguments.dropFirst())
        guard teile.count >= 2 else {
            print("Aufruf: Bildprobe <ansicht> <datei.png> [breite] [hoehe]")
            exit(1)
        }
        let breite = Double(teile.count > 2 ? teile[2] : "") ?? 980
        let hoehe = Double(teile.count > 3 ? teile[3] : "") ?? 700
        MainActor.assumeIsolated {
            malen(teile[0], nach: teile[1], breite: breite, hoehe: hoehe)
        }
    }

    @MainActor
    private static func malen(_ name: String, nach datei: String,
                              breite: Double, hoehe: Double) {
        let speicher = Speicher()
        let lenkung = Fokuslenkung()
        let ansicht = AnyView(
            Group {
                switch name {
                case "uebersicht": Uebersichtsansicht(speicher: speicher, lenkung: lenkung)
                case "auswertung": Auswertungsansicht(speicher: speicher, lenkung: lenkung)
                case "posten": Postenansicht(speicher: speicher, lenkung: lenkung)
                case "toepfe": Toepfeansicht(speicher: speicher, lenkung: lenkung)
                case "mehr": Einstellungenansicht(speicher: speicher, lenkung: lenkung)
                case "eingabe": Schnelleingabe(speicher: speicher, lenkung: lenkung)
                case "umzug": Umzugsansicht(speicher: speicher) {}
                default: Einrichtungsansicht(speicher: speicher) {}
                }
            }
            .frame(width: breite, height: hoehe)
        )

        let fenster = NSWindow(contentRect: NSRect(x: -9000, y: -9000,
                                                   width: breite, height: hoehe),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        fenster.contentView = NSHostingView(rootView: ansicht)
        fenster.orderFrontRegardless()

        // Ein paar Umläufe, sonst sind Liste und Diagramm noch nicht gesetzt.
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        guard let inhalt = fenster.contentView,
              let karte = inhalt.bitmapImageRepForCachingDisplay(in: inhalt.bounds) else {
            print("kein Bild")
            exit(2)
        }
        inhalt.cacheDisplay(in: inhalt.bounds, to: karte)
        guard let png = karte.representation(using: .png, properties: [:]) else {
            print("kein PNG")
            exit(2)
        }
        try? png.write(to: URL(fileURLWithPath: datei))
        print("geschrieben nach \(datei)")
        exit(0)
    }
}
