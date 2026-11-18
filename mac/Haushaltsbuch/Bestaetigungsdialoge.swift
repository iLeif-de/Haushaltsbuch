import SwiftUI

/// Einen geplanten Abschlag mit anderem Datum oder Betrag bestätigen, wie
/// `anpassen_und_bestaetigen` in ui/uebersicht.py. Etwa wenn der Strom diesen
/// Monat an einem anderen Tag oder mit einem anderen Betrag abging.
///
/// Das Vorzeichen bleibt, wie es war, das Feld zeigt den Betrag ohne. Tab geht
/// zwischen Datum und Betrag, Enter bestätigt, Escape bricht ab.
struct Bestaetigungsdialog: View {
    let speicher: Speicher
    let buchung: Buchung
    let fertig: () -> Void

    @State private var datum: Date
    @State private var betragText: String
    @State private var hinweis: String?
    @FocusState private var imBetrag: Bool

    init(speicher: Speicher, buchung: Buchung, fertig: @escaping () -> Void) {
        self.speicher = speicher
        self.buchung = buchung
        self.fertig = fertig
        _datum = State(initialValue: Datumsformat.iso.date(from: buchung.datum) ?? Date())
        _betragText = State(initialValue: Geld.ohneEuro(abs(buchung.betragCent)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(buchung.titel) bestätigen").font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Datum")
                    DatePicker("", selection: $datum, displayedComponents: .date)
                        .datePickerStyle(.stepperField)
                        .labelsHidden()
                }
                GridRow {
                    Text("Betrag")
                    TextField("in Euro", text: $betragText)
                        .focused($imBetrag)
                }
            }

            Text("Aus dem geplanten Abschlag wird eine gebuchte Buchung. Datum und Betrag "
                 + "gelten nur für diesen Monat, der Posten selbst bleibt, wie er ist.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let hinweis {
                Text(hinweis).font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { fertig() }
                    .keyboardShortcut(.cancelAction)
                Button("Bestätigen") { sichern() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            imBetrag = true
        }
    }

    private func sichern() {
        guard let cent = Geld.cent(aus: betragText), cent != 0 else {
            hinweis = "Der Betrag fehlt oder ist nicht zu lesen."
            return
        }
        let vorzeichen = buchung.betragCent < 0 ? -1 : 1
        if speicher.bestaetigen(buchung, betragCent: abs(cent) * vorzeichen,
                                datum: Datumsformat.iso.string(from: datum)) {
            fertig()
        } else {
            hinweis = speicher.meldung
        }
    }
}

/// Die Gruppe eines geplanten Abschlags, wie `gruppe_aendern` in
/// ui/uebersicht.py. Eine gebuchte Buchung hat dafür den Dialog Buchung
/// bearbeiten, eine geplante nicht, sie bekommt deshalb diesen, damit die
/// Gruppe wirklich überall änderbar ist.
struct Gruppendialog: View {
    let speicher: Speicher
    let buchung: Buchung
    let fertig: () -> Void

    private enum Feld: Hashable { case gruppe, gruppenmenue }
    private let kette: [Feld] = [.gruppe, .gruppenmenue]

    @State private var gruppentext: String
    @State private var offenes: Feld?
    @FocusState private var fokus: Feld?

    init(speicher: Speicher, buchung: Buchung, fertig: @escaping () -> Void) {
        self.speicher = speicher
        self.buchung = buchung
        self.fertig = fertig
        _gruppentext = State(initialValue: buchung.gruppe ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Gruppe der Buchung").font(.headline)
            Gruppenzeile(text: $gruppentext,
                         vorhanden: Gruppenwahl.auswahl(speicher.gruppen),
                         fokus: $fokus, feldMarke: .gruppe, knopfMarke: .gruppenmenue,
                         offenes: $offenes)
            Text("Leer lassen heißt, die Buchung bekommt keine Gruppe.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { fertig() }
                    .keyboardShortcut(.cancelAction)
                Button("Speichern") { sichern() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
        .dialogtasten(fokus: $fokus, kette: kette, listen: [.gruppenmenue]) { glied in
            guard glied == .gruppenmenue else { return false }
            offenes = glied
            return true
        }
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            fokus = .gruppe
        }
    }

    private func sichern() {
        let wert = Gruppenwahl.gespeichertWert(getippt: gruppentext,
                                               angezeigt: buchung.gruppe ?? "",
                                               gespeichert: buchung.eigeneGruppe,
                                               vorhanden: speicher.gruppen)
        if speicher.buchungGruppeSetzen(buchung, gruppe: wert) { fertig() }
    }
}
