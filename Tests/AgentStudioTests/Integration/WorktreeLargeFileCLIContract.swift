import Foundation
import Testing

enum WorktreeLargeFileCLIContract {
    struct MaterializationDocument: Decodable {
        let kind: String
        let trackedChanges: Int?
        let untrackedFiles: Int?
        let ignoredExcluded: Bool?
    }

    enum ScanDocument: Decodable, Equatable {
        case complete
        case incompleteReadFailed(errno: Int32)
        case incompleteGitFailure(kind: String)

        private enum CodingKeys: String, CodingKey {
            case incomplete
        }

        private enum FailureKeys: String, CodingKey {
            case readFailed
            case gitFailure
        }

        init(from decoder: any Decoder) throws {
            if let value = try? decoder.singleValueContainer().decode(String.self) {
                guard value == "complete" else {
                    throw DecodingError.dataCorrupted(
                        .init(codingPath: decoder.codingPath, debugDescription: "unknown scan status"))
                }
                self = .complete
                return
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.allKeys.count == 1, container.contains(.incomplete) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "expected incomplete scan"))
            }
            let failure = try container.nestedContainer(keyedBy: FailureKeys.self, forKey: .incomplete)
            guard failure.allKeys.count == 1 else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "expected one scan failure"))
            }
            if failure.contains(.readFailed) {
                self = .incompleteReadFailed(errno: try failure.decode(Int32.self, forKey: .readFailed))
            } else if failure.contains(.gitFailure) {
                self = .incompleteGitFailure(kind: try failure.decode(String.self, forKey: .gitFailure))
            } else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "unknown scan failure"))
            }
        }
    }

    static func rawScanJSON(in output: String) throws -> String {
        let document = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let largeFiles = try #require(document["largeFiles"] as? [String: Any])
        let scan = try #require(largeFiles["scan"])
        let encoded = try JSONSerialization.data(withJSONObject: scan, options: [.fragmentsAllowed, .sortedKeys])
        return try #require(String(bytes: encoded, encoding: .utf8))
    }

    static func expectedPullCommand(for worktreePath: URL) -> String {
        let escapedPath = worktreePath.standardizedFileURL.path.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "git -C '\(escapedPath)' lfs pull"
    }
}
