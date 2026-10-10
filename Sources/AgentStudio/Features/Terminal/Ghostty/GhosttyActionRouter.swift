import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import GhosttyKit

@MainActor
protocol GhosttyActionRoutingLookup: AnyObject {
    func surfaceId(forViewObjectId viewObjectId: ObjectIdentifier) -> UUID?
    func paneId(for surfaceId: UUID) -> UUID?
}

extension SurfaceManager: GhosttyActionRoutingLookup {}

extension Ghostty {
    /// Owns callback admission, contracted source state and all admitted apply work.
    package final class ActionRouter: Sendable {
        let host: GhosttyActionRoutingHost
        let taskOwner: GhosttyCallbackTaskOwner
        let localActionDrainScheduler: TerminalLocalActionDrainScheduler
        let localActionAccumulator: TerminalLocalActionAccumulator
        @MainActor private var retirementTask: Task<Void, Never>?

        @MainActor
        package init(host: GhosttyActionRoutingHost) {
            let taskOwner = GhosttyCallbackTaskOwner()
            let scheduler = TerminalLocalActionDrainScheduler(
                drain: { surfaceID, lane, accumulator in
                    await host.drainLocalActions(for: surfaceID, lane: lane, accumulator: accumulator)
                },
                enqueueMainActorDrain: { operation in
                    // fire-and-forget: the callback task owner retains this handle and joins it during retirement.
                    _ = taskOwner.enqueueTask(operation)
                }
            )
            self.host = host
            self.taskOwner = taskOwner
            self.localActionDrainScheduler = scheduler
            self.localActionAccumulator = TerminalLocalActionAccumulator(
                scheduleDrain: scheduler.schedule,
                scheduleFollowUpDrain: scheduler.scheduleFollowUp,
                cancelScheduledTitleDrain: scheduler.cancelTitle,
                isAcceptingWork: { taskOwner.isAcceptingWork }
            )
        }

        func accept(_ work: GhosttyOwnedCallbackWork) -> Bool {
            guard taskOwner.isAcceptingWork else { return false }
            switch work {
            case .directHost(let surfaceID, let viewObjectID, let update):
                return enqueueDirectHost(surfaceID: surfaceID, viewObjectID: viewObjectID, update: update)
            case .close(let surfaceID, let viewObjectID):
                return enqueueDirectHost(surfaceID: surfaceID, viewObjectID: viewObjectID, update: .closeRequested)
            case .action(let target, let tag, let payload):
                guard case .surface(let surfaceID, let viewObjectID) = target else { return false }
                switch payload {
                case .cwdChanged(let path):
                    _ = enqueueDirectHost(
                        surfaceID: surfaceID, viewObjectID: viewObjectID, update: .workingDirectory(path))
                case .initialSizeChanged(let width, let height):
                    _ = enqueueDirectHost(
                        surfaceID: surfaceID, viewObjectID: viewObjectID,
                        update: .reportedInitialSize(width: width, height: height))
                case .cellSizeChanged(let width, let height):
                    _ = enqueueDirectHost(
                        surfaceID: surfaceID, viewObjectID: viewObjectID,
                        update: .reportedCellSize(width: width, height: height))
                default:
                    break
                }
                let event = GhosttyActionTranslation.translate(actionTag: tag, payload: payload)
                let admission = Self.admitTranslatedActionToTerminalRuntime(
                    event, surfaceID: surfaceID, accumulator: localActionAccumulator,
                    equalSuppressionObserver: { [host] kind in
                        host.actionTraceQueueStore.record(
                            tag: .performance, body: "performance.terminal.equal_suppressed",
                            attributes: [
                                "agentstudio.performance.terminal.publication.kind": .string(kind.rawValue),
                                "agentstudio.performance.terminal.equal_suppressed.count": .int(1),
                            ]
                        )
                    }
                )
                switch admission {
                case .routeExactFactOrControl(let precedingTitle):
                    return taskOwner.enqueueTask { @MainActor [host, localActionAccumulator] in
                        await host.applyExactFactOrControl(
                            precedingTitle: precedingTitle, actionTag: tag, payload: payload,
                            surfaceID: surfaceID, viewObjectID: viewObjectID, accumulator: localActionAccumulator
                        )
                    } != nil
                case .updateDirectHostState:
                    return enqueueDirectHost(
                        surfaceID: surfaceID, viewObjectID: viewObjectID, update: .cache(tag: tag, payload: payload))
                case .handledLocally:
                    return true
                case .rejectedRetired:
                    return false
                }
            }
        }

        private func enqueueDirectHost(surfaceID: UUID, viewObjectID: ObjectIdentifier, update: GhosttyDirectHostUpdate)
            -> Bool
        {
            taskOwner.enqueueTask { @MainActor [host] in
                await host.applyDirectHost(surfaceID: surfaceID, viewObjectID: viewObjectID, update: update)
            } != nil
        }

        /// Close admission independently before any native-resource release.
        func closeAdmission() {
            _ = taskOwner.closeAdmissionAndSnapshot()
        }

        /// Called by a lifecycle owner, never from one of the apply tasks being joined.
        @MainActor
        package func retire() async {
            if let retirementTask {
                await retirementTask.value
                return
            }
            let snapshot = taskOwner.closeAdmissionAndSnapshot()
            localActionDrainScheduler.cancelAll()
            localActionAccumulator.removeAllSurfaces()
            let traceStore = host.actionTraceQueueStore
            let completion = Task { @MainActor in
                await snapshot.joinAdmittedTasks()
                do {
                    try await traceStore.drain()
                } catch {
                    ghosttyLogger.warning("Ghostty action trace drain failed: \(error.localizedDescription)")
                }
            }
            retirementTask = completion
            await completion.value
        }

        static let explicitlyRoutedTags: Set<GhosttyActionTag> = [
            .newTab,
            .ringBell,
            .setTitle,
            .setTabTitle,
            .pwd,
            .newSplit,
            .gotoSplit,
            .resizeSplit,
            .equalizeSplits,
            .toggleSplitZoom,
            .closeTab,
            .gotoTab,
            .moveTab,
            .sizeLimit,
            .initialSize,
            .cellSize,
            .desktopNotification,
            .promptTitle,
            .mouseShape,
            .mouseVisibility,
            .mouseOverLink,
            .rendererHealth,
            .secureInput,
            .keySequence,
            .keyTable,
            .colorChange,
            .reloadConfig,
            .configChange,
            .undo,
            .redo,
            .openURL,
            .progressReport,
            .commandFinished,
            .scrollbar,
            .startSearch,
            .endSearch,
            .searchTotal,
            .searchSelected,
            .readOnly,
            .copyTitleToClipboard,
        ]
        static let deferredTags: Set<GhosttyActionTag> = []
        static let unsupportedTags: Set<GhosttyActionTag> = [
            .exportTerminalIO, .setWindowTitle, .selectionChanged, .moveTabToNewWindow,
        ]
        static let interceptedTags: Set<GhosttyActionTag> = [
            .quit,
            .newWindow,
            .closeAllWindows,
            .toggleMaximize,
            .toggleFullscreen,
            .toggleTabOverview,
            .toggleWindowDecorations,
            .toggleQuickTerminal,
            .toggleCommandPalette,
            .toggleVisibility,
            .toggleBackgroundOpacity,
            .gotoWindow,
            .presentTerminal,
            .resetWindowSize,
            .resizeWindow,
            .inspector,
            .showGtkInspector,
            .renderInspector,
            .render,
            .openConfig,
            .quitTimer,
            .floatWindow,
            .closeWindow,
            .checkForUpdates,
            .showChildExited,
            .showOnScreenKeyboard,
        ]

    }
}
