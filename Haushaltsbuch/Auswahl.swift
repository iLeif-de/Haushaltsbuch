import SwiftUI

/// Tabkette, Auswahlliste und Gruppenfeld.
///
/// **Gemessen am 25. September 2026**, mit ausgeschalteter Tastaturnavigation
/// des Systems, siehe mac/Tastentest:
///
/// | Steuerelement | Fokus | Tasten |
/// | --- | --- | --- |
/// | Textfeld, Datumsfeld | ja | ja |
/// | Knopf, Haken mit `focusable` | ja | über unseren Händler |
/// | `Picker`, `Menu` mit `focusable` | ja | **nein** |
/// | `Picker`, `Menu` ohne `focusable` | **nein** | ja, aber unerreichbar |
///
/// Eine native Aufklappliste ist damit nicht mit der Tastatur zu bedienen,
/// solange die Tastaturnavigation aus ist, und die ist bewusst aus. Deshalb
/// baut `Auswahlknopf` sie selbst, mit Pfeiltasten, Anfangsbuchstaben und
/// Enter. Alles andere bleibt nativ.

/// Ein Knopf, der eine Liste aufklappt, die sich mit der Tastatur bedienen
/// lässt. Leertaste und Pfeiltasten öffnen ihn, in der Liste bewegen die
/// Pfeiltasten, Buchstaben springen zum passenden Eintrag, Enter nimmt ihn,
/// Escape schließt.
struct Auswahlknopf<Marke: Hashable>: View {
    /// Was gerade gewählt ist.
    let wert: String
    let namen: [String]
    var fokus: FocusState<Marke?>.Binding
    let marke: Marke
    /// Welches Glied gerade offen ist, gehört dem Dialog.
    @Binding var offenes: Marke?
    let waehlen: (String) -> Void

    var body: some View {
        Button {
            offenes = marke
        } label: {
            HStack(spacing: 6) {
                Text(wert).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .focusable()
        .focused(fokus, equals: marke)
        .popover(isPresented: Binding(
            get: { offenes == marke },
            set: { if !$0 { offenes = nil } }
        ), arrowEdge: .bottom) {
            Wahlliste(namen: namen, gewaehlt: wert) { name in
                offenes = nil
                if let name { waehlen(name) }
                fokus.wrappedValue = marke
            }
        }
    }
}

/// Die Liste im Popover. Sie nimmt den Fokus selbst und bedient sich wie eine
/// Aufklappliste des Systems.
struct Wahlliste: View {
    let namen: [String]
    let gewaehlt: String
    /// Nil heißt abgebrochen.
    let fertig: (String?) -> Void

    @State private var stelle = 0
    @State private var getippt = ""
    @State private var letzterTipp = Date.distantPast
    @FocusState private var drin: Bool

    var body: some View {
        ScrollViewReader { blick in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(namen.enumerated()), id: \.offset) { i, name in
                        Text(name)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(i == stelle ? Color.accentColor : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(i == stelle ? Color.white : Color.primary)
                            .contentShape(Rectangle())
                            .onTapGesture { fertig(name) }
                            .id(i)
                    }
                }
                .padding(6)
            }
            .onChange(of: stelle) { _, neu in
                withAnimation(.linear(duration: 0.1)) { blick.scrollTo(neu, anchor: .center) }
            }
        }
        .frame(width: 240, height: min(CGFloat(namen.count) * 26 + 16, 320))
        .focusable()
        .focused($drin)
        .onKeyPress(phases: .down) { druck in taste(druck) }
        .task {
            stelle = max(0, namen.firstIndex(of: gewaehlt) ?? 0)
            drin = true
        }
    }

    private func taste(_ druck: KeyPress) -> KeyPress.Result {
        switch druck.key {
        case .downArrow:
            stelle = min(stelle + 1, namen.count - 1)
            return .handled
        case .upArrow:
            stelle = max(stelle - 1, 0)
            return .handled
        case .return, .space:
            fertig(namen.indices.contains(stelle) ? namen[stelle] : nil)
            return .handled
        case .escape:
            fertig(nil)
            return .handled
        default:
            return tippen(druck.characters)
        }
    }

    /// Anfangsbuchstaben wie bei einer Aufklappliste des Systems. Was in kurzem
    /// Abstand getippt wird, zählt zusammen, sonst beginnt die Suche neu.
    private func tippen(_ zeichen: String) -> KeyPress.Result {
        let sauber = zeichen.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sauber.count == 1, sauber.rangeOfCharacter(from: .alphanumerics) != nil else {
            return .ignored
        }
        let jetzt = Date()
        getippt = jetzt.timeIntervalSince(letzterTipp) > 1 ? sauber : getippt + sauber
        letzterTipp = jetzt
        if let treffer = namen.firstIndex(where: {
            $0.lowercased().hasPrefix(getippt.lowercased())
        }) {
            stelle = treffer
        }
        return .handled
    }
}

/// Tab, Umschalt Tab und das Auslösen in einem Dialog oder einem Bereich.
///
/// **Die Regel ist überall dieselbe.** Tab und Umschalt Tab bewegen den Fokus,
/// in einem Dialog im Ring, die **Leertaste löst aus**, worauf der Fokus steht,
/// also Knopf, Haken oder Aufklappliste, und **Enter gehört dem Standardknopf**
/// des Fensters, in einem Dialog also Speichern oder Anlegen (2026-09-24).
/// Pfeil hoch und runter öffnen zusätzlich eine Aufklappliste, wie gewohnt.
///
/// Der Händler sieht eine Taste nur, wenn das Element sie nicht selbst
/// verbraucht. Ein Textfeld behält seine Leertaste also.
struct Dialogtasten<Marke: Hashable>: ViewModifier {
    var fokus: FocusState<Marke?>.Binding
    let kette: [Marke]
    /// Die Glieder, die eine Aufklappliste sind. Nur sie reagieren auf die
    /// Pfeiltasten.
    let listen: Set<Marke>
    /// Was die Leertaste auf diesem Glied tut. true heißt, sie ist verbraucht.
    let ausloesen: (Marke) -> Bool

    func body(content: Content) -> some View {
        content.onKeyPress(phases: .down) { druck in
            if let richtung = Tasten.tabRichtung(druck) {
                weiter(richtung)
                return .handled
            }
            guard let jetzt = fokus.wrappedValue else { return .ignored }
            if druck.key == .space {
                return ausloesen(jetzt) ? .handled : .ignored
            }
            if druck.key == .upArrow || druck.key == .downArrow, listen.contains(jetzt) {
                return ausloesen(jetzt) ? .handled : .ignored
            }
            return .ignored
        }
    }

    private func weiter(_ richtung: Int) {
        guard let start = fokus.wrappedValue ?? kette.first else { return }
        springen(von: start, richtung, versuche: 0)
    }

    /// Setzt den Fokus auf das nächste Glied und fasst nach.
    ///
    /// Nimmt ein Element den Fokus nicht an, bleibt er stehen, wo er war, er
    /// verschwindet nicht. Weitergezählt wird deshalb ab dem **gescheiterten
    /// Ziel** und nicht ab dem Fokus, sonst läuft die Rettung ewig auf dasselbe
    /// gesperrte Glied (2026-09-25, gemessen).
    private func springen(von: Marke, _ richtung: Int, versuche: Int) {
        guard versuche < kette.count, let stelle = kette.firstIndex(of: von) else { return }
        let ziel = kette[((stelle + richtung) % kette.count + kette.count) % kette.count]
        fokus.wrappedValue = ziel
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            if fokus.wrappedValue != ziel {
                springen(von: ziel, richtung, versuche: versuche + 1)
            }
        }
    }
}

extension View {
    /// Der Kürze halber. `ausloesen` bekommt das Glied, auf dem der Fokus
    /// steht, und meldet, ob es etwas damit anfangen konnte.
    func dialogtasten<Marke: Hashable>(fokus: FocusState<Marke?>.Binding, kette: [Marke],
                                       listen: Set<Marke> = [],
                                       ausloesen: @escaping (Marke) -> Bool) -> some View {
        modifier(Dialogtasten(fokus: fokus, kette: kette, listen: listen, ausloesen: ausloesen))
    }
}

/// Das Gruppenfeld mit eigenem Auslöser. Es zeigt die Gruppe, die gilt, der
/// Knopf daneben klappt die vorhandenen auf. Zur Bedeutung von leer siehe
/// Gruppenwahl.
struct Gruppenzeile<Marke: Hashable>: View {
    @Binding var text: String
    let vorhanden: [String]
    var fokus: FocusState<Marke?>.Binding
    /// Das Textfeld und der Auslöser sind zwei Glieder der Kette.
    let feldMarke: Marke
    let knopfMarke: Marke
    @Binding var offenes: Marke?

    var body: some View {
        HStack(spacing: 4) {
            TextField("Gruppe, optional", text: $text)
                .focused(fokus, equals: feldMarke)
            Button {
                offenes = knopfMarke
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .focusable()
            .focused(fokus, equals: knopfMarke)
            .help("Vorhandene Gruppen")
            .popover(isPresented: Binding(
                get: { offenes == knopfMarke },
                set: { if !$0 { offenes = nil } }
            ), arrowEdge: .bottom) {
                Wahlliste(namen: ["Keine Gruppe"] + vorhanden, gewaehlt: text) { name in
                    offenes = nil
                    if let name { text = name == "Keine Gruppe" ? "" : name }
                    fokus.wrappedValue = knopfMarke
                }
            }
        }
    }
}
