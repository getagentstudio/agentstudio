import AgentStudioPrimitives
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCLIStore

extension CLIStoreTests {
    @Test("two real CLI processes released together migrate a brand-new store and both commit notices")
    func concurrentFirstWriterProcessesDoNotLoseNotices() async throws {
        let fixture = try CLIStoreFileFixture()
        defer { fixture.remove() }
        let executable = try fixture.processExecutableURL()
        let firstPane = UUIDv7.generate()
        let secondPane = UUIDv7.generate()
        let firstReady = HeldStep<Void>("first fresh-store writer is ready")
        let secondReady = HeldStep<Void>("second fresh-store writer is ready")
        #expect(!FileManager.default.fileExists(atPath: fixture.databaseURL.path))
        let first = Task {
            try await firstReady.arrive(())
            return try await runProcessToExit(
                executableURL: executable, arguments: [fixture.databaseURL.path, firstPane.uuidString])
        }
        let second = Task {
            try await secondReady.arrive(())
            return try await runProcessToExit(
                executableURL: executable, arguments: [fixture.databaseURL.path, secondPane.uuidString])
        }
        let outputs: [ExitedProcessOutput]
        do {
            try await firstReady.firstArrival()
            try await secondReady.firstArrival()
            firstReady.release()
            secondReady.release()
            outputs = try await [first.value, second.value]
        } catch {
            firstReady.release()
            secondReady.release()
            _ = try? await first.value
            _ = try? await second.value
            throw error
        }
        let processLabels = ["first", "second"]
        let processObservations = zip(processLabels, outputs).map { label, output in
            let standardError =
                String(bytes: output.standardError, encoding: .utf8)
                ?? "<non-UTF8 stderr, \(output.standardError.count) bytes>"
            return "\(label): terminationStatus=\(output.terminationStatus); stderr=\(standardError)"
        }
        let allProcessObservations = processObservations.joined(separator: "\n")
        var committedIDs: [Int64] = []
        for (index, output) in outputs.enumerated() {
            let observation = processObservations[index]
            #expect(output.terminationStatus == 0, "\(observation)")
            #expect(output.standardError.isEmpty, "\(observation)")
            let text = try #require(String(bytes: output.standardOutput, encoding: .utf8), "\(observation)")
            let identifiers = text.split(separator: "\n").compactMap { Int64($0) }
            #expect(!identifiers.isEmpty, "\(observation)")
            committedIDs.append(contentsOf: identifiers)
        }
        let rows = try await valueFromDedicatedThread {
            let reader = try CLIStore.openReader(url: fixture.databaseURL, expectedChannel: .debug).get()
            return try reader.readOutbox(after: 0).get().entries
        }
        #expect(rows.map(\.id) == committedIDs.sorted(), "\(allProcessObservations)")
        let notices = rows.map { entry -> CLINoticeEntry in
            switch entry {
            case .notice(let notice): notice
            }
        }
        #expect(Set(notices.map(\.paneID)) == Set([firstPane, secondPane]), "\(allProcessObservations)")
        #expect(Set(notices.map(\.messageID)).count == notices.count, "\(allProcessObservations)")
    }
}
