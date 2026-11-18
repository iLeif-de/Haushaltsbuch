import Foundation

/// Die Modelle spiegeln die Tabellen aus haushalt/schema.sql, Fassung 10.
/// Beträge sind Cent als Ganzzahl, Einnahmen positiv, Ausgaben negativ.
struct Kategorie: Identifiable, Hashable {
    let id: Int64
    let name: String
    let icon: String?
    let gruppe: String?
    let favorit: Bool
    let sortierung: Int

    init(zeile: [String: Wert]) {
        id = zeile["id"]?.alsZahl ?? 0
        name = zeile["name"]?.alsText ?? ""
        icon = zeile["icon"]?.alsText
        gruppe = zeile["gruppe"]?.alsText
        favorit = zeile["favorit"]?.istWahr ?? false
        sortierung = zeile["sortierung"]?.alsGanz ?? 0
    }
}

struct Buchung: Identifiable, Hashable {
    let id: Int64
    let datum: String
    let betragCent: Int
    let notiz: String?
    let kategorie: String
    /// Der Name des festen Postens, wenn die Buchung aus einem kommt. Er ist der
    /// Titel der Zeile, etwa Stellplatz, die Kategorie steht dann darunter.
    let posten: String?
    /// Die Gruppe, unter der sie zählt, also ihre eigene oder eine geerbte.
    let gruppe: String?
    /// Die eigene Gruppe. Nil heißt nicht gesetzt und erbt, leerer Text heißt
    /// bewusst gelöscht. Wird nur weitergegeben, nicht angezeigt.
    let eigeneGruppe: String?
    let topfId: Int64?
    let ausserplanmaessig: Bool
    /// Buchungen mit Posten kommen aus einer Regel, sie sind fix.
    let ausPosten: Bool
    /// Geplant heißt, der Abschlag ist noch nicht bestätigt.
    let geplant: Bool
    /// art und status, wie sie in der Datenbank stehen, für den Export.
    let art: String
    let status: String

    init(zeile: [String: Wert]) {
        id = zeile["id"]?.alsZahl ?? 0
        datum = zeile["datum"]?.alsText ?? ""
        betragCent = zeile["betrag_cent"]?.alsGanz ?? 0
        notiz = zeile["notiz"]?.alsText
        kategorie = zeile["kategorie"]?.alsText ?? "Ohne Kategorie"
        posten = zeile["posten"]?.alsText
        gruppe = zeile["wirksame_gruppe"]?.alsText
        eigeneGruppe = zeile["gruppe"]?.alsText
        topfId = zeile["topf_id"]?.alsZahl
        ausserplanmaessig = zeile["ausserplanmaessig"]?.istWahr ?? false
        ausPosten = zeile["regel_id"]?.alsZahl != nil
        geplant = zeile["status"]?.alsText == "geplant"
        art = zeile["art"]?.alsText ?? "variabel"
        status = zeile["status"]?.alsText ?? "gebucht"
    }

    /// Wie in der Fassung mit Flet. Ein fester Posten lässt sich bearbeiten,
    /// aber nicht löschen und nicht duplizieren, er gehört seiner Regel. Eine
    /// geplante Zeile wird erst bestätigt, siehe Bestaetigungsdialog.
    var loeschbar: Bool { !geplant && !ausPosten }

    /// Die Kennung in der Buchungsliste. Sie mischt drei Sorten Zeilen, und alle
    /// drei zählen ihre Nummern für sich. Ohne eigenen Vorsatz hält SwiftUI
    /// Buchung 1 und Topf 1 für dieselbe Zeile und zeichnet eine davon zweimal
    /// (2026-09-24).
    var zeilenSchluessel: String { "buchung-\(id)" }

    /// Der Titel der Zeile, wie in ui/uebersicht.py. Der Posten, wenn es einen
    /// gibt, sonst die Kategorie.
    var titel: String { posten ?? kategorie }

    /// Was klein darunter steht, in dieser Reihenfolge. Die Kategorie nur dann,
    /// wenn oben der Posten steht, sonst stünde sie zweimal da.
    var unterzeile: String {
        [posten != nil ? kategorie : nil,
         (gruppe?.isEmpty ?? true) ? nil : gruppe,
         (notiz?.isEmpty ?? true) ? nil : notiz,
         ausserplanmaessig ? "außerplanmäßig" : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

/// Ein fester Posten, eine Regel aus der Tabelle regeln.
struct Posten: Identifiable, Hashable {
    let id: Int64
    let name: String
    let betragCent: Int
    let tagImMonat: Int
    let intervallMonate: Int
    let giltAb: String
    let giltBis: String?
    let kategorien: String?
    /// Die Gruppe, die gilt, also die eigene oder die der Kategorie.
    let wirksameGruppe: String?
    /// Die eigene Gruppe des Postens. Nil heißt nicht gesetzt und erbt.
    let gruppe: String?

    init(zeile: [String: Wert]) {
        id = zeile["id"]?.alsZahl ?? 0
        name = zeile["name"]?.alsText ?? ""
        betragCent = zeile["betrag_cent"]?.alsGanz ?? 0
        tagImMonat = zeile["tag_im_monat"]?.alsGanz ?? 1
        intervallMonate = zeile["intervall_monate"]?.alsGanz ?? 1
        giltAb = zeile["gilt_ab"]?.alsText ?? ""
        giltBis = zeile["gilt_bis"]?.alsText
        kategorien = zeile["kategorien"]?.alsText
        wirksameGruppe = zeile["wirksame_gruppe"]?.alsText
        gruppe = zeile["gruppe"]?.alsText
    }

    /// Ein Posten hat in der Oberfläche genau eine Kategorie.
    var ersteKategorie: String? {
        kategorien?.split(separator: ", ").first.map(String.init)
    }

    /// Gilt der Posten erst ab diesem Monat, gäbe es keinen gültigen Vormonat,
    /// zu dem er beendet werden könnte, dann wird er ganz gelöscht.
    func nurGanzLoeschbar(heuteMonat: String) -> Bool {
        giltAb > Monat.plus(heuteMonat, -1)
    }

    /// "am 1., monatlich", wie INTERVALL_NAMEN in ui/hilfen.py.
    var rhythmus: String {
        let namen = [1: "monatlich", 3: "vierteljährlich", 6: "halbjährlich", 12: "jährlich"]
        return "am \(tagImMonat)., \(namen[intervallMonate] ?? "alle \(intervallMonate) Monate")"
    }
}

/// Eine Aufstockung, also Geld, das außerhalb der Rate in einen Topf gelegt
/// wurde. Keine Buchung, das Geld liegt schon auf dem Konto.
struct Einlage: Identifiable, Hashable {
    let id: Int64
    let topfId: Int64
    let monat: String
    let betragCent: Int
    let topf: String

    /// Siehe Buchung.zeilenSchluessel.
    var zeilenSchluessel: String { "einlage-\(id)" }

    init(zeile: [String: Wert]) {
        id = zeile["id"]?.alsZahl ?? 0
        topfId = zeile["topf_id"]?.alsZahl ?? 0
        monat = zeile["monat"]?.alsText ?? ""
        betragCent = zeile["betrag_cent"]?.alsGanz ?? 0
        topf = zeile["topf"]?.alsText ?? ""
    }
}

/// Eine gelöschte Buchung, so lange aufgehoben, dass sie sich zurückholen lässt.
struct GeloeschteBuchung {
    let datum: String
    let betragCent: Int
    let notiz: String?
    let kategorieId: Int64
    let topfId: Int64?
    let eigeneGruppe: String?
    let ausserplanmaessig: Bool
}

/// Wo die Datenbank und die Sicherungen liegen. Seit Fassung 2.0 in eigenen
/// Ordnern namens Haushaltsbuch, wie das Programm heißt (2026-09-26). Fassung
/// 1.2 lag in iCloud Drive im Ordner Haushaltbuch, ohne s, und sicherte nach
/// Application Support/Haushalt. Beim ersten Start zieht die Datenbank um,
/// siehe Umzug. Zum Ausprobieren `HAUSHALT_DB` auf eine Kopie setzen, etwa auf
/// eine frisch mit demo_daten.py erzeugte, siehe README.md.
enum Pfade {
    private static var heim: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Die echte Datenbank in iCloud Drive.
    static var standard: String {
        heim.appendingPathComponent(
            "Library/Mobile Documents/com~apple~CloudDocs/Haushaltsbuch/haushaltsbuch.sqlite").path
    }

    /// Wo Fassung 1.2 die Datenbank hatte, für den Umzug.
    static var alt: String {
        heim.appendingPathComponent(
            "Library/Mobile Documents/com~apple~CloudDocs/Haushaltbuch/haushalt.sqlite").path
    }

    /// Die Datenbank, die das Programm öffnet. Ohne HAUSHALT_DB die echte,
    /// in jedem Bau. Den Umzug von 1.2 schützt die Rückfrage, siehe
    /// Umzugsansicht.
    static var datenbank: String {
        if let eigener = ProcessInfo.processInfo.environment["HAUSHALT_DB"], !eigener.isEmpty {
            return eigener
        }
        return standard
    }

    /// Der Ordner der Sicherungen zu einer Datenbank. Für die echte liegt er im
    /// normalen Dateisystem und nicht in iCloud. Für jede andere liegt er neben
    /// ihr. Sonst schriebe ein Lauf mit einer Kopie deren Monatssicherung in
    /// den echten Ordner, und die echte Datenbank bekäme diesen Monat keine
    /// mehr, weil die Datei schon da ist (2026-09-26).
    static func sicherungen(fuer datenbank: String) -> URL {
        if datenbank == standard {
            return heim.appendingPathComponent("Library/Application Support/Haushaltsbuch/backup")
        }
        return URL(fileURLWithPath: datenbank).deletingLastPathComponent()
            .appendingPathComponent("backup")
    }
}
