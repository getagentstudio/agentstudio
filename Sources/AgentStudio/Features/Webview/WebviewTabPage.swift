import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Observation
import WebKit
import os

/// Makes the loaded page for a browser tab. The controller calls it only when
/// a tab is first opened or selected, so a restored tab costs nothing until
/// the person shows it.
@MainActor
package protocol WebviewTabPageFactory {
    func makeTabPage(
        contentInteractionEnabled: Bool,
        onCommittedNavigation: @escaping @MainActor (URL, String) -> Void
    ) -> WebviewTabPage
}

/// The production factory: one `WebPage` per tab, sharing the app's website data store.
package struct WebKitWebviewTabPageFactory: WebviewTabPageFactory {
    package init() {}

    package func makeTabPage(
        contentInteractionEnabled: Bool,
        onCommittedNavigation: @escaping @MainActor (URL, String) -> Void
    ) -> WebviewTabPage {
        WebviewTabPage(
            contentInteractionEnabled: contentInteractionEnabled,
            onCommittedNavigation: onCommittedNavigation
        )
    }
}

/// The committed document a browser tab shows.
struct WebviewCommittedPage: Equatable, Sendable {
    let url: URL
    let title: String
}

/// One pass of a browser tab's page observation, as its owner recorded it at
/// the end of the pass, after that pass's publication. `sequence` counts the
/// passes. A load has ended when a pass shows `isLoading` false after one that
/// showed it true; the document's title can arrive in a later pass.
struct WebviewTabObservation: Equatable, Sendable {
    let sequence: Int
    let committedPage: WebviewCommittedPage?
    let isLoading: Bool
}

/// One read of the page by the owner's observation: its committed document
/// and whether a load is in progress.
private struct WebviewTabPageObservedState: Equatable {
    let committedPage: WebviewCommittedPage?
    let isLoading: Bool
}

/// One loaded browser tab: its `WebPage`, its own management script, and the
/// observation that reports its committed page, active or not.
@Observable
@MainActor
package final class WebviewTabPage {
    private static let logger = Logger(subsystem: "com.agentstudio", category: "WebviewTabPage")

    /// All browser tabs share one persistent data store (cookies, local storage).
    static let sharedWebsiteDataStore: WKWebsiteDataStore = .default()

    let page: WebPage
    private(set) var isContentInteractionEnabled: Bool
    /// The last committed address this tab reported, nil until its first commit.
    private(set) var lastCommittedURL: URL?
    /// False once committed-page observation has ended, after the tab closes.
    private(set) var isObservingCommittedPage = true
    /// The latest pass of the page's observation, recorded at the end of the
    /// pass, so it never precedes that pass's publication.
    private(set) var lastObservation: WebviewTabObservation?
    /// True once `close()` has cancelled this tab's work.
    private(set) var isClosed = false
    @ObservationIgnored private let userContentController: WKUserContentController
    /// The latest interaction-state apply; a newer apply or `close()` cancels it.
    @ObservationIgnored private(set) var interactionApplyTask: Task<Void, Never>?
    @ObservationIgnored private var navigationObservationTask: Task<Void, Never>?

    /// Starts observing the page at once, so every committed navigation,
    /// active or not, reaches `onCommittedNavigation` with the page's address and title.
    package init(
        contentInteractionEnabled: Bool,
        onCommittedNavigation: @escaping @MainActor (URL, String) -> Void
    ) {
        self.isContentInteractionEnabled = contentInteractionEnabled
        let managementScript = WebInteractionManagementScript.makeUserScript(
            blockInteraction: !contentInteractionEnabled
        )
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = Self.sharedWebsiteDataStore
        configuration.userContentController.addUserScript(managementScript)
        self.userContentController = configuration.userContentController
        self.page = WebPage(
            configuration: configuration,
            navigationDecider: WebviewNavigationDecider(),
            dialogPresenter: WebviewDialogHandler()
        )
        observeCommittedPage(onCommittedNavigation)
    }

    /// The page's one observation. It publishes the tab's committed page each
    /// time it changes: a new committed document, a redirect's final address,
    /// Back, Forward, or the document's title arriving. A provisional or failed
    /// navigation changes neither the committed item nor the document title, so
    /// it publishes nothing. Each pass then records what it observed, after any
    /// publication it made.
    private func observeCommittedPage(_ onCommitted: @escaping @MainActor (URL, String) -> Void) {
        let page = self.page
        navigationObservationTask = Task { @MainActor [weak self] in
            defer { self?.isObservingCommittedPage = false }
            var lastObserved: WebviewTabPageObservedState?
            var lastPublished: WebviewCommittedPage?
            var passes = 0
            for await observed in Observations({
                WebviewTabPageObservedState(committedPage: Self.committedPage(of: page), isLoading: page.isLoading)
            }) {
                guard observed != lastObserved else { continue }
                lastObserved = observed
                if observed.committedPage != lastPublished {
                    lastPublished = observed.committedPage
                    if let committedPage = observed.committedPage {
                        self?.lastCommittedURL = committedPage.url
                        onCommitted(committedPage.url, committedPage.title)
                    }
                }
                passes += 1
                self?.lastObservation = WebviewTabObservation(
                    sequence: passes, committedPage: observed.committedPage, isLoading: observed.isLoading)
            }
        }
    }

    /// The page's committed document: the back-forward list's current item and
    /// the document title. `WebPage.url` already names a provisional
    /// navigation's address as soon as it starts; the current item moves only
    /// on commit.
    static func committedPage(of page: WebPage) -> WebviewCommittedPage? {
        guard let item = page.backForwardList.currentItem else { return nil }
        return WebviewCommittedPage(url: item.url, title: page.title)
    }

    /// Cancels this tab's observation and interaction work. The page is
    /// released when the controller drops its reference.
    func close() {
        isClosed = true
        navigationObservationTask?.cancel()
        navigationObservationTask = nil
        interactionApplyTask?.cancel()
        interactionApplyTask = nil
        page.stopLoading()
    }

    // MARK: - Content Interaction

    /// Keeps both the current document and future navigations in sync with the
    /// management layer's interaction state.
    func setContentInteractionEnabled(_ enabled: Bool) {
        let didChange = enabled != isContentInteractionEnabled
        isContentInteractionEnabled = enabled
        if didChange {
            refreshPersistentManagementScript()
        }
        applyCurrentDocumentInteractionState()
    }

    private func refreshPersistentManagementScript() {
        userContentController.removeAllUserScripts()
        userContentController.addUserScript(
            WebInteractionManagementScript.makeUserScript(blockInteraction: !isContentInteractionEnabled)
        )
    }

    private func applyCurrentDocumentInteractionState() {
        let script = WebInteractionManagementScript.makeRuntimeToggleSource(
            blockInteraction: !isContentInteractionEnabled
        )
        interactionApplyTask?.cancel()
        let page = self.page
        let shouldReapplyAfterLoad = page.isLoading
        let passBeforeApply = lastObservation?.sequence

        interactionApplyTask = Task { @MainActor [weak self] in
            do {
                _ = try await page.callJavaScript(script)
            } catch is CancellationError {
                return
            } catch {
                Self.logger.debug(
                    "Failed to apply interaction script: \(error.localizedDescription, privacy: .public)"
                )
            }

            guard shouldReapplyAfterLoad else { return }

            // Reapply once this load ends, to the document it produced, as the
            // page's own observation reports it: a pass after the apply showing
            // the page no longer loading. No deadline: a newer apply or closing
            // the tab cancels the wait, and a page that never finishes loading
            // never needs the reapply.
            guard let self else { return }
            var lastPass: Int?
            for await observation in Observations({ self.lastObservation }) {
                guard observation?.sequence != lastPass else { continue }
                lastPass = observation?.sequence
                if let observation, observation.sequence != passBeforeApply, !observation.isLoading { break }
            }

            if Task.isCancelled { return }
            do {
                _ = try await page.callJavaScript(script)
            } catch is CancellationError {
                return
            } catch {
                Self.logger.debug(
                    "Failed to reapply interaction script: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
