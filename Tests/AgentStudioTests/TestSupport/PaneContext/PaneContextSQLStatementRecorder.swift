import Foundation
import GRDB
import Synchronization

/// Records actual statements on every real pool connection, within an explicit
/// observation interval. Reader identity comes from GRDB's connection config.
package final class PaneContextSQLStatementRecorder: Sendable {
    package struct RecordedStatement: Sendable {
        package let sql: String
        package let isReader: Bool

        package var isMutation: Bool {
            ["INSERT", "UPDATE", "DELETE"].contains(sql.split(separator: " ").first.map(String.init) ?? "")
        }
    }

    private struct State {
        var observing = false
        var statements: [RecordedStatement] = []
    }
    private let state = Mutex(State())

    package init() {}

    package func makePool(at url: URL, configuration: Configuration) throws -> DatabasePool {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = configuration
        configuration.journalMode = .wal
        configuration.prepareDatabase { [self] database in
            let isReader = database.configuration.readonly
            database.trace(options: .statement) { event in
                guard case .statement(let statement) = event else { return }
                let sql = statement.sql.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                self.state.withLock { state in
                    if state.observing { state.statements.append(RecordedStatement(sql: sql, isReader: isReader)) }
                }
            }
        }
        return try DatabasePool(path: url.path, configuration: configuration)
    }

    package func begin() {
        state.withLock { state in
            state.statements.removeAll()
            state.observing = true
        }
    }

    package func end() -> [RecordedStatement] {
        state.withLock { state in
            state.observing = false
            return state.statements
        }
    }
}
