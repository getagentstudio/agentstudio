import AgentStudioInfrastructure
import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree repository config")
struct WorktreeRepositoryConfigTests {
    @Test("absent config supplies empty include and busy-lock lists")
    func readsAbsentConfig() async throws {
        let root = try makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await AgentStudioRepositoryConfigReader.read(mainWorktree: root) == AgentStudioRepositoryConfig())
    }

    @Test("valid config ignores unknown keys and defaults absent entries")
    func decodesRepositoryCopyConfig() throws {
        let config = try JSONDecoder().decode(
            AgentStudioRepositoryConfig.self,
            from: Data(
                #"{"other":{"feature":true},"worktree":{"include":[".build*/","Frameworks/"],"busyLocks":["build.lock"],"future":1}}"#
                    .utf8))
        #expect(config.worktree.include == [".build*/", "Frameworks/"])
        #expect(config.worktree.busyLocks == ["build.lock"])
        for json in [#"{}"#, #"{"worktree":{}}"#, #"{"future":1}"#] {
            #expect(
                try JSONDecoder().decode(AgentStudioRepositoryConfig.self, from: Data(json.utf8))
                    == AgentStudioRepositoryConfig())
        }
    }

    @Test("malformed and unreadable declarations refuse with their file path")
    func refusesInvalidConfig() async throws {
        let root = try makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appending(path: ".agentstudio.config.json")
        for json in ["{", #"{"worktree":{"include":42}}"#] {
            try Data(json.utf8).write(to: path)
            do {
                _ = try await AgentStudioRepositoryConfigReader.read(mainWorktree: root)
                Issue.record("expected invalid config refusal")
            } catch let stop as WorktreeCreationStop {
                guard case .configInvalid(let actualPath, let error) = stop else {
                    Issue.record("expected configInvalid, got \(stop)")
                    return
                }
                #expect(actualPath == path.path)
                #expect(!error.isEmpty)
            }
        }
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: root.appending(path: "absent-target"))
        do {
            _ = try await AgentStudioRepositoryConfigReader.read(mainWorktree: root)
            Issue.record("a dangling config declaration must not count as absent")
        } catch let stop as WorktreeCreationStop {
            #expect(stop.reason == .configInvalid)
        }
    }

    private func makeConfigDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "worktree-config-\(UUIDv7.generate())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
