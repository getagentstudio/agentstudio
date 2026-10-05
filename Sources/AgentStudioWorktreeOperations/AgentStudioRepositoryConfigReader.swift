import AgentStudioGit
import Darwin
import Foundation

package struct AgentStudioRepositoryConfig: Codable, Sendable, Equatable {
    package let worktree: WorktreeCopyConfig

    package init(worktree: WorktreeCopyConfig = WorktreeCopyConfig()) {
        self.worktree = worktree
    }

    private enum CodingKeys: String, CodingKey { case worktree }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        worktree = try container.decodeIfPresent(WorktreeCopyConfig.self, forKey: .worktree) ?? WorktreeCopyConfig()
    }
}

package struct WorktreeCopyConfig: Codable, Sendable, Equatable {
    package let include: [String]

    package init(include: [String] = []) {
        self.include = include
    }

    package func compiledIncludePatterns(configurationPath: URL) throws(WorktreeCreationStop) -> [GitPathPattern] {
        var patterns: [GitPathPattern] = []
        patterns.reserveCapacity(include.count)
        for entry in include {
            do {
                patterns.append(try GitPathPattern(entry))
            } catch {
                throw .configInvalid(
                    path: configurationPath.path,
                    error: "include entry \(String(reflecting: entry)): \(error)"
                )
            }
        }
        return patterns
    }

    private enum CodingKeys: String, CodingKey { case include }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        include = try container.decodeIfPresent([String].self, forKey: .include) ?? []
    }
}

package enum AgentStudioRepositoryConfigReader {
    @concurrent
    package static func read(mainWorktree: URL) async throws -> AgentStudioRepositoryConfig {
        let path = mainWorktree.appending(path: ".agentstudio.config.json")
        let descriptor = open(path.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT {
                // A dangling link is an unreadable declaration, not an absent file.
                var metadata = stat()
                if lstat(path.path, &metadata) != 0, errno == ENOENT { return AgentStudioRepositoryConfig() }
            }
            throw WorktreeCreationStop.configInvalid(path: path.path, error: "open errno \(code)")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        do {
            let data = try handle.readToEnd() ?? Data()
            return try JSONDecoder().decode(AgentStudioRepositoryConfig.self, from: data)
        } catch {
            throw WorktreeCreationStop.configInvalid(path: path.path, error: String(describing: error))
        }
    }
}
