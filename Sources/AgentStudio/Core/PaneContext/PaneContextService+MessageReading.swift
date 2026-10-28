import AgentStudioInfrastructure
import Foundation

extension PaneContextService {
    package func readMessage(source: PaneId, message: AgentMessageId) async -> MessageReadResult {
        do {
            try await ensureOpen()
            guard captureMembershipView(paneId: source) != nil, !isPendingRetirement(source) else { return .notFound }
            let now = wallNow()
            let found = try await sqliteAccess.read { database -> AgentMessageDetail? in
                guard try !PaneContextStorage.isRetired(database, paneId: source),
                    let stored = try PaneContextStorage.message(database, paneId: source, messageId: message),
                    !stored.displayHidden
                else { return nil }
                if let settledAt = stored.settledAt,
                    settledAt.addingTimeInterval(AppPolicies.PaneContext.settledMessageLifetime) <= now
                {
                    return nil
                }
                return stored.detail
            }
            guard !isPendingRetirement(source), let found else { return .notFound }
            return .found(found)
        } catch { return .unavailable(storageFailure(error)) }
    }
}
