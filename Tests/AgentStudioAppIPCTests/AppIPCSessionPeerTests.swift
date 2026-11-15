import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Synchronization
import Testing

@Suite("Session peer attribution")
struct AppIPCSessionPeerTests {
    @Test("token and request-local claim registrations preserve the captured peer")
    func bothSessionRoutesCarryPeer() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let port = RecordingSessionsPort()
        let admission = AppIPCPaneClaimAdmission(membershipRefusal: { _ in nil })
        let registrations = try fixture.registrations(sessionsPort: port, paneClaimAdmission: admission)
        let peer = AppIPCPeerProcess(pid: 42, pidVersion: 17)
        let principal = IPCPrincipal(
            principalId: UUIDv7.generate(), runtimeId: fixture.runtimeId, accessMode: .agentStudioOnly,
            kind: .spawnedPaneAgent(boundPaneId: fixture.paneId.uuidString, boundWorkspaceId: fixture.workspaceId),
            approvalAuthority: .noApprovalAuthority)
        let event = IPCSessionEventIdentity(
            name: .sessionStart, conversationId: "main", turnId: nil, requestId: nil,
            toolId: nil, subagentId: nil, occurrenceId: UUIDv7.generate())
        let provider = IPCSessionProviderIdentity(identifier: "claude", version: "1", mode: "interactive")
        _ = try await fixture.registration(named: "session.event", in: registrations).invoke(
            parameters: fixture.jsonValue(
                IPCSessionEventParams(
                    handle: "self", provider: provider, event: event, correlationId: UUIDv7.generate())),
            connectionContext: fixture.connectionContext(principal: principal, peerProcess: peer),
            targetResolutionTools: fixture.targetResolutionTools(), authorize: { _, _ in })
        let status = IPCSessionStatusParams(
            paneClaim: .init(paneId: fixture.paneId, workspaceId: fixture.workspaceId),
            tokenOutcome: .absent, report: .refusal(reason: .noSessionId), correlationId: UUIDv7.generate())
        _ = try await fixture.registration(named: "session.status", in: registrations).invoke(
            parameters: fixture.jsonValue(status),
            connectionContext: fixture.connectionContext(
                principal: nil, paneClaimAdmission: admission, peerProcess: peer),
            targetResolutionTools: fixture.targetResolutionTools(), authorize: { _, _ in })
        #expect(await port.eventPeers == [peer])
        #expect(await port.statusPeers == [peer])
    }

    @Test("peer capture precedes connection I/O construction and optional token failure still admits a request")
    func acceptCapturesPeerBeforeHandler() async throws {
        let operations = PeerOperationRecorder()
        let port = RecordingSessionsPort()
        let admission = AppIPCPaneClaimAdmission(membershipRefusal: { _ in nil })
        let provider = OrderedPeerCredentialProvider(operations: operations)
        try await withLiveServer(
            makeFixture: {
                try LiveServerFixture(
                    sessionsPort: port, paneClaimAdmission: admission, peerCredentialProvider: provider,
                    makeConnectionIO: { connection in
                        operations.record("handler preparation")
                        return AppIPCConnectionIO.live(connection)
                    })
            },
            body: { fixture in
                try fixture.server.start()
                let connection = try await connectWithoutBlockingCooperativePool(
                    socketPath: fixture.paths.socketURL.path)
                defer { connection.close() }
                let params = IPCSessionStatusParams(
                    paneClaim: .init(paneId: fixture.boundPaneId, workspaceId: fixture.workspaceId),
                    tokenOutcome: .absent, report: .refusal(reason: .noSessionId), correlationId: UUIDv7.generate())
                try await sendRequestWithoutBlockingCooperativePool(
                    connection: connection,
                    request: JSONRPCClientRequest(
                        id: .number(1), method: "session.status", params: JSONRPCCodec.encodeJSONValue(params)))
                var reader = TestFrameReader()
                let reply = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
                #expect(reply.error == nil)
                #expect(await port.statusPeers == [nil])
                #expect(Array(operations.snapshot.prefix(2)) == ["peer capture", "handler preparation"])
            })
    }
}

private struct OrderedPeerCredentialProvider: PeerCredentialProviding {
    let operations: PeerOperationRecorder

    func credentials(forAcceptedSocket descriptor: Int32) throws -> PeerCredentials {
        operations.record("peer capture")
        return try DarwinPeerCredentialProvider(readPeerProcess: { _ in
            DarwinPeerCredentialProvider.peerProcess(forAcceptedSocket: -1)
        }).credentials(forAcceptedSocket: descriptor)
    }
}

private final class PeerOperationRecorder: Sendable {
    private let values = Mutex<[String]>([])
    func record(_ value: String) { values.withLock { $0.append(value) } }
    var snapshot: [String] { values.withLock { $0 } }
}
