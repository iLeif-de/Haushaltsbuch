import SwiftUI

/// Bindeglied zwischen SwiftUIs `KeyPress` und `Tasten`. Zwei Zeilen Anpassung,
/// dafür bleibt die Regel für Tab an einer Stelle und ohne SwiftUI prüfbar.
extension KeyPress: KeyPressAehnlich {
    var zeichen: String { characters }
    var istTab: Bool { key == .tab }
    var mitUmschalt: Bool { modifiers.contains(.shift) }
    var mitOption: Bool { modifiers.contains(.option) }
}

/// Was ein Bereich mit einem Tastendruck macht, soweit es alle Bereiche
/// gleich machen. Der Bereich gibt seine eigene Kette und sein Fokusfeld dazu.
enum Bereichstasten {
    /// Behandelt Tab und Option Tab. Liefert true, wenn die Taste verbraucht ist.
    ///
    /// - `ring`: einen Schritt in der eigenen Kette, im Ring
    /// - `wechsel`: einen Bereich weiter, also Option Tab
    static func tab(_ druck: KeyPress, ring: (Int) -> Void, wechsel: (Int) -> Void) -> Bool {
        guard let richtung = Tasten.tabRichtung(druck) else { return false }
        if druck.mitOption {
            wechsel(richtung)
        } else {
            ring(richtung)
        }
        return true
    }
}
