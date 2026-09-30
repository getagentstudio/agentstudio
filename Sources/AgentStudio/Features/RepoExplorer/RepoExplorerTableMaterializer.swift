import AgentStudioInfrastructure
import AppKit

struct RepoExplorerTableScrollAnchor: Equatable {
    let rowID: RepoExplorerRowID
    let offset: CGFloat
    let identity: RepoExplorerRowAnchorIdentity
    let followingIdentities: [RepoExplorerRowAnchorIdentity]
    let wasAtTop: Bool
}

enum RepoExplorerRowAnchorIdentity: Hashable {
    case pane(UUID)
    case row(RepoExplorerRowID)

    init(rowID: RepoExplorerRowID) {
        switch rowID {
        case .associatedPane(_, _, _, let paneID), .tabPane(_, let paneID), .unassociatedPane(let paneID):
            self = .pane(paneID)
        default:
            self = .row(rowID)
        }
    }
}

@MainActor
final class RepoExplorerTableMaterializer: NSObject,
    RepoExplorerMaterializationContentChild,
    RepoExplorerNativeTableTransactionTarget,
    NSTableViewDataSource,
    NSTableViewDelegate
{
    typealias VisibleRowHeightMeasurer =
        @MainActor (
            RepoExplorerMaterializedRow,
            CGFloat
        ) -> CGFloat?

    let view: NSView
    private(set) var nativeTransactionApplyCount = 0
    private(set) var hostedCellCreationCount = 0
    private(set) var tableFrameUpdateCount = 0
    private(set) var forcedLayoutPassCount = 0
    private(set) var explicitScrollRestorationCount = 0

    var numberOfRows: Int { snapshot?.rows.count ?? 0 }

    private struct HeightCacheEntry {
        let contentRevision: RepoExplorerRowContentRevision
        let widthRevision: Int
        let height: CGFloat
    }

    let tableView = RepoExplorerTableView()
    let scrollView: NSScrollView
    private let materializationHostLifetimeID: RepoExplorerMaterializationHostLifetimeID
    private let octiconLoader: OcticonLoader
    let interactions: RepoExplorerTableInteractions
    private let measureVisibleRowHeight: VisibleRowHeightMeasurer
    private let onVisibleWorktreeSnapshotChange: @MainActor (RepoExplorerVisibleWorktreeSnapshot) -> Void
    private let observeCurrentVisibleTarget: @MainActor (RepoExplorerVisibleWorktreeSnapshot) -> Void
    private var contextMenuPresenter: RepoExplorerContextMenuPresenter?
    private(set) var snapshot: RepoExplorerMaterializationSnapshot?
    private var visibleGeneration: UInt64?
    private var viewportTask: Task<Void, Never>?
    private var viewportSequence: UInt64 = 0
    private var visibleRevision: UInt64 = 0
    private var currentVisibleSnapshot: RepoExplorerVisibleWorktreeSnapshot
    private var lastPublishedVisibleSnapshot: RepoExplorerVisibleWorktreeSnapshot?
    private var acceptedCommandPresentationSnapshot = RepoExplorerCommandPresentationSnapshot.empty
    private var acceptedCommandGeneration: UInt64 = 0
    private var heightByRowID: [RepoExplorerRowID: HeightCacheEntry] = [:]
    var selectedVariantRowID: RepoExplorerRowID?
    private var widthRevision = 0
    private var pendingReloadRows = IndexSet()
    private var pendingHeightRows = IndexSet()
    private var pendingApplicationRequiresGeometryUpdate = false
    var isApplyingProgrammaticSelection = false
    // Render-only input; key routing always checks the actual responder and current owner.
    var showsKeyboardHints = false
    private var boundsObserver: NSObjectProtocol?
    /// A size-only change of the clip view (sidebar re-shown or expanded) posts a frame
    /// change but not a bounds change; it is the moment suspended rows become representable.
    private var clipFrameObserver: NSObjectProtocol?
    private(set) var isDetached = false
    private var isDemandActive = true
    /// Set when suspension cleared represented cells and no row was representable to rebind
    /// at resume (the view had no laid-out bounds yet). The next geometry change rebinds once.
    private var needsRepresentedRebindAfterLayout = false

    init(
        materializationHostLifetimeID: RepoExplorerMaterializationHostLifetimeID =
            RepoExplorerMaterializationHostLifetimeID(
                rawValue: UUIDv7.generate()
            ),
        octiconLoader: OcticonLoader,
        interactions: RepoExplorerTableInteractions = .inert,
        onVisibleWorktreeSnapshotChange: @escaping @MainActor (RepoExplorerVisibleWorktreeSnapshot) -> Void,
        observeCurrentVisibleTarget: @escaping @MainActor (RepoExplorerVisibleWorktreeSnapshot) -> Void = { _ in },
        measureVisibleRowHeight: @escaping VisibleRowHeightMeasurer = { _, _ in nil }
    ) {
        self.materializationHostLifetimeID = materializationHostLifetimeID
        self.octiconLoader = octiconLoader
        self.interactions = interactions
        self.onVisibleWorktreeSnapshotChange = onVisibleWorktreeSnapshotChange
        self.observeCurrentVisibleTarget = observeCurrentVisibleTarget
        self.measureVisibleRowHeight = measureVisibleRowHeight
        currentVisibleSnapshot = RepoExplorerVisibleWorktreeSnapshot(
            target: RepoExplorerCommandPresentationTarget(
                materializationHostLifetimeID: materializationHostLifetimeID,
                materializationGeneration: 0,
                visibleRevision: 0
            ),
            worktreeIDs: []
        )
        scrollView = NSScrollView(frame: .zero)
        view = scrollView
        super.init()

        contextMenuPresenter = RepoExplorerContextMenuPresenter(
            octiconLoader: octiconLoader,
            interactions: interactions,
            isRowCurrent: { [weak self] rowID in
                self?.snapshot?.rowIndexByID[rowID] != nil
            }
        )
        tableView.contextMenuProvider = { [weak self] rowIndex in
            self?.makeContextMenu(forRowAt: rowIndex)
        }

        scrollView.drawsBackground = false
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = .zero
        tableView.usesAutomaticRowHeights = false
        tableView.addTableColumn(
            NSTableColumn(identifier: NSUserInterfaceItemIdentifier("repo-explorer-content"))
        )
        tableView.dataSource = self
        tableView.delegate = self
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.boundsDidChange()
            }
        }
        scrollView.contentView.postsFrameChangedNotifications = true
        clipFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebindRepresentedCellsAfterSuspension()
            }
        }
        updateTableFrame()
    }

    func makeContextMenu(forRowID rowID: RepoExplorerRowID) -> NSMenu? {
        guard let rowIndex = snapshot?.rowIndexByID[rowID] else { return nil }
        return makeContextMenu(forRowAt: rowIndex)
    }

    private func makeContextMenu(forRowAt rowIndex: Int) -> NSMenu? {
        guard let row = snapshot?.rows[safe: rowIndex] else { return nil }
        return contextMenuPresenter?.makeMenu(
            for: row,
            commandPresentationSnapshot: acceptedCommandPresentationSnapshot
        )
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        numberOfRows
    }

    func tableView(
        _ tableView: NSTableView,
        objectValueFor tableColumn: NSTableColumn?,
        row: Int
    ) -> Any? {
        row
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row rowIndex: Int
    ) -> NSView? {
        guard let row = snapshot?.rows[safe: rowIndex], let visibleGeneration else {
            return nil
        }
        let cell: RepoExplorerTableRowCell
        if let reused = tableView.makeView(
            withIdentifier: RepoExplorerTableRowCell.reuseIdentifier,
            owner: self
        ) as? RepoExplorerTableRowCell {
            cell = reused
        } else {
            cell = RepoExplorerTableRowCell(
                octiconLoader: octiconLoader,
                interactions: interactions
            )
            hostedCellCreationCount += 1
        }
        cell.bind(
            row: displayedRow(row),
            visibleGeneration: visibleGeneration,
            commandPresentationSnapshot: acceptedCommandPresentationSnapshot
        )
        cell.applyKeyboardPresentation(keyboardPresentation(for: row.id))
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard isApplyingProgrammaticSelection,
            let rowID = snapshot?.rows[safe: row]?.id
        else { return false }
        return snapshot?.navigationIndex.containsSelectableRow(rowID) == true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingProgrammaticSelection else { return }
        guard let tableView = notification.object as? NSTableView else { return }
        tableView.deselectAll(nil)
    }

    func tableView(_ tableView: NSTableView, heightOfRow rowIndex: Int) -> CGFloat {
        resolvedHeight(forRowAt: rowIndex)
    }

    func resolvedHeight(forRowAt rowIndex: Int) -> CGFloat {
        guard let sourceRow = snapshot?.rows[safe: rowIndex] else { return tableView.rowHeight }
        let row = displayedRow(sourceRow)
        let fallbackHeight = max(row.layout.metrics.minimumHeight, row.layout.metrics.fallbackHeight)
        guard row.layout.requiresVisibleWidthMeasurement,
            representedRowIndexes().contains(rowIndex)
        else {
            return fallbackHeight
        }

        let currentWidthRevision = normalizedWidthRevision()
        if let cached = heightByRowID[row.id],
            cached.contentRevision == row.contentRevision,
            cached.widthRevision == currentWidthRevision
        {
            return cached.height
        }
        guard let measured = measureVisibleRowHeight(row, availableContentWidth(for: row)) else {
            return fallbackHeight
        }
        let height = max(row.layout.metrics.minimumHeight, measured)
        heightByRowID[row.id] = HeightCacheEntry(
            contentRevision: row.contentRevision,
            widthRevision: currentWidthRevision,
            height: height
        )
        return height
    }

    func apply(
        _ candidate: RepoExplorerMaterializationContentCandidate,
        completion: @escaping (RepoExplorerMaterializationChildDisposition) -> Void
    ) {
        guard !isDetached else {
            completion(.rejected)
            return
        }
        if let selectedRowID = candidate.selectedRowID,
            !candidate.snapshot.navigationIndex.containsSelectableRow(selectedRowID)
        {
            completion(.rejected)
            return
        }
        let priorSnapshot = snapshot
        let priorVisibleGeneration = visibleGeneration
        let priorVisibleSnapshot = currentVisibleSnapshot
        let priorCommandSnapshot = acceptedCommandPresentationSnapshot
        let priorCommandGeneration = acceptedCommandGeneration
        let priorSelectedVariantRowID = selectedVariantRowID
        let anchor = currentTopVisibleAnchor
        snapshot = candidate.snapshot
        selectedVariantRowID = candidate.selectedRowID
        visibleGeneration = candidate.visibleGeneration
        if priorVisibleGeneration != candidate.visibleGeneration {
            advanceVisibleTarget(
                materializationGeneration: candidate.visibleGeneration,
                worktreeIDs: priorVisibleSnapshot.worktreeIDs,
                paneIDs: priorVisibleSnapshot.paneIDs,
                repositoryIDs: priorVisibleSnapshot.repositoryIDs
            )
            acceptedCommandPresentationSnapshot = .empty
            acceptedCommandGeneration = 0
        }
        heightByRowID = heightByRowID.filter { candidate.snapshot.rowIndexByID[$0.key] != nil }
        updateWidthRevisionIfNeeded()
        pendingApplicationRequiresGeometryUpdate =
            priorSelectedVariantRowID != selectedVariantRowID
            || Self.requiresGeometryUpdate(
                for: candidate.tableUpdatePlan,
                snapshot: candidate.snapshot
            )
        if pendingApplicationRequiresGeometryUpdate {
            updateTableFrame()
        }

        nativeTransactionApplyCount += 1
        let didApply = RepoExplorerNativeTransactionApplier.apply(
            tablePlan: candidate.tableUpdatePlan,
            to: self
        )
        guard didApply, tableView.numberOfRows == candidate.snapshot.rows.count else {
            snapshot = priorSnapshot
            visibleGeneration = priorVisibleGeneration
            currentVisibleSnapshot = priorVisibleSnapshot
            acceptedCommandPresentationSnapshot = priorCommandSnapshot
            acceptedCommandGeneration = priorCommandGeneration
            selectedVariantRowID = priorSelectedVariantRowID
            updateTableFrame()
            pendingApplicationRequiresGeometryUpdate = false
            completion(.rejected)
            return
        }
        if priorSelectedVariantRowID != selectedVariantRowID {
            var affected = IndexSet()
            if let priorSelectedVariantRowID {
                heightByRowID.removeValue(forKey: priorSelectedVariantRowID)
                if let priorIndex = candidate.snapshot.rowIndexByID[priorSelectedVariantRowID] {
                    affected.insert(priorIndex)
                }
            }
            if let selectedVariantRowID {
                heightByRowID.removeValue(forKey: selectedVariantRowID)
                if let selectedIndex = candidate.snapshot.rowIndexByID[selectedVariantRowID] {
                    affected.insert(selectedIndex)
                }
            }
            if !affected.isEmpty {
                tableView.noteHeightOfRows(withIndexesChanged: affected)
            }
        }
        pendingApplicationRequiresGeometryUpdate = false
        precondition(
            applySelection(rowID: candidate.selectedRowID, scrollIntoView: false),
            "Validated Repo Explorer selection must apply after its native table transaction"
        )
        restore(anchor: anchor, tablePlan: candidate.tableUpdatePlan, priorSnapshot: priorSnapshot)
        scheduleViewportPublication()
        completion(.accepted)
    }

    /// Content-only application policy: a plan that only reloads row content in
    /// place (same membership, no height-affecting change) skips the frame
    /// update, forced layout passes, and anchor restoration that a membership
    /// or height-affecting change still requires. A row that requires visible
    /// width measurement is treated as height-affecting even when its cached
    /// layout metrics did not change, because its rendered height depends on
    /// content that just changed.
    private static func requiresGeometryUpdate(
        for tablePlan: RepoExplorerNativeTableUpdatePlan,
        snapshot: RepoExplorerMaterializationSnapshot
    ) -> Bool {
        switch tablePlan {
        case .membership:
            return true
        case .content(let content):
            if !content.heightReloadRowsInNewSpace.isEmpty {
                return true
            }
            return content.reloadRowsInNewSpace.contains { index in
                snapshot.rows[safe: index]?.layout.requiresVisibleWidthMeasurement == true
            }
        }
    }

    func prepareForRemoval(
        visibleGeneration: UInt64,
        completion: @escaping (RepoExplorerMaterializationChildDisposition) -> Void
    ) {
        invalidateScheduledViewportPublication()
        self.visibleGeneration = visibleGeneration
        advanceVisibleTarget(
            materializationGeneration: visibleGeneration,
            worktreeIDs: []
        )
        acceptedCommandPresentationSnapshot = .empty
        acceptedCommandGeneration = 0
        lastPublishedVisibleSnapshot = currentVisibleSnapshot
        onVisibleWorktreeSnapshotChange(currentVisibleSnapshot)
        clearRepresentedCellsForReuse()
        completion(.accepted)
    }

    func suspendDemand() {
        guard !isDetached, isDemandActive else { return }
        isDemandActive = false
        invalidateScheduledViewportPublication()
        clearRepresentedCellsForReuse()
        needsRepresentedRebindAfterLayout = true
        publishClearedViewportDemand()
    }

    func resumeDemand(visibleGeneration: UInt64) {
        guard !isDetached, !isDemandActive, self.visibleGeneration == visibleGeneration else { return }
        isDemandActive = true
        advanceVisibleTarget(
            materializationGeneration: visibleGeneration,
            worktreeIDs: currentVisibleSnapshot.worktreeIDs,
            paneIDs: currentVisibleSnapshot.paneIDs,
            repositoryIDs: currentVisibleSnapshot.repositoryIDs
        )
        acceptedCommandPresentationSnapshot = .empty
        acceptedCommandGeneration = 0
        rebindRepresentedCellsAfterSuspension()
        scheduleViewportPublication()
    }

    func detach() {
        guard !isDetached else { return }
        isDetached = true
        invalidateScheduledViewportPublication()
        clearRepresentedCellsForReuse()
        clearViewportDemand()
        if let clipFrameObserver {
            NotificationCenter.default.removeObserver(clipFrameObserver)
            self.clipFrameObserver = nil
        }
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
            self.boundsObserver = nil
        }
        tableView.contextMenuProvider = nil
        contextMenuPresenter = nil
        tableView.dataSource = nil
        tableView.delegate = nil
        scrollView.documentView = nil
        snapshot = nil
        heightByRowID.removeAll(keepingCapacity: false)
    }

    func scroll(to rowID: RepoExplorerRowID, offset: CGFloat) {
        guard let rowIndex = snapshot?.rowIndexByID[rowID] else { return }
        scroll(toRowAt: rowIndex, offset: offset)
        scheduleViewportPublication()
    }

    func drainViewportPublication() async {
        await viewportTask?.value
    }

    func applyCommandPresentationDelta(
        _ delta: RepoExplorerCommandPresentationDelta
    ) -> RepoExplorerCommandPresentationDeltaDisposition {
        guard !isDetached, delta.target == currentVisibleSnapshot.target else {
            observeCurrentVisibleTarget(currentVisibleSnapshot)
            return .stale(currentVisibleSnapshot: currentVisibleSnapshot)
        }
        guard delta.commandGeneration > acceptedCommandGeneration else {
            return .duplicateOrOlderCommandGeneration
        }

        acceptedCommandPresentationSnapshot = delta.snapshot
        acceptedCommandGeneration = delta.commandGeneration
        var affectedRowIDs: Set<RepoExplorerRowID> = []
        if let snapshot {
            for paneID in delta.affectedPaneIDs {
                affectedRowIDs.formUnion(snapshot.rowIDsByPaneID[paneID] ?? [])
            }
            for worktreeID in delta.affectedWorktreeIDs {
                affectedRowIDs.formUnion(snapshot.rowIDsByWorktreeID[worktreeID] ?? [])
            }
            for repositoryID in delta.affectedRepositoryIDs {
                affectedRowIDs.formUnion(snapshot.rowIDsByRepoID[repositoryID] ?? [])
            }
        }
        let represented = representedRowIndexes()
        var reboundRowCount = 0
        for rowID in affectedRowIDs {
            guard let rowIndex = snapshot?.rowIndexByID[rowID], represented.contains(rowIndex),
                let cell = tableView.view(
                    atColumn: 0,
                    row: rowIndex,
                    makeIfNecessary: false
                ) as? RepoExplorerTableRowCell,
                let row = snapshot?.rows[safe: rowIndex],
                let visibleGeneration
            else { continue }
            cell.bind(
                row: displayedRow(row),
                visibleGeneration: visibleGeneration,
                commandPresentationSnapshot: acceptedCommandPresentationSnapshot
            )
            cell.applyKeyboardPresentation(keyboardPresentation(for: row.id))
            reboundRowCount += 1
        }
        return .accepted(reboundRowCount: reboundRowCount)
    }

    func beginUpdates() {
        pendingReloadRows.removeAll()
        pendingHeightRows.removeAll()
        tableView.beginUpdates()
    }

    func removeRows(_ indexes: IndexSet) {
        tableView.removeRows(at: indexes, withAnimation: [])
    }

    func moveRow(from oldIndex: Int, to newIndex: Int) {
        tableView.moveRow(at: oldIndex, to: newIndex)
    }

    func insertRows(_ indexes: IndexSet) {
        tableView.insertRows(at: indexes, withAnimation: [])
    }

    func reloadRows(_ indexes: IndexSet) {
        pendingReloadRows.formUnion(indexes)
    }

    func noteHeightChanges(_ indexes: IndexSet) {
        pendingHeightRows.formUnion(indexes)
    }

    func endUpdates() {
        tableView.endUpdates()
        if pendingApplicationRequiresGeometryUpdate {
            updateTableFrame()
            forceTableAndScrollLayout()
            let represented = representedRowIndexes()
            let visibleReloadRows = pendingReloadRows.intersection(represented)
            if !visibleReloadRows.isEmpty {
                tableView.reloadData(
                    forRowIndexes: visibleReloadRows,
                    columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
                )
            }
            if !pendingHeightRows.isEmpty {
                tableView.noteHeightOfRows(withIndexesChanged: pendingHeightRows)
            }
            rebindRepresentedCells()
        } else {
            let represented = representedRowIndexes()
            let visibleReloadRows = pendingReloadRows.intersection(represented)
            if !visibleReloadRows.isEmpty {
                tableView.reloadData(
                    forRowIndexes: visibleReloadRows,
                    columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
                )
                rebindRepresentedCells(at: visibleReloadRows)
            }
        }
        pendingReloadRows.removeAll()
        pendingHeightRows.removeAll()
    }

    private func restore(
        anchor: RepoExplorerTableScrollAnchor?,
        tablePlan: RepoExplorerNativeTableUpdatePlan? = nil,
        priorSnapshot: RepoExplorerMaterializationSnapshot?
    ) {
        guard let anchor, let snapshot else { return }
        if anchor.wasAtTop {
            guard scrollView.contentView.documentVisibleRect.minY > 0 else { return }
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            explicitScrollRestorationCount += 1
            return
        }
        let targetRowID: RepoExplorerRowID?
        if let sameIdentity = rowID(for: anchor.identity, in: snapshot) {
            targetRowID = sameIdentity
        } else if let nextVisible = anchor.followingIdentities.lazy.compactMap({
            self.rowID(for: $0, in: snapshot)
        }).first {
            targetRowID = nextVisible
        } else if case .membership(let membership)? = tablePlan,
            priorSnapshot?.rowIndexByID[anchor.rowID] != nil
        {
            targetRowID = membership.anchorFallbacks.targetRowID(
                forRemovedRowID: anchor.rowID
            )
        } else {
            targetRowID = nil
        }
        guard let targetRowID else { return }
        if currentTopVisibleAnchor?.rowID == targetRowID,
            currentTopVisibleAnchor?.offset == anchor.offset
        {
            return
        }
        explicitScrollRestorationCount += 1
        scroll(to: targetRowID, offset: anchor.offset)
    }

    private func rowID(
        for identity: RepoExplorerRowAnchorIdentity,
        in snapshot: RepoExplorerMaterializationSnapshot
    ) -> RepoExplorerRowID? {
        switch identity {
        case .pane(let paneID):
            snapshot.navigationIndex.firstRowID(for: .pane(paneID))
        case .row(let rowID):
            snapshot.rowIndexByID[rowID] == nil ? nil : rowID
        }
    }

    func displayedRow(_ row: RepoExplorerMaterializedRow) -> RepoExplorerMaterializedRow {
        guard row.id == selectedVariantRowID else { return row }
        return row.displayingPaneVariant(.expanded)
    }

    private func scroll(toRowAt rowIndex: Int, offset: CGFloat) {
        guard tableView.numberOfRows > rowIndex else { return }
        let rowRect = tableView.rect(ofRow: rowIndex)
        let documentVisibleRect = scrollView.contentView.documentVisibleRect
        let maximumOriginY = max(0, tableView.bounds.height - documentVisibleRect.height)
        let requestedOriginY = rowRect.minY - offset
        scrollView.contentView.scroll(
            to: NSPoint(
                x: documentVisibleRect.minX,
                y: min(maximumOriginY, max(0, requestedOriginY))
            )
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        forceTableAndScrollLayout()
    }

    private func forceTableAndScrollLayout() {
        forcedLayoutPassCount += 1
        scrollView.layoutSubtreeIfNeeded()
        tableView.layoutSubtreeIfNeeded()
    }

    private func boundsDidChange() {
        guard !isDetached else { return }
        let anchor = currentTopVisibleAnchor
        let previousWidthRevision = widthRevision
        updateWidthRevisionIfNeeded()
        if widthRevision != previousWidthRevision {
            heightByRowID.removeAll(keepingCapacity: true)
            let visibleWrappingRows = IndexSet(
                representedRowIndexes().filter { rowIndex in
                    snapshot?.rows[safe: rowIndex]?.layout.requiresVisibleWidthMeasurement == true
                }
            )
            if !visibleWrappingRows.isEmpty {
                tableView.noteHeightOfRows(withIndexesChanged: visibleWrappingRows)
                restore(anchor: anchor, priorSnapshot: snapshot)
            }
        }
        rebindRepresentedCellsAfterSuspension()
        scheduleViewportPublication()
    }

    func scheduleViewportPublication() {
        guard !isDetached, let visibleGeneration else { return }
        viewportSequence &+= 1
        let scheduledSequence = viewportSequence
        viewportTask?.cancel()
        viewportTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled,
                self.viewportSequence == scheduledSequence,
                self.visibleGeneration == visibleGeneration
            else { return }
            self.publishVisibleWorktreeIDs()
        }
    }

    private func invalidateScheduledViewportPublication() {
        viewportSequence &+= 1
        viewportTask?.cancel()
        viewportTask = nil
    }

    private func publishVisibleWorktreeIDs() {
        guard let snapshot else {
            clearViewportDemand()
            return
        }
        if let visibleGeneration {
            RepoExplorerNativeVisibleProjectionReadback.stampExpectedVisibleProjection(
                in: tableView,
                snapshot: snapshot,
                materializationGeneration: visibleGeneration
            )
        }
        let worktreeIDs = Set(
            representedRowIndexes().compactMap { rowIndex in
                snapshot.rows[safe: rowIndex]?.representedWorktreeID
            }
        )
        let paneIDs = Set(
            representedRowIndexes().compactMap { rowIndex -> UUID? in
                guard let row = snapshot.rows[safe: rowIndex], case .pane(let pane) = row.presentation else {
                    return nil
                }
                return pane.destination.paneId
            }
        )
        let repositoryIDs = Set(
            representedRowIndexes().compactMap { rowIndex -> UUID? in
                guard let row = snapshot.rows[safe: rowIndex],
                    case .groupHeader(let group) = row.presentation,
                    group.presentsRepositoryActivity,
                    group.repoIDs.count == 1
                else { return nil }
                return group.repoIDs[0]
            }
        )
        let settledUpdateAttemptByRepositoryID = Dictionary(
            uniqueKeysWithValues: representedRowIndexes().compactMap { rowIndex -> (UUID, UUID)? in
                guard let row = snapshot.rows[safe: rowIndex],
                    case .groupHeader(let group) = row.presentation,
                    group.presentsRepositoryActivity,
                    let progress = group.repositoryFactUpdateProgress,
                    progress.phase == .settled,
                    group.repoIDs == [progress.repoId]
                else { return nil }
                return (progress.repoId, progress.attemptId)
            }
        )
        if paneIDs != currentVisibleSnapshot.paneIDs
            || worktreeIDs != currentVisibleSnapshot.worktreeIDs
            || repositoryIDs != currentVisibleSnapshot.repositoryIDs
            || settledUpdateAttemptByRepositoryID
                != currentVisibleSnapshot.settledUpdateAttemptByRepositoryID
        {
            advanceVisibleTarget(
                materializationGeneration: visibleGeneration ?? 0,
                worktreeIDs: worktreeIDs,
                paneIDs: paneIDs,
                repositoryIDs: repositoryIDs,
                settledUpdateAttemptByRepositoryID: settledUpdateAttemptByRepositoryID
            )
        }
        guard lastPublishedVisibleSnapshot != currentVisibleSnapshot else { return }
        lastPublishedVisibleSnapshot = currentVisibleSnapshot
        onVisibleWorktreeSnapshotChange(currentVisibleSnapshot)
    }

    private func clearViewportDemand() {
        guard
            !currentVisibleSnapshot.paneIDs.isEmpty
                || !currentVisibleSnapshot.worktreeIDs.isEmpty
                || !currentVisibleSnapshot.repositoryIDs.isEmpty
                || !currentVisibleSnapshot.settledUpdateAttemptByRepositoryID.isEmpty
        else {
            return
        }
        publishClearedViewportDemand()
    }

    private func publishClearedViewportDemand() {
        advanceVisibleTarget(
            materializationGeneration: visibleGeneration ?? 0,
            worktreeIDs: [],
            repositoryIDs: [],
            settledUpdateAttemptByRepositoryID: [:]
        )
        lastPublishedVisibleSnapshot = currentVisibleSnapshot
        onVisibleWorktreeSnapshotChange(currentVisibleSnapshot)
    }

    private func advanceVisibleTarget(
        materializationGeneration: UInt64,
        worktreeIDs: Set<UUID>,
        paneIDs: Set<UUID> = [],
        repositoryIDs: Set<UUID> = [],
        settledUpdateAttemptByRepositoryID: [UUID: UUID] = [:]
    ) {
        visibleRevision &+= 1
        currentVisibleSnapshot = RepoExplorerVisibleWorktreeSnapshot(
            target: RepoExplorerCommandPresentationTarget(
                materializationHostLifetimeID: materializationHostLifetimeID,
                materializationGeneration: materializationGeneration,
                visibleRevision: visibleRevision
            ),
            worktreeIDs: worktreeIDs,
            repositoryIDs: repositoryIDs,
            paneIDs: paneIDs,
            settledUpdateAttemptByRepositoryID: settledUpdateAttemptByRepositoryID
        )
    }

    func representedRowIndexes() -> IndexSet {
        let range = tableView.rows(in: scrollView.contentView.documentVisibleRect)
        guard range.location != NSNotFound, range.length > 0 else { return [] }
        let upperBound = min(NSMaxRange(range), numberOfRows)
        guard range.location < upperBound else { return [] }
        return IndexSet(integersIn: range.location..<upperBound)
    }

    private func rebindRepresentedCells() {
        rebindRepresentedCells(at: representedRowIndexes())
    }

    private func rebindRepresentedCells(at indexes: IndexSet) {
        guard let snapshot, let visibleGeneration else { return }
        for rowIndex in indexes {
            guard
                let cell = tableView.view(
                    atColumn: 0,
                    row: rowIndex,
                    makeIfNecessary: false
                ) as? RepoExplorerTableRowCell
            else {
                continue
            }
            cell.bind(
                row: displayedRow(snapshot.rows[rowIndex]),
                visibleGeneration: visibleGeneration,
                commandPresentationSnapshot: acceptedCommandPresentationSnapshot
            )
            cell.applyKeyboardPresentation(keyboardPresentation(for: snapshot.rows[rowIndex].id))
        }
        RepoExplorerNativeVisibleProjectionReadback.stampExpectedVisibleProjection(
            in: tableView,
            snapshot: snapshot,
            materializationGeneration: visibleGeneration
        )
    }

    private func clearRepresentedCellsForReuse() {
        for rowIndex in representedRowIndexes() {
            guard
                let cell = tableView.view(
                    atColumn: 0,
                    row: rowIndex,
                    makeIfNecessary: false
                ) as? RepoExplorerTableRowCell
            else {
                continue
            }
            cell.clearBindingForReuse()
        }
    }

    private func updateTableFrame() {
        tableFrameUpdateCount += 1
        let fallbackContentHeight = snapshot?.fallbackContentHeight ?? 0
        let selectedHeightDelta: CGFloat
        if let selectedVariantRowID,
            let selectedRow = snapshot?.row(id: selectedVariantRowID)
        {
            selectedHeightDelta =
                displayedRow(selectedRow).layout.metrics.fallbackHeight
                - selectedRow.layout.metrics.fallbackHeight
        } else {
            selectedHeightDelta = 0
        }
        let visibleMeasurementDelta = heightByRowID.reduce(into: CGFloat.zero) { delta, entry in
            guard let row = snapshot?.row(id: entry.key) else { return }
            delta += max(0, entry.value.height - row.layout.metrics.fallbackHeight)
        }
        let documentHeight = max(
            scrollView.contentView.bounds.height,
            fallbackContentHeight + selectedHeightDelta + visibleMeasurementDelta
        )
        tableView.frame = NSRect(
            x: 0,
            y: 0,
            width: max(scrollView.contentView.bounds.width, tableView.frame.width),
            height: documentHeight
        )
    }

    private func updateWidthRevisionIfNeeded() {
        widthRevision = normalizedWidthRevision()
    }

    private func normalizedWidthRevision() -> Int {
        let backingScale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        return Int((scrollView.contentView.bounds.width * backingScale).rounded())
    }

    private func availableContentWidth(for row: RepoExplorerMaterializedRow) -> CGFloat {
        max(
            0,
            scrollView.contentView.bounds.width
                - row.layout.metrics.leadingInset
                - row.layout.metrics.trailingInset
        )
    }
}

extension RepoExplorerTableMaterializer {
    func applyPaneVariantSelection(from previousRowID: RepoExplorerRowID?, to rowID: RepoExplorerRowID?) {
        guard previousRowID != rowID, let snapshot else { return }
        let anchor = currentTopVisibleAnchor
        selectedVariantRowID = rowID
        if let previousRowID { heightByRowID.removeValue(forKey: previousRowID) }
        if let rowID { heightByRowID.removeValue(forKey: rowID) }
        updateTableFrame()
        var affected = IndexSet()
        if let previousRowID, let previousIndex = snapshot.rowIndexByID[previousRowID] {
            affected.insert(previousIndex)
        }
        if let rowID, let selectedIndex = snapshot.rowIndexByID[rowID] {
            affected.insert(selectedIndex)
        }
        if !affected.isEmpty {
            tableView.noteHeightOfRows(withIndexesChanged: affected)
            let visibleAffected = affected.intersection(representedRowIndexes())
            if !visibleAffected.isEmpty {
                tableView.reloadData(
                    forRowIndexes: visibleAffected,
                    columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
                )
            }
        }
        forceTableAndScrollLayout()
        restore(anchor: anchor, priorSnapshot: snapshot)
    }
}

extension Array {
    fileprivate subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension RepoExplorerTableMaterializer {
    /// A resume that runs before the re-shown view is laid out sees no represented rows, so
    /// the cells suspension cleared would stay blank until a scroll. Keep the rebind pending
    /// until a geometry change makes rows representable.
    fileprivate func rebindRepresentedCellsAfterSuspension() {
        guard !isDetached, needsRepresentedRebindAfterLayout, isDemandActive else { return }
        let representedRows = representedRowIndexes()
        guard !representedRows.isEmpty else { return }
        needsRepresentedRebindAfterLayout = false
        rebindRepresentedCells(at: representedRows)
    }
}
