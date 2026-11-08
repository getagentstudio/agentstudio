import Foundation
import Observation
import Testing
import WebKit

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport
@testable import AgentStudioWebview

/// Records every tab page the controller asks for, so tests can count
/// creations (R28) and see the interaction state each page started with.
@Observable
@MainActor
private final class RecordingTabPageFactory: WebviewTabPageFactory {
    private(set) var createdPages: [WebviewTabPage] = []
    private(set) var interactionEnabledAtCreation: [Bool] = []
    /// Every address and title any page reported to the controller, in order.
    private(set) var reportedURLs: [URL] = []
    private(set) var reportedTitles: [String] = []

    func makeTabPage(
        contentInteractionEnabled: Bool,
        onCommittedNavigation: @escaping @MainActor (URL, String) -> Void
    ) -> WebviewTabPage {
        interactionEnabledAtCreation.append(contentInteractionEnabled)
        let page = WebKitWebviewTabPageFactory().makeTabPage(
            contentInteractionEnabled: contentInteractionEnabled,
            onCommittedNavigation: { [weak self] url, title in
                self?.reportedURLs.append(url)
                self?.reportedTitles.append(title)
                onCommittedNavigation(url, title)
            }
        )
        createdPages.append(page)
        return page
    }
}

/// Static HTML files for real local navigations, removed after the test.
private struct LocalPages {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "webview-tab-tests-\(UUIDv7.generate().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Writes a page with a `<title>`. Title waits decide on the first
    /// observation pass that shows a non-empty title, so every page a title
    /// wait reads must have one; an untitled page would leave that wait open.
    func page(_ name: String, title: String? = nil) throws -> URL {
        let url = directory.appending(path: "\(name).html")
        let documentTitle = title ?? name
        try #require(!documentTitle.isEmpty, "every title-wait fixture page has a non-empty <title>")
        try "<html><head><title>\(documentTitle)</title></head><body>\(documentTitle)</body></html>"
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A page whose own script counts the management script's `setBlocked`
    /// calls on this document. It reads -1 when the bootstrap state is missing.
    func managementCountingPage(_ name: String) throws -> URL {
        let url = directory.appending(path: "\(name).html")
        try """
        <html><head><title>\(name)</title><script>
        window.__managementCalls = 0;
        var state = window.__agentStudioManagementInteraction;
        if (state && typeof state.setBlocked === 'function') {
            var original = state.setBlocked;
            state.setBlocked = function(blocked) {
                window.__managementCalls += 1;
                window.__lastBlocked = blocked;
                return original.call(state, blocked);
            };
        } else {
            window.__managementCalls = -1;
        }
        </script></head><body>\(name)</body></html>
        """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func missing(_ name: String) -> URL {
        directory.appending(path: "\(name)-missing.html")
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

extension WebKitSerializedTests {
    @MainActor
    @Suite(.serialized)
    struct WebviewPaneControllerTabTests {
        init() {
            installTestCoreAtomsIfNeeded()
        }

        private func restoredList(count: Int, activeIndex: Int) -> WebviewTabList {
            let tabs = (0..<count).map { index in
                WebviewTab(id: .generate(), url: URL(string: "about:tab-\(index)")!, title: "Tab \(index)")
            }
            return WebviewTabList(restoring: tabs, activeTabId: tabs[activeIndex].id)!
        }

        /// What a wait for a tab page's publication saw. A failed wait names it,
        /// so a missing publication fails with its cause, not at the hang bound.
        private struct PublicationWait {
            /// Which watched page published the awaited value, nil when none did.
            let publishedIndex: Int?
            let observed: String

            var published: Bool { publishedIndex != nil }
        }

        /// The load a wait decides on. `.inFlight` is the load the stimulus in
        /// this same turn started; a page with none has nothing to wait for.
        /// `.endingAfter` is a load the test already drove, given by the page
        /// owner's observation pass from before that load.
        private enum AwaitedLoad {
            case inFlight
            case endingAfter(Int?)
        }

        /// True once the owner has recorded a pass after `baseline` with the
        /// load ended, showing the document the page has committed now.
        private static func settledOnCurrentDocument(_ tabPage: WebviewTabPage, after baseline: Int?) -> Bool {
            guard let pass = tabPage.lastObservation, pass.sequence != baseline, !pass.isLoading else { return false }
            return pass.committedPage?.url == WebviewTabPage.committedPage(of: tabPage.page)?.url
        }

        /// Waits for a tab page to publish `url`.
        private func awaitCommit(
            of url: URL, on tabPage: WebviewTabPage, load: AwaitedLoad = .inFlight
        ) async -> PublicationWait {
            await awaitFirstCommit(of: url, among: [tabPage], load: load)
        }

        /// Waits until one of `tabPages` publishes `url`, deciding only on the
        /// page owner's own facts: the published address is success; a pass
        /// after the load ended showing the page's current document, or ended
        /// observation, ends that page's chance. The owner records each pass
        /// after publishing in it, so a pass never precedes its publication.
        private func awaitFirstCommit(
            of url: URL, among tabPages: [WebviewTabPage], load: AwaitedLoad = .inFlight
        ) async -> PublicationWait {
            let target = url.standardizedFileURL
            let baselines: [Int?] = tabPages.map { tabPage in
                switch load {
                case .inFlight: tabPage.lastObservation?.sequence
                case .endingAfter(let sequence): sequence
                }
            }
            let watched: [Bool] = tabPages.map { tabPage in
                switch load {
                case .inFlight: tabPage.page.isLoading
                case .endingAfter: true
                }
            }
            func observed() -> String {
                tabPages.enumerated().map { index, tabPage in
                    let published = tabPage.lastCommittedURL?.lastPathComponent ?? "nothing"
                    let settled =
                        tabPage.lastObservation.map {
                            "pass #\($0.sequence) showing \($0.committedPage?.url.lastPathComponent ?? "nothing")"
                                + ($0.isLoading ? " while loading" : "")
                        } ?? "no pass"
                    return "page \(index): published \(published), \(settled), "
                        + "watched \(watched[index]), observing \(tabPage.isObservingCommittedPage)"
                }.joined(separator: "; ")
            }
            let states = Observations {
                tabPages.enumerated().map { index, tabPage in
                    (
                        published: tabPage.lastCommittedURL?.standardizedFileURL,
                        settled: !watched[index] || !tabPage.isObservingCommittedPage
                            || Self.settledOnCurrentDocument(tabPage, after: baselines[index])
                    )
                }
            }
            for await pageStates in states {
                if let index = pageStates.firstIndex(where: { $0.published == target }) {
                    return PublicationWait(publishedIndex: index, observed: observed())
                }
                if pageStates.allSatisfy(\.settled) { break }
            }
            return PublicationWait(
                publishedIndex: nil, observed: "no page published \(url.lastPathComponent): \(observed())")
        }

        // MARK: - R28: restored tabs create no page until selected

        @Test
        func test_restoredTabs_createPageOnlyForSelectedTabs() async throws {
            await WebviewRetirementScope.run { retirement in
                // Arrange
                let factory = RecordingTabPageFactory()
                retirement.track { factory.createdPages }
                let list = restoredList(count: 3, activeIndex: 1)
                let first = list.tabs[0].id
                let third = list.tabs[2].id

                // Act + Assert: only the active tab gets a page at restore.
                let controller = WebviewPaneController(
                    paneId: UUIDv7.generate(), tabList: list, showNavigation: true, tabPageFactory: factory
                )
                retirement.track(controller)
                #expect(factory.createdPages.count == 1)

                controller.selectTab(third)
                #expect(factory.createdPages.count == 2)

                controller.selectTab(first)
                #expect(factory.createdPages.count == 3)

                controller.selectTab(third)
                #expect(factory.createdPages.count == 3)
            }
        }

        @Test
        func test_savedState_restoresTabsLazily_andSnapshotsTheSameState() async throws {
            try await WebviewRetirementScope.run { retirement in
                // Arrange: saved state with three tabs, the second active.
                let tabs = (0..<3).map {
                    WebviewTabSnapshot(
                        id: UUIDv7.generate(), url: URL(string: "about:saved-\($0)")!, title: "Saved \($0)")
                }
                let saved = try #require(WebviewState(tabs: tabs, activeTabId: tabs[1].id, showNavigation: false))
                let factory = RecordingTabPageFactory()
                retirement.track { factory.createdPages }

                // Act
                let controller = WebviewPaneController(paneId: UUIDv7.generate(), state: saved, tabPageFactory: factory)
                retirement.track(controller)

                // Assert: same tabs, order and active tab; only the active tab has a page.
                #expect(controller.tabList.tabs.map(\.id.rawValue) == tabs.map(\.id))
                #expect(controller.activeTabId.rawValue == tabs[1].id)
                #expect(factory.createdPages.count == 1)
                #expect(controller.snapshot() == saved)
            }
        }

        // MARK: - R5: management state reaches every loaded tab

        @Test
        func test_managementToggle_reachesInactiveLoadedTab_andNewTabsStartFromIt() async throws {
            await WebviewRetirementScope.run { retirement in
                // Arrange: two loaded tabs, the first now inactive.
                let factory = RecordingTabPageFactory()
                retirement.track { factory.createdPages }
                let list = restoredList(count: 2, activeIndex: 0)
                let controller = WebviewPaneController(
                    paneId: UUIDv7.generate(), tabList: list, showNavigation: true, tabPageFactory: factory
                )
                retirement.track(controller)
                controller.selectTab(list.tabs[1].id)
                #expect(factory.createdPages.count == 2)
                let inactivePage = factory.createdPages[0]

                // Act
                controller.setWebContentInteractionEnabled(false)
                controller.openPage(URL(string: "about:new-tab")!)

                // Assert
                #expect(!inactivePage.isContentInteractionEnabled)
                #expect(!factory.createdPages[1].isContentInteractionEnabled)
                #expect(factory.interactionEnabledAtCreation.last == false)

                // Act: the inactive tab becomes active and still respects the mode.
                controller.selectTab(list.tabs[0].id)
                #expect(!controller.activeTabPage.isContentInteractionEnabled)
            }
        }

        // MARK: - Runtime commands hit the active tab

        @Test
        func test_runtimeNavigate_loadsInActiveTabOnly() async throws {
            try await WebviewRetirementScope.run { retirement in
                // Arrange
                let pages = try LocalPages()
                defer { pages.remove() }
                let target = try pages.page("runtime-target")
                let factory = RecordingTabPageFactory()
                retirement.track { factory.createdPages }
                let list = restoredList(count: 2, activeIndex: 0)
                let controller = WebviewPaneController(
                    paneId: UUIDv7.generate(), tabList: list, showNavigation: true, tabPageFactory: factory
                )
                retirement.track(controller)
                controller.selectTab(list.tabs[1].id)
                let inactivePage = factory.createdPages[0]
                let activePage = factory.createdPages[1]

                // Act
                let handled = controller.handleBrowserCommand(.navigate(url: target))

                // Assert
                #expect(handled)
                let commit = await awaitFirstCommit(of: target, among: [inactivePage, activePage])
                #expect(
                    commit.publishedIndex == 1,
                    "the runtime navigation must load in the active tab's page: \(commit.observed)")
                #expect(controller.tabList.tab(list.tabs[1].id)?.url.standardizedFileURL == target.standardizedFileURL)
                #expect(controller.tabList.tab(list.tabs[0].id)?.url.absoluteString == "about:tab-0")
            }
        }

        @Test
        func test_runtimeReload_reloadsActiveTabOnly() async throws {
            try await WebviewRetirementScope.run { retirement in
                // Arrange: two tabs on real files, B active; both files are then
                // rewritten so a reload of either would show a new title.
                let pages = try LocalPages()
                defer { pages.remove() }
                let fileA = try pages.page("a", title: "a-one")
                let fileB = try pages.page("b", title: "b-one")
                let factory = RecordingTabPageFactory()
                retirement.track { factory.createdPages }
                let controller = WebviewPaneController(
                    paneId: UUIDv7.generate(), state: WebviewState(url: fileA), tabPageFactory: factory
                )
                retirement.track(controller)
                let tabA = controller.activeTabId
                let shownA = await awaitReportedTitle("a-one", in: factory, on: factory.createdPages[0], after: 0)
                try #require(shownA.published, "\(shownA.observed)")
                let reportsBeforeB = factory.reportedTitles.count
                let openB = controller.openPage(fileB)
                let shownB = await awaitReportedTitle(
                    "b-one", in: factory, on: factory.createdPages[1], after: reportsBeforeB)
                try #require(shownB.published, "\(shownB.observed)")
                let inactivePage = factory.createdPages[0]
                let activePage = factory.createdPages[1]
                try #require(!inactivePage.page.isLoading && !activePage.page.isLoading)
                _ = try pages.page("a", title: "a-two")
                _ = try pages.page("b", title: "b-two")
                let reportsBeforeReload = factory.reportedTitles.count

                // Act: the loads a reload starts are visible in the same turn.
                let handled = controller.handleBrowserCommand(.reload(hard: false))
                let activeStartedLoading = activePage.page.isLoading
                let inactiveStartedLoading = inactivePage.page.isLoading

                // Assert: only the active tab's page loaded again. The wait runs
                // only when the active page has a navigation that can end it.
                #expect(handled)
                #expect(!inactiveStartedLoading, "the reload must not start in an inactive tab's page")
                try #require(activeStartedLoading, "the reload must start in the active tab's page")
                let activeShowedRewrite = await awaitReportedTitle(
                    "b-two", in: factory, on: activePage, after: reportsBeforeReload
                )
                #expect(activeShowedRewrite.published, "\(activeShowedRewrite.observed)")
                #expect(controller.tabList.tab(openB.tabId)?.title == "b-two")
                #expect(controller.tabList.tab(tabA)?.title == "a-one")
                #expect(inactivePage.page.title == "a-one")
                #expect(!factory.reportedTitles.dropFirst(reportsBeforeReload).contains("a-two"))
            }
        }

        // MARK: - J7: an inactive tab's navigation updates reuse and search

        @Test
        func test_inactiveTabNavigationXToY_updatesReuseMatching() async throws {
            try await WebviewRetirementScope.run { retirement in
                // Arrange: tab A shows X, then tab B is opened and active.
                let pages = try LocalPages()
                defer { pages.remove() }
                let pageX = try pages.page("x")
                let pageY = try pages.page("y")
                let pageB = try pages.page("b")
                let factory = RecordingTabPageFactory()
                retirement.track { factory.createdPages }
                let controller = WebviewPaneController(
                    paneId: UUIDv7.generate(),
                    state: WebviewState(url: pageX),
                    tabPageFactory: factory
                )
                retirement.track(controller)
                let tabA = controller.activeTabId
                let tabAPage = factory.createdPages[0]
                let commitX = await awaitCommit(of: pageX, on: tabAPage)
                #expect(commitX.published, "\(commitX.observed)")
                let openB = controller.openPage(pageB)
                #expect(controller.activeTabId == openB.tabId)

                // Act: the inactive tab navigates X -> Y through its real page.
                let passBeforeY = tabAPage.lastObservation?.sequence
                for try await _ in tabAPage.page.load(pageY) {}
                let commitY = await awaitCommit(of: pageY, on: tabAPage, load: .endingAfter(passBeforeY))
                #expect(commitY.published, "\(commitY.observed)")

                // Assert
                #expect(controller.tabList.tab(tabA)?.url.standardizedFileURL == pageY.standardizedFileURL)
                #expect(controller.openPage(pageY) == .reused(tabA))
                guard case .added = controller.openPage(pageX) else {
                    Issue.record("opening X matched the stale address of a tab now showing Y")
                    return
                }
                #expect(controller.tabList.tabs.count == 3)
            }
        }

        @Test
        func test_committedAddress_ignoresProvisionalNavigation() async throws {
            try await WebviewRetirementScope.run { retirement in
                // Arrange
                let pages = try LocalPages()
                defer { pages.remove() }
                let first = try pages.page("first")
                let tabPage = WebKitWebviewTabPageFactory().makeTabPage(
                    contentInteractionEnabled: true, onCommittedNavigation: { _, _ in }
                )
                retirement.track(tabPage)
                for try await _ in tabPage.page.load(first) {}

                // Act: a navigation starts and is still provisional.
                let provisional = tabPage.page.load(pages.missing("gone"))

                // Assert: the page's own url already names the provisional address;
                // the committed address a tab records does not.
                #expect(tabPage.page.url?.lastPathComponent == "gone-missing.html")
                #expect(
                    WebviewTabPage.committedPage(of: tabPage.page)?.url.standardizedFileURL == first.standardizedFileURL
                )
                do {
                    for try await _ in provisional {}
                } catch {
                    // The failed navigation ends the stimulus.
                }
            }
        }

        @Test
        func test_failedNavigation_keepsAddress_andLaterCommitsStillUpdateTab() async throws {
            try await WebviewRetirementScope.run { retirement in
                // Arrange
                let pages = try LocalPages()
                defer { pages.remove() }
                let first = try pages.page("first")
                let missing = pages.missing("gone")
                let later = try pages.page("later")
                let factory = RecordingTabPageFactory()
                retirement.track { factory.createdPages }
                let controller = WebviewPaneController(
                    paneId: UUIDv7.generate(),
                    state: WebviewState(url: URL(string: "about:start")!),
                    tabPageFactory: factory
                )
                retirement.track(controller)
                let tabId = controller.activeTabId
                let tabPage = factory.createdPages[0]

                // Act: a committed load, a failed load, then another committed load.
                for try await _ in tabPage.page.load(first) {}
                var missingLoadFailed = false
                do {
                    for try await _ in tabPage.page.load(missing) {}
                } catch {
                    missingLoadFailed = true
                }
                let passBeforeLater = tabPage.lastObservation?.sequence
                for try await _ in tabPage.page.load(later) {}

                // Assert: the failed address never reached the tab, and later commits still do.
                #expect(missingLoadFailed, "the missing file was expected to fail to load")
                let commitLater = await awaitCommit(
                    of: later, on: tabPage, load: .endingAfter(passBeforeLater))
                #expect(commitLater.published, "\(commitLater.observed)")
                let reported = factory.reportedURLs.map(\.standardizedFileURL)
                #expect(!reported.contains(missing.standardizedFileURL), "reported addresses: \(reported)")
                #expect(controller.tabList.tab(tabId)?.url.standardizedFileURL == later.standardizedFileURL)
            }
        }

        // MARK: - R12: a reused open shows rewritten content

        @Test
        func test_reusedOpen_reloadsRewrittenFileInSameTab() async throws {
            try await WebviewRetirementScope.run { retirement in
                // Arrange: two tabs, the report showing version one first.
                let pages = try LocalPages()
                defer { pages.remove() }
                let report = try pages.page("report", title: "version-one")
                let other = try pages.page("other")
                let factory = RecordingTabPageFactory()
                retirement.track { factory.createdPages }
                let controller = WebviewPaneController(
                    paneId: UUIDv7.generate(), state: WebviewState(url: report), tabPageFactory: factory
                )
                retirement.track(controller)
                let reportTab = controller.activeTabId
                let shownOne = await awaitReportedTitle(
                    "version-one", in: factory, on: factory.createdPages[0], after: 0)
                try #require(shownOne.published, "\(shownOne.observed)")
                try #require(!factory.createdPages[0].page.isLoading)
                let reportsBeforeOther = factory.reportedTitles.count
                controller.openPage(other)
                let shownOther = await awaitReportedTitle(
                    "other", in: factory, on: factory.createdPages[1], after: reportsBeforeOther)
                try #require(shownOther.published, "\(shownOther.observed)")
                _ = try pages.page("report", title: "version-two")
                let reportsBeforeReopen = factory.reportedTitles.count

                // Act
                let result = controller.openPage(report)

                // Assert: same tab, no new tab, and the rewritten document shows.
                #expect(result == .reused(reportTab))
                #expect(controller.tabList.tabs.count == 2)
                #expect(factory.createdPages.count == 2)
                try #require(factory.createdPages[0].page.isLoading, "a reused open must load the page again")
                let showedRewrite = await awaitReportedTitle(
                    "version-two", in: factory, on: factory.createdPages[0], after: reportsBeforeReopen
                )
                let titlesAfterReopen = Array(factory.reportedTitles.dropFirst(reportsBeforeReopen))
                #expect(
                    showedRewrite.published,
                    "titles reported after reopening: \(titlesAfterReopen); \(showedRewrite.observed)")
                #expect(controller.tabList.tab(reportTab)?.title == "version-two")
            }
        }

        /// Waits for `title` among the reports made after `index`, for the load
        /// the stimulus in this same turn started, deciding on the page owner's
        /// facts. The terminal is the first observation pass after that load
        /// ended that shows a non-empty title: the target title is success only
        /// if it was reported by then (the pass publishes before it records);
        /// any other title fails, naming it. An empty title means not yet. Ended
        /// observation fails. With no load in flight it decides at once.
        private func awaitReportedTitle(
            _ title: String, in factory: RecordingTabPageFactory, on tabPage: WebviewTabPage, after index: Int
        ) async -> PublicationWait {
            let baseline = tabPage.lastObservation?.sequence
            let watched = tabPage.page.isLoading
            func reported() -> [String] { Array(factory.reportedTitles.dropFirst(index)) }
            func observed() -> String {
                let pass =
                    tabPage.lastObservation.map {
                        "pass #\($0.sequence) showing '\($0.committedPage?.title ?? "nothing")'"
                            + ($0.isLoading ? " while loading" : "")
                    } ?? "no pass"
                return "reported \(reported()), \(pass), load in flight at the call \(watched), "
                    + "observing \(tabPage.isObservingCommittedPage)"
            }
            guard watched else {
                if reported().contains(title) { return PublicationWait(publishedIndex: 0, observed: observed()) }
                return PublicationWait(
                    publishedIndex: nil,
                    observed: "'\(title)' was not reported, and no load was in flight: \(observed())")
            }
            var loadEnded = false
            for await state in Observations({
                (pass: tabPage.lastObservation, observing: tabPage.isObservingCommittedPage)
            }) {
                if let pass = state.pass, pass.sequence != baseline, !pass.isLoading { loadEnded = true }
                if loadEnded, let shown = state.pass?.committedPage?.title, !shown.isEmpty {
                    if shown == title, reported().contains(title) {
                        return PublicationWait(publishedIndex: 0, observed: observed())
                    }
                    let cause = shown == title ? "shown but never reported" : "the load ended showing '\(shown)'"
                    return PublicationWait(publishedIndex: nil, observed: "'\(title)' \(cause): \(observed())")
                }
                if !state.observing { break }
            }
            return PublicationWait(publishedIndex: nil, observed: "'\(title)' was not reported: \(observed())")
        }

        // MARK: - The page owner records each pass after publishing in it

        @Test
        func test_observationPass_isRecordedAfterItsPublication_andTitleWaitsPass() async throws {
            try await WebviewRetirementScope.run { retirement in
                // Arrange: each publication records the owner's latest pass at that moment.
                let pages = try LocalPages()
                defer { pages.remove() }
                let first = try pages.page("first-ordered")
                let second = try pages.page("second-ordered")
                let factory = RecordingTabPageFactory()
                retirement.track { factory.createdPages }
                let recorder = PublicationOrderRecorder()
                let tabPage = factory.makeTabPage(
                    contentInteractionEnabled: true,
                    onCommittedNavigation: { url, title in recorder.recordPublication(of: url, title: title) }
                )
                recorder.tabPage = tabPage

                // Act: two loads, each awaited through the title wait. A title can
                // arrive in a pass after the load has ended; the wait still passes.
                _ = tabPage.page.load(first)
                let shownFirst = await awaitReportedTitle("first-ordered", in: factory, on: tabPage, after: 0)
                let reportsBeforeSecond = factory.reportedTitles.count
                _ = tabPage.page.load(second)
                let shownSecond = await awaitReportedTitle(
                    "second-ordered", in: factory, on: tabPage, after: reportsBeforeSecond)

                // Assert: both titles were awaited to their publication, and no
                // publication found the owner's record already showing its page.
                #expect(shownFirst.published, "\(shownFirst.observed)")
                #expect(shownSecond.published, "\(shownSecond.observed)")
                #expect(recorder.publications.count >= 2)
                #expect(
                    recorder.publications.allSatisfy { $0.recordedBefore != $0.page },
                    "publications: \(recorder.publications)")
            }
        }

        // MARK: - A mode change during a load reapplies once the load ends

        @Test
        func test_interactionModeChangeDuringLoad_reappliesOnceWhenLoadingEnds() async throws {
            try await WebviewRetirementScope.run { retirement in
                // Arrange: a page that counts the management script's calls on its document.
                let pages = try LocalPages()
                defer { pages.remove() }
                let counted = try pages.managementCountingPage("counted")
                let tabPage = WebKitWebviewTabPageFactory().makeTabPage(
                    contentInteractionEnabled: true, onCommittedNavigation: { _, _ in }
                )
                retirement.track(tabPage)

                // Act: the mode changes while the load is in progress.
                let navigation = tabPage.page.load(counted)
                try #require(tabPage.page.isLoading, "the load must still be in progress")
                tabPage.setContentInteractionEnabled(false)
                let apply = try #require(tabPage.interactionApplyTask)
                // Ends when the load finishes, or throws when it fails.
                for try await _ in navigation {}
                // Ends when the reapply runs, or when a newer apply or close cancels it.
                await apply.value

                // Assert: the loaded document got exactly one apply, blocking.
                let calls = try await tabPage.page.callJavaScript("return window.__managementCalls") as? NSNumber
                let blocked = try await tabPage.page.callJavaScript("return window.__lastBlocked") as? Bool
                #expect(calls?.intValue == 1, "the loaded document must be reapplied once")
                #expect(blocked == true)
            }
        }

        // MARK: - Retirement releases every loaded tab's work

        @Test
        func test_paneHostRetire_endsEveryLoadedTabPagesObservation() async throws {
            try await WebviewRetirementScope.run { retirement in
                // Arrange: a mounted browser pane with three loaded tabs.
                let view = WebviewPaneMountView(
                    paneId: UUIDv7.generate(), state: WebviewState(url: URL(string: "about:tab-a")!)
                )
                retirement.track(view.controller)
                var loadedPages = [view.controller.activeTabPage]
                view.controller.openPage(URL(string: "about:tab-b")!)
                loadedPages.append(view.controller.activeTabPage)
                view.controller.openPage(URL(string: "about:tab-c")!)
                loadedPages.append(view.controller.activeTabPage)
                #expect(view.controller.loadedTabCount == 3)
                let host = PaneHostView(paneId: view.paneId)
                host.mountContentView(view)

                // Act: the host retires the pane, as teardown does.
                host.retire()

                // Assert: every loaded tab, active or not, was closed, and its
                // observation (the task that holds its page) has ended.
                let closedPageCount = loadedPages.filter { $0.isClosed }.count
                try #require(closedPageCount == loadedPages.count, "retire must close every loaded tab page")
                for tabPage in loadedPages {
                    for await isObserving in Observations({ tabPage.isObservingCommittedPage }) where !isObserving {
                        break
                    }
                    #expect(!tabPage.isObservingCommittedPage)
                }
            }
        }

        // MARK: - R6: the picker opens through the browser runtime command

        @Test
        func test_showTabsRuntimeCommand_presentsTabPicker() async throws {
            await WebviewRetirementScope.run { retirement in
                // Arrange
                let controller = WebviewPaneController(
                    paneId: UUIDv7.generate(),
                    state: WebviewState(url: URL(string: "about:start")!),
                    tabPageFactory: RecordingTabPageFactory()
                )
                retirement.track(controller)
                #expect(!controller.isTabPickerPresented)

                // Act
                let handled = controller.handleBrowserCommand(.showTabs)

                // Assert
                #expect(handled)
                #expect(controller.isTabPickerPresented)
            }
        }

        // MARK: - R10: closing the last tab closes the pane

        @Test
        func test_closeLastTab_requestsPaneClose_otherwiseReleasesPage() async throws {
            await WebviewRetirementScope.run { retirement in
                // Arrange
                let factory = RecordingTabPageFactory()
                retirement.track { factory.createdPages }
                let list = restoredList(count: 2, activeIndex: 0)
                let controller = WebviewPaneController(
                    paneId: UUIDv7.generate(), tabList: list, showNavigation: true, tabPageFactory: factory
                )
                retirement.track(controller)
                var paneCloseRequests = 0
                controller.onLastTabClosed = { paneCloseRequests += 1 }

                // Act
                controller.closeTab(list.tabs[0].id)

                // Assert: the closed tab's page is released.
                #expect(paneCloseRequests == 0)
                #expect(controller.loadedTabCount == 1)
                #expect(controller.activeTabId == list.tabs[1].id)

                // Act
                controller.closeTab(list.tabs[1].id)

                // Assert
                #expect(paneCloseRequests == 1)
            }
        }

        // MARK: - R29: tab switch timing

        @Test
        func test_tabSwitch_recordsOneTimingWhenSelectedTabViewCommits() async throws {
            await WebviewRetirementScope.run { retirement in
                // Arrange
                let recorded = RecordedInteractions()
                let probe = AgentStudioInteractionPerformanceProbe(
                    nowNanoseconds: { 0 },
                    recordDuration: { kind, _ in recorded.append(kind) }
                )
                let list = restoredList(count: 2, activeIndex: 0)
                let controller = WebviewPaneController(
                    paneId: UUIDv7.generate(), tabList: list, showNavigation: true,
                    tabPageFactory: RecordingTabPageFactory(), tabSwitchProbe: probe
                )
                retirement.track(controller)

                // Act: a commit for a tab that wasn't selected settles nothing.
                controller.selectTab(list.tabs[1].id)
                controller.tabViewCommitted(list.tabs[0].id)
                #expect(recorded.kinds.isEmpty)

                controller.tabViewCommitted(list.tabs[1].id)
                controller.tabViewCommitted(list.tabs[1].id)

                // Assert
                #expect(recorded.kinds == [.browserTabSwitch])
            }
        }
    }
}

/// Each publication a tab page made, with the page the owner's latest
/// recorded pass showed at that moment.
@MainActor
private final class PublicationOrderRecorder {
    weak var tabPage: WebviewTabPage?
    private(set) var publications: [(page: WebviewCommittedPage, recordedBefore: WebviewCommittedPage?)] = []

    func recordPublication(of url: URL, title: String) {
        publications.append((WebviewCommittedPage(url: url, title: title), tabPage?.lastObservation?.committedPage))
    }
}

private final class RecordedInteractions: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AgentStudioInteractionKind] = []

    var kinds: [AgentStudioInteractionKind] { lock.withLock { storage } }

    func append(_ kind: AgentStudioInteractionKind) {
        lock.withLock { storage.append(kind) }
    }
}
