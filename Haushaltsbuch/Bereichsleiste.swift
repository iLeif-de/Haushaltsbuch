import SwiftUI

/// Die Bereiche, die es später alle geben soll, in derselben Reihenfolge wie die
/// Leiste in der Fassung mit Flet. Was noch nicht gebaut ist, steht grau da und
/// sagt das auch, statt zu fehlen.
enum Bereich: String, CaseIterable, Identifiable {
    case uebersicht, auswertung, posten, toepfe, mehr

    var id: String { rawValue }

    var titel: String {
        switch self {
        case .uebersicht: return "Übersicht"
        case .auswertung: return "Auswertung"
        case .posten: return "Posten"
        case .toepfe: return "Töpfe"
        case .mehr: return "Mehr"
        }
    }

    var symbol: String {
        switch self {
        case .uebersicht: return "house"
        case .auswertung: return "chart.bar"
        case .posten: return "repeat"
        case .toepfe: return "banknote"
        case .mehr: return "gearshape"
        }
    }

    var gebaut: Bool {
        true   // alle fünf sind gebaut
    }
}

/// Die schmale Leiste links. Ein Knopf je Bereich, der gewählte ist hinterlegt.
/// Mit Tab läuft der Fokus im Ring durch die gebauten Bereiche, die Leertaste
/// wählt, Option Tab geht zum nächsten Bereich des Fensters.
struct Bereichsleiste: View {
    @Binding var gewaehlt: Bereich
    let lenkung: Fokuslenkung

    @FocusState private var fokus: Bereich?

    private var kette: [Bereich] { Bereich.allCases.filter(\.gebaut) }

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Bereich.allCases) { bereich in
                Button {
                    gewaehlt = bereich
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: bereich.symbol)
                            .font(.system(size: 16))
                        Text(bereich.titel)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .frame(width: 64, height: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(farbe(bereich))
                .background(gewaehlt == bereich ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 8))
                .help(bereich.gebaut ? bereich.titel : "\(bereich.titel), noch nicht gebaut")
                .disabled(!bereich.gebaut)
                .focusable(bereich.gebaut)
                .focused($fokus, equals: bereich)
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .frame(width: 76)
        .focusSection()
        .onKeyPress(phases: .down) { druck in taste(druck) }
        .onChange(of: lenkung.wunsch) {
            if lenkung.zone == .leiste { fokus = gewaehlt.gebaut ? gewaehlt : kette.first }
        }
        .onChange(of: fokus) { _, neu in
            if neu != nil { lenkung.meldet(.leiste) }
        }
        .onChange(of: gewaehlt) {
            // Wechselt der Bereich, bekommt der neue Inhalt den Fokus und dort
            // eine gewählte Zeile. Sonst müsste man erst Option Tab drücken.
            lenkung.hin(.inhalt)
        }
    }

    private func taste(_ druck: KeyPress) -> KeyPress.Result {
        if Bereichstasten.tab(druck, ring: { weiter($0) }, wechsel: lenkung.wechseln) {
            return .handled
        }
        // Die Leertaste wählt den Bereich, auf dem der Fokus steht
        if druck.key == .space, let bereich = fokus {
            gewaehlt = bereich
            return .handled
        }
        return .ignored
    }

    private func weiter(_ schritt: Int, versuche: Int = 0) {
        let glieder = kette
        guard !glieder.isEmpty, versuche < glieder.count else { return }
        let ziel: Bereich
        if let jetzt = fokus, let stelle = glieder.firstIndex(of: jetzt) {
            ziel = glieder[((stelle + schritt) % glieder.count + glieder.count) % glieder.count]
        } else {
            ziel = glieder[0]
        }
        fokus = ziel
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            // Siehe Auswahl.swift, der Fokus bleibt stehen statt zu
            // verschwinden (2026-09-25, gemessen).
            if fokus != ziel {
                weiter(schritt, versuche: versuche + 1)
            }
        }
    }

    private func farbe(_ bereich: Bereich) -> Color {
        if !bereich.gebaut { return .secondary.opacity(0.5) }
        return gewaehlt == bereich ? .accentColor : .primary
    }
}
