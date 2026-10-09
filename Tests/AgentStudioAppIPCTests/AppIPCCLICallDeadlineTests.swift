import AgentStudioAppIPC
import AgentStudioDeadlineTestSupport
import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import Testing

@Suite("App IPC CLI call deadline", .serialized)
struct AppIPCCLICallDeadlineTests {
    @Test("a CLI call whose reply-read stage passes the call limit reports outcomeUnknown")
    func replyReadDeadlineReportsUnknownOutcome() async throws {
        let submitted = HeldStep<Data>("system.capabilities request submitted")
        let heldReply = HeldStep<Data>("system.capabilities reply held before delivery")
        let driver = ControlledDeadlineDriver()
        defer { driver.close() }

        let observed = try await withLiveServer(
            makeFixture: {
                try LiveServerFixture(
                    accessMode: .unsafeDebug,
                    makeConnectionIO: { connection in
                        let live = AppIPCConnectionIO.live(connection)
                        return AppIPCConnectionIO(
                            receive: { limit in
                                let bytes = try live.receive(limit)
                                try submitted.arriveBlocking(bytes)
                                return bytes
                            },
                            send: { bytes in
                                try heldReply.arriveBlocking(bytes)
                                try live.send(bytes)
                            },
                            close: live.close
                        )
                    }
                )
            },
            releaseHeldWork: {
                submitted.release()
                heldReply.release()
            },
            body: { fixture in
                try fixture.server.start()
                let client = Task {
                    await runClientCommandLineOffCooperativePool(
                        arguments: ["system.capabilities"],
                        environment: ["AGENTSTUDIO_IPC_SOCKET": fixture.paths.socketURL.path],
                        correlationId: UUIDv7.generate(), deadlineTiming: driver.timing)
                }

                let submittedFrame = try await submitted.firstArrival()
                submitted.release()
                _ = try await heldReply.firstArrival()
                try await valueFromDedicatedThread {
                    try driver.advance(by: CLIPolicy.ordinaryCallLimit)
                }
                let outcome = await client.value
                heldReply.release()

                var decoder = NDJSONFrameDecoder(maxFrameBytes: IPCFramePolicy.maximumRequestFrameBytes)
                let requestFrame = try #require(decoder.append(submittedFrame).first)
                let request = try JSONRPCCodec.decodeRequest(requestFrame)
                #expect(request.method == "system.capabilities")
                return outcome
            }
        )

        #expect(observed.exitCode != 0)
        #expect(observed.standardError == "outcomeUnknown\n")
    }
}
