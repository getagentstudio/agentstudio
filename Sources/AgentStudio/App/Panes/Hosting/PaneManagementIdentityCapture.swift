import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioSessions
import Foundation
import Observation

/// App captures keyed facts; the existing sidebar projection builds the display lines.
@MainActor
enum PaneManagementIdentityCapture {
    struct SessionReadTrigger: Equatable {
        let paneId: UUID
        let presentation: PaneAgentStatusPresentation?
    }

    struct LineInput: Equatable, Sendable {
        let paneId: UUID
        let terminalTitle: String
        let cwd: URL?
        let shellExecutablePath: String?
        let agentTitle: String?
        let note: String?
        let isDrawer: Bool
        let agentLine: AgentLineDetail?
        let sessionPresentation: PaneAgentStatusPresentation?
        var activityTime: PaneActivityTime?
    }

    struct Presentation: Equatable, Sendable {
        let lines: [RepoExplorerPaneRowLine]
        let recencyText: String
        let recencyTier: RepoExplorerPaneRecencyTier
        let isActive: Bool
    }

    static func input(
        context: PaneManagementContext, store: WorkspaceStore, readers: PaneContextUIReaders?
    ) -> LineInput {
        let paneId = PaneId(existingUUID: context.paneId)
        let pane = store.paneAtom.pane(context.paneId)
        let display = readers?.contextDisplayForPane(paneId)
        return LineInput(
            paneId: context.paneId,
            terminalTitle: pane?.title ?? "Terminal", cwd: pane?.metadata.facets.cwd,
            shellExecutablePath: pane?.metadata.contentType == .terminal
                ? SessionConfiguration.defaultShell() : nil,
            agentTitle: display?.agentTitle,
            note: atom(\.paneDisplay).displayParts(for: context.paneId).note,
            isDrawer: readers?.isDrawerPane(paneId) ?? false,
            agentLine: display?.agentLine,
            sessionPresentation: readers?.sessionStatusForPane(paneId),
            activityTime: atom(\.paneActivityTime).value(for: context.paneId))
    }

    @concurrent nonisolated static func lines(_ input: LineInput) async -> [RepoExplorerPaneRowLine] {
        let title =
            input.agentTitle
            ?? RepoExplorerPaneTitleNormalizer.normalizedTitle(
                liveTitle: input.terminalTitle, cwd: input.cwd,
                shellExecutablePath: input.shellExecutablePath)
        return RepoExplorerPaneRowVariants.informationLines(
            title: title, note: input.note, agentLine: input.agentLine,
            sessionStatus: input.sessionPresentation?.status,
            connectionIssue: input.sessionPresentation?.connectionIssue)
    }

    static func verifiedLiveSession(paneId: UUID, readers: PaneContextUIReaders?) async
        -> SessionSummary?
    {
        guard let readers,
            let result = try? await readers.readSessionStatus(.init(existingUUID: paneId)),
            case .live(let summary) = result
        else { return nil }
        return summary
    }

    @concurrent nonisolated static func watch<C: Clock>(
        _ input: LineInput, clock: C,
        referenceInstant suppliedReference: ContinuousClock.Instant? = nil,
        wallNow suppliedWallDate: Date? = nil, calendar: Calendar = .current,
        publish: @MainActor @Sendable (Presentation) -> Void
    ) async where C.Duration == Duration {
        let clockReference = clock.now
        let referenceInstant = suppliedReference ?? ContinuousClock.now
        let wallNow = suppliedWallDate ?? Date.now
        let preparedLines = await lines(input)
        var previous: Presentation?
        while !Task.isCancelled {
            let elapsed = clockReference.duration(to: clock.now)
            let parts = elapsed.components
            let elapsedSeconds =
                Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
            let currentWallDate = wallNow.addingTimeInterval(elapsedSeconds)
            let activity = RepoExplorerPaneActivityProjection.make(
                time: input.activityTime, referenceInstant: referenceInstant.advanced(by: elapsed),
                wallNow: currentWallDate, calendar: calendar)
            let prepared = Presentation(
                lines: preparedLines, recencyText: activity.clockText,
                recencyTier: activity.recencyTier, isActive: activity.isActive)
            if prepared != previous {
                guard !Task.isCancelled else { return }
                await publish(prepared)
                previous = prepared
            }
            guard let nextDate = activity.nextPresentationChangeDate else { return }
            let deadline = clockReference.advanced(
                by: elapsed + .seconds(nextDate.timeIntervalSince(currentWallDate)))
            do {
                try await clock.sleep(until: deadline, tolerance: nil)
            } catch {
                return
            }
        }
    }
}

/// Owns one visible pane card's relative-time worker and its transition receipts.
@MainActor
@Observable
final class PaneCardRelativeTimeRefresh {
    enum StartResult: Equatable, Sendable {
        case started
        case unchanged
        case replaced(cancelRequested: Bool)
    }

    enum HideResult: Equatable, Sendable {
        case cancelled(requested: Bool)
        case notRunning
    }

    enum WorkerOutcome: Equatable, Sendable { case completed, cancelled }

    enum Event: Equatable, Sendable {
        case operation(PaneManagementIdentityCapture.LineInput, StartResult)
        case hidden(HideResult)
        case entered(PaneManagementIdentityCapture.LineInput)
        case ended(PaneManagementIdentityCapture.LineInput, WorkerOutcome)
    }

    private struct Worker: Sendable {
        let input: PaneManagementIdentityCapture.LineInput
        let id: UUID
        let task: Task<Void, Never>
    }

    private(set) var presentation: PaneManagementIdentityCapture.Presentation?
    @ObservationIgnored private var worker: Worker?
    @ObservationIgnored private let onEvent: @MainActor @Sendable (Event) -> Void

    init(onEvent: @escaping @MainActor @Sendable (Event) -> Void = { _ in }) {
        self.onEvent = onEvent
    }

    isolated deinit { worker?.task.cancel() }

    @discardableResult
    func startOrReplace<C: Clock>(
        _ input: PaneManagementIdentityCapture.LineInput, clock: C
    ) -> StartResult where C.Duration == Duration, C.Instant == ContinuousClock.Instant {
        if worker?.input == input {
            onEvent(.operation(input, .unchanged))
            return .unchanged
        }
        let result: StartResult
        if let previous = worker {
            previous.task.cancel()
            result = .replaced(cancelRequested: previous.task.isCancelled)
        } else {
            result = .started
        }
        let id = UUIDv7.generate()
        let onEvent = onEvent
        let task = Task { [weak self] in
            onEvent(.entered(input))
            defer {
                if self?.worker?.id == id { self?.worker = nil }
                onEvent(.ended(input, Task.isCancelled ? .cancelled : .completed))
            }
            await PaneManagementIdentityCapture.watch(
                input, clock: clock, referenceInstant: clock.now
            ) { [weak self] prepared in
                guard let self, !Task.isCancelled, self.worker?.id == id, self.presentation != prepared else { return }
                self.presentation = prepared
            }
        }
        worker = Worker(input: input, id: id, task: task)
        onEvent(.operation(input, result))
        return result
    }

    @discardableResult
    func hide() -> HideResult {
        guard let previous = worker else {
            onEvent(.hidden(.notRunning))
            return .notRunning
        }
        worker = nil
        previous.task.cancel()
        let result = HideResult.cancelled(requested: previous.task.isCancelled)
        presentation = nil
        onEvent(.hidden(result))
        return result
    }
}
