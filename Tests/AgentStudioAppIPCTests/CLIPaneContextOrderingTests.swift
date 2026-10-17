import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import Testing

@Suite("Pane CLI ordering through real processes", .serialized)
struct CLIPaneContextOrderingTests {
    @Test("two real CLI processes allocate distinct numbers in one shared store")
    func concurrentProcessesAllocateDistinctCounters() async throws {
        try await withS5PaneCLIContext { context in
            let seed = try await context.run(["title", "seed"])
            #expect(seed.terminationStatus == 0)
            guard seed.terminationStatus == 0 else { return }
            async let first = context.run(["title", "first concurrent intent"])
            async let second = context.run(["title", "second concurrent intent"])
            let results = try await [first, second]
            #expect(results.contains { $0.terminationStatus == 0 })
            let attempts = context.port.titles.filter { $0.text != "seed" }
            #expect(attempts.count == 2)
            #expect(Set(attempts.map { $0.number.counter }) == Set([UInt64(2), 3]))
            #expect(Set(attempts.map { $0.number.epoch }).count == 1)
            let stored = try await context.storedNumber()
            #expect(stored.value == 3)
            let claimID = try #require(stored.claimID)
            let parsed = try #require(UUID(uuidString: claimID))
            #expect(UUIDv7.isV7(parsed))
        }
    }

    @Test("a late claim changes no value; an old refused payload is dropped and only a distinct intent claims again")
    func lateClaimNeverResubmitsRefusedPayload() async throws {
        try await withS5PaneCLIContext { context in
            let seed = try await context.run(["title", "visible before late claim"])
            #expect(seed.terminationStatus == 0)
            guard seed.terminationStatus == 0 else { return }
            let scope = UUIDv7.generate()
            let hold = context.port.holdNextTitle(in: scope)
            let recorder = try context.port.facts.attach()
            let pending = context.launchCLIProcess(["title", "refused pending payload"], scope: scope)
            do {
                try await recorder.expectNext(in: scope, .writeEntered)
                let request = try await hold.firstArrival()
                let lateClaim = try await context.claim(UUIDv7.generate())
                #expect(lateClaim.exitCode == 0)
                let decoded = try JSONDecoder().decode(
                    IPCPaneEpochClaimResult.self, from: Data(lateClaim.standardOutput.utf8))
                let lateEpoch: UInt64
                switch decoded {
                case .claimed(let epoch): lateEpoch = epoch
                }
                #expect(lateEpoch > request.writeNumber.epoch)
                let beforeRelease = try await context.title()
                #expect(beforeRelease == "visible before late claim")
                hold.release()
                let refused = try await pending.value
                #expect(refused.terminationStatus != 0)
                let refusalText = try #require(String(bytes: refused.standardError, encoding: .utf8))
                #expect(refusalText.contains("epochSuperseded"))
                try await recorder.expectNext(in: scope, .clientExited)
                let next = try await context.run(["title", "distinct next intent"])
                #expect(next.terminationStatus == 0)
                let finalTitle = try await context.title()
                #expect(finalTitle == "distinct next intent")
                #expect(context.port.titles.filter { $0.text == "refused pending payload" }.count == 1)
                let nextAttempt = try #require(context.port.titles.last)
                #expect(nextAttempt.number.epoch > lateEpoch)
                try await recorder.finish()
            } catch {
                hold.release()
                pending.cancel()
                _ = await pending.result
                try? await recorder.finish()
                throw error
            }
        }
    }

    @Test("store recreation and a backward wall clock cannot admit a delayed old-store title")
    func storeLossRefusesOldEpochDespiteClockRollback() async throws {
        try await withS5PaneCLIContext { context in
            let seed = try await context.run(["title", "old store value"])
            #expect(seed.terminationStatus == 0)
            guard seed.terminationStatus == 0 else { return }
            let scope = UUIDv7.generate()
            let hold = context.port.holdNextTitle(in: scope)
            let recorder = try context.port.facts.attach()
            let delayed = context.launchCLIProcess(["title", "delayed old intent"], scope: scope)
            do {
                try await recorder.expectNext(in: scope, .writeEntered)
                let oldRequest = try await hold.firstArrival()
                let storeURL = context.storeURL
                try await valueFromDedicatedThread {
                    for path in [storeURL.path, storeURL.path + "-wal", storeURL.path + "-shm"] {
                        if FileManager.default.fileExists(atPath: path) {
                            try FileManager.default.removeItem(atPath: path)
                        }
                    }
                }
                let replacement = await context.runWithWallClock(
                    ["title", "replacement store value"], now: Date(timeIntervalSince1970: 1))
                #expect(replacement.exitCode == 0)
                let replacementAttempt = try #require(context.port.titles.last)
                #expect(replacementAttempt.number.epoch > oldRequest.writeNumber.epoch)
                hold.release()
                let refused = try await delayed.value
                #expect(refused.terminationStatus != 0)
                let refusalText = try #require(String(bytes: refused.standardError, encoding: .utf8))
                #expect(refusalText.contains("epochSuperseded"))
                try await recorder.expectNext(in: scope, .clientExited)
                let finalTitle = try await context.title()
                #expect(finalTitle == "replacement store value")
                #expect(context.port.titles.filter { $0.text == "delayed old intent" }.count == 1)
                try await recorder.finish()
            } catch {
                hold.release()
                delayed.cancel()
                _ = await delayed.result
                try? await recorder.finish()
                throw error
            }
        }
    }

    @Test("a lower counter is final and the next distinct intent starts above lastAccepted")
    func lastAcceptedAdvancesOnlyTheNextIntent() async throws {
        try await withS5PaneCLIContext { context in
            let seed = try await context.run(["title", "seed before competing counter"])
            #expect(seed.terminationStatus == 0)
            guard seed.terminationStatus == 0 else { return }
            let first = try #require(context.port.titles.first)
            let parameters = IPCPaneTitleSetParams(
                handle: "self", writer: context.writer,
                text: "higher accepted title", writeNumber: .init(epoch: first.number.epoch, counter: 17),
                correlationId: UUIDv7.generate())
            let bytes = try JSONEncoder().encode(parameters)
            let json = try #require(String(data: bytes, encoding: .utf8))
            let competing = await runClientCommandLineOffCooperativePool(
                arguments: ["pane.title.set", "--json", json], environment: context.environment)
            #expect(competing.exitCode == 0)
            let refused = try await context.run(["title", "lower counter payload"])
            #expect(refused.terminationStatus != 0)
            let refusalText = try #require(String(bytes: refused.standardError, encoding: .utf8))
            #expect(refusalText.contains("lastAccepted"))
            let visible = try await context.title()
            #expect(visible == "higher accepted title")
            let afterRefusal = try await context.storedNumber()
            #expect(afterRefusal.value == 17)
            let next = try await context.run(["title", "next distinct counter intent"])
            #expect(next.terminationStatus == 0)
            let last = try #require(context.port.titles.last)
            #expect(last.number == .init(epoch: first.number.epoch, counter: 18))
            #expect(context.port.titles.filter { $0.text == "lower counter payload" }.count == 1)
            let finalTitle = try await context.title()
            #expect(finalTitle == "next distinct counter intent")
        }
    }

    @Test("a lost epoch-claim reply retries the durable claim identity without applying the old payload")
    func lostClaimReplyReusesClaimID() async throws {
        try await withS5PaneCLIContext(dropFirstClaimReply: true) { context in
            let first = try await context.run(["title", "payload before lost claim reply"])
            #expect(first.terminationStatus != 0)
            #expect(context.port.titles.isEmpty)
            let firstClaim = try #require(context.port.claims.first)
            let pendingState = try await context.storedNumber()
            #expect(pendingState.claimID == firstClaim.claimId.uuidString)
            #expect(pendingState.epoch == nil)
            let second = try await context.run(["title", "distinct intent after lost claim reply"])
            #expect(second.terminationStatus == 0)
            #expect(context.port.claims.count == 2)
            #expect(context.port.claims.allSatisfy { $0.claimId == firstClaim.claimId })
            let finalTitle = try await context.title()
            #expect(finalTitle == "distinct intent after lost claim reply")
            #expect(context.port.titles.count == 1)
        }
    }
}
