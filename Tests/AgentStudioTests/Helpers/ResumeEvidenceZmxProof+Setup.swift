import AgentStudioCLIStore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioTerminal

extension ResumeEvidenceZmxProof {
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
