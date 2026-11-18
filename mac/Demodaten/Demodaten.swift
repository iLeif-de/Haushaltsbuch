import Foundation

/// Eine Demodatenbank mit gut einem Jahr Geschichte, der Nachfolger von
/// demo_daten.py (2026-09-26). Jede Besonderheit des Programms kommt darin
/// mindestens einmal vor, damit sie beim Prüfen von Hand auch gesehen wird,
/// siehe CLAUDE.md, Abschnitt Prüfen.
///
/// Anders als das Skript in Python füllt sie den laufenden Monat nicht bis zur
/// Warnschwelle auf. Das war für das Erklärvideo gedacht und ergab einen Monat
/// mit dem Dreifachen der üblichen Ausgaben. Der laufende Monat entsteht wie
/// jeder andere, mit denselben Gewohnheiten, nur bis heute. Dazu kommt heute
/// ein einzelner Kauf, gerade groß genug, dass die Übersicht warnt, damit die
/// Warnung in jeder Demo zu sehen ist (2026-09-26). Gegen Monatsende reicht
/// das Budget dafür nicht mehr, dann ist der Monat überzogen und die Warnung rot.
///
/// Die Zufallszahlen kommen aus einem festen Startwert. Am selben Tag entsteht
/// also immer dieselbe Datenbank.
enum Demodaten {
    struct Bericht {
        let monat: String
        let bild: Monatsbild
        /// Wie viel weitere variable Ausgabe die Warnung orange macht, nil wenn
        /// sie schon da ist.
        let bisZurWarnung: Int?
    }

    static func anlegen(in db: Datenbank, heute: Date) throws -> Bericht {
        let h = Kern(db: db, heute: heute)
        var zufall = Zufall(startwert: 7)
        let aktuell = Monat.von(heute)
        let heuteTag = Calendar(identifier: .gregorian).component(.day, from: heute)
        try h.favoritenVorbelegen()

        // Feste Posten, Beginn vierzehn Monate vor heute, damit der
        // Vorjahresvergleich und alle zwölf Balken der Auswertung Daten haben
        let beginn = Monat.plus(aktuell, -14)
        try h.posten("Gehalt", 320000, 1, beginn, "Gehalt")
        // Kategorie nach Art, Gruppe nach Lebensbereich, siehe Anleitung,
        // Kapitel 16. Miete und Strom bringen Wohnen schon als Vorgabe mit.
        // Kommunikation hat bewusst keine, dort entscheidet der Posten.
        try h.posten("Miete", -80000, 1, beginn, "Miete")
        // Zweimal Miete, zwei Lebensbereiche, genau dafür sind es zwei Merkmale
        try h.posten("Stellplatz", -5000, 1, beginn, "Miete", gruppe: "Auto")
        try h.posten("Strom", -9200, 15, beginn, "Energie")
        try h.posten("Internet", -4499, 3, beginn, "Kommunikation", gruppe: "Wohnen")
        try h.posten("Handy", -1999, 5, beginn, "Kommunikation", gruppe: "Persönliches")
        try h.posten("Fitnessstudio", -2990, 1, beginn, "Sport")
        // Bucht die Bank selbst ab und wird deshalb leicht vergessen. Am
        // Dreißigsten steht sie im laufenden Monat fast immer noch als geplant
        // da, mit Haken und Stift
        try h.posten("Kontoführung", -490, 30, beginn, "Gebühren", gruppe: "Finanzen")
        // Vierteljährlich, zuletzt im Vormonat, bekommt damit einen Topf
        try h.posten("Rundfunkbeitrag", -5508, 15, Monat.plus(aktuell, -1), "Gebühren",
                     intervall: 3, gruppe: "Wohnen")
        // Ratenkauf, läuft in fünf Monaten aus. Nach Kategorie sieht man, was
        // in Raten gebunden ist, nach Gruppe, was die Wohnung kostet.
        let sofa = try h.posten("Sofa auf Raten", -6000, 10, Monat.plus(aktuell, -7),
                                "Kredite und Raten", gruppe: "Wohnen")
        try h.regelBeenden(sofa, letzterMonat: Monat.plus(aktuell, 5))
        // Hieß anfangs anders und wurde teurer. Die Umbenennung gilt für den
        // ganzen Posten, auch die alten Abschläge zeigen den neuen Namen.
        let streaming = try h.posten("Videodienst", -1299, 8, beginn, "Kultur")
        let streamingNeu = try h.regelAendern(streaming, neuerBetrag: -1399,
                                              abMonat: Monat.plus(aktuell, -6))
        try h.regelUmbenennen(streaming, name: "Streaming")
        // Zwei Versicherungen in derselben Kategorie, verschiedene Gruppen
        try h.posten("Haftpflicht", -1190, 20, beginn, "Versicherungen", gruppe: "Wohnen")
        // Jährlich, zuletzt vor sieben Monaten fällig, Topf teils gefüllt
        try h.posten("Kfz Versicherung", -57600, 5, Monat.plus(aktuell, -7), "Versicherungen",
                     intervall: 12, schonVorhanden: 7 * 4800, gruppe: "Auto")
        try h.posten("Kfz Steuer", -12800, 12, Monat.plus(aktuell, -3), "Steuern",
                     intervall: 12, gruppe: "Auto")

        // Eigener Topf mit fester Rate und einer mit Termin, bei dem die Rate
        // das ist, was noch fehlt, verteilt auf die Monate bis dahin
        let urlaub = try h.topf("Urlaub", rate: 15000, ziel: 150000, schonVorhanden: 60000,
                                kategorie: "Reisen", gruppe: "Urlaub")
        let waschmaschine = try h.topf("Neue Waschmaschine", ziel: 60000,
                                       zielMonat: Monat.plus(aktuell, 8),
                                       kategorie: "Möbel und Geräte", gruppe: "Wohnen")

        // Dreizehn Monate Geschichte
        for i in stride(from: 13, through: 1, by: -1) {
            let m = Monat.plus(aktuell, -i)
            try h.fortschreiben(m)
            try alltag(h, m, bisTag: 31, &zufall)
            try besonderes(h, m, vorMonaten: i, &zufall)
            for b in h.buchungen(m) where b.status == "geplant" {
                try h.bestaetigen(b.id)
            }
        }

        // Der laufende Monat, dieselben Gewohnheiten, nur bis heute
        try h.fortschreiben(aktuell)
        try alltag(h, aktuell, bisTag: heuteTag, &zufall)
        let heuteText = Datumsformat.iso.string(from: heute)
        for b in h.buchungen(aktuell) where b.status == "geplant" && b.datum <= heuteText {
            try h.bestaetigen(b.id)
        }
        // Streaming nachträglich nach Medien umordnen, erst jetzt, da es
        // Abschläge gibt. Die neue Kategorie muss auch diese erreichen.
        try h.regelKategorieSetzen(streamingNeu, kategorieId: try h.kategorieId("Medien"))

        // Aus einer Rücklage bezahlen und in eine hineinlegen. Beides im
        // laufenden Monat, ein eigener Topf rechnet erst ab seinem Startmonat.
        if heuteTag >= 12 {
            try h.buchen(-24000, "Reisen", datum: tag(aktuell, 11, heuteTag, &zufall),
                         notiz: "Anzahlung Ferienwohnung", topfId: urlaub)
        }
        try h.topfAufstocken(waschmaschine, betrag: 12000)
        // Außerplanmäßige Einnahme, landet auf dem Konto statt im Budget
        if heuteTag >= 2 {
            try h.buchen(63500, "Sonstiges", datum: tag(aktuell, 2, heuteTag, &zufall),
                         notiz: "Steuererstattung", ausserplanmaessig: true)
        }

        // Startsaldo vor gut einem Jahr, damit der Kontostand etwas zeigt
        try h.startsaldoSetzen(betragCent: 200000, datum: "\(beginn)-01")

        try h.fortschreiben(aktuell)
        // Heute ein Kauf, der die Warnung auslöst, auf einen glatten Preis
        // aufgerundet, etwa 249,00 €, siehe oben
        var bild = h.uebersicht(aktuell)
        if bild.warnung == nil, let fehlt = bisZurWarnung(bild) {
            let preis = ((fehlt + 1000) / 5000 + 1) * 5000 - 100
            try h.buchen(-preis, "Hobbys", datum: heuteText, notiz: "Fahrrad")
            bild = h.uebersicht(aktuell)
        }
        return Bericht(monat: aktuell, bild: bild, bisZurWarnung: bisZurWarnung(bild))
    }

    /// Wie viel weitere variable Ausgabe die Übersicht warnen lässt, orange
    /// oder, wenn das Budget dafür nicht reicht, rot. Nil, wenn sie es schon tut.
    private static func bisZurWarnung(_ bild: Monatsbild) -> Int? {
        guard bild.warnung == nil else { return nil }
        let ist = -bild.variabelCent
        let budget = bild.einnahmenCent + bild.fixCent - bild.ratenCent
        let orange = Int(Double(budget) * Kern.warnSchwelle(bild.monatAnteil)) - ist + 1
        let rot = bild.verfuegbarCent + 1
        return max(1, min(orange, rot))
    }

    // MARK: Gewohnheiten

    /// Was in einem gewöhnlichen Monat so ausgegeben wird, alles über den Monat
    /// verteilt und nur bis zum genannten Tag gebucht. Im laufenden Monat liegt
    /// die Summe damit von selbst etwa beim Üblichen bis heute.
    private static func alltag(_ h: Kern, _ m: String, bisTag: Int,
                               _ zufall: inout Zufall) throws {
        /// Ein Kauf an einem zufälligen Tag, oder im Fenster `fenster` von
        /// `fenstern` gleich großen Stücken des Monats. Wer einmal die Woche
        /// einkauft, kauft nicht dreimal in der ersten Woche ein, und genau das
        /// ließ den laufenden Monat vorher ständig nach Ausreißer aussehen.
        func kauf(_ kategorie: String, _ von: Int, _ bis: Int, notiz: String? = nil,
                  gruppe: String? = nil, fenster: Int = 0, fenstern: Int = 1) throws {
            let breite = 28 / fenstern
            let tagImMonat = fenster * breite + zufall.zahl(1, breite)
            let betrag = zufall.zahl(von, bis)
            guard tagImMonat <= bisTag else { return }
            try h.buchen(-betrag, kategorie, datum: String(format: "%@-%02d", m, tagImMonat),
                         notiz: notiz, gruppe: gruppe)
        }
        let monatImJahr = Int(m.suffix(2)) ?? 1
        // Einmal die Woche einkaufen, dazu mal der Bäcker oder der Markt. Die
        // Summen sind die eines Haushalts zu zweit, der ausgibt, was er hat,
        // und nicht jeden Monat über tausend Euro zurücklegt (2026-09-26)
        for woche in 0..<4 {
            try kauf("Lebensmittel", 12000, 18000, notiz: zufall.eins(["Wocheneinkauf", nil, nil]),
                     fenster: woche, fenstern: 4)
        }
        for _ in 0..<zufall.zahl(4, 7) {
            try kauf("Lebensmittel", 600, 2400, notiz: zufall.eins(["Bäcker", "Markt", nil]))
        }
        for _ in 0..<zufall.zahl(5, 7) {
            try kauf("Gastronomie", 1800, 6000,
                     notiz: zufall.eins(["Pizzeria", "Café", "Mittagessen", nil]))
        }
        // Katzenfutter und Streu, alle zwei Wochen
        for haelfte in 0..<2 {
            try kauf("Haustier", 3000, 5000, notiz: zufall.eins(["Futter", "Streu", nil]),
                     fenster: haelfte, fenstern: 2)
        }
        try kauf("Medien", 800, 3000, notiz: zufall.eins(["Buch", "App", "Zeitschrift"]))
        try kauf("Arzt und Apotheke", 500, 3000, notiz: "Apotheke")
        try kauf("Geschenke", 1500, 4000, notiz: zufall.eins(["Geburtstag", "Mitbringsel", nil]))
        let tankstopps = 3
        for stopp in 0..<tankstopps {
            try kauf("Tanken", 6000, 8500, fenster: stopp, fenstern: tankstopps)
        }
        try kauf("Haushalt", 800, 3500, notiz: zufall.eins(["Drogerie", "Baumarkt", nil]))
        try kauf("Haushalt", 800, 3500, notiz: zufall.eins(["Drogerie", "Baumarkt", nil]))
        try kauf("Körperpflege", 900, 2800, notiz: "Drogerie")
        try kauf("Körperpflege", 2500, 4500, notiz: "Friseur")
        try kauf("Kleidung", 3000, 9000)
        try kauf("Kultur", 2000, 4000, notiz: zufall.eins(["Kino", "Theater", "Konzert"]))
        if monatImJahr % 2 == 1 { try kauf("Hobbys", 1500, 6000) }
        // Im Dezember Weihnachten, das Übliche fängt es über den Median ab
        if monatImJahr == 12 {
            try kauf("Geschenke", 8000, 16000, notiz: "Weihnachten")
            try kauf("Geschenke", 3000, 6000, notiz: "Weihnachten")
        }
    }

    /// Was nicht jeden Monat vorkommt, aber in der Demo zu sehen sein soll.
    private static func besonderes(_ h: Kern, _ m: String, vorMonaten i: Int,
                                   _ zufall: inout Zufall) throws {
        func am(_ von: Int = 1, _ bis: Int = 28) -> String { tag(m, von, bis, &zufall) }
        if i % 4 == 0 {
            // Einzelne Buchung mit eigener Gruppe, sie übersteuert die Kategorie
            try h.buchen(-zufall.zahl(4000, 9000), "Kleidung", datum: am(),
                         notiz: "Arbeitskleidung", gruppe: "Arbeit")
        }
        if i % 5 == 0 {
            try h.buchen(-zufall.zahl(12000, 28000), "Werkstatt", datum: am(),
                         notiz: "Inspektion")
        }
        switch i {
        case 7:
            try h.buchen(-5980, "Fahrkarten", datum: am(), notiz: "Bahnfahrt zur Oma",
                         gruppe: "Familie und Freunde")
        case 6:
            // Ein Buch ist Medien, zur Weiterbildung gekauft gehört es dorthin
            try h.buchen(-4990, "Medien", datum: am(), notiz: "Fachbuch",
                         gruppe: "Weiterbildung")
        case 5:
            // Gleiche Kategorie wie das Kino, anderer Lebensbereich
            try h.buchen(-2400, "Kultur", datum: am(), notiz: "Museum mit den Enkeln",
                         gruppe: "Familie und Freunde")
        case 4:
            try h.buchen(-3990, "Geschenke", datum: am(), notiz: "Geburtstag Anna")
        case 3:
            // Größere Ausgabe ohne Vorlauf. Sie senkt den Kontostand und zählt
            // in der Auswertung, trifft aber Monatsbudget und Warnung nicht.
            try h.buchen(-42900, "Möbel und Geräte", datum: am(), notiz: "Neuer Herd",
                         ausserplanmaessig: true)
        case 2:
            try h.buchen(-2350, "Arzt und Apotheke", datum: am(), notiz: "Apotheke")
        default:
            break
        }
    }

    private static func tag(_ m: String, _ von: Int, _ bis: Int,
                            _ zufall: inout Zufall) -> String {
        String(format: "%@-%02d", m, zufall.zahl(von, min(bis, 28)))
    }
}

/// Zufallszahlen aus einem festen Startwert, SplitMix64. Swift bringt keinen
/// Generator mit Startwert mit, und derselbe Tag soll dieselbe Demo ergeben.
struct Zufall {
    private var zustand: UInt64

    init(startwert: UInt64) { zustand = startwert }

    mutating func naechste() -> UInt64 {
        zustand &+= 0x9E37_79B9_7F4A_7C15
        var z = zustand
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Eine ganze Zahl von bis, beide eingeschlossen.
    mutating func zahl(_ von: Int, _ bis: Int) -> Int {
        guard bis > von else { return von }
        return von + Int(naechste() % UInt64(bis - von + 1))
    }

    mutating func eins<T>(_ auswahl: [T]) -> T {
        auswahl[zahl(0, auswahl.count - 1)]
    }
}
