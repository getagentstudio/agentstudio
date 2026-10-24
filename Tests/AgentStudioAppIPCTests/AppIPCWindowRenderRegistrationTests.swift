import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

struct FakeWindowRenderPort: AppIPCWindowRenderPort {
    func render(_ params: IPCWindowRenderParams) throws -> IPCWindowRenderResult {
        throw AppIPCWindowRenderError.targetNotFound
    }

    func resize(_ params: IPCWindowResizeParams) throws -> IPCWindowResizeResult {
        throw AppIPCWindowRenderError.targetNotFound
    }
}

@MainActor
@Suite("Window render typed registrations", .serialized)
struct AppIPCWindowRenderRegistrationTests {
    @Test("both exact diagnostic pairs forward explicit windows, correlation and actual results")
    func windowRegistrationsForwardDiagnosticRequests() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let port = RecordingWindowRenderPort(windowId: fixture.windowId)
        let registrations = try fixture.registrations(windowRenderPort: port)
        let unsafePrincipal = IPCPrincipal(
            principalId: UUIDv7.generate(), runtimeId: fixture.runtimeId, accessMode: .unsafeDebug,
            kind: .unsafeDebugClient, approvalAuthority: .noApprovalAuthority)
        for principal in [fixture.diagnosticPrincipal, unsafePrincipal] {
            let renderValue = try await invoke(
                "window.render", fixture: fixture, registrations: registrations,
                context: fixture.connectionContext(principal: principal))
            #expect(try decodeJSONValue(IPCWindowRenderResult.self, from: renderValue) == port.renderResult)
            let resizeValue = try await invoke(
                "window.resize", fixture: fixture, registrations: registrations,
                context: fixture.connectionContext(principal: principal))
            let resizeResult = try decodeJSONValue(IPCWindowResizeResult.self, from: resizeValue)
            #expect(resizeResult.contentSize == IPCWindowContentSize(width: 321, height: 234))
            #expect(resizeResult.correlationId == fixture.correlationId)
        }
        #expect(port.renderParameters == Array(repeating: .init(workspaceWindowId: fixture.windowId), count: 2))
        #expect(
            port.resizeParameters
                == Array(
                    repeating: .init(
                        workspaceWindowId: fixture.windowId, contentWidth: 520, contentHeight: 600,
                        correlationId: fixture.correlationId), count: 2))
    }

    @Test("refused principals and channels have no capture, file or layout effect")
    func windowRegistrationsRejectPrincipalAndChannelMatrix() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let port = RecordingWindowRenderPort(windowId: fixture.windowId)
        let registrations = try fixture.registrations(windowRenderPort: port)
        let kinds: [IPCPrincipalKind] = [
            .automationClient, .unsafeDebugClient, .futureMCPClient,
            .spawnedPaneAgent(boundPaneId: fixture.paneId.uuidString, boundWorkspaceId: fixture.workspaceId),
            .paneClaim(paneId: fixture.paneId, workspaceId: fixture.workspaceId),
        ]
        for channel in [AgentStudioIPCChannel.debug, .stable, .beta] {
            for kind in kinds {
                for accessMode in IPCAccessMode.allCases {
                    let exactDiagnostic =
                        (kind == .automationClient && accessMode == .automationSameUser)
                        || (kind == .unsafeDebugClient && accessMode == .unsafeDebug)
                    if channel == .debug && exactDiagnostic { continue }
                    let principal = IPCPrincipal(
                        principalId: UUIDv7.generate(), runtimeId: fixture.runtimeId, accessMode: accessMode,
                        kind: kind, approvalAuthority: .noApprovalAuthority)
                    for name in ["window.render", "window.resize"] {
                        await #expect(throws: AppIPCTypedMethodRegistrationError.methodNotExposed) {
                            try await invoke(
                                name, fixture: fixture, registrations: registrations,
                                context: fixture.connectionContext(principal: principal, channel: channel))
                        }
                    }
                }
            }
            for name in ["window.render", "window.resize"] {
                await #expect(throws: AppIPCTypedMethodRegistrationError.authenticationRequired) {
                    try await invoke(
                        name, fixture: fixture, registrations: registrations,
                        context: fixture.connectionContext(principal: nil, channel: channel))
                }
            }
        }
        #expect(port.renderParameters.isEmpty)
        #expect(port.resizeParameters.isEmpty)
    }

    @Test("window bindings preserve each documented owner failure on the wire")
    func windowRegistrationsPreserveOwnerFailures() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let port = RecordingWindowRenderPort(windowId: fixture.windowId)
        let registrations = try fixture.registrations(windowRenderPort: port)
        for error in [
            AppIPCWindowRenderError.targetNotFound, .noContentView, .bitmapCreationFailed,
            .imageCreationFailed, .untrustedRenderDirectory, .encodingFailed, .writeFailed,
        ] {
            port.failure = error
            await #expect(throws: error) {
                try await invoke(
                    "window.render", fixture: fixture, registrations: registrations,
                    context: fixture.connectionContext(principal: fixture.diagnosticPrincipal))
            }
            #expect(AgentStudioAppIPCRequestError(error).data == .object(["reason": .string(error.rawValue)]))
        }
        port.failure = .invalidSize
        await #expect(throws: AppIPCWindowRenderError.invalidSize) {
            try await invoke(
                "window.resize", fixture: fixture, registrations: registrations,
                context: fixture.connectionContext(principal: fixture.diagnosticPrincipal))
        }
        #expect(AgentStudioAppIPCRequestError(AppIPCWindowRenderError.invalidSize).code == -32_602)
    }

    private func invoke(
        _ name: String, fixture: BuiltInMethodRegistrationsFixture,
        registrations: [AnyAppIPCMethodRegistration], context: AppIPCConnectionContext
    ) async throws -> AppIPCInvocationResult {
        let parameters: JSONValue
        if name == "window.render" {
            parameters = try fixture.jsonValue(IPCWindowRenderParams(workspaceWindowId: fixture.windowId))
        } else {
            parameters = try fixture.jsonValue(
                IPCWindowResizeParams(
                    workspaceWindowId: fixture.windowId, contentWidth: 520, contentHeight: 600,
                    correlationId: fixture.correlationId))
        }
        return try await fixture.registration(named: name, in: registrations).invoke(
            parameters: parameters, connectionContext: context, targetResolutionTools: fixture.targetResolutionTools(),
            authorize: { _, request in
                #expect(request.target == .app)
                #expect(request.dataScope == .uiSurface)
                #expect(request.requiredPrivileges == (name == "window.render" ? [.workspaceRead] : [.layoutMutate]))
            })
    }
}

@MainActor
private final class RecordingWindowRenderPort: AppIPCWindowRenderPort {
    var renderParameters: [IPCWindowRenderParams] = []
    var resizeParameters: [IPCWindowResizeParams] = []
    var failure: AppIPCWindowRenderError?
    let renderResult: IPCWindowRenderResult

    init(windowId: UUID) {
        renderResult = .init(
            workspaceWindowId: windowId,
            image: .init(
                path: "/fixture/renders/example.png", pixelWidth: 642, pixelHeight: 468,
                scale: 2, imagePointSize: .init(width: 321, height: 234)),
            contentSize: .init(width: 321, height: 234), surfaces: [])
    }

    func render(_ params: IPCWindowRenderParams) throws -> IPCWindowRenderResult {
        if let failure { throw failure }
        renderParameters.append(params)
        return renderResult
    }

    func resize(_ params: IPCWindowResizeParams) throws -> IPCWindowResizeResult {
        if let failure { throw failure }
        resizeParameters.append(params)
        return .init(
            workspaceWindowId: params.workspaceWindowId,
            contentSize: .init(width: 321, height: 234), correlationId: params.correlationId)
    }
}
