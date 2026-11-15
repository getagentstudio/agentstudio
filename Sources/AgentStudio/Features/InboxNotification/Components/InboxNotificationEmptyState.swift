import AgentStudioCore
import AgentStudioSharedComponents
import SwiftUI

struct InboxNotificationEmptyState: View {
    var body: some View {
        CenteredEmptyState(LocalActionSpec.inboxNoNotifications.actionSpec.label)
    }
}
