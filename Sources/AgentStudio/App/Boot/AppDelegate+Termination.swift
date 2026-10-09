import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTerminal
import AppKit
import Foundation

private let terminationTraceDrainTimeout: Duration = AppPolicies.IPC.shutdownDrainTimeout

private final class TerminationDrainCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(_ continuation: CheckedContinuation<Bool, Never>, value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume(returning: value)
    }
}

package enum TerminationDrainOutcome: Equatable, Sendable {
    case completed
    case timedOut
}

/// AppKit's `.terminateLater` contract has exactly one exit: the reply. An
/// unbounded await anywhere in the drain therefore does not delay the quit, it
/// abandons it — the process stays alive at 0% CPU inside
/// `-[NSApplication _shouldTerminate]` with no further event to wake it. The
/// deadline makes the reply unconditional and reports which side won.
@MainActor
func replyToApplicationTerminationAfterBoundedDrain(
    timeout: Duration,
    delay: AsyncDelay = .taskSleep,
    drain: @escaping @MainActor () async -> Void,
    reply: @escaping @MainActor (TerminationDrainOutcome) -> Void
) async {
    reply(await runWithTerminationDeadline(timeout: timeout, delay: delay, operation: drain))
}

/// AppKit exits the process inside a committed
/// `replyToApplicationShouldTerminate(true)`, so a reply that returns means
/// AppKit cancelled the quit after the drain had already shut subsystems
/// down. On 2026-09-24 a modifier-key exception inside `_shouldTerminate` did
/// exactly that and left a live app that nothing could drive or quit. Our
/// delegate never cancels a quit itself, so the quit is finished instead.
@MainActor
func replyToTerminationFinishingIfCancelled(
    reply: @MainActor () -> Void,
    finishCancelledTermination: @MainActor () -> Void
) {
    reply()
    finishCancelledTermination()
}

/// Races one termination stage against its deadline and reports which side won.
/// Nothing here cancels the stage: a stage that overruns keeps running, it just
/// stops being able to hold up what follows.
@MainActor
func runWithTerminationDeadline(
    timeout: Duration,
    delay: AsyncDelay = .taskSleep,
    operation: @escaping @MainActor () async -> Void
) async -> TerminationDrainOutcome {
    let didComplete = await withCheckedContinuation { continuation in
        let completion = TerminationDrainCompletion()
        Task { @MainActor in
            await operation()
            completion.resume(continuation, value: true)
        }
        Task {
            try? await delay.wait(timeout)
            completion.resume(continuation, value: false)
        }
    }
    return didComplete ? .completed : .timedOut
}

/// The workspace flush must never lose its budget to the IPC drain. Decision AB
/// accepts a non-durable credential window at process end, so the drain is the
/// least important stage; a workspace layout that never reached disk is not
/// recoverable at all. The drain therefore runs after the flush, under its own
/// bound, and its overrun costs nothing that was still unwritten.
@MainActor
func runBoundedIPCDrainAfterWorkspaceFlush(
    timeout: Duration,
    delay: AsyncDelay = .taskSleep,
    workspaceFlush: @MainActor () async -> Void,
    ipcDrain: @escaping @MainActor () async -> Void
) async -> TerminationDrainOutcome {
    await workspaceFlush()
    return await runWithTerminationDeadline(timeout: timeout, delay: delay, operation: ipcDrain)
}

@MainActor
func runFirstPersistenceFlushAfterWorkspaceCacheShutdown(
    workspaceCacheCoordinator: WorkspaceCacheCoordinator?,
    firstPersistenceFlush: @MainActor () async -> Void
) async {
    await workspaceCacheCoordinator?.shutdown()
    await firstPersistenceFlush()
}

extension AppDelegate {
    func flushApplicationStateBeforeTermination(store: WorkspaceStore) async {
        // Ingress closes first. Nothing durable happens in this stage, and
        // leaving the socket open across the flushes below would let a late
        // IPC request mutate state the workspace flush had already written.
        await runTerminationDrain("IPC stop") { [weak self] in
            self?.startupTraceRecorder.recordAppStartup(
                "app.termination.ipc_stop", phase: "started", outcome: "started"
            )
            await self?.stopAcceptingAppIPCConnections()
            self?.startupTraceRecorder.recordAppStartup(
                "app.termination.ipc_stop", phase: "completed", outcome: "completed"
            )
        }
        stopWorkspacePaneRecencyObservation()

        await runFirstPersistenceFlushAfterWorkspaceCacheShutdown(
            workspaceCacheCoordinator: workspaceCacheCoordinator
        ) {
            do {
                try await self.repoCacheStore.flushAsync(for: store.identityAtom.workspaceId)
            } catch {
                appLogger.warning("Workspace cache flush failed at termination: \(error.localizedDescription)")
            }
        }

        do {
            try await entityRecencyStore.flushAllAsync()
        } catch {
            appLogger.warning("Entity recency flush failed at termination: \(error.localizedDescription)")
        }

        do {
            try await repositoryTopologyStore.flushAsync()
        } catch {
            appLogger.warning("Repository topology flush failed at termination: \(error.localizedDescription)")
        }

        do {
            try await sidebarCacheStore.flushAsync(for: store.identityAtom.workspaceId)
        } catch {
            appLogger.warning("Sidebar cache flush failed at termination: \(error.localizedDescription)")
        }

        do {
            try await uiStateStore.flushAsync(for: store.identityAtom.workspaceId)
        } catch {
            appLogger.warning("Workspace UI flush failed at termination: \(error.localizedDescription)")
        }

        do {
            try await workspaceSettingsStore.flush(for: store.identityAtom.workspaceId)
        } catch {
            appLogger.warning("Workspace settings flush failed at termination: \(error.localizedDescription)")
        }

        await runTerminationDrain("Ghostty action trace") { [weak self] in
            await self?.callbackHandlingForBoot().retire()
        }
        await runTerminationDrain("terminal activity trace") { [weak self] in
            await self?.terminalActivityRouter?.stop()
        }
        await runTerminationDrain("pane activity clock") { [weak self] in
            await self?.paneActivityClock?.shutdown()
        }
        await runTerminationDrain("trace identity refresh") { [weak self] in
            await self?.waitForTraceIdentityRefreshIdle()
        }

        await runTerminationDrain("startup trace") { [weak self] in
            try? await self?.startupTraceRecorder.drain()
        }
        await runTerminationDrain("performance trace") { [weak self] in
            try? await self?.performanceTraceRecorder?.drain()
        }

        let ipcDrainOutcome = await runBoundedIPCDrainAfterWorkspaceFlush(
            timeout: AppPolicies.IPC.shutdownDrainTimeout,
            workspaceFlush: {
                // Always flush on quit — the pre-persist hook syncs runtime webview
                // state back to the pane model, so this must run even when
                // isDirty == false.
                if !(await store.flushAsync()).succeeded {
                    appLogger.warning("Workspace flush failed at termination")
                }
            },
            ipcDrain: { [weak self] in
                self?.startupTraceRecorder.recordAppStartup(
                    "app.termination.ipc_drain", phase: "started", outcome: "started"
                )
                await self?.drainAppIPCCredentialPersistence()
                self?.startupTraceRecorder.recordAppStartup(
                    "app.termination.ipc_drain", phase: "completed", outcome: "completed"
                )
            }
        )
        if ipcDrainOutcome == .timedOut {
            appLogger.warning("IPC drain timed out at termination; continuing shutdown")
        }

        await runTerminationDrain("trace flush") { [weak self] in
            do {
                try await self?.traceRuntime?.flush()
            } catch {
                appLogger.warning("Trace flush failed at termination: \(error.localizedDescription)")
            }
        }

        await runTerminationDrain("trace shutdown") { [weak self] in
            do {
                try await self?.traceRuntime?.shutdown()
            } catch {
                appLogger.warning("Trace shutdown failed at termination: \(error.localizedDescription)")
            }
        }
    }

    private func runTerminationDrain(
        _ name: String,
        operation: @escaping @MainActor () async -> Void
    ) async {
        let outcome = await runWithTerminationDeadline(
            timeout: terminationTraceDrainTimeout, operation: operation
        )
        if outcome == .timedOut {
            appLogger.warning("\(name) drain timed out at termination; continuing shutdown")
        }
    }
}
