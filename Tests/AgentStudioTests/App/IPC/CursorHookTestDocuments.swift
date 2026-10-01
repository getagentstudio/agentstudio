import AgentStudioIPCClientCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation

/// Shared fixture decoding only; every projection mints its own correlation.
enum CursorHookTestDocuments {
    /// `Tests/AgentStudioTests/App/IPC` -> repository root -> the CLI suite's
    /// recorded Cursor documents.
    private static func fixtureURL(_ event: String, file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Tests/AgentStudioIPCClientTests/Fixtures/cursor-2026.09.15/\(event).json")
    }

    static func projectedParams(_ event: String) throws -> IPCSessionEventParams {
        let payload = try JSONDecoder().decode(
            CursorHookPayload.self, from: try Data(contentsOf: fixtureURL(event))
        )
        let outcome = CursorHookProjection.project(
            announcedEvent: event,
            payload: payload,
            providerVersion: CursorProviderIdentity.supportedExactVersion,
            correlationIdentifier: UUIDv7.generate(),
            freshOccurrenceIdentifier: { UUIDv7.generate() }
        )
        guard case .projected(let params) = outcome else {
            throw CursorHookFixtureProjectionError.notProjected(event)
        }
        return params
    }
}

private enum CursorHookFixtureProjectionError: Error {
    case notProjected(String)
}
