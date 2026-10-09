import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product session producer registry")
struct BridgeProductSessionProducerTests {
    @Test("transport keepalives cannot enter the N3 frame and credit registry")
    func keepaliveBypassesProducerRegistry() async throws {
        let registry = BridgeProductProducerRegistryTestHarness()
        let request = try producerRegistryMetadataStreamRequest()
        let operation = HeldStep<BridgeProductProducerLease>("keepaliveOperation")
        let registration = await registry.registerMetadataProducer(request: request) { lease in
            try? await operation.arrive(lease)
        }
        let lease = try #require(registration.lease)
        _ = try await operation.firstArrival()
        _ = try await registry.enqueueRequiredOpeningFrame(for: lease) { sequence in
            try producerRegistryMetadataOpeningFrame(for: request, sequence: sequence)
        }
        let before = await registry.snapshot()

        let keepalive = try await registry.enqueueNonterminalFrame(
            for: lease,
            build: { sequence in
                .metadata(
                    .streamKeepalive(
                        .init(frameIdentity: .init(correlation: request.correlation, streamSequence: sequence))
                    ))
            },
            overflowReset: { sequence in
                try producerRegistryMetadataTerminalFrame(for: request, sequence: sequence)
            }
        )

        #expect(keepalive == .rejected(.frameKindMismatch))
        #expect(await registry.snapshot() == before)
        try await closeAllProducerRegistryProducers(in: registry)
    }

    @Test("metadata registration is singular and rejects before starting duplicate work")
    func metadataRegistrationRejectsDuplicateBeforeStartingWork() async throws {
        // Arrange
        let registry = BridgeProductProducerRegistryTestHarness()
        let activeRequest = try producerRegistryMetadataStreamRequest(resumeFromStreamSequence: nil)
        let duplicateRequest = try producerRegistryMetadataStreamRequest(resumeFromStreamSequence: nil)
        let activeOperation = HeldStep<BridgeProductProducerLease>("activeOperation")
        let duplicateInvocation = BridgeProductProducerInvocationCounter()

        // Act
        let activeRegistration = await registry.registerMetadataProducer(
            request: activeRequest
        ) { lease in
            try? await activeOperation.arrive(lease)
        }
        let activeLease = try #require(activeRegistration.lease)
        _ = try await activeOperation.firstArrival()
        let beforeDuplicate = await registry.snapshot()
        let duplicateRegistration = await registry.registerMetadataProducer(
            request: duplicateRequest
        ) { _ in
            await duplicateInvocation.recordInvocation()
        }
        let afterDuplicate = await registry.snapshot()
        let opening = try await registry.enqueueRequiredOpeningFrame(
            for: activeLease,
            build: { sequence in
                try producerRegistryMetadataOpeningFrame(for: activeRequest, sequence: sequence)
            }
        )

        // Assert
        #expect(activeRegistration.lease != nil)
        #expect(beforeDuplicate.nextMetadataStreamSequence == 0)
        #expect(duplicateRegistration == .rejected(.duplicate))
        #expect(!(await duplicateInvocation.wasInvoked))
        #expect(afterDuplicate == beforeDuplicate)
        #expect(opening.enqueuedFrame?.sequence == 0)
        #expect(await registry.snapshot().nextMetadataStreamSequence == 1)
        try await closeAllProducerRegistryProducers(in: registry)
        #expect(await registry.snapshot().hasZeroResidue)
    }

    @Test("content registration keys duplicates by the complete frozen admission")
    func contentRegistrationUsesCompleteAdmissionIdentity() async throws {
        // Arrange
        let registry = BridgeProductProducerRegistryTestHarness()
        let firstRequest = try producerRegistryContentRequest(workerDerivationEpoch: 2)
        let changedRequest = try producerRegistryContentRequest(workerDerivationEpoch: 3)
        let firstOperation = HeldStep<BridgeProductProducerLease>("firstOperation")
        let changedOperation = HeldStep<BridgeProductProducerLease>("changedOperation")
        let duplicateInvocation = BridgeProductProducerInvocationCounter()

        // Act
        let firstRegistration = await registry.registerContentProducer(request: firstRequest) { lease in
            try? await firstOperation.arrive(lease)
        }
        _ = try await firstOperation.firstArrival()
        let duplicateRegistration = await registry.registerContentProducer(request: firstRequest) { _ in
            await duplicateInvocation.recordInvocation()
        }
        let changedRegistration = await registry.registerContentProducer(request: changedRequest) { lease in
            try? await changedOperation.arrive(lease)
        }
        _ = try await changedOperation.firstArrival()

        // Assert
        #expect(firstRegistration.lease != nil)
        #expect(duplicateRegistration == .rejected(.duplicate))
        #expect(changedRegistration.lease != nil)
        #expect(!(await duplicateInvocation.wasInvoked))
        #expect(await registry.snapshot().activeContentLeaseCount == 2)
        try await closeAllProducerRegistryProducers(in: registry)
    }

    @Test("metadata opening and mixed frames share one contiguous pane-wide sequence")
    func metadataFramesUseOnePaneWideSequence() async throws {
        // Arrange
        let registry = BridgeProductProducerRegistryTestHarness()
        let request = try producerRegistryMetadataStreamRequest()
        let operation = HeldStep<BridgeProductProducerLease>("operation")
        let registration = await registry.registerMetadataProducer(request: request) { lease in
            try? await operation.arrive(lease)
        }
        let lease = try #require(registration.lease)
        _ = try await operation.firstArrival()
        let openingFrame = try await registry.enqueueRequiredOpeningFrame(
            for: lease,
            build: { sequence in
                try producerRegistryMetadataOpeningFrame(for: request, sequence: sequence)
            }
        )
        let deliveredOpening = await registry.consumeNextFrame(for: lease)

        // Act
        let reviewFrame = try await registry.enqueueNonterminalFrame(
            for: lease,
            build: { sequence in
                try producerRegistryMetadataProgressFrame(for: request, sequence: sequence, identitySuffix: "review")
            },
            overflowReset: { sequence in
                try producerRegistryMetadataTerminalFrame(for: request, sequence: sequence)
            }
        )
        let fileFrame = try await registry.enqueueNonterminalFrame(
            for: lease,
            build: { sequence in
                try producerRegistryMetadataProgressFrame(for: request, sequence: sequence, identitySuffix: "file")
            },
            overflowReset: { sequence in
                try producerRegistryMetadataTerminalFrame(for: request, sequence: sequence)
            }
        )

        // Assert
        #expect(openingFrame.enqueuedFrame?.sequence == 0)
        #expect(openingFrame.enqueuedFrame?.requiredOpening == true)
        #expect(deliveredOpening?.sequence == 0)
        #expect(reviewFrame.enqueuedFrame?.sequence == 1)
        #expect(fileFrame.enqueuedFrame?.sequence == 2)
        #expect(await registry.consumeNextFrame(for: lease)?.sequence == 1)
        #expect(await registry.consumeNextFrame(for: lease)?.sequence == 2)
        #expect(await registry.snapshot().nextMetadataStreamSequence == 3)
        try await closeAllProducerRegistryProducers(in: registry)
    }

    @Test("nonterminal overflow atomically installs a terminal reset after opening delivery")
    func nonterminalOverflowInstallsTerminalResetAtomically() async throws {
        // Arrange
        let request = try producerRegistryMetadataStreamRequest()
        let openingFrame = try producerRegistryMetadataOpeningFrame(for: request, sequence: 0)
        let firstFrame = try producerRegistryMetadataProgressFrame(
            for: request,
            sequence: 1,
            identitySuffix: "first"
        )
        let secondFrame = try producerRegistryMetadataProgressFrame(
            for: request,
            sequence: 2,
            identitySuffix: "second"
        )
        let thirdFrame = try producerRegistryMetadataProgressFrame(
            for: request,
            sequence: 3,
            identitySuffix: "third"
        )
        let resetFrame = try producerRegistryMetadataTerminalFrame(for: request, sequence: 1)
        let openingData = try openingFrame.encode()
        let firstData = try firstFrame.encode()
        let secondData = try secondFrame.encode()
        let thirdData = try thirdFrame.encode()
        let resetData = try resetFrame.encode()
        let maximumEncodedFrameByteCount = try #require(
            [openingData.count, firstData.count, secondData.count, thirdData.count, resetData.count].max()
        )
        let limits = try BridgeProductProducerQueueLimits(
            maximumQueuedFrameCount: 3,
            maximumQueuedByteCount: firstData.count + secondData.count + thirdData.count + resetData.count,
            maximumEncodedFrameByteCount: maximumEncodedFrameByteCount,
            terminalFrameReserve: 1
        )
        let registry = BridgeProductProducerRegistryTestHarness(limits: limits)
        let operation = HeldStep<BridgeProductProducerLease>("operation")
        let registration = await registry.registerMetadataProducer(request: request) { lease in
            try? await operation.arrive(lease)
        }
        let lease = try #require(registration.lease)
        _ = try await operation.firstArrival()
        _ = try await registry.enqueueRequiredOpeningFrame(
            for: lease,
            build: { _ in openingFrame }
        )
        #expect(await registry.consumeNextFrame(for: lease)?.requiredOpening == true)
        _ = try await registry.enqueueNonterminalFrame(
            for: lease,
            build: { _ in firstFrame },
            overflowReset: { sequence in
                try producerRegistryMetadataTerminalFrame(for: request, sequence: sequence)
            }
        )
        _ = try await registry.enqueueNonterminalFrame(
            for: lease,
            build: { _ in secondFrame },
            overflowReset: { sequence in
                try producerRegistryMetadataTerminalFrame(for: request, sequence: sequence)
            }
        )

        // Act
        let overflowResult = try await registry.enqueueNonterminalFrame(
            for: lease,
            build: { _ in thirdFrame },
            overflowReset: { _ in resetFrame }
        )
        let snapshot = await registry.snapshot()
        let queuedReset = await registry.consumeNextFrame(for: lease)

        // Assert
        #expect(
            overflowResult
                == .queueReset(
                    frame: .init(
                        data: resetData,
                        sequence: 1,
                        terminal: true,
                        requiredOpening: false,
                        batchComplete: false
                    ),
                    discardedFrameCount: 2,
                    discardedByteCount: firstData.count + secondData.count
                )
        )
        #expect(snapshot.queuedFrameCount == 1)
        #expect(snapshot.queuedByteCount == resetData.count)
        #expect(snapshot.nextMetadataStreamSequence == 2)
        #expect(queuedReset?.sequence == 1)
        #expect(queuedReset?.terminal == true)
        try await closeAllProducerRegistryProducers(in: registry)
    }

    @Test("oversized overflow reset leaves queue bytes lifecycle and sequence unchanged")
    func invalidOverflowResetDoesNotPartiallyMutateQueue() async throws {
        // Arrange
        let request = try producerRegistryMetadataStreamRequest()
        let openingFrame = try producerRegistryMetadataOpeningFrame(for: request, sequence: 0)
        let pendingFrame = try producerRegistryMetadataProgressFrame(
            for: request,
            sequence: 1,
            identitySuffix: "pending"
        )
        let candidateFrame = try producerRegistryMetadataProgressFrame(
            for: request,
            sequence: 2,
            identitySuffix: "candidate"
        )
        let oversizedResetFrame = try producerRegistryMetadataTerminalFrame(
            for: request,
            sequence: 1,
            safeMessage: String(repeating: "x", count: BridgeProductWireContract.maximumSafeMessageByteLength)
        )
        let openingData = try openingFrame.encode()
        let pendingData = try pendingFrame.encode()
        let candidateData = try candidateFrame.encode()
        let oversizedResetData = try oversizedResetFrame.encode()
        let maximumEncodedFrameByteCount = try #require(
            [openingData.count, pendingData.count, candidateData.count].max()
        )
        let maximumQueuedByteCount = pendingData.count + candidateData.count - 1
        try #require(maximumQueuedByteCount >= maximumEncodedFrameByteCount)
        try #require(oversizedResetData.count > maximumEncodedFrameByteCount)
        let limits = try BridgeProductProducerQueueLimits(
            maximumQueuedFrameCount: 3,
            maximumQueuedByteCount: maximumQueuedByteCount,
            maximumEncodedFrameByteCount: maximumEncodedFrameByteCount,
            terminalFrameReserve: 1
        )
        let registry = BridgeProductProducerRegistryTestHarness(limits: limits)
        let operation = HeldStep<BridgeProductProducerLease>("operation")
        let registration = await registry.registerMetadataProducer(request: request) { lease in
            try? await operation.arrive(lease)
        }
        let lease = try #require(registration.lease)
        _ = try await operation.firstArrival()
        _ = try await registry.enqueueRequiredOpeningFrame(
            for: lease,
            build: { _ in openingFrame }
        )
        _ = await registry.consumeNextFrame(for: lease)
        _ = try await registry.enqueueNonterminalFrame(
            for: lease,
            build: { _ in pendingFrame },
            overflowReset: { sequence in
                try producerRegistryMetadataTerminalFrame(for: request, sequence: sequence)
            }
        )
        let beforeOverflow = await registry.snapshot()

        // Act
        let overflowResult = try await registry.enqueueNonterminalFrame(
            for: lease,
            build: { _ in candidateFrame },
            overflowReset: { _ in oversizedResetFrame }
        )
        let afterOverflow = await registry.snapshot()

        // Assert
        #expect(
            overflowResult
                == .rejected(
                    .frameTooLarge(maximumEncodedByteCount: maximumEncodedFrameByteCount)
                )
        )
        #expect(afterOverflow == beforeOverflow)
        #expect(await registry.consumeNextFrame(for: lease)?.data == pendingData)
        try await closeAllProducerRegistryProducers(in: registry)
    }

    @Test("byte-saturated queue atomically replaces pending data with a fitting terminal")
    func terminalFrameCanReplaceByteSaturatedPendingFrames() async throws {
        // Arrange
        let request = try producerRegistryMetadataStreamRequest()
        let openingFrame = try producerRegistryMetadataOpeningFrame(for: request, sequence: 0)
        let pendingFrame = try producerRegistryMetadataProgressFrame(
            for: request,
            sequence: 1,
            identitySuffix: String(repeating: "p", count: 100)
        )
        let replacementTerminalFrame = try producerRegistryMetadataTerminalFrame(for: request, sequence: 1)
        let candidateTerminalFrame = try producerRegistryMetadataTerminalFrame(for: request, sequence: 2)
        let openingData = try openingFrame.encode()
        let pendingData = try pendingFrame.encode()
        let replacementTerminalData = try replacementTerminalFrame.encode()
        let candidateTerminalData = try candidateTerminalFrame.encode()
        try #require(pendingData.count >= openingData.count)
        try #require(pendingData.count >= replacementTerminalData.count)
        try #require(pendingData.count >= candidateTerminalData.count)
        let limits = try BridgeProductProducerQueueLimits(
            maximumQueuedFrameCount: 3,
            maximumQueuedByteCount: pendingData.count,
            maximumEncodedFrameByteCount: pendingData.count,
            terminalFrameReserve: 1
        )
        let registry = BridgeProductProducerRegistryTestHarness(limits: limits)
        let operation = HeldStep<BridgeProductProducerLease>("operation")
        let registration = await registry.registerMetadataProducer(request: request) { lease in
            try? await operation.arrive(lease)
        }
        let lease = try #require(registration.lease)
        _ = try await operation.firstArrival()
        _ = try await registry.enqueueRequiredOpeningFrame(
            for: lease,
            build: { _ in openingFrame }
        )
        _ = await registry.consumeNextFrame(for: lease)
        _ = try await registry.enqueueNonterminalFrame(
            for: lease,
            build: { _ in pendingFrame },
            overflowReset: { sequence in
                try producerRegistryMetadataTerminalFrame(for: request, sequence: sequence)
            }
        )

        // Act
        let terminalResult = try await registry.enqueueTerminalFrame(
            for: lease,
            build: { sequence in
                try producerRegistryMetadataTerminalFrame(for: request, sequence: sequence)
            }
        )
        let queuedTerminal = await registry.consumeNextFrame(for: lease)

        // Assert
        #expect(
            terminalResult
                == .queueReset(
                    frame: .init(
                        data: replacementTerminalData,
                        sequence: 1,
                        terminal: true,
                        requiredOpening: false,
                        batchComplete: false
                    ),
                    discardedFrameCount: 1,
                    discardedByteCount: pendingData.count
                )
        )
        #expect(queuedTerminal?.sequence == 1)
        #expect(queuedTerminal?.terminal == true)
        try await closeAllProducerRegistryProducers(in: registry)
    }

    @Test("required opening survives saturation and ordinary content terminal is never sequence zero")
    func requiredOpeningCannotBeReplacedByTerminal() async throws {
        // Arrange
        let request = try producerRegistryContentRequest(workerDerivationEpoch: 2)
        let openingFrame = producerRegistryContentOpeningFrame(for: request)
        let terminalFrame = try producerRegistryContentTerminalFrame(sequence: 1)
        let openingData = try openingFrame.encode()
        let terminalData = try terminalFrame.encode()
        try #require(openingData.count >= terminalData.count)
        let limits = try BridgeProductProducerQueueLimits(
            maximumQueuedFrameCount: 3,
            maximumQueuedByteCount: openingData.count,
            maximumEncodedFrameByteCount: openingData.count,
            terminalFrameReserve: 1
        )
        let registry = BridgeProductProducerRegistryTestHarness(limits: limits)
        let operation = HeldStep<BridgeProductProducerLease>("operation")
        let registration = await registry.registerContentProducer(request: request) { lease in
            try? await operation.arrive(lease)
        }
        let lease = try #require(registration.lease)
        _ = try await operation.firstArrival()

        // Act
        let prematureTerminal = try await registry.enqueueTerminalFrame(
            for: lease,
            build: { sequence in try producerRegistryContentTerminalFrame(sequence: sequence) }
        )
        let opening = try await registry.enqueueRequiredOpeningFrame(
            for: lease,
            build: { _ in openingFrame }
        )
        let beforeSaturatedTerminal = await registry.snapshot()
        let saturatedTerminal = try await registry.enqueueTerminalFrame(
            for: lease,
            build: { _ in terminalFrame }
        )
        let afterSaturatedTerminal = await registry.snapshot()
        let deliveredOpening = await registry.consumeNextFrame(for: lease)
        let admittedTerminal = try await registry.enqueueTerminalFrame(
            for: lease,
            build: { _ in terminalFrame }
        )

        // Assert
        #expect(prematureTerminal == .rejected(.openingFrameRequired))
        #expect(opening.enqueuedFrame?.sequence == 0)
        #expect(opening.enqueuedFrame?.requiredOpening == true)
        #expect(await registry.openingFrameState(for: lease) == .delivered)
        #expect(saturatedTerminal == .rejected(.closeRequired))
        #expect(afterSaturatedTerminal == beforeSaturatedTerminal)
        #expect(deliveredOpening?.requiredOpening == true)
        #expect(admittedTerminal.enqueuedFrame?.sequence == 1)
        #expect(admittedTerminal.enqueuedFrame?.terminal == true)
        try await closeAllProducerRegistryProducers(in: registry)
    }

    @Test("individual encoded frame ceiling and queue policy cross-fields are enforced")
    func individualFrameAndQueuePolicyLimitsAreValidated() async throws {
        // Arrange
        let request = try producerRegistryMetadataStreamRequest(
            metadataStreamId: "metadata-stream-" + String(repeating: "x", count: 96)
        )
        let openingFrame = try producerRegistryMetadataOpeningFrame(for: request, sequence: 0)
        let openingData = try openingFrame.encode()
        let maximumEncodedFrameByteCount = openingData.count - 1
        let limits = try BridgeProductProducerQueueLimits(
            maximumQueuedFrameCount: 3,
            maximumQueuedByteCount: openingData.count,
            maximumEncodedFrameByteCount: maximumEncodedFrameByteCount,
            terminalFrameReserve: 1
        )
        let registry = BridgeProductProducerRegistryTestHarness(limits: limits)
        let operation = HeldStep<BridgeProductProducerLease>("operation")
        let registration = await registry.registerMetadataProducer(request: request) { lease in
            try? await operation.arrive(lease)
        }
        let lease = try #require(registration.lease)
        _ = try await operation.firstArrival()
        let beforeOversizedFrame = await registry.snapshot()

        // Act
        let oversizedOpening = try await registry.enqueueRequiredOpeningFrame(
            for: lease,
            build: { _ in openingFrame }
        )
        let afterOversizedFrame = await registry.snapshot()

        // Assert
        #expect(
            oversizedOpening
                == .rejected(
                    .frameTooLarge(maximumEncodedByteCount: maximumEncodedFrameByteCount)
                )
        )
        #expect(afterOversizedFrame == beforeOversizedFrame)
        #expect(await registry.openingFrameState(for: lease) == .required)
        #expect(throws: BridgeProductProducerQueueLimitsError.maximumEncodedFrameExceedsQueue) {
            try BridgeProductProducerQueueLimits(
                maximumQueuedFrameCount: 3,
                maximumQueuedByteCount: maximumEncodedFrameByteCount - 1,
                maximumEncodedFrameByteCount: maximumEncodedFrameByteCount,
                terminalFrameReserve: 1
            )
        }
        #expect(throws: BridgeProductProducerQueueLimitsError.invalidTerminalFrameReserve) {
            try BridgeProductProducerQueueLimits(
                maximumQueuedFrameCount: 3,
                maximumQueuedByteCount: openingData.count,
                maximumEncodedFrameByteCount: maximumEncodedFrameByteCount,
                terminalFrameReserve: 0
            )
        }
        try await closeAllProducerRegistryProducers(in: registry)
    }

}

extension BridgeProductProducerRegistration {
    fileprivate var lease: BridgeProductProducerLease? {
        guard case .accepted(let lease) = self else { return nil }
        return lease
    }
}

extension BridgeProductProducerEnqueueResult {
    fileprivate var enqueuedFrame: BridgeProductQueuedProducerFrame? {
        switch self {
        case .enqueued(let frame), .queueReset(let frame, _, _):
            frame
        case .rejected:
            nil
        }
    }
}
