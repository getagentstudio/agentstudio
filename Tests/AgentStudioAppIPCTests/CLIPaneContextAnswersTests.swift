import AgentStudioCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import Testing

@Suite("Pane CLI answer bookmarks", .serialized)
struct CLIPaneContextAnswersTests {
    @Test("answers uses one authenticated exchange and prints one complete document before saving its bookmark")
    func answersPagesBeforeStoringPosition() async throws {
        try await withS5PaneCLIContext(changesPageSize: 1) { context in
            let firstId = try await context.seedAnswer("first answer")
            let secondId = try await context.seedAnswer("second answer")
            let (output, observations) = await context.runAnswersRecordingBookmarks()
            #expect(output.exitCode == 0)
            let complete = try JSONDecoder().decode(
                IPCPaneMessageChangesResult.self, from: Data(output.standardOutput.utf8))
            #expect(!complete.more)
            #expect(complete.entries.map(\.messageId) == [firstId, secondId])
            let firstEntry = try #require(complete.entries.first)
            let lastEntry = try #require(complete.entries.last)
            #expect(complete.nextPosition == lastEntry.position)
            let bookmarks = try observations.map { try $0.get() }
            #expect(bookmarks == [0])
            #expect(context.port.wire.connections == 1)
            #expect(context.port.wire.methods == ["auth.login", "pane.message.changes", "pane.message.changes"])
            #expect(context.port.changes.map(\.after) == [0, firstEntry.position])
            #expect(context.port.changes.first?.correlationId != context.port.changes.last?.correlationId)
            let storedPosition = try await context.storedAnswerPosition()
            #expect(storedPosition == Int64(complete.nextPosition))
        }
    }
    @Test("an interrupted second answer page prints the received page before storing its bookmark")
    func interruptedAnswersPrintReceivedPage() async throws {
        let held = HeldStep<Data>("S6 second answer page before physical write")
        try await withS5PaneCLIContext(heldReply: (.number(3), held), changesPageSize: 1) { context in
            let firstId = try await context.seedAnswer("first answer")
            let secondId = try await context.seedAnswer("second answer")
            async let pending = context.runAnswersRecordingBookmarks()
            do {
                let bytes = try await held.firstArrival()
                let frame = try #require(String(data: bytes, encoding: .utf8))
                let response = try JSONRPCCodec.decodeResponse(frame)
                #expect(response.id == .number(3))
                let result = try #require(response.result)
                let secondPage = try JSONDecoder().decode(
                    IPCPaneMessageChangesResult.self, from: JSONEncoder().encode(result))
                #expect(secondPage.entries.map(\.messageId) == [secondId])
                let secondRequest = try #require(context.port.changes.last)
                let firstPosition = secondRequest.after
                #expect(firstPosition > 0)
                let detailResult = await context.domain.service.readDetail(
                    .init(paneId: PaneId(existingUUID: context.domain.paneId), page: .first))
                guard case .detail(let detail) = detailResult,
                    let firstMessage = detail.messages.first(where: { $0.id.uuid == firstId }),
                    case .ask(_, _, _, .answered(_, _, .confirmed)) = firstMessage.shape
                else {
                    Issue.record("The second request must confirm the first answer before its reply is written")
                    throw S5CLIFixtureError.unavailableDetail
                }
                held.fail(UnixSocketTransportError(reason: .writeFailed))
                let (output, observations) = await pending
                #expect(output.exitCode == 0)
                let received = try JSONDecoder().decode(
                    IPCPaneMessageChangesResult.self, from: Data(output.standardOutput.utf8))
                #expect(received.entries.map(\.messageId) == [firstId])
                #expect(received.more)
                #expect(received.nextPosition == firstPosition)
                let bookmarks = try observations.map { try $0.get() }
                #expect(bookmarks == [0])
                let stored = try await context.storedAnswerPosition()
                #expect(stored == Int64(firstPosition))
                #expect(output.standardError == "answers interrupted; read again")
                #expect(context.port.wire.connections == 1)
                #expect(context.port.wire.methods == ["auth.login", "pane.message.changes", "pane.message.changes"])
            } catch {
                held.fail(error)
                _ = await pending
                throw error
            }
        }
    }

    @Test("a late older answers response cannot move the shared bookmark backward")
    func concurrentAnswersOnlyAdvancePosition() async throws {
        try await withS5PaneCLIContext { context in
            _ = try await context.seedAnswer("first answer")
            let scope = UUIDv7.generate()
            let hold = context.port.holdNextChanges(in: scope)
            let recorder = try context.port.facts.attach()
            let older = context.launchCLIProcess(["answers"], scope: scope)
            do {
                try await recorder.expectNext(in: scope, .changesRead)
                let firstPage = try await hold.firstArrival()
                #expect(firstPage.nextPosition > 0)
                _ = try await context.seedAnswer("second answer")
                let newer = try await context.run(["answers"])
                #expect(newer.terminationStatus == 0)
                let newerPosition = try await context.storedAnswerPosition()
                let advanced = try #require(newerPosition)
                #expect(advanced > Int64(firstPage.nextPosition))
                hold.release()
                let olderOutput = try await older.value
                #expect(olderOutput.terminationStatus == 0)
                try await recorder.expectNext(in: scope, .clientExited)
                let retained = try await context.storedAnswerPosition()
                #expect(retained == advanced)
                let finalRead = try await context.run(["answers"])
                #expect(finalRead.terminationStatus == 0)
                let finalRequest = try #require(context.port.changes.last)
                #expect(finalRequest.after == UInt64(advanced))
                try await recorder.finish()
            } catch {
                hold.release()
                older.cancel()
                _ = await older.result
                try? await recorder.finish()
                throw error
            }
        }
    }
}
