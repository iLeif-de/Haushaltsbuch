import SwiftUI

/// Die Schnelleingabe, und damit der Grund für dieses Versuchsstück.
///
/// **Klassische Tastaturbedienung.** Tab und Umschalt Tab bewegen den Fokus,
/// die Leertaste wählt oder schaltet das Element, auf dem er steht, Enter
/// speichert. Die Pfeiltasten gehören dem System, also dem Datumsfeld zum
/// Zählen, dem Textfeld für den Cursor und einem offenen Menü zum Blättern
/// darin. Eigene Pfeiltastenwege gibt es nicht mehr, sie waren doppelt belegt
/// und standen dem gewohnten Verhalten im Weg (2026-09-24).
///
/// **Die Kette.** `kette` führt vom Datum bis zum Speichernknopf und schließt
/// sich zum Ring, vom Speichern führt Tab zurück zum Datum. Genau das war in
/// Flet nicht zu bauen. Damit der Ring keine Falle wird, holt Cmd N den Fokus
/// von überall in den Betrag, Escape leert die Eingabe, und die Monate blättert
/// Cmd Alt Pfeil, ohne den Fokus zu bewegen, siehe Uebersicht.swift.
///
/// | Taste | Wirkung |
/// | --- | --- |
/// | Tab, Umschalt Tab | einen Schritt weiter oder zurück, im Ring |
/// | Leertaste | wählt die Kachel, schaltet den Schalter, klappt auf und zu |
/// | Enter | speichert, solange der Fokus in der Eingabe steht |
/// | Escape | leert die Eingabe |
/// | Cmd 1 bis Cmd 8 | wählt eine Kachel, ganz ohne Fokus |
/// | Pfeiltasten | dem System überlassen, im Datum zählen sie |
/// | `+` oder `-` am Betrag | verschiebt das Datum um einen Tag |
struct Schnelleingabe: View {
    let speicher: Speicher
    /// Wer den Fokus hat, bereichsweise. Option Tab wechselt den Bereich, Cmd N
    /// holt ihn hierher, siehe Fokuslenkung.swift.
    let lenkung: Fokuslenkung

    /// Die Glieder der Kette. Hashable, damit `focused` sie unterscheiden kann.
    private enum Feld: Hashable {
        case datum, betrag, kachel(Int), suchen, bereich, notiz, gruppe, gruppenmenue,
             topf, einnahme, ausserplan, speichern
    }

    @State private var datum = Date()
    @State private var betragText = ""
    @State private var notiz = ""
    @State private var gruppentext = ""
    @State private var topfId: Int64?
    @State private var offenes: Feld?
    @State private var einnahme = false
    @State private var ausserplan = false
    @State private var gewaehlt: Kategorie?
    @State private var hinweis: String?
    @State private var mehrOffen = false
    @State private var sucheOffen = false
    @State private var suchtext = ""
    @FocusState private var fokus: Feld?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Schnelleingabe").font(.headline)

            DatePicker("Datum", selection: $datum, displayedComponents: .date)
                .datePickerStyle(.stepperField)
                .labelsHidden()
                .focusable()
                .focused($fokus, equals: .datum)

            TextField("Betrag in Euro", text: $betragText)
                .font(.title3)
                .focused($fokus, equals: .betrag)
                .onSubmit(speichern)
                .onChange(of: betragText) { _, neu in plusMinus(neu) }

            kacheln

            Text(gewaehlt?.name ?? "Keine Kategorie gewählt")
                .font(.caption)
                .foregroundStyle(.secondary)

            aufklappbarerBereich

            if let hinweis {
                Text(hinweis).font(.caption).foregroundStyle(.orange)
            }

            Button("Speichern", systemImage: "checkmark") { speichern() }
                .buttonStyle(.borderedProminent)
                .focusable()
                .focused($fokus, equals: .speichern)
                .disabled(!speicher.schreibbar)

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 300)
        // Ein Fokusbereich, damit die Eingabe als Ganzes ansteuerbar bleibt
        .focusSection()
        .onKeyPress(phases: .down) { druck in taste(druck) }
        .onExitCommand { leeren() }
        .onChange(of: lenkung.wunsch) {
            if lenkung.zone == .eingabe { fokus = .betrag }
        }
        .onChange(of: fokus) { _, neu in
            if neu != nil { lenkung.meldet(.eingabe) }
        }
        // Beim Start steht der Cursor im Betrag. Nicht über defaultFocus, das
        // holt den Fokus bei jedem Neuzeichnen zurück und macht Tab damit
        // wirkungslos (2026-09-24). Ein kurzer Moment genügt, damit das Fenster
        // erst aktiv wird, onAppear allein ist zu früh.
        .task {
            try? await Task.sleep(for: .milliseconds(200))
            fokus = .betrag
        }
    }

    // MARK: Die Kette

    /// Die Reihenfolge, in der Tab läuft. Sie wird bei jedem Tastendruck frisch
    /// gebildet, denn die Kacheln wechseln mit den Favoriten und der
    /// aufklappbare Bereich ist mal offen und mal zu. Was nicht sichtbar ist,
    /// steht nicht darin, sonst landete der Fokus im Nichts.
    private var kette: [Feld] {
        var glieder: [Feld] = [.datum, .betrag]
        glieder += speicher.favoriten.indices.map { Feld.kachel($0) }
        glieder += [.suchen, .bereich]
        if mehrOffen {
            glieder += [.notiz, .gruppe, .gruppenmenue, .topf, .einnahme, .ausserplan]
        }
        if speicher.schreibbar { glieder.append(.speichern) }
        return glieder
    }

    /// Einen Schritt weiter, mit Ringschluss.
    private func weiter(_ schritt: Int, versuche: Int = 0) {
        let glieder = kette
        guard !glieder.isEmpty, versuche < glieder.count else { return }
        let ziel: Feld
        if let jetzt = fokus, let stelle = glieder.firstIndex(of: jetzt) {
            ziel = glieder[((stelle + schritt) % glieder.count + glieder.count) % glieder.count]
        } else {
            ziel = .betrag
        }
        fokus = ziel
        // Nachfassen, siehe Auswahl.swift. Ein Element, das den Fokus nicht
        // annimmt, darf die Kette nicht anhalten (2026-09-24).
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            // Siehe Auswahl.swift, der Fokus bleibt stehen statt zu
            // verschwinden (2026-09-25, gemessen).
            if fokus != ziel {
                weiter(schritt, versuche: versuche + 1)
            }
        }
    }

    /// Alle Tasten, die die Kette und das Auswählen betreffen.
    ///
    /// Der Händler sieht eine Taste nur, wenn das fokussierte Element sie nicht
    /// selbst verbraucht hat. Ein offenes Menü behält seine Pfeiltasten und
    /// seine Leertaste also, und doppelt geschaltet wird nie.
    private func taste(_ druck: KeyPress) -> KeyPress.Result {
        // Tab im Ring, Option Tab in den nächsten Bereich. Beides steckt in
        // Bereichstasten, damit jeder Bereich dieselbe Regel benutzt.
        if Bereichstasten.tab(druck, ring: { weiter($0) }, wechsel: lenkung.wechseln) {
            return .handled
        }
        // Auf einer Auswahlliste öffnen auch die Pfeiltasten, wie gewohnt
        if druck.key == .upArrow || druck.key == .downArrow,
           fokus == .gruppenmenue || fokus == .topf {
            return leertaste() ? .handled : .ignored
        }
        switch druck.key {
        case .space:
            return leertaste() ? .handled : .ignored
        case .return:
            speichern()
            return .handled
        default:
            // Pfeiltasten und alles andere bleiben beim System
            return .ignored
        }
    }

    /// Auswählen und Umschalten, überall dort, wo etwas zu wählen ist.
    private func leertaste() -> Bool {
        switch fokus {
        case .kachel(let platz):
            guard speicher.favoriten.indices.contains(platz) else { return false }
            waehlen(speicher.favoriten[platz])
            return true
        case .suchen:
            sucheOeffnen()
            return true
        case .gruppenmenue, .topf:
            offenes = fokus
            return true
        case .bereich:
            mehrOffen.toggle()
            return true
        case .einnahme:
            einnahme.toggle()
            return true
        case .ausserplan:
            ausserplan.toggle()
            return true
        case .speichern:
            speichern()
            return true
        default:
            // Im Textfeld ist die Leertaste ein Leerzeichen
            return false
        }
    }

    // MARK: Aufbau

    private var ausserplanText: String {
        einnahme
            ? "Außerplanmäßig, aufs Konto statt ins Monatsbudget"
            : "Außerplanmäßig, aus dem Konto statt aus dem Monatsbudget"
    }

    /// Bis zu acht Favoriten in der eingestellten Reihenfolge, dazu der Knopf
    /// Mehr mit der vollständigen Liste. Kein automatisches Auffüllen nach
    /// Nutzung, die Auswahl gehört dem Nutzer, siehe CLAUDE.md.
    private var kacheln: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            ForEach(Array(speicher.favoriten.enumerated()), id: \.element.id) { platz, kategorie in
                Button {
                    waehlen(kategorie)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: Symbole.sfSymbol(kategorie.icon))
                        Text(kategorie.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .tint(gewaehlt?.id == kategorie.id ? .accentColor : .secondary)
                .help("\(kategorie.name), Cmd \(platz + 1)")
                .keyboardShortcut(kurzTaste(platz), modifiers: .command)
                // focusable ausdrücklich, damit Tab hier auch dann hält, wenn
                // die Tastaturnavigation des Systems aus ist
                .focusable()
                .focused($fokus, equals: .kachel(platz))
            }

            Button {
                sucheOeffnen()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    Text("Mehr")
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            .focusable()
            .focused($fokus, equals: .suchen)
            .popover(isPresented: $sucheOffen, arrowEdge: .trailing) { suchliste }
        }
    }

    /// Alle Kategorien mit Suchfeld, wie die Kachel Mehr in der Fassung mit
    /// Flet. Ein Menü wäre einfacher, aber dort führt die Leertaste nicht
    /// zuverlässig hinein, und Suchen ist bei dreißig Kategorien schneller.
    private var suchliste: some View {
        VStack(spacing: 0) {
            TextField("Suchen", text: $suchtext)
                .textFieldStyle(.roundedBorder)
                .padding(8)
                .onSubmit {
                    if let erste = treffer.first { waehlen(erste) }
                }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(treffer) { kategorie in
                        Button {
                            waehlen(kategorie)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: Symbole.sfSymbol(kategorie.icon))
                                Text(kategorie.name)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                    }
                }
            }
        }
        .frame(width: 260, height: 320)
    }

    private var treffer: [Kategorie] {
        let suche = suchtext.trimmingCharacters(in: .whitespaces).lowercased()
        guard !suche.isEmpty else { return speicher.kategorien }
        return speicher.kategorien.filter { $0.name.lowercased().contains(suche) }
    }

    /// Der aufklappbare Bereich, aber mit eigenem Knopf statt DisclosureGroup.
    /// Nur so lässt sich sein Kopf in die Kette nehmen und mit der Leertaste
    /// auf und zu klappen.
    private var aufklappbarerBereich: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                mehrOffen.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: mehrOffen ? "chevron.down" : "chevron.right")
                        .font(.caption)
                    // So heißt er auch in der Anleitung (2026-09-26)
                    Text("Notiz, Gruppe, Topf und mehr").font(.callout)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($fokus, equals: .bereich)

            if mehrOffen {
                TextField("Notiz", text: $notiz)
                    .focused($fokus, equals: .notiz)
                    .onSubmit(speichern)
                // Das Gruppenfeld steht hier von Hand und nicht als
                // Gruppenfeld Ansicht. Ein focused an einer zusammengesetzten
                // Ansicht greift ins Leere, der Fokus landet dann nirgends und
                // der Tastenhändler des Bereichs läuft nicht mehr, weil kein
                // Element im Bereich den Fokus hat (2026-09-24).
                HStack(spacing: 4) {
                    TextField("Gruppe, optional", text: $gruppentext)
                        .focused($fokus, equals: .gruppe)
                    // Die Liste der vorhandenen Gruppen, eine eigene Wahlliste
                    // und kein natives Menü, das bei ausgeschalteter
                    // Tastaturnavigation keine Tasten annimmt, siehe
                    // Auswahl.swift (2026-09-25).
                    Button {
                        offenes = .gruppenmenue
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .focusable()
                    .focused($fokus, equals: .gruppenmenue)
                    .help("Vorhandene Gruppen")
                    .popover(isPresented: Binding(
                        get: { offenes == .gruppenmenue },
                        set: { if !$0 { offenes = nil } }
                    ), arrowEdge: .bottom) {
                        Wahlliste(namen: ["Keine Gruppe"] + Gruppenwahl.auswahl(speicher.gruppen),
                                  gewaehlt: gruppentext) { name in
                            offenes = nil
                            if let name { gruppentext = name == "Keine Gruppe" ? "" : name }
                            fokus = .gruppenmenue
                        }
                    }
                }
                Text("Aus einem Topf bezahlen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Auswahlknopf(wert: topfName, namen: ["Kein Topf"] + speicher.toepfe.map(\.name),
                             fokus: $fokus, marke: .topf, offenes: $offenes) { name in
                    topfId = speicher.toepfe.first { $0.name == name }?.id
                }
                Toggle("Einnahme, zum Beispiel Geschenk oder Verkauf", isOn: $einnahme)
                    .focusable()
                    .focused($fokus, equals: .einnahme)
                Toggle(ausserplanText, isOn: $ausserplan)
                    .focusable()
                    .focused($fokus, equals: .ausserplan)
            }
        }
    }

    private var topfName: String {
        speicher.toepfe.first { $0.id == topfId }?.name ?? "Kein Topf"
    }

    private func kurzTaste(_ platz: Int) -> KeyEquivalent {
        KeyEquivalent(Character("\(platz + 1)"))
    }

    // MARK: Buchen

    private func sucheOeffnen() {
        suchtext = ""
        sucheOffen = true
    }

    private func waehlen(_ kategorie: Kategorie) {
        // Ein zweiter Griff zur selben Kachel hebt die Wahl wieder auf
        gewaehlt = gewaehlt?.id == kategorie.id ? nil : kategorie
        hinweis = nil
        // Der Fokus bleibt stehen, wo er ist (2026-09-24). Er sprang vorher
        // zurück in den Betrag, das war aus der Fassung mit Flet übernommen,
        // wo ein Kachelklick dem Feld den Fokus nahm und Enter danach nirgends
        // ankam. Hier speichert Enter aus der ganzen Eingabe, der Umweg ist
        // also unnötig und reißt nur aus der Kette.
        if sucheOffen {
            // Die Liste verschwindet, mit ihr ihr Suchfeld, deshalb zurück auf
            // den Knopf, der sie geöffnet hat.
            sucheOffen = false
            fokus = .suchen
        }
    }

    /// Ein Plus oder Minus am Ende des Betrags verschiebt das Datum.
    private func plusMinus(_ text: String) {
        guard let letztes = text.last, letztes == "+" || letztes == "-" else { return }
        let tage = letztes == "+" ? 1 : -1
        if let neu = Calendar.current.date(byAdding: .day, value: tage, to: datum) {
            datum = neu
        }
        betragText = String(text.dropLast())
    }

    private func speichern() {
        guard let kategorie = gewaehlt else {
            hinweis = "Erst eine Kategorie wählen, mit Cmd und einer Ziffer geht es am schnellsten."
            return
        }
        guard let getippt = Geld.cent(aus: betragText) else {
            hinweis = "Der Betrag fehlt oder ist nicht zu lesen."
            fokus = .betrag
            return
        }
        // Einnahmen positiv, Ausgaben negativ, das Vorzeichen macht der Schalter
        let betrag = einnahme ? abs(getippt) : -abs(getippt)
        // Eine neue Buchung zeigt keine geerbte Gruppe, leer heißt hier also
        // nicht gesetzt und erbt von Posten, Topf oder Kategorie.
        let gruppe = Gruppenwahl.gespeichertWert(
            getippt: gruppentext, angezeigt: "", gespeichert: nil, vorhanden: speicher.gruppen)
        if speicher.buchen(datum: datum, betragCent: betrag, kategorie: kategorie,
                           notiz: notiz, topfId: topfId, gruppe: gruppe,
                           ausserplanmaessig: ausserplan) {
            leeren()
        } else {
            hinweis = speicher.meldung
        }
    }

    private func leeren() {
        betragText = ""
        notiz = ""
        gruppentext = ""
        topfId = nil
        einnahme = false
        ausserplan = false
        gewaehlt = nil
        hinweis = nil
        mehrOffen = false
        sucheOffen = false
        datum = Date()
        fokus = .betrag
    }
}
