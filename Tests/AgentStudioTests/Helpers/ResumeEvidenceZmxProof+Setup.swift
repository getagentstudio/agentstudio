import AgentStudioCLIStore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioTerminal

extension ResumeEvidenceZmxProof {
    func captureForeground(expected: ForegroundProgram) async throws {
        let snapshots = try await foreground.probe.probeForeground(of: [foreground.sessionId])
        let snapshot = try #require(snapshots[foreground.sessionId])
        #expect(snapshot.program == expected)
        let previous = try #require(try await foreground.repository.load(paneId: foreground.paneId))
        let look = PaneForegroundLook(
            paneId: previous.paneId, zmxSessionId: previous.zmxSessionId, sessionIdentity: snapshot.sessionIdentity,
            bindingGenerationId: previous.bindingGenerationId, program: snapshot.program,
            observerLaunchId: previous.observerLaunchId, sequence: previous.sequence + 1, observedAt: Date())
        #expect(try await foreground.repository.admit(look) == .admitted)
    }

    func replaceStore(missing: Bool, fresh: Bool = false) async throws {
        if fresh {
            try await data.access.write { database in
                try database.execute(sql: "DELETE FROM terminal_restore_outbox_identity")
                try database.execute(sql: "DELETE FROM pane_context_cli_outbox_cursor")
            }
        }
        let writer = data.writer
        let store = data.storeURL
        let backup = data.root.appending(path: "old-cli.sqlite")
        try await valueFromDedicatedThread {
            try writer.close()
            try FileManager.default.moveItem(at: store, to: backup)
            if !missing {
                let replacement = try CLIStore.openWriter(url: store, channel: .debug).get()
                try replacement.close()
            }
        }
    }
}
