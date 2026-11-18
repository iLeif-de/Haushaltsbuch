import AppIntents
import SwiftUI

/// Das Haushaltsbuch als native Mac App, Fassung 2.0. Es arbeitet auf derselben
/// Datenbank wie Fassung 1.2 in Python und ersetzt sie, siehe mac/README.md.
@main
struct HaushaltsbuchApp: App {
    /// Ohne Vorgabewert, er entsteht in init. Mit `= Speicher()` hier legte
    /// Swift ihn zweimal an, das hielt zwei Verbindungen zur Datenbank offen,
    /// und beim Beenden räumte die eine die -shm Datei unter der anderen weg
    /// (2026-09-27).
    @State private var speicher: Speicher
    /// Wer den Fokus hat, bereichsweise. Cmd N schickt ihn in die
    /// Schnelleingabe, Option Tab wechselt den Bereich, siehe Fokuslenkung.swift.
    @State private var lenkung = Fokuslenkung()
    @State private var bereich: Bereich = .uebersicht
    /// Beim allerersten Start läuft der Assistent statt des Fensters.
    @State private var eingerichtet: Bool

    /// Der mittlere Bereich. Die Schnelleingabe rechts bleibt immer stehen,
    /// genau wie in der Fassung mit Flet.
    @ViewBuilder
    private var inhalt: some View {
        switch bereich {
        case .toepfe: Toepfeansicht(speicher: speicher, lenkung: lenkung)
        case .posten: Postenansicht(speicher: speicher, lenkung: lenkung)
        case .mehr: Einstellungenansicht(speicher: speicher, lenkung: lenkung)
        case .auswertung: Auswertungsansicht(speicher: speicher, lenkung: lenkung)
        default: Uebersichtsansicht(speicher: speicher, lenkung: lenkung)
        }
    }

    init() {
        let speicher = Speicher()
        _speicher = State(initialValue: speicher)
        // Die Aktionen für Kurzbefehle arbeiten über denselben Speicher, siehe
        // Kurzbefehle/Kurzbefehle.swift (2026-09-27)
        AppDependencyManager.shared.add(dependency: speicher)
        // Beim Beenden die Datenbank schließen, sonst bleiben -wal und -shm
        // neben ihr in iCloud liegen, siehe Datenbank.schliessen (2026-09-26)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { speicher.beenden() }
        }
        // Buchungen vom iPhone, jedes Mal wenn das Programm in den Vordergrund
        // kommt, siehe Eingang.swift (2026-09-27)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { speicher.eingangLesen() }
        }
        // Und einmal pro Minute, auch im Hintergrund. Wer das Programm offen
        // lässt, sieht eine Buchung vom iPhone sonst erst beim Hineinklicken.
        // Mehr als ein Blick in den Ordner ist es nicht, solange nichts liegt.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { speicher.eingangLesen() }
        }
        _eingerichtet = State(initialValue: speicher.eingerichtet)
    }

    var body: some Scene {
        // Window und nicht WindowGroup. Das Haushaltsbuch ist eine App mit
        // genau einem Fenster, und WindowGroup legt von sich aus den Eintrag
        // Neues Fenster auf Cmd N. Genau die Taste brauchen wir für eine neue
        // Buchung (2026-09-24).
        Window("Haushaltsbuch", id: "haupt") {
            if speicher.umzugOffen {
                // Beim ersten Start von 2.0 erst fragen, übernehmen oder neu
                // anfangen, siehe Umzugsansicht. Danach entscheidet sich neu,
                // ob der Assistent kommt, nach dem Übernehmen sind die Daten da.
                Umzugsansicht(speicher: speicher) { eingerichtet = speicher.eingerichtet }
            } else if eingerichtet {
                hauptfenster
            } else {
                // Beim allerersten Start führt der Assistent durch vier
                // Schritte, siehe Einrichtung.swift.
                Einrichtungsansicht(speicher: speicher) { eingerichtet = true }
            }
        }
        .windowResizability(.contentMinSize)
        .commands {
            // replacing statt after, damit kein zweiter Eintrag auf Cmd N liegt
            CommandGroup(replacing: .newItem) {
                Button("Neue Buchung") { lenkung.hin(.eingabe) }
                    .keyboardShortcut("n", modifiers: .command)
            }
            // Cmd Komma führt auf dem Mac zu den Einstellungen. Hier stehen sie
            // im Bereich Mehr, zusammen mit Kategorien, Sicherung und Export.
            CommandGroup(replacing: .appSettings) {
                Button("Einstellungen") { gehe(zu: .mehr) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            // Jeder Bereich auf Cmd Option und seiner Nummer in der Leiste.
            // Cmd allein mit einer Ziffer gehört den Kacheln der Schnelleingabe.
            CommandMenu("Gehe zu") {
                ForEach(Array(Bereich.allCases.enumerated()), id: \.element) { i, ziel in
                    Button(ziel.titel) { gehe(zu: ziel) }
                        .keyboardShortcut(KeyEquivalent(Character(String(i + 1))),
                                          modifiers: [.command, .option])
                }
            }
            CommandGroup(replacing: .help) {
                Button("Anleitung Haushaltsbuch") { anleitungOeffnen() }
                    .keyboardShortcut("?", modifiers: .command)
            }
        }
    }

    /// Wechselt den Bereich und setzt den Fokus hinein, wie Option Tab es tut.
    /// Einen Augenblick später, sonst gibt es die Ansicht noch nicht, die auf
    /// den Wunsch hört.
    private func gehe(zu ziel: Bereich) {
        bereich = ziel
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            lenkung.hin(.inhalt)
        }
    }

    /// Die Anleitung liegt als PDF im Programm, dieselbe wie auf der Webseite.
    private func anleitungOeffnen() {
        if let url = Bundle.main.url(forResource: "Anleitung Haushaltsbuch",
                                     withExtension: "pdf") {
            NSWorkspace.shared.open(url)
        }
    }

    private var hauptfenster: some View {
        HStack(spacing: 0) {
                Bereichsleiste(gewaehlt: $bereich, lenkung: lenkung)
                Divider()
                inhalt
                Divider()
                Schnelleingabe(speicher: speicher, lenkung: lenkung)
            }
        .frame(minWidth: 900, minHeight: 540)
    }
}
