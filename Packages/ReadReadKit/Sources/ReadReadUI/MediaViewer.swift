import AVKit
import ReadReadModel
import SwiftUI

/// What the full-screen media viewer is currently showing.
///
/// Held by ``RootView`` and reached through the environment rather than owned by whichever view
/// was clicked. A timeline row is recycled the moment it scrolls off, and a sheet presented *from*
/// a row goes with it — so a viewer opened from the timeline would close itself as soon as an
/// arriving refresh moved the list. Presenting from the shell instead outlives the row entirely.
@MainActor
@Observable
final class MediaViewerModel {

    /// One opening of the viewer.
    ///
    /// Carries the whole post's media, not just the one that was clicked, so the viewer can page
    /// between them — which is what anyone who opens the second of four pictures expects next.
    struct Session: Identifiable, Equatable {
        let id = UUID()
        var attachments: [Attachment]
        var index: Int
    }

    var session: Session?

    func present(_ attachments: [Attachment], startingAt index: Int) {
        guard !attachments.isEmpty else { return }
        session = Session(
            attachments: attachments,
            index: min(max(index, 0), attachments.count - 1)
        )
    }

    func dismiss() {
        session = nil
    }
}

/// Media at full size: images zoomable, video and audio playable.
struct MediaViewer: View {

    let attachments: [Attachment]

    /// Which attachment to open on.
    let initialIndex: Int

    init(attachments: [Attachment], initialIndex: Int) {
        self.attachments = attachments
        self.initialIndex = initialIndex
        // Seeded here rather than in `onAppear`: `scrollPosition(id:)` has to hold the right value
        // for the *first* layout, or opening the third of four pictures shows the first and then
        // jumps — or, when the scroll view has already settled, does not jump at all.
        _currentID = State(initialValue: initialIndex)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The page the scroll view has settled on, as an index into ``attachments``.
    ///
    /// Optional because that is the shape `scrollPosition(id:)` binds to — it is nil while the
    /// scroll view is between pages.
    @State private var currentID: Int?

    /// Whether the visible image is scaled past its fit.
    ///
    /// Hoisted out of the page because it has to turn *paging* off: while an image is zoomed a
    /// drag is a pan, and leaving the paging behaviour attached means every attempt to look at the
    /// right-hand side of a photo flicks to the next one instead.
    @State private var isZoomed = false

    /// Created with the viewer and released with it. See ``MediaImageLoader``.
    @State private var loader = MediaImageLoader()

    private var index: Int { currentID ?? initialIndex }

    var body: some View {
        ZStack {
            // Deliberately not a material: media is looked *at*, and the surround should not
            // colour it. Black is what every viewer that respects photographs uses.
            Color.black
                .ignoresSafeArea()

            pages

            chrome
        }
        // Deliberately no frame of its own. On the Mac a sheet takes the size of its content, so
        // an ideal size named here *is* the sheet's size — a fixed 900 by 700 regardless of the
        // window it belongs to, which on a large display is a small window inside a big one. The
        // presentation measures the window and passes the size in instead.
        #if !os(macOS)
        .statusBarHidden()
        #endif
        // Left and right page on the Mac, where there is a keyboard and no swipe. Escape is
        // handled by the close button's cancel-action shortcut.
        //
        // Focusable because `onKeyPress` only fires for a focused view, and a freshly presented
        // sheet's content is not focused — so the arrows would have gone nowhere. The focus ring
        // is off: there is nothing here for a ring to usefully surround.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
    }

    private var pages: some View {
        ScrollView(.horizontal) {
            // `LazyHStack`, and it has to be. A plain `HStack` lays every page out at once, and
            // the scroll view then simply starts at offset zero — so `scrollPosition(id:)` never
            // established the opening page and *every* picture opened on the first one. A lazy
            // stack materialises its children from the scroll position instead, which is what
            // makes that binding mean anything on the first layout.
            //
            // Laziness used to cost something here: a page torn down as it scrolled out took its
            // in-flight image load with it, and the cancellation came back latched as a failure.
            // That is no longer this stack's problem — ``MediaImageLoader`` owns the loads, not
            // the pages, so a page can come and go as often as it likes.
            LazyHStack(spacing: 0) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { offset, attachment in
                    MediaPage(
                        attachment: attachment,
                        // Only the page you are looking at plays. Without this every video in the
                        // post would start at once, four soundtracks over each other.
                        isCurrent: offset == index,
                        isZoomed: $isZoomed,
                        loader: loader
                    )
                    .containerRelativeFrame(.horizontal)
                    .id(offset)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentID)
        .scrollDisabled(isZoomed || attachments.count == 1)
        .scrollIndicators(.hidden)
        // Held here rather than in each page's `onDisappear`, which is where it was: with a lazy
        // stack the page that disappears is usually *not* the page you are looking at, so leaving
        // one behind while zoomed into another would clear the flag under it and quietly hand the
        // drag gesture back to paging.
        .onChange(of: currentID) { _, _ in isZoomed = false }
    }

    @ViewBuilder
    private var chrome: some View {
        VStack {
            HStack(alignment: .top) {
                if attachments.count > 1 {
                    Text("\(index + 1) of \(attachments.count)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.4), in: .capsule)
                }

                Spacer(minLength: 8)

                Button("Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.4), in: .circle)
                    .keyboardShortcut(.cancelAction)
            }

            Spacer(minLength: 0)

            // The author's alt text, which is a description of the picture and so belongs with it
            // rather than only in the accessibility tree.
            if let description = attachments[safe: index]?.describedAs, !description.isEmpty {
                ScrollView {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(12)
                .background(.black.opacity(0.55), in: .rect(cornerRadius: 12))
                // Hidden from VoiceOver, and only from VoiceOver. This caption exists so a
                // *sighted* reader gets the description too; the same string is the picture's own
                // accessibility label, where it belongs. Exposed here as well it would simply be
                // read out twice, once as the image and once as the text under it.
                .accessibilityHidden(true)
            }
        }
        .padding(16)
        // Chrome must never eat a drag meant for the image underneath it.
        .allowsHitTesting(true)
        .opacity(isZoomed ? 0 : 1)
        .motionSafeAnimation(.easeInOut(duration: 0.15), value: isZoomed)
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        guard attachments.count > 1, !isZoomed else { return .ignored }
        let next = index + delta
        guard attachments.indices.contains(next) else { return .ignored }
        withAnimation(.motionSafe(.default, reduceMotion: reduceMotion)) { currentID = next }
        return .handled
    }
}

/// One attachment, filling the viewer.
private struct MediaPage: View {

    let attachment: Attachment
    let isCurrent: Bool
    @Binding var isZoomed: Bool
    let loader: MediaImageLoader

    var body: some View {
        switch attachment.kind {
        case .image:
            ZoomableImage(
                attachment: attachment,
                isCurrent: isCurrent,
                isZoomed: $isZoomed,
                loader: loader
            )
        case .video, .gifv, .audio:
            AttachmentPlayer(attachment: attachment, isCurrent: isCurrent)
        case .other:
            // Nothing here can be shown inline — a PDF enclosure, an unknown type. Said plainly
            // rather than drawn as a broken image.
            UnplayableMedia(attachment: attachment)
        }
    }
}

/// An image that can be pinched, double-clicked and dragged.
private struct ZoomableImage: View {

    let attachment: Attachment
    let isCurrent: Bool
    @Binding var isZoomed: Bool
    let loader: MediaImageLoader

    /// The committed scale, plus whatever a live pinch is adding to it.
    @State private var scale: CGFloat = 1
    @State private var gestureScale: CGFloat = 1

    @State private var offset: CGSize = .zero
    @State private var gestureOffset: CGSize = .zero

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let maximumScale: CGFloat = 6
    private static let doubleTapScale: CGFloat = 2.5

    /// How far one VoiceOver zoom step moves the scale.
    ///
    /// Coarser than a pinch on purpose: the rotor's zoom is a discrete command, so a step small
    /// enough to be smooth under a finger would need a dozen of them to get anywhere.
    private static let zoomActionStep: CGFloat = 1.6

    private var effectiveScale: CGFloat {
        min(max(scale * gestureScale, 1), Self.maximumScale)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onChange(of: effectiveScale) { _, scale in
                // Only the page being looked at speaks for the viewer's zoom state. A page that
                // is not current is resetting itself below, and must not report that as the
                // reader having zoomed back out of the page they are actually on.
                guard isCurrent else { return }
                isZoomed = scale > 1.01
            }
            .onChange(of: isCurrent) { _, current in
                // A page you have left forgets how you left it, so paging back gives you the
                // whole picture rather than the corner of it you were last looking at.
                if !current { reset() }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch loader.state(for: attachment.url) {
        case .loaded(let image):
            image
                .resizable()
                // Fit, not fill: the viewer's job is to show the whole picture, and filling
                // would crop the edges off the very thing that was opened to be seen.
                .scaledToFit()
                .scaleEffect(effectiveScale)
                .offset(
                    x: offset.width + gestureOffset.width,
                    y: offset.height + gestureOffset.height
                )
                .gesture(magnification)
                .gesture(pan, including: effectiveScale > 1 ? .all : .subviews)
                .onTapGesture(count: 2) { toggleZoom() }
                // The picture had no name at all. Its description was drawn in the chrome, which
                // is where a sighted reader finds it — but the image itself reached VoiceOver as
                // an unlabelled element, so the one thing the viewer exists to show announced
                // nothing.
                .accessibilityLabel(attachment.describedAs.map { Text($0) } ?? Text("Image"))
                .accessibilityValue(zoomDescription)
                // Zooming was a pinch or a double-tap and nothing else, which is to say it was
                // unavailable to anyone driving the app by VoiceOver — where a double-tap is
                // "activate" and a pinch is not a gesture that reaches the view at all. This is
                // the same zoom, offered through the rotor.
                .accessibilityZoomAction { action in
                    switch action.direction {
                    case .zoomIn: stepZoom(by: Self.zoomActionStep)
                    case .zoomOut: stepZoom(by: 1 / Self.zoomActionStep)
                    @unknown default: break
                    }
                }

        case .loading:
            ProgressView()
                .controlSize(.large)
                .tint(.white)

        case .failed:
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34))
                Text("This image could not be loaded.")
                    .font(.callout)
                // Offered because the reasons an image does not arrive are mostly temporary, and
                // without this the only way to ask again was to close the viewer and reopen it on
                // the same picture.
                Button("Try Again") { loader.retry(attachment.url) }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var magnification: some Gesture {
        MagnifyGesture()
            .onChanged { value in gestureScale = value.magnification }
            .onEnded { _ in
                scale = effectiveScale
                gestureScale = 1
                if scale <= 1.01 { reset() }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in gestureOffset = value.translation }
            .onEnded { value in
                offset.width += value.translation.width
                offset.height += value.translation.height
                gestureOffset = .zero
            }
    }

    /// How zoomed in the picture is, announced alongside its description.
    ///
    /// Stated because the zoom action is otherwise silent: without it, asking to zoom in at full
    /// magnification and asking to zoom in with room to spare sound exactly the same.
    private var zoomDescription: Text {
        effectiveScale <= 1.01
            ? Text("Fit to screen")
            : Text("Zoomed \(Double(effectiveScale).formatted(.number.precision(.fractionLength(1))))×")
    }

    /// One step of the accessibility zoom, clamped to the same bounds as a pinch.
    private func stepZoom(by factor: CGFloat) {
        withAnimation(.motionSafe(.easeInOut(duration: 0.2), reduceMotion: reduceMotion)) {
            scale = min(max(scale * factor, 1), Self.maximumScale)
            // Back to the centre once it no longer fills the frame, so zooming out never leaves
            // the picture parked off to one side with nothing on screen.
            if scale <= 1.01 { reset() }
        }
    }

    private func toggleZoom() {
        withAnimation(.motionSafe(.easeInOut(duration: 0.2), reduceMotion: reduceMotion)) {
            if effectiveScale > 1.01 {
                reset()
            } else {
                scale = Self.doubleTapScale
            }
        }
    }

    private func reset() {
        scale = 1
        gestureScale = 1
        offset = .zero
        gestureOffset = .zero
    }
}

/// Video, animated GIF or audio, played in place.
private struct AttachmentPlayer: View {

    let attachment: Attachment
    let isCurrent: Bool

    @State private var player: AVPlayer?

    /// Retained for as long as the loop should run — `AVPlayerLooper` stops the moment it is
    /// released, which is the classic reason a "looping" video plays exactly once.
    @State private var looper: AVPlayerLooper?

    /// A `gifv` is an MP4 that Mastodon serves in place of an animated GIF, so it wants GIF
    /// behaviour: silent, endless, no fanfare.
    private var isAnimatedGIF: Bool { attachment.kind == .gifv }

    /// The video's own shape, when the server said what it is.
    private var aspectRatio: CGFloat? { MediaAspect.ratio(for: attachment) }

    var body: some View {
        VideoPlayer(player: player)
            // Shaped to the video rather than stretched to the page, and this is what puts the
            // controls within reach.
            //
            // `VideoPlayer` draws its transport bar along the bottom edge of *its own bounds*,
            // while the picture inside is letterboxed to fit. Filling the page therefore left the
            // video floating in the middle of the screen with its scrubber pinned to the very
            // bottom — on an iPhone that is down at the home indicator, which is both awkward to
            // reach and the strip where a swipe belongs to the system rather than to the app.
            //
            // Given the ratio, the player is the size of the video, so the controls sit directly
            // under the picture in the middle of the screen. `nil` is passed through deliberately:
            // the modifier then imposes nothing and the fill behaviour is unchanged.
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: isCurrent) {
                guard isCurrent else {
                    player?.pause()
                    return
                }
                if player == nil { build() }
                player?.play()
            }
            .onDisappear {
                player?.pause()
                player = nil
                looper = nil
                releaseAudioSession()
            }
    }

    private func build() {
        if isAnimatedGIF {
            let queue = AVQueuePlayer()
            queue.isMuted = true
            looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: attachment.url))
            player = queue
        } else {
            claimAudioSession()
            player = AVPlayer(url: attachment.url)
        }
    }

    /// Lets a video with a soundtrack actually be heard.
    ///
    /// Without this the app keeps the default `soloAmbient` category, under which iOS silences
    /// playback whenever the ring switch is set to silent — so tapping a video would play a silent
    /// one and look broken. Deliberately not claimed for a muted GIF: interrupting whatever the
    /// reader is listening to in order to play no sound at all is worse than doing nothing.
    private func claimAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        #endif
    }

    private func releaseAudioSession() {
        #if os(iOS)
        guard !isAnimatedGIF else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

/// The shape a piece of media should be laid out in.
///
/// Its own type, and not private, because it decides a layout that cannot be checked by looking:
/// a wrong answer here is a video the size of a stripe, or a scrubber under the home indicator.
enum MediaAspect {

    /// Width over height, or `nil` when the server did not say.
    ///
    /// `nil` rather than a guessed 16:9. A guess is wrong for exactly the videos that suffer most
    /// from it — a portrait clip in a landscape box is shrunk to the height of the box — and `nil`
    /// is what `aspectRatio(_:contentMode:)` takes to mean "impose nothing", which leaves the
    /// player filling its page as it did before. Audio has no shape at all and lands here too.
    ///
    /// Zero and negative are rejected as absent, not clamped: a zero would divide, and a store or
    /// a server sending `width: 0` is describing nothing rather than describing a stripe.
    static func ratio(for attachment: Attachment) -> CGFloat? {
        guard let width = attachment.width, let height = attachment.height,
              width > 0, height > 0
        else {
            return nil
        }
        return CGFloat(width) / CGFloat(height)
    }
}

/// An attachment this app has no way to show.
private struct UnplayableMedia: View {

    let attachment: Attachment

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.7))

            (attachment.mimeType.map { Text($0) } ?? Text("Attachment"))
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))

            Button("Open in Browser") { openURL(attachment.url) }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension Array {
    /// Bounds-checked subscript, for chrome that reads the current page while it is mid-scroll.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension View {

    /// Presents ``MediaViewer`` for whatever the model is currently holding.
    ///
    /// A modifier rather than inline in ``RootView`` because the presentation differs by platform
    /// in two ways: a full-screen cover is the right shape on a phone and does not exist on the
    /// Mac, and on the Mac the sheet has to be *measured* against the window it comes out of.
    func mediaViewer(_ model: MediaViewerModel) -> some View {
        modifier(MediaViewerPresentation(model: model))
    }
}

private struct MediaViewerPresentation: ViewModifier {

    let model: MediaViewerModel

    /// The size of the view this is attached to — the split view, so the window's content area.
    ///
    /// Measured rather than asked of `NSWindow`: the shell is the thing the sheet is proportional
    /// to, it is right here, and it keeps reporting as the window is resized, so a sheet that is
    /// already open follows the window instead of keeping the size it was born at.
    @State private var hostSize: CGSize = .zero

    private var session: Binding<MediaViewerModel.Session?> {
        Binding(get: { model.session }, set: { model.session = $0 })
    }

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { hostSize = $0 }
            .sheet(item: session) { session in
                let size = MediaViewer.presentedSize(inHostOf: hostSize)
                MediaViewer(attachments: session.attachments, initialIndex: session.index)
                    // Nil until the host has been measured, which `frame` reads as "no opinion" —
                    // so the first frame sizes itself and every frame after follows the window.
                    .frame(width: size?.width, height: size?.height)
            }
        #else
        content
            .fullScreenCover(item: session) { session in
                MediaViewer(attachments: session.attachments, initialIndex: session.index)
            }
        #endif
    }
}

extension MediaViewer {

    /// How large the viewer should come up, given the window it is presented from.
    ///
    /// Four fifths of the window, so it reads as a viewer *over* the app rather than a panel
    /// beside it, and so the picture gets most of the screen the reader has already chosen to
    /// give the app. Nil for a host not yet measured, which leaves the sheet to size itself for
    /// the one frame before the measurement lands.
    static func presentedSize(inHostOf host: CGSize) -> CGSize? {
        guard host.width > 0, host.height > 0 else { return nil }

        // Floored, then capped back to the window. A narrow window's four fifths is not enough to
        // look at a photograph in, and a sheet cannot exceed its parent window anyway — so asking
        // for more than the host would only have the window silently clamp it.
        return CGSize(
            width: min(max(host.width * fraction, minimumSide), host.width),
            height: min(max(host.height * fraction, minimumSide), host.height)
        )
    }

    private static let fraction: CGFloat = 0.8
    private static let minimumSide: CGFloat = 360
}
