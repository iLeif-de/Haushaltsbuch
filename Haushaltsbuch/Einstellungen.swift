import AppKit
import SwiftUI

/// Der Bereich Mehr, aufgebaut wie ui/einstellungen.py. Vier Karten,
/// Kategorien, Startsaldo, Feste Posten und Daten mit Sicherung und Export.
///
/// Tab und Umschalt Tab gehen im Ring durch alle Steuerelemente, die
/// Leertaste löst aus, wie in jedem Bereich (2026-09-26). Vorher sprang Tab
/// hier nur in die Kategorienliste, alles andere war nur mit der Maus zu haben.
struct Einstellungenansicht: View {
    let speicher: Speicher
    let lenkung: Fokuslenkung

    private enum Feld: Hashable {
        case liste, neueKategorie, betrag, datum, setzen, autoBestaetigen,
             finder, sichern, zeitraum, von, bis, konto, exportieren, exportZeigen
    }

    /// Was Sicherung oder Export gemeldet haben. Die Meldung steht direkt unter
    /// dem Knopf, der sie ausgelöst hat, mit Haken oder Warnzeichen. Vorher
    /// stand sie klein am Ende der Karte und war oft gar nicht im Bild
    /// (2026-09-26).
    private struct Rueckmeldung {
        let text: String
        let gelungen: Bool
        /// Die geschriebene Datei, beim Export für Im Finder zeigen.
        var datei: URL?
    }

    @FocusState private var fokus: Feld?
    @State private var auswahl: Int64?
    @State private var imDialog: Kategorienvorgang?
    @State private var loeschfrage: Kategorie?
    @State private var startsaldoText = ""
    @State private var startsaldoDatum = Date()
    @State private var hinweis: String?
    @State private var sicherungsmeldung: Rueckmeldung?
    @State private var exportmeldung: Rueckmeldung?
    @State private var nurZeitraum = false
    @State private var exportVon = Date()
    @State private var exportBis = Date()
    @State private var mitKonto = false

    enum Kategorienvorgang: Identifiable {
        case bearbeiten(Kategorie)
        case neu

        var id: String {
            switch self {
            case .bearbeiten(let k): return "k\(k.id)"
            case .neu: return "neu"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Mehr").font(.title2).fontWeight(.semibold)
                kategorienkarte
                startsaldokarte
                postenkarte
                datenkarte
                if let hinweis {
                    Text(hinweis).font(.callout).foregroundStyle(.orange)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 470)
        .focusSection()
        .onKeyPress(phases: .down) { druck in taste(druck) }
        .onChange(of: lenkung.wunsch) {
            if lenkung.zone == .inhalt {
                ersteZeileWaehlen()
                fokus = .liste
            }
        }
        .onChange(of: fokus) { _, neu in
            if neu != nil { lenkung.meldet(.inhalt) }
            if neu == .liste { ersteZeileWaehlen() }
        }
        .onAppear(perform: startsaldoFuellen)
        .sheet(item: $imDialog) { vorgang in
            switch vorgang {
            case .bearbeiten(let k):
                Kategoriedialog(speicher: speicher, kategorie: k) { imDialog = nil }
            case .neu:
                Kategoriedialog(speicher: speicher, kategorie: nil) { imDialog = nil }
            }
        }
        .alert("Kategorie löschen", isPresented: Binding(
            get: { loeschfrage != nil },
            set: { if !$0 { loeschfrage = nil } }
        ), presenting: loeschfrage) { kategorie in
            ForEach(ersatzvorschlaege(fuer: kategorie)) { ersatz in
                Button("Buchungen nach \(ersatz.name)") {
                    speicher.kategorieLoeschen(kategorie, ersatz: ersatz)
                    loeschfrage = nil
                }
            }
            Button("Abbrechen", role: .cancel) { loeschfrage = nil }
        } message: { kategorie in
            Text("\(kategorie.name) verschwindet. Es gehen keine Buchungen verloren, sie wandern "
                 + "in die gewählte Kategorie.")
        }
    }

    // MARK: Kategorien

    private var kategorienkarte: some View {
        karte("Kategorien") {
            Text("Die Gruppe hier ist nur die Vorgabe. Ein fester Posten oder eine einzelne "
                 + "Buchung kann eine eigene tragen und übersteuert sie damit.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List(selection: $auswahl) {
                ForEach(speicher.kategorien) { kategorie in
                    kategoriezeile(kategorie)
                }
            }
            .listStyle(.inset)
            .frame(height: 320)
            .focused($fokus, equals: .liste)

            HStack {
                Button("Neue Kategorie", systemImage: "plus") { imDialog = .neu }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .focusable()
                    .focused($fokus, equals: .neueKategorie)
                Spacer()
                Text("\(speicher.favoriten.count) von acht Favoriten")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func kategoriezeile(_ kategorie: Kategorie) -> some View {
        HStack(spacing: 8) {
            Image(systemName: Symbole.sfSymbol(kategorie.icon))
                .frame(width: 20)
            Text(kategorie.name)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(kategorie.gruppe ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            // Die Pfeile haben immer ihren Platz, auch ohne Stern. Sonst
            // rutschte die Gruppenspalte bei jeder Kategorie ohne Stern nach
            // rechts (2026-09-26).
            HStack(spacing: 8) {
                if kategorie.favorit {
                    Button {
                        speicher.favoritVerschieben(kategorie, -1)
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .help("Kachel nach vorn")
                    Button {
                        speicher.favoritVerschieben(kategorie, 1)
                    } label: {
                        Image(systemName: "arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .help("Kachel nach hinten")
                }
            }
            .frame(width: 44, alignment: .leading)

            Button {
                if !speicher.favoritUmschalten(kategorie) { hinweis = speicher.meldung }
            } label: {
                Image(systemName: kategorie.favorit ? "star.fill" : "star")
                    .foregroundStyle(kategorie.favorit ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help("Favorit, liegt als Kachel in der Schnelleingabe")

            Button {
                imDialog = .bearbeiten(kategorie)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Bearbeiten")

            Menu {
                Button("Bearbeiten") { imDialog = .bearbeiten(kategorie) }
                Divider()
                Button("Löschen") { loeschfrage = kategorie }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded { imDialog = .bearbeiten(kategorie) })
        .contextMenu {
            Button("Bearbeiten") { imDialog = .bearbeiten(kategorie) }
            Button(kategorie.favorit ? "Kein Favorit" : "Favorit") {
                if !speicher.favoritUmschalten(kategorie) { hinweis = speicher.meldung }
            }
            Divider()
            Button("Löschen") { loeschfrage = kategorie }
        }
    }

    /// Wohin die Buchungen wandern. Sonstiges zuerst, wie die Vorgabe in
    /// ui/einstellungen.py, dann die übrigen.
    private func ersatzvorschlaege(fuer kategorie: Kategorie) -> [Kategorie] {
        let andere = speicher.kategorien.filter { $0.id != kategorie.id }
        let sonstiges = andere.filter { $0.name == "Sonstiges" }
        return sonstiges + andere.filter { $0.name != "Sonstiges" }.prefix(3)
    }

    // MARK: Startsaldo

    private var startsaldokarte: some View {
        karte("Startsaldo") {
            if let stand = speicher.kontostandCent, let datum = speicher.startsaldoDatum {
                Text("Errechneter Kontostand \(Geld.euro(stand)), Startsaldo "
                     + "\(Geld.euro(speicher.startsaldoCent ?? 0)) vom \(Datumsformat.lesbar(datum))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Noch kein Startsaldo gesetzt, deshalb gibt es keinen Kontostand.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Fliesslayout {
                TextField("Betrag in Euro", text: $startsaldoText)
                    .frame(width: 140)
                    .focused($fokus, equals: .betrag)
                DatePicker("", selection: $startsaldoDatum, displayedComponents: .date)
                    .datePickerStyle(.stepperField)
                    .labelsHidden()
                    .focusable()
                    .focused($fokus, equals: .datum)
                Button("Setzen") { startsaldoSetzen() }
                    .focusable()
                    .focused($fokus, equals: .setzen)
            }
            Text("Der Startsaldo gilt zu Beginn dieses Tages, Buchungen des Tages zählen also "
                 + "mit. Er ist keine Buchung und ändert das Monatsbudget nicht.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func startsaldoFuellen() {
        if let cent = speicher.startsaldoCent, startsaldoText.isEmpty {
            startsaldoText = Geld.ohneEuro(cent)
        }
        if let datum = speicher.startsaldoDatum, let d = Datumsformat.iso.date(from: datum) {
            startsaldoDatum = d
        }
    }

    private func startsaldoSetzen() {
        guard let cent = Geld.cent(aus: startsaldoText) else {
            hinweis = "Der Betrag ist nicht zu lesen."
            return
        }
        hinweis = nil
        speicher.startsaldoSetzen(betragCent: cent,
                                  datum: Datumsformat.iso.string(from: startsaldoDatum))
    }

    // MARK: Feste Posten und Daten

    private var postenkarte: some View {
        karte("Feste Posten") {
            Toggle("Feste Posten am Solltag automatisch bestätigen", isOn: autoBestaetigen)
                .focusable()
                .focused($fokus, equals: .autoBestaetigen)
            Text("Ohne das stehen sie als geplant in der Liste und warten auf den Haken.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var autoBestaetigen: Binding<Bool> {
        Binding(get: { speicher.autoBestaetigen },
                set: { speicher.einstellungSetzen("auto_bestaetigen", $0 ? "1" : "0") })
    }

    /// Wo die Daten liegen, Sicherung und Export, wie der Abschnitt Daten in
    /// ui/einstellungen.py.
    private var datenkarte: some View {
        karte("Daten") {
            Text("Die Datenbank liegt unter \(speicher.pfad) und wird über iCloud Drive "
                 + "synchronisiert. Einmal im Monat entsteht zusätzlich automatisch eine "
                 + "Sicherung im normalen Dateisystem unter \(speicher.sicherungsordner.path).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Fliesslayout {
                Button("Sicherung jetzt anlegen") { sichern() }
                    .focusable()
                    .focused($fokus, equals: .sichern)
                Button("Datenbank im Finder zeigen") {
                    NSWorkspace.shared.selectFile(speicher.pfad, inFileViewerRootedAtPath: "")
                }
                .focusable()
                .focused($fokus, equals: .finder)
            }
            if let sicherungsmeldung { rueckmeldung(sicherungsmeldung) }
            // Bewusst kein Knopf, der den Ordner der Sicherungen öffnet. Wer
            // dorthin will, will meist wiederherstellen, und dafür muss das
            // Programm vorher beendet sein, wie in ui/einstellungen.py.
            Text("Zum Wiederherstellen einer Sicherung beende zuerst das Programm. Die "
                 + "Anleitung beschreibt den Weg Schritt für Schritt.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            Text("Export als CSV").font(.subheadline).fontWeight(.semibold)
            Toggle("Nur einen Zeitraum", isOn: $nurZeitraum)
                .focusable()
                .focused($fokus, equals: .zeitraum)
            if nurZeitraum {
                Fliesslayout {
                    Text("Von")
                    DatePicker("", selection: $exportVon, displayedComponents: .date)
                        .datePickerStyle(.stepperField)
                        .labelsHidden()
                        .focusable()
                        .focused($fokus, equals: .von)
                    Text("Bis")
                    DatePicker("", selection: $exportBis, displayedComponents: .date)
                        .datePickerStyle(.stepperField)
                        .labelsHidden()
                        .focusable()
                        .focused($fokus, equals: .bis)
                }
            }
            Toggle("Kontostand und Rücklagen einbeziehen", isOn: $mitKonto)
                .focusable()
                .focused($fokus, equals: .konto)
            Text("Zum Ende des Zeitraums, ohne Eingrenzung zum heutigen Tag.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Exportieren") { exportieren() }
                .focusable()
                .focused($fokus, equals: .exportieren)
            if let exportmeldung {
                rueckmeldung(exportmeldung)
                if let datei = exportmeldung.datei {
                    Button("Im Finder zeigen") {
                        NSWorkspace.shared.activateFileViewerSelecting([datei])
                    }
                    .focusable()
                    .focused($fokus, equals: .exportZeigen)
                }
            }
        }
    }

    private func rueckmeldung(_ meldung: Rueckmeldung) -> some View {
        Label(meldung.text,
              systemImage: meldung.gelungen ? "checkmark.circle.fill"
                                            : "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(meldung.gelungen ? Color.green : Color.orange)
            .textSelection(.enabled)
    }

    private func sichern() {
        if let ziel = speicher.sicherungJetzt() {
            sicherungsmeldung = Rueckmeldung(
                text: "Sicherung angelegt, \(ziel.lastPathComponent)", gelungen: true)
        } else {
            sicherungsmeldung = Rueckmeldung(
                text: speicher.meldung ?? "Die Sicherung ist gescheitert.", gelungen: false)
        }
    }

    private func exportieren() {
        var von: String?
        var bis: String?
        if nurZeitraum {
            von = Datumsformat.iso.string(from: exportVon)
            bis = Datumsformat.iso.string(from: exportBis)
            if let von, let bis, von > bis {
                exportmeldung = Rueckmeldung(text: "Von liegt nach Bis.", gelungen: false)
                return
            }
        }
        if let ziel = speicher.exportieren(von: von, bis: bis, mitKonto: mitKonto) {
            exportmeldung = Rueckmeldung(
                text: "Export angelegt, \(ziel.lastPathComponent) im Ordner Downloads",
                gelungen: true, datei: ziel)
        } else {
            exportmeldung = Rueckmeldung(
                text: speicher.meldung ?? "Der Export ist gescheitert.", gelungen: false)
        }
    }

    // MARK: Gerüst

    private func karte<Inhalt: View>(_ titel: String,
                                     @ViewBuilder inhalt: () -> Inhalt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(titel).font(.headline)
            inhalt()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Tasten

    /// Die Kette in der Reihenfolge der Karten. Von und Bis nur, wenn sie zu
    /// sehen sind.
    private var kette: [Feld] {
        var glieder: [Feld] = [.liste, .neueKategorie, .betrag, .datum, .setzen,
                               .autoBestaetigen, .sichern, .finder, .zeitraum]
        if nurZeitraum { glieder += [.von, .bis] }
        glieder += [.konto, .exportieren]
        if exportmeldung?.datei != nil { glieder.append(.exportZeigen) }
        return glieder
    }

    /// Ein Schritt im Ring. Nimmt ein Glied den Fokus nicht an, geht es ab dem
    /// gescheiterten Ziel weiter, nicht ab dem Fokus, siehe Auswahl.swift.
    private func weiter(_ richtung: Int) {
        springen(von: fokus ?? .liste, richtung, versuche: 0)
    }

    private func springen(von: Feld, _ richtung: Int, versuche: Int) {
        guard versuche < kette.count, let stelle = kette.firstIndex(of: von) else { return }
        let ziel = kette[((stelle + richtung) % kette.count + kette.count) % kette.count]
        fokus = ziel
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            if fokus != ziel { springen(von: ziel, richtung, versuche: versuche + 1) }
        }
    }

    private func taste(_ druck: KeyPress) -> KeyPress.Result {
        if Bereichstasten.tab(druck, ring: { weiter($0) }, wechsel: lenkung.wechseln) {
            return .handled
        }
        // Die Leertaste löst aus, worauf der Fokus steht. Textfeld und
        // Datumsfeld behalten sie, sie kommt dort gar nicht erst an.
        if druck.key == .space {
            switch fokus {
            case .neueKategorie: imDialog = .neu
            case .setzen: startsaldoSetzen()
            case .autoBestaetigen: autoBestaetigen.wrappedValue.toggle()
            case .sichern: sichern()
            case .finder:
                NSWorkspace.shared.selectFile(speicher.pfad, inFileViewerRootedAtPath: "")
            case .zeitraum: nurZeitraum.toggle()
            case .konto: mitKonto.toggle()
            case .exportieren: exportieren()
            case .exportZeigen:
                if let datei = exportmeldung?.datei {
                    NSWorkspace.shared.activateFileViewerSelecting([datei])
                }
            default: break
            }
            if fokus != .liste && fokus != nil { return .handled }
        }
        guard fokus == .liste, let kategorie = gewaehlteKategorie else { return .ignored }
        switch druck.key {
        case .space:
            imDialog = .bearbeiten(kategorie)
            return .handled
        case .delete, .deleteForward:
            loeschfrage = kategorie
            return .handled
        default:
            return .ignored
        }
    }

    private var gewaehlteKategorie: Kategorie? {
        guard let auswahl else { return nil }
        return speicher.kategorien.first { $0.id == auswahl }
    }

    private func ersteZeileWaehlen() {
        if auswahl == nil || !speicher.kategorien.contains(where: { $0.id == auswahl }) {
            auswahl = speicher.kategorien.first?.id
        }
    }
}
