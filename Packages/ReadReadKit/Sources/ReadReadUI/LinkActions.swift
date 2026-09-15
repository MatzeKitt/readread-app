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
    @MainActor
    static func copy(_ url: URL) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        // Required before every write. Without it the pasteboard keeps what was there, and the old
        // contents out-rank the new ones for every type this write does not happen to replace.
        pasteboard.clearContents()
        // `NSURL` rather than the string, because it writes both representations itself.
        pasteboard.writeObjects([url as NSURL])
        #else
        UIPasteboard.general.items = [[
            UTType.url.identifier: url,
            UTType.utf8PlainText.identifier: url.absoluteString,
        ]]
        #endif
    }

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
