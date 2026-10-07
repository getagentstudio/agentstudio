import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal

@MainActor
@Suite("Workspace prepared content mount coordinator")
struct WorkspacePreparedContentMountCoordinatorTests {
    @Test("publishes the complete terminal placeholder cohort before activation")
    func publishesCompleteTerminalPlaceholderCohortBeforeActivation() async throws {
        // Arrange
        let generation = try makePreparedContentCoordinatorGeneration()
        let firstDescriptor = makePreparedContentCoordinatorTerminalDescriptor(title: "First")
        let secondDescriptor = makePreparedContentCoordinatorTerminalDescriptor(title: "Second")
        let cohort = WorkspacePreparedContentMountCohort(
            generation: generation,
            terminalActivationInput: TerminalActivationInput(
                entries: [firstDescriptor, secondDescriptor]
            ),
            nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
        )
        let registry = ViewRegistry()
        registry.beginInitialRestore()
        let terminalPort = RecordingPreparedContentTerminalPort()
        let coordinator = WorkspacePreparedContentMountCoordinator(
            cohort: cohort,
            viewRegistry: registry,
            terminalAdmissionPort: terminalPort,
            nonterminalAdmissionPort: RecordingPreparedContentNonterminalPort()
        )
        var publishedPaneIDs: [PaneId] = []

        // Act
        let publication = coordinator.publishTerminalPlaceholders { descriptor in
            #expect(terminalPort.admissions.isEmpty)
            publishedPaneIDs.append(descriptor.paneID)
        }

        // Assert
        #expect(publication.paneIDs == [firstDescriptor.paneID, secondDescriptor.paneID])
        #expect(publishedPaneIDs == publication.paneIDs)
        #expect(terminalPort.admissions.isEmpty)
    }

    @Test("re-entrant restore joins one terminal placeholder publication")
    func reentrantRestoreJoinsOneTerminalPlaceholderPublication() async throws {
        // Arrange
        let generation = try makePreparedContentCoordinatorGeneration()
        let descriptor = makePreparedContentCoordinatorTerminalDescriptor()
        let cohort = WorkspacePreparedContentMountCohort(
            generation: generation,
            terminalActivationInput: TerminalActivationInput(entries: [descriptor]),
            nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
        )
        let registry = ViewRegistry()
        registry.beginInitialRestore()
        let coordinator = WorkspacePreparedContentMountCoordinator(
            cohort: cohort,
            viewRegistry: registry,
            terminalAdmissionPort: RecordingPreparedContentTerminalPort(descriptors: [descriptor]),
            nonterminalAdmissionPort: RecordingPreparedContentNonterminalPort()
        )
        var publishedPaneIDs: [PaneId] = []

        // Act
        let firstPublication = coordinator.publishTerminalPlaceholders { descriptor in
            publishedPaneIDs.append(descriptor.paneID)
        }
        await coordinator.holdTerminalActivationUntilReleased()
        let mountTask = Task { @MainActor in
            await coordinator.mount()
        }
        await Task.yield()
        let reentrantPublication = coordinator.publishTerminalPlaceholders { descriptor in
            publishedPaneIDs.append(descriptor.paneID)
        }
        await coordinator.releaseTerminalActivation()
        _ = await mountTask.value

        // Assert
        #expect(firstPublication.disposition == .published)
        #expect(reentrantPublication.disposition == .joinedExistingPublication)
        #expect(publishedPaneIDs == [descriptor.paneID])
    }

    @Test("terminal activation deferral returns timeout when its injected deadline fires")
    func terminalActivationDeferralReturnsTimeout() async {
        let timeout = AsyncStream<Void>.makeStream()
        let gate = TerminalActivationReleaseGate(
            isReleased: false,
            deferralDelay: AsyncDelay { _ in
                var iterator = timeout.stream.makeAsyncIterator()
                _ = await iterator.next()
            }
        )
        let waiter = Task {
            await gate.waitUntilReleased()
        }
        await Task.yield()

        timeout.continuation.yield()

        #expect(await waiter.value == .fallbackTimeout)
    }

    @Test("terminal activation deferral returns cancelled when its caller is cancelled")
    func terminalActivationDeferralReturnsCancelled() async {
        let timeout = AsyncStream<Void>.makeStream()
        let gate = TerminalActivationReleaseGate(
            isReleased: false,
            deferralDelay: AsyncDelay { _ in
                var iterator = timeout.stream.makeAsyncIterator()
                _ = await iterator.next()
            }
        )
        let waiter = Task {
            await gate.waitUntilReleased()
        }
        await Task.yield()

        waiter.cancel()

        #expect(await waiter.value == .cancelled)
    }

    @Test("empty accepted cohort settles both lanes and completes initial restore")
    func emptyCohortCompletesInitialRestore() async throws {
        // Arrange
        let generation = try makePreparedContentCoordinatorGeneration()
        let cohort = WorkspacePreparedContentMountCohort(
            generation: generation,
            terminalActivationInput: TerminalActivationInput(entries: []),
            nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
        )
        let registry = ViewRegistry()
        registry.beginInitialRestore()
        let terminalPort = RecordingPreparedContentTerminalPort()
        let nonterminalPort = RecordingPreparedContentNonterminalPort()
        let coordinator = WorkspacePreparedContentMountCoordinator(
            cohort: cohort,
            viewRegistry: registry,
            terminalAdmissionPort: terminalPort,
            nonterminalAdmissionPort: nonterminalPort
        )

        // Act
        let settlement = await coordinator.mount()

        // Assert
        #expect(settlement.generation == generation)
        #expect(settlement.terminal.outcomesByPaneID.isEmpty)
        #expect(settlement.nonterminal.outcomesByPaneID.isEmpty)
        #expect(registry.isInitialRestorePending == false)
        #expect(terminalPort.admissions.isEmpty)
        #expect(nonterminalPort.descriptors.isEmpty)
    }

    @Test("concurrent mount callers share one lane execution and cached settlement")
    func concurrentMountCallersShareOneExecution() async throws {
        // Arrange
        let generation = try makePreparedContentCoordinatorGeneration()
        let descriptor = makePreparedContentCoordinatorTerminalDescriptor()
        let cohort = WorkspacePreparedContentMountCohort(
            generation: generation,
            terminalActivationInput: TerminalActivationInput(entries: [descriptor]),
            nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
        )
        let registry = ViewRegistry()
        registry.beginInitialRestore()
        let terminalPort = SuspendedPreparedContentTerminalPort(descriptors: [descriptor])
        let coordinator = WorkspacePreparedContentMountCoordinator(
            cohort: cohort,
            viewRegistry: registry,
            terminalAdmissionPort: terminalPort,
            nonterminalAdmissionPort: RecordingPreparedContentNonterminalPort()
        )
        await coordinator.installTerminalGeometryAvailability([descriptor.paneID])
        let firstMount = Task { @MainActor in
            await coordinator.mount()
        }
        await terminalPort.waitUntilAdmissionStarts()
        let secondCallerStarted = AsyncStream<Void>.makeStream()
        let secondMount = Task { @MainActor in
            secondCallerStarted.continuation.yield()
            return await coordinator.mount()
        }
        var secondCallerIterator = secondCallerStarted.stream.makeAsyncIterator()
        _ = await secondCallerIterator.next()
        let surfaceID = UUIDv7.generate()

        // Act
        terminalPort.finish(with: .ready(surfaceID: surfaceID))
        let firstSettlement = await firstMount.value
        let secondSettlement = await secondMount.value
        let cachedSettlement = await coordinator.mount()

        // Assert
        #expect(terminalPort.admissions.count == 1)
        #expect(firstSettlement == secondSettlement)
        #expect(secondSettlement == cachedSettlement)
        #expect(
            cachedSettlement.terminal.outcomesByPaneID[descriptor.paneID]
                == .ready(surfaceID: surfaceID)
        )
        #expect(registry.isInitialRestorePending == false)
    }

    @Test("failed member visibility intent waits for aggregate settlement before repair")
    func failedMemberVisibilityIntentWaitsForAggregateSettlement() async throws {
        // Arrange
        let generation = try makePreparedContentCoordinatorGeneration()
        let failedDescriptor = makePreparedContentCoordinatorTerminalDescriptor(title: "Failed")
        let blockingDescriptor = makePreparedContentCoordinatorTerminalDescriptor(title: "Blocking")
        let cohort = WorkspacePreparedContentMountCohort(
            generation: generation,
            terminalActivationInput: TerminalActivationInput(
                entries: [failedDescriptor, blockingDescriptor]
            ),
            nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
        )
        let registry = ViewRegistry()
        registry.beginInitialRestore()
        let terminalPort = FailedAndSuspendedPreparedContentTerminalPort(
            failedDescriptor: failedDescriptor,
            suspendedDescriptor: blockingDescriptor
        )
        let coordinator = WorkspacePreparedContentMountCoordinator(
            cohort: cohort,
            viewRegistry: registry,
            terminalAdmissionPort: terminalPort,
            nonterminalAdmissionPort: RecordingPreparedContentNonterminalPort()
        )
        await coordinator.installTerminalGeometryAvailability([failedDescriptor.paneID, blockingDescriptor.paneID])
        let mountTask = Task { @MainActor in
            await coordinator.mount()
        }
        await terminalPort.waitUntilFailureReturns()
        await terminalPort.waitUntilSuspendedAdmissionStarts()

        // Act
        let handledPaneIDs = coordinator.handleVisibilitySignals(
            for: PreparedContentVisibleQueuedSet(visiblePaneIDs: [failedDescriptor.paneID], activePaneIDs: [])
        )
        terminalPort.finishSuspendedAdmission()
        _ = await mountTask.value
        let deferredAfterSettlement = coordinator.takeDeferredSteadyStateRepairPaneIDs()

        // Assert
        #expect(handledPaneIDs == [failedDescriptor.paneID])
        #expect(deferredAfterSettlement == [failedDescriptor.paneID])
        #expect(terminalPort.admissions.filter { $0.descriptor.paneID == failedDescriptor.paneID }.count == 1)
        #expect(registry.isInitialRestorePending == false)
    }

    @Test("terminal restore orders foreground before hidden and main before drawer")
    func terminalRestoreOrdersForegroundBeforeHiddenAndMainBeforeDrawer() async throws {
        let generation = try makePreparedContentCoordinatorGeneration()
        let tabID = UUIDv7.generate()
        let parentPaneID = PaneId(existingUUID: UUIDv7.generate())
        let drawerID = UUIDv7.generate()
        let mainTerminal = makePreparedContentCoordinatorTerminalDescriptor(
            title: "Main terminal",
            visibilityPriority: .activeVisible,
            hostPlacement: .tab(tabID: tabID)
        )
        let drawerTerminal = makePreparedContentCoordinatorTerminalDescriptor(
            title: "Drawer terminal",
            visibilityPriority: .activeVisible,
            hostPlacement: .drawer(
                tabID: tabID,
                parentPaneID: parentPaneID,
                drawerID: drawerID
            )
        )
        let hiddenMainTerminal = makePreparedContentCoordinatorTerminalDescriptor(
            title: "Hidden main terminal",
            visibilityPriority: .hidden,
            hostPlacement: .tab(tabID: UUIDv7.generate())
        )
        let hiddenDrawerTerminal = makePreparedContentCoordinatorTerminalDescriptor(
            title: "Hidden drawer terminal",
            visibilityPriority: .hidden,
            hostPlacement: .drawer(
                tabID: UUIDv7.generate(),
                parentPaneID: PaneId(existingUUID: UUIDv7.generate()),
                drawerID: UUIDv7.generate()
            )
        )
        let mainNonterminal = makePreparedContentCoordinatorNonterminalDescriptor(
            title: "Main webview",
            visibilityPriority: .visible,
            hostPlacement: .tab(tabID: tabID)
        )
        let drawerNonterminal = makePreparedContentCoordinatorNonterminalDescriptor(
            title: "Drawer webview",
            visibilityPriority: .activeVisible,
            hostPlacement: .drawer(
                tabID: tabID,
                parentPaneID: parentPaneID,
                drawerID: drawerID
            )
        )
        let hiddenNonterminal = makePreparedContentCoordinatorNonterminalDescriptor(
            title: "Hidden webview",
            visibilityPriority: .hidden,
            hostPlacement: .tab(tabID: tabID)
        )
        let terminalDescriptors = [hiddenDrawerTerminal, drawerTerminal, hiddenMainTerminal, mainTerminal]
        let cohort = WorkspacePreparedContentMountCohort(
            generation: generation,
            terminalActivationInput: TerminalActivationInput(entries: terminalDescriptors),
            nonterminalContentMountInput: NonterminalContentMountInput(
                entries: [mainNonterminal, drawerNonterminal, hiddenNonterminal]
            )
        )
        let registry = ViewRegistry()
        registry.beginInitialRestore()
        let terminalPort = RecordingPreparedContentTerminalPort(descriptors: terminalDescriptors)
        let nonterminalPort = SignallingPreparedContentNonterminalPort(
            signalPaneID: mainNonterminal.paneID
        )
        let coordinator = WorkspacePreparedContentMountCoordinator(
            cohort: cohort,
            viewRegistry: registry,
            terminalAdmissionPort: terminalPort,
            nonterminalAdmissionPort: nonterminalPort
        )
        await coordinator.installTerminalGeometryAvailability(Set(terminalDescriptors.map(\.paneID)))
        let settlement = await coordinator.mount()

        #expect(
            terminalPort.admissions.map(\.descriptor.paneID) == [
                mainTerminal.paneID,
                drawerTerminal.paneID,
                hiddenMainTerminal.paneID,
                hiddenDrawerTerminal.paneID,
            ]
        )
        #expect(
            nonterminalPort.descriptors.map(\.paneID)
                == [mainNonterminal.paneID, drawerNonterminal.paneID]
        )
        #expect(
            Set(settlement.terminal.outcomesByPaneID.keys) == [
                mainTerminal.paneID,
                drawerTerminal.paneID,
                hiddenMainTerminal.paneID,
                hiddenDrawerTerminal.paneID,
            ]
        )
        #expect(
            Set(settlement.nonterminal.outcomesByPaneID.keys)
                == [mainNonterminal.paneID, drawerNonterminal.paneID]
        )
        #expect(registry.preparedContentMountState(for: hiddenNonterminal.paneID, generation: generation) == nil)
    }

    @Test("one terminal scheduler owns the complete cohort")
    func oneTerminalSchedulerOwnsTheCompleteCohort() async throws {
        // Arrange
        let generation = try makePreparedContentCoordinatorGeneration()
        let activeMain = makePreparedContentCoordinatorTerminalDescriptor(
            title: "Active main",
            visibilityPriority: .activeVisible,
            hostPlacement: .tab(tabID: UUIDv7.generate())
        )
        let hiddenMain = makePreparedContentCoordinatorTerminalDescriptor(
            title: "Hidden main",
            visibilityPriority: .hidden,
            hostPlacement: .tab(tabID: UUIDv7.generate())
        )
        let activeDrawer = makePreparedContentCoordinatorTerminalDescriptor(
            title: "Active drawer",
            visibilityPriority: .activeVisible,
            hostPlacement: .drawer(
                tabID: UUIDv7.generate(),
                parentPaneID: PaneId(existingUUID: UUIDv7.generate()),
                drawerID: UUIDv7.generate()
            )
        )
        let hiddenDrawer = makePreparedContentCoordinatorTerminalDescriptor(
            title: "Hidden drawer",
            visibilityPriority: .hidden,
            hostPlacement: .drawer(
                tabID: UUIDv7.generate(),
                parentPaneID: PaneId(existingUUID: UUIDv7.generate()),
                drawerID: UUIDv7.generate()
            )
        )
        let allDescriptors = [activeMain, hiddenMain, activeDrawer, hiddenDrawer]
        let cohort = WorkspacePreparedContentMountCohort(
            generation: generation,
            terminalActivationInput: TerminalActivationInput(entries: allDescriptors),
            nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
        )
        let registry = ViewRegistry()
        registry.beginInitialRestore()
        let terminalPort = RecordingPreparedContentTerminalPort(descriptors: allDescriptors)
        let coordinator = WorkspacePreparedContentMountCoordinator(
            cohort: cohort,
            viewRegistry: registry,
            terminalAdmissionPort: terminalPort,
            nonterminalAdmissionPort: RecordingPreparedContentNonterminalPort()
        )
        await coordinator.installTerminalGeometryAvailability(Set(allDescriptors.map(\.paneID)))

        // Act
        let settlement = await coordinator.mount()

        // Assert
        #expect(Set(settlement.terminal.outcomesByPaneID.keys) == Set(allDescriptors.map(\.paneID)))
        #expect(terminalPort.admissions.count == allDescriptors.count)
        #expect(
            terminalPort.admissions.map(\.descriptor.paneID).count
                == Set(terminalPort.admissions.map(\.descriptor.paneID)).count
        )
    }

    @Test("settlement carries waiting members without failing them")
    func settlementCarriesWaitingMembersWithoutFailingThem() async throws {
        // Arrange: no `installTerminalGeometryAvailability` call at all —
        // `descriptor` stays `waitingForGeometry` for the whole `mount()`.
        let generation = try makePreparedContentCoordinatorGeneration()
        let descriptor = makePreparedContentCoordinatorTerminalDescriptor()
        let cohort = WorkspacePreparedContentMountCohort(
            generation: generation,
            terminalActivationInput: TerminalActivationInput(entries: [descriptor]),
            nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
        )
        let registry = ViewRegistry()
        registry.beginInitialRestore()
        let terminalPort = RecordingPreparedContentTerminalPort(descriptors: [descriptor])
        let coordinator = WorkspacePreparedContentMountCoordinator(
            cohort: cohort,
            viewRegistry: registry,
            terminalAdmissionPort: terminalPort,
            nonterminalAdmissionPort: RecordingPreparedContentNonterminalPort()
        )

        // Act
        let settlement = await coordinator.mount()

        // Assert: `requireCompleteSettlement`'s key-set precondition already
        // proves `mount()` did not trap; this asserts the *value* is the
        // deferral outcome, not a failure, and that no proposal ever reached
        // the port (SPEC R5, R1's deferral half).
        #expect(settlement.terminal.outcomesByPaneID[descriptor.paneID] == .waitingForGeometry)
        #expect(terminalPort.admissions.isEmpty)
        #expect(registry.isInitialRestorePending == false)
    }

    @Test("a waiting member is not reported as deferred steady-state repair")
    func aWaitingMemberIsNotReportedAsDeferredSteadyStateRepair() async throws {
        // Arrange: `waiting`'s `ViewRegistry` custody is `deferredGeometry`
        // (as the real port would leave it) and its visibility is signaled,
        // so `deferredVisibilityIntentPaneIDs` genuinely contains it — the
        // only question this test asks is whether the *failure* filter
        // wrongly includes a still-waiting member.
        let generation = try makePreparedContentCoordinatorGeneration()
        let waiting = makePreparedContentCoordinatorTerminalDescriptor()
        let cohort = WorkspacePreparedContentMountCohort(
            generation: generation,
            terminalActivationInput: TerminalActivationInput(entries: [waiting]),
            nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
        )
        let registry = ViewRegistry()
        registry.beginInitialRestore()
        let terminalPort = RecordingPreparedContentTerminalPort(descriptors: [waiting])
        let coordinator = WorkspacePreparedContentMountCoordinator(
            cohort: cohort,
            viewRegistry: registry,
            terminalAdmissionPort: terminalPort,
            nonterminalAdmissionPort: RecordingPreparedContentNonterminalPort()
        )
        // The coordinator's own init installs the cohort (custody becomes
        // `.pending(owner: .terminal)`); only now can this move to deferred.
        #expect(registry.deferPreparedContentMount(paneID: waiting.paneID, owner: .terminal, generation: generation))

        // Act
        _ = await coordinator.mount()
        _ = coordinator.handleVisibilitySignals(
            for: PreparedContentVisibleQueuedSet(visiblePaneIDs: [waiting.paneID], activePaneIDs: [])
        )
        let deferredSteadyStateRepairPaneIDs = coordinator.takeDeferredSteadyStateRepairPaneIDs()

        // Assert
        #expect(deferredSteadyStateRepairPaneIDs.isEmpty)
    }

    @Test("a settled deferred member moves from preparing to waitingForGeometry")
    func aSettledDeferredMemberMovesFromPreparingToWaitingForGeometry() async throws {
        // Arrange: no `installTerminalGeometryAvailability` call at all —
        // `waiting` stays `waitingForGeometry` for the whole `mount()`.
        let generation = try makePreparedContentCoordinatorGeneration()
        let waiting = makePreparedContentCoordinatorTerminalDescriptor()
        let cohort = WorkspacePreparedContentMountCohort(
            generation: generation,
            terminalActivationInput: TerminalActivationInput(entries: [waiting]),
            nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
        )
        let registry = ViewRegistry()
        registry.beginInitialRestore()
        let terminalPort = RecordingPreparedContentTerminalPort(descriptors: [waiting])
        let placeholderHandler = RecordingPlaceholderTransitionHandler()
        let coordinator = WorkspacePreparedContentMountCoordinator(
            cohort: cohort,
            viewRegistry: registry,
            terminalAdmissionPort: terminalPort,
            nonterminalAdmissionPort: RecordingPreparedContentNonterminalPort(),
            placeholderTransitionHandler: { pane, mode in placeholderHandler.handle(pane: pane, mode: mode) }
        )
        // Matches production: `PreparedTerminalMountAdmissionPort
        // .installTrustedInitialFrames` defers a frameless pane's
        // `ViewRegistry` custody to `deferredGeometry` before `activate()`
        // runs. This fake port bypasses that real port, so the test drives
        // the same custody edge directly — `notifyWaitingForGeometryPlaceholders`
        // now reads it live before publishing (R4).
        #expect(registry.deferPreparedContentMount(paneID: waiting.paneID, owner: .terminal, generation: generation))
        // Matches `publishTerminalPlaceholders`'s production sequencing: a
        // `.preparing` host already exists before the settlement transition.
        placeholderHandler.handle(pane: waiting.pane, mode: .preparing)
        let originalHost = try #require(placeholderHandler.placeholderViewsByPaneID[waiting.pane.id])

        // Act
        _ = await coordinator.mount()

        // Assert: the same host instance was reconfigured in place, not
        // rebuilt, and its mode history shows the exact transition.
        let hostAfterSettlement = try #require(placeholderHandler.placeholderViewsByPaneID[waiting.pane.id])
        #expect(hostAfterSettlement === originalHost)
        #expect(placeholderHandler.requestedModesByPaneID[waiting.pane.id] == [.preparing, .waitingForGeometry])
    }

    @Test("requeuing a deferred member returns the placeholder to preparing")
    func requeuingADeferredMemberReturnsThePlaceholderToPreparing() async throws {
        // Arrange
        let generation = try makePreparedContentCoordinatorGeneration()
        let waiting = makePreparedContentCoordinatorTerminalDescriptor()
        let cohort = WorkspacePreparedContentMountCohort(
            generation: generation,
            terminalActivationInput: TerminalActivationInput(entries: [waiting]),
            nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
        )
        let registry = ViewRegistry()
        registry.beginInitialRestore()
        let terminalPort = RecordingPreparedContentTerminalPort(descriptors: [waiting])
        let placeholderHandler = RecordingPlaceholderTransitionHandler()
        let coordinator = WorkspacePreparedContentMountCoordinator(
            cohort: cohort,
            viewRegistry: registry,
            terminalAdmissionPort: terminalPort,
            nonterminalAdmissionPort: RecordingPreparedContentNonterminalPort(),
            placeholderTransitionHandler: { pane, mode in placeholderHandler.handle(pane: pane, mode: mode) }
        )
        // See the matching note in
        // `aSettledDeferredMemberMovesFromPreparingToWaitingForGeometry`.
        #expect(registry.deferPreparedContentMount(paneID: waiting.paneID, owner: .terminal, generation: generation))
        placeholderHandler.handle(pane: waiting.pane, mode: .preparing)
        _ = await coordinator.mount()
        let hostAfterSettlement = try #require(placeholderHandler.placeholderViewsByPaneID[waiting.pane.id])

        // Act: later geometry arrives and requeues the still-waiting member.
        // Production restores custody to `pending` before this call
        // (`PreparedTerminalMountAdmissionPort.acceptLaterTrustedFrames`);
        // this fake port bypasses that, so the test drives the same edge.
        #expect(
            registry.restorePreparedContentMountToPending(
                paneID: waiting.paneID, owner: .terminal, generation: generation)
        )
        await coordinator.acceptTerminalGeometry([waiting.paneID])

        // Assert: same host instance across both transitions.
        let hostAfterRequeue = try #require(placeholderHandler.placeholderViewsByPaneID[waiting.pane.id])
        #expect(hostAfterRequeue === hostAfterSettlement)
        #expect(
            placeholderHandler.requestedModesByPaneID[waiting.pane.id] == [.preparing, .waitingForGeometry, .preparing])
    }

    @Test("visibility is recorded synchronously at the coordinator boundary")
    func visibilityIsRecordedSynchronouslyAtTheCoordinatorBoundary() throws {
        // Arrange
        let generation = try makePreparedContentCoordinatorGeneration()
        let descriptor = makePreparedContentCoordinatorTerminalDescriptor()
        let cohort = WorkspacePreparedContentMountCohort(
            generation: generation,
            terminalActivationInput: TerminalActivationInput(entries: [descriptor]),
            nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
        )
        let registry = ViewRegistry()
        registry.beginInitialRestore()
        let terminalPort = RecordingPreparedContentTerminalPort(descriptors: [descriptor])
        let coordinator = WorkspacePreparedContentMountCoordinator(
            cohort: cohort,
            viewRegistry: registry,
            terminalAdmissionPort: terminalPort,
            nonterminalAdmissionPort: RecordingPreparedContentNonterminalPort()
        )

        // Act
        let handledPaneIDs = coordinator.handleVisibilitySignals(
            for: PreparedContentVisibleQueuedSet(
                visiblePaneIDs: [descriptor.paneID],
                activePaneIDs: [descriptor.paneID]
            )
        )

        // Assert: the classified snapshot is observable immediately after the
        // call returns — no `Task` hop, no `Task.sleep`.
        #expect(handledPaneIDs == [descriptor.paneID])
        #expect(terminalPort.recordedVisibleQueuedTerminals.count == 1)
        #expect(
            terminalPort.recordedVisibleQueuedTerminals.first
                == TerminalVisibleQueuedTerminals(
                    generation: generation,
                    activeMainPaneIDs: [descriptor.paneID],
                    visibleMainSiblingPaneIDs: [],
                    activeDrawerPaneIDs: [],
                    visibleDrawerSiblingPaneIDs: []
                )
        )
    }

    @Test("active membership, not list order, decides the active tier")
    func activeMembershipNotListOrderDecidesTheActiveTier() throws {
        // Arrange: the visible set lists the sibling BEFORE the true active
        // pane, proving classification uses `activePaneIDs` membership, not
        // position.
        let generation = try makePreparedContentCoordinatorGeneration()
        let trueActive = makePreparedContentCoordinatorTerminalDescriptor(title: "True active")
        let sibling = makePreparedContentCoordinatorTerminalDescriptor(title: "Sibling")
        let cohort = WorkspacePreparedContentMountCohort(
            generation: generation,
            terminalActivationInput: TerminalActivationInput(entries: [trueActive, sibling]),
            nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
        )
        let registry = ViewRegistry()
        registry.beginInitialRestore()
        let terminalPort = RecordingPreparedContentTerminalPort(descriptors: [trueActive, sibling])
        let coordinator = WorkspacePreparedContentMountCoordinator(
            cohort: cohort,
            viewRegistry: registry,
            terminalAdmissionPort: terminalPort,
            nonterminalAdmissionPort: RecordingPreparedContentNonterminalPort()
        )

        // Act: `sibling` is listed first; `activePaneIDs` still names `trueActive`.
        _ = coordinator.handleVisibilitySignals(
            for: PreparedContentVisibleQueuedSet(
                visiblePaneIDs: [sibling.paneID, trueActive.paneID],
                activePaneIDs: [trueActive.paneID]
            )
        )

        // Assert
        #expect(terminalPort.recordedVisibleQueuedTerminals.count == 1)
        #expect(
            terminalPort.recordedVisibleQueuedTerminals.first
                == TerminalVisibleQueuedTerminals(
                    generation: generation,
                    activeMainPaneIDs: [trueActive.paneID],
                    visibleMainSiblingPaneIDs: [sibling.paneID],
                    activeDrawerPaneIDs: [],
                    visibleDrawerSiblingPaneIDs: []
                )
        )
    }
}

/// The propose/claim/activate handshake needs a descriptor for any pane it
/// claims (see `TerminalAdmissionProposal`, which carries only a `paneID`).
/// These coordinator-level fakes carry no `ViewRegistry` of their own, so each
/// caller registers the cohort's descriptors at construction.
@MainActor
final class RecordingPreparedContentTerminalPort: TerminalActivationAdmissionPort {
    private let descriptorsByPaneID: [PaneId: TerminalActivationDescriptor]
    private(set) var admissions: [TerminalActivationAdmission] = []
    private(set) var recordedVisibleQueuedTerminals: [TerminalVisibleQueuedTerminals] = []

    init(descriptors: [TerminalActivationDescriptor] = []) {
        descriptorsByPaneID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.paneID, $0) })
    }

    func recordCurrentVisibleQueuedTerminals(
        _ terminals: TerminalVisibleQueuedTerminals
    ) -> TerminalVisibilityRevision {
        recordedVisibleQueuedTerminals.append(terminals)
        return TerminalVisibilityRevision(
            generation: terminals.generation,
            ordinal: UInt64(recordedVisibleQueuedTerminals.count)
        )
    }

    func claimPreparedTerminal(_ proposal: TerminalAdmissionProposal) -> TerminalAdmissionClaimOutcome {
        guard let descriptor = descriptorsByPaneID[proposal.paneID] else {
            return .rejected(.paneNotInCohort)
        }
        return .claimed(
            ClaimedTerminalAdmission(
                claimID: UUIDv7.generate(),
                admission: TerminalActivationAdmission(
                    generation: proposal.generation,
                    descriptor: descriptor,
                    attempt: proposal.attempt
                ),
                acknowledgedVisibilityRevision: proposal.appliedVisibilityRevision
            )
        )
    }

    func activateClaimedTerminal(_ claim: ClaimedTerminalAdmission) async -> ClaimedTerminalActivationOutcome {
        admissions.append(claim.admission)
        return .attempted(
            .failed(
                failure: .attachmentRejected(code: "unexpected"),
                retry: .doNotRetry
            )
        )
    }
}

@MainActor
private final class SuspendedPreparedContentTerminalPort: TerminalActivationAdmissionPort {
    private let descriptorsByPaneID: [PaneId: TerminalActivationDescriptor]
    private let admissionStarted = AsyncStream<Void>.makeStream()
    private var resultContinuation: CheckedContinuation<TerminalActivationAttemptResult, Never>?
    private(set) var admissions: [TerminalActivationAdmission] = []

    init(descriptors: [TerminalActivationDescriptor] = []) {
        descriptorsByPaneID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.paneID, $0) })
    }

    func recordCurrentVisibleQueuedTerminals(
        _ terminals: TerminalVisibleQueuedTerminals
    ) -> TerminalVisibilityRevision {
        TerminalVisibilityRevision(generation: terminals.generation, ordinal: 0)
    }

    func claimPreparedTerminal(_ proposal: TerminalAdmissionProposal) -> TerminalAdmissionClaimOutcome {
        guard let descriptor = descriptorsByPaneID[proposal.paneID] else {
            return .rejected(.paneNotInCohort)
        }
        return .claimed(
            ClaimedTerminalAdmission(
                claimID: UUIDv7.generate(),
                admission: TerminalActivationAdmission(
                    generation: proposal.generation,
                    descriptor: descriptor,
                    attempt: proposal.attempt
                ),
                acknowledgedVisibilityRevision: proposal.appliedVisibilityRevision
            )
        )
    }

    func activateClaimedTerminal(_ claim: ClaimedTerminalAdmission) async -> ClaimedTerminalActivationOutcome {
        admissions.append(claim.admission)
        admissionStarted.continuation.yield()
        let result = await withCheckedContinuation { continuation in
            resultContinuation = continuation
        }
        return .attempted(result)
    }

    func waitUntilAdmissionStarts() async {
        var iterator = admissionStarted.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func finish(with result: TerminalActivationAttemptResult) {
        let continuation = resultContinuation
        resultContinuation = nil
        continuation?.resume(returning: result)
    }
}

@MainActor
private final class FailedAndSuspendedPreparedContentTerminalPort: TerminalActivationAdmissionPort {
    private let failedDescriptor: TerminalActivationDescriptor
    private let suspendedDescriptor: TerminalActivationDescriptor
    private let failureReturned = AsyncStream<Void>.makeStream()
    private let suspendedAdmissionStarted = AsyncStream<Void>.makeStream()
    private var suspendedContinuation: CheckedContinuation<TerminalActivationAttemptResult, Never>?
    private(set) var admissions: [TerminalActivationAdmission] = []

    init(failedDescriptor: TerminalActivationDescriptor, suspendedDescriptor: TerminalActivationDescriptor) {
        self.failedDescriptor = failedDescriptor
        self.suspendedDescriptor = suspendedDescriptor
    }

    func recordCurrentVisibleQueuedTerminals(
        _ terminals: TerminalVisibleQueuedTerminals
    ) -> TerminalVisibilityRevision {
        TerminalVisibilityRevision(generation: terminals.generation, ordinal: 0)
    }

    func claimPreparedTerminal(_ proposal: TerminalAdmissionProposal) -> TerminalAdmissionClaimOutcome {
        let descriptor: TerminalActivationDescriptor
        if proposal.paneID == failedDescriptor.paneID {
            descriptor = failedDescriptor
        } else if proposal.paneID == suspendedDescriptor.paneID {
            descriptor = suspendedDescriptor
        } else {
            return .rejected(.paneNotInCohort)
        }
        return .claimed(
            ClaimedTerminalAdmission(
                claimID: UUIDv7.generate(),
                admission: TerminalActivationAdmission(
                    generation: proposal.generation,
                    descriptor: descriptor,
                    attempt: proposal.attempt
                ),
                acknowledgedVisibilityRevision: proposal.appliedVisibilityRevision
            )
        )
    }

    func activateClaimedTerminal(_ claim: ClaimedTerminalAdmission) async -> ClaimedTerminalActivationOutcome {
        admissions.append(claim.admission)
        if claim.admission.descriptor.paneID == failedDescriptor.paneID {
            failureReturned.continuation.yield()
            return .attempted(
                .failed(
                    failure: .surfaceCreationFailed(code: "prepared_failure"),
                    retry: .doNotRetry
                )
            )
        }
        precondition(claim.admission.descriptor.paneID == suspendedDescriptor.paneID)
        suspendedAdmissionStarted.continuation.yield()
        let result = await withCheckedContinuation { continuation in
            suspendedContinuation = continuation
        }
        return .attempted(result)
    }

    func waitUntilFailureReturns() async {
        var iterator = failureReturned.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func waitUntilSuspendedAdmissionStarts() async {
        var iterator = suspendedAdmissionStarted.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func finishSuspendedAdmission() {
        let continuation = suspendedContinuation
        suspendedContinuation = nil
        continuation?.resume(returning: .ready(surfaceID: UUIDv7.generate()))
    }
}

@MainActor
final class RecordingPreparedContentNonterminalPort: NonterminalContentMountAdmissionPort {
    private(set) var descriptors: [NonterminalContentMountDescriptor] = []

    func mount(_ descriptor: NonterminalContentMountDescriptor) -> NonterminalContentMountAdmissionResult {
        descriptors.append(descriptor)
        return .mounted
    }
}

/// Stands in for `WorkspaceSurfaceCoordinator.registerTerminalPlaceholderIfNeeded(for:mode:)`
/// closely enough to prove host-instance identity: the first request for a
/// pane creates a real `TerminalStatusPlaceholderView`; every later request
/// for the same pane reconfigures that same instance in place, exactly like
/// the production writer's existing-placeholder branch.
@MainActor
private final class RecordingPlaceholderTransitionHandler {
    private(set) var placeholderViewsByPaneID: [UUID: TerminalStatusPlaceholderView] = [:]
    private(set) var requestedModesByPaneID: [UUID: [TerminalStatusPlaceholderMode]] = [:]

    func handle(pane: Pane, mode: TerminalStatusPlaceholderMode) {
        requestedModesByPaneID[pane.id, default: []].append(mode)
        if let existingHost = placeholderViewsByPaneID[pane.id] {
            existingHost.configure(mode: mode)
        } else {
            placeholderViewsByPaneID[pane.id] = TerminalStatusPlaceholderView(
                paneId: pane.id,
                title: pane.metadata.title,
                mode: mode
            )
        }
    }
}

@MainActor
private final class SignallingPreparedContentNonterminalPort: NonterminalContentMountAdmissionPort {
    private let signalPaneID: PaneId
    private let signalMountCompleted = AsyncStream<Void>.makeStream()
    private(set) var descriptors: [NonterminalContentMountDescriptor] = []

    init(signalPaneID: PaneId) {
        self.signalPaneID = signalPaneID
    }

    func mount(_ descriptor: NonterminalContentMountDescriptor) -> NonterminalContentMountAdmissionResult {
        descriptors.append(descriptor)
        if descriptor.paneID == signalPaneID {
            signalMountCompleted.continuation.yield()
        }
        return .mounted
    }

    func waitUntilSignalMountCompletes() async {
        var iterator = signalMountCompleted.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

@MainActor
func makePreparedContentCoordinatorGeneration() throws -> WorkspaceContentMountGeneration {
    WorkspaceContentMountGeneration()
}

func makePreparedContentCoordinatorTerminalDescriptor(
    title: String = "Prepared Coordinator Terminal",
    visibilityPriority: TerminalActivationVisibilityPriority = .activeVisible,
    hostPlacement: TerminalHostPlacementIdentity = .tab(tabID: UUIDv7.generate())
) -> TerminalActivationDescriptor {
    let launchDirectory = URL(filePath: "/tmp/prepared-content-coordinator")
    let terminalState = TerminalState(
        provider: .zmx,
        lifetime: .persistent,
        zmxSessionID: .generateUUIDv7()
    )
    let pane = Pane(
        id: UUIDv7.generate(),
        content: .terminal(terminalState),
        metadata: PaneMetadata(
            launchDirectory: launchDirectory,
            title: title
        )
    )
    return TerminalActivationDescriptor(
        pane: pane,
        visibilityPriority: visibilityPriority,
        hostPlacement: hostPlacement
    )
}

private func makePreparedContentCoordinatorNonterminalDescriptor(
    title: String,
    visibilityPriority: TerminalActivationVisibilityPriority,
    hostPlacement: TerminalHostPlacementIdentity
) -> NonterminalContentMountDescriptor {
    let pane = Pane(
        id: UUIDv7.generate(),
        content: .webview(
            WebviewState(
                url: URL(string: "https://example.com")!,
                title: title,
                showNavigation: false
            )
        ),
        metadata: PaneMetadata(title: title)
    )
    return NonterminalContentMountDescriptor(
        content: .webview(pane),
        visibilityPriority: visibilityPriority,
        hostPlacement: hostPlacement
    )
}
