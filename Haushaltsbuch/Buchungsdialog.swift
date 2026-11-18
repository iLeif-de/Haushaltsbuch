import SwiftUI

/// Eine Buchung bearbeiten, wie der Dialog Buchung bearbeiten in ui/uebersicht.py,
/// nur ohne Gruppe und Topf. Die beiden bleiben unberührt stehen, wie auch der
/// Kern es macht, was nicht übergeben wird, bleibt wie es ist.
///
/// Das Vorzeichen bleibt, wie es war. Das Feld zeigt den Betrag ohne Vorzeichen,
/// eine Ausgabe bleibt also eine Ausgabe und eine Einnahme eine Einnahme, genau
/// wie in der Fassung mit Flet.
struct Buchungsdialog: View {
    let speicher: Speicher
    let buchung: Buchung
    /// Wird gerufen, wenn der Dialog zu ist, egal ob gespeichert oder nicht.
    let fertig: () -> Void

    private enum Feld: Hashable {
        case datum, betrag, kategorie, gruppe, gruppenmenue, topf, notiz, ausserplan
    }

    /// Die Kette dieses Dialogs. Tab läuft darin im Ring, ein Dialog ist modal,
    /// da ist das richtig. Siehe Auswahl.swift.
    private let kette: [Feld] = [.datum, .betrag, .kategorie, .gruppe, .gruppenmenue,
                                 .topf, .notiz, .ausserplan]

    @State private var datum: Date
    @State private var betragText: String
    @State private var kategorieName: String
    @State private var notiz: String
    @State private var gruppentext: String
    @State private var topfId: Int64?
    @State private var ausserplan: Bool
    @State private var hinweis: String?
    @State private var offenes: Feld?
    @FocusState private var fokus: Feld?

    private let vorzeichen: Int
    private let angezeigteGruppe: String

    init(speicher: Speicher, buchung: Buchung, fertig: @escaping () -> Void) {
        self.speicher = speicher
        self.buchung = buchung
        self.fertig = fertig
        _datum = State(initialValue: Datumsformat.iso.date(from: buchung.datum) ?? Date())
        // Ohne Vorzeichen und ohne Eurozeichen, so wie es sich tippen lässt
        _betragText = State(initialValue: Geld.euro(abs(buchung.betragCent))
            .replacingOccurrences(of: " €", with: ""))
        _kategorieName = State(initialValue: buchung.kategorie)
        _notiz = State(initialValue: buchung.notiz ?? "")
        angezeigteGruppe = buchung.gruppe ?? ""
        _gruppentext = State(initialValue: buchung.gruppe ?? "")
        _topfId = State(initialValue: buchung.topfId)
        _ausserplan = State(initialValue: buchung.ausserplanmaessig)
        vorzeichen = buchung.betragCent < 0 ? -1 : 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Buchung bearbeiten").font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Datum")
                    DatePicker("", selection: $datum, displayedComponents: .date)
                        .datePickerStyle(.stepperField)
                        .labelsHidden()
                        .focusable()
                        .focused($fokus, equals: .datum)
                }
                GridRow {
                    Text(vorzeichen < 0 ? "Betrag" : "Einnahme")
                    TextField("in Euro", text: $betragText)
                        .focused($fokus, equals: .betrag)
                        .onSubmit(sichern)
                }
                GridRow {
                    Text("Kategorie")
                    Auswahlknopf(wert: kategorieName, namen: kategorienamen, fokus: $fokus,
                                 marke: .kategorie, offenes: $offenes) { kategorieName = $0 }
                }
                GridRow {
                    Text("Gruppe")
                    Gruppenzeile(text: $gruppentext,
                                 vorhanden: Gruppenwahl.auswahl(speicher.gruppen),
                                 fokus: $fokus, feldMarke: .gruppe, knopfMarke: .gruppenmenue,
                                 offenes: $offenes)
                }
                GridRow {
                    Text("Aus einem Topf")
                    Auswahlknopf(wert: topfName,
                                 namen: ["Kein Topf"] + speicher.toepfe.map(\.name),
                                 fokus: $fokus, marke: .topf, offenes: $offenes) { name in
                        topfId = speicher.toepfe.first { $0.name == name }?.id
                    }
                }
                GridRow {
                    Text("Notiz")
                    TextField("was es konkret war", text: $notiz)
                        .focused($fokus, equals: .notiz)
                        .onSubmit(sichern)
                }
            }

            Toggle("Außerplanmäßig, aus dem Konto statt aus dem Monatsbudget", isOn: $ausserplan)
                .font(.callout)
                .focusable()
                .focused($fokus, equals: .ausserplan)

            if buchung.ausPosten {
                Text("Diese Buchung gehört zu einem festen Posten. Änderungen hier gelten "
                     + "nur für sie, nicht für den Posten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let hinweis {
                Text(hinweis).font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { fertig() }
                    .keyboardShortcut(.cancelAction)
                Button("Speichern") { sichern() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
        // Die Aufklapplisten bedient das System, unsere Leertaste schaltet nur
        // den Schalter. Enter gehört dem Standardknopf.
        .dialogtasten(fokus: $fokus, kette: kette,
                      listen: [.kategorie, .gruppenmenue, .topf]) { glied in
            if glied == .ausserplan {
                ausserplan.toggle()
                return true
            }
            guard [.kategorie, .gruppenmenue, .topf].contains(glied) else { return false }
            offenes = glied
            return true
        }
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            fokus = .betrag
        }
    }

    private var kategorienamen: [String] {
        var namen = speicher.kategorien.map(\.name)
        // Die Kategorie einer alten Buchung kann inzwischen abgewählt sein
        if !namen.contains(kategorieName) { namen.append(kategorieName) }
        return namen
    }

    private var topfName: String {
        speicher.toepfe.first { $0.id == topfId }?.name ?? "Kein Topf"
    }

    private func sichern() {
        guard let cent = Geld.cent(aus: betragText) else {
            hinweis = "Der Betrag ist nicht zu lesen."
            fokus = .betrag
            return
        }
        guard let kategorie = speicher.kategorie(nach: kategorieName) else {
            hinweis = "Diese Kategorie gibt es nicht mehr, bitte eine andere wählen."
            return
        }
        let betrag = abs(cent) * vorzeichen
        // Das Feld zeigt die Gruppe, die gilt. Unverändert bleibt eine geerbte
        // geerbt, geleert heißt keine Gruppe, nur für diese Buchung.
        let gruppe = Gruppenwahl.gespeichertWert(
            getippt: gruppentext, angezeigt: angezeigteGruppe,
            gespeichert: buchung.eigeneGruppe, vorhanden: speicher.gruppen)
        if speicher.buchungAendern(buchung.id, datum: Datumsformat.iso.string(from: datum),
                                   betragCent: betrag, kategorieId: kategorie.id,
                                   notiz: notiz, topfId: topfId, gruppe: gruppe,
                                   ausserplanmaessig: ausserplan) {
            fertig()
        } else {
            hinweis = speicher.meldung
        }
    }
}
