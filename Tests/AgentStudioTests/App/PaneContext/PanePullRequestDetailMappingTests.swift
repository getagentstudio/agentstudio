import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@Suite("Pane PR detail mapping")
struct PanePullRequestDetailMappingTests {
    @Test("Mixed source row preserves details, last-good time and refresh failure through the strict wire schema")
    func loadedFailureMapping() throws {
        let identity = try ForgePullRequestIdentity(host: "github.com", owner: "owner", repository: "repo", number: 7)
        let readAt = Date(timeIntervalSince1970: 100)
        let updatedAt = Date(timeIntervalSince1970: 80)
        let url: URL = try #require(URL(string: "https://github.com/owner/repo/pull/7"))
        let read = ForgePullRequestLastGoodRead(
            details: .init(
                title: "Keep this title", state: .draft,
                readiness: .init(
                    isDraft: true, checkStatus: .failed, reviewStatus: .changesRequested,
                    mergeability: .conflicting, mergeState: .dirty),
                updatedAt: updatedAt, url: url),
            readAt: readAt)
        let row = PanePullRequestRow(
            identity: identity, isWorktree: true,
            contributions: [.init(author: .person, createdAt: updatedAt)], createdAt: updatedAt,
            details: .loaded(read, refreshFailure: .offline))
        let mapped = PaneContextIPCMapping.pullRequests(.init(rows: [row]))
        #expect(mapped.rows.count == 1 && mapped.rows.first?.isWorktree == true)
        #expect(mapped.rows.first?.authors == [.person])
        #expect(mapped.worstChecks == .failed)
        guard case .loaded(let details) = mapped.rows.first?.details else {
            Issue.record("Expected last-good details")
            return
        }
        #expect(details.title == "Keep this title" && details.state == .draft)
        #expect(details.checks == .failed && details.review == .changesRequested)
        #expect(details.mergeability == .conflicting && details.mergeState == .dirty)
        #expect(details.lastGoodReadAt == readAt && details.updatedAt == updatedAt)
        #expect(details.refreshFailure == .offline)
        let encoded = try JSONEncoder().encode(mapped)
        let decoded = try IPCPanePullRequestPresentationList.ipcSchema().decode(
            IPCPanePullRequestPresentationList.self, from: encoded)
        #expect(decoded == mapped)
    }
}
