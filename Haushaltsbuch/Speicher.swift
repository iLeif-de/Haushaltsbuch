import Foundation
import Observation

/// Der Speicher hält die Verbindung und die Listen, die die Oberfläche zeigt.
/// Es gibt keinen Zustand neben der Datenbank, jede Änderung endet mit `laden`,
/// dieselbe Regel wie in der Fassung mit Flet.
///
/// Gerechnet wird im Kern, siehe Kern.swift. Der Speicher holt dort die Zahlen
/// und hält sie für die Oberfläche bereit.
@Observable
final class Speicher {
    /// Für diese Schemafassung ist der Code geschrieben. Eine ältere hat
    /// Datenbank beim Öffnen schon migriert. Steht danach eine neuere da, kommt
    /// die Datei von einer späteren Fassung des Programms, dann wird nichts
    /// geschrieben.
    static let erwarteteFassung = Datenbank.schemaFassung

    private(set) var kategorien: [Kategorie] = []
    private(set) var buchungen: [Buchung] = []
    private(set) var bild: Monatsbild?
    private(set) var toepfe: [Topf] = []
    private(set) var posten: [Posten] = []
    private(set) var einlagen: [Einlage] = []
    /// Die nächsten Termine der nicht monatlichen Posten, für die Übersicht.
    private(set) var termine: [Termin] = []
    /// Alle vergebenen Gruppen, für das Menü am Gruppenfeld.
    private(set) var gruppen: [String] = []
    /// Die Jahre, die zur Auswahl stehen, vom ältesten Buchungsjahr bis zum
    /// nächsten. Das nächste kommt mit, weil die Übersicht einen Monat
    /// vorausschaut.
    private(set) var jahre: [Int] = []
    /// Nil, solange kein Startsaldo gesetzt ist. Dann gibt es weder Kontostand
    /// noch frei Verfügbares, genau wie in der Fassung mit Flet.
    private(set) var kontostandCent: Int?
    private(set) var freiVerfuegbarCent: Int?
    /// Die letzte gelöschte Buchung, für Rückgängig. Wie die Meldung mit
    /// Rückgängig in der Fassung mit Flet, nur ohne Zeitlimit.
    private(set) var letzteLoeschung: GeloeschteBuchung?
    private(set) var meldung: String?
    /// Was beim letzten Lesen des Eingangs vom iPhone kam, siehe Eingang.swift.
    private(set) var eingangHinweis: String?
    /// Meldet neue Dateien im Eingang sofort, siehe Eingangswaechter.
    @ObservationIgnored private var waechter: Eingangswaechter?
    private(set) var schreibbar = false
    var monat: String {
        didSet { if monat != oldValue { laden() } }
    }

    private var db: Datenbank?
    private(set) var kern: Kern?

    var favoriten: [Kategorie] {
        Array(kategorien.filter(\.favorit).sorted { $0.sortierung < $1.sortierung }.prefix(8))
    }

    /// Der heutige Monat, unabhängig davon, welcher gerade angezeigt wird.
    /// Beenden und Löschen rechnen damit, nicht mit dem angezeigten, genau wie
    /// ui/posten.py es tut.
    let heuteMonat: String

    /// Der Tag, an dem das Programm gestartet wurde, für Kern und Sicherung.
    private let starttag: Date

    /// Gibt es am neuen Ort noch keine Datenbank, aber am alten eine von
    /// Fassung 1.2? Dann ist nichts geöffnet, und das Fenster fragt erst, ob
    /// sie übernommen oder neu angefangen wird, siehe Umzugsansicht.
    private(set) var umzugOffen = false

    init(pfad: String = Pfade.datenbank, heute: Date = Date()) {
        self.pfad = pfad
        starttag = heute
        heuteMonat = Datumsformat.monat(heute)
        monat = Datumsformat.monat(heute)
        // Beim ersten Start von 2.0 liegt die Datenbank noch am Ort von 1.2.
        // Umgezogen wird erst nach einer Rückfrage (2026-09-26). Ohne sie zog
        // schon das bloße Anschauen einer neuen Fassung die Datenbank um, und
        // 1.2 fing danach leer an.
        if pfad == Pfade.standard, Umzug.steht(von: Pfade.alt, nach: pfad) {
            umzugOffen = true
            return
        }
        oeffnen()
    }

    /// Zieht die Datenbank von 1.2 um und öffnet sie dann, nach der Rückfrage.
    /// Scheitert das, wird nichts geöffnet, sonst entstünde am neuen Ort eine
    /// leere Datenbank, und der Assistent finge von vorn an.
    func umziehen() {
        do {
            try Umzug.wennNoetig(von: Pfade.alt, nach: pfad)
        } catch {
            meldung = "Die Datenbank ließ sich nicht von \(Pfade.alt) nach \(pfad) holen. "
                + error.localizedDescription
            return
        }
        umzugOffen = false
        oeffnen()
    }

    /// Schließt die Datenbank beim Beenden des Programms, siehe
    /// Datenbank.schliessen. Danach wird nichts mehr gelesen oder geschrieben.
    func beenden() {
        schreibbar = false
        db?.schliessen()
    }

    /// Fängt mit einer leeren Datenbank am neuen Ort an, statt die von 1.2 zu
    /// übernehmen. Die alte bleibt, wie sie ist, 1.2 arbeitet damit weiter.
    func neuAnfangen() {
        umzugOffen = false
        oeffnen()
    }

    private func oeffnen() {
        let heute = starttag
        do {
            let verbindung = try Datenbank(pfad: pfad)
            let fassung = Int(try verbindung.einstellung("schema_version") ?? "0") ?? 0
            guard fassung == Self.erwarteteFassung else {
                meldung = "Die Datenbank stammt von einer neueren Fassung des Programms, "
                    + "Schema \(fassung) statt \(Self.erwarteteFassung). Es wird nichts geändert."
                return
            }
            db = verbindung
            // Wie app.py, WAL für die Datei, dann die Monatssicherung. Die
            // braucht die offene Verbindung, sie läuft über die
            // Sicherungsschnittstelle von SQLite und nicht als Dateikopie.
            try? verbindung.ausfuehren("PRAGMA journal_mode = WAL")
            var sicherungsfehler: String?
            do {
                try Sicherungen.monatlich(verbindung, heute: heute,
                                          ordner: Pfade.sicherungen(fuer: pfad))
            } catch {
                sicherungsfehler = "Die Monatssicherung ist gescheitert. "
                    + error.localizedDescription
            }
            let kern = Kern(db: verbindung, heute: heute)
            self.kern = kern
            schreibbar = true
            // Beim ersten Start die üblichen Favoriten setzen, wie app.py.
            try? verbindung.inEinemStueck { try kern.favoritenVorbelegen() }
            laden()
            eingangLesen()
            waechter = Eingangswaechter(ordner: Eingang.ordner(fuer: pfad)) { [weak self] in
                self?.eingangLesen()
            }
            // Erst nach dem Laden, das setzt die Meldung sonst wieder zurück
            if let sicherungsfehler { meldung = sicherungsfehler }
        } catch {
            meldung = error.localizedDescription
        }
    }

    func laden() {
        guard let db else { return }
        // Vor dem Lesen fortschreiben, genau wie Haushalt.uebersicht es tut.
        // Der laufende Monat und der nächste, dazu der gezeigte, wenn er ein
        // anderer ist. Ohne das fehlten die Abschläge, solange das Programm in
        // Python nicht gelaufen ist, und nach dem Assistenten stand die
        // Übersicht leer da (2026-09-24).
        if let kern, schreibbar {
            try? db.inEinemStueck {
                try kern.fortschreiben(heuteMonat)
                try kern.fortschreiben(Monat.plus(heuteMonat, 1))
                if monat != heuteMonat { try kern.fortschreiben(monat) }
            }
        }
        do {
            kategorien = try db.zeilen(
                "SELECT id, name, icon, gruppe, favorit, sortierung FROM kategorien "
                + "WHERE aktiv = 1 ORDER BY sortierung, name"
            ).map(Kategorie.init)

            if let kern {
                buchungen = kern.buchungen(monat)
                bild = kern.uebersicht(monat)
                toepfe = kern.toepfe(monat)
                posten = kern.regeln(monat)
                einlagen = kern.einlagen(monat)
                termine = kern.anstehendeTermine(ab: monat)
                gruppen = kern.gruppen()
                let erstes = Int(kern.ersterMonat()?.prefix(4) ?? "") ?? Self.jahr(heuteMonat)
                jahre = Array(min(erstes, Self.jahr(monat))...max(Self.jahr(heuteMonat) + 1,
                                                                 Self.jahr(monat)))
                kontostandCent = kern.kontostand()
                freiVerfuegbarCent = kern.freiVerfuegbar()
            }
            meldung = nil
        } catch {
            meldung = error.localizedDescription
        }
        // Stand und Kategorien für den Kurzbefehl auf dem iPhone, nur wenn
        // sich etwas geändert hat, siehe Eingang.auskunft
        if let kern, schreibbar { Eingang.auskunft(kern, neben: pfad) }
    }

    /// Bucht, was vom iPhone im Ordner Eingang liegt, siehe Eingang.swift.
    /// Beim Öffnen und immer, wenn das Programm in den Vordergrund kommt.
    func eingangLesen() {
        guard let kern, schreibbar else { return }
        let ergebnis = Eingang.einlesen(kern, ordner: Eingang.ordner(fuer: pfad))
        if ergebnis.uebernommen > 0 || !ergebnis.fehler.isEmpty {
            laden()
            eingangHinweis = ergebnis.satz
        }
    }

    func eingangHinweisVergessen() { eingangHinweis = nil }

    /// Eine Buchung aus der Schnelleingabe, genau wie Haushalt.buchen.
    @discardableResult
    func buchen(datum: Date, betragCent: Int, kategorie: Kategorie, notiz: String?,
                topfId: Int64?, gruppe: String?, ausserplanmaessig: Bool) -> Bool {
        buchen(datum: Datumsformat.iso.string(from: datum), betragCent: betragCent,
               kategorieId: kategorie.id, notiz: notiz, topfId: topfId, gruppe: gruppe,
               ausserplanmaessig: ausserplanmaessig)
    }

    /// Der eigentliche Weg hinein, mit allen Feldern, die Haushalt.buchen kennt.
    /// Eine Zeile in buchungen, eine in buchung_kategorien, beides in einem
    /// Stück. Den Nutzungszähler erhöht der Auslöser trg_kategorie_nutzung.
    /// Topf und Gruppe braucht das Zurückholen einer gelöschten Buchung, die
    /// Schnelleingabe setzt sie noch nicht.
    @discardableResult
    func buchen(datum: String, betragCent: Int, kategorieId: Int64, notiz: String?,
                topfId: Int64?, gruppe: String?, ausserplanmaessig: Bool) -> Bool {
        guard let db, schreibbar else {
            meldung = meldung ?? "Diese Datenbank wird nur gelesen."
            return false
        }
        do {
            try db.inEinemStueck {
                try kern?.buchen(betragCent, kategorieId: kategorieId, datum: datum, notiz: notiz,
                                 topfId: topfId, gruppe: gruppe,
                                 ausserplanmaessig: ausserplanmaessig)
            }
            letzteLoeschung = nil
            // Eine Buchung mit altem Datum landet in ihrem Monat, die Liste
            // springt aber nicht dorthin, genau wie in der Fassung mit Flet.
            laden()
            return true
        } catch {
            meldung = error.localizedDescription
            return false
        }
    }

    /// Ändert eine Buchung, wie Haushalt.buchung_aendern. Was nicht übergeben
    /// wird, bleibt unberührt, Gruppe und Topf fasst diese App also nicht an.
    @discardableResult
    func buchungAendern(_ id: Int64, datum: String, betragCent: Int, kategorieId: Int64,
                        notiz: String?, topfId: Int64?, gruppe: String?,
                        ausserplanmaessig: Bool) -> Bool {
        guard let db, schreibbar else {
            meldung = meldung ?? "Diese Datenbank wird nur gelesen."
            return false
        }
        do {
            try db.inEinemStueck {
                // Der Dialog setzt immer alles, auch Topf und Gruppe, nil
                // entfernt sie. Eine leere Notiz löscht die Notiz, ein leerer
                // Text an der Gruppe heißt bewusst gelöscht.
                try kern?.buchungAendern(id, betrag: betragCent, datum: datum, notiz: notiz ?? "",
                                         kategorieId: kategorieId, topf: .setzen(topfId),
                                         gruppe: .setzen(gruppe),
                                         ausserplanmaessig: ausserplanmaessig)
            }
            letzteLoeschung = nil
            laden()
            return true
        } catch {
            meldung = error.localizedDescription
            return false
        }
    }

    /// Löscht eine Buchung und hebt sie für Rückgängig auf. Ein fester Posten
    /// und eine geplante Zeile lassen sich nicht löschen, wie in Flet.
    @discardableResult
    func buchungLoeschen(_ buchung: Buchung) -> Bool {
        guard let db, schreibbar, buchung.loeschbar else {
            meldung = meldung ?? "Diese Buchung lässt sich nicht löschen."
            return false
        }
        do {
            let kategorieId = try db.zeilen(
                "SELECT kategorie_id FROM buchung_kategorien WHERE buchung_id=? "
                + "ORDER BY kategorie_id LIMIT 1", [.zahl(buchung.id)]
            ).first?["kategorie_id"]?.alsZahl
            try kern?.buchungLoeschen(buchung.id)
            if let kategorieId {
                letzteLoeschung = GeloeschteBuchung(
                    datum: buchung.datum, betragCent: buchung.betragCent, notiz: buchung.notiz,
                    kategorieId: kategorieId, topfId: buchung.topfId,
                    eigeneGruppe: buchung.eigeneGruppe,
                    ausserplanmaessig: buchung.ausserplanmaessig)
            }
            laden()
            return true
        } catch {
            meldung = error.localizedDescription
            return false
        }
    }

    /// Holt die letzte gelöschte Buchung zurück. Sie bekommt eine neue Nummer,
    /// alles andere steht wieder wie vorher.
    func loeschungZurueckholen() {
        guard let weg = letzteLoeschung else { return }
        letzteLoeschung = nil
        buchen(datum: weg.datum, betragCent: weg.betragCent, kategorieId: weg.kategorieId,
               notiz: weg.notiz, topfId: weg.topfId, gruppe: weg.eigeneGruppe,
               ausserplanmaessig: weg.ausserplanmaessig)
    }

    func loeschungVergessen() {
        letzteLoeschung = nil
    }

    /// Leerer oder nur aus Leerzeichen bestehender Text wird NULL, wie in Python.
    func monatBlaettern(_ schritte: Int) {
        letzteLoeschung = nil
        monat = Monat.plus(monat, schritte)
    }

    private static func jahr(_ monat: String) -> Int {
        Int(monat.prefix(4)) ?? 2026
    }

    /// Setzt Monat und Jahr getrennt, das braucht die Monatswahl im Kopf.
    func monatSetzen(jahr: Int? = nil, monatImJahr: Int? = nil) {
        let teile = monat.split(separator: "-")
        let j = jahr ?? Int(teile[0]) ?? 2026
        let m = monatImJahr ?? Int(teile[1]) ?? 1
        monat = String(format: "%04d-%02d", j, m)
    }

    func kategorie(nach name: String) -> Kategorie? {
        kategorien.first { $0.name == name }
    }

    // MARK: Feste Posten

    /// Name, Kategorie und Gruppe gelten für den ganzen Posten, ein neuer Betrag
    /// erst ab seinem Monat. Die Reihenfolge ist dieselbe wie in ui/posten.py,
    /// erst die Merkmale des Postens, dann der Betrag, damit eine neu angelegte
    /// Regel schon die neuen Werte übernimmt.
    @discardableResult
    func postenAendern(_ posten: Posten, name: String, kategorieId: Int64, gruppe: String?,
                       neuerBetrag: Int?, abMonat: String) -> Bool {
        arbeiten { kern in
            if name != posten.name {
                try kern.regelUmbenennen(posten.id, name: name)
            }
            let neueKategorie = self.kategorien.first { $0.id == kategorieId }?.name
            if posten.ersteKategorie != neueKategorie {
                try kern.regelKategorieSetzen(posten.id, kategorieId: kategorieId)
            }
            try kern.regelGruppeSetzen(posten.id, gruppe: gruppe)
            if let neuerBetrag {
                try kern.regelAendern(posten.id, neuerBetrag: neuerBetrag, abMonat: abMonat)
            }
        }
    }

    /// Ein neuer fester Posten. Der Vorschlag für den Fälligkeitsmonat steht im
    /// Dialog, nicht hier.
    @discardableResult
    func postenAnlegen(name: String, betragCent: Int, tag: Int, giltAb: String,
                       kategorieId: Int64, intervall: Int, zuruecklegen: Bool,
                       schonVorhanden: Int, gruppe: String?) -> Bool {
        arbeiten { kern in
            try kern.regelAnlegen(name: name, betrag: betragCent, tag: tag, giltAb: giltAb,
                                  kategorieId: kategorieId, intervall: intervall,
                                  zuruecklegen: zuruecklegen, schonVorhanden: schonVorhanden,
                                  gruppe: gruppe)
        }
    }

    /// Verschiebt den nächsten Termin eines Postens, also Fälligkeitsmonat und
    /// Tag im Monat. Beides hängt zusammen, im Dialog steht ein Datum.
    @discardableResult
    func postenTerminSetzen(_ posten: Posten, monat: String, tag: Int) -> Bool {
        arbeiten { kern in
            if tag != posten.tagImMonat {
                try kern.regelSolltagSetzen(posten.id, tag: tag)
            }
            if monat != posten.giltAb {
                try kern.regelFaelligkeitSetzen(posten.id, monat: monat)
            }
        }
    }

    @discardableResult
    func postenKorrektur(_ posten: Posten, betragCent: Int, datum: String) -> Bool {
        arbeiten { kern in
            try kern.korrektur(posten.id, betrag: betragCent, datum: datum)
        }
    }

    /// Ein geplanter Abschlag wird zur Buchung, auf Wunsch mit anderem Betrag
    /// oder Datum, wie `Haushalt.bestaetigen`.
    @discardableResult
    func bestaetigen(_ buchung: Buchung, betragCent: Int? = nil, datum: String? = nil) -> Bool {
        arbeiten { kern in
            try kern.bestaetigen(buchung.id, betrag: betragCent, datum: datum)
        }
    }

    /// Nur die Gruppe einer Buchung, für geplante Abschläge, die keinen Dialog
    /// Buchung bearbeiten haben. Nil heißt nicht gesetzt und erbt, leer heißt
    /// bewusst keine.
    @discardableResult
    func buchungGruppeSetzen(_ buchung: Buchung, gruppe: String?) -> Bool {
        arbeiten { kern in
            try kern.buchungAendern(buchung.id, gruppe: .setzen(gruppe))
        }
    }

    @discardableResult
    func postenBeenden(_ posten: Posten, letzterMonat: String) -> Bool {
        arbeiten { kern in
            try kern.regelBeenden(posten.id, letzterMonat: letzterMonat)
        }
    }

    /// Löschen heißt beim Posten beenden zum Vormonat. Vergangene Buchungen
    /// bleiben, der geplante Abschlag dieses Monats verschwindet. Gilt der
    /// Posten erst ab diesem Monat, gäbe es keinen gültigen Vormonat, dann wird
    /// er ganz gelöscht.
    @discardableResult
    func postenLoeschen(_ posten: Posten) -> Bool {
        arbeiten { kern in
            if posten.nurGanzLoeschbar(heuteMonat: self.heuteMonat) {
                try kern.regelLoeschen(posten.id)
            } else {
                try kern.regelBeenden(posten.id, letzterMonat: Monat.plus(self.heuteMonat, -1))
            }
        }
    }

    // MARK: Kategorien und Einstellungen

    @discardableResult
    func kategorieAnlegen(name: String, gruppe: String?, icon: String?) -> Bool {
        arbeiten { kern in
            try kern.kategorieAnlegen(name: name, gruppe: gruppe, icon: icon)
        }
    }

    @discardableResult
    func kategorieAendern(_ kategorie: Kategorie, neuerName: String?, gruppe: String?,
                          icon: String?) -> Bool {
        arbeiten { kern in
            try kern.kategorieAendern(kategorie.id, neuerName: neuerName, gruppe: gruppe,
                                      icon: icon)
        }
    }

    /// Höchstens acht Favoriten, denn die Schnelleingabe hat acht Kacheln. Ein
    /// neuer Favorit stellt sich hinten an, wie in ui/einstellungen.py.
    @discardableResult
    func favoritUmschalten(_ kategorie: Kategorie) -> Bool {
        if !kategorie.favorit, favoriten.count >= 8 {
            meldung = "Höchstens acht Favoriten, erst einen Stern entfernen."
            return false
        }
        let neu = !kategorie.favorit
        let ergebnis = arbeiten { kern in
            try kern.kategorieAendern(kategorie.id, favorit: neu)
            if neu {
                let namen = self.favoriten.filter { $0.id != kategorie.id }.map(\.name)
                try kern.kategorienOrdnen(namen + [kategorie.name])
            }
        }
        return ergebnis
    }

    /// Verschiebt einen Favoriten in der Reihenfolge der Kacheln.
    @discardableResult
    func favoritVerschieben(_ kategorie: Kategorie, _ schritt: Int) -> Bool {
        var namen = favoriten.map(\.name)
        guard let i = namen.firstIndex(of: kategorie.name) else { return false }
        let j = i + schritt
        guard namen.indices.contains(j) else { return false }
        namen.swapAt(i, j)
        return arbeiten { kern in try kern.kategorienOrdnen(namen) }
    }

    @discardableResult
    func kategorieLoeschen(_ kategorie: Kategorie, ersatz: Kategorie) -> Bool {
        arbeiten { kern in
            try kern.kategorieLoeschen(kategorie.id, ersatzId: ersatz.id)
        }
    }

    @discardableResult
    func startsaldoSetzen(betragCent: Int, datum: String) -> Bool {
        arbeiten { kern in try kern.startsaldoSetzen(betragCent: betragCent, datum: datum) }
    }

    @discardableResult
    func einstellungSetzen(_ schluessel: String, _ wert: String) -> Bool {
        arbeiten { kern in try kern.einstellungSetzen(schluessel, wert) }
    }

    func einstellung(_ schluessel: String) -> String? {
        (try? db?.einstellung(schluessel)) ?? nil
    }

    /// Der Startsaldo als Cent, nil wenn keiner gesetzt ist.
    var startsaldoCent: Int? {
        Int(einstellung("startsaldo_cent") ?? "")
    }

    var startsaldoDatum: String? {
        einstellung("startsaldo_datum")
    }

    var autoBestaetigen: Bool {
        einstellung("auto_bestaetigen") == "1"
    }

    let pfad: String

    // MARK: Töpfe

    @discardableResult
    func topfAnlegen(name: String, rate: Int?, ziel: Int?, zielMonat: String?,
                     schonVorhanden: Int, kategorieId: Int64?, gruppe: String?) -> Bool {
        arbeiten { kern in
            try kern.topfAnlegen(name: name, rate: rate, ziel: ziel, zielMonat: zielMonat,
                                 schonVorhanden: schonVorhanden, kategorieId: kategorieId,
                                 gruppe: gruppe)
        }
    }

    @discardableResult
    func topfAendern(_ topf: Topf, name: String, kategorieId: Int64?, gruppe: String?,
                     rate: Int, ziel: Int?) -> Bool {
        arbeiten { kern in
            try kern.topfAendern(topf.id, name: name, kategorieId: kategorieId,
                                 gruppe: gruppe, rate: rate, ziel: ziel)
        }
    }

    @discardableResult
    func topfPausieren(_ topf: Topf) -> Bool {
        arbeiten { kern in
            try kern.topfPausieren(topf.id, pausiert: !topf.pausiert)
        }
    }

    @discardableResult
    func topfAufloesen(_ topf: Topf) -> Bool {
        arbeiten { kern in try kern.topfAufloesen(topf.id) }
    }

    /// Aufstocken kann abgelehnt werden, wenn der Betrag nicht mehr ins Ziel
    /// passt. Die Meldung des Kerns steht danach in `meldung`.
    @discardableResult
    func topfAufstocken(_ topf: Topf, betragCent: Int) -> Bool {
        arbeiten { kern in try kern.topfAufstocken(topf.id, betrag: betragCent) }
    }

    @discardableResult
    func einlageZuruecknehmen(_ einlage: Einlage) -> Bool {
        arbeiten { kern in try kern.topfEinlageLoeschen(einlage.id) }
    }

    // MARK: Einrichtung

    /// Schreibt die Aufträge des Assistenten in ihrer Reihenfolge, alles in
    /// einem Stück, und merkt sich, dass eingerichtet wurde. Geht etwas schief,
    /// bleibt die Datenbank, wie sie war.
    @discardableResult
    func einrichtungSchreiben(_ auftraege: [Auftrag]) -> Bool {
        arbeiten { kern in
            for auftrag in auftraege {
                switch auftrag {
                case .startsaldo(let cent, let datum):
                    try kern.startsaldoSetzen(betragCent: cent, datum: datum)
                case .posten(let name, let betrag, let tag, let giltAb, let kategorie,
                             let intervall, let vorhanden, let gruppe):
                    try kern.regelAnlegen(name: name, betrag: betrag, tag: tag, giltAb: giltAb,
                                          kategorieId: self.kategorie(nach: kategorie)?.id,
                                          intervall: intervall, zuruecklegen: true,
                                          schonVorhanden: vorhanden, gruppe: gruppe)
                case .topf(let name, let rate, let ziel, let zielMonat, let vorhanden,
                           let kategorie, let gruppe):
                    try kern.topfAnlegen(name: name, rate: rate, ziel: ziel,
                                         zielMonat: zielMonat, schonVorhanden: vorhanden,
                                         kategorieId: kategorie.flatMap {
                                             self.kategorie(nach: $0)?.id
                                         },
                                         gruppe: gruppe)
                }
            }
            try kern.einstellungSetzen("eingerichtet", "1")
        }
    }

    // MARK: Sicherung und Export

    /// Der Ordner der Sicherungen zu dieser Datenbank, siehe Pfade.
    var sicherungsordner: URL { Pfade.sicherungen(fuer: pfad) }

    /// Eine Sicherung sofort, wie der Knopf in ui/einstellungen.py. Liefert
    /// die Datei, oder nil mit einer Meldung.
    func sicherungJetzt() -> URL? {
        guard let db, let kern else { return nil }
        do {
            return try Sicherungen.jetzt(db, heute: kern.heute, ordner: sicherungsordner)
        } catch {
            meldung = "Die Sicherung ist gescheitert. \(error.localizedDescription)"
            return nil
        }
    }

    /// Alle Buchungen als CSV in den Ordner Downloads, auf Wunsch nur ein
    /// Zeitraum und mit Kontostand und Rücklagen zu dessen Ende.
    func exportieren(von: String?, bis: String?, mitKonto: Bool) -> URL? {
        guard let kern else { return nil }
        do {
            return try Ausfuhr.csv(kern.alleBuchungen(von: von, bis: bis),
                                   nach: Ausfuhr.gesamtZiel(von: von, bis: bis, heute: kern.heute),
                                   zusatz: mitKonto ? Ausfuhr.kontoZeilen(kern, bis: bis) : [])
        } catch {
            meldung = "Der Export ist gescheitert. \(error.localizedDescription)"
            return nil
        }
    }

    /// Ist schon eingerichtet? Wer Posten oder einen Startsaldo hat, gilt
    /// rückwirkend als eingerichtet, wie in app.py.
    var eingerichtet: Bool {
        // Ließ sich die Datenbank nicht öffnen, gibt es nichts einzurichten.
        // Dann kommt das Hauptfenster, und die Übersicht zeigt die Meldung,
        // statt dass der Assistent Eingaben sammelt, die nirgends landen.
        if db == nil { return true }
        if einstellung("eingerichtet") == "1" { return true }
        return !posten.isEmpty || startsaldoCent != nil
    }

    /// Ein Schreibvorgang in einem Stück, danach wird alles neu gelesen.
    private func arbeiten(_ arbeit: (Kern) throws -> Void) -> Bool {
        guard let db, let kern, schreibbar else {
            meldung = meldung ?? "Diese Datenbank wird nur gelesen."
            return false
        }
        do {
            try db.inEinemStueck { try arbeit(kern) }
            letzteLoeschung = nil
            laden()
            return true
        } catch {
            meldung = error.localizedDescription
            return false
        }
    }

    /// Alle Ausgaben des Monats, auch die außerplanmäßigen. Für das Budget
    /// zählen nicht alle davon, siehe Monatsbild.
    var ausgabenCent: Int {
        buchungen.map(\.betragCent).filter { $0 < 0 }.reduce(0, +)
    }

    var einnahmenCent: Int {
        buchungen.map(\.betragCent).filter { $0 > 0 }.reduce(0, +)
    }

    var ruecklagenCent: Int {
        toepfe.reduce(0) { $0 + $1.stand }
    }
}

/// Die Aktionen für Kurzbefehle halten den Speicher in Strukturen, die Sendable
/// sein müssen (2026-10-05). Er ist es nicht von sich aus, wird aber nur im
/// Hauptthread benutzt, von den Ansichten und von den Aktionen, deren perform
/// auf dem MainActor läuft. Deshalb ist es hier zugesichert und nicht
/// erzwungen. Ein @MainActor an der Klasse selbst zöge jeden Aufruf aus
/// nicht isoliertem Code nach sich, zum Beispiel in init der App.
extension Speicher: @unchecked Sendable {}
