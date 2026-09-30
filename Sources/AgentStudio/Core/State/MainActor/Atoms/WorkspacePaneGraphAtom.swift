import AgentStudioInfrastructure
import Foundation
import Observation
import os.log

private let workspacePaneLogger = Logger(subsystem: "com.agentstudio", category: "WorkspacePaneGraphAtom")

package struct PaneRepositoryAssociation: Equatable, Sendable {
    package let repoId: UUID?
    package let worktreeId: UUID?

    package init(repoId: UUID?, worktreeId: UUID?) {
        if repoId != nil, worktreeId != nil {
            self.repoId = repoId
            self.worktreeId = worktreeId
        } else {
            self.repoId = nil
            self.worktreeId = nil
        }
    }

    fileprivate init(facets: PaneGraphFacets) {
        self.init(repoId: facets.repoId, worktreeId: facets.worktreeId)
    }
}

struct DrawerGraphState: Hashable, Sendable {
    let drawerId: UUID
    let parentPaneId: UUID
    var paneIds: [UUID]

    init(drawerId: UUID = UUID(), parentPaneId: UUID, paneIds: [UUID] = []) {
        self.drawerId = drawerId
        self.parentPaneId = parentPaneId
        self.paneIds = paneIds
    }

    init(drawer: Drawer) {
        self.init(drawerId: drawer.drawerId, parentPaneId: drawer.parentPaneId, paneIds: drawer.paneIds)
    }

    func drawer(isExpanded: Bool) -> Drawer {
        Drawer(drawerId: drawerId, parentPaneId: parentPaneId, paneIds: paneIds, isExpanded: isExpanded)
    }
}

enum PaneGraphKind: Hashable, Sendable {
    case layout(drawer: DrawerGraphState)
    case drawerChild(parentPaneId: UUID)

    init(kind: PaneKind) {
        switch kind {
        case .layout(let drawer):
            self = .layout(drawer: DrawerGraphState(drawer: drawer))
        case .drawerChild(let parentPaneId):
            self = .drawerChild(parentPaneId: parentPaneId)
        }
    }

    func paneKind(isDrawerExpanded: Bool) -> PaneKind {
        switch self {
        case .layout(let drawer):
            return .layout(drawer: drawer.drawer(isExpanded: isDrawerExpanded))
        case .drawerChild(let parentPaneId):
            return .drawerChild(parentPaneId: parentPaneId)
        }
    }
}

struct PaneGraphFacets: Hashable, Sendable {
    var repoId: UUID?
    var worktreeId: UUID?
    var cwd: URL?

    init(repoId: UUID? = nil, worktreeId: UUID? = nil, cwd: URL? = nil) {
        if repoId != nil, worktreeId != nil {
            self.repoId = repoId
            self.worktreeId = worktreeId
        } else {
            self.repoId = nil
            self.worktreeId = nil
        }
        self.cwd = cwd
    }

    init(contextFacets: PaneContextFacets) {
        self.init(
            repoId: contextFacets.repoId,
            worktreeId: contextFacets.worktreeId,
            cwd: contextFacets.cwd
        )
    }

    var paneContextFacets: PaneContextFacets {
        PaneContextFacets(repoId: repoId, worktreeId: worktreeId, cwd: cwd)
    }
}

struct PaneGraphMetadata: Hashable, Sendable {
    let paneId: PaneId
    let contentType: PaneContentType
    let launchDirectory: URL?
    let executionBackend: ExecutionBackend
    let createdAt: Date
    var title: String
    var facets: PaneGraphFacets
    var checkoutRef: String?
    var note: String?
    var isPinned: Bool

    init(metadata: PaneMetadata) {
        self.paneId = metadata.paneId
        self.contentType = metadata.contentType
        self.launchDirectory = metadata.launchDirectory
        self.executionBackend = metadata.executionBackend
        self.createdAt = metadata.createdAt
        self.title = metadata.title
        self.facets = PaneGraphFacets(contextFacets: metadata.facets)
        self.checkoutRef = metadata.checkoutRef
        self.note = metadata.note
        self.isPinned = metadata.isPinned
    }

    mutating func updateNote(_ newNote: String?) {
        let trimmed = newNote?.trimmingCharacters(in: .whitespacesAndNewlines)
        note = trimmed?.isEmpty == true ? nil : trimmed
    }

    var paneMetadata: PaneMetadata {
        PaneMetadata(
            paneId: paneId,
            contentType: contentType,
            launchDirectory: launchDirectory,
            executionBackend: executionBackend,
            createdAt: createdAt,
            title: title,
            facets: facets.paneContextFacets,
            checkoutRef: checkoutRef,
            note: note,
            isPinned: isPinned,
            fillNilLaunchDirectoryFacet: false
        )
    }
}

/// Core pane graph state. This is the write-owner shape for pane identity,
/// content, residency, durable metadata, drawer identity, and drawer
/// membership. It intentionally excludes drawer expansion and display/cache
/// facets, which are composed by cursor and derived read models.
package struct PaneGraphState: Identifiable, Hashable, Sendable {
    package let id: UUID
    var content: PaneContent
    var metadata: PaneGraphMetadata
    var residency: SessionResidency
    var kind: PaneGraphKind

    init(
        id: UUID,
        content: PaneContent,
        metadata: PaneGraphMetadata,
        residency: SessionResidency,
        kind: PaneGraphKind
    ) {
        self.id = id
        self.content = content
        self.metadata = metadata
        self.residency = residency
        self.kind = kind
    }

    init(pane: Pane) {
        self.init(
            id: pane.id,
            content: pane.content,
            metadata: PaneGraphMetadata(metadata: pane.metadata),
            residency: pane.residency,
            kind: PaneGraphKind(kind: pane.kind)
        )
    }

    var drawer: DrawerGraphState? {
        if case .layout(let drawer) = kind { return drawer }
        return nil
    }

    package var isDrawerChild: Bool {
        if case .drawerChild = kind { return true }
        return false
    }

    package var paneContent: PaneContent {
        content
    }

    package var title: String { metadata.title }

    package var isPinned: Bool { metadata.isPinned }

    package var sessionResidency: SessionResidency { residency }

    package var durableContextFacets: PaneContextFacets {
        metadata.facets.paneContextFacets
    }

    package var parentPaneId: UUID? {
        if case .drawerChild(let parentPaneId) = kind { return parentPaneId }
        return nil
    }

    package var ownedDrawerId: UUID? {
        drawer?.drawerId
    }

    package func ownsDrawerChild(_ paneId: UUID) -> Bool {
        drawer?.paneIds.contains(paneId) == true
    }

    mutating func withDrawer(_ transform: (inout DrawerGraphState) -> Void) {
        guard case .layout(var drawer) = kind else { return }
        transform(&drawer)
        kind = .layout(drawer: drawer)
    }

    func pane(isDrawerExpanded: Bool) -> Pane {
        let graphFacets = metadata.facets.paneContextFacets
        var pane = Pane(
            id: id,
            content: content,
            metadata: metadata.paneMetadata,
            residency: residency,
            kind: kind.paneKind(isDrawerExpanded: isDrawerExpanded)
        )
        pane.metadata.updateFacets(graphFacets)
        return pane
    }
}

package enum WorkspacePaneGraphReplacementRejection: Error, Equatable, Sendable {
    case paneKeyIdentityMismatch(key: UUID, paneID: UUID)
    case duplicateDrawerIdentity(UUID)
    case drawerParentMismatch(drawerID: UUID, expectedParentPaneID: UUID, actualParentPaneID: UUID)
    case drawerChildParentMismatch(
        childPaneID: UUID,
        expectedParentPaneID: UUID,
        actualParentPaneID: UUID
    )
    case orphanDrawerChild(childPaneID: UUID, parentPaneID: UUID)
    case duplicateDrawerChildMembership(UUID)
}

package enum BridgePaneStateMutationResult: Equatable, Sendable {
    case applied(BridgePaneState)
    case unchanged(BridgePaneState)
    case paneMissing
    case notBridgePane
    case notWorkspaceSource
}

@MainActor
@Observable
package final class WorkspacePaneGraphAtom {
    @ObservationIgnored private let paneStateMap = AtomFamily<UUID, PaneGraphState>(
        telemetryLabel: "pane_graph_canonical",
        isContentEqual: ==
    )
    @ObservationIgnored private let paneStructuralFactsMap = AtomFamily<UUID, PaneStructuralFacts>(
        telemetryLabel: "pane_graph_structural",
        isContentEqual: ==
    )
    @ObservationIgnored private let paneResidencyMap = AtomFamily<UUID, SessionResidency>(
        telemetryLabel: "pane_graph_residency",
        isContentEqual: ==
    )
    @ObservationIgnored private let paneRepositoryAssociationMap = AtomFamily<UUID, PaneRepositoryAssociation>(
        telemetryLabel: "pane_graph_repository_association",
        isContentEqual: ==
    )
    @ObservationIgnored private let acceptedCommitRevision = AtomRevision()
    @ObservationIgnored private var latestIssuedAssociationRevisionByPaneID: [UUID: UInt64] = [:]
    @ObservationIgnored private var lastAppliedAssociationRevisionByPaneID: [UUID: UInt64] = [:]
    @ObservationIgnored private var parentPaneIDByDrawerID: [UUID: UUID] = [:]

    package init() {}

    package var paneIDs: Set<UUID> {
        _ = paneStateMap.membershipRevision
        return paneStateMap.membershipKeys()
    }

    package var repositoryAssociationPaneIds: Set<UUID> {
        _ = paneRepositoryAssociationMap.membershipRevision
        return paneRepositoryAssociationMap.membershipKeys()
    }

    package var paneAcceptedCommitRevision: Int {
        acceptedCommitRevision.value
    }

    var drawerIds: Set<UUID> {
        Set(paneStructuralFactsMap.snapshot().values.compactMap(\.ownedDrawerID))
    }

    package func paneState(_ id: UUID) -> PaneGraphState? {
        paneStateMap.value(for: id)
    }

    package func paneStructuralFacts(_ id: UUID) -> PaneStructuralFacts? {
        paneStructuralFactsMap.value(for: id)
    }

    package func paneResidency(_ id: UUID) -> SessionResidency? {
        paneResidencyMap.value(for: id)
    }

    package func repositoryAssociation(for paneId: UUID) -> PaneRepositoryAssociation? {
        paneRepositoryAssociationMap.value(for: paneId)
    }

    package func activeRepositoryAssociationWorktreeIDs(
        in associationsByPaneID: [UUID: PaneRepositoryAssociation]
    ) -> Set<UUID> {
        Set(
            associationsByPaneID.compactMap { paneID, association in
                guard let worktreeID = association.worktreeId,
                    paneResidency(paneID)?.isActive == true
                else { return nil }
                return worktreeID
            }
        )
    }

    package func paneStateSnapshot() -> [UUID: PaneGraphState] {
        paneStateMap.snapshot()
    }

    package func parentPaneID(containingDrawer drawerID: UUID) -> UUID? {
        parentPaneIDByDrawerID[drawerID]
    }

    func replacePaneStates(_ replacement: WorkspacePaneGraphReplacement) {
        let previousPaneStates = paneStateMap.snapshot()
        commitPaneStates(
            previousPaneStates: previousPaneStates,
            nextPaneStates: replacement.paneStates
        )
        latestIssuedAssociationRevisionByPaneID = Dictionary(
            uniqueKeysWithValues: replacement.paneStates.keys.map { ($0, 0) }
        )
        lastAppliedAssociationRevisionByPaneID = Dictionary(
            uniqueKeysWithValues: replacement.paneStates.keys.map { ($0, 0) }
        )
    }

    func addPane(_ pane: Pane) {
        mutatePaneStates { paneStates in
            paneStates[pane.id] = PaneGraphState(pane: pane)
        }
        recordSynchronousAssociationWrite(for: pane.id)
    }

    @discardableResult
    func createPane(
        launchDirectory: URL? = nil,
        title: String = "Terminal",
        provider: SessionProvider = .zmx,
        lifetime: SessionLifetime = .persistent,
        zmxSessionID: ZmxSessionID,
        residency: SessionResidency = .active,
        facets: PaneContextFacets = .empty
    ) -> PaneGraphState {
        let admittedCWD =
            [facets.cwd, launchDirectory, FileManager.default.homeDirectoryForCurrentUser]
            .compactMap { candidate -> URL? in
                guard case .accepted(let cwd) = PaneFilesystemLocationPolicy.runtimeCWDUpdate(candidate) else {
                    return nil
                }
                return cwd
            }
            .first ?? FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        var admittedFacets = facets
        admittedFacets.cwd = admittedCWD
        let pane = Pane(
            content: .terminal(
                TerminalState(provider: provider, lifetime: lifetime, zmxSessionID: zmxSessionID)
            ),
            metadata: PaneMetadata(
                launchDirectory: admittedCWD,
                title: title,
                facets: admittedFacets
            ),
            residency: residency
        )
        let state = PaneGraphState(pane: pane)
        mutatePaneStates { paneStates in
            paneStates[state.id] = state
        }
        recordSynchronousAssociationWrite(for: state.id)
        return state
    }

    private func admittedMetadata(
        for content: PaneContent,
        metadata: PaneMetadata
    ) -> PaneMetadata? {
        var admittedMetadata = metadata
        switch PaneFilesystemLocationPolicy.resolveRestoredCWD(
            for: content,
            cwd: metadata.cwd,
            launchDirectory: metadata.launchDirectory
        ) {
        case .valid(let cwd):
            admittedMetadata.updateCWD(cwd)
            return admittedMetadata
        case .repaired(let cwd):
            admittedMetadata.updateCWD(cwd)
            return admittedMetadata
        case .degradedRequired:
            workspacePaneLogger.warning("pane admission: required content has no trustworthy filesystem location")
            return nil
        }
    }

    @discardableResult
    func createPane(
        content: PaneContent,
        metadata: PaneMetadata,
        residency: SessionResidency = .active
    ) -> PaneGraphState? {
        guard let admittedMetadata = admittedMetadata(for: content, metadata: metadata) else { return nil }

        let pane = Pane(content: content, metadata: admittedMetadata, residency: residency)
        let state = PaneGraphState(pane: pane)
        mutatePaneStates { paneStates in
            paneStates[state.id] = state
        }
        recordSynchronousAssociationWrite(for: state.id)
        return state
    }

    @discardableResult
    func insertRestoredPane(_ pane: Pane) -> Bool {
        guard paneStateMap.snapshotValue(for: pane.id) == nil else { return false }
        mutatePaneStates { paneStates in
            paneStates[pane.id] = PaneGraphState(pane: pane)
        }
        recordSynchronousAssociationWrite(for: pane.id)
        return true
    }

    @discardableResult
    func deletePaneAndOwnedDrawerChildren(_ paneId: UUID) -> Bool {
        guard let paneState = paneStateMap.snapshotValue(for: paneId) else { return false }
        mutatePaneStates { paneStates in
            if let drawer = paneState.drawer {
                for childId in drawer.paneIds {
                    paneStates.removeValue(forKey: childId)
                }
            }
            paneStates.removeValue(forKey: paneId)
        }
        return true
    }

    func updatePaneTitle(_ paneId: UUID, title: String) {
        guard var currentState = paneStateMap.snapshotValue(for: paneId) else {
            workspacePaneLogger.warning("updatePaneTitle: pane \(paneId) not found")
            return
        }
        guard currentState.metadata.title != title else { return }
        currentState.metadata.title = title
        let mutation = AtomMutationContext(aggregateRevision: acceptedCommitRevision)
        paneStateMap.setValue(currentState, for: paneId, mutation: mutation)
        mutation.commit()
    }

    func updatePaneCWD(_ paneId: UUID, cwd: URL?) {
        guard let revision = reservePaneAssociationRevision(paneId) else {
            workspacePaneLogger.warning("updatePaneCWD: pane \(paneId) not found")
            return
        }
        _ = applyPaneAssociationUpdate(
            paneId,
            cwdAdmission: .explicit(cwd),
            resolution: .uncertain,
            revision: revision
        )
    }

    func updatePaneNote(_ paneId: UUID, note: String?) {
        guard paneStateMap.snapshotValue(for: paneId) != nil else {
            workspacePaneLogger.warning("updatePaneNote: pane \(paneId) not found")
            return
        }
        mutatePaneStates { paneStates in
            paneStates[paneId]?.metadata.updateNote(note)
        }
    }

    func updatePanePinned(_ paneId: UUID, isPinned: Bool) {
        guard let currentState = paneStateMap.snapshotValue(for: paneId) else {
            workspacePaneLogger.warning("updatePanePinned: pane \(paneId) not found")
            return
        }
        guard currentState.metadata.isPinned != isPinned else { return }
        mutatePaneStates { paneStates in
            paneStates[paneId]?.metadata.isPinned = isPinned
        }
    }

    package func reservePaneAssociationRevision(_ paneId: UUID) -> PaneAssociationRevision? {
        guard paneStateMap.snapshotValue(for: paneId) != nil else { return nil }
        let revision = (latestIssuedAssociationRevisionByPaneID[paneId] ?? 0) + 1
        latestIssuedAssociationRevisionByPaneID[paneId] = revision
        return PaneAssociationRevision(rawValue: revision)
    }

    package func applyPaneAssociationUpdate(
        _ paneId: UUID,
        cwd: URL?,
        resolution: PaneAssociationResolution,
        revision: PaneAssociationRevision
    ) -> PaneCWDContextUpdateResult {
        applyPaneAssociationUpdate(
            paneId,
            cwdAdmission: .runtime(cwd),
            resolution: resolution,
            revision: revision
        )
    }

    private enum PaneAssociationCWDAdmission {
        case explicit(URL?)
        case runtime(URL?)
    }

    private func applyPaneAssociationUpdate(
        _ paneId: UUID,
        cwdAdmission: PaneAssociationCWDAdmission,
        resolution: PaneAssociationResolution,
        revision: PaneAssociationRevision
    ) -> PaneCWDContextUpdateResult {
        guard let currentState = paneStateMap.snapshotValue(for: paneId) else {
            workspacePaneLogger.warning("applyPaneAssociationUpdate: pane \(paneId) not found")
            return .paneMissing
        }
        guard
            latestIssuedAssociationRevisionByPaneID[paneId] == revision.rawValue,
            revision.rawValue > (lastAppliedAssociationRevisionByPaneID[paneId] ?? 0)
        else { return .staleRevision }

        let acceptedCWD: URL?
        switch cwdAdmission {
        case .explicit(nil):
            acceptedCWD = nil
        case .explicit(let candidate), .runtime(let candidate):
            guard case .accepted(let normalizedCWD) = PaneFilesystemLocationPolicy.runtimeCWDUpdate(candidate)
            else { return .unchanged }
            acceptedCWD = normalizedCWD
        }

        var facets = currentState.metadata.facets
        facets.cwd = acceptedCWD
        switch resolution {
        case .matched(let repoId, let worktreeId):
            facets.repoId = repoId
            facets.worktreeId = worktreeId
        case .confidentNoMatch:
            facets.repoId = nil
            facets.worktreeId = nil
        case .uncertain:
            break
        }

        lastAppliedAssociationRevisionByPaneID[paneId] = revision.rawValue

        guard facets != currentState.metadata.facets else {
            return resolution == .uncertain ? .deferredUncertain : .unchanged
        }

        mutatePaneStates { paneStates in
            paneStates[paneId]?.metadata.facets = facets
        }
        return resolution == .uncertain ? .deferredUncertain : .applied
    }

    func updatePaneWebviewState(_ paneId: UUID, state: WebviewState) {
        guard paneStateMap.snapshotValue(for: paneId) != nil else {
            workspacePaneLogger.warning("updatePaneWebviewState: pane \(paneId) not found")
            return
        }
        mutatePaneStates { paneStates in
            paneStates[paneId]?.content = .webview(state)
        }
    }

    func syncPaneWebviewState(_ paneId: UUID, state: WebviewState) {
        guard let paneState = paneStateMap.snapshotValue(for: paneId) else {
            workspacePaneLogger.warning("syncPaneWebviewState: pane \(paneId) not found")
            return
        }
        guard paneState.content != .webview(state) else { return }
        mutatePaneStates { paneStates in
            paneStates[paneId]?.content = .webview(state)
        }
    }

    @discardableResult
    package func updateBridgePaneState(
        _ paneId: UUID,
        state: BridgePaneState
    ) -> BridgePaneStateMutationResult {
        mutatePaneStates { paneStates in
            guard let paneState = paneStates[paneId] else {
                return .paneMissing
            }
            guard case .bridgePanel(let currentState) = paneState.content else {
                return .notBridgePane
            }
            guard currentState != state else {
                return .unchanged(currentState)
            }
            paneStates[paneId]?.content = .bridgePanel(state)
            return .applied(state)
        }
    }

    @discardableResult
    package func setInitialBridgeContributionTargetIfAbsent(
        _ paneId: UUID,
        target: WorkspaceReviewContributionTarget
    ) -> BridgePaneStateMutationResult {
        mutatePaneStates { paneStates in
            guard let paneState = paneStates[paneId] else {
                return .paneMissing
            }
            guard case .bridgePanel(let currentState) = paneState.content else {
                return .notBridgePane
            }
            guard case .workspace(let rootPath, let baseline) = currentState.source else {
                return .notWorkspaceSource
            }
            guard baseline == nil else {
                return .unchanged(currentState)
            }

            let updatedState = BridgePaneState(
                panelKind: currentState.panelKind,
                source: .workspace(
                    rootPath: rootPath,
                    baseline: WorkspaceBaseline(contributionTarget: target)
                )
            )
            paneStates[paneId]?.content = .bridgePanel(updatedState)
            return .applied(updatedState)
        }
    }

    @discardableResult
    package func setBridgeContributionTarget(
        _ paneId: UUID,
        target: WorkspaceReviewContributionTarget
    ) -> BridgePaneStateMutationResult {
        mutatePaneStates { paneStates in
            guard let paneState = paneStates[paneId] else {
                return .paneMissing
            }
            guard case .bridgePanel(let currentState) = paneState.content else {
                return .notBridgePane
            }
            guard case .workspace(let rootPath, _) = currentState.source else {
                return .notWorkspaceSource
            }
            let updatedState = BridgePaneState(
                panelKind: currentState.panelKind,
                source: .workspace(
                    rootPath: rootPath,
                    baseline: WorkspaceBaseline(contributionTarget: target)
                )
            )
            guard updatedState != currentState else {
                return .unchanged(currentState)
            }
            paneStates[paneId]?.content = .bridgePanel(updatedState)
            return .applied(updatedState)
        }
    }

    func setResidency(_ residency: SessionResidency, for paneId: UUID) {
        guard paneStateMap.snapshotValue(for: paneId) != nil else {
            workspacePaneLogger.warning("setResidency: pane \(paneId) not found")
            return
        }
        mutatePaneStates { paneStates in
            paneStates[paneId]?.residency = residency
        }
    }

    func purgeOrphanedPane(_ paneId: UUID) {
        guard let pane = paneStateMap.snapshotValue(for: paneId), pane.residency == .backgrounded else {
            workspacePaneLogger.warning("purgeOrphanedPane: pane \(paneId) is not backgrounded")
            return
        }
        _ = mutatePaneStates { paneStates in
            paneStates.removeValue(forKey: paneId)
        }
    }

    @discardableResult
    func addDrawerPane(
        to parentPaneId: UUID,
        content: PaneContent,
        metadata: PaneMetadata,
        childPaneId: UUID? = nil
    ) -> PaneGraphState? {
        guard paneStateMap.snapshotValue(for: parentPaneId) != nil else {
            workspacePaneLogger.warning("addDrawerPane: parent pane \(parentPaneId) not found")
            return nil
        }
        guard let admittedMetadata = admittedMetadata(for: content, metadata: metadata) else { return nil }

        let drawerPane = Pane(
            id: childPaneId ?? UUIDv7.generate(),
            content: content,
            metadata: admittedMetadata,
            residency: .active,
            kind: .drawerChild(parentPaneId: parentPaneId)
        )
        let drawerState = PaneGraphState(pane: drawerPane)
        mutatePaneStates { paneStates in
            paneStates[drawerState.id] = drawerState
            paneStates[parentPaneId]?.withDrawer { drawer in
                drawer.paneIds.append(drawerState.id)
            }
        }
        recordSynchronousAssociationWrite(for: drawerState.id)
        return drawerState
    }

    @discardableResult
    func insertDrawerPane(
        in parentPaneId: UUID,
        at targetDrawerPaneId: UUID,
        content: PaneContent,
        metadata: PaneMetadata
    ) -> PaneGraphState? {
        guard let parentPane = paneStateMap.snapshotValue(for: parentPaneId), let drawer = parentPane.drawer else {
            workspacePaneLogger.warning("insertDrawerPane: parent pane \(parentPaneId) has no drawer")
            return nil
        }
        guard drawer.paneIds.contains(targetDrawerPaneId) else {
            workspacePaneLogger.warning("insertDrawerPane: target \(targetDrawerPaneId) not in drawer")
            return nil
        }

        return addDrawerPane(to: parentPaneId, content: content, metadata: metadata)
    }

    func removeDrawerPane(_ drawerPaneId: UUID, from parentPaneId: UUID) {
        guard paneStateMap.snapshotValue(for: parentPaneId)?.drawer != nil else {
            workspacePaneLogger.warning("removeDrawerPane: parent pane \(parentPaneId) has no drawer")
            return
        }

        mutatePaneStates { paneStates in
            paneStates[parentPaneId]?.withDrawer { drawer in
                drawer.paneIds.removeAll { $0 == drawerPaneId }
            }
            paneStates.removeValue(forKey: drawerPaneId)
        }
    }

    @discardableResult
    func detachDrawerPane(_ drawerPaneId: UUID, from parentPaneId: UUID) -> PaneGraphState? {
        guard var drawerPane = paneStateMap.snapshotValue(for: drawerPaneId),
            drawerPane.parentPaneId == parentPaneId
        else {
            workspacePaneLogger.warning(
                "detachDrawerPane: pane \(drawerPaneId) is not a child of \(parentPaneId)"
            )
            return nil
        }
        guard paneStateMap.snapshotValue(for: parentPaneId)?.drawer != nil else {
            workspacePaneLogger.warning("detachDrawerPane: parent pane \(parentPaneId) has no drawer")
            return nil
        }

        drawerPane.kind = .layout(drawer: DrawerGraphState(parentPaneId: drawerPaneId))
        mutatePaneStates { paneStates in
            paneStates[parentPaneId]?.withDrawer { drawer in
                drawer.paneIds.removeAll { $0 == drawerPaneId }
            }
            paneStates[drawerPaneId] = drawerPane
        }
        return drawerPane
    }

    @discardableResult
    func restoreDrawerPane(_ drawerPane: Pane, to parentPaneId: UUID) -> Bool {
        guard paneStateMap.snapshotValue(for: parentPaneId) != nil else {
            workspacePaneLogger.warning("restoreDrawerPane: parent pane \(parentPaneId) not found")
            return false
        }
        guard paneStateMap.snapshotValue(for: parentPaneId)?.drawer != nil else {
            workspacePaneLogger.warning("restoreDrawerPane: parent pane \(parentPaneId) has no drawer")
            return false
        }

        var restoredPane = drawerPane
        restoredPane.kind = .drawerChild(parentPaneId: parentPaneId)
        mutatePaneStates { paneStates in
            paneStates[restoredPane.id] = PaneGraphState(pane: restoredPane)
            paneStates[parentPaneId]?.withDrawer { drawer in
                drawer.paneIds.removeAll { $0 == restoredPane.id }
                drawer.paneIds.append(restoredPane.id)
            }
        }
        recordSynchronousAssociationWrite(for: restoredPane.id)
        return true
    }

    private func recordSynchronousAssociationWrite(for paneID: UUID) {
        let revision = (latestIssuedAssociationRevisionByPaneID[paneID] ?? 0) + 1
        latestIssuedAssociationRevisionByPaneID[paneID] = revision
        lastAppliedAssociationRevisionByPaneID[paneID] = revision
    }

    private func mutatePaneStates<TMutationResult>(
        _ transform: (inout [UUID: PaneGraphState]) -> TMutationResult
    ) -> TMutationResult {
        let previousPaneStates = paneStateMap.snapshot()
        var nextPaneStates = previousPaneStates
        let result = transform(&nextPaneStates)
        commitPaneStates(
            previousPaneStates: previousPaneStates,
            nextPaneStates: nextPaneStates
        )
        return result
    }

    private func commitPaneStates(
        previousPaneStates: [UUID: PaneGraphState],
        nextPaneStates: [UUID: PaneGraphState]
    ) {
        let mutation = AtomMutationContext(aggregateRevision: acceptedCommitRevision)
        let previousPaneIDs = Set(previousPaneStates.keys)
        let nextPaneIDs = Set(nextPaneStates.keys)
        let removedPaneIDs = previousPaneIDs.subtracting(nextPaneIDs)

        for removedPaneID in removedPaneIDs {
            paneStateMap.removeValue(for: removedPaneID, mutation: mutation)
            paneStructuralFactsMap.removeValue(for: removedPaneID, mutation: mutation)
            paneResidencyMap.removeValue(for: removedPaneID, mutation: mutation)
            paneRepositoryAssociationMap.removeValue(for: removedPaneID, mutation: mutation)
            latestIssuedAssociationRevisionByPaneID.removeValue(forKey: removedPaneID)
            lastAppliedAssociationRevisionByPaneID.removeValue(forKey: removedPaneID)
        }
        for (paneID, nextPaneState) in nextPaneStates where previousPaneStates[paneID] != nextPaneState {
            paneStateMap.setValue(nextPaneState, for: paneID, mutation: mutation)
            paneStructuralFactsMap.setValue(
                PaneStructuralFacts(state: nextPaneState),
                for: paneID,
                mutation: mutation
            )
            paneResidencyMap.setValue(
                nextPaneState.residency,
                for: paneID,
                mutation: mutation
            )
            paneRepositoryAssociationMap.setValue(
                PaneRepositoryAssociation(facets: nextPaneState.metadata.facets),
                for: paneID,
                mutation: mutation
            )
        }

        let nextParentPaneIDByDrawerID = Dictionary(
            uniqueKeysWithValues: nextPaneStates.values.compactMap { paneState in
                paneState.drawer.map { ($0.drawerId, paneState.id) }
            }
        )
        if parentPaneIDByDrawerID != nextParentPaneIDByDrawerID {
            parentPaneIDByDrawerID = nextParentPaneIDByDrawerID
        }
        mutation.commit()

        precondition(Set(paneStateMap.snapshot().keys) == nextPaneIDs)
        precondition(Set(paneStructuralFactsMap.snapshot().keys) == nextPaneIDs)
        precondition(Set(paneResidencyMap.snapshot().keys) == nextPaneIDs)
        precondition(Set(paneRepositoryAssociationMap.snapshot().keys) == nextPaneIDs)
        precondition(
            nextPaneStates.allSatisfy { paneID, paneState in
                paneStructuralFactsMap.snapshotValue(for: paneID) == PaneStructuralFacts(state: paneState)
            }
        )
        precondition(
            nextPaneStates.allSatisfy { paneID, paneState in
                paneResidencyMap.snapshotValue(for: paneID) == paneState.residency
            }
        )
    }
}
