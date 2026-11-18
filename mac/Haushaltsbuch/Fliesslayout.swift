import SwiftUI

/// Eine Zeile aus Eingabefeldern, die umbricht, sobald sie nicht mehr passt.
///
/// SwiftUI hat dafür nichts Eigenes, ein `HStack` schiebt seinen Inhalt einfach
/// aus dem Fenster heraus. Genau das darf nicht sein, siehe CLAUDE.md,
/// Konventionen, und in der Fassung mit Flet macht das `wrap=True`
/// (2026-09-25). Die Reihenfolge bleibt die geschriebene, also bleibt auch die
/// Tabkette, wie sie ist.
struct Fliesslayout: Layout {
    var abstand: CGFloat = 8
    var zeilenabstand: CGFloat = 8

    /// Eine umgebrochene Zeile, mit den Plätzen ihrer Felder.
    private struct Zeile {
        var plaetze: [Int] = []
        var breite: CGFloat = 0
        var hoehe: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let grenze = proposal.width ?? .infinity
        let zeilen = umbrechen(subviews, grenze: grenze)
        let hoehe = zeilen.reduce(0) { $0 + $1.hoehe }
            + CGFloat(max(0, zeilen.count - 1)) * zeilenabstand
        let breite = zeilen.map(\.breite).max() ?? 0
        return CGSize(width: min(breite, grenze), height: hoehe)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let zeilen = umbrechen(subviews, grenze: bounds.width)
        var y = bounds.minY
        for zeile in zeilen {
            var x = bounds.minX
            for platz in zeile.plaetze {
                let mass = subviews[platz].sizeThatFits(.unspecified)
                // Innerhalb der Zeile stehen die Felder auf gleicher Mitte, ein
                // Haken neben einem Textfeld sonst oben am Rand.
                subviews[platz].place(at: CGPoint(x: x, y: y + (zeile.hoehe - mass.height) / 2),
                                      proposal: ProposedViewSize(mass))
                x += mass.width + abstand
            }
            y += zeile.hoehe + zeilenabstand
        }
    }

    private func umbrechen(_ subviews: Subviews, grenze: CGFloat) -> [Zeile] {
        var zeilen: [Zeile] = []
        var jetzt = Zeile()
        for (platz, teil) in subviews.enumerated() {
            let mass = teil.sizeThatFits(.unspecified)
            let mitFeld = jetzt.plaetze.isEmpty ? mass.width : jetzt.breite + abstand + mass.width
            if !jetzt.plaetze.isEmpty, mitFeld > grenze {
                zeilen.append(jetzt)
                jetzt = Zeile(plaetze: [platz], breite: mass.width, hoehe: mass.height)
            } else {
                jetzt.plaetze.append(platz)
                jetzt.breite = mitFeld
                jetzt.hoehe = max(jetzt.hoehe, mass.height)
            }
        }
        if !jetzt.plaetze.isEmpty { zeilen.append(jetzt) }
        return zeilen
    }
}

/// Ein Kasten um die Felder eines Eintrags. Sobald eine Zeile umbricht, ist
/// sonst nicht mehr zu sehen, was zusammengehört.
struct Eintragskasten<Inhalt: View>: View {
    @ViewBuilder let inhalt: Inhalt

    var body: some View {
        Fliesslayout { inhalt }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension View {
    /// Schreibt die Breite, die diese Ansicht bekommen hat, in einen Zustand.
    /// Damit entscheidet eine Liste, ob sie alle Spalten nebeneinander zeigt
    /// oder zwei Zeilen daraus macht (2026-09-25).
    func breiteMessen(in wert: Binding<CGFloat>) -> some View {
        background(
            GeometryReader { raum in
                Color.clear.onChange(of: raum.size.width, initial: true) { _, neu in
                    wert.wrappedValue = neu
                }
            }
        )
    }
}

extension View {
    /// Zeigt über einer anklickbaren Fläche die Hand. Bei den Balken der
    /// Auswertung war sonst nicht zu erkennen, dass man sie anklicken kann
    /// (2026-09-25).
    func zeigefinger() -> some View {
        onHover { drin in
            if drin { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
