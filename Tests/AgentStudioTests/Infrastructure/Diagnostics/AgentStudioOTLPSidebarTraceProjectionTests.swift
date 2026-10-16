import Testing

@testable import AgentStudioInfrastructure

struct AgentStudioOTLPSidebarTraceProjectionTests {
    @Test(arguments: ["pinned_capture_mainactor", "pinned_projection_worker"])
    func pinnedNavigationKeepsCompleteControlledMetricTaxonomy(phase: String) throws {
        let record = AgentStudioTraceRecord(
            timeUnixNano: 181, severityText: .info, body: "performance.sidebar.projection",
            traceID: nil, spanID: nil, parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.elapsed_ms": .double(0.25),
                "agentstudio.performance.sidebar.surface": .string("repo"),
                "agentstudio.performance.sidebar.phase": .string(phase),
                "agentstudio.performance.sidebar.query_state": .string("empty"),
                "agentstudio.performance.sidebar.group_mode": .string("not_applicable"),
                "agentstudio.performance.sidebar.trigger": .string("pinned_navigation"),
            ]
        )
        let projected = AgentStudioOTLPTraceProjection.project(record)
        #expect(projected.attributes["agentstudio.performance.sidebar.phase"] == .string(phase))
        #expect(projected.attributes["agentstudio.performance.sidebar.trigger"] == .string("pinned_navigation"))
        let metric = try #require(AgentStudioOTLPPerformanceMetricEvent(record: projected))
        #expect(metric.elapsedMilliseconds == 0.25)
        #expect(metric.dimensions.contains(.init(name: "phase", value: phase)))
    }

    @Test
    func sidebarSortProjectionKeepsControlledTrigger() {
        let record = AgentStudioTraceRecord(
            timeUnixNano: 179,
            severityText: .info,
            body: "performance.sidebar.projection",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.elapsed_ms": .double(2.25),
                "agentstudio.performance.sidebar.surface": .string("repo"),
                "agentstudio.performance.sidebar.phase": .string("projection_worker"),
                "agentstudio.performance.sidebar.query_state": .string("empty"),
                "agentstudio.performance.sidebar.group_mode": .string("repo"),
                "agentstudio.performance.sidebar.trigger": .string("sort_order"),
                "agentstudio.performance.sidebar.total_worker_elapsed_ms": .double(2.25),
                "agentstudio.trace.tag": .string("performance"),
            ]
        )

        let projection = AgentStudioOTLPTraceProjection.project(record)

        #expect(projection.attributes["agentstudio.performance.sidebar.trigger"] == .string("sort_order"))
        #expect(projection.attributes["agentstudio.performance.sidebar.total_worker_elapsed_ms"] == .double(2.25))
    }

    @Test(arguments: [("ascending", true), ("descending", true), ("uncontrolled", false)])
    func sidebarSortProjectionKeepsOnlyControlledSortOrders(sortOrder: String, shouldExport: Bool) {
        let record = AgentStudioTraceRecord(
            timeUnixNano: 182,
            severityText: .info,
            body: "performance.sidebar.projection",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.sidebar.surface": .string("repo"),
                "agentstudio.performance.sidebar.phase": .string("projection_worker"),
                "agentstudio.performance.sidebar.group_mode": .string("repo"),
                "agentstudio.performance.sidebar.sort_order": .string(sortOrder),
                "agentstudio.performance.sidebar.trigger": .string("sort_order"),
            ]
        )

        let projection = AgentStudioOTLPTraceProjection.project(record)

        let expectedSortOrder: AgentStudioTraceValue? = shouldExport ? .string(sortOrder) : nil
        #expect(projection.attributes["agentstudio.performance.sidebar.sort_order"] == expectedSortOrder)
    }

    @Test
    func sidebarSurfaceSwitchProjectionKeepsControlledPhase() {
        let record = AgentStudioTraceRecord(
            timeUnixNano: 180,
            severityText: .info,
            body: "performance.sidebar.projection",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.sidebar.surface": .string("repo"),
                "agentstudio.performance.sidebar.phase": .string("surface_switch"),
                "agentstudio.performance.sidebar.trigger": .string("surface_switch"),
                "agentstudio.startup_diagnostic.projection_proof.succeeded": .bool(true),
            ]
        )

        let projection = AgentStudioOTLPTraceProjection.project(record)

        #expect(projection.attributes["agentstudio.performance.sidebar.phase"] == .string("surface_switch"))
        #expect(projection.attributes["agentstudio.startup_diagnostic.projection_proof.succeeded"] == .bool(true))
    }
}
