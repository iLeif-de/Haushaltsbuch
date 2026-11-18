import Foundation

/// Tagesrechnung auf Datumstexten, ohne Kalender und ohne Zeitzone.
///
/// Der erste Versuch rechnete mit `Calendar` auf einem über `DateFormatter`
/// gelesenen Datum. Der Formatierer liest örtlich, der Kalender rechnete in UTC,
/// und die Woche lag einen Tag daneben (2026-09-24). Ein Datum in der Datenbank
/// ist aber gar kein Zeitpunkt, sondern ein Kalendertag. Also wird er auch so
/// gerechnet, als Tageszahl seit dem 1. Januar 1970, nach dem bekannten
/// Verfahren von Howard Hinnant. Dieselbe Rechnung wie `date` in Python.
enum Tage {
    /// Tage seit dem 1. Januar 1970, negativ davor.
    static func zahl(_ iso: String) -> Int {
        let teile = iso.split(separator: "-")
        guard teile.count >= 3, var jahr = Int(teile[0]),
              let monat = Int(teile[1]), let tag = Int(teile[2]) else { return 0 }
        if monat <= 2 { jahr -= 1 }
        let aera = (jahr >= 0 ? jahr : jahr - 399) / 400
        let jahrInAera = jahr - aera * 400
        let tagImJahr = (153 * (monat + (monat > 2 ? -3 : 9)) + 2) / 5 + tag - 1
        let tagInAera = jahrInAera * 365 + jahrInAera / 4 - jahrInAera / 100 + tagImJahr
        return aera * 146097 + tagInAera - 719468
    }

    /// Der Umkehrweg, aus der Tageszahl wieder JJJJ-MM-TT.
    static func iso(_ tage: Int) -> String {
        let verschoben = tage + 719468
        let aera = (verschoben >= 0 ? verschoben : verschoben - 146096) / 146097
        let tagInAera = verschoben - aera * 146097
        let jahrInAera = (tagInAera - tagInAera / 1460 + tagInAera / 36524
                          - tagInAera / 146096) / 365
        let jahr = jahrInAera + aera * 400
        let tagImJahr = tagInAera - (365 * jahrInAera + jahrInAera / 4 - jahrInAera / 100)
        let mp = (5 * tagImJahr + 2) / 153
        let tag = tagImJahr - (153 * mp + 2) / 5 + 1
        let monat = mp + (mp < 10 ? 3 : -9)
        return String(format: "%04d-%02d-%02d", jahr + (monat <= 2 ? 1 : 0), monat, tag)
    }

    /// Montag ist 0, wie `date.weekday()` in Python. Der 1. Januar 1970 war ein
    /// Donnerstag, also 3.
    static func wochentag(_ iso: String) -> Int {
        let rest = (zahl(iso) + 3) % 7
        return rest < 0 ? rest + 7 : rest
    }

    static func plus(_ iso: String, _ tage: Int) -> String {
        Self.iso(zahl(iso) + tage)
    }
}
