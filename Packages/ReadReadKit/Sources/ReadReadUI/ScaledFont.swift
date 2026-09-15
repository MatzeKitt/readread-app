import ReadReadModel
import SwiftUI

/// Applies a ``TextScale`` to a text style without discarding Dynamic Type.
///
/// The naive way to honour a size preference is `.font(.system(size: 17 * scale))`, and it quietly
/// breaks accessibility: a hard point size ignores whatever the reader has chosen system-wide, so
/// someone running Larger Text gets *smaller* text the moment they touch the app's own setting.
///
/// `@ScaledMetric` is the piece that avoids it. It resolves a base size through the current Dynamic
/// Type setting, `relativeTo` the style it belongs to, and the app's multiplier is applied to that
/// result — so the two compose instead of competing.
struct ScaledFont: ViewModifier {

    let style: Font.TextStyle
    let weight: Font.Weight?
    let scale: TextScale

    /// Leading as a CSS-style multiple of the font size, or `nil` to leave it alone.
    let lineHeight: Double?

    @ScaledMetric private var resolved: CGFloat

    init(
        style: Font.TextStyle,
        weight: Font.Weight? = nil,
        scale: TextScale,
        lineHeight: Double? = nil
    ) {
        self.style = style
        self.weight = weight
        self.scale = scale
        self.lineHeight = lineHeight
        _resolved = ScaledMetric(wrappedValue: Self.baseSize(for: style), relativeTo: style)
    }

    func body(content: Content) -> some View {
        content
            .font(.system(size: pointSize, weight: weight))
            .lineSpacing(extraLeading)
    }

    private var pointSize: CGFloat {
        resolved * scale.multiplier
    }

    /// CSS `line-height` translated into SwiftUI's `lineSpacing`.
    ///
    /// The two measure from different places, and conflating them is how text ends up with twice
    /// the leading it was asked for. CSS `line-height` is the **whole** line box as a multiple of
    /// the font size; `lineSpacing` is the gap *added between* line boxes that already have the
    /// font's own natural leading in them. So the setting has to have that natural leading
    /// subtracted before it becomes a gap.
    ///
    /// ``naturalLineHeightRatio`` is an approximation — the exact figure is a property of the
    /// typeface's metrics, and the system font's varies slightly by size and weight. It is close
    /// enough that 1.5 here and 1.5 in the stylesheet look like the same setting, which is the
    /// actual requirement; asking `CTFont` for real metrics would buy precision nobody can see at
    /// the cost of resolving a font on every text view.
    private var extraLeading: CGFloat {
        guard let lineHeight else { return 0 }
        return max(0, pointSize * (lineHeight - Self.naturalLineHeightRatio))
    }

    /// Roughly what the system font already spends on a line, as a multiple of its point size.
    private static let naturalLineHeightRatio = 1.2

    /// The point size each style has at the default Dynamic Type setting.
    ///
    /// A table because there is no public way to ask a `Font.TextStyle` for its size, and
    /// `@ScaledMetric` needs a number to scale *from*. These are the platform's own values at the
    /// `.large` content size, so a reader who has changed nothing sees exactly what they saw
    /// before this setting existed — which is the bar for adding it at all.
    private static func baseSize(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline: 17
        case .subheadline: 15
        case .body: 17
        case .callout: 16
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        default: 17
        }
    }
}

extension View {

    /// Draws this text at `style`, scaled by the reader's preference for that kind of text.
    func scaledFont(
        _ style: Font.TextStyle,
        weight: Font.Weight? = nil,
        scale: TextScale,
        lineHeight: Double? = nil
    ) -> some View {
        modifier(ScaledFont(style: style, weight: weight, scale: scale, lineHeight: lineHeight))
    }
}
