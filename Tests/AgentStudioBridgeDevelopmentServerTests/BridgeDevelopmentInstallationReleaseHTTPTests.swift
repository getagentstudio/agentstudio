import AgentStudioTestSupport
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import AgentStudioBridge
@testable import AgentStudioBridgeDevelopmentServer
@testable import AgentStudioCore

@Suite("Bridge development acknowledged installation release")
struct BridgeDevelopmentInstallationReleaseHTTPTests {
    @MainActor
    @Test("acknowledged release admits a different tab and stale release cannot retire its successor")
    func acknowledgedReleaseAdmitsDifferentTab() async throws {
        // Arrange: real development host, router and a live metadata stream.
        let repository = try await FilesystemTestGitRepo.create(named: "bridge-http-installation-release")
        defer { FilesystemTestGitRepo.destroy(repository) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repository)
        let paneID = PaneId.generateUUIDv7().uuid
        let dataRoot = FileManager.default.temporaryDirectory.appending(path: "bridge-release-\(paneID.uuidString)")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let runtime = try await makeHTTPDevelopmentProductRuntime(
            dataRoot: dataRoot, paneID: paneID, worktreeRoot: repository
        )
        do {
            try await withBridgeDevelopmentHTTPRouterTestClient(host: runtime.host) { client in
                try await Self.assertReleaseHandoff(client: client, host: runtime.host)
            }
            _ = await runtime.host.shutdown()
            try await runtime.composition.shutdown()
        } catch {
            _ = await runtime.host.shutdown()
            try? await runtime.composition.shutdown()
            throw error
        }
    }

    private static func assertReleaseHandoff(
        client: some TestClientProtocol,
        host: BridgeDevelopmentProductHost
    ) async throws {
        let connection = try await openHTTPProductConnection(client: client)
        let stream = try await startHTTPMetadataStream(host: host, connection: connection, streamID: "release-stream")
        do {
            let _: BridgeProductMetadataStreamAcceptedFrame = try await waitForAcknowledgedMetadataFrame(
                client: client, connection: connection, recorder: stream.recorder
            ) { frame in
                guard case .metadataStreamAccepted(let accepted) = frame else { return nil }
                return accepted
            }
            let successorRequest = ByteBuffer(
                string:
                    #"{"navigationIntent":{"commandId":"open-file-view","commandKind":"activateContext","surface":"file"},"reason":"initial","tabId":"different-tab"}"#
            )
            let refused = try await client.execute(
                uri: "/__bridge-product/bootstrap", method: .post,
                headers: [.contentType: "application/json"], body: successorRequest
            )
            #expect(refused.status == .conflict)
            #expect(
                await host.productSessionOwner.schemeRouter.metadataStreamHasEnded(
                    for: connection.bootstrap.workerInstanceId) == false)

            // Act / Assert: wrong authority and wrong identity cannot release the owner.
            let wrongCapability = try await release(client: client, connection: connection, capability: "invalid")
            #expect(wrongCapability.status == .forbidden)
            let wrongIdentity = try await release(
                client: client, connection: connection, workerInstanceId: "wrong-worker")
            #expect(wrongIdentity.status == .conflict)
            let acknowledged = try await release(client: client, connection: connection)
            try #require(
                acknowledged.status == .noContent, "Acknowledged release must succeed before joining the metadata drain"
            )
            #expect(acknowledged.body.readableBytes == 0)
            try #require(
                await host.productSessionOwner.schemeRouter.metadataStreamHasEnded(
                    for: connection.bootstrap.workerInstanceId),
                "Acknowledged release must end the metadata stream before joining its drain")
            _ = await stream.drain.result

            let successor = try await client.execute(
                uri: "/__bridge-product/bootstrap", method: .post,
                headers: [.contentType: "application/json"], body: successorRequest
            )
            #expect(successor.status == .ok)
            let activeWorker = await host.productSessionOwner.activeInstallation?.bootstrap.workerInstanceId
            #expect(activeWorker != connection.bootstrap.workerInstanceId)
            let stale = try await release(client: client, connection: connection)
            #expect(stale.status == .forbidden || stale.status == .conflict)
            #expect(await host.productSessionOwner.activeInstallation?.bootstrap.workerInstanceId == activeWorker)
        } catch {
            _ = await host.shutdown()
            _ = await stream.drain.result
            throw error
        }
    }

    private static func release(
        client: some TestClientProtocol,
        connection: HTTPProductConnection,
        capability: String? = nil,
        workerInstanceId: String? = nil
    ) async throws -> TestResponse {
        let capabilityHeader = try #require(HTTPField.Name(BridgeProductWireContract.capabilityHeaderName))
        return try await client.execute(
            uri: "/__bridge-product/release", method: .post,
            headers: [.contentType: "application/json", capabilityHeader: capability ?? connection.capability],
            body: ByteBuffer(
                data: try JSONSerialization.data(withJSONObject: [
                    "paneSessionId": connection.bootstrap.paneSessionId,
                    "workerInstanceId": workerInstanceId ?? connection.bootstrap.workerInstanceId,
                ]))
        )
    }
}
