import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal

@MainActor
@Suite("Prepared terminal mount admission")
struct PreparedTerminalMountAdmissionPortTests {
    enum NonPendingCustodyCase: CaseIterable, CustomTestStringConvertible {
        case mounting
        case deferredGeometry
        case completed

        var testDescription: String { String(describing: self) }
    }

    @Test("claim transitions pending custody to mounting in one turn")
    func claimTransitionsPendingCustodyToMountingInOneTurn() throws {
        // Arrange
        let generation = try makePreparedTerminalTestGeneration()
        let descriptor = makePreparedTerminalTestDescriptor(pane: makePreparedTerminalTestPane())
        let paneID = descriptor.paneID
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let registry = ViewRegistry()
        registry.installPreparedContentMountCohort(
            WorkspacePreparedContentMountCohort(
                generation: generation,
                terminalActivationInput: TerminalActivationInput(entries: [descriptor]),
                nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
            )
        )
        let handler = RecordingPreparedTerminalMountHandler(results: [])
        let port = PreparedTerminalMountAdmissionPort(
            generation: generation,
            initialFramesByPaneID: [paneID: frame],
            viewRegistry: registry,
            mountHandler: handler,
            descriptorsByPaneID: [paneID: descriptor]
        )

        // Act
        let outcome = port.claimPreparedTerminal(
            TerminalAdmissionProposal(
                generation: generation,
                paneID: paneID,
                attempt: 1,
                appliedVisibilityRevision: TerminalVisibilityRevision(generation: generation, ordinal: 0)
            )
        )

        // Assert
        guard case .claimed(let claim) = outcome else {
            Issue.record("expected a granted claim")
            return
        }
        #expect(claim.admission.descriptor == descriptor)
        #expect(claim.admission.attempt == 1)
        #expect(
            registry.preparedContentMountState(for: paneID, generation: generation)
                == .mounting(owner: .terminal)
        )
    }

    @Test("claim is rejected for a stale generation")
    func claimIsRejectedForStaleGeneration() throws {
        // Arrange
        let generation = try makePreparedTerminalTestGeneration()
        let staleGeneration = try makePreparedTerminalTestGeneration()
        let descriptor = makePreparedTerminalTestDescriptor(pane: makePreparedTerminalTestPane())
        let paneID = descriptor.paneID
        let registry = ViewRegistry()
        registry.installPreparedContentMountCohort(
            WorkspacePreparedContentMountCohort(
                generation: generation,
                terminalActivationInput: TerminalActivationInput(entries: [descriptor]),
                nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
            )
        )
        let handler = RecordingPreparedTerminalMountHandler(results: [])
        let port = PreparedTerminalMountAdmissionPort(
            generation: generation,
            initialFramesByPaneID: [paneID: NSRect(x: 0, y: 0, width: 800, height: 600)],
            viewRegistry: registry,
            mountHandler: handler,
            descriptorsByPaneID: [paneID: descriptor]
        )

        // Act
        let outcome = port.claimPreparedTerminal(
            TerminalAdmissionProposal(
                generation: staleGeneration,
                paneID: paneID,
                attempt: 1,
                appliedVisibilityRevision: TerminalVisibilityRevision(generation: staleGeneration, ordinal: 0)
            )
        )

        // Assert
        #expect(outcome == .rejected(.staleGeneration))
        #expect(handler.admissions.isEmpty)
    }

    @Test("claim is rejected for a pane outside the cohort")
    func claimIsRejectedForPaneOutsideTheCohort() throws {
        // Arrange
        let generation = try makePreparedTerminalTestGeneration()
        let descriptor = makePreparedTerminalTestDescriptor(pane: makePreparedTerminalTestPane())
        let outsidePaneID = PaneId.generateUUIDv7()
        let registry = ViewRegistry()
        registry.installPreparedContentMountCohort(
            WorkspacePreparedContentMountCohort(
                generation: generation,
                terminalActivationInput: TerminalActivationInput(entries: [descriptor]),
                nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
            )
        )
        let handler = RecordingPreparedTerminalMountHandler(results: [])
        let port = PreparedTerminalMountAdmissionPort(
            generation: generation,
            initialFramesByPaneID: [descriptor.paneID: NSRect(x: 0, y: 0, width: 800, height: 600)],
            viewRegistry: registry,
            mountHandler: handler,
            descriptorsByPaneID: [descriptor.paneID: descriptor]
        )

        // Act
        let outcome = port.claimPreparedTerminal(
            TerminalAdmissionProposal(
                generation: generation,
                paneID: outsidePaneID,
                attempt: 1,
                appliedVisibilityRevision: TerminalVisibilityRevision(generation: generation, ordinal: 0)
            )
        )

        // Assert
        #expect(outcome == .rejected(.paneNotInCohort))
        #expect(handler.admissions.isEmpty)
    }

    @Test(
        "claim is rejected when custody is not pending",
        arguments: NonPendingCustodyCase.allCases
    )
    func claimIsRejectedWhenCustodyIsNotPending(testCase: NonPendingCustodyCase) throws {
        // Arrange
        let generation = try makePreparedTerminalTestGeneration()
        let descriptor = makePreparedTerminalTestDescriptor(pane: makePreparedTerminalTestPane())
        let paneID = descriptor.paneID
        let registry = ViewRegistry()
        registry.installPreparedContentMountCohort(
            WorkspacePreparedContentMountCohort(
                generation: generation,
                terminalActivationInput: TerminalActivationInput(entries: [descriptor]),
                nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
            )
        )
        switch testCase {
        case .mounting:
            #expect(
                registry.claimPreparedContentMount(paneID: paneID, owner: .terminal, generation: generation)
                    == .accepted
            )
        case .deferredGeometry:
            #expect(registry.deferPreparedContentMount(paneID: paneID, owner: .terminal, generation: generation))
        case .completed:
            #expect(
                registry.claimPreparedContentMount(paneID: paneID, owner: .terminal, generation: generation)
                    == .accepted
            )
            registry.settlePreparedContentMount(
                paneID: paneID,
                owner: .terminal,
                generation: generation,
                disposition: .mounted
            )
        }
        let handler = RecordingPreparedTerminalMountHandler(results: [])
        let port = PreparedTerminalMountAdmissionPort(
            generation: generation,
            initialFramesByPaneID: [paneID: NSRect(x: 0, y: 0, width: 800, height: 600)],
            viewRegistry: registry,
            mountHandler: handler,
            descriptorsByPaneID: [paneID: descriptor]
        )

        // Act
        let outcome = port.claimPreparedTerminal(
            TerminalAdmissionProposal(
                generation: generation,
                paneID: paneID,
                attempt: 1,
                appliedVisibilityRevision: TerminalVisibilityRevision(generation: generation, ordinal: 0)
            )
        )

        // Assert
        #expect(outcome == .rejected(.custodyUnavailableForClaim))
        #expect(handler.admissions.isEmpty)
    }

    @Test("claim fails closed when an eligible pane has no installed frame")
    func claimFailsClosedWhenAnEligiblePaneHasNoInstalledFrame() throws {
        // Arrange
        let generation = try makePreparedTerminalTestGeneration()
        let descriptor = makePreparedTerminalTestDescriptor(pane: makePreparedTerminalTestPane())
        let paneID = descriptor.paneID
        let registry = ViewRegistry()
        registry.installPreparedContentMountCohort(
            WorkspacePreparedContentMountCohort(
                generation: generation,
                terminalActivationInput: TerminalActivationInput(entries: [descriptor]),
                nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
            )
        )
        let handler = RecordingPreparedTerminalMountHandler(results: [])
        let port = PreparedTerminalMountAdmissionPort(
            generation: generation,
            viewRegistry: registry,
            mountHandler: handler,
            descriptorsByPaneID: [paneID: descriptor]
        )

        // Act
        let outcome = port.claimPreparedTerminal(
            TerminalAdmissionProposal(
                generation: generation,
                paneID: paneID,
                attempt: 1,
                appliedVisibilityRevision: TerminalVisibilityRevision(generation: generation, ordinal: 0)
            )
        )

        // Assert
        #expect(outcome == .rejected(.trustedFrameUnavailable))
        #expect(handler.admissions.isEmpty)
        #expect(
            registry.preparedContentMountState(for: paneID, generation: generation)
                == .pending(owner: .terminal)
        )
    }

    @Test("installation defers every pane without a finite non-empty frame")
    func installationDefersEveryPaneWithoutAFiniteNonEmptyFrame() throws {
        // Arrange
        let generation = try makePreparedTerminalTestGeneration()
        let withFrame = makePreparedTerminalTestDescriptor(pane: makePreparedTerminalTestPane())
        let withoutFrame = makePreparedTerminalTestDescriptor(pane: makePreparedTerminalTestPane())
        let registry = ViewRegistry()
        registry.installPreparedContentMountCohort(
            WorkspacePreparedContentMountCohort(
                generation: generation,
                terminalActivationInput: TerminalActivationInput(entries: [withFrame, withoutFrame]),
                nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
            )
        )
        let handler = RecordingPreparedTerminalMountHandler(results: [])
        let port = PreparedTerminalMountAdmissionPort(
            generation: generation,
            viewRegistry: registry,
            mountHandler: handler,
            descriptorsByPaneID: [withFrame.paneID: withFrame, withoutFrame.paneID: withoutFrame]
        )

        // Act: `withoutFrame` is entirely absent from the supplied dictionary
        // — proving deferral covers a missing key, not only a
        // present-but-invalid one.
        let eligiblePaneIDs = port.installTrustedInitialFrames([
            withFrame.paneID: NSRect(x: 0, y: 0, width: 800, height: 600)
        ])

        // Assert
        #expect(eligiblePaneIDs == [withFrame.paneID])
        #expect(
            registry.preparedContentMountState(for: withFrame.paneID, generation: generation)
                == .pending(owner: .terminal)
        )
        #expect(
            registry.preparedContentMountState(for: withoutFrame.paneID, generation: generation)
                == .deferredGeometry(owner: .terminal)
        )
        #expect(handler.admissions.isEmpty)
    }

    enum InvalidFrameCase: CaseIterable, CustomTestStringConvertible {
        case zeroWidth
        case zeroHeight
        case negativeWidth
        case nonFiniteWidth
        case nonFiniteOriginX

        var testDescription: String { String(describing: self) }

        var frame: NSRect {
            switch self {
            case .zeroWidth:
                return NSRect(x: 0, y: 0, width: 0, height: 600)
            case .zeroHeight:
                return NSRect(x: 0, y: 0, width: 800, height: 0)
            case .negativeWidth:
                return NSRect(x: 0, y: 0, width: -800, height: 600)
            case .nonFiniteWidth:
                return NSRect(x: 0, y: 0, width: CGFloat.infinity, height: 600)
            case .nonFiniteOriginX:
                return NSRect(x: CGFloat.nan, y: 0, width: 800, height: 600)
            }
        }
    }

    @Test(
        "empty, negative, and non-finite frames are treated as absent",
        arguments: InvalidFrameCase.allCases
    )
    func emptyNegativeAndNonFiniteFramesAreTreatedAsAbsent(testCase: InvalidFrameCase) throws {
        // Arrange
        let generation = try makePreparedTerminalTestGeneration()
        let descriptor = makePreparedTerminalTestDescriptor(pane: makePreparedTerminalTestPane())
        let paneID = descriptor.paneID
        let registry = ViewRegistry()
        registry.installPreparedContentMountCohort(
            WorkspacePreparedContentMountCohort(
                generation: generation,
                terminalActivationInput: TerminalActivationInput(entries: [descriptor]),
                nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
            )
        )
        let handler = RecordingPreparedTerminalMountHandler(results: [])
        let port = PreparedTerminalMountAdmissionPort(
            generation: generation,
            viewRegistry: registry,
            mountHandler: handler,
            descriptorsByPaneID: [paneID: descriptor]
        )

        // Act
        let eligiblePaneIDs = port.installTrustedInitialFrames([paneID: testCase.frame])

        // Assert
        #expect(eligiblePaneIDs.isEmpty)
        #expect(
            registry.preparedContentMountState(for: paneID, generation: generation)
                == .deferredGeometry(owner: .terminal)
        )
    }

    enum LaterFrameCustodyCase: CaseIterable, CustomTestStringConvertible {
        case deferredGeometrySameGeneration
        case pendingNeverDeferred
        case mounting
        case completed
        case foreignGeneration

        var testDescription: String { String(describing: self) }
    }

    @Test(
        "later frames are accepted only for same-generation deferred custody",
        arguments: LaterFrameCustodyCase.allCases
    )
    func laterFramesAreAcceptedOnlyForSameGenerationDeferredCustody(testCase: LaterFrameCustodyCase) throws {
        // Arrange: `installTrustedInitialFrames([:])` defers the pane first —
        // every case below then moves it (or a stand-in generation) into the
        // custody this case names before the shared act/assert.
        let generation = try makePreparedTerminalTestGeneration()
        let descriptor = makePreparedTerminalTestDescriptor(pane: makePreparedTerminalTestPane())
        let paneID = descriptor.paneID
        let registry = ViewRegistry()
        registry.installPreparedContentMountCohort(
            WorkspacePreparedContentMountCohort(
                generation: generation,
                terminalActivationInput: TerminalActivationInput(entries: [descriptor]),
                nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
            )
        )
        let handler = RecordingPreparedTerminalMountHandler(results: [])
        let port = PreparedTerminalMountAdmissionPort(
            generation: generation,
            viewRegistry: registry,
            mountHandler: handler,
            descriptorsByPaneID: [paneID: descriptor]
        )
        _ = port.installTrustedInitialFrames([:])

        switch testCase {
        case .deferredGeometrySameGeneration:
            break
        case .pendingNeverDeferred:
            #expect(
                registry.restorePreparedContentMountToPending(paneID: paneID, owner: .terminal, generation: generation)
            )
        case .mounting:
            #expect(
                registry.restorePreparedContentMountToPending(paneID: paneID, owner: .terminal, generation: generation)
            )
            #expect(
                registry.claimPreparedContentMount(paneID: paneID, owner: .terminal, generation: generation)
                    == .accepted
            )
        case .completed:
            #expect(
                registry.restorePreparedContentMountToPending(paneID: paneID, owner: .terminal, generation: generation)
            )
            #expect(
                registry.claimPreparedContentMount(paneID: paneID, owner: .terminal, generation: generation)
                    == .accepted
            )
            registry.settlePreparedContentMount(
                paneID: paneID,
                owner: .terminal,
                generation: generation,
                disposition: .mounted
            )
        case .foreignGeneration:
            let otherGeneration = try makePreparedTerminalTestGeneration()
            registry.installPreparedContentMountCohort(
                WorkspacePreparedContentMountCohort(
                    generation: otherGeneration,
                    terminalActivationInput: TerminalActivationInput(entries: [descriptor]),
                    nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
                )
            )
        }

        // Act
        let acceptedPaneIDs = port.acceptLaterTrustedFrames([paneID: NSRect(x: 0, y: 0, width: 800, height: 600)])

        // Assert
        switch testCase {
        case .deferredGeometrySameGeneration:
            #expect(acceptedPaneIDs == [paneID])
            #expect(
                registry.preparedContentMountState(for: paneID, generation: generation)
                    == .pending(owner: .terminal)
            )
        case .pendingNeverDeferred, .mounting, .completed, .foreignGeneration:
            #expect(acceptedPaneIDs.isEmpty)
        }
    }

    @Test("replaying a consumed claim performs no mount effect")
    func replayingAConsumedClaimPerformsNoMountEffect() async throws {
        // Arrange
        let generation = try makePreparedTerminalTestGeneration()
        let descriptor = makePreparedTerminalTestDescriptor(pane: makePreparedTerminalTestPane())
        let paneID = descriptor.paneID
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let surfaceID = UUIDv7.generate()
        let registry = ViewRegistry()
        registry.installPreparedContentMountCohort(
            WorkspacePreparedContentMountCohort(
                generation: generation,
                terminalActivationInput: TerminalActivationInput(entries: [descriptor]),
                nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
            )
        )
        let handler = RecordingPreparedTerminalMountHandler(results: [.ready(surfaceID: surfaceID)])
        let port = PreparedTerminalMountAdmissionPort(
            generation: generation,
            initialFramesByPaneID: [paneID: frame],
            viewRegistry: registry,
            mountHandler: handler,
            descriptorsByPaneID: [paneID: descriptor]
        )
        let claimOutcome = port.claimPreparedTerminal(
            TerminalAdmissionProposal(
                generation: generation,
                paneID: paneID,
                attempt: 1,
                appliedVisibilityRevision: TerminalVisibilityRevision(generation: generation, ordinal: 0)
            )
        )
        guard case .claimed(let claim) = claimOutcome else {
            Issue.record("expected a granted claim")
            return
        }

        // Act
        let first = await port.activateClaimedTerminal(claim)
        let second = await port.activateClaimedTerminal(claim)

        // Assert
        #expect(first == .attempted(.ready(surfaceID: surfaceID)))
        #expect(second == .rejected(.claimAlreadyConsumed))
        #expect(handler.admissions.count == 1)
    }

    @Test("a claim value not minted by the port is refused")
    func aClaimValueNotMintedByThePortIsRefused() async throws {
        // Arrange
        let generation = try makePreparedTerminalTestGeneration()
        let descriptor = makePreparedTerminalTestDescriptor(pane: makePreparedTerminalTestPane())
        let paneID = descriptor.paneID
        let registry = ViewRegistry()
        registry.installPreparedContentMountCohort(
            WorkspacePreparedContentMountCohort(
                generation: generation,
                terminalActivationInput: TerminalActivationInput(entries: [descriptor]),
                nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
            )
        )
        let handler = RecordingPreparedTerminalMountHandler(results: [])
        let port = PreparedTerminalMountAdmissionPort(
            generation: generation,
            initialFramesByPaneID: [paneID: NSRect(x: 0, y: 0, width: 800, height: 600)],
            viewRegistry: registry,
            mountHandler: handler,
            descriptorsByPaneID: [paneID: descriptor]
        )
        let forgedClaim = ClaimedTerminalAdmission(
            claimID: UUID(),
            admission: TerminalActivationAdmission(generation: generation, descriptor: descriptor, attempt: 1),
            acknowledgedVisibilityRevision: TerminalVisibilityRevision(generation: generation, ordinal: 0)
        )

        // Act
        let outcome = await port.activateClaimedTerminal(forgedClaim)

        // Assert
        #expect(outcome == .rejected(.claimNotIssued))
        #expect(handler.admissions.isEmpty)
    }

    @Test("attempt two reuses held custody and the same frame")
    func attemptTwoReusesHeldCustodyAndTheSameFrame() async throws {
        // Arrange
        let generation = try makePreparedTerminalTestGeneration()
        let descriptor = makePreparedTerminalTestDescriptor(pane: makePreparedTerminalTestPane())
        let paneID = descriptor.paneID
        let frame = NSRect(x: 10, y: 20, width: 900, height: 600)
        let surfaceID = UUIDv7.generate()
        let registry = ViewRegistry()
        registry.installPreparedContentMountCohort(
            WorkspacePreparedContentMountCohort(
                generation: generation,
                terminalActivationInput: TerminalActivationInput(entries: [descriptor]),
                nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
            )
        )
        let handler = RecordingPreparedTerminalMountHandler(
            results: [
                .failed(failure: .surfaceCreationFailed(code: "transient"), retry: .retry),
                .ready(surfaceID: surfaceID),
            ]
        )
        let port = PreparedTerminalMountAdmissionPort(
            generation: generation,
            initialFramesByPaneID: [paneID: frame],
            viewRegistry: registry,
            mountHandler: handler,
            descriptorsByPaneID: [paneID: descriptor]
        )
        let revision = TerminalVisibilityRevision(generation: generation, ordinal: 0)

        // Act
        let firstClaimOutcome = port.claimPreparedTerminal(
            TerminalAdmissionProposal(
                generation: generation,
                paneID: paneID,
                attempt: 1,
                appliedVisibilityRevision: revision
            )
        )
        guard case .claimed(let firstClaim) = firstClaimOutcome else {
            Issue.record("expected attempt 1 to be granted a claim")
            return
        }
        let firstActivation = await port.activateClaimedTerminal(firstClaim)
        let stateAfterFirst = registry.preparedContentMountState(for: paneID, generation: generation)

        let secondClaimOutcome = port.claimPreparedTerminal(
            TerminalAdmissionProposal(
                generation: generation,
                paneID: paneID,
                attempt: 2,
                appliedVisibilityRevision: revision
            )
        )
        guard case .claimed(let secondClaim) = secondClaimOutcome else {
            Issue.record("expected attempt 2 to be granted a claim")
            return
        }
        let secondActivation = await port.activateClaimedTerminal(secondClaim)

        // Assert
        #expect(
            firstActivation
                == .attempted(.failed(failure: .surfaceCreationFailed(code: "transient"), retry: .retry))
        )
        #expect(stateAfterFirst == .mounting(owner: .terminal))
        #expect(firstClaim.claimID != secondClaim.claimID)
        #expect(secondActivation == .attempted(.ready(surfaceID: surfaceID)))
        #expect(
            registry.preparedContentMountState(for: paneID, generation: generation)
                == .completed(owner: .terminal, disposition: .mounted)
        )
        #expect(handler.initialFrames == [frame, frame])
    }

    @Test("a proposal with a mismatched attempt is rejected")
    func aProposalWithAMismatchedAttemptIsRejected() async throws {
        // Arrange
        let generation = try makePreparedTerminalTestGeneration()
        let descriptor = makePreparedTerminalTestDescriptor(pane: makePreparedTerminalTestPane())
        let paneID = descriptor.paneID
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let registry = ViewRegistry()
        registry.installPreparedContentMountCohort(
            WorkspacePreparedContentMountCohort(
                generation: generation,
                terminalActivationInput: TerminalActivationInput(entries: [descriptor]),
                nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
            )
        )
        let handler = RecordingPreparedTerminalMountHandler(
            results: [.failed(failure: .surfaceCreationFailed(code: "transient"), retry: .retry)]
        )
        let port = PreparedTerminalMountAdmissionPort(
            generation: generation,
            initialFramesByPaneID: [paneID: frame],
            viewRegistry: registry,
            mountHandler: handler,
            descriptorsByPaneID: [paneID: descriptor]
        )
        let revision = TerminalVisibilityRevision(generation: generation, ordinal: 0)
        let firstClaimOutcome = port.claimPreparedTerminal(
            TerminalAdmissionProposal(
                generation: generation,
                paneID: paneID,
                attempt: 1,
                appliedVisibilityRevision: revision
            )
        )
        guard case .claimed(let firstClaim) = firstClaimOutcome else {
            Issue.record("expected attempt 1 to be granted a claim")
            return
        }
        _ = await port.activateClaimedTerminal(firstClaim)

        // Act: skip straight to attempt 3, which does not match the expected next attempt (2).
        let mismatchedOutcome = port.claimPreparedTerminal(
            TerminalAdmissionProposal(
                generation: generation,
                paneID: paneID,
                attempt: 3,
                appliedVisibilityRevision: revision
            )
        )

        // Assert
        #expect(mismatchedOutcome == .rejected(.retryClaimMismatch))
        #expect(handler.admissions.count == 1)
    }

    @Test("two visibility changes before acknowledgement coalesce into one current set")
    func twoVisibilityChangesBeforeAcknowledgementCoalesceIntoOneCurrentSet() throws {
        // Arrange
        let generation = try makePreparedTerminalTestGeneration()
        let mainDescriptor = makePreparedTerminalTestDescriptor(pane: makePreparedTerminalTestPane())
        let drawerDescriptor = makePreparedTerminalTestDrawerDescriptor(pane: makePreparedTerminalTestPane())
        let registry = ViewRegistry()
        registry.installPreparedContentMountCohort(
            WorkspacePreparedContentMountCohort(
                generation: generation,
                terminalActivationInput: TerminalActivationInput(entries: [mainDescriptor, drawerDescriptor]),
                nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
            )
        )
        let handler = RecordingPreparedTerminalMountHandler(results: [])
        let port = PreparedTerminalMountAdmissionPort(
            generation: generation,
            initialFramesByPaneID: [
                mainDescriptor.paneID: NSRect(x: 0, y: 0, width: 800, height: 600),
                drawerDescriptor.paneID: NSRect(x: 0, y: 0, width: 400, height: 300),
            ],
            viewRegistry: registry,
            mountHandler: handler,
            descriptorsByPaneID: [
                mainDescriptor.paneID: mainDescriptor,
                drawerDescriptor.paneID: drawerDescriptor,
            ]
        )
        let mainOnlySnapshot = TerminalVisibleQueuedTerminals(
            generation: generation,
            activeMainPaneIDs: [mainDescriptor.paneID],
            visibleMainSiblingPaneIDs: [],
            activeDrawerPaneIDs: [],
            visibleDrawerSiblingPaneIDs: []
        )
        let mainAndDrawerSnapshot = TerminalVisibleQueuedTerminals(
            generation: generation,
            activeMainPaneIDs: [mainDescriptor.paneID],
            visibleMainSiblingPaneIDs: [],
            activeDrawerPaneIDs: [drawerDescriptor.paneID],
            visibleDrawerSiblingPaneIDs: []
        )

        // Act
        let firstRevision = port.recordCurrentVisibleQueuedTerminals(mainOnlySnapshot)
        let secondRevision = port.recordCurrentVisibleQueuedTerminals(mainAndDrawerSnapshot)
        let outcome = port.claimPreparedTerminal(
            TerminalAdmissionProposal(
                generation: generation,
                paneID: mainDescriptor.paneID,
                attempt: 1,
                appliedVisibilityRevision: firstRevision
            )
        )

        // Assert
        guard case .visibilityChanged(let snapshot) = outcome else {
            Issue.record("expected a stale proposal to receive the newest snapshot")
            return
        }
        #expect(snapshot.revision == secondRevision)
        #expect(snapshot.terminals == mainAndDrawerSnapshot)
        #expect(handler.admissions.isEmpty)
    }

    @Test("an identical current set mints no new revision")
    func anIdenticalCurrentSetMintsNoNewRevision() throws {
        // Arrange
        let generation = try makePreparedTerminalTestGeneration()
        let descriptor = makePreparedTerminalTestDescriptor(pane: makePreparedTerminalTestPane())
        let registry = ViewRegistry()
        registry.installPreparedContentMountCohort(
            WorkspacePreparedContentMountCohort(
                generation: generation,
                terminalActivationInput: TerminalActivationInput(entries: [descriptor]),
                nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
            )
        )
        let port = PreparedTerminalMountAdmissionPort(
            generation: generation,
            initialFramesByPaneID: [descriptor.paneID: NSRect(x: 0, y: 0, width: 800, height: 600)],
            viewRegistry: registry,
            mountHandler: RecordingPreparedTerminalMountHandler(results: []),
            descriptorsByPaneID: [descriptor.paneID: descriptor]
        )
        let terminals = TerminalVisibleQueuedTerminals(
            generation: generation,
            activeMainPaneIDs: [descriptor.paneID],
            visibleMainSiblingPaneIDs: [],
            activeDrawerPaneIDs: [],
            visibleDrawerSiblingPaneIDs: []
        )

        // Act
        let firstRevision = port.recordCurrentVisibleQueuedTerminals(terminals)
        let secondRevision = port.recordCurrentVisibleQueuedTerminals(terminals)

        // Assert
        #expect(firstRevision == secondRevision)
    }

    @Test("a pane that is no longer visible disappears from the current set")
    func aPaneThatIsNoLongerVisibleDisappearsFromTheCurrentSet() throws {
        // Arrange
        let generation = try makePreparedTerminalTestGeneration()
        let stillVisible = makePreparedTerminalTestDescriptor(pane: makePreparedTerminalTestPane())
        let noLongerVisible = makePreparedTerminalTestDescriptor(pane: makePreparedTerminalTestPane())
        let registry = ViewRegistry()
        registry.installPreparedContentMountCohort(
            WorkspacePreparedContentMountCohort(
                generation: generation,
                terminalActivationInput: TerminalActivationInput(entries: [stillVisible, noLongerVisible]),
                nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
            )
        )
        let port = PreparedTerminalMountAdmissionPort(
            generation: generation,
            initialFramesByPaneID: [
                stillVisible.paneID: NSRect(x: 0, y: 0, width: 800, height: 600),
                noLongerVisible.paneID: NSRect(x: 0, y: 0, width: 400, height: 300),
            ],
            viewRegistry: registry,
            mountHandler: RecordingPreparedTerminalMountHandler(results: []),
            descriptorsByPaneID: [
                stillVisible.paneID: stillVisible,
                noLongerVisible.paneID: noLongerVisible,
            ]
        )
        port.recordCurrentVisibleQueuedTerminals(
            TerminalVisibleQueuedTerminals(
                generation: generation,
                activeMainPaneIDs: [stillVisible.paneID],
                visibleMainSiblingPaneIDs: [noLongerVisible.paneID],
                activeDrawerPaneIDs: [],
                visibleDrawerSiblingPaneIDs: []
            )
        )

        // Act
        let revision = port.recordCurrentVisibleQueuedTerminals(
            TerminalVisibleQueuedTerminals(
                generation: generation,
                activeMainPaneIDs: [stillVisible.paneID],
                visibleMainSiblingPaneIDs: [],
                activeDrawerPaneIDs: [],
                visibleDrawerSiblingPaneIDs: []
            )
        )
        let outcome = port.claimPreparedTerminal(
            TerminalAdmissionProposal(
                generation: generation,
                paneID: stillVisible.paneID,
                attempt: 1,
                appliedVisibilityRevision: revision
            )
        )

        // Assert
        guard case .claimed = outcome else {
            Issue.record("expected the still-visible pane's proposal, carrying the latest revision, to claim")
            return
        }
    }

    @Test("a proposal carrying a foreign revision generation is rejected as stale, not visibility-changed")
    func aProposalCarryingAForeignRevisionGenerationIsRejectedAsStaleNotVisibilityChanged() throws {
        // Arrange: `proposal.generation` matches this port's generation (G1's
        // first, already-checked clause), but `appliedVisibilityRevision`
        // carries a foreign generation — as if the caller mixed a revision
        // acknowledged under a different cohort into an otherwise
        // correctly-generationed proposal.
        let generation = try makePreparedTerminalTestGeneration()
        let foreignGeneration = try makePreparedTerminalTestGeneration()
        let descriptor = makePreparedTerminalTestDescriptor(pane: makePreparedTerminalTestPane())
        let paneID = descriptor.paneID
        let registry = ViewRegistry()
        registry.installPreparedContentMountCohort(
            WorkspacePreparedContentMountCohort(
                generation: generation,
                terminalActivationInput: TerminalActivationInput(entries: [descriptor]),
                nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
            )
        )
        let handler = RecordingPreparedTerminalMountHandler(results: [])
        let port = PreparedTerminalMountAdmissionPort(
            generation: generation,
            initialFramesByPaneID: [paneID: NSRect(x: 0, y: 0, width: 800, height: 600)],
            viewRegistry: registry,
            mountHandler: handler,
            descriptorsByPaneID: [paneID: descriptor]
        )

        // Act
        let outcome = port.claimPreparedTerminal(
            TerminalAdmissionProposal(
                generation: generation,
                paneID: paneID,
                attempt: 1,
                appliedVisibilityRevision: TerminalVisibilityRevision(generation: foreignGeneration, ordinal: 0)
            )
        )

        // Assert
        #expect(outcome == .rejected(.staleGeneration))
        #expect(handler.admissions.isEmpty)
    }
}

@MainActor
final class RecordingPreparedTerminalMountHandler: PreparedTerminalMountHandling {
    private var results: [TerminalActivationAttemptResult]
    private(set) var admissions: [TerminalActivationAdmission] = []
    private(set) var initialFrames: [NSRect?] = []
    private(set) var authorities: [TerminalSurfaceCreationAuthority] = []

    init(results: [TerminalActivationAttemptResult]) {
        self.results = results
    }

    func mountPreparedTerminalContent(
        admission: TerminalActivationAdmission,
        initialFrame: NSRect?,
        authority: TerminalSurfaceCreationAuthority
    ) async -> TerminalActivationAttemptResult {
        admissions.append(admission)
        initialFrames.append(initialFrame)
        authorities.append(authority)
        return results.removeFirst()
    }
}

@MainActor
func makePreparedTerminalTestGeneration() throws -> WorkspaceContentMountGeneration {
    WorkspaceContentMountGeneration()
}

func makePreparedTerminalTestPane() -> Pane {
    Pane(
        id: UUIDv7.generate(),
        content: .terminal(
            TerminalState(
                provider: .zmx,
                lifetime: .persistent,
                zmxSessionID: .generateUUIDv7()
            )
        ),
        metadata: PaneMetadata(
            launchDirectory: URL(filePath: "/tmp/prepared-terminal-admission"),
            title: "Prepared Terminal"
        )
    )
}

private func makePreparedTerminalTestDescriptor(pane: Pane) -> TerminalActivationDescriptor {
    guard case .terminal = pane.content else {
        preconditionFailure("prepared terminal test requires terminal content")
    }
    return TerminalActivationDescriptor(
        pane: pane,
        visibilityPriority: .activeVisible,
        hostPlacement: .tab(tabID: UUIDv7.generate())
    )
}

func makePreparedTerminalTestDrawerDescriptor(pane: Pane) -> TerminalActivationDescriptor {
    guard case .terminal = pane.content else {
        preconditionFailure("prepared terminal test requires terminal content")
    }
    return TerminalActivationDescriptor(
        pane: pane,
        visibilityPriority: .activeVisible,
        hostPlacement: .drawer(
            tabID: UUIDv7.generate(),
            parentPaneID: PaneId(existingUUID: UUIDv7.generate()),
            drawerID: UUIDv7.generate()
        )
    )
}
