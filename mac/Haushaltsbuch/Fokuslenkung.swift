import Foundation
import Observation

/// Wer den Fokus hat, und zwar bereichsweise. Das Fenster hat drei Bereiche,
/// die Leiste links, den Inhalt in der Mitte und die Schnelleingabe rechts.
///
/// **Tab bleibt im Bereich, Option Tab wechselt ihn.** Innerhalb eines Bereichs
/// läuft Tab im Ring, mit Umschalt rückwärts. Option Tab geht zum nächsten
/// Bereich und setzt den Fokus dort auf sein erstes Glied, mit Umschalt zum
/// vorigen. Das ist genau das, was in Flet nicht zu bauen war, dort läuft Tab
/// stur über den ganzen Steuerelementbaum.
///
/// Jeder Bereich hat seinen eigenen `FocusState`, deshalb braucht es diese
/// gemeinsame Stelle. `zone` sagt, wer gerade dran ist, `wunsch` ist ein Zähler,
/// den die Bereiche beobachten. Springt er, setzt der angesprochene Bereich
/// seinen Fokus auf den Anfang. Nur der Wechsel erhöht den Zähler, das bloße
/// Melden tut es nicht, sonst schaukelt sich das auf.
@Observable
final class Fokuslenkung {
    enum Zone: CaseIterable {
        case leiste, inhalt, eingabe
    }

    private(set) var zone: Zone = .eingabe
    private(set) var wunsch = 0

    /// Ein Bereich meldet, dass der Fokus bei ihm angekommen ist, etwa durch
    /// einen Mausklick. Das verschiebt nur die Buchführung.
    func meldet(_ zone: Zone) {
        self.zone = zone
    }

    /// Option Tab, einen Bereich weiter oder zurück.
    func wechseln(_ richtung: Int) {
        let zonen = Zone.allCases
        guard let jetzt = zonen.firstIndex(of: zone) else { return }
        zone = zonen[((jetzt + richtung) % zonen.count + zonen.count) % zonen.count]
        wunsch += 1
    }

    /// Gezielt in einen Bereich, etwa Cmd N in die Schnelleingabe.
    func hin(_ zone: Zone) {
        self.zone = zone
        wunsch += 1
    }
}

/// Die Tasten, die überall gleich wirken. Steht hier, damit jeder Bereich
/// denselben Code benutzt und sich niemand eine eigene Regel ausdenkt.
enum Tasten {
    /// Umschalt Tab kommt auf dem Mac als eigenes Zeichen an, Back Tab, 0x19,
    /// und nicht als Tab mit Umschalt (2026-09-24).
    static let backTab = "\u{19}"

    /// Ist das ein Tab, und in welche Richtung? Liefert nil bei anderen Tasten.
    static func tabRichtung(_ druck: KeyPressAehnlich) -> Int? {
        if druck.zeichen == backTab { return -1 }
        guard druck.istTab else { return nil }
        return druck.mitUmschalt ? -1 : 1
    }
}

/// Damit `Tasten` ohne SwiftUI auskommt und prüfbar bleibt.
protocol KeyPressAehnlich {
    var zeichen: String { get }
    var istTab: Bool { get }
    var mitUmschalt: Bool { get }
    var mitOption: Bool { get }
}
