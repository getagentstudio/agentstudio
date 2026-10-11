import Foundation

extension RepoScannerTraversalSession {
    struct RetainedTargetIndex: Sendable {
        let retainedPathKeys: [String]
        private let rootURL: URL
        private let rootUsesPrivateSpelling: Bool
        private let cachedRootPathKey: String
        private let pathKeyByEntryComponents: [ArraySlice<String>: String]
        private let privateEntryComponents: Set<ArraySlice<String>>

        var rootPathKey: String {
            rootUsesPrivateSpelling ? rootURL.standardizedFileURL.path : cachedRootPathKey
        }

        init(rootURL: URL, retainedCheckoutPaths: [URL]) {
            self.rootURL = rootURL
            rootUsesPrivateSpelling = rootURL.pathComponents.starts(with: ["/", "private"])
            let standardizedRootURL = rootURL.standardizedFileURL
            let rootComponents = standardizedRootURL.pathComponents
            cachedRootPathKey = standardizedRootURL.path
            retainedPathKeys = retainedCheckoutPaths.map { $0.standardizedFileURL.path }

            var pathKeysByComponents: [ArraySlice<String>: String] = [:]
            var privateComponents: Set<ArraySlice<String>> = []
            for (retainedPath, retainedPathKey) in zip(retainedCheckoutPaths, retainedPathKeys) {
                let retainedComponents = URL(fileURLWithPath: retainedPathKey).pathComponents
                guard retainedComponents.starts(with: rootComponents) else { continue }
                let entryComponents = retainedComponents.dropFirst(rootComponents.count)
                pathKeysByComponents[entryComponents] = retainedPathKey
                if retainedPath.pathComponents.starts(with: ["/", "private"]) {
                    privateComponents.insert(entryComponents)
                }
            }
            pathKeyByEntryComponents = pathKeysByComponents
            privateEntryComponents = privateComponents
        }

        func pathKey(for entry: PendingEnumerationEntry) -> String? {
            // Enumeration can use a physical root alias. Its level identifies
            // the root-relative components without normalizing another URL.
            let entryComponents = entry.url.pathComponents.suffix(entry.depth)
            // Foundation shortens a leading /private only while the shortened
            // path exists. Preserve inspection-time identity for those spellings.
            if rootUsesPrivateSpelling || privateEntryComponents.contains(entryComponents) {
                return entryComponents.reduce(rootURL) { partialPath, component in
                    partialPath.appending(path: component)
                }.standardizedFileURL.path
            }
            return pathKeyByEntryComponents[entryComponents]
        }
    }

    func removeRetainedTargetExaminedByTraversal(
        _ entry: PendingEnumerationEntry,
        isSymbolicLink: Bool,
        state: inout TraversalState
    ) {
        guard entry.depth <= state.maxDepth,
            !isSymbolicLink,
            !state.remainingRetainedPathKeys.isEmpty,
            let retainedPathKey = retainedTargetIndex.pathKey(for: entry)
        else { return }
        state.remainingRetainedPathKeys.remove(retainedPathKey)
    }

    func inspectNextRetainedTarget<ServiceClock: Clock<Duration>>(
        at nextIndex: Int,
        traversalLease: TraversalLease,
        usage: inout MutableQuantumUsage,
        serviceClock: ServiceClock,
        serviceStartedAt: ServiceClock.Instant
    ) -> QuantumDisposition? {
        guard !traversalLease.state.remainingRetainedPathKeys.isEmpty else {
            traversalLease.state.position = .exhausted
            return .exhausted
        }
        guard nextIndex < traversalLease.state.retainedCheckoutPaths.count else {
            traversalLease.state.position = .exhausted
            return .exhausted
        }

        let retainedCheckoutPath = traversalLease.state.retainedCheckoutPaths[nextIndex]
        let followingPosition = TraversalPosition.retainedTargets(nextIndex: nextIndex + 1)
        let retainedPathKey = retainedCheckoutPath.standardizedFileURL.path
        guard traversalLease.state.remainingRetainedPathKeys.contains(retainedPathKey) else {
            usage.enumeratedItemCount += 1
            traversalLease.state.position = followingPosition
            return nil
        }
        if shouldSuspendBeforeConsumingPath(retainedCheckoutPath, usage: usage) {
            traversalLease.state.position = .retainedTargets(nextIndex: nextIndex)
            return .suspended
        }
        traversalLease.state.remainingRetainedPathKeys.remove(retainedPathKey)
        guard
            consumeEnumeratedItem(
                retainedCheckoutPath,
                state: &traversalLease.state,
                usage: &usage
            )
        else {
            return .exhausted
        }

        let resolvedRetainedCheckoutPath = retainedCheckoutPath.resolvingSymlinksInPath()
        guard
            resolvedRetainedCheckoutPath.pathComponents.starts(
                with: traversalLease.state.rootURL.pathComponents
            )
        else {
            traversalLease.state.validationFailureCount += 1
            if recordFailure(
                .gitRepositoryDiscoveryFailed(
                    candidatePath: retainedCheckoutPath,
                    reason: .candidateAdmissionRejected(.outsideRegisteredRoot)
                ),
                state: &traversalLease.state,
                usage: &usage
            ) {
                return .exhausted
            }
            traversalLease.state.position = followingPosition
            return nil
        }

        let retainedTargetValues: URLResourceValues
        do {
            retainedTargetValues = try retainedCheckoutPath.resourceValues(
                forKeys: [.isDirectoryKey]
            )
        } catch let error as CocoaError where Self.isMissingFileError(error) {
            traversalLease.state.position = followingPosition
            return nil
        } catch {
            traversalLease.state.entryMetadataFailureCount += 1
            if recordFailure(
                .entryMetadataReadFailed(
                    entryPath: retainedCheckoutPath,
                    detail: String(describing: error)
                ),
                state: &traversalLease.state,
                usage: &usage
            ) {
                return .exhausted
            }
            traversalLease.state.position = followingPosition
            return nil
        }
        guard retainedTargetValues.isDirectory == true else {
            traversalLease.state.position = followingPosition
            return nil
        }

        traversalLease.state.directoryVisitCount += 1
        return inspectRetainedTargetGitMarker(
            at: retainedCheckoutPath,
            nextIndex: nextIndex,
            traversalLease: traversalLease,
            usage: &usage,
            serviceClock: serviceClock,
            serviceStartedAt: serviceStartedAt
        )
    }

    private func inspectRetainedTargetGitMarker<ServiceClock: Clock<Duration>>(
        at retainedCheckoutPath: URL,
        nextIndex: Int,
        traversalLease: TraversalLease,
        usage: inout MutableQuantumUsage,
        serviceClock: ServiceClock,
        serviceStartedAt: ServiceClock.Instant
    ) -> QuantumDisposition? {
        let followingPosition = TraversalPosition.retainedTargets(nextIndex: nextIndex + 1)
        switch inspectGitMarker(at: retainedCheckoutPath) {
        case .candidate:
            traversalLease.state.gitCandidateCount += 1
            let continuation = PostValidationContinuation.retainedTargets(
                nextIndex: nextIndex + 1
            )
            if shouldSuspendBeforeValidation(
                usage: usage,
                serviceClock: serviceClock,
                serviceStartedAt: serviceStartedAt
            ) {
                traversalLease.state.position = .pendingValidation(
                    retainedCheckoutPath,
                    continuation: continuation
                )
                return .suspended
            }
            return requestValidation(
                retainedCheckoutPath,
                continuation: continuation,
                traversalLease: traversalLease,
                usage: &usage
            )
        case .notCandidate:
            traversalLease.state.position = followingPosition
            return nil
        case .failed(let detail):
            traversalLease.state.entryMetadataFailureCount += 1
            if recordFailure(
                .gitMarkerInspectionFailed(
                    candidatePath: retainedCheckoutPath,
                    detail: detail
                ),
                state: &traversalLease.state,
                usage: &usage
            ) {
                return .exhausted
            }
            traversalLease.state.position = followingPosition
            return nil
        }
    }
}
