import AgentStudioCore
import AgentStudioTestSupport
import Foundation
import Observation
import Testing

@testable import AgentStudioRepoExplorer

private final class RepoExplorerObservationInvalidationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedInvalidationCount = 0

    var invalidationCount: Int {
        lock.withLock { storedInvalidationCount }
    }

    func recordInvalidation() {
        lock.withLock {
            storedInvalidationCount += 1
        }
    }
}

@MainActor
@Suite("RepoExplorerView injection")
struct RepoExplorerViewInjectionTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("initializer preserves the exact injected Repo Explorer preferences")
    func initializerPreservesExactInjectedPreferences() {
        // Arrange
        let preferences = RepoExplorerSidebarPrefsAtom()

        // Act
        let view = makeRepoExplorerView(repoExplorerPrefs: preferences)

        // Assert
        #expect(view.repoExplorerPrefs === preferences)
    }

    @Test("named preference mutation invalidates the injected view model reference")
    func namedPreferenceMutationInvalidatesInjectedViewModelReference() {
        // Arrange
        let preferences = RepoExplorerSidebarPrefsAtom()
        let view = makeRepoExplorerView(repoExplorerPrefs: preferences)
        let invalidationRecorder = RepoExplorerObservationInvalidationRecorder()
        withObservationTracking {
            _ = view.repoExplorerPrefs.groupingMode(for: .repos)
        } onChange: {
            invalidationRecorder.recordInvalidation()
        }

        // Act
        preferences.setGroupingMode(.activity, for: .repos)

        // Assert
        #expect(invalidationRecorder.invalidationCount == 1)
        #expect(view.repoExplorerPrefs.groupingMode(for: .repos) == .activity)
    }

    @Test("drawer and pin tooltips share the list keyboard hint gate")
    func drawerAndPinTooltipHintGating() {
        for command in [AppCommand.togglePanesShowsDrawers, .togglePanesShowsPinned] {
            let hidden = RepoExplorerSidebarShortcutPresentation.display(
                for: command,
                showsListKeyboardHints: false
            )
            let active = RepoExplorerSidebarShortcutPresentation.display(
                for: command,
                showsListKeyboardHints: true
            )
            #expect(hidden == nil)
            #expect(
                command.definition.controlTooltipRenderValue(shortcutTextOverride: hidden)
                    .shortcutDisplayText == nil
            )
            #expect(active == command.definition.shortcut?.spec.displayTrigger(in: .sidebarList)?.displayText)
            #expect(
                command.definition.controlTooltipRenderValue(shortcutTextOverride: active)
                    .shortcutDisplayText == active
            )
            if command == .togglePanesShowsDrawers {
                #expect(active != nil)
            }
        }
    }

    private func makeRepoExplorerView(
        store: WorkspaceStore = WorkspaceStore(startsObserving: false),
        repoExplorerPrefs: RepoExplorerSidebarPrefsAtom,
        bridgeAttendanceSnapshot: @escaping BridgeAttendanceSnapshot = { _ in nil },
    ) -> RepoExplorerView {
        RepoExplorerView(
            store: store,
            octiconLoader: makeRepoExplorerTestOcticonLoader(),
            repoExplorerPrefs: repoExplorerPrefs,
            bridgeAttendanceSnapshot: bridgeAttendanceSnapshot,
            commandDispatcher: FakeRepoExplorerAppCommandDispatcher(),
            onRefocusActivePane: {},
            onSidebarVisibleWorktreesChanged: {},
        )
    }
}

@MainActor
final class FakeRepoExplorerAppCommandDispatcher: AppCommandDispatching {
    func dispatchKeyboardShortcut(_: AppShortcut) {}
    func dispatchExtractPaneToTab(tabId _: UUID, paneId _: UUID, targetTabInsertionIndex _: Int?) {}

    func dispatch(_: AppCommand) -> Bool { false }
    func dispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) {}
    func canDispatch(_: AppCommand) -> Bool { true }
    func canDispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool { true }
    func bridgePaneCommandTarget(worktreeId _: UUID) -> BridgePaneCommandTarget? { nil }
    func dispatchMovePaneToTab(sourcePaneId _: UUID, sourceTabId _: UUID?, targetTabId _: UUID) {}
}
