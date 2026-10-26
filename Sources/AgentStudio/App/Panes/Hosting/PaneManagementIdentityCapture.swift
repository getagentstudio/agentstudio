import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioSessions
import AgentStudioSharedComponents
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
        var contextDisplay: PaneContextDisplay?
        var scopedPresentations: [PaneContextCardScopePresentation] = []
        var selectedAsk: PaneContextSelectedAsk?
        var selectedSourceTitle: String?
        var cardUnavailable = false
        var detailMessages: MessagesPopoverModel?
    }

    enum VisibleInput: Equatable, Sendable {
        case card(LineInput)
        case toolbar(paneId: UUID, display: PaneContextDisplay?, isDrawer: Bool)
        case popover(PaneContextPopoverShape, PopoverContent)

        var paneId: UUID {
            switch self {
            case .card(let input): input.paneId
            case .toolbar(let paneId, _, _): paneId
            case .popover(let shape, _): shape.paneId.uuid
            }
        }

        var activityTime: PaneActivityTime? {
            if case .card(let input) = self { return input.activityTime }
            return nil
        }

        var agentLine: AgentLineDetail? {
            switch self {
            case .card(let input): input.agentLine
            case .toolbar(_, let display, _): display?.agentLine
            case .popover: nil
            }
        }
    }

    enum PopoverContent: Equatable, Sendable { case messages, agentLine }

    enum VisiblePresentation: Equatable, Sendable {
        case pane(Presentation)
        case card(CardModel)
        case popover(PaneContextPopoverShape)
    }

    struct Presentation: Equatable, Sendable {
        let lines: [RepoExplorerPaneRowLine]
        var toolbarItem: ToolbarItemModel = .none
    }

    static func input(
        context: PaneManagementContext, store: WorkspaceStore, readers: PaneContextUIReaders?
    ) -> LineInput {
        let paneId = PaneId(existingUUID: context.paneId)
        let pane = store.paneAtom.pane(context.paneId)
        let display = readers?.contextDisplayForPane(paneId)
        let scope = readers?.scopeForPane(paneId) ?? [paneId]
        let scopedPresentations = scope.map {
            PaneContextCardScopePresentation(source: $0, presentation: readers?.sessionStatusForPane($0))
        }
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
            activityTime: atom(\.paneActivityTime).value(for: context.paneId), contextDisplay: display,
            scopedPresentations: scopedPresentations)
    }

    @concurrent nonisolated static func lines(_ input: LineInput, now: Date) async
        -> [RepoExplorerPaneRowLine]
    {
        let title = PaneContextPresentationRules.displayTitle(
            raw: input.terminalTitle, agentTitle: input.agentTitle, cwd: input.cwd,
            shell: input.shellExecutablePath)
        return RepoExplorerPaneRowVariants.informationLines(
            title: title, note: input.note, agentLine: input.agentLine,
            sessionStatus: input.sessionPresentation?.status,
            connectionIssue: input.sessionPresentation?.connectionIssue, now: now)
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
        _ input: VisibleInput, clock: C,
        wallNow suppliedWallDate: Date? = nil,
        publish: @MainActor @Sendable (VisiblePresentation) -> Void
    ) async where C.Duration == Duration {
        let clockReference = clock.now
        let wallNow = suppliedWallDate ?? Date.now
        var previous: VisiblePresentation?
        while !Task.isCancelled {
            let elapsed = clockReference.duration(to: clock.now)
            let parts = elapsed.components
            let elapsedSeconds =
                Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
            let currentWallDate = wallNow.addingTimeInterval(elapsedSeconds)
            let projected = await visiblePresentation(input, now: currentWallDate)
            if projected.value != previous {
                guard !Task.isCancelled else { return }
                await publish(projected.value)
                previous = projected.value
            }
            guard let nextDate = projected.nextChange else { return }
            let deadline = clockReference.advanced(
                by: elapsed + .seconds(nextDate.timeIntervalSince(currentWallDate)))
            do {
                try await clock.sleep(until: deadline, tolerance: nil)
            } catch {
                return
            }
        }
    }

    @concurrent nonisolated private static func visiblePresentation(
        _ input: VisibleInput, now: Date
    ) async -> (value: VisiblePresentation, nextChange: Date?) {
        if case .popover(let shape, let content) = input {
            let refreshed = await PaneContextPopoverShaping.refresh(shape, content: content, now: now)
            return (.popover(refreshed.shape), refreshed.nextChange)
        }
        let preparedLines: [RepoExplorerPaneRowLine]
        var toolbarItem: ToolbarItemModel = .none
        var toolbarDeadline: Date?
        switch input {
        case .card(let card): preparedLines = await lines(card, now: now)
        case .toolbar(_, let display, let isDrawer):
            let projected = ToolbarProjection.project(display: display, isDrawer: isDrawer, now: now)
            toolbarItem = projected.item
            toolbarDeadline = projected.nextChange
            if case .agentLine = projected.item, let detail = display?.agentLine {
                preparedLines = [.agentLine(.agent(detail, now: now))]
            } else {
                preparedLines = []
            }
        case .popover: preconditionFailure("Popover handled before pane projection")
        }
        let prepared = Presentation(lines: preparedLines, toolbarItem: toolbarItem)
        let messageDeadline: Date?
        if case .toolbar = input {
            messageDeadline = toolbarDeadline
        } else {
            messageDeadline = input.agentLine.map {
                RepoExplorerPaneContextLine.nextMessageAgeChangeDate($0, now: now)
            }
        }
        if case .card(let card) = input {
            let model = await CardProjection.project(card, now: now, information: prepared)
            let activityDeadline = card.activityTime.map {
                PaneContextPresentationRules.age(referenceDate: $0.wallTime, now: now).nextChange
            }
            return (.card(model), [activityDeadline, messageDeadline].compactMap(\.self).min())
        }
        return (.pane(prepared), messageDeadline)
    }
}

/// Owns one visible card or toolbar's relative-time worker and its transition receipts.
@MainActor
@Observable
final class PaneRelativeTimeRefresh {
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
        case operation(PaneManagementIdentityCapture.VisibleInput, StartResult)
        case hidden(HideResult)
        case entered(PaneManagementIdentityCapture.VisibleInput)
        case ended(PaneManagementIdentityCapture.VisibleInput, WorkerOutcome)
    }

    private struct Worker: Sendable {
        let input: PaneManagementIdentityCapture.VisibleInput
        let id: UUID
        let task: Task<Void, Never>
    }

    private(set) var value: PaneManagementIdentityCapture.VisiblePresentation?
    var presentation: PaneManagementIdentityCapture.Presentation? {
        switch value {
        case .pane(let presentation): presentation
        case .card(let card): card.information
        case .popover, nil: nil
        }
    }
    var popoverShape: PaneContextPopoverShape? {
        if case .popover(let shape) = value { return shape }
        return nil
    }
    var cardModel: CardModel? {
        if case .card(let card) = value { return card }
        return nil
    }
    @ObservationIgnored private var worker: Worker?
    @ObservationIgnored private let onEvent: @MainActor @Sendable (Event) -> Void

    init(onEvent: @escaping @MainActor @Sendable (Event) -> Void = { _ in }) {
        self.onEvent = onEvent
    }

    isolated deinit { worker?.task.cancel() }

    @discardableResult
    func startOrReplace<C: Clock>(
        _ input: PaneManagementIdentityCapture.LineInput, clock: C, wallNow: Date? = nil
    ) -> StartResult where C.Duration == Duration, C.Instant == ContinuousClock.Instant {
        startOrReplace(.card(input), clock: clock, wallNow: wallNow)
    }

    @discardableResult
    func startOrReplace<C: Clock>(
        _ input: PaneManagementIdentityCapture.VisibleInput, clock: C, wallNow: Date? = nil
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
                input, clock: clock, wallNow: wallNow
            ) { [weak self] prepared in
                guard let self, !Task.isCancelled, self.worker?.id == id, self.value != prepared else { return }
                self.value = prepared
            }
        }
        worker = Worker(input: input, id: id, task: task)
        onEvent(.operation(input, result))
        return result
    }

    @discardableResult
    func hide() -> HideResult {
        value = nil
        guard let previous = worker else {
            onEvent(.hidden(.notRunning))
            return .notRunning
        }
        worker = nil
        previous.task.cancel()
        let result = HideResult.cancelled(requested: previous.task.isCancelled)
        onEvent(.hidden(result))
        return result
    }
}
