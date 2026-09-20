import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What a reader can do with an item's link, other than read the item here.
///
/// Both of these fork per platform in ways that are easy to get quietly wrong — a link copied as
/// text only, a browser stolen to the foreground — so they are written once, beside each other,
/// rather than at each of the four places that offer them.
enum LinkActions {

    /// Puts the link on the pasteboard, as a link *and* as text.
    ///
    /// Both representations, deliberately. Written as a URL alone it pastes into a browser's address
    /// bar and into almost nothing else: a note, a chat message, a terminal all ask the pasteboard
    /// for text and would find it empty. Written as text alone it loses its type, so a field that
    /// expects a link stops recognising one.
    ///
    @MainActor
    static func copy(_ url: URL) {
        #if os(macOS)
        copy(url, to: .general)
        #else
        UIPasteboard.general.items = [[
            UTType.url.identifier: url,
            UTType.utf8PlainText.identifier: url.absoluteString,
        ]]
        #endif
    }

    #if os(macOS)
    /// The Mac's half, taking the pasteboard so it can be written to one that is not the reader's.
    ///
    /// Split out only for that: `LinkActionsTests` writes to a named pasteboard of its own, because
    /// a test that clobbers the clipboard is a test nobody can run twice while working. Nothing in
    /// the app calls this directly.
    @MainActor
    static func copy(_ url: URL, to pasteboard: NSPasteboard) {
        // Required before every write. Without it the pasteboard keeps what was there, and the old
        // contents out-rank the new ones for every type this write does not happen to replace.
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        // And the text, separately, which is the whole of the bug this line fixes.
        //
        // The comment that used to be here said `NSURL` "writes both representations itself". It
        // does not. It writes `public.url` and three legacy URL flavours and **no text at all**, so
        // `string(forType: .string)` came back nil and Copy Link pasted nothing into a note, a
        // message, a terminal, or any other plain-text field — which is nearly everywhere anyone
        // would paste a link. Measured rather than reasoned about this time: `LinkActionsTests`
        // asserts both types are on the pasteboard, so the claim cannot rot back into a comment.
        pasteboard.setString(url.absoluteString, forType: .string)
    }
    #endif

    /// Opens the link for the configured Open in Browser key, leaving this app in front where the
    /// platform allows it.
    ///
    /// The key and the menu item deliberately differ, and this is the only place that difference
    /// lives. Pressing the key is triage — you are working down a list and putting pages aside to
    /// read later, and having the browser jump in front on each one means going back to the app
    /// between every item. Clicking **Open in Browser** in a context menu is a decision to go and
    /// read the thing, so it still goes.
    ///
    /// On the Mac this bypasses the environment's `openURL`, which is safe here and nowhere else:
    /// `LinkPolicy` has no in-app browser to offer on macOS and answers `.system` for every link, so
    /// the only thing being stepped around is the activation the system would otherwise perform.
    ///
    /// iOS has no equivalent. `UIApplication.open` hands over the foreground by definition, and the
    /// in-app browser this would otherwise route through is a full-screen presentation — there is no
    /// "behind" for a page to open in. So the key does there exactly what it did before.
    @MainActor
    static func openForShortcut(_ url: URL, otherwise openURL: OpenURLAction) {
        #if os(macOS)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration)
        #else
        openURL(url)
        #endif
    }
}
