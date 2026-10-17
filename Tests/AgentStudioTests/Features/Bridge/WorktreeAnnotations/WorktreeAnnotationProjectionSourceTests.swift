import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Worktree annotation projection source")
struct WorktreeAnnotationProjectionSourceTests {
    @Test("initial query is surface and source-generation bound and yields page zero")
    func initialQueryValidatesAuthorityAndYieldsPageZero() async throws {
        let harness = try await makeProjectionSourceHarness(messageCount: 1)

        let descriptor = try await harness.source.descriptor(
            for: try projectionQuery(
                sessionID: harness.detail.session.id,
                sourceGeneration: harness.sourceGeneration,
                surface: .file
            ),
            issuing: try projectionControlRequest(surface: .file),
            productAdmission: harness.productAdmission
        )

        #expect(descriptor.surface == .file)
        #expect(descriptor.page.pageOrdinal == 0)
        #expect(descriptor.page.sourceGeneration == harness.sourceGeneration)
        #expect(descriptor.page.expectedSessionCount == 1)
        #expect(descriptor.page.expectedThreadCount == 1)
        #expect(descriptor.page.expectedMessageCount == 1)

        await #expect(
            throws: BridgeAnnotationProjectionSourceError.staleSourceGeneration(
                currentSourceGeneration: harness.sourceGeneration
            )
        ) {
            _ = try await harness.source.descriptor(
                for: try projectionQuery(
                    sessionID: harness.detail.session.id,
                    sourceGeneration: harness.sourceGeneration + 1,
                    surface: .file
                ),
                issuing: try projectionControlRequest(surface: .file),
                productAdmission: harness.productAdmission
            )
        }
        await #expect(throws: BridgeAnnotationProjectionSourceError.unavailable) {
            _ = try await harness.source.descriptor(
                for: try projectionQuery(
                    sessionID: harness.detail.session.id,
                    sourceGeneration: harness.sourceGeneration,
                    surface: .file
                ),
                issuing: try projectionControlRequest(surface: .review),
                productAdmission: harness.productAdmission
            )
        }
    }

    @Test("descriptor is single-use and exact worker and pane authority bound")
    func descriptorIsSingleUseAndAuthorityBound() async throws {
        let harness = try await makeProjectionSourceHarness(messageCount: 1)
        let issuingRequest = try projectionControlRequest(surface: .file)
        let descriptor = try await harness.source.descriptor(
            for: try projectionQuery(
                sessionID: harness.detail.session.id,
                sourceGeneration: harness.sourceGeneration,
                surface: .file
            ),
            issuing: issuingRequest,
            productAdmission: harness.productAdmission
        )

        await #expect(throws: BridgeAnnotationProjectionSourceError.descriptorMismatch) {
            _ = try await harness.source.claim(
                try projectionContentRequest(
                    descriptor: descriptor,
                    paneSessionID: "pane-foreign",
                    workerInstanceID: issuingRequest.workerInstanceId
                )
            )
        }

        let workerBoundDescriptor = try await harness.source.descriptor(
            for: try projectionQuery(
                sessionID: harness.detail.session.id,
                sourceGeneration: harness.sourceGeneration,
                surface: .file
            ),
            issuing: issuingRequest,
            productAdmission: harness.productAdmission
        )
        await #expect(throws: BridgeAnnotationProjectionSourceError.descriptorMismatch) {
            _ = try await harness.source.claim(
                try projectionContentRequest(
                    descriptor: workerBoundDescriptor,
                    paneSessionID: issuingRequest.paneSessionId,
                    workerInstanceID: "worker-foreign"
                )
            )
        }

        let replacement = try await harness.source.descriptor(
            for: try projectionQuery(
                sessionID: harness.detail.session.id,
                sourceGeneration: harness.sourceGeneration,
                surface: .file
            ),
            issuing: issuingRequest,
            productAdmission: harness.productAdmission
        )
        let contentRequest = try projectionContentRequest(
            descriptor: replacement,
            paneSessionID: issuingRequest.paneSessionId,
            workerInstanceID: issuingRequest.workerInstanceId
        )
        _ = try await harness.source.claim(contentRequest)

        await #expect(throws: BridgeAnnotationProjectionSourceError.descriptorMismatch) {
            _ = try await harness.source.claim(contentRequest)
        }
    }

    @Test("continuation requires prior claim and rejects wrong and stale cursors")
    func continuationIsClaimOrderedAndSnapshotBound() async throws {
        let harness = try await makeProjectionSourceHarness(messageCount: 136)
        let issuingRequest = try projectionControlRequest(surface: .file)
        let firstDescriptor = try await harness.source.descriptor(
            for: try projectionQuery(
                sessionID: harness.detail.session.id,
                sourceGeneration: harness.sourceGeneration,
                surface: .file
            ),
            issuing: issuingRequest,
            productAdmission: harness.productAdmission
        )
        let nextCursor = try #require(firstDescriptor.page.nextCursor)
        #expect(!firstDescriptor.page.isLastPage)

        await #expect(throws: BridgeAnnotationProjectionSourceError.invalidCursor) {
            _ = try await harness.source.descriptor(
                for: try projectionQuery(
                    sessionID: harness.detail.session.id,
                    sourceGeneration: harness.sourceGeneration,
                    surface: .file,
                    cursor: nextCursor
                ),
                issuing: issuingRequest,
                productAdmission: harness.productAdmission
            )
        }

        _ = try await harness.source.claim(
            try projectionContentRequest(
                descriptor: firstDescriptor,
                paneSessionID: issuingRequest.paneSessionId,
                workerInstanceID: issuingRequest.workerInstanceId
            )
        )
        await #expect(throws: BridgeAnnotationProjectionSourceError.invalidCursor) {
            _ = try await harness.source.descriptor(
                for: try projectionQuery(
                    sessionID: harness.detail.session.id,
                    sourceGeneration: harness.sourceGeneration,
                    surface: .file,
                    cursor: "wrong-cursor"
                ),
                issuing: issuingRequest,
                productAdmission: harness.productAdmission
            )
        }

        let secondDescriptor = try await harness.source.descriptor(
            for: try projectionQuery(
                sessionID: harness.detail.session.id,
                sourceGeneration: harness.sourceGeneration,
                surface: .file,
                cursor: nextCursor
            ),
            issuing: issuingRequest,
            productAdmission: harness.productAdmission
        )
        #expect(secondDescriptor.page.pageOrdinal == 1)
        #expect(secondDescriptor.page.snapshotID == firstDescriptor.page.snapshotID)

        await #expect(throws: BridgeAnnotationProjectionSourceError.invalidCursor) {
            _ = try await harness.source.descriptor(
                for: try projectionQuery(
                    sessionID: harness.detail.session.id,
                    sourceGeneration: harness.sourceGeneration,
                    surface: .file,
                    cursor: nextCursor
                ),
                issuing: issuingRequest,
                productAdmission: harness.productAdmission
            )
        }
    }

    @Test("new initial query replaces prior snapshot and descriptors")
    func newInitialQueryReplacesPriorReservation() async throws {
        let harness = try await makeProjectionSourceHarness(messageCount: 1)
        let issuingRequest = try projectionControlRequest(surface: .file)
        let query = try projectionQuery(
            sessionID: harness.detail.session.id,
            sourceGeneration: harness.sourceGeneration,
            surface: .file
        )
        let firstDescriptor = try await harness.source.descriptor(
            for: query,
            issuing: issuingRequest,
            productAdmission: harness.productAdmission
        )
        let secondDescriptor = try await harness.source.descriptor(
            for: query,
            issuing: issuingRequest,
            productAdmission: harness.productAdmission
        )

        #expect(firstDescriptor.page.snapshotID != secondDescriptor.page.snapshotID)
        await #expect(throws: BridgeAnnotationProjectionSourceError.descriptorMismatch) {
            _ = try await harness.source.claim(
                try projectionContentRequest(
                    descriptor: firstDescriptor,
                    paneSessionID: issuingRequest.paneSessionId,
                    workerInstanceID: issuingRequest.workerInstanceId
                )
            )
        }
        _ = try await harness.source.claim(
            try projectionContentRequest(
                descriptor: secondDescriptor,
                paneSessionID: issuingRequest.paneSessionId,
                workerInstanceID: issuingRequest.workerInstanceId
            )
        )
    }

    @Test("native source evaluation determines located placement")
    func nativeSourceEvaluationDeterminesLocatedPlacement() async throws {
        let harness = try await makeProjectionSourceHarness(messageCount: 1)
        let issuingRequest = try projectionControlRequest(surface: .file)
        let descriptor = try await harness.source.descriptor(
            for: try projectionQuery(
                sessionID: harness.detail.session.id,
                sourceGeneration: harness.sourceGeneration,
                surface: .file
            ),
            issuing: issuingRequest,
            productAdmission: harness.productAdmission
        )
        var page = try await harness.source.claim(
            try projectionContentRequest(
                descriptor: descriptor,
                paneSessionID: issuingRequest.paneSessionId,
                workerInstanceID: issuingRequest.workerInstanceId
            )
        )
        let records = try collectProjectionRecords(cursor: &page.cursor)
        let messageRecords: [BridgeProductAnnotationProjectionMessageRecord] = records.compactMap { record in
            guard case .message(let message) = record else { return nil }
            return message
        }
        let messageRecord = try #require(messageRecords.first)

        #expect(messageRecord.context.placement == .relocated)
        #expect(messageRecord.context.path == "Sources/RenamedFeature.swift")
        #expect(messageRecord.context.startLine == 2)
        #expect(messageRecord.context.endLine == 2)
        #expect(messageRecord.context.sourceIdentity == "source-current")
    }

    @Test("close invalidates every descriptor and continuation")
    func closeInvalidatesDescriptorsAndCursors() async throws {
        let harness = try await makeProjectionSourceHarness(messageCount: 270)
        let issuingRequest = try projectionControlRequest(surface: .file)
        let firstDescriptor = try await harness.source.descriptor(
            for: try projectionQuery(
                sessionID: harness.detail.session.id,
                sourceGeneration: harness.sourceGeneration,
                surface: .file
            ),
            issuing: issuingRequest,
            productAdmission: harness.productAdmission
        )
        let firstCursor = try #require(firstDescriptor.page.nextCursor)
        _ = try await harness.source.claim(
            try projectionContentRequest(
                descriptor: firstDescriptor,
                paneSessionID: issuingRequest.paneSessionId,
                workerInstanceID: issuingRequest.workerInstanceId
            )
        )
        let outstandingDescriptor = try await harness.source.descriptor(
            for: try projectionQuery(
                sessionID: harness.detail.session.id,
                sourceGeneration: harness.sourceGeneration,
                surface: .file,
                cursor: firstCursor
            ),
            issuing: issuingRequest,
            productAdmission: harness.productAdmission
        )
        let nextCursor = try #require(outstandingDescriptor.page.nextCursor)
        await harness.source.close()

        await #expect(throws: BridgeAnnotationProjectionSourceError.descriptorMismatch) {
            _ = try await harness.source.claim(
                try projectionContentRequest(
                    descriptor: outstandingDescriptor,
                    paneSessionID: issuingRequest.paneSessionId,
                    workerInstanceID: issuingRequest.workerInstanceId
                )
            )
        }
        await #expect(throws: BridgeAnnotationProjectionSourceError.invalidCursor) {
            _ = try await harness.source.descriptor(
                for: try projectionQuery(
                    sessionID: harness.detail.session.id,
                    sourceGeneration: harness.sourceGeneration,
                    surface: .file,
                    cursor: nextCursor
                ),
                issuing: issuingRequest,
                productAdmission: harness.productAdmission
            )
        }
    }
}
