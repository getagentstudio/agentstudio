import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Foundation
import Observation
import os.log

@MainActor
package protocol TerminalSurfaceCommandDispatching: AnyObject {
    func sendInput(_ input: String, toPaneId paneId: UUID) -> Result<Void, SurfaceError>
    func clearScrollback(forPaneId paneId: UUID) -> Result<Void, SurfaceError>
    func scrollToBottom(forPaneId paneId: UUID) -> Result<Void, SurfaceError>
    func scrollPageFractional(fraction: Double, forPaneId paneId: UUID) -> Result<Void, SurfaceError>
    func jumpToPrompt(delta: Int, forPaneId paneId: UUID) -> Result<Void, SurfaceError>
}

@MainActor
@Observable
package final class TerminalRuntime: BusPostingPaneRuntime, TerminalRuntimeSnapshotFactProviding {
    private static let logger = Logger(subsystem: "com.agentstudio", category: "TerminalRuntime")

    package let paneId: PaneId
    package private(set) var metadata: PaneMetadata
    package private(set) var lifecycle: PaneRuntimeLifecycle
    private(set) var commandProgress: ProgressState?
    private(set) var isReadOnly: Bool = false
    private(set) var isSecureInput: Bool = false
    private(set) var rendererHealthy: Bool = true
    private(set) var cellSize: NSSize = .zero
    private(set) var sizeConstraints: TerminalSizeConstraints?
    private(set) var scrollbarState: ScrollbarState?
    private(set) var searchState: TerminalSearchState?
    private(set) var searchLifecycleState: TerminalSearchLifecycleState
    private(set) var mouseShape: TerminalMouseShape?
    private(set) var isMouseVisible: Bool = true
    private var localSearchEpoch: UInt64?
    package let capabilities: Set<PaneCapability>

    private let eventChannel: PaneRuntimeEventChannel
    private let surfaceCommandDispatcher: any TerminalSurfaceCommandDispatching
    private let openExternalURL: @MainActor (String) -> Void

    package init(
        paneId: PaneId,
        metadata: PaneMetadata,
        clock: ContinuousClock = ContinuousClock(),
        replayBuffer: EventReplayBuffer? = nil,
        paneEventBus: EventBus<RuntimeEnvelope> = PaneRuntimeEventBus.shared,
        surfaceCommandDispatcher: any TerminalSurfaceCommandDispatching = SurfaceManager.shared,
        openExternalURL: (@MainActor (String) -> Void)? = nil
    ) {
        self.paneId = paneId
        self.metadata = metadata
        self.lifecycle = .created
        self.commandProgress = nil
        self.scrollbarState = nil
        self.searchState = nil
        self.searchLifecycleState = .inactive(lastEndedEpoch: 0)
        self.mouseShape = nil
        self.localSearchEpoch = nil
        self.capabilities = [.input, .resize, .search]
        self.eventChannel = PaneRuntimeEventChannel(
            clock: clock,
            replayBuffer: replayBuffer ?? EventReplayBuffer(),
            paneEventBus: paneEventBus
        )
        self.surfaceCommandDispatcher = surfaceCommandDispatcher
        self.openExternalURL = openExternalURL ?? { TerminalExternalURLOpener.open($0) }
    }

    @discardableResult
    package func transitionToReady() -> Bool {
        guard lifecycle == .created else {
            Self.logger.warning(
                "Rejected transitionToReady for pane \(self.paneId.uuid.uuidString, privacy: .public): lifecycle=\(String(describing: self.lifecycle), privacy: .public)"
            )
            return false
        }
        lifecycle = .ready
        return true
    }

    package func handleCommand(_ envelope: RuntimeCommandEnvelope) async -> ActionResult {
        guard lifecycle == .ready else {
            return .failure(.runtimeNotReady(lifecycle: lifecycle))
        }

        switch envelope.command {
        case .activate:
            return .success(commandId: envelope.commandId)
        case .deactivate:
            return .success(commandId: envelope.commandId)
        case .prepareForClose:
            lifecycle = .draining
            return .success(commandId: envelope.commandId)
        case .requestSnapshot:
            return .success(commandId: envelope.commandId)
        case .terminal(let terminalCommand):
            if let requiredCapability = requiredCapability(for: terminalCommand),
                !capabilities.contains(requiredCapability)
            {
                return .failure(
                    .unsupportedCommand(
                        command: String(describing: envelope.command),
                        required: requiredCapability
                    )
                )
            }

            return dispatchTerminalCommand(terminalCommand, commandId: envelope.commandId)
        case .browser, .diff, .editor, .plugin:
            return .failure(
                .unsupportedCommand(
                    command: String(describing: envelope.command),
                    required: envelope.command.requiredCapability
                )
            )
        }
    }

    package func subscribe() -> AsyncStream<RuntimeEnvelope> {
        eventChannel.subscribe(isTerminated: lifecycle == .terminated)
    }

    package func snapshot() -> PaneRuntimeSnapshot {
        eventChannel.snapshot(
            paneId: paneId,
            metadata: metadata,
            lifecycle: lifecycle,
            capabilities: capabilities
        )
    }

    package func terminalRuntimeSnapshotFacts() -> TerminalRuntimeSnapshotFacts {
        TerminalRuntimeSnapshotFacts(
            rendererHealthy: rendererHealthy,
            readOnly: isReadOnly,
            secureInput: isSecureInput
        )
    }

    package func eventsSince(seq: UInt64) async -> EventReplayBuffer.ReplayResult {
        eventChannel.eventsSince(seq: seq)
    }

    package func shutdown(timeout _: Duration) async -> [UUID] {
        if lifecycle == .terminated {
            return []
        }
        lifecycle = .draining
        lifecycle = .terminated
        eventChannel.finishSubscribers()
        return []
    }

    func handleGhosttyEvent(
        _ event: GhosttyEvent,
        commandId: UUID? = nil,
        correlationId: UUID? = nil,
        commandFinishedSourceInstant: ContinuousClock.Instant? = nil
    ) {
        guard lifecycle != .terminated else {
            Self.logger.debug(
                "Dropped terminal event after termination for pane \(self.paneId.uuid.uuidString, privacy: .public): \(String(describing: event), privacy: .public)"
            )
            return
        }

        if handleGhosttyStructuralEvent(
            event,
            commandId: commandId,
            correlationId: correlationId,
            commandFinishedSourceInstant: commandFinishedSourceInstant
        ) {
            return
        }
        if handleGhosttyStateEvent(event, commandId: commandId, correlationId: correlationId) { return }
        if handleGhosttyConfigurationEvent(event, commandId: commandId, correlationId: correlationId) { return }
        if handleGhosttySearchEvent(event, commandId: commandId, correlationId: correlationId) { return }
        if handleGhosttyRequestEvent(event, commandId: commandId, correlationId: correlationId) { return }

        Self.logger.warning(
            "Unhandled terminal runtime event for pane \(self.paneId.uuid.uuidString, privacy: .public): \(String(describing: event), privacy: .public)"
        )
    }

    /// Applies coalesced terminal-local presentation state without admitting runtime events.
    ///
    /// This path intentionally does not allocate envelopes, advance event sequences, write
    /// replay, or publish through the pane/global event buses.
    @discardableResult
    func applyLocalActionBatch(_ batch: TerminalLocalActionBatch) -> Int {
        guard lifecycle != .terminated else { return 0 }

        var equalWriteSuppressedCount = 0

        if let scrollbarState = batch.presentation.scrollbarState {
            if self.scrollbarState == scrollbarState {
                equalWriteSuppressedCount += 1
            } else {
                self.scrollbarState = scrollbarState
            }
        }

        if let mouseShape = batch.presentation.mouseShape {
            if self.mouseShape == mouseShape {
                equalWriteSuppressedCount += 1
            } else {
                self.mouseShape = mouseShape
            }
        }

        if let isMouseVisible = batch.presentation.mouseVisibility {
            if self.isMouseVisible == isMouseVisible {
                equalWriteSuppressedCount += 1
            } else {
                self.isMouseVisible = isMouseVisible
            }
        }

        if let lifecycle = batch.searchLifecycle {
            localSearchEpoch = lifecycle.latestEpoch
            searchLifecycleState = lifecycle.state
            switch lifecycle.state {
            case .active(let query, let epoch):
                localSearchEpoch = epoch
                searchState = TerminalSearchState(
                    query: query ?? "",
                    totalMatches: nil,
                    selectedMatchIndex: nil
                )
            case .inactive:
                searchState = nil
            }
        }

        if let searchUpdate = batch.presentation.searchUpdate,
            localSearchEpoch == searchUpdate.epoch,
            searchState != nil
        {
            if searchUpdate.hasTotalMatchesUpdate {
                if searchState?.totalMatches == searchUpdate.totalMatches {
                    equalWriteSuppressedCount += 1
                } else {
                    searchState?.totalMatches = searchUpdate.totalMatches
                }
            }
            if searchUpdate.hasSelectionUpdate {
                if searchState?.selectedMatchIndex == searchUpdate.selectedMatchIndex {
                    equalWriteSuppressedCount += 1
                } else {
                    searchState?.selectedMatchIndex = searchUpdate.selectedMatchIndex
                }
            }
        }

        return equalWriteSuppressedCount
    }

    private func handleGhosttyStructuralEvent(
        _ event: GhosttyEvent,
        commandId: UUID?,
        correlationId: UUID?,
        commandFinishedSourceInstant: ContinuousClock.Instant?
    ) -> Bool {
        switch event {
        case .newTab, .closeTab, .gotoTab, .moveTab, .newSplit, .gotoSplit, .resizeSplit, .equalizeSplits,
            .toggleSplitZoom:
            emit(event, commandId: commandId, correlationId: correlationId, persistForReplay: false)
            return true
        case .titleChanged(let title), .tabTitleChanged(let title):
            guard metadata.title != title else { return true }
            metadata.updateTitle(title)
            emit(event, commandId: commandId, correlationId: correlationId, persistForReplay: true)
            return true
        case .cwdChanged(let cwdPath):
            let cwd = URL(fileURLWithPath: cwdPath)
            guard metadata.cwd != cwd else { return true }
            metadata.updateCWD(cwd)
            emit(event, commandId: commandId, correlationId: correlationId, persistForReplay: true)
            return true
        case .commandFinished:
            emit(
                event,
                commandId: commandId,
                correlationId: correlationId,
                persistForReplay: true,
                timestamp: commandFinishedSourceInstant
            )
            return true
        case .bellRang, .unhandled:
            emit(event, commandId: commandId, correlationId: correlationId, persistForReplay: true)
            return true
        default:
            return false
        }
    }

    private func handleGhosttyStateEvent(
        _ event: GhosttyEvent,
        commandId: UUID?,
        correlationId: UUID?
    ) -> Bool {
        switch event {
        case .scrollbarChanged(let scrollbarState):
            self.scrollbarState = scrollbarState
            return true
        case .progressReportUpdated(let progressState):
            guard commandProgress != progressState else { return true }
            commandProgress = progressState
            emit(event, commandId: commandId, correlationId: correlationId, persistForReplay: true)
            return true
        case .readOnlyChanged(let isReadOnly):
            guard self.isReadOnly != isReadOnly else { return true }
            self.isReadOnly = isReadOnly
            emit(event, commandId: commandId, correlationId: correlationId, persistForReplay: true)
            return true
        case .secureInputRequested(let mode):
            let resolvedValue = resolvedSecureInputValue(for: mode)
            guard isSecureInput != resolvedValue else { return true }
            isSecureInput = resolvedValue
            emit(
                .secureInputChanged(resolvedValue),
                commandId: commandId,
                correlationId: correlationId,
                persistForReplay: true
            )
            return true
        case .secureInputChanged(let isActive):
            isSecureInput = isActive
            return true
        case .rendererHealthChanged(let healthy):
            guard rendererHealthy != healthy else { return true }
            rendererHealthy = healthy
            emit(event, commandId: commandId, correlationId: correlationId, persistForReplay: true)
            return true
        case .cellSizeChanged(let size):
            cellSize = size
            return true
        case .initialSizeChanged:
            return true
        case .sizeLimitChanged(let constraints):
            sizeConstraints = constraints
            return true
        default:
            return false
        }
    }

    private func handleGhosttyConfigurationEvent(
        _ event: GhosttyEvent,
        commandId: UUID?,
        correlationId: UUID?
    ) -> Bool {
        switch event {
        case .mouseShapeChanged(let shape):
            mouseShape = shape
            return true
        case .mouseVisibilityChanged(let isVisible):
            isMouseVisible = isVisible
            return true
        case .mouseLinkHovered, .keySequenceChanged, .keyTableChanged:
            return true
        case .colorChanged, .configChanged:
            return true
        case .configReloadRequested:
            emit(event, commandId: commandId, correlationId: correlationId, persistForReplay: false)
            return true
        default:
            return false
        }
    }

    private func handleGhosttySearchEvent(
        _ event: GhosttyEvent,
        commandId: UUID?,
        correlationId: UUID?
    ) -> Bool {
        switch event {
        case .searchStarted(let query):
            let epoch = searchLifecycleState.epoch &+ 1
            localSearchEpoch = epoch
            searchLifecycleState = .active(query: query, epoch: epoch)
            searchState = TerminalSearchState(query: query ?? "", totalMatches: nil, selectedMatchIndex: nil)
            return true
        case .searchEnded:
            searchLifecycleState = .inactive(lastEndedEpoch: searchLifecycleState.epoch)
            searchState = nil
            return true
        case .searchMatchesUpdated(let totalMatches):
            if searchState == nil {
                Self.logger.debug(
                    "Synthesizing terminal search state from searchMatchesUpdated without prior searchStarted for pane \(self.paneId.uuid.uuidString, privacy: .public)"
                )
                searchState = TerminalSearchState(query: "", totalMatches: totalMatches, selectedMatchIndex: nil)
            } else {
                searchState?.totalMatches = totalMatches
            }
            return true
        case .searchSelectionChanged(let selectedMatchIndex):
            if searchState == nil {
                Self.logger.debug(
                    "Synthesizing terminal search state from searchSelectionChanged without prior searchStarted for pane \(self.paneId.uuid.uuidString, privacy: .public)"
                )
                searchState = TerminalSearchState(
                    query: "",
                    totalMatches: nil,
                    selectedMatchIndex: selectedMatchIndex
                )
            } else {
                searchState?.selectedMatchIndex = selectedMatchIndex
            }
            return true
        default:
            return false
        }
    }

    private func handleGhosttyRequestEvent(
        _ event: GhosttyEvent,
        commandId: UUID?,
        correlationId: UUID?
    ) -> Bool {
        switch event {
        case .promptTitleRequested, .desktopNotificationRequested:
            emit(event, commandId: commandId, correlationId: correlationId, persistForReplay: false)
            return true
        case .openURLRequested(let url, _):
            openExternalURL(url)
            emit(event, commandId: commandId, correlationId: correlationId, persistForReplay: false)
            return true
        case .undoRequested, .redoRequested, .copyTitleToClipboardRequested:
            emit(event, commandId: commandId, correlationId: correlationId, persistForReplay: false)
            return true
        case .deferred:
            return true
        default:
            return false
        }
    }

    private func resolvedSecureInputValue(for mode: SecureInputMode) -> Bool {
        switch mode {
        case .on:
            return true
        case .off:
            return false
        case .toggle:
            return !isSecureInput
        }
    }

    private func emit(
        _ event: GhosttyEvent,
        commandId: UUID?,
        correlationId: UUID?,
        persistForReplay: Bool,
        timestamp: ContinuousClock.Instant? = nil
    ) {
        eventChannel.emit(
            paneId: paneId,
            metadata: metadata,
            paneKind: .terminal,
            commandId: commandId,
            correlationId: correlationId,
            event: .terminal(event),
            persistForReplay: persistForReplay,
            timestamp: timestamp
        )
    }

    private func requiredCapability(for command: TerminalCommand) -> PaneCapability? {
        switch command {
        case .sendInput, .clearScrollback:
            return .input
        case .scrollToBottom, .scrollPageFractional, .jumpToPrompt:
            return nil
        case .resize:
            return .resize
        }
    }

    private func dispatchTerminalCommand(_ command: TerminalCommand, commandId: UUID) -> ActionResult {
        switch command {
        case .sendInput(let input):
            let dispatchResult = surfaceCommandDispatcher.sendInput(input, toPaneId: paneId.uuid)
            return mapSurfaceDispatchResult(dispatchResult, commandId: commandId, command: command)
        case .clearScrollback:
            let dispatchResult = surfaceCommandDispatcher.clearScrollback(forPaneId: paneId.uuid)
            return mapSurfaceDispatchResult(dispatchResult, commandId: commandId, command: command)
        case .scrollToBottom:
            let dispatchResult = surfaceCommandDispatcher.scrollToBottom(forPaneId: paneId.uuid)
            return mapSurfaceDispatchResult(dispatchResult, commandId: commandId, command: command)
        case .scrollPageFractional(let fraction):
            let dispatchResult = surfaceCommandDispatcher.scrollPageFractional(
                fraction: fraction, forPaneId: paneId.uuid)
            return mapSurfaceDispatchResult(dispatchResult, commandId: commandId, command: command)
        case .jumpToPrompt(let delta):
            let dispatchResult = surfaceCommandDispatcher.jumpToPrompt(delta: delta, forPaneId: paneId.uuid)
            return mapSurfaceDispatchResult(dispatchResult, commandId: commandId, command: command)
        case .resize(let cols, let rows):
            Self.logger.warning(
                "Rejected terminal resize command for pane \(self.paneId.uuid.uuidString, privacy: .public): cols=\(cols, privacy: .public) rows=\(rows, privacy: .public). Programmatic col/row resizing is not supported by embedded Ghostty surface API."
            )
            return .failure(
                .invalidPayload(
                    description: "Programmatic terminal resize by columns/rows is not supported by embedded Ghostty"
                )
            )
        }
    }

    private func mapSurfaceDispatchResult(
        _ result: Result<Void, SurfaceError>,
        commandId: UUID,
        command: TerminalCommand
    ) -> ActionResult {
        switch result {
        case .success:
            return .success(commandId: commandId)
        case .failure(let error):
            Self.logger.warning(
                "Terminal command dispatch failed for pane \(self.paneId.uuid.uuidString, privacy: .public) command=\(String(describing: command), privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return .failure(.backendUnavailable(backend: "SurfaceManager"))
        }
    }
}
