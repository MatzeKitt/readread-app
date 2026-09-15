import ReadReadModel
import SwiftUI

/// A Mastodon poll, shown as results.
///
/// Not interactive, and that is a design decision rather than a gap: ReadRead never writes to a
/// server it reads from, so there is no vote to cast here. Rendering the options as tappable
/// buttons that quietly do nothing would be worse than showing them plainly.
struct PollView: View {

    let poll: RenderablePoll

    /// A poll's options are words the author wrote, so they are content and follow its size.
    /// The vote tallies beside them are not, and stay put.
    var contentScale: TextScale = .standard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(poll.options) { option in
                row(for: option)
            }

            footnote
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Poll")
    }

    private func row(for option: RenderablePoll.Option) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(option.title)
                    .scaledFont(.callout, scale: contentScale)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let percentage = poll.percentage(of: option) {
                    Text(percentage, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if let share = poll.share(of: option) {
                bar(share: share)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(option.title)
        .accessibilityValue(accessibilityValue(for: option))
    }

    /// The result bar.
    ///
    /// Drawn with a `GeometryReader`-free overlay so the width follows the row rather than
    /// imposing one: a poll sits inside a status card whose width is the reading column's, not
    /// something this view gets to decide.
    private func bar(share: Double) -> some View {
        Capsule()
            .fill(.quaternary)
            .frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(.tint)
                        .frame(width: max(0, geometry.size.width * share))
                }
            }
            .accessibilityHidden(true)
    }

    /// Returns `Text`, not `String`.
    ///
    /// Inflection markup is only applied by `Text`'s literal-string overload — build the sentence
    /// as a `String` first and `^[1 vote](inflect: true)` renders on screen exactly like that.
    /// Verified the hard way: the running app showed the markup verbatim under every poll.
    private func accessibilityValue(for option: RenderablePoll.Option) -> Text {
        guard let votes = option.votes else { return Text("Results hidden until the poll ends") }
        guard let percentage = poll.percentage(of: option) else {
            return Text("^[\(votes) vote](inflect: true)")
        }
        let count = Text("^[\(votes) vote](inflect: true)")
        // Interpolating `Text` into `Text` rather than concatenating with `+`, which is deprecated
        // on macOS 26 — and unlike a plain `String`, this keeps the inflection markup live.
        return Text("\(count), \(percentage.formatted(.percent.precision(.fractionLength(0))))")
    }

    /// The line under the options: how many voted, and whether it is still open.
    private var footnote: Text {
        var text = Text("^[\(poll.totalVotes) vote](inflect: true)")

        if poll.isExpired {
            text = Text("\(text) · Closed")
        } else if let expiresAt = poll.expiresAt {
            text = Text("\(text) · Ends \(expiresAt.formatted(.relative(presentation: .named)))")
        }

        if !poll.showsResults, !poll.isExpired {
            // Says why there are no bars, rather than leaving the options looking broken. Hiding
            // running tallies is the Mastodon default, not an error.
            text = Text("\(text) · Results hidden until it closes")
        }

        return text
    }
}
