import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import Testing

@Suite("Pane CLI answer bookmarks", .serialized)
struct CLIPaneContextAnswersTests {
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
