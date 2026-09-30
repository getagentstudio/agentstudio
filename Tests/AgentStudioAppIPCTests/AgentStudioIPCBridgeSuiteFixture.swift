import AgentStudioAppIPC
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

/// Groups Bridge socket cases by their server configuration. The default
/// Bridge and terminal groups share a real server; individual cases still
/// open their own client connections and assert their own protocol results.
struct BridgeLiveServerFixtureTrait: SuiteTrait, TestScoping {
    enum Configuration: Sendable {
        case unsafeBridge
        case unsafeTerminal
        case safeBridge
    }

    let configuration: Configuration
    var isRecursive: Bool { false }

    func provideScope(
        for _: Test,
        testCase _: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        let fixture = try BridgeLiveServerFixtureBox.make(configuration: configuration)
        do {
            try await BridgeLiveServerFixtureContext.$current.withValue(fixture) {
                try await function()
            }
        } catch {
            await fixture.tearDown()
            throw error
        }
        await fixture.tearDown()
    }
}

enum BridgeLiveServerFixtureContext {
    @TaskLocal static var current: BridgeLiveServerFixtureBox?
}

final class BridgeLiveServerFixtureBox: @unchecked Sendable {
    let fixture: LiveServerFixture
    let paneId: UUID

    private init(fixture: LiveServerFixture, paneId: UUID) {
        self.fixture = fixture
        self.paneId = paneId
    }

    static func make(configuration: BridgeLiveServerFixtureTrait.Configuration) throws -> Self {
        let paneId = UUIDv7.generate()
        let fixture: LiveServerFixture
        switch configuration {
        case .unsafeBridge:
            fixture = try LiveServerFixture(
                accessMode: .unsafeDebug,
                channel: .debug,
                panes: [makePaneSummary(id: paneId, ordinal: 1, contentKind: .bridgePanel)]
            )
        case .unsafeTerminal:
            fixture = try LiveServerFixture(
                accessMode: .unsafeDebug,
                channel: .debug,
                panes: [makePaneSummary(id: paneId, ordinal: 1, contentKind: .terminal)]
            )
        case .safeBridge:
            fixture = try LiveServerFixture(
                panes: [makePaneSummary(id: paneId, ordinal: 1, contentKind: .bridgePanel)]
            )
        }
        do {
            try fixture.server.start()
        } catch {
            fixture.cleanup()
            throw error
        }
        return Self(fixture: fixture, paneId: paneId)
    }

    /// `cleanup()` stops the server (no new connections, existing ones
    /// closed) and removes the socket root; joining afterward proves every
    /// handler that was still running when the socket closed has actually
    /// returned, not merely that its connection was closed.
    func tearDown() async {
        fixture.cleanup()
        await fixture.server.joinConnectionHandlers()
    }
}
