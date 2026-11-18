import Foundation

/// Texte, die aus gerechneten Zahlen entstehen. Sie stehen hier und nicht in der
/// Ansicht, damit sie ohne Fenster gegen die Fassung in Python geprüft werden
/// können, siehe mac/README.md, Abschnitt Geprüft gegen das Orakel.
enum Texte {
    /// Die Kalenderwoche nach ISO, wie `isocalendar().week` in Python. Über den
    /// Donnerstag der Woche, der bestimmt das Jahr, zu dem die Woche gehört.
    static func kalenderwoche(_ tag: String) -> Int {
        let montag = Tage.plus(tag, -Tage.wochentag(tag))
        let donnerstag = Tage.plus(montag, 3)
        let jahr = String(donnerstag.prefix(4))
        return (Tage.zahl(donnerstag) - Tage.zahl(jahr + "-01-01")) / 7 + 1
    }

    /// Lange Bezeichnung für den Kopf, etwa "KW 38, 14.09. bis 20.09.2026".
    static func zeitraumName(_ art: Zeitraumart, _ stichtag: String) -> String {
        switch art {
        case .woche:
            let montag = Tage.plus(stichtag, -Tage.wochentag(stichtag))
            let sonntag = Tage.plus(montag, 6)
            return "KW \(kalenderwoche(stichtag)), \(Datumsformat.tagUndMonat(montag)) bis "
                + Datumsformat.lesbar(sonntag)
        case .monat:
            return Datumsformat.monatsname(String(stichtag.prefix(7)))
        case .jahr:
            return String(stichtag.prefix(4))
        }
    }

    /// Kurze Bezeichnung unter einem Balken, etwa "KW 38", "Sep" oder "2026".
    static func zeitraumKurz(_ art: Zeitraumart, _ von: String) -> String {
        switch art {
        case .woche: return "KW \(kalenderwoche(von))"
        case .monat: return String(Datumsformat.monatName(String(von.prefix(7))).prefix(3))
        case .jahr: return String(von.prefix(4))
        }
    }

    /// Die Beschreibung eines Topfs, dieselben Teile in derselben Reihenfolge
    /// wie `zeile` in ui/toepfe.py.
    static func topfBeschreibung(_ topf: Topf, monat: String) -> String {
        var teile: [String] = []
        if let ziel = topf.zielCent, ziel > 0 {
            teile.append("\(Geld.euro(topf.stand)) von \(Geld.euro(ziel))")
        } else {
            teile.append(Geld.euro(topf.stand))
        }
        teile.append("Rate \(Geld.euro(topf.rateCent)) im Monat")
        // Die Rate des laufenden Monats steckt im Budget dieses Monats schon
        // drin, eine Aufstockung oder Entnahme wirkt darum erst ab dem nächsten.
        // Ohne diesen Zusatz sähe es aus, als hätte sich nichts getan.
        if abs(topf.naechsteRateCent - topf.rateCent) > 1 {
            let naechster = Monat.plus(monat, 1)
            teile.append("ab \(Datumsformat.monatName(naechster)) \(Geld.euro(topf.naechsteRateCent))")
        }
        if let voll = topf.vollInMonaten {
            teile.append("voll in \(voll) Monaten")
        }
        if topf.pausiert {
            teile.append("pausiert")
        }
        return teile.joined(separator: ", ")
    }
}
