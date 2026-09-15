import Foundation
import ReadReadModel
import Testing

@testable import ReadReadUI

/// `Testing` exports an `Attachment` of its own, so the model's has to be named explicitly.
private typealias MediaAttachment = ReadReadModel.Attachment

/// How a post's media is laid out across a timeline row.
///
/// `@MainActor` because `StatusMediaStrip` is a `View`, and SwiftUI's `View` carries main-actor
/// isolation onto the whole conforming type — including its static helpers. Calling one from a
/// nonisolated test context is only a *warning* at compile time and a `SIGTRAP` at run time, which
/// is not a pleasant thing to diagnose from a test that reports nothing at all.
@Suite("Timeline media layout")
@MainActor
struct StatusMediaLayoutTests {

    private func image(_ name: String, width: Int? = 1_200, height: Int? = 800) -> MediaAttachment {
        MediaAttachment(
            url: URL(string: "https://cdn.example.com/\(name).jpg")!,
            kind: .image,
            width: width,
            height: height
        )
    }

    // MARK: - Rows

    @Test("One picture takes the row to itself")
    func oneFillsTheRow() {
        let rows = StatusMediaStrip.rows(of: [image("a")])

        #expect(rows.count == 1)
        #expect(rows[0].count == 1)
    }

    @Test("Two share the row")
    func twoShareTheRow() {
        let rows = StatusMediaStrip.rows(of: [image("a"), image("b")])

        #expect(rows.count == 1)
        #expect(rows[0].count == 2)
    }

    /// The odd case, and the reason this is not a two-column grid: a grid gives the third picture
    /// half the width and leaves the other half empty.
    @Test("Three put the last one across the full width")
    func threeSpanTheLast() {
        let rows = StatusMediaStrip.rows(of: [image("a"), image("b"), image("c")])

        #expect(rows.map { $0.count } == [2, 1])
    }

    @Test("Four make two rows of two")
    func fourMakeAGrid() {
        let rows = StatusMediaStrip.rows(of: (1...4).map { image("\($0)") })

        #expect(rows.map { $0.count } == [2, 2])
    }

    /// Each tile has to be able to open the viewer at *itself*, so the offsets must survive being
    /// chunked into rows.
    @Test("Every tile keeps its place in the post")
    func offsetsSurviveChunking() {
        let rows = StatusMediaStrip.rows(of: (1...4).map { image("\($0)") })

        #expect(rows.flatMap { $0 }.map { $0.offset } == [0, 1, 2, 3])
    }

    @Test("Nothing in, nothing out")
    func emptyMakesNoRows() {
        #expect(StatusMediaStrip.rows(of: []).isEmpty)
    }

    // MARK: - Shape

    @Test("A portrait picture is recognised as one")
    func portraitRecognised() {
        #expect(StatusMediaStrip.isPortrait(image("a", width: 800, height: 1_200)))
    }

    @Test("Landscape and square are not")
    func landscapeAndSquareAreNot() {
        #expect(!StatusMediaStrip.isPortrait(image("a", width: 1_200, height: 800)))
        #expect(!StatusMediaStrip.isPortrait(image("a", width: 900, height: 900)))
    }

    /// The safe way round: the landscape tile is the shorter one, so an unknown shape costs a crop
    /// rather than a row of empty space.
    @Test("A picture the server did not measure is treated as landscape", arguments: [
        (nil, 1_200),
        (800, nil),
        (0, 1_200),
    ] as [(Int?, Int?)])
    func unmeasuredIsLandscape(width: Int?, height: Int?) {
        #expect(!StatusMediaStrip.isPortrait(image("a", width: width, height: height)))
    }
}
