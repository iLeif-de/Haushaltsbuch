import Foundation
import Observation

/// Die Eingaben des Einrichtungsassistenten, vier Schritte, und was daraus
/// werden soll. Aufgebaut wie ui/einrichtung.py.
///
/// Geschrieben wird erst am Ende. Jeder Schritt liefert beim Weiterklicken
/// seine Aufträge als Daten, nicht als Funktionen, und sie stehen in der
/// Reihenfolge der Schritte. So lässt sich zurückgehen, ohne dass schon etwas
/// in der Datenbank steht, und der Kontostand wird vor den Posten gesetzt.

/// Name, passende Kategorie und Gruppe für die vorgeschlagenen festen Ausgaben.
/// Die Kategorie ist die Art der Ausgabe, die Gruppe der Lebensbereich. Bei
/// Internet, Handy und den Versicherungen hat die Kategorie bewusst keine
/// Vorgabe, dort entscheidet erst der Posten.
let kandidatenFix: [(name: String, kategorie: String, gruppe: String)] = [
    ("Miete", "Miete", "Wohnen"),
    ("Strom", "Energie", "Wohnen"),
    ("Internet", "Kommunikation", "Wohnen"),
    ("Handy", "Kommunikation", "Persönliches"),
    // Früher nur Versicherung. Das lud dazu ein, hier auch die jährliche Kfz
    // Versicherung einzutragen, die gehört aber in Schritt 4.
    ("Haftpflicht und Hausrat", "Versicherungen", "Wohnen"),
    // Bucht die Bank selbst ab und steht nur auf dem Kontoauszug, deshalb wird
    // sie leicht vergessen, und der Kontostand stimmt dann nicht mehr
    ("Kontoführung", "Gebühren", "Finanzen"),
]

/// Die Namen tragen den Unterschied zwischen Schritt 3 und 4 schon selbst. Ein
/// Tester hielt die festen Ausgaben für alle festen Kosten und suchte dort die
/// Kfz Versicherung. Die Leiste zeigt alle vier von Anfang an.
let schrittNamen = ["Kontostand", "Monatliche Einnahmen", "Monatliche Ausgaben",
                    "Periodische Ausgaben und Rücklagen"]

/// Was am Ende geschrieben wird.
enum Auftrag {
    case startsaldo(cent: Int, datum: String)
    case posten(name: String, betragCent: Int, tag: Int, giltAb: String, kategorie: String,
                intervall: Int, schonVorhanden: Int, gruppe: String?)
    case topf(name: String, rate: Int?, ziel: Int?, zielMonat: String?, schonVorhanden: Int,
              kategorie: String?, gruppe: String?)
}

@Observable
final class Einrichtungsdaten {
    struct Einnahme: Identifiable {
        let id = UUID()
        var name = ""
        var betrag = ""
        var tag = "1"
    }

    struct Fixposten: Identifiable {
        let id = UUID()
        var aktiv = false
        var name = ""
        var betrag = ""
        var tag = "1"
        var kategorie = ""
        var gruppe = ""
    }

    struct Periodisch: Identifiable {
        let id = UUID()
        var name = ""
        var betrag = ""
        var tag = "1"
        var intervall = 12
        var faelligkeit = ""
        var kategorie = ""
        var gruppe = ""
        var vorhanden = "0"
    }

    struct EigenerTopf: Identifiable {
        let id = UUID()
        var name = ""
        var ziel = ""
        var rate = ""
        var zielmonat = ""
        var vorhanden = "0"
        var kategorie = ""
        var gruppe = ""
    }

    var kontostand = ""
    var kontodatum = Date()
    var einnahmen: [Einnahme]
    var fixposten: [Fixposten]
    var periodisch: [Periodisch]
    var toepfe: [EigenerTopf]
    /// Die Aufträge je Schritt, damit Zurück sie wieder verwirft.
    var plaene: [Int: [Auftrag]] = [:]

    init(vorhandeneKategorien: Set<String>, heuteMonat: String, vormonatEnde: String) {
        einnahmen = [Einnahme(name: "Gehalt")]
        // Eine Kategorie, die es in dieser Datenbank nicht gibt, bleibt leer
        // statt als unwählbarer Wert im Feld zu stehen.
        fixposten = kandidatenFix.map { kandidat in
            Fixposten(name: kandidat.name,
                      kategorie: vorhandeneKategorien.contains(kandidat.kategorie)
                          ? kandidat.kategorie : "",
                      gruppe: kandidat.gruppe)
        }
        periodisch = [Periodisch(faelligkeit: Monat.plus(heuteMonat, 12))]
        toepfe = []
        kontodatum = Datumsformat.iso.date(from: vormonatEnde) ?? Date()
    }

    // MARK: Prüfen

    /// Prüft einen Schritt und liefert seine Aufträge, oder einen Satz, was
    /// fehlt. Geschrieben wird hier nichts.
    func auftraege(schritt: Int, heuteMonat: String) -> Result<[Auftrag], DbFehler> {
        switch schritt {
        case 0: return kontoAuftrag()
        case 1: return einnahmenAuftraege(heuteMonat: heuteMonat)
        case 2: return fixAuftraege(heuteMonat: heuteMonat)
        default: return periodischeAuftraege()
        }
    }

    private func kontoAuftrag() -> Result<[Auftrag], DbFehler> {
        guard !kontostand.trimmingCharacters(in: .whitespaces).isEmpty else { return .success([]) }
        guard let cent = Geld.cent(aus: kontostand) else {
            return .failure(DbFehler(text: "Der Kontostand ist nicht zu lesen."))
        }
        return .success([.startsaldo(cent: cent,
                                     datum: Datumsformat.iso.string(from: kontodatum))])
    }

    private func einnahmenAuftraege(heuteMonat: String) -> Result<[Auftrag], DbFehler> {
        var raus: [Auftrag] = []
        for zeile in einnahmen {
            let name = zeile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || zeile.betrag.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            guard let cent = Geld.cent(aus: zeile.betrag) else {
                return .failure(DbFehler(text: "Der Betrag bei \(name) ist nicht zu lesen."))
            }
            guard let tag = Int(zeile.tag.isEmpty ? "1" : zeile.tag), (1...31).contains(tag) else {
                return .failure(DbFehler(text: "Der Tag bei \(name) muss zwischen 1 und 31 liegen."))
            }
            raus.append(.posten(name: name, betragCent: abs(cent), tag: tag, giltAb: heuteMonat,
                                kategorie: "Gehalt", intervall: 1, schonVorhanden: 0, gruppe: nil))
        }
        return .success(raus)
    }

    private func fixAuftraege(heuteMonat: String) -> Result<[Auftrag], DbFehler> {
        var raus: [Auftrag] = []
        for zeile in fixposten where zeile.aktiv {
            let name = zeile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || zeile.betrag.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            guard !zeile.kategorie.isEmpty else {
                return .failure(DbFehler(text: "Bitte eine Kategorie für \(name) wählen."))
            }
            guard let cent = Geld.cent(aus: zeile.betrag) else {
                return .failure(DbFehler(text: "Der Betrag bei \(name) ist nicht zu lesen."))
            }
            guard let tag = Int(zeile.tag.isEmpty ? "1" : zeile.tag), (1...31).contains(tag) else {
                return .failure(DbFehler(text: "Der Tag bei \(name) muss zwischen 1 und 31 liegen."))
            }
            raus.append(.posten(name: name, betragCent: -abs(cent), tag: tag, giltAb: heuteMonat,
                                kategorie: zeile.kategorie, intervall: 1, schonVorhanden: 0,
                                gruppe: zeile.gruppe.isEmpty ? nil : zeile.gruppe))
        }
        return .success(raus)
    }

    private func periodischeAuftraege() -> Result<[Auftrag], DbFehler> {
        var raus: [Auftrag] = []
        for zeile in periodisch {
            let name = zeile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || zeile.betrag.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            guard !zeile.kategorie.isEmpty else {
                return .failure(DbFehler(text: "Bitte eine Kategorie für \(name) wählen."))
            }
            let faellig = zeile.faelligkeit.trimmingCharacters(in: .whitespaces)
            guard Monat.gueltig(faellig) else {
                return .failure(DbFehler(text: "Den Fälligkeitsmonat bei \(name) bitte als JJJJ-MM eintragen."))
            }
            guard let cent = Geld.cent(aus: zeile.betrag),
                  let tag = Int(zeile.tag.isEmpty ? "1" : zeile.tag) else {
                return .failure(DbFehler(text: "Die Angaben bei \(name) sind nicht zu lesen."))
            }
            let vorhanden = abs(Geld.cent(aus: zeile.vorhanden) ?? 0)
            raus.append(.posten(name: name, betragCent: -abs(cent), tag: tag, giltAb: faellig,
                                kategorie: zeile.kategorie, intervall: zeile.intervall,
                                schonVorhanden: vorhanden,
                                gruppe: zeile.gruppe.isEmpty ? nil : zeile.gruppe))
        }
        for zeile in toepfe {
            let name = zeile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { continue }
            // Leer heißt hier nicht null, sondern nicht angegeben, sonst
            // entstünde stillschweigend ein Topf, der sich nie füllt
            let ziel = zeile.ziel.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil : Geld.cent(aus: zeile.ziel).map { abs($0) }
            let rate = zeile.rate.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil : Geld.cent(aus: zeile.rate).map { abs($0) }
            let zielmonat = zeile.zielmonat.trimmingCharacters(in: .whitespaces)
            if !zielmonat.isEmpty, !Monat.gueltig(zielmonat) {
                return .failure(DbFehler(text: "Den Monat bei \(name) bitte als JJJJ-MM eintragen."))
            }
            // Dieselbe Bedingung wie in topfAnlegen, hier schon vorab geprüft
            if rate == nil, ziel == nil || zielmonat.isEmpty {
                return .failure(DbFehler(text: "Bei \(name) entweder eine Rate oder Ziel und Monat angeben."))
            }
            raus.append(.topf(name: name, rate: rate, ziel: ziel,
                              zielMonat: zielmonat.isEmpty ? nil : zielmonat,
                              schonVorhanden: abs(Geld.cent(aus: zeile.vorhanden) ?? 0),
                              kategorie: zeile.kategorie.isEmpty ? nil : zeile.kategorie,
                              gruppe: zeile.gruppe.isEmpty ? nil : zeile.gruppe))
        }
        return .success(raus)
    }
}
