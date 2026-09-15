import ReadReadModel
import SwiftUI

/// Text with custom emoji rendered inline.
///
/// Builds one concatenated `Text`, so the result behaves like any other text: it wraps, it selects,
/// it takes the font it is given. An `HStack` of pieces would not wrap mid-sentence, which is the
/// obvious alternative and the reason it is not used.
struct EmojiText: View {

    let attributed: AttributedString
    let emojis: [String: URL]

    /// The reader's size preference for this text, so an emoji grows with the words it sits in.
    ///
    /// Needed because these are *images*, not glyphs: a `.font()` on the surrounding text has no
    /// effect on them. Without this, raising the content size left a post's custom emoji at their
    /// old size, shrinking visibly against the sentence they belong to.
    let scale: TextScale

    /// Tracks Dynamic Type, so an emoji stays the size of the words around it.
    @ScaledMetric(relativeTo: .body) private var baseGlyphHeight: CGFloat = 17

    private var store = CustomEmojiStore.shared

    private var glyphHeight: CGFloat { baseGlyphHeight * scale.multiplier }

    init(_ attributed: AttributedString, emojis: [String: URL], scale: TextScale = .standard) {
        self.attributed = attributed
        self.emojis = emojis
        self.scale = scale
    }

    init(_ text: String, emojis: [String: URL], scale: TextScale = .standard) {
        self.init(AttributedString(text), emojis: emojis, scale: scale)
    }

    var body: some View {
        composed
            .task(id: attributed) {
                store.load(shortcodesInUse.compactMap { emojis[$0] })
            }
    }

    /// Shortcodes this particular text actually mentions.
    ///
    /// Only these are fetched. A busy instance can define thousands of emoji, and loading its
    /// whole set to render one post would be absurd.
    private var shortcodesInUse: [String] {
        segments.compactMap { segment in
            if case .emoji(let shortcode) = segment { return shortcode }
            return nil
        }
    }

    private var segments: [EmojiSegment] {
        CustomEmojiText.segments(of: attributed, shortcodes: Set(emojis.keys))
    }

    private var composed: Text {
        segments.reduce(Text("")) { result, segment in
            switch segment {
            case .text(let value):
                // Interpolation rather than `+`, which is deprecated on macOS 26.
                return Text("\(result)\(Text(value))")

            case .emoji(let shortcode):
                guard let url = emojis[shortcode],
                      let image = store.image(for: url, height: glyphHeight) else {
                    // Still loading, or it failed. The literal `:shortcode:` is the honest
                    // placeholder — a blank would silently delete a word from the post.
                    return Text("\(result):\(shortcode):")
                }
                return Text("\(result)\(Text(image).baselineOffset(-1))")
            }
        }
    }
}
