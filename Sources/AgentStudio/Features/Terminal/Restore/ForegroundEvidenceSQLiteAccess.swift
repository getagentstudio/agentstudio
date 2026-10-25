import Foundation
import GRDB

package struct ForegroundLatestBinding: Equatable, Sendable {
    package let bindingGenerationId: UUID
    package let isLive: Bool

    package init(bindingGenerationId: UUID, isLive: Bool) {
        self.bindingGenerationId = bindingGenerationId
        self.isLive = isLive
    }
}

/// App supplies the Sessions read inside Core's transaction; Terminal owns only its evidence table.
package protocol ForegroundEvidenceSQLiteAccess: Sendable {
    var latestBinding: @Sendable (Database, UUID) throws -> ForegroundLatestBinding? { get }
    func read<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output
    func write<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output
}
