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
        try await BridgeLiveServerFixtureBox.withScope(
            configuration: configuration,
            body: { fixture in
                try await BridgeLiveServerFixtureContext.$current.withValue(fixture) {
                    try await function()
                }
            })
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

    static func withScope<Result>(
        configuration: BridgeLiveServerFixtureTrait.Configuration,
        body: (BridgeLiveServerFixtureBox) async throws -> Result
    ) async throws -> Result {
        let paneId = UUIDv7.generate()
        return try await withLiveServer(
            makeFixture: {
                switch configuration {
                case .unsafeBridge:
                    return try LiveServerFixture(
                        accessMode: .unsafeDebug, channel: .debug,
                        panes: [makePaneSummary(id: paneId, ordinal: 1, contentKind: .bridgePanel)]
                    )
                case .unsafeTerminal:
                    return try LiveServerFixture(
                        accessMode: .unsafeDebug, channel: .debug,
                        panes: [makePaneSummary(id: paneId, ordinal: 1, contentKind: .terminal)]
                    )
                case .safeBridge:
                    return try LiveServerFixture(
                        panes: [makePaneSummary(id: paneId, ordinal: 1, contentKind: .bridgePanel)]
                    )
                }
            },
            body: { fixture in
                try fixture.server.start()
                return try await body(Self(fixture: fixture, paneId: paneId))
            }
        )
    }
}
