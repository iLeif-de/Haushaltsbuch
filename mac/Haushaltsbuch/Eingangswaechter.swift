import Foundation

/// Beobachtet den Ordner Eingang und meldet, sobald sich darin etwas ändert,
/// etwa weil iCloud eine Buchung vom iPhone gebracht hat (2026-09-27). Dann
/// wird sofort gebucht und nicht erst beim nächsten Blick, der einmal pro
/// Minute bleibt, als Netz, falls ein Ereignis ausbleibt. Siehe Eingang.swift
/// und docs/kurzbefehle.md.
///
/// Beobachtet wird mit den Dateisystemereignissen des Ordners selbst. Eine
/// NSMetadataQuery sähe in iCloud nur den eigenen Container des Programms und
/// nicht einen beliebigen Ordner in iCloud Drive.
final class Eingangswaechter {
    private let ordner: URL
    private let melden: () -> Void
    private var quelle: DispatchSourceFileSystemObject?
    private var verzoegerung: DispatchWorkItem?

    init(ordner: URL, melden: @escaping () -> Void) {
        self.ordner = ordner
        self.melden = melden
        starten()
    }

    deinit { quelle?.cancel() }

    private func starten() {
        try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        let beschreiber = open(ordner.path, O_EVTONLY)
        guard beschreiber >= 0 else { return }
        let quelle = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: beschreiber, eventMask: [.write, .rename, .delete], queue: .main)
        quelle.setEventHandler { [weak self, weak quelle] in
            guard let self, let quelle else { return }
            // Wurde der Ordner selbst verschoben oder gelöscht, gilt der alte
            // Beschreiber nicht mehr, dann von vorn
            if !quelle.data.isDisjoint(with: [.rename, .delete]) {
                quelle.cancel()
                self.starten()
            }
            self.bald()
        }
        quelle.setCancelHandler { close(beschreiber) }
        quelle.resume()
        self.quelle = quelle
    }

    /// Eine Sekunde warten, bis sich der Ordner beruhigt hat. iCloud legt oft
    /// erst einen Platzhalter an und dann die Datei, und das eigene Verschieben
    /// nach Übernommen löst ebenfalls Ereignisse aus.
    private func bald() {
        verzoegerung?.cancel()
        let arbeit = DispatchWorkItem { [weak self] in self?.melden() }
        verzoegerung = arbeit
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: arbeit)
    }
}
