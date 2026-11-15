import Testing

@testable import AgentStudioInfrastructure

@Suite
struct AgentStudioOTLPTracePreferenceProjectionTests {
    @Test
    func startupProjectionKeepsGlobalPreferenceLoadFieldsAndRetainsRawEndpoint() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/App/Boot/GlobalPreferencesStartupTelemetry.swift:25: preference startup emits status/settings facts, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 110,
            severityText: .info,
            body: "app.preferences.global.loaded",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "service.name": "AgentStudio",
                "service.version": "0.0.99",
            ],
            scope: .init(name: "agentstudio.app.startup", version: "0.1.0"),
            attributes: [
                "agentstudio.app.startup.phase": .string("global_preferences"),
                "agentstudio.app.startup.outcome": .string("loaded"),
                "agentstudio.preferences.global.load_elapsed_ms": .double(1.25),
                "agentstudio.preferences.global.observability_enabled": .bool(true),
                "agentstudio.preferences.global.schema_version": .int(1),
                "agentstudio.preferences.global.status": .string("loaded"),
                "agentstudio.preferences.global.otlp_endpoint": .string("http://127.0.0.1:4318"),
                "agentstudio.trace.tag": .string("app.startup"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.body == "app.preferences.global.loaded")
        #expect(projection.attributes["agentstudio.app.startup.phase"] == .string("global_preferences"))
        #expect(projection.attributes["agentstudio.app.startup.outcome"] == .string("loaded"))
        #expect(projection.attributes["agentstudio.preferences.global.load_elapsed_ms"] == .double(1.25))
        #expect(projection.attributes["agentstudio.preferences.global.observability_enabled"] == .bool(true))
        #expect(projection.attributes["agentstudio.preferences.global.schema_version"] == .int(1))
        #expect(projection.attributes["agentstudio.preferences.global.status"] == .string("loaded"))
        #expect(projection.attributes["agentstudio.preferences.global.otlp_endpoint"] != nil)
    }
}
