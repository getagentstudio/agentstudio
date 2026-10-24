import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite
struct AgentStudioOTLPTraceSinkTests {
    @Test
    func sinkProjectsRecordBeforeEmittingThroughBootstrapper() async throws {
        let bootstrapper = RecordingOTLPBootstrapper()
        let context = AgentStudioOTLPTraceSinkContext(
            endpoint: URL(string: "http://127.0.0.1:4318")!,
            otlpProtocol: .httpProtobuf,
            queueStatistics: AgentStudioTraceQueueStatistics()
        )
        let sink = AgentStudioOTLPTraceSink(context: context, bootstrapper: bootstrapper)
        // R10: TerminalActivityRouter.swift:518 records runtime identity, never message text; this synthetic sink fixture bypasses it.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 500,
            severityText: .info,
            body: "runtime.state_changed",
            traceID: "trace-should-not-export",
            spanID: "span-should-not-export",
            parentSpanID: "parent-should-not-export",
            resource: [
                "process.pid": "9876",
                "service.name": "AgentStudio",
            ],
            scope: .init(name: "agentstudio.runtime", version: "0.1.0"),
            attributes: [
                "agentstudio.runtime.event": .string("state_changed"),
                "agentstudio.trace.tag": .string("runtime"),
                "agentstudio.workspace.id": .string(UUIDv7.generate().uuidString),
            ]
        )

        try await sink.record(record)
        try await sink.flush()
        try await sink.shutdown()

        let emittedRecords = await bootstrapper.emittedRecords()
        let emittedContexts = await bootstrapper.emittedContexts()
        #expect(emittedRecords.count == 1)
        #expect(emittedRecords.first?.body == "runtime.state_changed")
        #expect(emittedRecords.first?.traceID == nil)
        #expect(emittedRecords.first?.spanID == nil)
        #expect(emittedRecords.first?.resource["service.name"] == "AgentStudio")
        #expect(emittedRecords.first?.resource["process.pid"] == nil)
        #expect(emittedRecords.first?.attributes["agentstudio.runtime.event"] == .string("state_changed"))
        #expect(
            emittedRecords.first?.attributes["agentstudio.workspace.id"]
                == record.attributes["agentstudio.workspace.id"])
        #expect(emittedContexts.first?.endpoint.absoluteString == "http://127.0.0.1:4318")
        #expect(await bootstrapper.flushCount() == 1)
        #expect(await bootstrapper.shutdownCount() == 1)
    }
}

private actor RecordingOTLPBootstrapper: AgentStudioOTLPBootstrapping {
    private var records: [AgentStudioOTLPProjectedLogRecord] = []
    private var contexts: [AgentStudioOTLPTraceSinkContext] = []
    private var recordedFlushCount = 0
    private var recordedShutdownCount = 0

    func emit(_ record: AgentStudioOTLPProjectedLogRecord, context: AgentStudioOTLPTraceSinkContext) {
        records.append(record)
        contexts.append(context)
    }

    func flush() {
        recordedFlushCount += 1
    }

    func shutdown() {
        recordedShutdownCount += 1
    }

    func emittedRecords() -> [AgentStudioOTLPProjectedLogRecord] {
        records
    }

    func emittedContexts() -> [AgentStudioOTLPTraceSinkContext] {
        contexts
    }

    func flushCount() -> Int {
        recordedFlushCount
    }

    func shutdownCount() -> Int {
        recordedShutdownCount
    }
}
