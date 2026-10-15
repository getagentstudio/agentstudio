import AgentStudioCore

package typealias RepoExplorerSessionStatusReader = @MainActor (PaneId) -> PaneAgentStatusPresentation?
package typealias RepoExplorerContextDisplayReader = @MainActor (PaneId) -> PaneContextDisplay?
