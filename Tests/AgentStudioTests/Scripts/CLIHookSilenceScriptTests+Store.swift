import AgentStudioCLIStore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

extension CLIHookSilenceScriptTests {
    @Test(
        "a real hook leaves an existing CLI store untouched even with a matching handled prefix",
        arguments: ["claude", "codex"])
    func hookDoesNotCleanExistingStore(provider: String) async throws {
        let fixture = try HookSilenceProcessFixture(condition: .up)
        defer { fixture.removeFiles() }
        let prepared = try await valueFromDedicatedThread {
            let store = try CLIStore.openWriter(url: fixture.storeURL, channel: .debug).get()
            let entry = try store.appendNotice(
                paneID: UUIDv7.generate(), messageID: UUIDv7.generate(), payloadJSON: "retained notice",
                createdAt: Date(timeIntervalSince1970: 1)
            ).get()
            return (store: store, entry: entry)
        }
        fixture.advertiseReadThrough(.init(storeId: prepared.store.identity.storeID, outbox: prepared.entry.id))
        let executable = try hookSilenceExecutableURL()
        let invocation = HookSilenceInvocation(
            provider: provider, event: "SessionStart", condition: .up,
            storeSetting: .fresh)
        let payloadURL = try fixture.writePayload(invocation.payload())
        let before = try await valueFromDedicatedThread { try hookStoreFileSnapshot(at: fixture.storeURL) }
        let output: ExitedProcessOutput
        do {
            try fixture.start()
            output = try await runProcessToExit(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c", #"input=$1; executable=$2; shift 2; exec "$executable" "$@" < "$input""#,
                    "hook-store-test", payloadURL.path, executable.path, "hook", provider, "SessionStart",
                ], environment: fixture.environment(executable: executable, storeSetting: .fresh))
        } catch {
            await fixture.shutdown()
            throw error
        }
        await fixture.shutdown()
        let after = try await valueFromDedicatedThread { try hookStoreFileSnapshot(at: fixture.storeURL) }
        let retained = try await valueFromDedicatedThread { try prepared.store.readOutbox(after: 0).get().entries }
        #expect(output.terminationStatus == 0)
        #expect(output.standardOutput.isEmpty)
        #expect(output.standardError.isEmpty)
        #expect(fixture.requests.contains { $0.method == "session.event" })
        #expect(after == before)
        #expect(retained == [prepared.entry])
    }
}

private struct HookStoreFileSnapshot: Sendable, Equatable {
    let bytes: Data
    let modifiedAt: Date
}

private func hookStoreFileSnapshot(at storeURL: URL) throws -> [String: HookStoreFileSnapshot] {
    let directory = storeURL.deletingLastPathComponent()
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    return try Dictionary(
        uniqueKeysWithValues: files.map { file in
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let modifiedAt = try #require(attributes[.modificationDate] as? Date)
            return (
                file.lastPathComponent, HookStoreFileSnapshot(bytes: try Data(contentsOf: file), modifiedAt: modifiedAt)
            )
        })
}
