import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioTerminal

extension TerminalActivityRouterTests {
    private struct TraceRecordFixture: Decodable {
        let body: String
        let traceID: String?
        let attributes: [String: TraceAttributeFixture]

        enum CodingKeys: String, CodingKey {
            case attributes
            case body
            case traceID = "trace_id"
        }
    }

    private enum TraceAttributeFixture: Decodable, Equatable {
        case int(Int)
        case string(String)
        case other

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Int.self) {
                self = .int(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else {
                self = .other
            }
        }
    }

    @Test("records terminal activity trace records when runtime tracing is enabled")
    func recordsTerminalActivityTraceRecordsWhenRuntimeTracingIsEnabled() async throws {
        let factSource = TerminalActivityRouterFactSource()
        let facts = try factSource.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let atom = TerminalActivityAtom(outputBurstThreshold: 30)
        let traceDirectory = temporaryTraceDirectoryURL()
        let traceFixture = makeTraceRuntime(
            traceDirectory: traceDirectory,
            traceName: "terminal-activity",
            traceTags: "terminal.activity",
            processIdentifier: 246,
            flushMode: "immediate"
        )
        let traceRuntime = traceFixture.runtime
        let router = TerminalActivityRouter(
            bus: bus, activityAtom: atom, traceRuntime: traceRuntime, factSink: factSource.sink)
        let paneId = PaneId.generateUUIDv7()
        let correlationId = UUID()

        do {
            await router.start()
            await bus.waitForSubscriberRegistration(subscriberName: "TerminalActivityRouter")
            let eventID = UUIDv7.generate()
            _ = await bus.post(
                .pane(
                    .test(
                        event: .terminal(.openURLRequested(url: "https://example.com/trace", kind: .text)),
                        paneId: paneId,
                        paneKind: .terminal,
                        seq: 7,
                        eventId: eventID,
                        correlationId: correlationId
                    )
                )
            )

            _ = try await facts.expectRuntimeEnvelopeHandled(paneID: paneId.uuid, eventID: eventID)
            #expect(atom.snapshot(for: paneId.uuid)?.recentURLRequests.count == 1)
            await router.stop()
            try await facts.finish()

            let outputFileURL = traceFixture.outputFileURL
            let contents = try String(contentsOf: outputFileURL, encoding: .utf8)
            #expect(contents.contains("\"body\":\"terminal.activity.observed\""))
            #expect(contents.contains("\"agentstudio.runtime.event\":\"terminal.openURLRequested\""))
            #expect(contents.contains("\"agentstudio.envelope.seq\":7"))
            #expect(contents.contains("\"agentstudio.pane.id\":\"\(paneId.uuidString)\""))
            #expect(contents.contains("\"agentstudio.envelope.correlation_id\":\"\(correlationId.uuidString)\""))
            #expect(contents.contains("\"agentstudio.session.id\":"))
        } catch {
            await router.stop()
            try? await facts.finish()
            throw error
        }
    }

    @Test("records eventbus delivery summaries for exact terminal facts")
    func recordsEventBusDeliverySummariesForExactTerminalFacts() async throws {
        let factSource = TerminalActivityRouterFactSource()
        let facts = try factSource.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let atom = TerminalActivityAtom(outputBurstThreshold: 30)
        let traceDirectory = temporaryTraceDirectoryURL()
        let traceFixture = makeTraceRuntime(
            traceDirectory: traceDirectory,
            traceName: "terminal-activity-eventbus",
            traceTags: "eventbus",
            processIdentifier: 251,
            flushMode: "immediate"
        )
        let traceRuntime = traceFixture.runtime
        let router = TerminalActivityRouter(
            bus: bus, activityAtom: atom, traceRuntime: traceRuntime, factSink: factSource.sink)
        let paneId = PaneId.generateUUIDv7()

        do {
            await router.start()
            await bus.waitForSubscriberRegistration(subscriberName: "TerminalActivityRouter")
            let eventID = UUIDv7.generate()
            _ = await bus.post(
                .pane(
                    .test(
                        event: .terminal(.openURLRequested(url: "https://example.com/eventbus", kind: .text)),
                        paneId: paneId,
                        paneKind: .terminal,
                        seq: 1,
                        eventId: eventID
                    )
                )
            )

            _ = try await facts.expectRuntimeEnvelopeHandled(paneID: paneId.uuid, eventID: eventID)
            #expect(atom.snapshot(for: paneId.uuid)?.recentURLRequests.count == 1)
            await router.stop()
            try await facts.finish()

            let outputFileURL = traceFixture.outputFileURL
            let contents = try String(contentsOf: outputFileURL, encoding: .utf8)
            let records = try traceRecords(in: outputFileURL)
            let deliveryRecords = records.filter { $0.body == "eventbus.deliver" }
            #expect(deliveryRecords.count == 1)
            let deliveryAttributes = try #require(deliveryRecords.first?.attributes)
            #expect(deliveryAttributes["agentstudio.eventbus.consumer"] == .string("TerminalActivityRouter"))
            #expect(deliveryAttributes["agentstudio.eventbus.name"] == .string("paneRuntime"))
            #expect(deliveryAttributes["agentstudio.eventbus.delivery"] == .string("consumed"))
            #expect(deliveryAttributes["agentstudio.runtime.event"] == .string("terminal.openURLRequested"))
            #expect(deliveryAttributes["agentstudio.envelope.seq"] == .int(1))
            #expect(contents.contains("\"agentstudio.eventbus.consumer\":\"TerminalActivityRouter\""))
            #expect(contents.contains("\"agentstudio.eventbus.name\":\"paneRuntime\""))
            #expect(contents.contains("\"agentstudio.eventbus.delivery\":\"consumed\""))
            #expect(contents.contains("\"agentstudio.runtime.event\":\"terminal.openURLRequested\""))
            #expect(contents.contains("\"agentstudio.envelope.seq\":1"))
        } catch {
            await router.stop()
            try? await facts.finish()
            throw error
        }
    }

    @Test("stop drains buffered terminal activity trace records")
    func stopDrainsBufferedTerminalActivityTraceRecords() async throws {
        let factSource = TerminalActivityRouterFactSource()
        let facts = try factSource.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let atom = TerminalActivityAtom(outputBurstThreshold: 30)
        let traceDirectory = temporaryTraceDirectoryURL()
        let traceFixture = makeTraceRuntime(
            traceDirectory: traceDirectory,
            traceName: "terminal-activity-drain",
            traceTags: "terminal.activity",
            processIdentifier: 247
        )
        let traceRuntime = traceFixture.runtime
        let router = TerminalActivityRouter(
            bus: bus, activityAtom: atom, traceRuntime: traceRuntime, factSink: factSource.sink)
        let paneId = PaneId.generateUUIDv7()

        do {
            await router.start()
            let eventID = UUIDv7.generate()
            _ = await bus.post(
                .pane(
                    .test(
                        event: .terminal(.openURLRequested(url: "https://example.com/drain", kind: .text)),
                        paneId: paneId,
                        paneKind: .terminal,
                        seq: 8,
                        eventId: eventID
                    )
                )
            )

            _ = try await facts.expectRuntimeEnvelopeHandled(paneID: paneId.uuid, eventID: eventID)
            #expect(atom.snapshot(for: paneId.uuid)?.recentURLRequests.count == 1)

            let outputFileURL = traceFixture.outputFileURL
            #expect(FileManager.default.fileExists(atPath: outputFileURL.path) == false)

            await router.stop()
            try await facts.finish()

            let contents = try String(contentsOf: outputFileURL, encoding: .utf8)
            #expect(contents.contains("\"body\":\"terminal.activity.observed\""))
            #expect(contents.contains("\"agentstudio.envelope.seq\":8"))
        } catch {
            await router.stop()
            try? await facts.finish()
            throw error
        }
    }

    @Test("terminal activity trace records preserve envelope arrival order")
    func terminalActivityTraceRecordsPreserveEnvelopeArrivalOrder() async throws {
        let factSource = TerminalActivityRouterFactSource()
        let facts = try factSource.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let atom = TerminalActivityAtom(outputBurstThreshold: 30)
        let traceDirectory = temporaryTraceDirectoryURL()
        let traceFixture = makeTraceRuntime(
            traceDirectory: traceDirectory,
            traceName: "terminal-activity-order",
            traceTags: "terminal.activity",
            processIdentifier: 248
        )
        let traceRuntime = traceFixture.runtime
        let router = TerminalActivityRouter(
            bus: bus, activityAtom: atom, traceRuntime: traceRuntime, factSink: factSource.sink)
        let paneId = PaneId.generateUUIDv7()

        do {
            await router.start()
            var eventIDs: [UUID] = []
            for sequence in 1...5 {
                let eventID = UUIDv7.generate()
                eventIDs.append(eventID)
                _ = await bus.post(
                    .pane(
                        .test(
                            event: .terminal(.openURLRequested(url: "https://example.com/\(sequence)", kind: .text)),
                            paneId: paneId,
                            paneKind: .terminal,
                            seq: UInt64(sequence),
                            eventId: eventID
                        )
                    )
                )
            }

            for eventID in eventIDs {
                _ = try await facts.expectRuntimeEnvelopeHandled(paneID: paneId.uuid, eventID: eventID)
            }
            #expect(atom.snapshot(for: paneId.uuid)?.recentURLRequests.count == 5)

            await router.stop()
            try await facts.finish()

            let outputFileURL = traceFixture.outputFileURL
            let sequences = try traceEnvelopeSequences(in: outputFileURL)
            #expect(sequences == [1, 2, 3, 4, 5])
        } catch {
            await router.stop()
            try? await facts.finish()
            throw error
        }
    }

    private func temporaryTraceDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agentstudio-terminal-activity-router-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeTraceRuntime(
        traceDirectory: URL,
        traceName: String,
        traceTags: String,
        processIdentifier: Int32,
        flushMode: String? = nil
    ) -> (runtime: AgentStudioTraceRuntime, outputFileURL: URL) {
        var environment = [
            "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
            "AGENTSTUDIO_TRACE_DIR": traceDirectory.path,
            "AGENTSTUDIO_TRACE_NAME": traceName,
            "AGENTSTUDIO_TRACE_TAGS": traceTags,
        ]
        environment["AGENTSTUDIO_TRACE_FLUSH"] = flushMode
        return (
            runtime: AgentStudioTraceRuntime.fromEnvironment(
                environment,
                processIdentifier: processIdentifier
            ),
            outputFileURL: traceDirectory.appendingPathComponent(
                "agentstudio-\(traceName)-\(processIdentifier).jsonl"
            )
        )
    }

    private func traceEnvelopeSequences(in fileURL: URL) throws -> [Int] {
        try traceRecords(in: fileURL).map { record in
            guard case .int(let sequence) = record.attributes["agentstudio.envelope.seq"] else {
                Issue.record("Missing integer envelope sequence in trace record")
                return -1
            }
            return sequence
        }
    }

    private func traceRecords(in fileURL: URL) throws -> [TraceRecordFixture] {
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        return try contents.split(separator: "\n").map { line in
            try JSONDecoder().decode(TraceRecordFixture.self, from: Data(line.utf8))
        }
    }
}
