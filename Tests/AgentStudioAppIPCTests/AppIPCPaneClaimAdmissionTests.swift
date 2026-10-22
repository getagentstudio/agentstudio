import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Synchronization
import Testing

@Suite("IPC pane claim admission")
struct AppIPCPaneClaimAdmissionTests {
    @Test("exact membership distinguishes unknown, retired, and another workspace")
    func membershipReasons() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let directory = PaneContextMembershipDirectory()
        directory.install(
            .init(
                workspaceId: fixture.workspaceId, membershipRevision: 1,
                entries: [
                    .init(paneId: .init(existingUUID: fixture.paneId), placement: .layout, ownedDrawerChildIds: [])
                ]))
        let admission = Self.admission(directory)
        let good = IPCPaneClaim(paneId: fixture.paneId, workspaceId: fixture.workspaceId)
        try admission.validate(good)
        #expect(throws: AppIPCPaneClaimError(reason: .paneNotFound)) {
            try admission.validate(.init(paneId: UUIDv7.generate(), workspaceId: fixture.workspaceId))
        }
        #expect(throws: AppIPCPaneClaimError(reason: .otherWorkspace)) {
            try admission.validate(.init(paneId: fixture.paneId, workspaceId: UUIDv7.generate()))
        }
        directory.commit(changed: [], removed: [.init(existingUUID: fixture.paneId)])
        #expect(throws: AppIPCPaneClaimError(reason: .paneRetired)) { try admission.validate(good) }
    }

    @Test("unauthenticated calls reach only the four status methods; every other catalog entry remains token gated")
    func fullInventoryDeniesNonStatus() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let admission = AppIPCPaneClaimAdmission(membershipRefusal: { _ in nil })
        let registrations = try fixture.registrations(paneClaimAdmission: admission)
        let context = fixture.connectionContext(principal: nil, paneClaimAdmission: admission)
        for registration in registrations
        where registration.descriptor.metadata.principalAvailability == .authenticated
            && registration.descriptor.metadata.callIntent != .status
        {
            await #expect(throws: AppIPCPaneClaimError(reason: .intentRequiresToken)) {
                try await registration.invoke(
                    parameters: .object([:]), connectionContext: context,
                    targetResolutionTools: fixture.targetResolutionTools(),
                    authorize: { _, _ in
                        Issue.record("A claim must not reach token authorization")
                    })
            }
        }
        #expect(context.principal == nil)
        #expect(context.authenticationStatus() == .unauthenticated)
    }

    @Test("status admission never upgrades a connection, and the next identity call still fails")
    func requestLocalAuthority() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let port = RecordingSessionsPort()
        let admission = AppIPCPaneClaimAdmission(membershipRefusal: { claim in
            claim.paneId == fixture.paneId && claim.workspaceId == fixture.workspaceId ? nil : .otherWorkspace
        })
        let registrations = try fixture.registrations(sessionsPort: port, paneClaimAdmission: admission)
        let context = fixture.connectionContext(principal: nil, paneClaimAdmission: admission)
        let params = IPCSessionStatusParams(
            paneClaim: .init(paneId: fixture.paneId, workspaceId: fixture.workspaceId),
            tokenOutcome: .rejected, report: .refusal(reason: .noSessionId), correlationId: UUIDv7.generate())
        let registration = try fixture.registration(named: "session.status", in: registrations)
        _ = try await registration.invoke(
            parameters: fixture.jsonValue(params), connectionContext: context,
            targetResolutionTools: fixture.targetResolutionTools(),
            authorize: { _, _ in Issue.record("No token principal") })
        #expect(await port.statusPaneIds == [fixture.paneId])
        #expect(context.principal == nil)
        #expect(context.authenticationStatus() == .unauthenticated)
        await #expect(throws: AppIPCPaneClaimError(reason: .intentRequiresToken)) {
            try await fixture.registration(named: "session.event", in: registrations).invoke(
                parameters: .object([:]), connectionContext: context,
                targetResolutionTools: fixture.targetResolutionTools(), authorize: { _, _ in })
        }
        #expect(await port.eventPaneIds.isEmpty)
    }

    @Test("session writers are refused before ordered writes, while pane writers reach only the exact claimed pane")
    func writerIntentAndExactTarget() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let admission = AppIPCPaneClaimAdmission(membershipRefusal: { _ in nil })
        let port = ClaimRecordingPaneContextPort()
        let registrations = try fixture.registrations(paneClaimAdmission: admission, paneContextPort: port)
        let context = fixture.connectionContext(principal: nil, paneClaimAdmission: admission)
        let claim = IPCPaneClaim(paneId: fixture.paneId, workspaceId: fixture.workspaceId)
        let session = IPCPaneWriterClaim(provider: "codex", conversationId: "protected")
        let attempts: [(String, JSONValue, JSONValue)] = try [
            (
                "pane.title.set",
                fixture.jsonValue(
                    IPCPaneTitleSetParams(
                        handle: "self", paneClaim: claim, text: "new", writeNumber: .init(epoch: 1, counter: 1),
                        correlationId: UUIDv7.generate())),
                fixture.jsonValue(
                    IPCPaneTitleSetParams(
                        handle: "self", writer: session, paneClaim: claim, text: "bad",
                        writeNumber: .init(epoch: 1, counter: 1), correlationId: UUIDv7.generate()))
            ),
            (
                "pane.line.set",
                fixture.jsonValue(
                    IPCPaneLineSetParams(
                        handle: "self", paneClaim: claim, writeNumber: .init(epoch: 1, counter: 1),
                        correlationId: UUIDv7.generate())),
                fixture.jsonValue(
                    IPCPaneLineSetParams(
                        handle: "self", writer: session, paneClaim: claim, writeNumber: .init(epoch: 1, counter: 1),
                        correlationId: UUIDv7.generate()))
            ),
            (
                "pane.writer.claimEpoch",
                fixture.jsonValue(
                    IPCPaneWriterClaimEpochParams(
                        handle: "self", paneClaim: claim, stream: .title, claimId: UUIDv7.generate(),
                        correlationId: UUIDv7.generate())),
                fixture.jsonValue(
                    IPCPaneWriterClaimEpochParams(
                        handle: "self", writer: session, paneClaim: claim, stream: .title, claimId: UUIDv7.generate(),
                        correlationId: UUIDv7.generate()))
            ),
        ]
        for (name, paneParams, sessionParams) in attempts {
            let registration = try fixture.registration(named: name, in: registrations)
            await #expect(throws: AppIPCPaneClaimError(reason: .intentRequiresToken)) {
                try await registration.invoke(
                    parameters: sessionParams, connectionContext: context,
                    targetResolutionTools: fixture.targetResolutionTools(), authorize: { _, _ in })
            }
            _ = try await registration.invoke(
                parameters: paneParams, connectionContext: context,
                targetResolutionTools: fixture.targetResolutionTools(),
                authorize: { _, _ in Issue.record("No token principal") })
        }
        #expect(await port.panes == [fixture.paneId, fixture.paneId, fixture.paneId])
        let otherPane = UUIDv7.generate()
        let otherTarget = IPCPaneTitleSetParams(
            handle: otherPane.uuidString, paneClaim: claim,
            text: "cannot-reach-owner-or-drawer", writeNumber: .init(epoch: 1, counter: 2),
            correlationId: UUIDv7.generate())
        await #expect(throws: AppIPCPaneContextError(reason: .notOwnPane)) {
            try await fixture.registration(named: "pane.title.set", in: registrations).invoke(
                parameters: fixture.jsonValue(otherTarget), connectionContext: context,
                targetResolutionTools: fixture.targetResolutionTools(), authorize: { _, _ in })
        }
        #expect(await port.panes.count == 3)
    }

    @Test("every status method rejects invalid membership before its effect")
    func allStatusMethodsRejectInvalidClaims() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        for reason in [IPCAgentConnectionRefusalReason.paneNotFound, .paneRetired, .otherWorkspace] {
            let admission = AppIPCPaneClaimAdmission(membershipRefusal: { _ in reason })
            let port = ClaimRecordingPaneContextPort()
            let sessions = RecordingSessionsPort()
            let registrations = try fixture.registrations(
                sessionsPort: sessions,
                paneClaimAdmission: admission, paneContextPort: port)
            let context = fixture.connectionContext(principal: nil, paneClaimAdmission: admission)
            for registration in registrations where registration.descriptor.metadata.callIntent == .status {
                let example = try #require(registration.descriptor.metadata.examples.first)
                let data = try example.encodedParameters()
                guard case .object(var fields) = try JSONDecoder().decode(JSONValue.self, from: data) else {
                    Issue.record("Expected typed status parameters")
                    return
                }
                fields["paneClaim"] = try fixture.jsonValue(
                    IPCPaneClaim(paneId: fixture.paneId, workspaceId: fixture.workspaceId))
                let parameters = JSONValue.object(fields)
                await #expect(throws: AppIPCPaneClaimError(reason: reason)) {
                    try await registration.invoke(
                        parameters: parameters, connectionContext: context,
                        targetResolutionTools: fixture.targetResolutionTools(), authorize: { _, _ in })
                }
            }
            #expect(await sessions.statusPaneIds.isEmpty)
            #expect(await port.panes.isEmpty)
        }
    }

    static func admission(_ directory: PaneContextMembershipDirectory) -> AppIPCPaneClaimAdmission {
        .init(membershipRefusal: { claim in
            switch directory.claimMembership(paneId: claim.paneId, workspaceId: claim.workspaceId) {
            case .live: nil
            case .paneNotFound: .paneNotFound
            case .paneRetired: .paneRetired
            case .otherWorkspace: .otherWorkspace
            }
        })
    }
}

private actor ClaimRecordingPaneContextPort: AppIPCPaneContextPort {
    var panes: [UUID] = []
    func setTitle(paneId: UUID, params: IPCPaneTitleSetParams) async throws -> IPCPaneOrderedWriteResult {
        panes.append(paneId)
        return .applied
    }
    func setLine(paneId: UUID, params: IPCPaneLineSetParams) async throws -> IPCPaneOrderedWriteResult {
        panes.append(paneId)
        return .applied
    }
    func claimEpoch(paneId: UUID, params: IPCPaneWriterClaimEpochParams) async throws -> IPCPaneEpochClaimResult {
        panes.append(paneId)
        return .claimed(epoch: 1)
    }
    func sendMessage(paneId: UUID, params: IPCPaneMessageSendParams) async throws -> IPCPaneMessageSendResult {
        throw AppIPCPaneClaimError(reason: .intentRequiresToken)
    }
    func askMessage(
        paneId: UUID, params: IPCPaneMessageAskParams,
        connectionEndCause: @escaping @Sendable () -> AppIPCConnectionEndCause
    ) async throws -> IPCPaneAskOutcome {
        throw AppIPCPaneClaimError(reason: .intentRequiresToken)
    }
    func withdrawMessage(paneId: UUID, params: IPCPaneMessageWithdrawParams) async throws
        -> IPCPaneMessageWithdrawResult
    {
        throw AppIPCPaneClaimError(reason: .intentRequiresToken)
    }
    func readChanges(paneId: UUID, params: IPCPaneMessageChangesParams) async throws -> IPCPaneMessageChangesResult {
        throw AppIPCPaneClaimError(reason: .intentRequiresToken)
    }
    func readContext(paneId: UUID, params: IPCPaneContextGetParams, replyEnvelopeOverheadBytes: Int) async throws
        -> IPCPaneContextGetResult
    {
        throw AppIPCPaneClaimError(reason: .intentRequiresToken)
    }
}
