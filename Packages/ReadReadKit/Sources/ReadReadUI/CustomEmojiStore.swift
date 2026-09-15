import Foundation
import Observation
import SwiftUI

#if os(macOS)
import AppKit
private typealias EmojiPlatformImage = NSImage
#else
import UIKit
private typealias EmojiPlatformImage = UIImage
#endif

/// Downloads and caches custom emoji images.
///
/// A single shared store rather than one per view: the same handful of emoji recur across a whole
/// timeline, and a per-status cache would re-download `:blobcat:` for every post that used it.
///
/// Not `AsyncImage`, which cannot be placed inside a `Text` — and inline is the only place these
/// belong. A custom emoji is a character in a sentence, not a picture beside one.
@MainActor
@Observable
final class CustomEmojiStore {

    static let shared = CustomEmojiStore()

    /// One emoji's bytes, plus the glyphs already built from them.
    ///
    /// A reference type with its own observation, and both halves matter.
    ///
    /// **Observation.** As a stored dictionary on an `@Observable` store, every arriving emoji
    /// invalidated every view that had ever asked for one — a timeline of posts sharing a handful
    /// of shortcodes re-rendered itself once per download. Observation is per *property*, and
    /// `entries` was one property, so there was no finer grain to be had while the images lived
    /// inside it. Reading through an entry moves the dependency onto the emoji actually being
    /// drawn, so a `:blobcat:` arriving redraws the posts using `:blobcat:`.
    ///
    /// **Glyphs.** Rendering used to happen on every call, which is to say on every body
    /// evaluation of every text mentioning the emoji: `NSImage(data:)`/`UIImage(data:)` is a full
    /// decode, and the macOS path then rasterised the result through `lockFocus`. All of it on the
    /// main actor, all of it to produce a value identical to the one produced last frame. Keyed by
    /// height because that is the only thing that varies — Dynamic Type and the reading-pane size
    /// preference both feed into it.
    @MainActor
    @Observable
    final class Entry {

        /// The bytes, or `nil` for one that failed. A broken URL is attempted once rather than on
        /// every redraw of every post that mentions it, which is what ``hasLoaded`` distinguishes.
        var data: Data?

        /// Whether the fetch has finished, either way.
        ///
        /// Separate from `data` because an entry now exists from the first *ask*, not from the
        /// first answer — `image(for:height:)` creates it so there is something to observe while
        /// the download is still running.
        @ObservationIgnored var hasLoaded = false

        @ObservationIgnored fileprivate var glyphs: [CGFloat: Image] = [:]

        /// Enough for a list and a reading pane at different size settings, and no more: heights
        /// come from a handful of text styles, so an unbounded map here would only ever hold
        /// duplicates of the same few numbers.
        @ObservationIgnored private let glyphLimit = 4

        fileprivate func glyph(height: CGFloat, make: (Data) -> Image?) -> Image? {
            if let cached = glyphs[height] { return cached }
            guard let data, let rendered = make(data) else { return nil }
            if glyphs.count >= glyphLimit { glyphs.removeAll(keepingCapacity: true) }
            glyphs[height] = rendered
            return rendered
        }
    }

    /// Not observed, on purpose. The entries are, one at a time — see ``Entry``.
    @ObservationIgnored private var entries: [URL: Entry] = [:]

    /// Insertion order, for eviction. A federated timeline can mention a lot of distinct emoji and
    /// this cache is never otherwise emptied.
    @ObservationIgnored private var order: [URL] = []
    @ObservationIgnored private var inFlight: Set<URL> = []

    @ObservationIgnored private let limit = 512
    @ObservationIgnored private let session: URLSession

    /// The largest emoji this will decode. Instances host these, and nothing legitimate is close.
    @ObservationIgnored private let maximumBytes = 512 * 1024

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Starts loading any of these that are not already known.
    func load(_ urls: some Collection<URL>) {
        for url in urls where !entry(for: url).hasLoaded && !inFlight.contains(url) {
            inFlight.insert(url)
            Task { await fetch(url) }
        }
    }

    /// The emoji image, sized to sit on a line of text, or `nil` while it is still loading.
    ///
    /// - Parameter height: The point height the glyph should occupy. Passed in rather than fixed
    ///   because it has to track Dynamic Type: an emoji pinned to 17pt beside 30pt text reads as a
    ///   rendering fault.
    func image(for url: URL, height: CGFloat) -> Image? {
        guard height > 0 else { return nil }
        // Through the entry even on a miss, so reading it takes an observation dependency on
        // *this* emoji and the caller is redrawn when it lands.
        return entry(for: url).glyph(height: height) { data in
            Self.image(from: data, height: height)
        }
    }

    // MARK: - Private

    private func fetch(_ url: URL) async {
        defer { inFlight.remove(url) }

        var request = URLRequest(url: url, timeoutInterval: 15)
        // Same reasoning as the article fetcher: this reader has no session with these hosts and
        // should not start building one.
        request.httpShouldHandleCookies = false

        var data: Data?
        if let (body, response) = try? await session.data(for: request), body.count <= maximumBytes {
            // A status code only exists for an HTTP response. `data:` URLs have none, and
            // demanding one made every inline emoji fail — including the app's own fixtures,
            // which is how this was caught.
            if let http = response as? HTTPURLResponse {
                data = (200..<300).contains(http.statusCode) ? body : nil
            } else {
                data = body
            }
        }

        let entry = entry(for: url)
        entry.hasLoaded = true
        entry.data = data
    }

    /// The entry for a URL, created on first sight so there is something to observe.
    private func entry(for url: URL) -> Entry {
        if let existing = entries[url] { return existing }

        let entry = Entry()
        entries[url] = entry
        order.append(url)

        while order.count > limit, let oldest = order.first, oldest != url {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
        return entry
    }

    /// Builds an image whose *point* size is the requested height.
    ///
    /// Done by choosing the image's scale rather than by redrawing it: a `Text` renders an inline
    /// image at its point size, so setting the scale to the ratio between the file's pixels and
    /// the wanted height gets the right result without rasterising anything.
    private static func image(from data: Data, height: CGFloat) -> Image? {
        guard height > 0 else { return nil }

        #if os(macOS)
        guard let native = NSImage(data: data), native.size.height > 0 else { return nil }
        let ratio = native.size.width / native.size.height
        let resized = NSImage(size: CGSize(width: height * ratio, height: height))
        resized.lockFocus()
        native.draw(in: CGRect(origin: .zero, size: resized.size))
        resized.unlockFocus()
        return Image(nsImage: resized)
        #else
        guard let native = UIImage(data: data), native.size.height > 0 else { return nil }
        let scale = native.size.height / height
        guard scale > 0, let cgImage = native.cgImage else { return nil }
        return Image(uiImage: UIImage(cgImage: cgImage, scale: scale, orientation: native.imageOrientation))
        #endif
    }
}
