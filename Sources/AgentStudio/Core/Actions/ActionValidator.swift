// swiftlint:disable cyclomatic_complexity function_body_length
import AgentStudioInfrastructure
import Foundation

/// Wrapper that proves an action has passed validation.
/// Only WorkspaceCommandValidator can create instances (fileprivate init).
package struct ValidatedAction: Equatable {
    package let action: WorkspaceActionCommand

    fileprivate init(_ action: WorkspaceActionCommand) {
        self.action = action
    }
}

/// Validation errors for rejected actions.
package enum ActionValidationError: Error, Equatable {
    case repoNotFound(repoId: UUID)
    case tabNotFound(tabId: UUID)
    case emptyName
    case paneNotFound(paneId: UUID, tabId: UUID)
    case paneTargetNotFound(paneId: UUID)
    case worktreeNotFound(worktreeId: UUID)
    case tabNotSplit(tabId: UUID)
    case singlePaneTab(tabId: UUID)
    case selfPaneInsertion(paneId: UUID)
    case selfTabMerge(sourceTabId: UUID)
    case sourcePaneNotFound(paneId: UUID, sourceTabId: UUID)
    case invalidRatio(ratio: Double)
    case paneAlreadyInLayout(paneId: UUID)
    case invalidDrawerLayout(parentPaneId: UUID, reason: DrawerLayoutValidationFailure)
    case drawerPaneCannotCrossTabs(paneId: UUID)
    case crossTabSameTab(tabId: UUID)
    case crossTabDestNotFound(tabId: UUID)
    case crossTabTargetNotFound(paneId: UUID, tabId: UUID)
    case tabReorderIndexOutOfRange(index: Int)
    case crossTabInsertPaneRequest(paneId: UUID, sourceTabId: UUID, targetTabId: UUID)
    case arrangementNotFound(tabId: UUID, arrangementId: UUID)
    case defaultArrangementCannotBeRemoved(tabId: UUID, arrangementId: UUID)
    case defaultArrangementCannotBeRenamed(tabId: UUID, arrangementId: UUID)
    case invalidVisiblePanePair(tabId: UUID, leftPaneId: UUID, rightPaneId: UUID)
    case zoomActive(tabId: UUID)
    case drawerChildContentRejected(parentPaneId: UUID, content: DrawerChildContentKind)
    case drawerOwnerNotZoomSource(parentPaneId: UUID)
    /// A pane agent's target is no longer inside its own pane, or the action is
    /// not one an agent may apply.
    case outsideOwnPane(paneId: UUID)
}

package enum DrawerLayoutValidationFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case missingLayout
    case insertionTargetRejected(UUID)
    case resultingLayoutWouldCreateThirdRow
    case projectedMove(DrawerProjectedMoveFailure)

    package var description: String {
        switch self {
        case .missingLayout:
            return "missingLayout"
        case .insertionTargetRejected(let targetPaneId):
            return "insertionTargetRejected(\(targetPaneId))"
        case .resultingLayoutWouldCreateThirdRow:
            return "resultingLayoutWouldCreateThirdRow"
        case .projectedMove(let failure):
            return "projectedMove(\(failure))"
        }
    }
}

/// Pure-function validation engine.
/// Takes a resolved action and a state snapshot, returns validated or error.
/// No side effects, no UI dependencies, no NSViews.
package enum WorkspaceCommandValidator {

    /// Validates an action a pane agent requested. The own-pane re-check runs
    /// against the same fresh snapshot as ordinary validation, after every
    /// queued predecessor and before any durable work.
    package static func validate(
        _ action: WorkspaceActionCommand,
        ownPaneAssertion: WorkspaceOwnPaneAssertion?,
        state: ActionStateSnapshot
    ) -> Result<ValidatedAction, ActionValidationError> {
        if let ownPaneAssertion {
            guard let touchedPaneIds = agentTouchedPaneIds(of: action) else {
                return .failure(.outsideOwnPane(paneId: ownPaneAssertion.boundPaneId))
            }
            if let outside = touchedPaneIds.first(where: { !ownPaneAssertion.admits($0, state: state) }) {
                return .failure(.outsideOwnPane(paneId: outside))
            }
            // Authorization already refuses an agent closing its own pane; the
            // effect owner holds the same line.
            if closedPaneId(of: action) == ownPaneAssertion.boundPaneId {
                return .failure(.outsideOwnPane(paneId: ownPaneAssertion.boundPaneId))
            }
        }
        return validate(action, state: state)
    }

    private static func closedPaneId(of action: WorkspaceActionCommand) -> UUID? {
        switch action {
        case .closePane(_, let paneId), .removeDrawerPane(_, let paneId):
            paneId
        default:
            nil
        }
    }

    /// The panes an agent-originated action touches, or `nil` for an action no
    /// agent may apply.
    private static func agentTouchedPaneIds(of action: WorkspaceActionCommand) -> [UUID]? {
        switch action {
        case .closePane(_, let paneId):
            [paneId]
        case .removeDrawerPane(let parentPaneId, let drawerPaneId):
            [parentPaneId, drawerPaneId]
        case .addDrawerChildInBackground(let parentPaneId, _, _):
            [parentPaneId]
        default:
            nil
        }
    }

    package static func validate(
        _ action: WorkspaceActionCommand,
        state: ActionStateSnapshot
    ) -> Result<ValidatedAction, ActionValidationError> {
        if let zoomActiveError = validateZoomActiveMutation(action, state: state) {
            return .failure(zoomActiveError)
        }

        switch action {
        case .selectTab(let tabId):
            guard state.tab(tabId) != nil else {
                return .failure(.tabNotFound(tabId: tabId))
            }
            return .success(ValidatedAction(action))

        case .closeTab(let tabId):
            guard state.tab(tabId) != nil else {
                return .failure(.tabNotFound(tabId: tabId))
            }
            return .success(ValidatedAction(action))

        case .breakUpTab(let tabId):
            guard let tab = state.tab(tabId) else {
                return .failure(.tabNotFound(tabId: tabId))
            }
            guard tab.isSplit else {
                return .failure(.tabNotSplit(tabId: tabId))
            }
            return .success(ValidatedAction(action))

        case .renameTab(let tabId, let name):
            guard state.tab(tabId) != nil else {
                return .failure(.tabNotFound(tabId: tabId))
            }
            let trimmedName = Tab.normalizedName(name)
            guard !trimmedName.isEmpty else {
                return .failure(.emptyName)
            }
            return .success(ValidatedAction(.renameTab(tabId: tabId, name: trimmedName)))

        case .closePane(let tabId, let paneId):
            guard state.tab(tabId) != nil else {
                return .failure(.tabNotFound(tabId: tabId))
            }
            guard state.tabOwnsPane(tabId, paneId: paneId) else {
                return .failure(.paneNotFound(paneId: paneId, tabId: tabId))
            }
            return .success(ValidatedAction(action))

        case .extractPaneToTab(let tabId, let paneId):
            guard let tab = state.tab(tabId) else {
                return .failure(.tabNotFound(tabId: tabId))
            }
            guard tab.showsPane(paneId) else {
                return .failure(.paneNotFound(paneId: paneId, tabId: tabId))
            }
            guard tab.visiblePaneCount > 1 else {
                return .failure(.singlePaneTab(tabId: tabId))
            }
            return .success(ValidatedAction(action))

        case .insertPaneRequest(let request):
            guard state.tab(request.targetTabId) != nil else {
                return .failure(.tabNotFound(tabId: request.targetTabId))
            }
            guard state.tabShowsPane(request.targetTabId, paneId: request.targetPaneId) else {
                return .failure(.paneNotFound(paneId: request.targetPaneId, tabId: request.targetTabId))
            }
            if case .existingPane(let sourcePaneId, let sourceTabId) = request.source {
                guard sourceTabId == request.targetTabId else {
                    return .failure(
                        .crossTabInsertPaneRequest(
                            paneId: sourcePaneId,
                            sourceTabId: sourceTabId,
                            targetTabId: request.targetTabId
                        )
                    )
                }
                guard state.tabOwnsPane(sourceTabId, paneId: sourcePaneId) else {
                    return .failure(
                        .sourcePaneNotFound(
                            paneId: sourcePaneId, sourceTabId: sourceTabId))
                }
                // Self-insertion check: can't drop a pane onto itself
                guard sourcePaneId != request.targetPaneId else {
                    return .failure(.selfPaneInsertion(paneId: sourcePaneId))
                }
            }
            return .success(ValidatedAction(action))

        case .resizePane(let tabId, _, let ratio):
            guard let tab = state.tab(tabId) else {
                return .failure(.tabNotFound(tabId: tabId))
            }
            guard tab.isSplit else {
                return .failure(.tabNotSplit(tabId: tabId))
            }
            guard ratio >= 0.1 && ratio <= 0.9 else {
                return .failure(.invalidRatio(ratio: ratio))
            }
            return .success(ValidatedAction(action))

        case .resizeVisiblePanePair(let tabId, let leftPaneId, let rightPaneId, let ratio):
            guard let tab = state.tab(tabId) else {
                return .failure(.tabNotFound(tabId: tabId))
            }
            guard tab.isSplit else {
                return .failure(.tabNotSplit(tabId: tabId))
            }
            guard ratio >= 0.1 && ratio <= 0.9 else {
                return .failure(.invalidRatio(ratio: ratio))
            }
            guard tab.ownsPane(leftPaneId) else {
                return .failure(.paneNotFound(paneId: leftPaneId, tabId: tabId))
            }
            guard tab.ownsPane(rightPaneId) else {
                return .failure(.paneNotFound(paneId: rightPaneId, tabId: tabId))
            }
            guard
                PaneResizeVisibilityResolver.validatesRenderedPanePair(
                    layoutPaneIds: tab.layoutPaneIds,
                    resizeExcludedPaneIds: tab.minimizedPaneIds.union(
                        Set(tab.layoutPaneIds).subtracting(tab.visiblePaneIds)
                    ),
                    leftPaneId: leftPaneId,
                    rightPaneId: rightPaneId
                )
            else {
                return .failure(
                    .invalidVisiblePanePair(tabId: tabId, leftPaneId: leftPaneId, rightPaneId: rightPaneId)
                )
            }
            return .success(ValidatedAction(action))

        case .equalizePanes(let tabId):
            guard let tab = state.tab(tabId) else {
                return .failure(.tabNotFound(tabId: tabId))
            }
            guard tab.isSplit else {
                return .failure(.tabNotSplit(tabId: tabId))
            }
            return .success(ValidatedAction(action))

        case .mergeTab(let sourceTabId, let targetTabId, let targetPaneId, _):
            guard state.tab(sourceTabId) != nil else {
                return .failure(.tabNotFound(tabId: sourceTabId))
            }
            guard state.tab(targetTabId) != nil else {
                return .failure(.tabNotFound(tabId: targetTabId))
            }
            guard state.tabShowsPane(targetTabId, paneId: targetPaneId) else {
                return .failure(.paneNotFound(paneId: targetPaneId, tabId: targetTabId))
            }
            guard sourceTabId != targetTabId else {
                return .failure(.selfTabMerge(sourceTabId: sourceTabId))
            }
            return .success(ValidatedAction(action))

        case .removeRepo(let repoId), .setRepoPinned(let repoId, _):
            guard state.knownRepoIds.contains(repoId) else {
                return .failure(.repoNotFound(repoId: repoId))
            }
            return .success(ValidatedAction(action))

        case .setPanePinned(let paneId, _):
            guard state.knownPaneIds.contains(paneId) else {
                return .failure(.paneTargetNotFound(paneId: paneId))
            }
            return .success(ValidatedAction(action))

        case .openWorktree(let worktreeId),
            .openNewTerminalInTab(let worktreeId, _, _),
            .openWorktreeInPane(let worktreeId):
            guard state.knownWorktreeIds.contains(worktreeId) else {
                return .failure(.worktreeNotFound(worktreeId: worktreeId))
            }
            return .success(ValidatedAction(action))

        case .openFloatingTerminal:
            return .success(ValidatedAction(action))

        case .resizePaneByDelta(let tabId, let paneId, _, _),
            .minimizePane(let tabId, let paneId):
            if let error = validateTabShowsPane(tabId: tabId, paneId: paneId, state: state) {
                return .failure(error)
            }
            return .success(ValidatedAction(action))

        case .expandPane(let tabId, let paneId):
            guard let tab = state.tab(tabId) else {
                return .failure(.tabNotFound(tabId: tabId))
            }
            guard tab.laysOutPane(paneId) else {
                return .failure(.paneNotFound(paneId: paneId, tabId: tabId))
            }
            return .success(ValidatedAction(action))

        case .moveTab(let tabId, _):
            guard state.tab(tabId) != nil else {
                return .failure(.tabNotFound(tabId: tabId))
            }
            return .success(ValidatedAction(action))

        case .reorderTab(let tabId, let insertionIndex):
            guard state.tab(tabId) != nil else {
                return .failure(.tabNotFound(tabId: tabId))
            }
            guard insertionIndex >= 0 && insertionIndex <= state.tabCount else {
                return .failure(.tabReorderIndexOutOfRange(index: insertionIndex))
            }
            return .success(ValidatedAction(action))

        case .movePaneAcrossTabs(let request):
            let paneId = request.paneId
            let sourceTabId = request.sourceTabId
            let destTabId = request.destTabId
            let targetPaneId = request.targetPaneId
            guard sourceTabId != destTabId else {
                return .failure(.crossTabSameTab(tabId: sourceTabId))
            }
            guard state.drawerParentPaneId(of: paneId) == nil else {
                return .failure(.drawerPaneCannotCrossTabs(paneId: paneId))
            }
            guard state.tab(destTabId) != nil else {
                return .failure(.crossTabDestNotFound(tabId: destTabId))
            }
            guard state.tabOwnsPane(sourceTabId, paneId: paneId) else {
                return .failure(.sourcePaneNotFound(paneId: paneId, sourceTabId: sourceTabId))
            }
            guard state.tab(destTabId)?.ownsPane(targetPaneId) == true else {
                return .failure(.crossTabTargetNotFound(paneId: targetPaneId, tabId: destTabId))
            }
            return .success(ValidatedAction(action))

        case .createArrangement(let tabId, let name):
            guard let tab = state.tab(tabId) else {
                return .failure(.tabNotFound(tabId: tabId))
            }
            if let staleActiveError = validateActiveArrangementState(tabId: tabId, tab: tab) {
                return .failure(staleActiveError)
            }
            let normalizedName = Tab.normalizedName(name)
            guard !normalizedName.isEmpty else {
                return .failure(.emptyName)
            }
            return .success(ValidatedAction(.createArrangement(tabId: tabId, name: normalizedName)))

        case .removeArrangement(let tabId, let arrangementId):
            guard let tab = state.tab(tabId) else {
                return .failure(.tabNotFound(tabId: tabId))
            }
            if let staleActiveError = validateActiveArrangementState(tabId: tabId, tab: tab) {
                return .failure(staleActiveError)
            }
            guard let arrangement = tab.arrangement(arrangementId) else {
                return .failure(.arrangementNotFound(tabId: tabId, arrangementId: arrangementId))
            }
            guard !arrangement.isDefault else {
                return .failure(.defaultArrangementCannotBeRemoved(tabId: tabId, arrangementId: arrangementId))
            }
            return .success(ValidatedAction(action))

        case .switchArrangement(let tabId, let arrangementId):
            guard let tab = state.tab(tabId) else {
                return .failure(.tabNotFound(tabId: tabId))
            }
            // Switching arrangements is also the repair path for a stale active arrangement.
            // Validate only the requested target here; the other arrangement commands fail
            // closed when the active arrangement is stale.
            guard tab.arrangement(arrangementId) != nil else {
                return .failure(.arrangementNotFound(tabId: tabId, arrangementId: arrangementId))
            }
            return .success(ValidatedAction(action))

        case .renameArrangement(let tabId, let arrangementId, let name):
            guard let tab = state.tab(tabId) else {
                return .failure(.tabNotFound(tabId: tabId))
            }
            if let staleActiveError = validateActiveArrangementState(tabId: tabId, tab: tab) {
                return .failure(staleActiveError)
            }
            let normalizedName = Tab.normalizedName(name)
            guard !normalizedName.isEmpty else {
                return .failure(.emptyName)
            }
            guard let arrangement = tab.arrangement(arrangementId) else {
                return .failure(.arrangementNotFound(tabId: tabId, arrangementId: arrangementId))
            }
            guard !arrangement.isDefault else {
                return .failure(.defaultArrangementCannotBeRenamed(tabId: tabId, arrangementId: arrangementId))
            }
            return .success(
                ValidatedAction(.renameArrangement(tabId: tabId, arrangementId: arrangementId, name: normalizedName)))

        // Orphaned pane pool — store-level
        case .backgroundPane, .purgeOrphanedPane:
            return .success(ValidatedAction(action))

        case .reactivatePane(_, let targetTabId, let targetPaneId, _):
            guard state.tab(targetTabId) != nil else {
                return .failure(.tabNotFound(tabId: targetTabId))
            }
            guard state.tabShowsPane(targetTabId, paneId: targetPaneId) else {
                return .failure(.paneNotFound(paneId: targetPaneId, tabId: targetTabId))
            }
            return .success(ValidatedAction(action))

        // Drawer actions — validate parent pane is in an active tab layout.
        // Store-level guards provide additional safety for panes in non-active arrangements.
        case .enterDrawer(let parentPaneId):
            guard state.tabShowing(paneId: parentPaneId) != nil else {
                return .failure(.paneNotFound(paneId: parentPaneId, tabId: state.activeTabId ?? UUID()))
            }
            return .success(ValidatedAction(action))

        case .focusDrawerPaneUp(let parentPaneId, let drawerPaneId),
            .focusDrawerPaneLeft(let parentPaneId, let drawerPaneId),
            .focusDrawerPaneDown(let parentPaneId, let drawerPaneId),
            .focusDrawerPaneRight(let parentPaneId, let drawerPaneId):
            if let error = DrawerCommandValidator.validateMembership(
                parentPaneId: parentPaneId,
                drawerPaneId: drawerPaneId,
                state: state
            ) {
                return .failure(error)
            }
            return .success(ValidatedAction(action))

        case .detachDrawerPane(let parentPaneId, let drawerPaneId):
            if let error = DrawerCommandValidator.validateMembership(
                parentPaneId: parentPaneId,
                drawerPaneId: drawerPaneId,
                state: state
            ) {
                return .failure(error)
            }
            guard state.tabShowing(paneId: parentPaneId) != nil else {
                return .failure(.paneNotFound(paneId: parentPaneId, tabId: state.activeTabId ?? UUID()))
            }
            return .success(ValidatedAction(action))

        case .addDrawerPane(let parentPaneId),
            .addWebviewDrawerPane(let parentPaneId, _):
            if let contentError = validateDrawerChildContent(of: action, parentPaneId: parentPaneId) {
                return .failure(contentError)
            }
            guard state.tabShowing(paneId: parentPaneId) != nil else {
                return .failure(.paneNotFound(paneId: parentPaneId, tabId: state.activeTabId ?? UUID()))
            }
            return .success(ValidatedAction(action))
        case .addDrawerChildInBackground(let parentPaneId, let childPaneId, _):
            guard state.tabOwning(paneId: parentPaneId) != nil, state.drawerParentPaneId(of: parentPaneId) == nil
            else {
                return .failure(.paneNotFound(paneId: parentPaneId, tabId: state.activeTabId ?? UUIDv7.generate()))
            }
            guard !state.knownPaneIds.contains(childPaneId) else {
                return .failure(.paneAlreadyInLayout(paneId: childPaneId))
            }
            return .success(ValidatedAction(action))
        case .removeDrawerPane(let parentPaneId, let drawerPaneId):
            guard state.tabOwning(paneId: parentPaneId) != nil else {
                return .failure(.paneNotFound(paneId: parentPaneId, tabId: state.activeTabId ?? UUID()))
            }
            // The named child must belong to the named parent; otherwise the
            // discard would silently do nothing and still report applied.
            guard state.drawerParentPaneId(of: drawerPaneId) == parentPaneId else {
                return .failure(.paneNotFound(paneId: drawerPaneId, tabId: state.activeTabId ?? UUIDv7.generate()))
            }
            return .success(ValidatedAction(action))
        case .toggleDrawer(let parentPaneId):
            guard state.tabShowing(paneId: parentPaneId) != nil else {
                return .failure(.paneNotFound(paneId: parentPaneId, tabId: state.activeTabId ?? UUID()))
            }
            return .success(ValidatedAction(action))
        case .setActiveDrawerPane(let parentPaneId, _),
            .resizeDrawerPane(let parentPaneId, _, _),
            .resizeDrawerVisiblePanePair(let parentPaneId, _, _, _),
            .equalizeDrawerPanes(let parentPaneId),
            .minimizeDrawerPane(let parentPaneId, _),
            .expandDrawerPane(let parentPaneId, _):
            guard state.tabShowing(paneId: parentPaneId) != nil else {
                return .failure(.paneNotFound(paneId: parentPaneId, tabId: state.activeTabId ?? UUID()))
            }
            return .success(ValidatedAction(action))

        case .setZoomSplitRatio(let tabId, let ratio):
            guard state.tab(tabId) != nil else {
                return .failure(.tabNotFound(tabId: tabId))
            }
            guard
                state.zoomSourcePaneIdByTabId[tabId] != nil,
                AppPolicies.PaneZoomSplit.containsTerminalRatio(ratio)
            else {
                return .failure(.invalidRatio(ratio: ratio))
            }
            return .success(ValidatedAction(action))

        case .setDrawerNormalHeightRatio(let parentPaneId, let ratio):
            guard state.tabOwning(paneId: parentPaneId) != nil,
                state.drawerParentByPaneId[parentPaneId] == nil
            else {
                return .failure(.paneNotFound(paneId: parentPaneId, tabId: state.activeTabId ?? UUID()))
            }
            guard DrawerPresentationPreference.validatedNormalHeightRatio(ratio) != nil else {
                return .failure(.invalidRatio(ratio: ratio))
            }
            return .success(ValidatedAction(action))

        case .setDrawerZoomSide(let parentPaneId, _):
            guard state.tabOwning(paneId: parentPaneId) != nil else {
                return .failure(.paneNotFound(paneId: parentPaneId, tabId: state.activeTabId ?? UUID()))
            }
            guard state.zoomSourcePaneIdByTabId.values.contains(parentPaneId) else {
                return .failure(.drawerOwnerNotZoomSource(parentPaneId: parentPaneId))
            }
            return .success(ValidatedAction(action))

        case .insertDrawerPane(let parentPaneId, let targetDrawerPaneId, let direction, let sizingMode):
            if let contentError = validateDrawerChildContent(of: action, parentPaneId: parentPaneId) {
                return .failure(contentError)
            }
            return DrawerCommandValidator.validateInsertion(
                parentPaneId: parentPaneId,
                targetDrawerPaneId: targetDrawerPaneId,
                direction: direction,
                sizingMode: sizingMode,
                state: state
            ).map { ValidatedAction(action) }

        case .moveDrawerPane(let parentPaneId, let drawerPaneId, let target, let sizingMode):
            return DrawerCommandValidator.validateMove(
                parentPaneId: parentPaneId,
                drawerPaneId: drawerPaneId,
                target: target,
                sizingMode: sizingMode,
                state: state
            ).map { ValidatedAction(action) }

        // System actions — trusted source, skip validation
        case .expireUndoEntry, .repair:
            return .success(ValidatedAction(action))
        }
    }

    /// Content family each drawer-child creation action produces. Admission
    /// checks it against `DrawerChildContentPolicy` before any pane exists.
    static func createdDrawerChildContent(of action: WorkspaceActionCommand) -> DrawerChildContentKind? {
        switch action {
        case .addDrawerPane, .insertDrawerPane:
            return .terminal
        case .addWebviewDrawerPane:
            return .browser
        default:
            return nil
        }
    }

    private static func validateDrawerChildContent(
        of action: WorkspaceActionCommand,
        parentPaneId: UUID
    ) -> ActionValidationError? {
        guard let content = createdDrawerChildContent(of: action),
            !DrawerChildContentPolicy.admits(content)
        else { return nil }
        return .drawerChildContentRejected(parentPaneId: parentPaneId, content: content)
    }

    private static func validateZoomActiveMutation(
        _ action: WorkspaceActionCommand,
        state: ActionStateSnapshot
    ) -> ActionValidationError? {
        let targetTabId: UUID?
        switch action {
        case .insertPaneRequest(let request):
            switch request.source {
            case .newTerminal, .newTerminalAtDirectory, .newWebview:
                targetTabId = request.targetTabId
            case .existingPane:
                return nil
            }
        case .minimizePane(let tabId, _),
            .expandPane(let tabId, _):
            targetTabId = tabId
        default:
            return nil
        }

        guard let targetTabId,
            state.tab(targetTabId) != nil,
            state.zoomSourcePaneIdByTabId[targetTabId] != nil
        else {
            return nil
        }
        return .zoomActive(tabId: targetTabId)
    }

    /// Check that a tab exists and currently presents the given pane.
    private static func validateTabShowsPane(
        tabId: UUID, paneId: UUID, state: ActionStateSnapshot
    ) -> ActionValidationError? {
        guard let tab = state.tab(tabId) else {
            return .tabNotFound(tabId: tabId)
        }
        guard tab.showsPane(paneId) else {
            return .paneNotFound(paneId: paneId, tabId: tabId)
        }
        return nil
    }

    /// Fail closed when a tab snapshot reports a stale active arrangement.
    /// Empty arrangement snapshots mean the caller has no arrangement context
    /// available, which is allowed for legacy/pure validation fixtures.
    private static func validateActiveArrangementState(tabId: UUID, tab: TabSnapshot) -> ActionValidationError? {
        guard let activeArrangementId = tab.activeArrangementId,
            !tab.arrangements.isEmpty,
            tab.arrangement(activeArrangementId) == nil
        else {
            return nil
        }

        return .arrangementNotFound(tabId: tabId, arrangementId: activeArrangementId)
    }
}
