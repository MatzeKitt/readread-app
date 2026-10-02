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
    ].merging(letters) { symbol, _ in symbol }

    /// The accented letters HTML 4 gives names to: all of Latin-1, and the handful of Latin
    /// Extended-A it adds.
    ///
    /// Missing until the search work found it, and the most common entities in German and French
    /// feeds — `&auml;`, `&uuml;`, `&szlig;` and `&eacute;` are how a good deal of older publishing
    /// software writes those letters. Undecoded, an excerpt read "&auml;ndern" and a search for
    /// "ändern" could never find the article.
    ///
    /// Each name maps to exactly one letter, and case is significant: `&Auml;` is Ä, `&auml;` is ä.
    private static let letters: [String: String] = [
        "Agrave": "À", "Aacute": "Á", "Acirc": "Â", "Atilde": "Ã", "Auml": "Ä", "Aring": "Å",
        "AElig": "Æ", "Ccedil": "Ç", "Egrave": "È", "Eacute": "É", "Ecirc": "Ê", "Euml": "Ë",
        "Igrave": "Ì", "Iacute": "Í", "Icirc": "Î", "Iuml": "Ï", "ETH": "Ð", "Ntilde": "Ñ",
        "Ograve": "Ò", "Oacute": "Ó", "Ocirc": "Ô", "Otilde": "Õ", "Ouml": "Ö", "Oslash": "Ø",
        "Ugrave": "Ù", "Uacute": "Ú", "Ucirc": "Û", "Uuml": "Ü", "Yacute": "Ý", "THORN": "Þ",
        "szlig": "ß",
        "agrave": "à", "aacute": "á", "acirc": "â", "atilde": "ã", "auml": "ä", "aring": "å",
        "aelig": "æ", "ccedil": "ç", "egrave": "è", "eacute": "é", "ecirc": "ê", "euml": "ë",
        "igrave": "ì", "iacute": "í", "icirc": "î", "iuml": "ï", "eth": "ð", "ntilde": "ñ",
        "ograve": "ò", "oacute": "ó", "ocirc": "ô", "otilde": "õ", "ouml": "ö", "oslash": "ø",
        "ugrave": "ù", "uacute": "ú", "ucirc": "û", "uuml": "ü", "yacute": "ý", "thorn": "þ",
        "yuml": "ÿ",
        "OElig": "Œ", "oelig": "œ", "Scaron": "Š", "scaron": "š", "Yuml": "Ÿ",
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
