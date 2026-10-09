import AgentStudioCore
import AgentStudioSharedComponents
import SwiftUI

/// App supplies the effect-owning host; RepoExplorer supplies prepared render values.
package enum RepoExplorerPaneContextControlPresentation {
    case messages(PaneMessageChipModel)
    case agentLine(RepoExplorerPaneContextLine)
}
package typealias RepoExplorerPaneContextControlFactory =
    @MainActor (PaneId, RepoExplorerPaneContextControlPresentation) -> AnyView?
