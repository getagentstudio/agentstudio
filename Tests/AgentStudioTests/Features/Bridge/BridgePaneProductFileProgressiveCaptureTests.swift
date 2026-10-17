import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("File progressive construction capture")
struct BridgePaneProductFileProgressiveCaptureTests {
    @Test("a demanded descriptor cannot hold later inventory windows or the certifying snapshot")
    func descriptorFollowsCertifiedInventory() async throws {
        let fixture = try ProductFileSourceFixture(fileCount: 3)
        defer { fixture.remove() }
        let firstProgress = HeldStep<FileInventoryProgress>("First File inventory certificate or descriptor work")
        firstProgress.release()
        let descriptorHeld = HeldStep<String>("File descriptor materialization after inventory")
        defer { descriptorHeld.release() }
        let collector = ProductFileSourceFactCollector()
        let source = fixture.makeSource(
            sharedSnapshotBuilder: { request, preparation, publisher in
                try await publisher.publishPreparation(preparation)
                let preparedRequest = BridgeWorktreeFileMaterializationRequest(
                    rootURL: request.rootURL,
                    openedSource: request.openedSource.withIgnorePolicy(preparation.ignorePolicy))
                var ordinal = 0
                for try await batch in BridgeWorktreeFileMaterializer.materializeTreeRowWindows(
                    request: preparedRequest, afterCount: 0, windowSize: 2)
                {
                    try await publisher.append(
                        .init(
                            ordinal: ordinal, startIndex: batch.startIndex,
                            discoveredRowCount: batch.discoveredRowCount, isFinalWindow: batch.isFinalWindow,
                            rows: batch.rows, retainedByteCount: 256))
                    ordinal += 1
                }
                return .init()
            },
            descriptorMaterializer: { request in
                try await firstProgress.arrive(.descriptorStarted)
                try await descriptorHeld.arrive(request.relativePath)
                return try await BridgePaneProductFileContentSource.materialize(request)
            })
        let subscription = try fixture.openSnapshot()
        let demand = try fixture.viewDemand()
        let openingAndEnrichment = Task {
            try await source.open(
                subscription: subscription, productAdmission: fixture.productAdmission.context
            ) { event in
                await collector.append(event, source: source)
                // Admit the real selected-path demand before enumeration discovers that path.
                if case .sourceAccepted = event {
                    try await source.applyViewDemand(
                        subscriptionId: subscription.subscriptionId, demand: demand,
                        productAdmission: fixture.productAdmission.context, forceRecapture: false
                    ) { demandEvent in await collector.append(demandEvent, source: source) }
                }
            }
            if let inventory = await source.captureKeyedSnapshot(
                subscriptionId: subscription.subscriptionId, demand: demand,
                productAdmission: fixture.productAdmission.context)
            {
                try await firstProgress.arrive(
                    .inventoryCertified(
                        rowCount: inventory.records.count,
                        mode: try sealProductFileSourceCapture(inventory, demand: demand).mode))
            }
            // The existing post-open consumer reconciles enrichment after inventory publication.
            try await source.applyViewDemand(
                subscriptionId: subscription.subscriptionId, demand: demand,
                productAdmission: fixture.productAdmission.context, forceRecapture: true
            ) { event in await collector.append(event, source: source) }
        }
        let progress = try await firstProgress.firstArrival()
        #expect(progress == .inventoryCertified(rowCount: 3, mode: .snapshot))
        #expect(try await descriptorHeld.firstArrival() == fixture.demandedPath)
        let inventoryWhileDescriptorHeld = await source.captureKeyedSnapshot(
            subscriptionId: subscription.subscriptionId, demand: demand,
            productAdmission: fixture.productAdmission.context)
        #expect(inventoryWhileDescriptorHeld?.records.count == 3)
        #expect(inventoryWhileDescriptorHeld?.memberStatus.record.status == .ready)
        #expect((await collector.events).compactMap(\.availableDescriptorForTest).isEmpty)
        descriptorHeld.release()
        try await openingAndEnrichment.value
        #expect((await collector.events).compactMap(\.availableDescriptorForTest).count == 1)
        await source.cancel(subscriptionId: subscription.subscriptionId)
    }

    @Test("real construction exposes non-pruning first rows before its completing snapshot")
    func firstRowsPrecedeCompletingSnapshot() async throws {
        let fixture = try ProductFileSourceFixture(fileCount: 3)
        defer { fixture.remove() }
        let constructionHeld = HeldStep<[String]>("File construction after its first real row window")
        let firstWindowReceived = HeldStep<[String]>("File source indexed its first construction window")
        defer {
            constructionHeld.release()
            firstWindowReceived.release()
        }
        let source = fixture.makeSource(
            sharedSnapshotBuilder: { request, preparation, publisher in
                try await publisher.publishPreparation(preparation)
                let preparedRequest = BridgeWorktreeFileMaterializationRequest(
                    rootURL: request.rootURL,
                    openedSource: request.openedSource.withIgnorePolicy(preparation.ignorePolicy))
                var ordinal = 0
                for try await batch in BridgeWorktreeFileMaterializer.materializeTreeRowWindows(
                    request: preparedRequest, afterCount: 0, windowSize: 2)
                {
                    try await publisher.append(
                        .init(
                            ordinal: ordinal, startIndex: batch.startIndex,
                            discoveredRowCount: batch.discoveredRowCount, isFinalWindow: batch.isFinalWindow,
                            rows: batch.rows, retainedByteCount: 256))
                    if ordinal == 0 {
                        try await constructionHeld.arrive(batch.rows.map(\.path))
                    }
                    ordinal += 1
                }
                return .init()
            })
        let subscription = try fixture.openSnapshot()
        let demand = try fixture.viewDemand(foregroundPaths: [])
        let opening = Task {
            try await source.open(
                subscription: subscription, productAdmission: fixture.productAdmission.context
            ) { event in
                if case .inventoryProgress(let window) = event, window.updatedPaths.contains(fixture.demandedPath) {
                    try await firstWindowReceived.arrive(window.updatedPaths.sorted())
                }
            }
        }
        let constructedPaths = try await constructionHeld.firstArrival()
        let indexedPaths = try await firstWindowReceived.firstArrival()
        #expect(indexedPaths == constructedPaths)
        #expect(indexedPaths.count == 2)
        try await source.applyViewDemand(
            subscriptionId: subscription.subscriptionId, demand: demand,
            productAdmission: fixture.productAdmission.context, forceRecapture: false
        ) { _ in }
        let partial = await source.captureKeyedSnapshot(
            subscriptionId: subscription.subscriptionId, demand: demand,
            productAdmission: fixture.productAdmission.context)

        #expect(partial != nil)
        if let partial {
            #expect(partial.records.map(\.row.path) == indexedPaths)
            #expect(!partial.isEnumerationComplete)
            #expect(partial.memberStatus.record.status == .loading)
            #expect(partial.memberStatus.record.branchName == "main")
            #expect(try sealProductFileSourceCapture(partial, demand: demand).mode == .coverage)
        }
        firstWindowReceived.release()
        constructionHeld.release()
        try await opening.value
        let complete = try #require(
            await source.captureKeyedSnapshot(
                subscriptionId: subscription.subscriptionId, demand: demand,
                productAdmission: fixture.productAdmission.context))
        #expect(complete.records.count == 3)
        #expect(complete.isEnumerationComplete)
        #expect(complete.records.map(\.row.path).starts(with: indexedPaths))
        #expect(complete.memberStatus.record.status == .ready)
        #expect(complete.memberStatus.record.branchName == "main")
        #expect(complete.memberStatus.record.staged == 2)
        #expect(complete.memberStatus.record.unstaged == 1)
        #expect(complete.memberStatus.record.untracked == 3)
        #expect(try sealProductFileSourceCapture(complete, demand: demand).mode == .snapshot)
        #expect(try sealProductFileSourceCapture(complete, demand: demand).parts.count == 4)
        await source.cancel(subscriptionId: subscription.subscriptionId)
    }
}

private enum FileInventoryProgress: Equatable, Sendable {
    case descriptorStarted
    case inventoryCertified(rowCount: Int, mode: BridgeProductBatchMode)
}
