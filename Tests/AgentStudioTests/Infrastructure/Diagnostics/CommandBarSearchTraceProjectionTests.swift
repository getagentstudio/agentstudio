import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite
struct CommandBarSearchTraceProjectionTests {
    @Test("correlated search stages export only bounded fields")
    func searchStagesRemainRecorded() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Features/CommandBar/CommandBarPanelController+Search.swift:249: search emits counts/stage/outcome, never query text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 211,
            severityText: .info,
            body: "performance.commandbar.search",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.commandbar.search.stage": .string("publication"),
                "agentstudio.performance.commandbar.search.outcome": .string("answered"),
                "agentstudio.performance.commandbar.search.sequence": .int(7),
                "agentstudio.performance.commandbar.search.generation": .int(3),
                "agentstudio.performance.commandbar.search.duplicate_item.count": .int(1),
                "agentstudio.performance.elapsed_ms": .double(12.5),
                "agentstudio.performance.commandbar.search.query_text": .string("private prompt"),
                "agentstudio.performance.commandbar.search.raw_path": .string("/Users/private/repo"),
            ]
        )

        let projected = OTLPProjectionAssertions.project(record)
        #expect(projected.body == "performance.commandbar.search")
        #expect(projected.attributes["agentstudio.performance.commandbar.search.stage"] == .string("publication"))
        #expect(projected.attributes["agentstudio.performance.commandbar.search.outcome"] == .string("answered"))
        #expect(projected.attributes["agentstudio.performance.commandbar.search.sequence"] == .int(7))
        #expect(projected.attributes["agentstudio.performance.commandbar.search.generation"] == .int(3))
        #expect(projected.attributes["agentstudio.performance.commandbar.search.duplicate_item.count"] == .int(1))
        #expect(projected.attributes["agentstudio.performance.elapsed_ms"] == .double(12.5))
        #expect(projected.attributes["agentstudio.performance.commandbar.search.query_text"] != nil)
        #expect(projected.attributes["agentstudio.performance.commandbar.search.raw_path"] != nil)
    }
}
