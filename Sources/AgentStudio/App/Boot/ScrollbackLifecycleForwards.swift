import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTerminal

/// Uses the existing first-frame gate and preserves its fallback outcome.
/// Scheduling and fact emission remain on the snapshotter actor.
@MainActor
func startScrollbackAfterFirstFrame(
    windowLifecycleStore: WindowLifecycleAtom, snapshotter: ScrollbackSnapshotter?
) async -> StartupDeferralOutcome {
    await snapshotter?.announceFirstFrameWait()
    let outcome = await windowLifecycleStore.waitUntilFirstInteractiveFramePublished()
    guard outcome != .cancelled else { return outcome }
    await snapshotter?.startAfterFirstFrame()
    return outcome
}

@MainActor
func captureScrollbackBeforeSurfaceShutdown(
    snapshotter: ScrollbackSnapshotter, budget: Duration, shutdown: () async -> Void
) async {
    _ = await snapshotter.captureForQuit(requestID: UUIDv7.generate(), budget: budget)
    await shutdown()
}
