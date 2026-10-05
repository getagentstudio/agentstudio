import AgentStudioTestHarness
import GRDB
import Testing

@testable import AgentStudioCLIStore

extension CLIStoreTests {
    @Test(
        "busy failures preserve SQLite's extended result code without its payload",
        arguments: [Int32(5), 261, 517, 773, 6]
    )
    func busyFailurePreservesExtendedCode(extendedCode: Int32) async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            return CLIStore.openWriter(
                url: fixture.databaseURL, channel: .debug,
                prepareConnection: { _ in
                    throw DatabaseError(
                        resultCode: ResultCode(rawValue: extendedCode),
                        message: "untrusted diagnostic payload", sql: "untrusted SQL payload")
                })
        }
        switch observed {
        case .success:
            Issue.record("The injected SQLite busy error was accepted")
        case .failure(let failure):
            #expect(failure == .busy(extendedResultCode: extendedCode, stage: .connectionSetup))
            let diagnostic = String(describing: failure)
            #expect(!diagnostic.contains("untrusted"))
        }
    }

    @Test("an exhausted call budget is busy without inventing a SQLite result code")
    func expiredBudgetHasNoSQLiteCode() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            return CLIStore.openWriter(
                url: fixture.databaseURL, channel: .debug, migrationLockWaitBudget: { .zero })
        }
        switch observed {
        case .success:
            Issue.record("A writer opened after its call budget was exhausted")
        case .failure(let failure):
            #expect(failure == .busy(extendedResultCode: nil, stage: .connectionSetup))
        }
    }
}
