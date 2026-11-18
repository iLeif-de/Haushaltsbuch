import AppKit
import SwiftUI

/// Wegwerfprogramm, das zwei Fragen beantwortet.
///
/// 1. Sieht ein Tastenhändler Tab, während der Cursor in einem Textfeld steht?
///    SwiftUIs `onKeyPress` womöglich nicht, ein Tastenmonitor von AppKit
///    schon. Der Schalter oben stellt zwischen beiden um.
/// 2. Welche Steuerelemente nehmen den Fokus an, wenn ihn eine eigene Kette
///    setzt, und welche Tasten kommen danach bei ihnen an? Jede Aufklappliste
///    steht einmal mit und einmal ohne `focusable`.
///
/// Es gibt bewusst nur einen Tastenhändler, zwei übereinander verfälschen die
/// Messung.
@main
struct TastentestApp: App {
    var body: some Scene {
        Window("Tastentest", id: "test") {
            Tastentest()
                .frame(minWidth: 700, minHeight: 660)
        }
    }
}

struct Tastentest: View {
    enum Feld: Hashable, CaseIterable {
        case textfeld
        case pickerNurFocused, pickerMitFocusable
        case menueNurFocused, menueMitFocusable
        case knopfMitFocusable, hakenMitFocusable
        case datumsfeld, zweitesTextfeld

        var titel: String {
            switch self {
            case .textfeld: return "Textfeld"
            case .pickerNurFocused: return "Picker, nur focused"
            case .pickerMitFocusable: return "Picker, mit focusable"
            case .menueNurFocused: return "Menu, nur focused"
            case .menueMitFocusable: return "Menu, mit focusable"
            case .knopfMitFocusable: return "Knopf, mit focusable"
            case .hakenMitFocusable: return "Haken, mit focusable"
            case .datumsfeld: return "Datumsfeld"
            case .zweitesTextfeld: return "Zweites Textfeld"
            }
        }
    }

    @State private var monitorAn = false
    @State private var text = ""
    @State private var text2 = ""
    @State private var wahlA = "Auto"
    @State private var wahlB = "Auto"
    @State private var menueA = "nichts gewählt"
    @State private var menueB = "nichts gewählt"
    @State private var haken = false
    @State private var datum = Date()
    @State private var protokoll: [String] = []
    @State private var monitor: Any?
    @State private var vollzugriff = NSApp?.isFullKeyboardAccessEnabled ?? false
    @FocusState private var fokus: Feld?

    private let namen = ["Auto", "Wohnen", "Freizeit", "Urlaub", "Persönliches"]
    private let kette = Feld.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            kopf
            felder
            Divider()
            Text("Fokus: \(fokus?.titel ?? "nirgends")").font(.headline)
            Text("Werte: Picker A \(wahlA), Picker B \(wahlB), Menu A \(menueA), "
                 + "Menu B \(menueB), Haken \(haken ? "an" : "aus")")
                .font(.caption)
                .foregroundStyle(.secondary)
            protokollansicht
        }
        .padding(16)
        .focusSection()
        // Der eine Händler von SwiftUI. Er läuft nur, wenn der Monitor aus ist.
        .onKeyPress(phases: .down) { druck in
            guard !monitorAn else { return .ignored }
            notieren("onKeyPress: \(beschreibung(druck.characters, druck.modifiers.contains(.shift)))"
                     + " bei \(fokus?.titel ?? "nirgends")")
            return behandeln(zeichen: druck.characters,
                             umschalt: druck.modifiers.contains(.shift)) ? .handled : .ignored
        }
        .onChange(of: monitorAn) { _, an in
            an ? monitorStarten() : monitorBeenden()
        }
        .onChange(of: fokus) { _, neu in
            notieren("Fokus auf \(neu?.titel ?? "nirgends")")
        }
        .task {
            try? await Task.sleep(for: .milliseconds(200))
            fokus = .textfeld
        }
        .onDisappear { monitorBeenden() }
    }

    private var kopf: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tastentest").font(.title2).fontWeight(.semibold)
            Text("Mit Tab durch die Kette gehen. Auf jedem Halt probieren: Leertaste, Pfeil "
                 + "runter, und einen Anfangsbuchstaben tippen. Unten steht, wo der Fokus ist "
                 + "und was ankam.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Tastenmonitor von AppKit statt onKeyPress", isOn: $monitorAn)
                .font(.callout)
            Text("Der Monitor sieht jede Taste, auch im Textfeld. Genau darum geht es, "
                 + "onKeyPress bekommt Tab dort womöglich nie.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Die wichtigste Zahl überhaupt. Ist die Tastaturnavigation des
            // Systems aus, nimmt AppKit nur Textfelder in die Fokuskette auf,
            // und dann hilft kein eigener Händler.
            HStack(spacing: 10) {
                Text(vollzugriff
                     ? "Tastaturnavigation des Systems: an"
                     : "Tastaturnavigation des Systems: AUS, Systemeinstellungen, Tastatur")
                    .font(.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(vollzugriff ? Color.green : Color.orange)
                Button("Kette durchmessen") { durchmessen() }
                Spacer()
            }
        }
    }

    private var felder: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text(Feld.textfeld.titel)
                TextField("tippen", text: $text)
                    .frame(width: 200)
                    .focused($fokus, equals: .textfeld)
            }
            GridRow {
                Text(Feld.pickerNurFocused.titel)
                Picker("", selection: $wahlA) {
                    ForEach(namen, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 200)
                .focused($fokus, equals: .pickerNurFocused)
            }
            GridRow {
                Text(Feld.pickerMitFocusable.titel)
                Picker("", selection: $wahlB) {
                    ForEach(namen, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 200)
                .focusable()
                .focused($fokus, equals: .pickerMitFocusable)
            }
            GridRow {
                Text(Feld.menueNurFocused.titel)
                Menu(menueA) {
                    ForEach(namen, id: \.self) { name in
                        Button(name) { menueA = name }
                    }
                }
                .frame(width: 200)
                .focused($fokus, equals: .menueNurFocused)
            }
            GridRow {
                Text(Feld.menueMitFocusable.titel)
                Menu(menueB) {
                    ForEach(namen, id: \.self) { name in
                        Button(name) { menueB = name }
                    }
                }
                .frame(width: 200)
                .focusable()
                .focused($fokus, equals: .menueMitFocusable)
            }
            GridRow {
                Text(Feld.knopfMitFocusable.titel)
                Button("Auslösen") { notieren("Knopf ausgelöst") }
                    .focusable()
                    .focused($fokus, equals: .knopfMitFocusable)
            }
            GridRow {
                Text(Feld.hakenMitFocusable.titel)
                Toggle("angehakt", isOn: $haken)
                    .focusable()
                    .focused($fokus, equals: .hakenMitFocusable)
            }
            GridRow {
                Text(Feld.datumsfeld.titel)
                DatePicker("", selection: $datum, displayedComponents: .date)
                    .datePickerStyle(.stepperField)
                    .labelsHidden()
                    .focused($fokus, equals: .datumsfeld)
            }
            GridRow {
                Text(Feld.zweitesTextfeld.titel)
                TextField("tippen", text: $text2)
                    .frame(width: 200)
                    .focused($fokus, equals: .zweitesTextfeld)
            }
        }
    }

    private var protokollansicht: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(protokoll.enumerated()), id: \.offset) { _, zeile in
                    Text(zeile).font(.caption).monospaced()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 150)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Geht die Kette selbst durch, setzt jedes Glied und schaut nach, ob der
    /// Fokus dort hängen bleibt. Damit steht am Ende schwarz auf weiß, welche
    /// Steuerelemente den Fokus überhaupt annehmen.
    private func durchmessen() {
        Task { @MainActor in
            vollzugriff = NSApp?.isFullKeyboardAccessEnabled ?? false
            try? "".write(to: Tastenprotokoll.pfad, atomically: true, encoding: .utf8)
            notieren("--- Messung, Tastaturnavigation \(vollzugriff ? "an" : "aus") ---")
            for glied in kette {
                fokus = glied
                try? await Task.sleep(for: .milliseconds(120))
                let sitzt = fokus == glied
                notieren("\(sitzt ? "nimmt Fokus  " : "nimmt NICHT  ") \(glied.titel)")
            }
            fokus = .textfeld
            notieren("--- Messung fertig ---")
        }
    }

    // MARK: Der Tastenmonitor

    /// Ein Monitor von AppKit sieht jede Taste im Programm, bevor sie irgendwo
    /// ankommt, und kann sie schlucken, indem er nil liefert.
    private func monitorStarten() {
        monitorBeenden()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ereignis in
            let zeichen = ereignis.charactersIgnoringModifiers ?? ""
            let umschalt = ereignis.modifierFlags.contains(.shift)
            notieren("Monitor: \(beschreibung(zeichen, umschalt)) bei "
                     + "\(fokus?.titel ?? "nirgends")")
            return behandeln(zeichen: zeichen, umschalt: umschalt) ? nil : ereignis
        }
        notieren("Monitor an")
    }

    private func monitorBeenden() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Was beide Wege tun sollen. true heißt, die Taste ist verbraucht.
    private func behandeln(zeichen: String, umschalt: Bool) -> Bool {
        if zeichen == "\u{19}" {
            weiter(-1)
            return true
        }
        if zeichen == "\t" {
            weiter(umschalt ? -1 : 1)
            return true
        }
        if zeichen == " ", fokus == .hakenMitFocusable {
            haken.toggle()
            notieren("Haken über die Leertaste umgelegt")
            return true
        }
        if zeichen == " ", fokus == .knopfMitFocusable {
            notieren("Knopf über die Leertaste ausgelöst")
            return true
        }
        return false
    }

    /// Ein Glied weiter, und was den Fokus nicht annimmt, wird übersprungen.
    /// Ohne das bleibt die Kette am ersten Steuerelement stehen, das ihn nicht
    /// nimmt, und selbst der Sprung von Textfeld zu Textfeld fällt aus
    /// (2026-09-24).
    private func weiter(_ schritt: Int, versuche: Int = 0) {
        guard versuche < kette.count else {
            notieren("kein Glied nimmt den Fokus an")
            return
        }
        let ziel: Feld
        if let jetzt = fokus, let stelle = kette.firstIndex(of: jetzt) {
            ziel = kette[((stelle + schritt) % kette.count + kette.count) % kette.count]
        } else {
            ziel = schritt > 0 ? kette[0] : kette[kette.count - 1]
        }
        fokus = ziel
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            // Nimmt das Element den Fokus nicht an, bleibt er stehen, wo er
            // war, er verschwindet nicht (2026-09-25, gemessen).
            if fokus != ziel {
                notieren("übersprungen, nimmt den Fokus nicht: \(ziel.titel)")
                weiter(schritt, versuche: versuche + 1)
            }
        }
    }

    private func beschreibung(_ zeichen: String, _ umschalt: Bool) -> String {
        let name = zeichen
            .replacingOccurrences(of: "\t", with: "Tab")
            .replacingOccurrences(of: "\u{19}", with: "BackTab")
            .replacingOccurrences(of: " ", with: "Leertaste")
            .replacingOccurrences(of: "\u{1B}", with: "Escape")
            .replacingOccurrences(of: "\r", with: "Enter")
        return (umschalt ? "Umschalt " : "") + (name.isEmpty ? "?" : name)
    }

    /// Alles landet zusätzlich in /tmp/tastentest.log, damit das Ergebnis nicht
    /// abgetippt werden muss.
    private func notieren(_ satz: String) {
        protokoll.insert(satz, at: 0)
        if protokoll.count > 60 { protokoll.removeLast() }
        Tastenprotokoll.schreiben(satz)
    }
}

enum Tastenprotokoll {
    static let pfad = URL(fileURLWithPath: "/tmp/tastentest.log")

    static func schreiben(_ satz: String) {
        let zeile = satz + "\n"
        guard let daten = zeile.data(using: .utf8) else { return }
        if let griff = try? FileHandle(forWritingTo: pfad) {
            defer { try? griff.close() }
            _ = try? griff.seekToEnd()
            try? griff.write(contentsOf: daten)
        } else {
            try? daten.write(to: pfad)
        }
    }
}
