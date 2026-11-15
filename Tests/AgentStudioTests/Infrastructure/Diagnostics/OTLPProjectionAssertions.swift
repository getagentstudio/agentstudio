import Testing

@testable import AgentStudioInfrastructure

// Mixed projection fixtures must retain every input, including former canaries.
// Keep shape/resource assertions in their owning scenarios rather than hiding them here.
enum OTLPProjectionAssertions {
    static func project(
        _ record: AgentStudioTraceRecord, sourceLocation: SourceLocation = #_sourceLocation
    ) -> AgentStudioOTLPProjectedLogRecord {
        let projection = AgentStudioOTLPTraceProjection.project(record)
        for (key, value) in record.attributes {
            #expect(projection.attributes[key] == value, "Recorded attribute: \(key)", sourceLocation: sourceLocation)
        }
        return projection
    }
}
