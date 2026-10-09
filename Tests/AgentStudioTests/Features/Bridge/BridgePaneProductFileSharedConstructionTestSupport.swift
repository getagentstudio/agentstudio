import Foundation
import Testing

@testable import AgentStudioBridge

struct ProductFileInventoryObservation: Sendable {
    let progress: BridgePaneProductFileInventoryProgress
    let inventory: BridgeWorktreeFileKeyedSnapshot?
    var finalWindow: Bool { progress.finalWindow }
    var inventoryRowCount: Int? { inventory?.records.count }
    var source: BridgeProductFileSourceIdentity { progress.source }
    var rows: [BridgeProductFileTreeRow] { canonicalRows(in: inventory, paths: progress.updatedPaths) }
}

struct ProductFileChangeObservation: Sendable {
    let change: BridgePaneProductFileInventoryChange
    let inventory: BridgeWorktreeFileKeyedSnapshot?
    var source: BridgeProductFileSourceIdentity { change.source }
    var rows: [BridgeProductFileTreeRow] { canonicalRows(in: inventory, paths: change.updatedPaths) }
}

enum ProductFileSourceObservation: Sendable {
    case sourceAccepted(BridgeProductFileSourceIdentity)
    case inventoryProgress(ProductFileInventoryObservation)
    case inventoryChanged(ProductFileChangeObservation)
    case statusChanged(BridgeProductFileSourceIdentity, BridgeProductFileMemberStatusRecord?)
    case descriptorReady(BridgeProductFileDescriptorReadyPayload)
    case invalidated(BridgePaneProductFileDescriptorInvalidation)

    var fact: BridgePaneProductFileSourceFact {
        switch self {
        case .sourceAccepted(let source): .sourceAccepted(source)
        case .inventoryProgress(let observation): .inventoryProgress(observation.progress)
        case .inventoryChanged(let observation): .inventoryChanged(observation.change)
        case .statusChanged(let source, _): .statusChanged(source)
        case .descriptorReady(let payload): .descriptorReady(payload)
        case .invalidated(let invalidation): .invalidated(invalidation)
        }
    }
    var availableDescriptorForTest: BridgeProductFileContentDescriptor? {
        guard case .descriptorReady(let ready) = self,
            case .available(let descriptor) = ready.availability
        else { return nil }
        return descriptor
    }
    var sourceForTest: BridgeProductFileSourceIdentity { fact.sourceIdentity }
    var inventoryProgressRowsForTest: [BridgeProductFileTreeRow] {
        guard case .inventoryProgress(let progress) = self else { return [] }
        return progress.rows
    }
    var inventoryChangedUpsertRowsForTest: [BridgeProductFileTreeRow] {
        guard case .inventoryChanged(let change) = self else { return [] }
        return change.rows
    }
}

actor ProductFileSourceFactCollector {
    private(set) var events: [ProductFileSourceObservation] = []
    private var treeWindowWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    func append(_ fact: BridgePaneProductFileSourceFact, source: BridgePaneProductFileMetadataSource) async {
        let inventory = await productFileCanonicalInventory(source: source, identity: fact.sourceIdentity)
        let observation: ProductFileSourceObservation =
            switch fact {
            case .sourceAccepted(let source): .sourceAccepted(source)
            case .inventoryProgress(let progress): .inventoryProgress(.init(progress: progress, inventory: inventory))
            case .inventoryChanged(let change): .inventoryChanged(.init(change: change, inventory: inventory))
            case .statusChanged(let source): .statusChanged(source, inventory?.memberStatus.record)
            case .descriptorReady(let payload): .descriptorReady(payload)
            case .invalidated(let invalidation): .invalidated(invalidation)
            }
        events.append(observation)
        let treeWindowCount = events.count { if case .inventoryProgress = $0 { true } else { false } }
        let readyWaiters = treeWindowWaiters.filter { $0.count <= treeWindowCount }
        treeWindowWaiters.removeAll { $0.count <= treeWindowCount }
        for waiter in readyWaiters { waiter.continuation.resume() }
    }
    func removeAll() { events.removeAll(keepingCapacity: false) }
    func waitForTreeWindowCount(_ expectedCount: Int) async {
        let treeWindowCount = events.count { if case .inventoryProgress = $0 { true } else { false } }
        guard treeWindowCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            treeWindowWaiters.append((count: expectedCount, continuation: continuation))
        }
    }
}

func productFileCanonicalInventory(
    source: BridgePaneProductFileMetadataSource, identity: BridgeProductFileSourceIdentity
) async -> BridgeWorktreeFileKeyedSnapshot? {
    let contexts = await source.contextBySubscriptionId
    guard let context = contexts.values.first(where: { $0.productSource == identity }) else { return nil }
    return await context.manifestIndex.captureKeyedSnapshot()
}

private func canonicalRows(
    in inventory: BridgeWorktreeFileKeyedSnapshot?, paths: Set<String>
) -> [BridgeProductFileTreeRow] {
    guard let inventory else { return [] }
    do {
        return try inventory.records.filter { paths.contains($0.row.path) }.map {
            try BridgePaneProductFileMetadataEncoding.productTreeRow($0.row)
        }
    } catch {
        Issue.record("Canonical inventory contains an invalid File row: \(error)")
        return []
    }
}
