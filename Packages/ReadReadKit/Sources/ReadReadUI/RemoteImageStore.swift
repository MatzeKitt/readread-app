import Foundation
import Observation
import SwiftUI

/// A shared cache of small remote images — favicons and avatars.
///
/// Exists because `AsyncImage` has no in-memory *decoded* cache. It re-reads and re-decodes on
/// every re-render, and a timeline re-renders whenever the fold moves. On a Mac that was merely
/// wasteful; on an iPhone scrolling a list of seventy rows, each with its own `AsyncImage`, it was
/// the reason scrolling stuttered and the CPU sat pinned.
///
/// Decoding once and handing back the same `Image` makes a re-render free.
@MainActor
@Observable
final class RemoteImageStore {

    static let shared = RemoteImageStore()

    /// A separate cache for timeline media.
    ///
    /// Separate because the two have opposite shapes. Favicons are tiny, few, and wanted for the
    /// whole session; post thumbnails are larger, endless, and stop mattering the moment they
    /// scroll away. Sharing one cache means the pictures evict the sidebar's icons, which then
    /// reload — so the icons flicker as a consequence of scrolling past photos.
    static let timelineMedia = RemoteImageStore(limit: 120, maximumBytes: 4 * 1024 * 1024)

    /// One URL's decoded image, once there is one.
    ///
    /// A reference type with observation of its own, rather than a value in the store's dictionary.
    /// Observation is per *property*, and a dictionary is one property — so every favicon that
    /// arrived invalidated every view that had ever asked this store for anything, which on a
    /// timeline is every row's icon and every post's thumbnails. The images are not re-decoded, so
    /// the cost is only re-evaluation, but it is re-evaluation of the whole visible list once per
    /// download, in the middle of the scroll this type exists to keep smooth.
    ///
    /// Reading through an entry narrows the dependency to the one picture being drawn.
    @MainActor
    @Observable
    final class Entry {

        /// Nil both while the fetch is running and when it found nothing usable — a feed with no
        /// favicon is the common case, and ``hasLoaded`` is what tells the two apart so it is
        /// attempted once rather than on every redraw.
        var image: Image?

        @ObservationIgnored var hasLoaded = false
    }

    /// Not observed, on purpose. The entries are, one at a time — see ``Entry``.
    @ObservationIgnored private var entries: [URL: Entry] = [:]

    @ObservationIgnored private var order: [URL] = []
    @ObservationIgnored private var inFlight: Set<URL> = []

    /// Enough for a large subscription list with room to spare; these are favicons.
    @ObservationIgnored private let limit: Int

    /// Icons are tiny. Anything past this is not one, and decoding it would cost more than the row
    /// it is drawn in is worth.
    @ObservationIgnored private let maximumBytes: Int

    @ObservationIgnored private let session: URLSession

    init(
        session: URLSession = .shared,
        limit: Int = 400,
        maximumBytes: Int = 2 * 1024 * 1024
    ) {
        self.session = session
        self.limit = limit
        self.maximumBytes = maximumBytes
    }

    /// The cached image, or `nil` while it loads or if there is none.
    ///
    /// Starts the load as a side effect of the first miss. That is deliberate: the caller is a
    /// list row, and giving it a separate "please load this" call to remember is how half the rows
    /// end up never asking.
    func image(for url: URL) -> Image? {
        let entry = entry(for: url)
        if !entry.hasLoaded { load(url, into: entry) }
        // Read through the entry even on a miss, so the dependency is taken on this one picture
        // and the caller is redrawn when it lands.
        return entry.image
    }

    /// The entry for a URL, created on first sight so there is something to observe.
    private func entry(for url: URL) -> Entry {
        if let existing = entries[url] { return existing }

        let entry = Entry()
        entries[url] = entry
        order.append(url)

        // Never the one just created, which is the entry the caller is about to read.
        while order.count > limit, let oldest = order.first, oldest != url {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
        return entry
    }

    private func load(_ url: URL, into entry: Entry) {
        guard !inFlight.contains(url) else { return }
        inFlight.insert(url)

        let session = session
        let maximumBytes = maximumBytes
        Task { [weak self] in
            let image = await Self.fetch(url, session: session, maximumBytes: maximumBytes)
            self?.inFlight.remove(url)
            entry.hasLoaded = true
            entry.image = image
        }
    }

    /// Fetches and decodes one image, off the main actor.
    ///
    /// Shared with ``MediaImageLoader``, which caches on completely different terms — a handful of
    /// full-size pictures for as long as the viewer is open, rather than hundreds of icons for the
    /// session — but wants exactly this fetch: no cookies, a size ceiling, a status check, and the
    /// decode done before the result reaches the main actor.
    nonisolated static func fetch(
        _ url: URL,
        session: URLSession,
        maximumBytes: Int
    ) async -> Image? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        // The reader has no session with these hosts and should not start one — the same reasoning
        // as the article fetcher.
        request.httpShouldHandleCookies = false

        guard let (data, response) = try? await session.data(for: request),
              data.count <= maximumBytes
        else { return nil }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return nil
        }

        // Decoded off the main actor. Doing it in `store` would put every favicon's decode on the
        // main thread, which is the cost this whole type exists to remove.
        #if os(macOS)
        guard let native = NSImage(data: data) else { return nil }
        return Image(nsImage: native)
        #else
        guard let native = UIImage(data: data) else { return nil }
        return Image(uiImage: native)
        #endif
    }
}
