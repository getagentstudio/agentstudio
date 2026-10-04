import AgentStudioAppIPC
import AgentStudioCLIStore
import AgentStudioCore
import AgentStudioProgrammaticControl
import Foundation
import GRDB
import os.log

struct AppCLIStoreReadThroughReader: AppIPCCLIStoreReadThroughPort {
    private static let logger = Logger(subsystem: "com.agentstudio", category: "CLIStoreReadThrough")
    let storeURL: URL
    let expectedChannel: CLIStoreChannel
    let datastore: WorkspaceSQLiteDatastoreActor

    func readThrough() async -> IPCCLIStoreReadThrough? {
        let identity: CLIStoreIdentity
        switch await Self.readStoreIdentity(url: storeURL, channel: expectedChannel) {
        case .success(let value): identity = value
        case .failure(.unavailable): return nil
        case .failure(let failure):
            Self.logger.info("CLI store read-through refused: \(String(describing: failure), privacy: .public)")
            return nil
        }
        do {
            let storeID = identity.storeID.uuidString
            let outbox = try await datastore.performApplicationLocalRead { database throws -> Int64? in
                guard try database.tableExists("pane_context_cli_outbox_cursor") else { return nil }
                return try Int64.fetchOne(
                    database,
                    sql: "SELECT last_handled_id FROM pane_context_cli_outbox_cursor WHERE store_id = ?",
                    arguments: [storeID])
            }
            guard let outbox else { return nil }
            guard (0...IPCSchemaScalars.maximumExactInteger).contains(outbox) else {
                Self.logger.warning("CLI store read-through refused: invalid cursor")
                return nil
            }
            return IPCCLIStoreReadThrough(storeId: identity.storeID, outbox: outbox)
        } catch {
            Self.logger.warning("CLI store read-through unavailable: local cursor read failed")
            return nil
        }
    }

    @concurrent private nonisolated static func readStoreIdentity(url: URL, channel: CLIStoreChannel) async
        -> Result<CLIStoreIdentity, CLIStoreFailure>
    {
        CLIStore.openReader(url: url, expectedChannel: channel).map(\.identity)
    }
}
