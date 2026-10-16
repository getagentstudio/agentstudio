import Foundation
import Testing

@testable import AgentStudioBridge

struct ProductFileDescriptorBatchObservation: Sendable {
    let begin: BridgeProductBatchBeginFrame
    let parts: [BridgeProductBatchPart]

    var rows: [BridgeProductFileBatchRow] {
        get throws {
            try parts.compactMap { part in
                guard case .put(let key, _, let value) = part,
                    key != BridgeProductFileMemberStatusRecord.recordKey
                else { return nil }
                return try JSONDecoder().decode(
                    BridgeProductFileBatchRow.self, from: JSONEncoder().encode(value))
            }
        }
    }
}

actor ProductFileDescriptorBatchCollector {
    private(set) var batches: [ProductFileDescriptorBatchObservation] = []
    func append(_ batch: ProductFileDescriptorBatchObservation) { batches.append(batch) }
}

struct ProductFileDescriptorDeliveryContext: Sendable {
    let source: BridgePaneProductFileMetadataSource
    let subscription: BridgeProductSubscriptionSnapshot
    let demand: BridgePaneProductFileViewDemand
    let admission: BridgeProductAdmissionContext
    let delivery: FileChangeDeliveryFixture

    func captureAndDeliver() async throws -> ProductFileDescriptorBatchObservation {
        let snapshot = try #require(
            await source.captureKeyedSnapshot(
                subscriptionId: subscription.subscriptionId, demand: demand, productAdmission: admission))
        try await delivery.seal(snapshot)
        let firstFrame = try await delivery.nextFrame()
        guard case .batch(.begin(let begin)) = firstFrame else {
            throw ProductFileSourceFixtureError.invalidControlRequest
        }
        var parts: [BridgeProductBatchPart] = []
        for _ in 0..<begin.partCount {
            let frame = try await delivery.nextFrame()
            guard case .batch(.part(let part)) = frame else {
                throw ProductFileSourceFixtureError.invalidControlRequest
            }
            parts.append(part.part)
            try await delivery.acknowledge(through: part.deliverySequence)
        }
        let lastFrame = try await delivery.nextFrame()
        guard case .batch(.complete(let complete)) = lastFrame else {
            throw ProductFileSourceFixtureError.invalidControlRequest
        }
        #expect(complete.identity.batchId == begin.identity.batchId)
        return .init(begin: begin, parts: parts)
    }
}

func assertProductFileDescriptorChange(
    _ update: ProductFileDescriptorBatchObservation,
    certificate: ProductFileDescriptorBatchObservation,
    demandedPath: String
) throws {
    #expect(certificate.begin.mode == .snapshot)
    #expect(try certificate.rows.allSatisfy { $0.readDescriptor == nil })
    #expect(update.begin.mode == .change)
    #expect(update.begin.baseRevision == certificate.begin.targetRevision)
    #expect(update.begin.targetRevision > certificate.begin.targetRevision)
    let rows = try update.rows
    #expect(rows.count == 1)
    #expect(rows.first?.displayKey == demandedPath)
    #expect(rows.first?.readDescriptor != nil)
    for part in update.parts {
        guard case .put(let key, let revision, _) = part else {
            Issue.record("Descriptor enrichment must not delete or evict an unrelated File key")
            continue
        }
        #expect(key.hasSuffix("/\(demandedPath)"))
        #expect(revision > certificate.begin.targetRevision)
    }
}
