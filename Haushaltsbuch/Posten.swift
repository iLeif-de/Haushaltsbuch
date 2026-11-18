import SwiftUI

/// Die festen Posten, aufgebaut wie ui/posten.py. Einnahmen und Ausgaben stehen
/// als zwei benannte Blöcke in derselben Liste, größter Betrag zuerst.
///
/// Der Stift öffnet Name, Kategorie, Gruppe und Betrag, das Menü am Zeilenende
/// Nachzahlung, Rückzahlung, Beenden und Löschen. Ein neuer Posten fehlt noch,
/// siehe mac/README.md.
struct Postenansicht: View {
    let speicher: Speicher
    let lenkung: Fokuslenkung

    @FocusState private var imFokus: Bool
    @State private var auswahl: Int64?
    @State private var imDialog: Postenvorgang?
    @State private var loeschfrage: Posten?
    /// Die Breite der Liste. Darunter passen nicht alle Spalten nebeneinander,
    /// dann rutschen Kategorie, Gruppe und Rhythmus in eine zweite Zeile
    /// (2026-09-25).
    @State private var breite: CGFloat = 0

    private var schmal: Bool { breite > 0 && breite < 620 }

    /// Welcher Dialog offen ist. Identifiable, damit sheet ihn führen kann.
    enum Postenvorgang: Identifiable {
        case bearbeiten(Posten)
        case nachzahlung(Posten)
        case rueckzahlung(Posten)
        case beenden(Posten)
        case neu

        var id: String {
            switch self {
            case .bearbeiten(let p): return "b\(p.id)"
            case .nachzahlung(let p): return "n\(p.id)"
            case .rueckzahlung(let p): return "r\(p.id)"
            case .beenden(let p): return "e\(p.id)"
            case .neu: return "neu"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Feste Posten").font(.title2).fontWeight(.semibold)
                Spacer()
                Text("Stand \(Datumsformat.monatsname(speicher.monat))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Neu", systemImage: "plus") { imDialog = .neu }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .help("Neuer fester Posten, Cmd Umschalt N")
            }

            if speicher.posten.isEmpty {
                Text("Noch keine festen Posten. Mit Neu beginnt es.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(selection: $auswahl) {
                    if !einnahmen.isEmpty {
                        Section("Einnahmen") {
                            ForEach(einnahmen) { zeile($0) }
                        }
                    }
                    if !ausgaben.isEmpty {
                        Section("Ausgaben") {
                            ForEach(ausgaben) { zeile($0) }
                        }
                    }
                }
                .listStyle(.inset)
                .focused($imFokus)
                .breiteMessen(in: $breite)
            }
        }
        .padding(16)
        .frame(minWidth: 470)
        .focusSection()
        .onKeyPress(phases: .down) { druck in taste(druck) }
        .onChange(of: lenkung.wunsch) {
            if lenkung.zone == .inhalt {
                ersteZeileWaehlen()
                imFokus = true
            }
        }
        .onChange(of: imFokus) { _, neu in
            if neu {
                lenkung.meldet(.inhalt)
                ersteZeileWaehlen()
            }
        }
        .sheet(item: $imDialog) { vorgang in
            switch vorgang {
            case .bearbeiten(let p):
                Postendialog(speicher: speicher, posten: p) { imDialog = nil }
            case .nachzahlung(let p):
                Korrekturdialog(speicher: speicher, posten: p, nachzahlung: true) { imDialog = nil }
            case .rueckzahlung(let p):
                Korrekturdialog(speicher: speicher, posten: p, nachzahlung: false) { imDialog = nil }
            case .beenden(let p):
                Beendendialog(speicher: speicher, posten: p) { imDialog = nil }
            case .neu:
                NeuerPostendialog(speicher: speicher) { imDialog = nil }
            }
        }
        .alert("Posten löschen", isPresented: Binding(
            get: { loeschfrage != nil },
            set: { if !$0 { loeschfrage = nil } }
        ), presenting: loeschfrage) { posten in
            Button("Löschen", role: .destructive) {
                speicher.postenLoeschen(posten)
                loeschfrage = nil
            }
            Button("Abbrechen", role: .cancel) { loeschfrage = nil }
        } message: { posten in
            Text("\(posten.name) bucht ab sofort nicht mehr. Vergangene Buchungen bleiben "
                 + "erhalten, der geplante Abschlag dieses Monats verschwindet.")
        }
    }

    /// Dieselben Tasten wie in der Buchungsliste. Enter bearbeitet die gewählte
    /// Zeile, die Rückschritttaste löscht sie, Option Tab wechselt den Bereich.
    private func taste(_ druck: KeyPress) -> KeyPress.Result {
        if Bereichstasten.tab(druck, ring: { _ in imFokus = true },
                              wechsel: lenkung.wechseln) {
            return .handled
        }
        guard let posten = gewaehlterPosten else { return .ignored }
        switch druck.key {
        case .space:
            imDialog = .bearbeiten(posten)
            return .handled
        case .delete, .deleteForward:
            loeschfrage = posten
            return .handled
        default:
            return .ignored
        }
    }

    /// Beim Betreten des Bereichs ist eine Zeile gewählt, sonst bewegen die
    /// Pfeiltasten nichts. Gilt in jedem Bereich gleich (2026-09-24).
    private func ersteZeileWaehlen() {
        if auswahl == nil || !speicher.posten.contains(where: { $0.id == auswahl }) {
            auswahl = speicher.posten.first?.id
        }
    }

    private var gewaehlterPosten: Posten? {
        guard let auswahl else { return nil }
        return speicher.posten.first { $0.id == auswahl }
    }

    private var einnahmen: [Posten] { speicher.posten.filter { $0.betragCent > 0 } }
    private var ausgaben: [Posten] { speicher.posten.filter { $0.betragCent < 0 } }

    private func zeile(_ posten: Posten) -> some View {
        Group {
            if schmal { schmaleZeile(posten) } else { breiteZeile(posten) }
        }
        .contentShape(Rectangle())
        // Doppelklick bearbeitet, wie in der Buchungsliste
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            imDialog = .bearbeiten(posten)
        })
        .contextMenu { zeilenmenue(posten) }
    }

    /// Alle Spalten nebeneinander. Der Name bekommt, was übrig ist, aber nie
    /// weniger als 140 Punkte, sonst verschwand er beim Schmalerziehen des
    /// Fensters ganz (2026-09-25).
    private func breiteZeile(_ posten: Posten) -> some View {
        HStack(spacing: 10) {
            Text(posten.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)

            Text(posten.kategorien ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            Text(posten.wirksameGruppe ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 100, alignment: .leading)

            rhythmus(posten)
                .frame(width: 170, alignment: .leading)

            Text(Geld.euro(posten.betragCent))
                .monospacedDigit()
                .foregroundStyle(posten.betragCent > 0 ? Color.green : Color.primary)
                .frame(width: 100, alignment: .trailing)

            zeilenknopf(posten)
        }
    }

    /// Schmale Fassung, zwei Zeilen. Oben Name und Betrag, darunter klein, was
    /// sonst in den Spalten stünde. Abschneiden hilft hier nicht weiter, aus
    /// Miete und Nebenkosten würde sonst Mie.
    private func schmaleZeile(_ posten: Posten) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(posten.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(nebenzeile(posten))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(Geld.euro(posten.betragCent))
                .monospacedDigit()
                .foregroundStyle(posten.betragCent > 0 ? Color.green : Color.primary)
                .frame(width: 100, alignment: .trailing)
            zeilenknopf(posten)
        }
    }

    /// Kategorie, Gruppe und Rhythmus in einem Satzstück, für die schmale Zeile.
    private func nebenzeile(_ posten: Posten) -> String {
        var teile: [String] = []
        if let k = posten.kategorien, !k.isEmpty { teile.append(k) }
        if let g = posten.wirksameGruppe, !g.isEmpty { teile.append(g) }
        teile.append(posten.rhythmus)
        if posten.intervallMonate > 1, let kern = speicher.kern {
            teile.append("nächste am " + Datumsformat.lesbar(kern.naechsterTermin(posten)))
        }
        return teile.joined(separator: ", ")
    }

    private func rhythmus(_ posten: Posten) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(posten.rhythmus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            // Bei einem nicht monatlichen Posten sagt der Rhythmus allein
            // nicht, wann es so weit ist. Genau daran hat sich schon einmal
            // jemand verrechnet (2026-09-24).
            if posten.intervallMonate > 1, let kern = speicher.kern {
                Text("nächste am " + Datumsformat.lesbar(kern.naechsterTermin(posten)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // Alles über ein Menü, auch das Bearbeiten. Ein eigener Stift daneben
    // brachte nichts, was das Menü nicht auch kann, und beim Löschen ist der
    // Umweg über das Menü sogar erwünscht (2026-09-24).
    private func zeilenknopf(_ posten: Posten) -> some View {
        Menu {
            zeilenmenue(posten)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
        .help("Bearbeiten, Nachzahlung, Rückzahlung, Beenden, Löschen")
    }

    /// Dieselben Einträge im Menü am Zeilenende und im Kontextmenü.
    @ViewBuilder
    private func zeilenmenue(_ posten: Posten) -> some View {
        Button("Bearbeiten") { imDialog = .bearbeiten(posten) }
        Divider()
        Button("Nachzahlung") { imDialog = .nachzahlung(posten) }
        Button("Rückzahlung") { imDialog = .rueckzahlung(posten) }
        Divider()
        Button("Ab Monat beenden") { imDialog = .beenden(posten) }
        Button("Löschen") { loeschfrage = posten }
    }
}
