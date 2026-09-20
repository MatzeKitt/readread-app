import Foundation
import Testing

@testable import ReadReadUI

#if os(macOS)
import AppKit

/// What Copy Link actually puts on the pasteboard.
///
/// Worth a suite because the bug it pins was invisible from the code and invisible from the menu:
/// the item was there, it ran, it wrote something, and pasting produced nothing. `NSURL` on a
/// pasteboard writes `public.url` and three legacy URL flavours and **no text**, so every
/// plain-text destination — a note, a message, a terminal, a search field — asked for a string and
/// found none. Only a browser's address bar, which asks for `public.url`, ever saw the link.
///
/// Written against a named pasteboard rather than the general one, so running the tests does not
/// take somebody's clipboard away from them.
@MainActor
@Suite("Copy Link")
struct LinkActionsTests {

    private let url = URL(string: "https://mastodon.social/@someone/117293616048754714")!

    /// A pasteboard of this suite's own, named per test so two tests cannot see each other's writes.
    private func pasteboard(_ name: String) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("readread-tests-\(name)"))
        pasteboard.clearContents()
        return pasteboard
    }

    /// The regression, stated as the thing the reader does: copy a link, paste it somewhere that
    /// wants text.
    @Test("A copied link can be pasted as text")
    func copiesAsText() {
        let pasteboard = pasteboard("text")

        LinkActions.copy(url, to: pasteboard)

        #expect(pasteboard.string(forType: .string) == url.absoluteString)
    }

    /// And the half that already worked, so fixing the text cannot quietly cost the type: a field
    /// expecting a link has to keep recognising one.
    @Test("A copied link is still a link")
    func copiesAsURL() {
        let pasteboard = pasteboard("url")

        LinkActions.copy(url, to: pasteboard)

        let read = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        #expect(read == [url])
        #expect(pasteboard.types?.contains(.URL) == true)
    }

    /// Both on one item, not two. Written as separate items, a paste into something that takes
    /// multiples — a file list, a multi-line field — would produce the same link twice.
    @Test("Both representations describe one link, not two")
    func writesASingleItem() {
        let pasteboard = pasteboard("single")

        LinkActions.copy(url, to: pasteboard)

        #expect(pasteboard.pasteboardItems?.count == 1)
    }

    /// `clearContents` before every write, or a previous, longer link survives underneath the new
    /// one in whichever types this write does not happen to replace.
    @Test("Copying a second link leaves nothing of the first")
    func replacesThePreviousLink() {
        let pasteboard = pasteboard("replace")
        let first = URL(string: "https://example.com/a-very-much-longer-first-link")!

        LinkActions.copy(first, to: pasteboard)
        LinkActions.copy(url, to: pasteboard)

        #expect(pasteboard.string(forType: .string) == url.absoluteString)
        #expect((pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) == [url])
    }
}

/// That the frameworks `VideoPlayer` needs are actually linked into the binary.
///
/// This is a link-time invariant wearing a test's clothes, and it earns its place: the app shipped
/// a build in which playing any video aborted the process, and nothing in the source, the compiler
/// or the warnings said so. `import AVKit` autolinks `AVFoundation`, `libswiftAVFoundation` and the
/// `_AVKit_SwiftUI` interop overlay — but **not AVKit**. So SwiftUI would ask the overlay for
/// `VideoPlayer`'s backing view and the Swift runtime would abort initialising it:
///
///     failed to demangle superclass of VideoPlayerView
///     from mangled name 'So12AVPlayerViewC': unknown error
///
/// `So12AVPlayerViewC` is the Objective-C class `AVPlayerView`. Asking the runtime whether that
/// class exists is therefore exactly the question the crash answered with "no", and it is one a
/// test can ask in a microsecond. See `Package.swift`, where `.linkedFramework("AVKit")` is what
/// makes it true.
@Suite("Media playback linkage")
struct MediaPlaybackLinkageTests {

    @Test("The class VideoPlayer inherits from is registered")
    func playerViewClassIsAvailable() {
        #expect(NSClassFromString("AVPlayerView") != nil)
    }
}
#endif
