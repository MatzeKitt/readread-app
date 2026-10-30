import ReadReadModel
import SwiftUI

/// A post's content warning, as a note under the post.
///
/// The post itself is shown straight away. It used to sit behind its warning until asked for —
/// in the row, the warning was all there was, and the reading pane wanted a tap before it showed
/// the post — and the warning now only says what the post is about. Under it rather than over it,
/// so the post is what is read first.
///
/// One view for the row, the post above a reply and the reading pane, so a warning looks the same
/// wherever the post does.
struct ContentWarningNotice: View {

    let text: String

    /// The reader's text size for the post the note belongs to.
    var scale: TextScale = .standard

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .scaledFont(.caption, scale: scale)
            .foregroundStyle(.secondary)
            // Said out loud, because the symbol that marks it as a warning is not.
            .accessibilityLabel(Text("Content warning: \(text)"))
    }
}
