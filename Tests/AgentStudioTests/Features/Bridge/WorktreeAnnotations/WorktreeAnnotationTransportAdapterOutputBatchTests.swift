import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioBridge

@MainActor
@Suite("Worktree annotation transport exact output batch", .serialized)
struct WorktreeAnnotationTransportAdapterOutputBatchTests {
    @Test("New unlisted comments and handled Pending comments never replace the displayed set")
    func displayedBatchSurvivesNewAndHandledCommentsInCanonicalOrder() async throws {
        let effect = TransportTestOutputEffect(outcome: .succeeded(destinationPath: nil))
        let harness = try await makeTransportAdapterHarness(outputEffect: effect)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let first = try await createSavedOutputRoot(body: "First displayed", editToken: "first", harness: harness)
        let second = try await createSavedOutputRoot(
            sessionID: first.sessionID, body: "Second displayed", editToken: "second", harness: harness)
        // Request order is deliberately reversed: native canonical order remains authoritative.
        let command = try exactOutputCommand(sessionID: first.sessionID, messages: [second.message, first.message])
        _ = try await createSavedOutputRoot(
            sessionID: first.sessionID, body: "New unlisted", editToken: "new", harness: harness)
        for requestID in ["displayed-original", "displayed-after-handled"] {
            let outcome = await harness.adapter.apply(
                command, surface: .file,
                correlation: try makeAnnotationCorrelation(requestID: requestID),
                productAdmission: harness.productAdmission
            )
            guard case .output(.succeeded(let summary)) = outcome.status else {
                Issue.record("Expected unchanged listed batch, got \(outcome.status)")
                return
            }
            #expect(summary.messageCount == 2)
        }
        let requests = await effect.requests
        #expect(requests.count == 2)
        for request in requests {
            let snapshot = try WorktreeAnnotationBatchProjector.decodeJSON(request.exactBytes)
            #expect(snapshot.entries.map(\.messageID) == [first.message.id, second.message.id])
            #expect(snapshot.entries.map(\.bodyMarkdown) == ["First displayed", "Second displayed"])
        }
        let detail = try await persistedDetail(sessionID: first.sessionID, harness: harness)
        #expect(
            detail.threads.flatMap(\.messages).filter(\.handled).map(\.id) == [first.message.id, second.message.id])
    }

    @Test(
        "Markdown and JSON retain the stored excerpt while exporting relocated placement",
        arguments: ["clipboardMarkdown", "jsonFile"])
    func outputRetainsOriginalExcerptAndCurrentPlacement(outputKind: String) async throws {
        let effect = TransportTestOutputEffect(outcome: .succeeded(destinationPath: nil))
        let harness = try await makeTransportAdapterHarness(
            outputEffect: effect,
            sourceBody: "// inserted before original\n1 │ func example() {\n2 │ let value = 1\n3 │ return value\n4 │ }"
        )
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let selected = try await createSavedOutputRoot(
            body: "Relocated output", editToken: "relocated", harness: harness)
        let outcome = await harness.adapter.apply(
            try exactOutputCommand(sessionID: selected.sessionID, messages: [selected.message], outputKind: outputKind),
            surface: .file,
            correlation: try makeAnnotationCorrelation(requestID: "relocated-\(outputKind)"),
            productAdmission: harness.productAdmission
        )
        guard case .output(.succeeded(let summary)) = outcome.status else {
            Issue.record("Expected relocated output, got \(outcome.status)")
            return
        }
        let persisted = try await harness.store.inspectOutputAttempt(attemptID: .init(rawValue: summary.attemptId))
        let snapshot: WorktreeAnnotationBatchSnapshotV2
        switch persisted.canonicalSnapshot {
        case .v2(let document): snapshot = document
        case .v1:
            Issue.record("Expected current v2 batch")
            return
        }
        let entry = try #require(snapshot.entries.first)
        #expect(entry.origin.startLine == 2)
        #expect(entry.origin.endLine == 3)
        #expect(entry.origin.excerpt.map(\.lineNumber) == [2, 3])
        #expect(entry.origin.excerpt.map(\.text) == ["2 │ let value = 1", "3 │ return value"])
        guard case .relocated(let placement) = entry.placement else {
            Issue.record("Expected relocated placement, got \(entry.placement)")
            return
        }
        #expect(placement.startLine == 3)
        #expect(placement.endLine == 4)
        let request = try #require(await effect.lastRequest)
        #expect(request.exactBytes == persisted.attempt.exactBytes)
        if outputKind == "jsonFile" {
            #expect(try WorktreeAnnotationBatchProjector.decodeJSON(request.exactBytes) == snapshot)
        } else {
            let markdown = try #require(String(data: request.exactBytes, encoding: .utf8))
            #expect(markdown.contains("2 │ let value = 1"))
            #expect(markdown.contains("3 │ return value"))
            #expect(markdown.contains("Location: lines 3–4"))
        }
    }

}
