import Foundation

package struct WorktreeCleanupLeftoversDocument: Encodable, Sendable, Equatable {
    package let status: String
    package let items: [WorktreeCleanupLeftoverDocument]?
}

package struct WorktreeCleanupLeftoverDocument: Encodable, Sendable, Equatable {
    package let kind: String
    package let location: String
    package let base: String
}

package enum WorktreeCleanupLeftoversFormatter {
    package static func human(_ leftovers: WorktreeLeftoverStatus) -> String {
        switch leftovers {
        case .notNeeded:
            return "notNeeded"
        case .noLeftovers:
            return "noLeftovers"
        case .unverified:
            return "unverified"
        case .incomplete(let items):
            guard !items.isEmpty else { return "incomplete" }
            let descriptions = items.map { item in
                "\(item.kind.rawValue) \(item.location) (\(humanBase(item.base)))"
            }
            return "incomplete [\(descriptions.joined(separator: "; "))]"
        }
    }

    package static func document(_ leftovers: WorktreeLeftoverStatus) -> WorktreeCleanupLeftoversDocument {
        switch leftovers {
        case .notNeeded:
            WorktreeCleanupLeftoversDocument(status: "notNeeded", items: nil)
        case .noLeftovers:
            WorktreeCleanupLeftoversDocument(status: "noLeftovers", items: nil)
        case .unverified:
            WorktreeCleanupLeftoversDocument(status: "unverified", items: nil)
        case .incomplete(let items):
            WorktreeCleanupLeftoversDocument(
                status: "incomplete",
                items: items.map {
                    WorktreeCleanupLeftoverDocument(
                        kind: $0.kind.rawValue,
                        location: $0.location,
                        base: jsonBase($0.base)
                    )
                }
            )
        }
    }

    private static func humanBase(_ base: WorktreeLeftoverBase) -> String {
        switch base {
        case .destination:
            "destination"
        case .repositoryGitDirectory:
            "repository Git directory"
        case .branchReference:
            "branch reference"
        case .temporary:
            "temporary"
        }
    }

    private static func jsonBase(_ base: WorktreeLeftoverBase) -> String {
        switch base {
        case .destination:
            "destination"
        case .repositoryGitDirectory:
            "repositoryGitDirectory"
        case .branchReference:
            "branchReference"
        case .temporary:
            "temporary"
        }
    }
}
