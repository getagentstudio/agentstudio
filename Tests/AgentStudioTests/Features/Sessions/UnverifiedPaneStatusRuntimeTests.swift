import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioSessions

@Suite("Unverified pane main election")
struct UnverifiedPaneStatusRuntimeTests {
    @Test("a live main excludes child sessions, releases, and fences late ordinary predecessor facts")
    func mainElectionAndResume() {
        var runtime = UnverifiedPaneStatusRuntime()
        let pane = UUIDv7.generate()
        let origin = ContinuousClock.now
        func hook(_ session: String, _ signal: SessionProviderSignal, _ offset: Int) -> SessionsHookAdmission {
            makeHookAdmission(
                paneId: pane, sessionId: session, eventName: signal.name, signal: signal,
                admissionInstant: origin + .seconds(offset), turnId: nil)
        }
        #expect(runtime.apply(hook("A", .turnStart, 0)))
        #expect(!runtime.apply(hook("child", .turnDone, 1)))
        #expect(runtime.status(paneId: pane) == .working(.active))
        #expect(runtime.apply(hook("A", .permission(toolName: nil, questions: nil), 2)))
        #expect(runtime.status(paneId: pane) == .needsYou(.approval))
        #expect(runtime.apply(hook("A", .sessionEnd, 3)))
        #expect(runtime.status(paneId: pane) == .idle(.ended))
        #expect(!runtime.apply(hook("A", .turnStart, 4)))
        #expect(runtime.apply(hook("B", .turnStart, 5)))
        #expect(!runtime.apply(hook("A", .sessionStart, 6)))
        #expect(!runtime.apply(hook("A", .turnDone, 7)))
        #expect(runtime.apply(hook("B", .sessionEnd, 8)))
        #expect(runtime.apply(hook("A", .sessionStart, 9)))
        #expect(runtime.apply(hook("A", .turnStart, 10)))
        #expect(runtime.status(paneId: pane) == .working(.active))
    }

    @Test("exit source instant must follow establishment and cannot end a newer main")
    func commandExitFence() {
        var runtime = UnverifiedPaneStatusRuntime()
        let pane = UUIDv7.generate()
        let origin = ContinuousClock.now
        let first = makeHookAdmission(
            paneId: pane, eventName: .turnStart, signal: .turnStart,
            admissionInstant: origin, turnId: nil)
        #expect(runtime.apply(first))
        runtime.commandFinished(paneId: pane, reportedAt: origin, at: .distantPast)
        #expect(runtime.status(paneId: pane) == .working(.active))
        runtime.commandFinished(paneId: pane, reportedAt: origin + .seconds(1), at: .distantPast)
        #expect(runtime.status(paneId: pane) == .idle(.ended))
        #expect(
            runtime.apply(
                makeHookAdmission(
                    paneId: pane, sessionId: "B", eventName: .turnStart,
                    signal: .turnStart, admissionInstant: origin + .seconds(3), turnId: nil)))
        runtime.commandFinished(paneId: pane, reportedAt: origin + .seconds(2), at: .distantPast)
        #expect(runtime.status(paneId: pane) == .working(.active))
    }

    @Test("done and viewed status use the shared transition rules without binding records")
    func viewedAfterDone() {
        var runtime = UnverifiedPaneStatusRuntime()
        let pane = UUIDv7.generate()
        let origin = ContinuousClock.now
        #expect(
            runtime.apply(
                makeHookAdmission(
                    paneId: pane, eventName: .turnDone, signal: .turnDone,
                    admissionInstant: origin, turnId: nil)))
        #expect(runtime.status(paneId: pane) == .idle(.done))
        runtime.viewed(paneId: pane, at: origin + .seconds(1))
        #expect(runtime.status(paneId: pane) == .idle(.ready))
    }
    @Test("a first SessionEnd reports ended without electing a live predecessor")
    func firstEndIsAppliedAndReleased() {
        var runtime = UnverifiedPaneStatusRuntime()
        let pane = UUIDv7.generate()
        #expect(runtime.apply(makeHookAdmission(paneId: pane, eventName: .sessionEnd, signal: .sessionEnd)))
        #expect(runtime.status(paneId: pane) == .idle(.ended))
        #expect(!runtime.apply(makeHookAdmission(paneId: pane, eventName: .turnStart, signal: .turnStart)))
        #expect(runtime.apply(makeHookAdmission(paneId: pane, eventName: .sessionStart, signal: .sessionStart)))
    }

}
