import SwiftUI

/// Die Töpfe, aufgebaut wie ui/toepfe.py. Je Topf eine Karte mit Titelzeile,
/// Balken und einer Beschreibung in derselben Reihenfolge wie dort.
///
/// Ein eigener Topf lässt sich bearbeiten, aufstocken, pausieren und auflösen.
/// Ein automatischer gehört seinem festen Posten und wird dort geändert.
struct Toepfeansicht: View {
    let speicher: Speicher
    let lenkung: Fokuslenkung

    /// Die Kette dieses Bereichs ist kurz, es gibt nur die Liste. In ihr
    /// bewegen die Pfeiltasten die Auswahl, das macht das System.
    @FocusState private var imFokus: Bool
    @State private var auswahl: Int64?
    @State private var imDialog: Topfvorgang?
    @State private var auflosefrage: Topf?

    enum Topfvorgang: Identifiable {
        case bearbeiten(Topf)
        case aufstocken(Topf)
        case neu

        var id: String {
            switch self {
            case .bearbeiten(let t): return "b\(t.id)"
            case .aufstocken(let t): return "a\(t.id)"
            case .neu: return "neu"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Töpfe").font(.title2).fontWeight(.semibold)
                Spacer()
                Text(Datumsformat.monatsname(speicher.monat))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Neu", systemImage: "plus") { imDialog = .neu }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .help("Neuer Topf, Cmd Umschalt N")
            }

            if speicher.toepfe.isEmpty {
                Text("Noch keine Töpfe. Nicht monatliche Posten legen ihren Topf "
                     + "selbst an, eigene entstehen mit Neu.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(speicher.toepfe, selection: $auswahl) { topf in
                    karte(topf)
                }
                .listStyle(.inset)
                .focused($imFokus)
                HStack {
                    Spacer()
                    Text("Rücklagen zusammen \(Geld.euro(speicher.ruecklagenCent))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
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
            case .bearbeiten(let t):
                Topfdialog(speicher: speicher, topf: t) { imDialog = nil }
            case .aufstocken(let t):
                Aufstockdialog(speicher: speicher, topf: t) { imDialog = nil }
            case .neu:
                NeuerTopfdialog(speicher: speicher) { imDialog = nil }
            }
        }
        .alert("Topf auflösen", isPresented: Binding(
            get: { auflosefrage != nil },
            set: { if !$0 { auflosefrage = nil } }
        ), presenting: auflosefrage) { topf in
            Button("Auflösen", role: .destructive) {
                speicher.topfAufloesen(topf)
                auflosefrage = nil
            }
            Button("Abbrechen", role: .cancel) { auflosefrage = nil }
        } message: { topf in
            Text("\(topf.name) sammelt danach nicht mehr. Der Stand von "
                 + "\(Geld.euro(topf.stand)) wird wieder frei verfügbar.")
        }
    }

    /// Dieselben Tasten wie in den anderen Listen. Enter oder Leertaste öffnet,
    /// die Rückschritttaste fragt nach dem Auflösen.
    private func taste(_ druck: KeyPress) -> KeyPress.Result {
        if Bereichstasten.tab(druck, ring: { _ in imFokus = true },
                              wechsel: lenkung.wechseln) {
            return .handled
        }
        guard let topf = gewaehlterTopf, !topf.automatisch else { return .ignored }
        switch druck.key {
        case .space:
            imDialog = .bearbeiten(topf)
            return .handled
        case .delete, .deleteForward:
            auflosefrage = topf
            return .handled
        default:
            return .ignored
        }
    }

    private var gewaehlterTopf: Topf? {
        guard let auswahl else { return nil }
        return speicher.toepfe.first { $0.id == auswahl }
    }

    /// Beim Betreten des Bereichs ist eine Zeile gewählt, sonst bewegen die
    /// Pfeiltasten nichts. Gilt in jedem Bereich gleich (2026-09-24).
    private func ersteZeileWaehlen() {
        if auswahl == nil || !speicher.toepfe.contains(where: { $0.id == auswahl }) {
            auswahl = speicher.toepfe.first?.id
        }
    }

    private func karte(_ topf: Topf) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(topf.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let kategorie = topf.zeile.kategorie {
                    Text(kategorie)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let gruppe = topf.zeile.wirksameGruppe, !gruppe.isEmpty {
                    Text(gruppe)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if topf.automatisch {
                    Text("aus festem Posten")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Button {
                        imDialog = .bearbeiten(topf)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Bearbeiten")

                    Button {
                        imDialog = .aufstocken(topf)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Aufstocken")

                    Menu {
                        Button(topf.pausiert ? "Fortsetzen" : "Pausieren") {
                            speicher.topfPausieren(topf)
                        }
                        Divider()
                        Button("Auflösen") { auflosefrage = topf }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 24)
                    .help("Pausieren oder auflösen")
                }
            }

            // Ohne Ziel gibt es nichts zu füllen, also auch keinen Balken
            if let ziel = topf.zielCent, ziel > 0 {
                ProgressView(value: min(1, Double(topf.stand) / Double(ziel)))
                    .progressViewStyle(.linear)
            }

            Text(Texte.topfBeschreibung(topf, monat: speicher.monat))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if !topf.automatisch { imDialog = .bearbeiten(topf) }
        })
        .contextMenu {
            if topf.automatisch {
                Text("Dieser Topf gehört zu einem festen Posten")
            } else {
                Button("Bearbeiten") { imDialog = .bearbeiten(topf) }
                Button("Aufstocken") { imDialog = .aufstocken(topf) }
                Button(topf.pausiert ? "Fortsetzen" : "Pausieren") {
                    speicher.topfPausieren(topf)
                }
                Divider()
                Button("Auflösen") { auflosefrage = topf }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

}
