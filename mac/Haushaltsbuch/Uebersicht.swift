import SwiftUI

/// Die Übersicht, aufgebaut wie ui/uebersicht.py. Oben der Monat mit zwei
/// Pfeilen, dann die große Zahl, darunter das frei Verfügbare mit seiner
/// Herleitung, der Balken mit dem Ausgabenanteil und ein Strich beim
/// Monatsanteil, drei kleine Karten und zuletzt die Buchungen des Monats.
struct Uebersichtsansicht: View {
    let speicher: Speicher
    let lenkung: Fokuslenkung

    /// Die Kette dieses Bereichs. Die Liste ist ein Glied, in ihr bewegen die
    /// Pfeiltasten die Auswahl, das macht das System.
    private enum Feld: Hashable { case zurueck, vor, monat, jahr, liste }

    @FocusState private var fokus: Feld?
    /// Die Auswahl ist Text und nicht die Datenbanknummer, denn die Liste mischt
    /// drei Sorten Zeilen und alle drei haben ihre eigene Nummernfolge. Eine
    /// Buchung 3 und ein Topf 3 wären sonst dasselbe (2026-09-24).
    @State private var auswahl: String?
    @State private var offenes: Feld?
    @State private var imDialog: Buchung?
    /// Ein geplanter Abschlag, der mit Anpassung bestätigt wird.
    @State private var imBestaetigen: Buchung?
    /// Ein geplanter Abschlag, dessen Gruppe geändert wird.
    @State private var inGruppe: Buchung?

    private let kette: [Feld] = [.zurueck, .vor, .monat, .jahr, .liste]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            monatszeile
            grosseZahl
            freiVerfuegbar
            balken
            karten
            if let bild = speicher.bild, bild.ausserplanCent != 0 {
                Text(ausserplanSatz(bild.ausserplanCent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let meldung = speicher.meldung {
                Text(meldung).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            termine
            Divider()
            // Was vom iPhone kam, siehe Eingang.swift (2026-09-27)
            if let hinweis = speicher.eingangHinweis {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "iphone").font(.caption).foregroundStyle(.secondary)
                    Text(hinweis).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Ausblenden") { speicher.eingangHinweisVergessen() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            if speicher.letzteLoeschung != nil {
                HStack(spacing: 8) {
                    Text("Buchung gelöscht").font(.caption)
                    Button("Rückgängig") { speicher.loeschungZurueckholen() }
                        .buttonStyle(.link)
                        .font(.caption)
                    Spacer()
                    Button("Ausblenden") { speicher.loeschungVergessen() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            liste
        }
        .padding(16)
        .frame(minWidth: 470)
        .focusSection()
        .onKeyPress(phases: .down) { druck in taste(druck) }
        .onChange(of: lenkung.wunsch) {
            // Option Tab landet in der Liste, nicht auf den Monatspfeilen. Dort
            // will man hin, wenn man in die Übersicht wechselt. Die Monatswahl
            // erreicht man von hier mit Umschalt Tab (2026-09-24).
            if lenkung.zone == .inhalt {
                ersteZeileWaehlen()
                fokus = .liste
            }
        }
        .onChange(of: fokus) { _, neu in
            if neu != nil { lenkung.meldet(.inhalt) }
            // Auch wenn der Fokus mit der Maus in die Liste kommt, soll eine
            // Zeile gewählt sein (2026-09-24).
            if neu == .liste { ersteZeileWaehlen() }
        }
        .sheet(item: $imDialog) { buchung in
            Buchungsdialog(speicher: speicher, buchung: buchung) { imDialog = nil }
        }
        .sheet(item: $imBestaetigen) { buchung in
            Bestaetigungsdialog(speicher: speicher, buchung: buchung) { imBestaetigen = nil }
        }
        .sheet(item: $inGruppe) { buchung in
            Gruppendialog(speicher: speicher, buchung: buchung) { inGruppe = nil }
        }
    }

    // MARK: Tasten

    private var monatsnamen: [String] {
        (1...12).map { Datumsformat.monatName(String(format: "2000-%02d", $0)) }
    }

    private func taste(_ druck: KeyPress) -> KeyPress.Result {
        if Bereichstasten.tab(druck, ring: { weiter($0) }, wechsel: lenkung.wechseln) {
            return .handled
        }
        // Die Leertaste löst aus, worauf der Fokus steht. Sie darf hier nur die
        // beiden Monatspfeile beantworten und muss sonst weiterlaufen, sonst
        // kommt die Liste weiter unten nie an sie heran (2026-09-24).
        if druck.key == .space {
            if fokus == .zurueck {
                speicher.monatBlaettern(-1)
                return .handled
            }
            if fokus == .vor {
                speicher.monatBlaettern(1)
                return .handled
            }
        }
        // Monat und Jahr sind Auswahllisten, sie klappen mit der Leertaste und
        // mit Pfeil hoch und runter auf, wie überall (2026-09-25).
        if fokus == .monat || fokus == .jahr,
           druck.key == .space || druck.key == .upArrow || druck.key == .downArrow {
            offenes = fokus
            return .handled
        }
        // In der Liste bearbeitet Enter die gewählte Zeile und die
        // Rückschritttaste löscht sie, wie im Finder.
        guard fokus == .liste else { return .ignored }
        // Enter und Leertaste öffnen die gewählte Zeile, die Rückschritttaste
        // löscht sie. Bei einer Aufstockung heißt löschen zurücknehmen, bei
        // einer Rücklagenzeile gibt es nichts zu tun, sie ist keine Buchung.
        if let buchung = gewaehlteBuchung {
            switch druck.key {
            case .space:
                // Leertaste löst aus, Enter gehört dem Standardknopf. In den
                // Bereichen gibt es keinen, also tut Enter hier nichts
                // (2026-09-24).
                bearbeiten(buchung)
                return .handled
            case .delete, .deleteForward:
                loeschen(buchung)
                return .handled
            default:
                return .ignored
            }
        }
        if let einlage = gewaehlteEinlage, druck.key == .delete || druck.key == .deleteForward {
            speicher.einlageZuruecknehmen(einlage)
            return .handled
        }
        return .ignored
    }

    private var gewaehlteBuchung: Buchung? {
        speicher.buchungen.first { $0.zeilenSchluessel == auswahl }
    }

    private var gewaehlteEinlage: Einlage? {
        speicher.einlagen.first { $0.zeilenSchluessel == auswahl }
    }

    /// Eine gebuchte Zeile öffnet Buchung bearbeiten, eine geplante das
    /// Bestätigen mit Anpassung. So führen Leertaste und Doppelklick bei jeder
    /// Zeile weiter, und Enter bestätigt dann im Dialog (2026-09-26).
    private func bearbeiten(_ buchung: Buchung) {
        if buchung.geplant {
            imBestaetigen = buchung
        } else {
            imDialog = buchung
        }
    }

    private func loeschen(_ buchung: Buchung) {
        guard buchung.loeschbar else { return }
        auswahl = nil
        speicher.buchungLoeschen(buchung)
    }

    private func weiter(_ schritt: Int, versuche: Int = 0) {
        guard versuche < kette.count else { return }
        let ziel: Feld
        if let jetzt = fokus, let stelle = kette.firstIndex(of: jetzt) {
            ziel = kette[((stelle + schritt) % kette.count + kette.count) % kette.count]
        } else {
            ziel = .liste
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

    // MARK: Kopf

    /// Monat und Jahr zum Aufklappen, dazu die zwei Pfeile zum Blättern. Zwei
    /// Pfeile allein waren zu langsam, ein Monat aus dem Vorjahr kostete zwölf
    /// Klicks (2026-09-24). Mit den Aufklapplisten sind es zwei Griffe, und mit
    /// der Tastatur Leertaste, Pfeiltasten, Enter.
    private var monatszeile: some View {
        HStack(spacing: 6) {
            // Cmd Alt Pfeil blättert, ohne den Fokus zu bewegen. Damit bleibt
            // die Tabkette der Schnelleingabe ein Ring und ist doch keine
            // Falle, siehe Schnelleingabe.swift.
            Button { speicher.monatBlaettern(-1) } label: { Image(systemName: "chevron.left") }
                .help("Voriger Monat, Cmd Alt Pfeil links")
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .focusable()
                .focused($fokus, equals: .zurueck)
            Button { speicher.monatBlaettern(1) } label: { Image(systemName: "chevron.right") }
                .help("Nächster Monat, Cmd Alt Pfeil rechts")
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .focusable()
                .focused($fokus, equals: .vor)

            Auswahlknopf(wert: Datumsformat.monatName(speicher.monat),
                         namen: monatsnamen, fokus: $fokus,
                         marke: .monat, offenes: $offenes) { name in
                if let nummer = monatsnamen.firstIndex(of: name) {
                    speicher.monatSetzen(monatImJahr: nummer + 1)
                }
            }
            .frame(width: 130)
            .help("Monat wählen")

            Auswahlknopf(wert: String(speicher.monat.prefix(4)),
                         namen: speicher.jahre.map(String.init), fokus: $fokus,
                         marke: .jahr, offenes: $offenes) { name in
                if let jahr = Int(name) { speicher.monatSetzen(jahr: jahr) }
            }
            .frame(width: 90)
            .help("Jahr wählen")

            Spacer()

            Button("Heute") { speicher.monat = speicher.heuteMonat }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(speicher.monat == speicher.heuteMonat)
                .help("Zurück zum laufenden Monat")
        }
    }

    /// Beim Eintritt in den Bereich soll eine Zeile gewählt sein, sonst
    /// bewegen die Pfeiltasten nichts und Enter öffnet nichts.
    /// Gewählt wird die erste Buchung, nicht die erste Zeile. Mit ihr kann man
    /// etwas tun, eine Rücklagenzeile ist nur ein Hinweis.
    private func ersteZeileWaehlen() {
        let vorhanden = auswahl != nil && (gewaehlteBuchung != nil || gewaehlteEinlage != nil)
        if !vorhanden, let erste = speicher.buchungen.first {
            auswahl = erste.zeilenSchluessel
        }
    }

    /// Einnahmen minus Fixkosten minus Topfraten minus variable Ausgaben.
    /// Rücklagen stehen nicht für Sonstiges zur Verfügung, auch wenn sie noch
    /// nicht wirklich abgebucht sind.
    private var grosseZahl: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Geld.euro(speicher.bild?.verfuegbarCent ?? 0))
                .font(.system(size: 40, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(zahlenfarbe)
            Text("bleiben bis Monatsende")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let warnung = speicher.bild?.warnung {
                Text(warnung).font(.callout).foregroundStyle(zahlenfarbe)
            }
        }
    }

    /// Dieselbe Farbe für Zahl, Warnung und Balken, wie in ui/uebersicht.py.
    /// Rot, wenn der Monat überzogen ist, orange bei einer Warnung, sonst grün
    /// (2026-09-26). Vorher stand die Zahl im Normalfall schwarz da, und der
    /// Balken hatte eine eigene Regel.
    private var zahlenfarbe: Color {
        guard let bild = speicher.bild else { return .primary }
        if bild.verfuegbarCent < 0 { return .red }
        return bild.warnung == nil ? .green : .orange
    }

    /// Kontostand minus aller Rücklagen, also das, worüber außerhalb des
    /// Monatsbudgets wirklich verfügt werden kann.
    private var freiVerfuegbar: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let frei = speicher.freiVerfuegbarCent {
                Text("Frei verfügbar \(Geld.euro(frei))")
                    .font(.headline)
                    .foregroundStyle(frei < 0 ? .red : .primary)
                Text("Kontostand \(Geld.euro(speicher.kontostandCent ?? 0)) minus Rücklagen "
                     + Geld.euro(speicher.ruecklagenCent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Kein Startsaldo gesetzt, deshalb kein Kontostand.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let deckung = speicher.bild?.deckung {
                Text(deckung).font(.caption).foregroundStyle(.red)
            }
        }
    }

    /// Der Balken zeigt den ausgegebenen Anteil, der Strich den verstrichenen
    /// Anteil des Monats. Steht der Balken rechts vom Strich, geht es zu schnell.
    private var balken: some View {
        let anteil = min(max(speicher.bild?.ausgabenAnteil ?? 0, 0), 1)
        let marke = min(max(speicher.bild?.monatAnteil ?? 0, 0), 1)
        return VStack(alignment: .leading, spacing: 3) {
            GeometryReader { raum in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(zahlenfarbe)
                        .frame(width: raum.size.width * anteil)
                    Rectangle()
                        .fill(.secondary)
                        .frame(width: 2)
                        .offset(x: raum.size.width * marke)
                }
            }
            .frame(height: 8)
            if let bild = speicher.bild {
                Text("\(prozent(bild.ausgabenAnteil)) des Budgets ausgegeben, "
                     + "\(prozent(bild.monatAnteil)) des Monats vorbei")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Dieselben drei Karten wie ui/uebersicht.py, Einnahmen, Ausgaben und
    /// Rücklagen. Ausgaben sind Fixkosten und Variables zusammen, denn beim
    /// Blick auf den Monat zählt, was weg ist, und nicht, wodurch. Die
    /// Rücklagen stehen mit Minus, sie sind Geld, das aus dem Monatsbudget
    /// herausgeht, auch wenn es auf dem Konto bleibt (2026-09-25).
    private var karten: some View {
        HStack(spacing: 8) {
            karte("Einnahmen", speicher.bild?.einnahmenCent ?? 0)
            karte("Ausgaben", (speicher.bild?.fixCent ?? 0) + (speicher.bild?.variabelCent ?? 0))
            karte("Rücklagen", -(speicher.bild?.ratenCent ?? 0))
        }
    }

    private func karte(_ beschriftung: String, _ cent: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(beschriftung).font(.caption).foregroundStyle(.secondary)
            Text(Geld.euro(cent)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func ausserplanSatz(_ cent: Int) -> String {
        cent > 0
            ? "Außerplanmäßig aufs Konto \(Geld.euro(cent)), nicht im Monatsbudget"
            : "Außerplanmäßig aus dem Konto \(Geld.euro(-cent)), nicht im Monatsbudget"
    }

    private func prozent(_ anteil: Double) -> String {
        "\(Int((anteil * 100).rounded()))%"
    }

    /// Was demnächst abgebucht wird, nur die nicht monatlichen Posten. Sie
    /// kommen selten und treffen dann voll, und man will sie mit der Rechnung
    /// abgleichen können (2026-09-24). Monatliche stehen ohnehin in der Liste.
    @ViewBuilder
    private var termine: some View {
        if !speicher.termine.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Demnächst fällig").font(.caption).foregroundStyle(.secondary)
                ForEach(speicher.termine.prefix(4)) { termin in
                    HStack(spacing: 8) {
                        Text(Datumsformat.lesbar(termin.datum))
                            .frame(width: 80, alignment: .leading)
                        Text(termin.name).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Geld.euro(termin.betragCent)).monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: Liste

    /// Die Liste zeigt drei Sorten Zeilen, wie ui/uebersicht.py. Erst die
    /// Rücklagenraten des Monats, die keine Buchungen sind, dann die
    /// Aufstockungen, dann die Buchungen. Ohne die ersten beiden wäre nicht
    /// nachvollziehbar, warum das frei Verfügbare gesunken ist.
    @ViewBuilder
    private var liste: some View {
        if speicher.buchungen.isEmpty && speicher.einlagen.isEmpty && ratenzeilen.isEmpty {
            Text("Noch keine Buchungen in diesem Monat.").foregroundStyle(.secondary)
            Spacer()
        } else {
            // Mit Auswahl, damit die Liste ein Glied der Kette sein kann und
            // die Pfeiltasten darin die Zeile wechseln. Das macht das System.
            List(selection: $auswahl) {
                // id ausdrücklich über den Schlüssel, nicht über die
                // Datenbanknummer. Sonst fällt Topf 1 mit Einlage 1 zusammen
                // und eine der beiden Zeilen erscheint doppelt (2026-09-24).
                ForEach(ratenzeilen, id: \.zeilenSchluessel) { topf in
                    ratenzeile(topf).tag(topf.zeilenSchluessel)
                }
                ForEach(speicher.einlagen, id: \.zeilenSchluessel) { einlage in
                    aufstockungszeile(einlage).tag(einlage.zeilenSchluessel)
                }
                ForEach(speicher.buchungen, id: \.zeilenSchluessel) { buchung in
                zeile(buchung)
                    .tag(buchung.zeilenSchluessel)
                    // Die ganze Zeile nimmt Klicks an, nicht nur der Text.
                    // Ohne das ging der Doppelklick zwischen den Spalten ins
                    // Leere (2026-09-24).
                    .contentShape(Rectangle())
                    // simultaneousGesture, damit der einfache Klick weiter die
                    // Zeile auswählt. Ein eigener TapGesture würde ihn schlucken.
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        bearbeiten(buchung)
                    })
                    .contextMenu { zeilenmenue(buchung) }
                }
            }
            .listStyle(.inset)
            .focused($fokus, equals: .liste)
        }
    }

    /// Wie Duplizieren in ui/uebersicht.py, dieselbe Buchung noch einmal,
    /// mit Topf und eigener Gruppe.
    private func duplizieren(_ buchung: Buchung) {
        guard buchung.loeschbar,
              let kategorie = speicher.kategorie(nach: buchung.kategorie) else { return }
        speicher.buchen(datum: buchung.datum, betragCent: buchung.betragCent,
                        kategorieId: kategorie.id, notiz: buchung.notiz,
                        topfId: buchung.topfId, gruppe: buchung.eigeneGruppe,
                        ausserplanmaessig: buchung.ausserplanmaessig)
    }

    /// Dieselben Einträge im Kontextmenü und im Menü am Zeilenende, damit für
    /// die Maus nichts fehlt, was die Tastatur kann.
    @ViewBuilder
    private func zeilenmenue(_ buchung: Buchung) -> some View {
        if buchung.geplant {
            // Wie in ui/uebersicht.py. Eine geplante Zeile hat keinen Dialog
            // Buchung bearbeiten, dafür eigene Wege für Bestätigen und Gruppe.
            Button("Bestätigen") { speicher.bestaetigen(buchung) }
            Button("Anpassen und bestätigen") { imBestaetigen = buchung }
            Divider()
            Button("Gruppe ändern") { inGruppe = buchung }
        } else {
            Button("Bearbeiten") { bearbeiten(buchung) }
            Button("Duplizieren") { duplizieren(buchung) }
                .disabled(!buchung.loeschbar)
            Divider()
            Button("Löschen") { loeschen(buchung) }
                .disabled(!buchung.loeschbar)
        }
    }

    /// Aufgebaut wie die Zeile in ui/uebersicht.py. Oben der Titel, also der
    /// Postenname oder die Kategorie, darunter klein Kategorie, Gruppe, Notiz
    /// und der Hinweis außerplanmäßig, soweit es sie gibt.
    private func zeile(_ buchung: Buchung) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Datumsformat.tagUndMonat(buchung.datum))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(buchung.titel).lineLimit(1).truncationMode(.tail)
                    if buchung.geplant { merker("Geplant") }
                }
                if !buchung.unterzeile.isEmpty {
                    Text(buchung.unterzeile)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)

            Text(Geld.euro(buchung.betragCent))
                .monospacedDigit()
                .foregroundStyle(buchung.betragCent > 0 ? Color.green : Color.primary)
                .frame(width: 100, alignment: .trailing)

            // Eine geplante Zeile hat Haken und Stift wie in ui/uebersicht.py,
            // Bestätigen mit einem Klick und Bestätigen mit Anpassung. Der
            // Platz dafür steht in jeder Zeile, sonst rückte der Betrag einer
            // geplanten Zeile aus seiner Spalte (2026-09-26).
            HStack(spacing: 10) {
                if buchung.geplant {
                    Button { speicher.bestaetigen(buchung) } label: {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Bestätigen")
                    Button { imBestaetigen = buchung } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Anpassen und bestätigen")
                }
            }
            .frame(width: 44, alignment: .leading)

            // Der sichtbare Weg für die Maus, wie der Menüknopf am Zeilenende
            // in ui/uebersicht.py. Ohne ihn findet man Duplizieren und Löschen
            // nur über das Kontextmenü, und das rät niemand.
            Menu {
                zeilenmenue(buchung)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
            .help(buchung.geplant ? "Bestätigen, Anpassen, Gruppe ändern"
                  : "Bearbeiten, Duplizieren, Löschen")
        }
        // Geplante Zeilen stehen blasser da, wie in der Fassung mit Flet
        .opacity(buchung.geplant ? 0.55 : 1)
    }

    /// Die Töpfe, deren Rate diesen Monat wirklich zählt. Pausierte und volle
    /// eigene Töpfe fallen heraus, genau wie in topfraten.
    private var ratenzeilen: [Topf] {
        speicher.toepfe.filter { topf in
            if topf.pausiert { return false }
            if let ziel = topf.zielCent, ziel != 0, !topf.automatisch, topf.stand >= ziel {
                return false
            }
            // Eine Rate von null sagt nichts. Sie steht im Fälligkeitsmonat, wo
            // der Topf gerade geleert wurde, und sah dort neben der echten
            // Abbuchung wie eine zweite Zeile zum selben Posten aus
            // (2026-09-24). Die Fassung mit Flet zeigt sie noch.
            if topf.rateCent == 0 { return false }
            return true
        }
    }

    /// Keine echte Buchung, nur der Hinweis, dass dieses Geld verplant ist.
    private func ratenzeile(_ topf: Topf) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "banknote")
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text("Rücklage, \(topf.name)")
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(Geld.euro(-topf.rateCent))
                .monospacedDigit()
                .frame(width: 100, alignment: .trailing)
            // Der Platz für Haken und Stift und für das Menü, siehe zeile
            Spacer().frame(width: 44 + 10 + 24)
        }
        .foregroundStyle(.secondary)
        .help("Monatliche Rate zur Rücklage, keine echte Buchung")
    }

    /// Eine Aufstockung ist keine Buchung, kein Geld verlässt das Konto. Sie
    /// steht trotzdem in der Liste, und zurücknehmen geht hier, sonst gäbe es
    /// für einen Vertipper keinen Weg zurück.
    private func aufstockungszeile(_ einlage: Einlage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "arrow.down.to.line")
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text("Aufstockung, \(einlage.topf)").lineLimit(1)
                Text("kein Geld vom Konto, nur nicht mehr frei verfügbar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Geld.euro(-einlage.betragCent))
                .monospacedDigit()
                .frame(width: 100, alignment: .trailing)
            // Der Platz für Haken und Stift, siehe zeile
            Spacer().frame(width: 44)
            Menu {
                Button("Zurücknehmen") { speicher.einlageZuruecknehmen(einlage) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
            .help("Aufstockung zurücknehmen")
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Zurücknehmen") { speicher.einlageZuruecknehmen(einlage) }
        }
    }

    private func merker(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}
