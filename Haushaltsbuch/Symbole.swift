import Foundation

/// Die Kategorien tragen in der Datenbank Iconnamen, teils die alten Kürzel aus
/// schema.sql, teils Material Iconnamen aus dem Programm in Python. Hier werden
/// sie auf SF Symbols übersetzt, dieselbe Aufgabe wie ui/hilfen.symbol.
/// Was fehlt, bekommt ein neutrales Schild, nie einen Absturz.
enum Symbole {
    static let ersatz = "tag"

    private static let tabelle: [String: String] = [
        "basket": "basket",
        "home": "house",
        "tools-kitchen-2": "fork.knife",
        "gas-station": "fuelpump",
        "tool": "wrench.and.screwdriver",
        "train": "tram",
        "shirt": "tshirt",
        "heartbeat": "heart.text.square",
        "masks-theater": "theatermasks",
        "device-tv": "tv",
        "confetti": "party.popper",
        "gift": "gift",
        "book": "book",
        "plane": "airplane",
        "dots": "ellipsis.circle",
        "building": "building.2",
        "bolt": "bolt",
        "shield": "shield",
        "wifi": "wifi",
        "cash": "banknote",
        // Material Iconnamen, wie neue Kategorien sie speichern
        "shopping_basket": "basket",
        "restaurant": "fork.knife",
        "local_gas_station": "fuelpump",
        "directions_bus": "bus",
        "checkroom": "tshirt",
        "favorite": "heart",
        "school": "graduationcap",
        "pets": "pawprint",
        "child_care": "figure.and.child.holdinghands",
        "fitness_center": "figure.run",
        "spa": "drop",
        "chair": "chair",
        "credit_card": "creditcard",
        "volunteer_activism": "hand.raised",
        "receipt_long": "doc.text",
        "account_balance": "building.columns",
        "phone_iphone": "iphone",
        "bolt_outlined": "bolt",
    ]

    /// Die Namen, die hier bekannt sind, für die Auswahl im Kategoriedialog.
    /// Nur sie lassen sich auch anzeigen.
    static var bekannteNamen: [String] {
        tabelle.keys.sorted()
    }

    static func sfSymbol(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return ersatz }
        return tabelle[name] ?? ersatz
    }
}
