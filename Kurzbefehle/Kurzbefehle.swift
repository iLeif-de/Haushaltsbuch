import AppIntents
import Foundation

// Aktionen für Kurzbefehle, Spotlight und Siri, Fassung 2.1 (2026-09-27).
// Sie laufen im Programm selbst und arbeiten über denselben Speicher wie die
// Oberfläche, eine offene Übersicht zeigt eine neue Buchung also sofort. Das
// System startet das Programm dafür bei Bedarf ohne Fenster.
//
// Der Ordner gehört nur zum Programm und nicht zur Bildprobe, die sonst alle
// Quellen des Programms mitübersetzt. Zwei Bündel mit denselben Aktionen
// stünden in Kurzbefehlen doppelt.
//
// Ausführen lässt das System die Aktionen nur bei einer Signatur mit Team ID,
// siehe project.yml. Ad hoc signiert findet Kurzbefehle sie, kann sie aber
// nicht ausführen.

// MARK: - Abfragen

/// Wie viel vom Monatsbudget bleibt, dazu das frei Verfügbare und eine
/// Warnung, wenn es eine gibt. Dieselben Zahlen wie oben in der Übersicht.
/// Zurück kommt ein Monatsstand, dessen Werte sich in Kurzbefehlen einzeln
/// weiterverwenden lassen (2026-09-27). Vorher kam nur das Budget zurück.
struct MonatsbudgetAbfragen: AppIntent {
    static let title: LocalizedStringResource = "Was bleibt diesen Monat"
    static let description = IntentDescription(
        "Sagt, wie viel vom Monatsbudget noch bleibt und was frei verfügbar ist, und gibt alle Zahlen der Übersicht zum Weiterverwenden zurück.")
    static let openAppWhenRun = false

    @Dependency private var speicher: Speicher

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Monatsstand>
        & ProvidesDialog {
        let kern = try Kurzbefehle.bereit(speicher)
        let stand = Monatsstand(kern, monat: speicher.heuteMonat)
        let bild = kern.uebersicht(speicher.heuteMonat)
        var satz = "Diesen Monat bleiben \(Geld.euro(bild.verfuegbarCent))."
        if let frei = kern.freiVerfuegbar() { satz += " Frei verfügbar sind \(Geld.euro(frei))." }
        if let warnung = bild.warnung { satz += " " + warnung }
        return .result(value: stand, dialog: "\(satz)")
    }
}

/// Die Zahlen der Übersicht für einen Monat, mit denselben Vorzeichen wie
/// dort. Ausgaben und Rücklagen stehen also negativ da. In Kurzbefehlen ist
/// jede Zahl eine eigene Eigenschaft, kein Wörterbuch.
struct Monatsstand: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Monatsstand"

    @Property(title: "Monat") var monat: String
    @Property(title: "Bleibt bis Monatsende") var bleibt: IntentCurrencyAmount
    @Property(title: "Frei verfügbar") var freiVerfuegbar: IntentCurrencyAmount?
    @Property(title: "Kontostand") var kontostand: IntentCurrencyAmount?
    @Property(title: "Rücklagen gesamt") var ruecklagen: IntentCurrencyAmount
    @Property(title: "Einnahmen") var einnahmen: IntentCurrencyAmount
    @Property(title: "Ausgaben") var ausgaben: IntentCurrencyAmount
    @Property(title: "Rücklagen diesen Monat") var raten: IntentCurrencyAmount
    @Property(title: "Außerplanmäßig") var ausserplan: IntentCurrencyAmount
    @Property(title: "Budget ausgegeben in Prozent") var budgetProzent: Int
    @Property(title: "Monat vorbei in Prozent") var monatProzent: Int
    @Property(title: "Warnung") var warnung: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(monat)",
                              subtitle: "Bleiben \(Geld.euro(bleibtCent))")
    }

    private var bleibtCent = 0

    init() {}

    @MainActor
    init(_ kern: Kern, monat: String) {
        let bild = kern.uebersicht(monat)
        let e = Kurzbefehle.euro
        self.monat = monat
        bleibtCent = bild.verfuegbarCent
        bleibt = e(bild.verfuegbarCent)
        freiVerfuegbar = kern.freiVerfuegbar().map(e)
        kontostand = kern.kontostand().map(e)
        ruecklagen = e(kern.ruecklagenGesamt(monat))
        einnahmen = e(bild.einnahmenCent)
        // Wie die Karte Ausgaben der Übersicht, alle Ausgaben des Monats
        ausgaben = e(kern.buchungen(monat).map(\.betragCent).filter { $0 < 0 }.reduce(0, +))
        raten = e(-bild.ratenCent)
        ausserplan = e(bild.ausserplanCent)
        budgetProzent = Int((bild.ausgabenAnteil * 100).rounded())
        monatProzent = Int((bild.monatAnteil * 100).rounded())
        warnung = bild.warnung
    }
}

// MARK: - Erfassen

/// Eine Ausgabe, wie aus der Schnelleingabe. Der Betrag wird positiv
/// eingegeben, gebucht wird er als Ausgabe.
struct AusgabeErfassen: AppIntent {
    static let title: LocalizedStringResource = "Ausgabe erfassen"
    static let description = IntentDescription(
        "Trägt eine Ausgabe ins Haushaltsbuch ein, auf Wunsch aus einem Topf bezahlt.")
    static let openAppWhenRun = false

    @Parameter(title: "Betrag in Euro", inclusiveRange: (0.01, 1_000_000))
    var betrag: Double
    @Parameter(title: "Kategorie")
    var kategorie: KategorieEintrag
    @Parameter(title: "Datum", description: "Ohne Angabe heute", kind: .date)
    var datum: Date?
    @Parameter(title: "Notiz")
    var notiz: String?
    @Parameter(title: "Gruppe", description: "Ohne Angabe die der Kategorie",
               optionsProvider: GruppenVorschlaege())
    var gruppe: String?
    @Parameter(title: "Aus einem Topf bezahlen")
    var topf: TopfEintrag?
    @Parameter(title: "Außerplanmäßig", default: false)
    var ausserplanmaessig: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$betrag) für \(\.$kategorie) ausgeben") {
            \.$datum
            \.$notiz
            \.$gruppe
            \.$topf
            \.$ausserplanmaessig
        }
    }

    @Dependency private var speicher: Speicher

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentCurrencyAmount>
        & ProvidesDialog {
        let cent = try Kurzbefehle.cent(betrag)
        try Kurzbefehle.buchen(speicher, betragCent: -cent, kategorie: kategorie, datum: datum,
                               notiz: notiz, gruppe: gruppe, topf: topf,
                               ausserplanmaessig: ausserplanmaessig)
        let satz = "\(Geld.euro(cent)) für \(kategorie.name) gebucht. "
            + Kurzbefehle.bleibtSatz(speicher)
        return .result(value: Kurzbefehle.euro(cent), dialog: "\(satz)")
    }
}

/// Eine Einnahme. Aus einem Topf kommt keine, deshalb ohne Topf.
struct EinnahmeErfassen: AppIntent {
    static let title: LocalizedStringResource = "Einnahme erfassen"
    static let description = IntentDescription("Trägt eine Einnahme ins Haushaltsbuch ein.")
    static let openAppWhenRun = false

    @Parameter(title: "Betrag in Euro", inclusiveRange: (0.01, 1_000_000))
    var betrag: Double
    @Parameter(title: "Kategorie")
    var kategorie: KategorieEintrag
    @Parameter(title: "Datum", description: "Ohne Angabe heute", kind: .date)
    var datum: Date?
    @Parameter(title: "Notiz")
    var notiz: String?
    @Parameter(title: "Gruppe", description: "Ohne Angabe die der Kategorie",
               optionsProvider: GruppenVorschlaege())
    var gruppe: String?
    @Parameter(title: "Außerplanmäßig",
               description: "Etwa eine Steuererstattung, sie landet auf dem Konto und nicht im Monatsbudget",
               default: false)
    var ausserplanmaessig: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$betrag) als \(\.$kategorie) einnehmen") {
            \.$datum
            \.$notiz
            \.$gruppe
            \.$ausserplanmaessig
        }
    }

    @Dependency private var speicher: Speicher

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentCurrencyAmount>
        & ProvidesDialog {
        let cent = try Kurzbefehle.cent(betrag)
        try Kurzbefehle.buchen(speicher, betragCent: cent, kategorie: kategorie, datum: datum,
                               notiz: notiz, gruppe: gruppe, topf: nil,
                               ausserplanmaessig: ausserplanmaessig)
        let satz = "\(Geld.euro(cent)) als \(kategorie.name) gebucht. "
            + Kurzbefehle.bleibtSatz(speicher)
        return .result(value: Kurzbefehle.euro(cent), dialog: "\(satz)")
    }
}

// MARK: - Kategorien, Töpfe und Gruppen zur Auswahl

/// Eine Kategorie, wie Kurzbefehle sie zur Auswahl stellt. Gemerkt wird die
/// ID, ein späteres Umbenennen bricht einen Kurzbefehl also nicht.
struct KategorieEintrag: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Kategorie"
    static let defaultQuery = KategorieAbfrage()

    let id: Int
    let name: String
    let gruppe: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: gruppe.map { "\($0)" })
    }

    init(_ kategorie: Kategorie) {
        id = Int(kategorie.id)
        name = kategorie.name
        gruppe = kategorie.gruppe
    }
}

struct KategorieAbfrage: EntityStringQuery {
    @Dependency private var speicher: Speicher

    @MainActor
    private var alle: [KategorieEintrag] {
        // Die Favoriten zuerst, in ihrer Reihenfolge, wie die Kacheln
        let favoriten = speicher.favoriten
        let rest = speicher.kategorien.filter { k in !favoriten.contains { $0.id == k.id } }
        return (favoriten + rest).map(KategorieEintrag.init)
    }

    @MainActor
    func entities(for identifiers: [Int]) async throws -> [KategorieEintrag] {
        alle.filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [KategorieEintrag] {
        alle.filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    @MainActor
    func suggestedEntities() async throws -> [KategorieEintrag] { alle }
}

/// Ein Topf, aus dem bezahlt werden kann. Aufgelöste stehen nicht zur Wahl.
struct TopfEintrag: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Topf"
    static let defaultQuery = TopfAbfrage()

    let id: Int
    let name: String
    let stand: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(Geld.euro(stand))")
    }
}

struct TopfAbfrage: EntityQuery {
    @Dependency private var speicher: Speicher

    @MainActor
    private var alle: [TopfEintrag] {
        guard let kern = speicher.kern else { return [] }
        return kern.toepfe(speicher.heuteMonat).map {
            TopfEintrag(id: Int($0.zeile.id), name: $0.zeile.name, stand: $0.stand)
        }
    }

    @MainActor
    func entities(for identifiers: [Int]) async throws -> [TopfEintrag] {
        alle.filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [TopfEintrag] { alle }
}

/// Die vergebenen Gruppen als Vorschlag. Eine neue darf man trotzdem
/// hinschreiben, Gruppen entstehen durch Hinschreiben.
struct GruppenVorschlaege: DynamicOptionsProvider {
    @Dependency private var speicher: Speicher

    @MainActor
    func results() async throws -> [String] { speicher.gruppen }
}

// MARK: - Siri und Spotlight

struct HaushaltsbuchKurzbefehle: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: MonatsbudgetAbfragen(),
            phrases: [
                "Was bleibt diesen Monat im \(.applicationName)",
                "Monatsbudget im \(.applicationName)",
            ],
            shortTitle: "Was bleibt diesen Monat",
            systemImageName: "eurosign.circle")
        AppShortcut(
            intent: AusgabeErfassen(),
            phrases: ["Ausgabe im \(.applicationName) erfassen"],
            shortTitle: "Ausgabe erfassen",
            systemImageName: "minus.circle")
        AppShortcut(
            intent: EinnahmeErfassen(),
            phrases: ["Einnahme im \(.applicationName) erfassen"],
            shortTitle: "Einnahme erfassen",
            systemImageName: "plus.circle")
    }
}

// MARK: - Gemeinsames

/// Der Zugang der Aktionen zum Speicher. Keine Aktion legt je eine Datenbank
/// an, sonst erschiene die Frage nach dem Umzug von Fassung 1.2 nie mehr und
/// ein Umsteiger finge stillschweigend leer an. Das übernimmt schon der
/// Speicher, der in diesem Fall gar nichts öffnet. Solange das Programm nicht
/// bereit ist, lehnt jede Aktion mit einem Satz ab, was zu tun ist.
enum Kurzbefehle {
    struct Fehler: Error, CustomLocalizedStringResourceConvertible {
        let text: String
        var localizedStringResource: LocalizedStringResource { "\(text)" }
    }

    @MainActor
    static func bereit(_ speicher: Speicher) throws -> Kern {
        if speicher.umzugOffen {
            throw Fehler(text: "Öffne das Haushaltsbuch einmal und entscheide, "
                + "ob deine Daten von Fassung 1.2 übernommen werden.")
        }
        guard let kern = speicher.kern, speicher.schreibbar else {
            throw Fehler(text: speicher.meldung
                ?? "Das Haushaltsbuch kann gerade nicht auf seine Daten zugreifen.")
        }
        guard speicher.eingerichtet else {
            throw Fehler(text: "Öffne das Haushaltsbuch einmal und richte es ein.")
        }
        // Fortschreiben wie beim Öffnen, sonst fehlten die Abschläge des Monats
        speicher.laden()
        return kern
    }

    /// Ein Betrag in Euro als ganze Cent, kaufmännisch gerundet.
    static func cent(_ euro: Double) throws -> Int {
        let cent = Int((euro * 100).rounded())
        guard cent > 0 else { throw Fehler(text: "Der Betrag muss größer als null sein.") }
        return cent
    }

    /// Cent als Eurobetrag für das System. Über Decimal und nicht über eine
    /// Kommazahl, sonst wird aus 16826 Cent 168,2599… und angezeigt 168,27.
    static func euro(_ cent: Int) -> IntentCurrencyAmount {
        IntentCurrencyAmount(amount: Decimal(cent) / 100, currencyCode: "EUR")
    }

    @MainActor
    static func buchen(_ speicher: Speicher, betragCent: Int, kategorie: KategorieEintrag,
                       datum: Date?, notiz: String?, gruppe: String?, topf: TopfEintrag?,
                       ausserplanmaessig: Bool) throws {
        _ = try bereit(speicher)
        let notiz = notiz?.trimmingCharacters(in: .whitespacesAndNewlines)
        let gruppe = gruppe?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = speicher.buchen(
            datum: Datumsformat.iso.string(from: datum ?? Date()), betragCent: betragCent,
            kategorieId: Int64(kategorie.id),
            notiz: notiz?.isEmpty == false ? notiz : nil,
            topfId: topf.map { Int64($0.id) },
            // Leer heißt hier nicht gesetzt, die Gruppe der Kategorie gilt
            gruppe: gruppe?.isEmpty == false ? gruppe : nil,
            ausserplanmaessig: ausserplanmaessig)
        guard ok else {
            throw Fehler(text: speicher.meldung ?? "Die Buchung ließ sich nicht speichern.")
        }
    }

    @MainActor
    static func bleibtSatz(_ speicher: Speicher) -> String {
        guard let bild = speicher.kern?.uebersicht(speicher.heuteMonat) else { return "" }
        return "Diesen Monat bleiben \(Geld.euro(bild.verfuegbarCent))."
    }
}
