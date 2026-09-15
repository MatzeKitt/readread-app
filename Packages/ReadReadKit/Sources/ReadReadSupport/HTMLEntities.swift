import Foundation

/// Decodes HTML character references.
///
/// Split out of ``HTMLText`` because ``HTMLParser`` needs the same decoding for attribute values
/// and text nodes, and two copies of an entity table drift.
public enum HTMLEntities {

    /// The named entities that actually occur in feed and article content. A full HTML5 entity
    /// table is thousands of names; the numeric forms below cover everything else.
    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»", "bull": "•",
        "middot": "·", "copy": "©", "reg": "®", "trade": "™", "deg": "°",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "sect": "§",
        "para": "¶", "dagger": "†", "Dagger": "‡", "permil": "‰", "prime": "′",
        "Prime": "″", "times": "×", "divide": "÷", "plusmn": "±", "frac12": "½",
        "frac14": "¼", "frac34": "¾", "sup2": "²", "sup3": "³", "micro": "µ",
        "ordm": "º", "ordf": "ª", "iexcl": "¡", "iquest": "¿", "shy": "",
        "ensp": " ", "emsp": " ", "thinsp": " ", "zwnj": "", "zwj": "",
    ]

    public static func decoding(_ text: String) -> String {
        // Cheap bail-out: the overwhelming majority of text has no entities at all.
        guard text.contains("&") else { return text }

        var output = ""
        output.reserveCapacity(text.count)
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index] == "&" else {
                output.append(text[index])
                index = text.index(after: index)
                continue
            }

            // Entities are short; scanning further than this means it was a bare ampersand.
            let searchEnd = text.index(index, offsetBy: 12, limitedBy: text.endIndex) ?? text.endIndex
            guard let semicolon = text[index..<searchEnd].firstIndex(of: ";") else {
                output.append("&")
                index = text.index(after: index)
                continue
            }

            let name = text[text.index(after: index)..<semicolon]
            if let replacement = replacement(forEntityNamed: name) {
                output.append(replacement)
                index = text.index(after: semicolon)
            } else {
                output.append("&")
                index = text.index(after: index)
            }
        }

        return output
    }

    static func replacement(forEntityNamed name: Substring) -> String? {
        guard !name.isEmpty else { return nil }

        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let scalarValue: UInt32? = if digits.hasPrefix("x") || digits.hasPrefix("X") {
                UInt32(digits.dropFirst(), radix: 16)
            } else {
                UInt32(digits, radix: 10)
            }
            guard let scalarValue, let scalar = Unicode.Scalar(scalarValue) else { return nil }
            return String(Character(scalar))
        }

        return named[String(name)]
    }
}
