import Foundation
import MastodonAPI
import ReadReadModel
import Testing

@testable import ReadReadUI

/// `Testing` exports an `Attachment` of its own, so the model's has to be named explicitly.
private typealias MediaAttachment = ReadReadModel.Attachment

@MainActor
@Suite("Media viewer")
struct MediaViewerTests {

    private func attachment(_ name: String) -> MediaAttachment {
        MediaAttachment(url: URL(string: "https://files.example/\(name).jpg")!, kind: .image)
    }

    @Test("Opening on the second of three keeps that one")
    func opensOnTheClickedAttachment() {
        let model = MediaViewerModel()
        model.present([attachment("a"), attachment("b"), attachment("c")], startingAt: 1)

        #expect(model.session?.index == 1)
        #expect(model.session?.attachments.count == 3)
    }

    /// The strip only draws the first four, so an index handed in from a caller that counted
    /// differently must land on something rather than trapping.
    @Test("An index past the end is clamped")
    func clampsOutOfRangeIndex() {
        let model = MediaViewerModel()
        model.present([attachment("a"), attachment("b")], startingAt: 9)
        #expect(model.session?.index == 1)

        model.present([attachment("a"), attachment("b")], startingAt: -3)
        #expect(model.session?.index == 0)
    }

    @Test("Nothing to show opens nothing")
    func ignoresEmpty() {
        let model = MediaViewerModel()
        model.present([], startingAt: 0)
        #expect(model.session == nil)
    }

    @Test("Dismissing clears the session")
    func dismissClears() {
        let model = MediaViewerModel()
        model.present([attachment("a")], startingAt: 0)
        model.dismiss()
        #expect(model.session == nil)
    }
}

/// A video's poster frame has to come from the preview URL, because the attachment's own URL is
/// an MP4 and no image decoder will touch it. The view layer used to map Mastodon attachments with
/// a second, thinner copy of the ingest planner's mapping that dropped the preview URL entirely —
/// so every video in a conversation drew as a broken image.
@Suite("Attachment posters")
struct AttachmentPosterTests {

    private func media(type: String, url: String, previewURL: String?) throws -> MastodonMediaAttachment {
        let preview = previewURL.map { "\"\($0)\"" } ?? "null"
        let json = """
            {
                "id": "1",
                "type": "\(type)",
                "url": "\(url)",
                "preview_url": \(preview),
                "remote_url": null,
                "description": "A short clip",
                "blurhash": null,
                "meta": { "original": { "width": 1280, "height": 720 } }
            }
            """
        return try JSONDecoder.mastodon.decode(
            MastodonMediaAttachment.self,
            from: Data(json.utf8)
        )
    }

    @Test("A video maps to a still poster, not to its own MP4")
    func videoCarriesAPoster() throws {
        let media = try media(
            type: "video",
            url: "https://files.example/clip.mp4",
            previewURL: "https://files.example/clip.jpg"
        )
        let attachment = try #require(MediaAttachment(mastodon: media))

        #expect(attachment.kind == .video)
        #expect(attachment.url.absoluteString == "https://files.example/clip.mp4")
        #expect(attachment.previewURL.absoluteString == "https://files.example/clip.jpg")
        #expect(attachment.describedAs == "A short clip")
    }

    @Test("A gifv maps the same way")
    func animatedGIFCarriesAPoster() throws {
        let media = try media(
            type: "gifv",
            url: "https://files.example/loop.mp4",
            previewURL: "https://files.example/loop.png"
        )
        let attachment = try #require(MediaAttachment(mastodon: media))

        #expect(attachment.kind == .gifv)
        #expect(attachment.previewURL.absoluteString == "https://files.example/loop.png")
    }

    /// Without a preview the fallback is the media itself, which is the honest answer — there is
    /// nothing else to draw — and the play badge still says what the tile is.
    @Test("No preview falls back to the media URL")
    func fallsBackToTheMediaURL() throws {
        let media = try media(
            type: "video",
            url: "https://files.example/clip.mp4",
            previewURL: nil
        )
        let attachment = try #require(MediaAttachment(mastodon: media))

        #expect(attachment.previewURL == attachment.url)
    }

    @Test("An upload the server is still processing is skipped")
    func skipsUnprocessedUpload() throws {
        let json = """
            {"id": "1", "type": "image", "url": null, "preview_url": "https://files.example/p.jpg",
             "remote_url": null, "description": null, "blurhash": null, "meta": null}
            """
        let media = try JSONDecoder.mastodon.decode(
            MastodonMediaAttachment.self,
            from: Data(json.utf8)
        )

        #expect(MediaAttachment(mastodon: media) == nil)
    }
}

/// Article images live in a web view, so click-to-enlarge is done inside the document. These
/// assert the document still carries it — the failure mode is silent, since an article without
/// the script renders perfectly and simply does nothing when clicked.
@Suite("Reader document media")
struct ReaderDocumentMediaTests {

    private func document() -> String {
        let key = SortKey(millis: 1_700_000_000_000, id: "a")
        let item = CachedItem(
            id: "a",
            sourceID: "freshrss:acct:feed/1",
            accountID: UUID(),
            kind: .article,
            title: "A piece with pictures in it",
            contentHTML: "<p>Words.</p><img src=\"https://files.example/wide.png\">",
            excerpt: "Words.",
            publishedAt: .now,
            sortKey: key,
            ingestKey: key
        )
        return ReaderDocument.html(for: item)
    }

    @Test("An article can open its images")
    func carriesTheLightbox() {
        let html = document()
        #expect(html.contains("rr-lightbox"))
        #expect(html.contains("cursor: zoom-in"))
        #expect(html.contains("<script>"))
    }

    /// A feed that emits `<video>` without `controls` gives you a still frame you cannot start.
    @Test("Video and audio are given controls")
    func enablesMediaControls() {
        let html = document()
        #expect(html.contains("querySelectorAll(\"video, audio\")"))
        #expect(html.contains("media.controls = true"))
        #expect(html.contains("preload = \"metadata\""))
    }

    /// An image the author wrapped in a link must still follow the link.
    @Test("A linked image is left to its link")
    func linkedImagesAreLeftAlone() {
        #expect(document().contains("image.closest(\"a\")"))
    }

    /// The blank document is loaded between selections to clear the pane. Anything running in it
    /// is pure waste, and a lightbox left open in it would survive the swap.
    @Test("The blank document carries no script")
    func blankDocumentIsInert() {
        #expect(!ReaderDocument.blank.contains("<script>"))
        #expect(!ReaderDocument.blank.contains("rr-lightbox"))
    }
}

/// On the Mac the viewer is a sheet, and a sheet is exactly as large as its content — so its size
/// is a calculation rather than a constraint the window applies. Getting it from the window is the
/// whole point: named as a fixed ideal size it came up 900 by 700 whatever the window was doing,
/// which on a large display is a small window inside a big one.
@Suite("Media viewer sizing")
struct MediaViewerSizingTests {

    @Test("It takes four fifths of the window")
    func takesFourFifths() throws {
        let size = try #require(MediaViewer.presentedSize(inHostOf: CGSize(width: 1600, height: 1000)))
        #expect(size.width == 1280)
        #expect(size.height == 800)
    }

    /// A sheet cannot be larger than the window it belongs to, so asking for more than the host
    /// only has the window clamp it — the floor must never win against the host's own size.
    @Test("The floor never pushes it past the window")
    func neverExceedsTheHost() throws {
        let size = try #require(MediaViewer.presentedSize(inHostOf: CGSize(width: 300, height: 240)))
        #expect(size.width == 300)
        #expect(size.height == 240)
    }

    /// Four fifths of a narrow window is not enough to look at a photograph in.
    @Test("A small window still gets a usable viewer")
    func appliesAFloor() throws {
        let size = try #require(MediaViewer.presentedSize(inHostOf: CGSize(width: 900, height: 420)))
        #expect(size.width == 720)
        // 336 would be four fifths; the floor raises it, and 420 is still the ceiling.
        #expect(size.height == 360)
    }

    /// The first evaluation happens before the geometry reader has reported anything, and a sheet
    /// framed to zero would come up as a sliver.
    @Test("An unmeasured window yields no opinion at all")
    func unmeasuredHostHasNoSize() {
        #expect(MediaViewer.presentedSize(inHostOf: .zero) == nil)
        #expect(MediaViewer.presentedSize(inHostOf: CGSize(width: 800, height: 0)) == nil)
    }
}

/// The shape the media viewer lays a video out in.
///
/// `VideoPlayer` draws its transport bar along the bottom edge of its own bounds, so a player
/// stretched to fill the page puts the scrubber at the very bottom of the screen — on an iPhone,
/// down in the home indicator's strip, which is where it was reported as barely usable. Sizing the
/// player to the video puts the controls under the picture instead, which makes this small function
/// a layout decision rather than a formatting detail.
@Suite("Media aspect")
struct MediaAspectTests {

    private func attachment(
        width: Int?,
        height: Int?,
        kind: MediaAttachment.Kind = .video
    ) -> MediaAttachment {
        MediaAttachment(
            url: URL(string: "https://example.com/clip.mp4")!,
            kind: kind,
            width: width,
            height: height
        )
    }

    @Test("A video's dimensions become its ratio")
    func knownDimensions() throws {
        let ratio = try #require(MediaAspect.ratio(for: attachment(width: 1_920, height: 1_080)))

        // Compared with a tolerance rather than for equality: 1920/1080 and 16/9 are the same
        // number and not the same `Double`, which is a fact about binary division rather than
        // anything this function should be asserting about.
        #expect(abs(ratio - 16.0 / 9.0) < 0.000_001)
    }

    @Test("A portrait video is taller than it is wide")
    func portrait() throws {
        let ratio = try #require(MediaAspect.ratio(for: attachment(width: 1_080, height: 1_920)))

        #expect(ratio < 1)
    }

    /// Nothing is imposed rather than something guessed: `nil` is what `aspectRatio` reads as
    /// "leave this alone", and a guessed 16:9 would squash exactly the portrait clips above.
    @Test("Missing dimensions impose no shape")
    func missingDimensions() {
        #expect(MediaAspect.ratio(for: attachment(width: nil, height: nil)) == nil)
        #expect(MediaAspect.ratio(for: attachment(width: 1_920, height: nil)) == nil)
        #expect(MediaAspect.ratio(for: attachment(width: nil, height: 1_080)) == nil)
    }

    /// A zero would divide, and a server describing a zero-width video is describing nothing.
    @Test("Zero and negative dimensions are treated as absent")
    func degenerateDimensions() {
        #expect(MediaAspect.ratio(for: attachment(width: 0, height: 1_080)) == nil)
        #expect(MediaAspect.ratio(for: attachment(width: 1_920, height: 0)) == nil)
        #expect(MediaAspect.ratio(for: attachment(width: -16, height: -9)) == nil)
    }

    /// Audio has no shape, and a player box sized to one would be nonsense.
    @Test("Audio imposes no shape")
    func audio() {
        #expect(MediaAspect.ratio(for: attachment(width: nil, height: nil, kind: .audio)) == nil)
    }
}
