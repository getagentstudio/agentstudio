import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import Testing

@Suite("Pane CLI answer bookmarks", .serialized)
struct CLIPaneContextAnswersTests {
    @Test("answers prints every page before saving its bookmark and consumes all returned pages")
    func answersPagesBeforeStoringPosition() async throws {
        try await withS5PaneCLIContext(changesPageSize: 1) { context in
            let firstId = try await context.seedAnswer("first answer")
            let secondId = try await context.seedAnswer("second answer")
            let (output, observations) = await context.runAnswersRecordingBookmarks()
            #expect(output.exitCode == 0)
            let pages = try output.standardOutput.split(separator: "\n").map {
                try JSONDecoder().decode(IPCPaneMessageChangesResult.self, from: Data($0.utf8))
            }
            #expect(pages.count == 2)
            let first = try #require(pages.first)
            let last = try #require(pages.last)
            #expect(first.more)
            #expect(!last.more)
            #expect(first.entries.map(\.messageId) == [firstId])
            #expect(last.entries.map(\.messageId) == [secondId])
            let bookmarks = try observations.map { try $0.get() }
            #expect(bookmarks == [0, Int64(first.nextPosition)])
            #expect(context.port.changes.map(\.after) == [0, first.nextPosition])
            #expect(context.port.changes.first?.correlationId != context.port.changes.last?.correlationId)
            let storedPosition = try await context.storedAnswerPosition()
            #expect(storedPosition == Int64(last.nextPosition))
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
