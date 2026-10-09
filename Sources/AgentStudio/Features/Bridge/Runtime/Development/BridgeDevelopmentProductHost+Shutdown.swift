import AgentStudioInfrastructure
import Foundation

extension BridgeDevelopmentProductHost {
    @discardableResult
    package func shutdown() async -> BridgeDevelopmentProductHostShutdownResult {
        guard !isShutdown else {
            if let shutdownResult { return shutdownResult }
            return await withCheckedContinuation { shutdownWaiters.append($0) }
        }
        isShutdown = true
        unfinishedShutdownDrains = [
            "bootstrap", "reviewComparison", "fileRefresh", "sessionOwner", "provider",
            "reviewCache", "publication", "construction", "gitRead",
        ]
        let (completionStream, completionSignal) = AsyncStream.makeStream(
            of: BridgeDevelopmentProductHostShutdownResult.self,
            bufferingPolicy: .bufferingOldest(1)
        )
        shutdownCompletion = completionSignal
        shutdownDeadlineTask = Task { [self] in
            do {
                try await retirementDelay.wait(AppPolicies.Bridge.productRetirementQuiescenceDeadline)
            } catch is CancellationError {
                return
            } catch {
                // A failed clock still resolves disposal through the typed diagnostic.
            }
            resolveShutdown(
                .quiescenceDeadlineExceeded(unfinishedExecutionCount: unfinishedShutdownDrains.count)
            )
        }

        // Close logical authority before any drain can suspend. The MainActor hop
        // publishes the remaining fences as one synchronous operation there.
        productAdmissionGate.close()
        reviewGitRefreshSeedHolder.retire()
        let transitionTail = bootstrapTransitionTail
        bootstrapTransitionTail = nil
        let reviewComparisonTask = activeReviewComparisonTask
        reviewComparisonTask?.cancel()
        let retiringReviewComparisonTasks = Array(retiringReviewComparisonTasks.values)
        for retiringReviewComparisonTask in retiringReviewComparisonTasks {
            retiringReviewComparisonTask.cancel()
        }
        activeReviewComparisonTask = nil
        activeReviewComparisonTaskAttempt = nil
        self.retiringReviewComparisonTasks.removeAll()
        let publicationDrain = await MainActor.run {
            // The admission gates reject late work while physical drains continue.
            if let comparison = refreshAdmissionCoordinator.productPresentationSnapshot.reviewComparison,
                case .pending(let generation) = comparison.attempt
            {
                refreshAdmissionCoordinator.failReviewComparisonAttempt(
                    reviewGeneration: generation,
                    failureKind: "publication_failed",
                    retryable: true
                )
            }
            refreshAdmissionCoordinator.close()
            return reviewPublicationCoordinator.close()
        }

        _ = scheduleShutdownDrain("bootstrap") {
            await transitionTail?.value
        }  // fire-and-forget: the task retains the host and records completion in its drain ledger.
        let comparisonDrain = scheduleShutdownDrain("reviewComparison") {
            await reviewComparisonTask?.value
            for retiringTask in retiringReviewComparisonTasks { await retiringTask.value }
        }
        let fileRefreshDrain = scheduleShutdownDrain("fileRefresh") { [self] in
            await worktreeRefreshDriver.closeAndDrain()
        }
        let ownerDrain = scheduleShutdownDrain("sessionOwner") { [self] in
            _ = await productSessionOwner.retire(reason: .paneDisposal)
        }
        let providerDrain = scheduleShutdownDrain("provider") { [self] in
            await ownerDrain.value
            await productProvider.closeAndDrain()
        }
        let reviewCacheDrain = scheduleShutdownDrain("reviewCache") { [self] in
            await reviewContentLoaderCache.closeAndDrain()
        }
        _ = scheduleShutdownDrain("publication") {
            await providerDrain.value
            await reviewCacheDrain.value
            await publicationDrain.releaseAndWait()
        }  // fire-and-forget: the task retains the host and records completion in its drain ledger.
        let constructionDrain = scheduleShutdownDrain("construction") { [self] in
            await comparisonDrain.value
            await fileRefreshDrain.value
            await constructionCoordinator.shutdown()
        }
        _ = scheduleShutdownDrain("gitRead") { [self] in
            await constructionDrain.value
            await providerDrain.value
            await gitReadScheduler.shutdown()
        }  // fire-and-forget: the task retains the host and records completion in its drain ledger.
        var completionIterator = completionStream.makeAsyncIterator()
        return await completionIterator.next() ?? .completed
    }

    package func shutdownSnapshot() -> BridgeDevelopmentProductHostShutdownSnapshot {
        .init(
            unfinishedDrainCount: unfinishedShutdownDrains.count,
            cleanupCompleted: isShutdown && unfinishedShutdownDrains.isEmpty
        )
    }

    package func waitForShutdownCleanup() async {
        guard isShutdown, !unfinishedShutdownDrains.isEmpty else { return }
        await withCheckedContinuation { cleanupWaiters.append($0) }
    }

    private func scheduleShutdownDrain(
        _ name: String,
        operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        Task { [self] in
            await operation()
            completeShutdownDrain(name)
        }
    }

    private func completeShutdownDrain(_ name: String) {
        unfinishedShutdownDrains.remove(name)
        if unfinishedShutdownDrains.isEmpty {
            resolveShutdown(.completed)
            let waiters = cleanupWaiters
            cleanupWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    private func resolveShutdown(_ result: BridgeDevelopmentProductHostShutdownResult) {
        guard shutdownResult == nil else { return }
        shutdownResult = result
        shutdownDeadlineTask?.cancel()
        shutdownDeadlineTask = nil
        shutdownCompletion?.yield(result)
        shutdownCompletion?.finish()
        shutdownCompletion = nil
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: result) }
    }

}
