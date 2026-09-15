import Foundation

/// What kind of source an item came from, which decides how its detail view renders.
///
/// Stored as its `String` raw value rather than as an enum attribute so it can be used directly in
/// a SwiftData `#Predicate` — predicates can only reference stored properties, and comparing raw
/// strings avoids depending on SwiftData's enum encoding staying stable across schema versions.
public enum ItemKind: String, Hashable, Sendable, Codable, CaseIterable {

    /// An RSS/Atom article from FreshRSS. Rendered as HTML in a `WebView` with reader CSS.
    case article

    /// A Mastodon status. Rendered natively in SwiftUI — the content is small and structured, and
    /// a web view would look out of place.
    case status
}

/// A media attachment or RSS enclosure.
///
/// A plain `Codable` value stored as a single attribute rather than a related `@Model`: attachments
/// are never queried independently, always loaded with their item, and modelling them as a
/// relationship would add a join and a cascade-delete rule for no benefit.
public struct Attachment: Hashable, Sendable, Codable, Identifiable {

    public enum Kind: String, Hashable, Sendable, Codable {
        case image
        case video
        case gifv
        case audio
        case other
    }

    public var url: URL
    public var kind: Kind
    public var mimeType: String?
    public var byteCount: Int?

    /// Mastodon's own description text, used as the accessibility label.
    public var describedAs: String?

    /// Mastodon blurhash, for a placeholder that matches the image's colours while it loads.
    public var blurhash: String?

    /// The server's scaled-down copy, for a thumbnail.
    ///
    /// Optional so blobs written before it existed still decode — the synthesised decoder uses
    /// `decodeIfPresent` for an optional, so an older attachment simply has no preview and falls
    /// back to ``url``. Worth carrying because a list thumbnail loaded from the full-size original
    /// downloads a few megabytes to draw sixty points of it.
    public var previewURLString: String?

    public var width: Int?
    public var height: Int?

    public var id: URL { url }

    /// The URL to load when drawing this at thumbnail size.
    public var previewURL: URL {
        previewURLString.flatMap(URL.init(string:)) ?? url
    }

    public init(
        url: URL,
        kind: Kind,
        mimeType: String? = nil,
        byteCount: Int? = nil,
        describedAs: String? = nil,
        blurhash: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        previewURLString: String? = nil
    ) {
        self.url = url
        self.kind = kind
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.describedAs = describedAs
        self.blurhash = blurhash
        self.width = width
        self.height = height
        self.previewURLString = previewURLString
    }

    /// Classifies an enclosure from a MIME type or Mastodon attachment type string.
    public static func kind(fromMIMEType type: String?) -> Kind {
        guard let type = type?.lowercased(), !type.isEmpty else { return .other }
        if type.hasPrefix("image") { return .image }
        if type.hasPrefix("video") { return .video }
        if type.hasPrefix("audio") { return .audio }
        if type == "gifv" { return .gifv }
        return .other
    }
}
