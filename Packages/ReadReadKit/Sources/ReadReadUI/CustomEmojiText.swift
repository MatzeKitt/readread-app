import Foundation

/// One piece of a status's text: either words, or a custom emoji standing in for a shortcode.
enum EmojiSegment: Equatable {
    case text(AttributedString)
    case emoji(shortcode: String)
}

/// Splits text around `:shortcode:` markers.
///
/// Kept separate from the view because this is where the mistakes are: a lone colon in ordinary
/// prose, a time like `12:30`, a shortcode the instance did not send, and the fact that only
/// *known* shortcodes may be replaced — Mastodon does not escape colons, so any text can contain
/// them and most of it is not an emoji.
///
/// Works on `AttributedString` rather than `String` so the surrounding runs keep their link
/// attributes: the content has already been through Markdown parsing by this point, and rebuilding
/// it from plain text would strip every link in the post.
enum CustomEmojiText {

    /// Longest shortcode this will consider. Mastodon's own limit is far below it; the cap exists
    /// so a line full of colons cannot make the scan quadratic.
    private static let maximumShortcodeLength = 64

    static func segments(of attributed: AttributedString, shortcodes: Set<String>) -> [EmojiSegment] {
        guard !shortcodes.isEmpty else { return [.text(attributed)] }

        let characters = attributed.characters
        var segments: [EmojiSegment] = []

        var pendingStart = characters.startIndex
        var index = characters.startIndex

        while index < characters.endIndex {
            guard characters[index] == ":" else {
                index = characters.index(after: index)
                continue
            }

            guard let (shortcode, afterClosing) = shortcode(at: index, in: characters, known: shortcodes) else {
                // Not an emoji. Skipping only this colon rather than the whole run matters for
                // `::blobcat::`, where the second colon opens the real shortcode.
                index = characters.index(after: index)
                continue
            }

            if pendingStart < index {
                segments.append(.text(AttributedString(attributed[pendingStart..<index])))
            }
            segments.append(.emoji(shortcode: shortcode))

            index = afterClosing
            pendingStart = afterClosing
        }

        if pendingStart < characters.endIndex {
            segments.append(.text(AttributedString(attributed[pendingStart..<characters.endIndex])))
        }

        return segments
    }

    /// Reads a `:shortcode:` starting at an opening colon.
    ///
    /// Returns the name and the index just past the closing colon, or `nil` when what follows is
    /// not a shortcode this instance sent.
    private static func shortcode(
        at start: AttributedString.CharacterView.Index,
        in characters: AttributedString.CharacterView,
        known: Set<String>
    ) -> (String, AttributedString.CharacterView.Index)? {
        var cursor = characters.index(after: start)
        var name = ""

        while cursor < characters.endIndex, name.count <= maximumShortcodeLength {
            let character = characters[cursor]

            if character == ":" {
                guard !name.isEmpty, known.contains(name) else { return nil }
                return (name, characters.index(after: cursor))
            }
            // Mastodon shortcodes are `[a-zA-Z0-9_]`. Anything else means this colon was just
            // punctuation, and bailing out immediately is what keeps `12:30 and 4:00` cheap.
            guard character.isASCII, character.isLetter || character.isNumber || character == "_" else {
                return nil
            }
            name.append(character)
            cursor = characters.index(after: cursor)
        }

        return nil
    }
}
