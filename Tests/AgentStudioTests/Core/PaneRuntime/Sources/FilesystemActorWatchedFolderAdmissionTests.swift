import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import CoreServices
import Foundation
import Testing

@testable import AgentStudioCore

enum WatchedFolderIngressFact: Sendable {
    case scanSubmitted(rootID: UUID)
    case ingressClosed
}

extension FilesystemActorWatchedFolderTests {
    enum OverflowAdmissionScenario: CaseIterable, Sendable {
        case nestedAndKnownDirectory, headUpdate, renamedRefs, outsideDirectory, coarse, fullRefresh, coverageLoss

        var expectsScan: Bool {
            switch self {
            case .nestedAndKnownDirectory: false
            case .headUpdate, .renamedRefs, .outsideDirectory, .coarse, .fullRefresh, .coverageLoss: true
            }
        }

        func droppedBatch(callbackID: UUID, checkout: URL, watchedFolder: URL) -> FSEventBatch {
            let paths: [String]
            let observations: [FSEventObservation]
            switch self {
            case .nestedAndKnownDirectory, .coarse, .fullRefresh:
                paths = [
                    checkout.appending(path: ".build-agent-1/checkouts/dep/.git/index").path,
                    checkout.appending(path: "Sources/Generated").path,
                ]
                observations = [
                    .init(path: paths[0], eventID: 2, flags: UInt32(kFSEventStreamEventFlagItemModified)),
                    .init(
                        path: paths[1], eventID: 3,
                        flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated)),
                ]
            case .headUpdate:
                paths = [checkout.appending(path: ".git/HEAD").path]
                observations = [.init(path: paths[0], eventID: 2, flags: UInt32(kFSEventStreamEventFlagItemRenamed))]
            case .renamedRefs:
                paths = [checkout.appending(path: ".git/refs").path, checkout.appending(path: "backup-refs").path]
                observations = paths.enumerated().map { offset, path in
                    .init(
                        path: path, eventID: UInt64(offset + 2),
                        flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed))
                }
            case .outsideDirectory:
                paths = [watchedFolder.appending(path: "new-repository").path]
                observations = [
                    .init(
                        path: paths[0], eventID: 2,
                        flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated))
                ]
            case .coverageLoss:
                paths = [checkout.appending(path: ".build-agent-1/checkouts/dep/.git/index").path]
                observations = [
                    .init(path: paths[0], eventID: 2, flags: UInt32(kFSEventStreamEventFlagItemModified)),
                    .init(path: "/", eventID: 3, flags: UInt32(kFSEventStreamEventFlagUserDropped)),
                ]
            }
            return .init(
                worktreeId: callbackID, paths: paths, observations: observations,
                requiresFullGitRefresh: self == .fullRefresh)
        }
    }

    @Test(
        "watched-folder overflow uses scoped admission and preserves coarse recovery",
        arguments: OverflowAdmissionScenario.allCases)
    func overflowAdmissionUsesRealIngressBuffer(_ scenario: OverflowAdmissionScenario) async throws {
        // Arrange
        let operationID = UUIDv7.generate()
        let source = makeWatchedFolderIngressFacts()
        let recorder = try source.attach()
        let buffer = DarwinFSEventIngressBuffer(
            capacity: 1, maximumRetainedOverflowPathsPerRegistration: scenario == .coarse ? 1 : 4)
        let client = ControllableFSEventStreamClient(ingressBuffer: buffer)
        let fixture = try await WatchedFolderActorFixture(
            fseventClient: client,
            onCallbackSubmission: { request in source.sink(operationID, .scanSubmitted(rootID: request.sourceID.rootID))
            })
        defer { fixture.removeTemporaryRoot() }
        let checkout = fixture.watchedFolder.appending(path: "repo")
        _ = await fixture.performInitialRefresh(result: completeResult(entries: [cloneEntry(checkout)]))
        let terminals = await fixture.actor.runtimeTerminals()
        let closingCollector = Task {
            for await terminal in terminals {
                if case .eventsEnded = terminal {
                    source.sink(operationID, .ingressClosed)
                    return
                }
            }
        }
        let callbackID = try #require(client.registeredWorktreeIds.first)

        do {
            // Hold the existing ingress submission so the bounded buffer has no consumer.
            await fixture.submissionGate.arm()
            client.send(.init(worktreeId: callbackID, paths: [checkout.appending(path: ".git/config").path]))
            let heldSubmission = try await fixture.submissionGate.waitForHeldSubmission()
            #expect(heldSubmission.sourceID.rootID == fixture.watchedPath.id)
            #expect(heldSubmission.cause == .callback)
            _ = try await recorder.expectNext(
                in: operationID,
                where: {
                    if case .scanSubmitted = $0 { return true }
                    return false
                },
                "setup submission at the held ingress boundary")
            let opening = await recorder.mark(operationID)
            client.send(.init(worktreeId: callbackID, paths: [checkout.appending(path: "Sources/retained.swift").path]))
            // Act: this batch must drop into recovery; finish closes only after the owner drains it.
            client.send(
                scenario.droppedBatch(callbackID: callbackID, checkout: checkout, watchedFolder: fixture.watchedFolder))
            client.shutdown()
            await fixture.submissionGate.open()

            // Assert
            if scenario.expectsScan {
                _ = try await recorder.expectNext(
                    in: operationID,
                    where: {
                        if case .scanSubmitted = $0 { return true }
                        return false
                    },
                    "one recovered membership scan submission")
                _ = try await recorder.expectNext(
                    in: operationID,
                    where: {
                        if case .ingressClosed = $0 { return true }
                        return false
                    },
                    "correlated recovered ingress close")
            } else {
                try await recorder.expectNone(
                    of: {
                        if case .scanSubmitted = $0 { return true }
                        return false
                    },
                    "scan from scoped checkout churn", from: opening,
                    closedBy: {
                        if case .ingressClosed = $0 { return true }
                        return false
                    })
            }
        } catch {
            await fixture.submissionGate.open()
            closingCollector.cancel()
            await fixture.shutdown()
            await closingCollector.value
            source.end()
            try? await recorder.finish()
            throw error
        }
        await closingCollector.value
        await fixture.shutdown()
        source.end()
        try await recorder.finish()
    }

    enum GitAdmissionScenario: CaseIterable, Sendable {
        case routineAndNestedChurn, linkedMembership, originConfig, mainHead, linkedHead, renamedRefs, renamedObjects

        var expectsScan: Bool { self != .routineAndNestedChurn }

        func ingressBatch(callbackID: UUID, checkout: URL) -> FSEventBatch {
            let relativePaths: [String]
            let flags: UInt32
            switch self {
            case .routineAndNestedChurn:
                relativePaths = [
                    ".build-agent-1/checkouts/dep/.git/index", ".build-agent-1/checkouts/dep/.git/config",
                    ".build-agent-1/checkouts/dep/.git/HEAD", ".git/index", ".git/objects/aa/bb", ".git/logs/HEAD",
                ]
                flags = UInt32(kFSEventStreamEventFlagItemModified)
            case .linkedMembership:
                relativePaths = [".git/worktrees/new"]
                flags = UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated)
            case .originConfig:
                relativePaths = [".git/config"]
                flags = UInt32(kFSEventStreamEventFlagItemModified)
            case .mainHead, .linkedHead:
                relativePaths = [self == .mainHead ? ".git/HEAD" : ".git/worktrees/new/HEAD"]
                flags = UInt32(kFSEventStreamEventFlagItemModified)
            case .renamedRefs, .renamedObjects:
                relativePaths =
                    self == .renamedRefs ? [".git/refs", "backup-refs"] : [".git/objects", "backup-objects"]
                flags = UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed)
            }
            let paths = relativePaths.map { checkout.appending(path: $0).path }
            return .init(
                worktreeId: callbackID, paths: paths,
                observations: paths.map { .init(path: $0, eventID: 1, flags: flags) })
        }
    }

    @Test(
        "watched-folder ingress contracts Git churn and preserves discovery inputs",
        arguments: GitAdmissionScenario.allCases)
    func gitChurnAdmissionUsesRealWatchedFolderIngress(_ scenario: GitAdmissionScenario) async throws {
        // Arrange
        let operationID = UUIDv7.generate()
        let source = makeWatchedFolderIngressFacts()
        let recorder = try source.attach()
        let fixture = try await WatchedFolderActorFixture(
            onCallbackSubmission: { request in
                source.sink(operationID, .scanSubmitted(rootID: request.sourceID.rootID))
            })
        defer { fixture.removeTemporaryRoot() }
        let checkout = fixture.watchedFolder.appending(path: "repo")
        _ = await fixture.performInitialRefresh(result: completeResult(entries: [cloneEntry(checkout)]))
        let terminals = await fixture.actor.runtimeTerminals()
        let closingCollector = Task {
            for await terminal in terminals {
                if case .eventsEnded = terminal {
                    source.sink(operationID, .ingressClosed)
                    return
                }
            }
        }
        let callbackID = try #require(fixture.fseventClient.registeredWorktreeIds.first)
        let batch = scenario.ingressBatch(callbackID: callbackID, checkout: checkout)
        let opening = await recorder.mark(operationID)

        do {
            // Act: the owner's stream-end fact closes all accepted ingress and overflow processing.
            fixture.fseventClient.send(batch)
            fixture.fseventClient.shutdown()

            // Assert
            if scenario.expectsScan {
                _ = try await recorder.expectNext(
                    in: operationID,
                    where: {
                        if case .scanSubmitted(let rootID) = $0 { return rootID == fixture.watchedPath.id }
                        return false
                    }, "one scan submission for discovery input")
                _ = try await recorder.expectNext(
                    in: operationID,
                    where: {
                        if case .ingressClosed = $0 { return true }
                        return false
                    },
                    "correlated watched-folder ingress close")
            } else {
                try await recorder.expectNone(
                    of: {
                        if case .scanSubmitted = $0 { return true }
                        return false
                    },
                    "scan submission from routine or nested Git churn", from: opening,
                    closedBy: {
                        if case .ingressClosed = $0 { return true }
                        return false
                    })
            }
        } catch {
            closingCollector.cancel()
            await fixture.shutdown()
            await closingCollector.value
            source.end()
            try? await recorder.finish()
            throw error
        }
        await closingCollector.value
        await fixture.shutdown()
        source.end()
        try await recorder.finish()
    }
}

func makeWatchedFolderIngressFacts() -> LocalFactSource<UUID, WatchedFolderIngressFact> {
    LocalFactSource(
        vocabulary: .init(
            describeScope: { $0.uuidString }, describeFact: { String(describing: $0) },
            isClosing: { _, fact in
                if case .ingressClosed = fact { return true }
                return false
            }))
}
