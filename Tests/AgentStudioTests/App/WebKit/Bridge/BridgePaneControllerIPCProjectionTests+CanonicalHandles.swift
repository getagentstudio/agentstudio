import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

extension WebKitSerializedTests.BridgePaneControllerIPCProjectionTests {
    @Test(
        "Bridge open returns a canonical handle reusable through the real IPC server",
        arguments: ["bridge.diff.load", "bridge.fileView.open"]
    )
    func bridgeOpenHandleResolvesToCreatedPane(method: String) async throws {
        // Arrange — use the App's live server and production Bridge adapter,
        // rather than the transport suite's FakeBridgePort result emitter.
        let repositoryURL = try await FilesystemTestGitRepo.create(named: "ipc-bridge-canonical-handles")
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repositoryURL)
        let harness = try await SessionsVerticalHarness.make()
        do {
            let repository = harness.commandHarness.store.addRepo(at: repositoryURL)
            let worktree = try #require(repository.worktrees.first(where: { $0.isMainWorktree }))
            let correlationId = UUIDv7.generate()
            let parameters = JSONValue.object([
                "worktreeId": .string(worktree.id.uuidString),
                "correlationId": .string(correlationId.uuidString),
            ])

            // Act — retain exactly the wire handle returned by the open call.
            let paneId: UUID
            let returnedHandle: String
            if method == "bridge.diff.load" {
                let opened: IPCBridgeReviewOpenResult = try await harness.decoded(method: method, params: parameters)
                paneId = opened.paneId
                returnedHandle = opened.handle
                #expect(opened.correlationId == correlationId)
            } else {
                let opened: IPCBridgeFileViewOpenResult = try await harness.decoded(method: method, params: parameters)
                paneId = opened.paneId
                returnedHandle = opened.handle
                #expect(opened.correlationId == correlationId)
            }
            let canonicalSnapshot: IPCPaneSnapshotResult = try await harness.decoded(
                method: "pane.snapshot", params: .object(["handle": .string(paneId.uuidString)]))
            #expect(canonicalSnapshot.pane.id == paneId)
            #expect(canonicalSnapshot.pane.contentKind == .bridgePanel)
            let snapshotResponse = try await harness.response(
                method: "pane.snapshot", params: .object(["handle": .string(returnedHandle)]))

            // Assert — both the public selector and the real follow-up admission
            // must identify the same pane, without repairing the client's handle.
            try #require(
                snapshotResponse.error == nil,
                "Returned handle was refused: \(returnedHandle), error: \(String(describing: snapshotResponse.error))")
            let snapshotValue = try #require(snapshotResponse.result)
            let snapshot = try JSONDecoder().decode(
                IPCPaneSnapshotResult.self, from: JSONEncoder().encode(snapshotValue))
            #expect(snapshot.pane.id == paneId)
            #expect(snapshot.pane.contentKind == .bridgePanel)
            #expect(returnedHandle == paneId.uuidString)
            #expect(
                try IPCTargetSelector.parse(returnedHandle, expectedKind: .pane)
                    == .canonical(kind: .pane, id: paneId))
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }
}
