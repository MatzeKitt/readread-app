import ReadReadModel
import ReadReadSync
import SwiftUI

/// What a row's context menu offers for a cached item: the post's own actions, Read Later, and the
/// link.
///
/// Shared by the timeline and the search results, which show the same rows in the same column. An
/// action offered on a row in one and missing from the same row in the other reads as a bug rather
/// than as a decision — the same reasoning that gave Read Later's menu Copy Link.
///
/// Lists that have actions of their own add them after this, as Older Items does with Dismiss.
struct ItemActionsMenu: View {

    let item: CachedItem
    let accounts: [AccountRecord]
    let isSaved: Bool
    let toggleReadLater: () -> Void

    var body: some View {
        // First, because for a post it is the thing most often wanted from this menu, and because
        // Read Later is also reachable by swiping.
        StatusActionMenu(
            item: item,
            accounts: StatusInteractions.Actor.menuOrder(
                for: accounts,
                owner: item.accountID
            )
        )

        if item.kind == .status, !accounts.isEmpty {
            Divider()
        }

        Button(
            isSaved ? "Remove from Read Later" : "Read Later",
            systemImage: isSaved ? "bookmark.slash" : "bookmark"
        ) {
            toggleReadLater()
        }

        if let url = item.url {
            Divider()
            Link("Open in Browser", destination: url)
            // Beside Open in Browser because it is the other half of the same question — this
            // link, but taken somewhere else rather than followed here. Both representations go on
            // the pasteboard; see `LinkActions.copy(_:)`.
            Button("Copy Link", systemImage: "link") {
                LinkActions.copy(url)
            }
        }

        // After the post's own address, because these are the places the post points *at* —
        // including any past the row's clip, which a tap on the text cannot reach.
        StatusLinksMenu(item: item)
    }
}
