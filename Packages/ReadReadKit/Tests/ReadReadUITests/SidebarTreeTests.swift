import Foundation
import ReadReadModel
import Testing

@testable import ReadReadUI

/// The Filtered Items row, which moved out of the filter settings and into the sidebar.
@Suite("Filtered Items in the sidebar")
struct SidebarFilteredRowTests {

    private var smartRows: [SidebarRow] {
        SidebarTree.build(accounts: [], sources: []).first?.rows ?? []
    }

    /// Present with no accounts, no feeds and no rules — the same bargain the other smart lists
    /// make. A row that appeared only once something was hidden would be missing exactly when
    /// someone went looking for what had gone.
    @Test("It is always in the sidebar")
    func alwaysPresent() {
        #expect(smartRows.contains { $0.kind == .filtered })
    }

    @Test("It sits with the other smart lists and addresses the filtered scope")
    func addressesTheFilteredScope() throws {
        let row = try #require(smartRows.first { $0.kind == .filtered })

        #expect(row.scope == .filtered)
        #expect(row.children.isEmpty)
    }

    /// The row is identified by its scope, so a collision would make two sidebar rows share an id.
    @Test("Its id is distinct from the other smart lists")
    func hasADistinctID() {
        let ids = smartRows.map(\.id)

        #expect(Set(ids).count == ids.count)
    }
}
