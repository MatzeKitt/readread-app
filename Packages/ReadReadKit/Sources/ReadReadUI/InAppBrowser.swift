import Foundation
import Observation
import SwiftUI

#if os(iOS)
import SafariServices
#endif

/// Where a tapped link should go.
enum LinkDestination: Equatable {
    /// Inside the app, in a Safari view.
    case inAppBrowser
    /// Out to whatever the system does with it — the default browser, Mail, the App Store.
    case system
}

/// Decides which of the two a link gets.
///
/// A separate, pure decision because it is the part that can be wrong in ways nobody would notice
/// by clicking around: a `mailto:` handed to a Safari view is not a mistake you see until someone
/// taps an author's address.
enum LinkPolicy {

    static func destination(for url: URL, opensInApp: Bool) -> LinkDestination {
        #if os(iOS)
        guard opensInApp else { return .system }

        // `SFSafariViewController` accepts http and https and *only* those — it raises on anything
        // else rather than declining politely. So mail, telephone, App Store and every custom
        // scheme go to the system, which is also where they belong: those are requests to leave
        // for another app, not to read a page.
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .system
        }
        return .inAppBrowser
        #else
        // No in-app browser on the Mac, and no wish for one: a link opens in the browser the
        // reader has already chosen, in a window they can keep.
        return .system
        #endif
    }
}

/// The page the in-app browser is showing, if it is open.
@MainActor
@Observable
final class InAppBrowserModel {

    /// Identified by a fresh id per opening rather than by the URL, so tapping the same link twice
    /// in a row presents it twice rather than the second tap doing nothing.
    struct Session: Identifiable, Equatable {
        let id = UUID()
        var url: URL
    }

    var session: Session?

    func open(_ url: URL) {
        session = Session(url: url)
    }

    func dismiss() {
        session = nil
    }
}

extension View {

    /// Presents the in-app browser for whatever the model is holding.
    ///
    /// Attached to the shell, like the media viewer, so a link tapped in a timeline row is not
    /// dismissed by the row being recycled underneath it.
    func inAppBrowser(_ model: InAppBrowserModel) -> some View {
        modifier(InAppBrowserPresentation(model: model))
    }
}

private struct InAppBrowserPresentation: ViewModifier {

    let model: InAppBrowserModel

    func body(content: Content) -> some View {
        #if os(iOS)
        // Presented by UIKit, not by SwiftUI, and that distinction is the whole of this.
        //
        // It was a `fullScreenCover` around a `UIViewControllerRepresentable`, on the reasoning
        // that `SFSafariViewController` "brings its own Done button and swipe-to-dismiss". It
        // brings them as a *presented view controller*. Inside a cover it is not one — SwiftUI owns
        // the presentation and the controller is a child view inside it, so its Done button and
        // its swipe-from-the-left-edge had nothing to dismiss and the only way back out was
        // whatever chrome SwiftUI supplied.
        //
        // Handing it to `present(_:animated:)` instead makes it the presented controller it is
        // documented to be, and its own gestures work because they are driving its own dismissal.
        content.background(
            SafariPresenter(session: model.session) { model.dismiss() }
                // No size and no hit testing: this is a handle on the view controller hierarchy,
                // not a view. Left visible it would sit behind the whole window swallowing taps.
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        #else
        content
        #endif
    }
}

#if os(iOS)
/// Safari, inside the app.
///
/// `SFSafariViewController` rather than a `WebView` of our own. It is the same engine, but it also
/// brings the things a reader expects from a browser and that would each have to be rebuilt
/// otherwise: Reader mode, the share sheet, AutoFill, content blockers, and Safari's own cookie
/// jar — so a page that knows the reader stays logged in. It is also the presentation that keeps
/// the app out of the page: the browsing that happens inside it is not visible to this app at all.
private struct SafariPresenter: UIViewControllerRepresentable {

    let session: InAppBrowserModel.Session?

    /// Called when Safari dismissed itself — Done, or the swipe. The model still holds the session
    /// at that point, and leaving it there would mean the next tap on the *same* link did nothing.
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        context.coordinator.onFinish = onFinish
        context.coordinator.update(to: session, from: host)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    @MainActor
    final class Coordinator: NSObject, SFSafariViewControllerDelegate {

        var onFinish: () -> Void

        /// Which session is on screen, so a redraw does not present a second copy of the page
        /// already being read. Compared by id rather than by URL, because opening the same link
        /// twice is deliberately two sessions — see ``InAppBrowserModel/Session``.
        private var presentedID: InAppBrowserModel.Session.ID?

        private weak var presented: SFSafariViewController?

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func update(to session: InAppBrowserModel.Session?, from host: UIViewController) {
            guard let session else {
                // Dismissed from the app's side rather than by the reader — the model was cleared
                // while Safari was still up.
                if let presented, presented.presentingViewController != nil {
                    presented.dismiss(animated: true)
                }
                self.presented = nil
                presentedID = nil
                return
            }

            guard session.id != presentedID else { return }

            let configuration = SFSafariViewController.Configuration()
            // Not forced on: a linked page is as often a video or an app listing as it is an
            // article, and Reader on one of those is an empty page. Safari offers it per page
            // anyway.
            configuration.entersReaderIfAvailable = false

            let controller = SFSafariViewController(url: session.url, configuration: configuration)
            controller.dismissButtonStyle = .done
            controller.delegate = self

            guard let presenter = Self.presenter(from: host) else { return }
            presentedID = session.id
            presented = controller
            presenter.present(controller, animated: true)
        }

        /// The controller that can actually present right now.
        ///
        /// The host is a zero-sized view's controller buried in SwiftUI's own hierarchy, and
        /// presenting from a controller that is itself already presenting something is what
        /// produces the "attempt to present while a presentation is in progress" failure. So: up
        /// to the root, then down through whatever is already modal.
        private static func presenter(from host: UIViewController) -> UIViewController? {
            var candidate: UIViewController = host
            while let parent = candidate.parent { candidate = parent }
            while let next = candidate.presentedViewController, !next.isBeingDismissed {
                candidate = next
            }
            return candidate.isViewLoaded && candidate.view.window != nil ? candidate : nil
        }

        nonisolated func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            MainActor.assumeIsolated {
                presented = nil
                presentedID = nil
                onFinish()
            }
        }
    }
}
#endif
