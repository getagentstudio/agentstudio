import Foundation
import Observation
import WebKit

@testable import AgentStudio
@testable import AgentStudioWebview

/// The browser controllers and pages a test made, retired when the test's body
/// exits, on a throw as well. Retiring does what pane teardown does: each
/// tracked controller retires its loaded tabs, and every page is closed. Then
/// it waits until our work has stopped: each interaction apply task has
/// returned and each committed-page observation has ended. No AgentStudio task
/// outlives the test that made it.
@MainActor
final class WebviewRetirementScope {
    private var controllerSources: [@MainActor () -> [WebviewPaneController]] = []
    private var pageSources: [@MainActor () -> [WebviewTabPage]] = []

    /// Retires every page `pages` returns when the scope ends.
    func track(pages: @escaping @MainActor () -> [WebviewTabPage]) {
        pageSources.append(pages)
    }

    func track(_ tabPage: WebviewTabPage) {
        track { [tabPage] }
    }

    /// Retires `controller`'s loaded tabs when the scope ends.
    func track(_ controller: WebviewPaneController) {
        controllerSources.append { [controller] }
    }

    /// Retires every browser mounted in `viewRegistry` when the scope ends.
    func track(_ viewRegistry: ViewRegistry) {
        controllerSources.append { viewRegistry.allWebviewViews.values.map(\.controller) }
    }

    /// Runs `body`, then retires everything it tracked, whether it returned or threw.
    static func run<Result>(_ body: (WebviewRetirementScope) async throws -> Result) async rethrows -> Result {
        let scope = WebviewRetirementScope()
        do {
            let result = try await body(scope)
            await scope.retireTracked()
            return result
        } catch {
            await scope.retireTracked()
            throw error
        }
    }

    /// Retires the browsers mounted in `viewRegistry` now, for a harness
    /// teardown that already runs on every exit path.
    static func retireMountedBrowsers(in viewRegistry: ViewRegistry) async {
        let scope = WebviewRetirementScope()
        scope.track(viewRegistry)
        await scope.retireTracked()
    }

    private func retireTracked() async {
        let controllers = controllerSources.flatMap { $0() }
        var seen = Set<ObjectIdentifier>()
        let tabPages = (controllers.flatMap { $0.loadedTabPages.values } + pageSources.flatMap { $0() })
            .filter { seen.insert(ObjectIdentifier($0)).inserted }
        let interactionApplies = tabPages.compactMap(\.interactionApplyTask)
        for controller in controllers { controller.retireAllTabPages() }
        for tabPage in tabPages where !tabPage.isClosed { tabPage.close() }
        for apply in interactionApplies { await apply.value }
        for tabPage in tabPages { await Self.observationEnded(tabPage) }
        RetiredWebPageKeepAlive.hold(tabPages.map(\.page))
    }

    /// Ends when the page's observation task has ended. Closing cancels that
    /// task and cancellation ends its loop, so this returns for a closed page.
    private static func observationEnded(_ tabPage: WebviewTabPage) async {
        for await isObserving in Observations({ tabPage.isObservingCommittedPage }) where !isObserving {
            return
        }
    }
}

/// Keeps every retired test `WebPage` until the test process exits, after all
/// of our work on it has ended.
///
/// Why: in the swiftpm test process, letting retired pages deallocate makes
/// WebKit tear down their per-page process pools mid-run, and WebKit then uses
/// a display-link client it has already freed. It crashes in one of two ways:
/// SIGTRAP in `WebKit::DisplayLink::~DisplayLink` while destroying `m_clients`
/// (reached from `-[WKProcessPool dealloc]` when the last `WebProcessProxy`
/// goes), or SIGSEGV in `WebKit::DisplayLink::notifyObserversDisplayDidRefresh`
/// on CoreVideo's display-link thread. The shortest sequence that triggers it
/// is `test_runtimeReload_reloadsActiveTabOnly` then
/// `test_inactiveTabNavigationXToY_updatesReuseMatching` in one process.
///
/// It is specific to the test process. A standalone program running the same
/// page lifecycles (load, reload, release mid-load, bursts, windowless and
/// window-hosted, with and without NSApplication) never crashed, and the real
/// app closed browser panes, the last browser and a pane owning a browser with
/// no crash: tmp/verify-agentstudio/2026-11-07-browser-close-crash/.
///
/// What this gives up: tests don't exercise WebKit's own pool teardown, which
/// the real-app checks cover. Tests that check a page is released check our
/// side (the controller's page map and the closed, no-longer-observing tab
/// page), never WebKit's deallocation.
@MainActor
enum RetiredWebPageKeepAlive {
    private static var pages: [WebPage] = []

    static func hold(_ retired: [WebPage]) {
        pages.append(contentsOf: retired)
    }
}
