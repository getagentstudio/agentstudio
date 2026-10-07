import AgentStudioCore

package typealias RepoExplorerSessionStatusReader = @MainActor (PaneId) -> AgentSessionStatus?
package typealias RepoExplorerContextDisplayReader = @MainActor (PaneId) -> PaneContextDisplay?
