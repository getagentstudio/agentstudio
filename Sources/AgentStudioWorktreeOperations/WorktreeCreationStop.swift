import Foundation

package enum WorktreeCreationStop: Error, Codable, Sendable, Equatable {
    case changesOnlyNeedsFrom
    case trackedOnlyExcludesSource
    case configInvalid(path: String, error: String)
    case sourceIndexUnreadable
    case sourceIndexUnsupported

    package var reason: WorktreeStopReason {
        switch self {
        case .changesOnlyNeedsFrom: .changesOnlyNeedsFrom
        case .trackedOnlyExcludesSource: .trackedOnlyExcludesSource
        case .configInvalid: .configInvalid
        case .sourceIndexUnreadable: .sourceIndexUnreadable
        case .sourceIndexUnsupported: .sourceIndexUnsupported
        }
    }

    var path: String? {
        switch self {
        case .configInvalid(let path, _): path
        default: nil
        }
    }

    var humanDetail: String? {
        switch self {
        case .configInvalid(_, let error): error.replacingOccurrences(of: "\n", with: " ")
        default: nil
        }
    }
}
