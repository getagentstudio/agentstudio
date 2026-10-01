import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio

@Suite("AgentStudio App IPC sidebar service")
struct AgentStudioAppIPCSidebarServiceTests {
    @Test("debug token automation can read sidebar grouping and surface")
    func debugTokenAutomationCanReadSidebarGroupingAndSurface() async throws {
        try await withLiveServer(
            makeFixture: {
                try LiveServerFixture(
                    channel: .debug,
                    sidebarPort: FakeSidebarPort(
                        repoGrouping: .activity,
                        inboxGrouping: .noGrouping,
                        surface: .inbox
                    )
                )
            },
            body: { fixture in
                try fixture.server.start()

                let connection = try await authenticatedConnection(for: fixture, tokenRequestId: 67)
                defer {
                    connection.close()
                }
                var reader = TestFrameReader()

                let repoGrouping = try await getGrouping(
                    connection: connection,
                    reader: &reader,
                    requestId: 68,
                    surface: .repo
                )
                #expect(repoGrouping.surface == .repo)
                #expect(repoGrouping.mode == .activity)

                let inboxGrouping = try await getGrouping(
                    connection: connection,
                    reader: &reader,
                    requestId: 69,
                    surface: .inbox
                )
                #expect(inboxGrouping.surface == .inbox)
                #expect(inboxGrouping.mode == .noGrouping)

                let surfaceGetResult = try await getSurface(
                    connection: connection,
                    reader: &reader,
                    requestId: 70
                )
                #expect(surfaceGetResult.surface == .inbox)
            })
    }

    @Test("removed sidebar write routes are not method registry entries")
    func removedSidebarWriteRoutesAreNotMethodRegistryEntries() async throws {
        try await withLiveServer(
            makeFixture: { try LiveServerFixture(channel: .debug) },
            body: { fixture in
                try fixture.server.start()

                let connection = try await authenticatedConnection(for: fixture, tokenRequestId: 71)
                defer {
                    connection.close()
                }
                var reader = TestFrameReader()

                for (requestId, method, params) in [
                    (
                        72,
                        "sidebar.grouping.set",
                        JSONValue.object(["surface": .string("repo"), "mode": .string("tab")])
                    ),
                    (
                        73,
                        "sidebar.surface.set",
                        JSONValue.object(["surface": .string("inbox")])
                    ),
                ] {
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: JSONRPCClientRequest(
                            id: .number(requestId),
                            method: method,
                            params: params
                        )
                    )
                    let response = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)

                    #expect(response.id == .number(requestId))
                    #expect(response.error?.code == -32_601)
                    #expect(response.error?.message == "method not found")
                }
            })
    }

    @Test("debug unsafe no-auth reads sidebar grouping and surface without login")
    func debugUnsafeNoAuthReadsSidebarGroupingAndSurfaceWithoutLogin() async throws {
        try await withLiveServer(
            makeFixture: {
                try LiveServerFixture(
                    accessMode: .unsafeDebug,
                    channel: .debug,
                    sidebarPort: FakeSidebarPort(
                        repoGrouping: .activity,
                        inboxGrouping: .noGrouping,
                        surface: .inbox
                    )
                )
            },
            body: { fixture in
                try fixture.server.start()

                let groupingResponse = try await sendRequestWithoutBlockingMainActor(
                    socketPath: fixture.paths.socketURL.path,
                    request: JSONRPCClientRequest(
                        id: .number(74),
                        method: "sidebar.grouping.get",
                        params: try JSONRPCCodec.encodeJSONValue(
                            IPCSidebarGroupingGetParams(surface: .repo)
                        )
                    )
                )
                let grouping = try decodeResponseResult(IPCSidebarGroupingResult.self, from: groupingResponse)

                let surfaceResponse = try await sendRequestWithoutBlockingMainActor(
                    socketPath: fixture.paths.socketURL.path,
                    request: JSONRPCClientRequest(
                        id: .number(75),
                        method: "sidebar.surface.get",
                        params: try JSONRPCCodec.encodeJSONValue(IPCSidebarSurfaceGetParams())
                    )
                )
                let surface = try decodeResponseResult(IPCSidebarSurfaceResult.self, from: surfaceResponse)

                #expect(groupingResponse.id == .number(74))
                #expect(groupingResponse.error == nil)
                #expect(grouping.surface == .repo)
                #expect(grouping.mode == .activity)
                #expect(surfaceResponse.id == .number(75))
                #expect(surfaceResponse.error == nil)
                #expect(surface.surface == .inbox)
            })
    }

    private func authenticatedConnection(
        for fixture: LiveServerFixture,
        tokenRequestId: Int
    ) async throws -> UnixSocketConnection {
        let token = fixture.installDebugCredential()
        let connection = try await connectWithoutBlockingCooperativePool(socketPath: fixture.paths.socketURL.path)
        var reader = TestFrameReader()
        try await loginWithoutBlockingMainActor(
            connection: connection,
            token: token,
            requestId: tokenRequestId,
            reader: &reader
        )
        return connection
    }

    private func getGrouping(
        connection: UnixSocketConnection,
        reader: inout TestFrameReader,
        requestId: Int,
        surface: IPCSidebarSurface
    ) async throws -> IPCSidebarGroupingResult {
        try await sendRequestWithoutBlockingCooperativePool(
            connection: connection,
            request: JSONRPCClientRequest(
                id: .number(requestId),
                method: "sidebar.grouping.get",
                params: try JSONRPCCodec.encodeJSONValue(
                    IPCSidebarGroupingGetParams(surface: surface)
                )
            )
        )
        let response = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
        #expect(response.error == nil)
        return try decodeResponseResult(IPCSidebarGroupingResult.self, from: response)
    }

    private func getSurface(
        connection: UnixSocketConnection,
        reader: inout TestFrameReader,
        requestId: Int
    ) async throws -> IPCSidebarSurfaceResult {
        try await sendRequestWithoutBlockingCooperativePool(
            connection: connection,
            request: JSONRPCClientRequest(
                id: .number(requestId),
                method: "sidebar.surface.get",
                params: try JSONRPCCodec.encodeJSONValue(IPCSidebarSurfaceGetParams())
            )
        )
        let response = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
        #expect(response.error == nil)
        return try decodeResponseResult(IPCSidebarSurfaceResult.self, from: response)
    }
}
