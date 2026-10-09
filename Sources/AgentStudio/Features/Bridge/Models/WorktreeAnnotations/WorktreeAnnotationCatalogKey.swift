import Foundation

enum WorktreeAnnotationCatalogKey: Hashable, Sendable {
    case session(WorktreeAnnotationSessionID)
    case thread(WorktreeAnnotationThreadID)
    case message(WorktreeAnnotationMessageID)

    init(entry: WorktreeAnnotationCatalogEntry) {
        switch entry {
        case .session(let session): self = .session(session.sessionID)
        case .thread(let thread): self = .thread(thread.threadID)
        case .message(let message): self = .message(message.messageID)
        }
    }

    var recordKey: String {
        switch self {
        case .session(let id): "session:\(id.rawValue.uuidString.lowercased())"
        case .thread(let id): "thread:\(id.rawValue.uuidString.lowercased())"
        case .message(let id): "message:\(id.rawValue.uuidString.lowercased())"
        }
    }
}
