import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite
struct CommandBarWorktreeTraceProjectionTests {
    @Test("worktree row counts survive OTLP projection")
    func worktreeRowCountsSurviveProjection() {
        let record = AgentStudioTraceRecord(
            timeUnixNano: 90,
            severityText: .info,
            body: "performance.commandbar.filter",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.commandbar.worktree_row.count": .int(4),
                "agentstudio.performance.commandbar.input_worktree_row.count": .int(4),
                "agentstudio.performance.commandbar.result_worktree_row.count": .int(2),
            ]
        )

        let projected = OTLPProjectionAssertions.project(record)
        #expect(projected.attributes["agentstudio.performance.commandbar.worktree_row.count"] == .int(4))
        #expect(projected.attributes["agentstudio.performance.commandbar.input_worktree_row.count"] == .int(4))
        #expect(projected.attributes["agentstudio.performance.commandbar.result_worktree_row.count"] == .int(2))
    }
}
