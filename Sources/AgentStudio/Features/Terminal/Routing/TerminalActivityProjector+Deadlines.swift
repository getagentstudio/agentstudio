import Foundation

// Deadline registration, cancellation and retirement stay on the projector actor.
extension TerminalActivityProjector {
    func scheduleUnseenClose(for paneID: UUID, state: PaneState) {
        cancelUnseenWindow(for: paneID, disposition: .superseded)
        guard let window = state.unseenWindow ?? state.activityWindow else { return }
        let deadlineClock = self.deadlineClock
        let recordsFacts = factSink != nil
        let duration = unseenQuietDuration
        let retirementTask = unseenRetirementTasks.removeValue(forKey: paneID)
        let closeTarget = ActivityWindowCloseTarget(
            windowID: window.id,
            surfaceID: window.surfaceID,
            paneID: window.paneID,
            generation: window.generation,
            unseenWindow: state.unseenWindow,
            activityWindow: state.activityWindow
        )
        let scope = TerminalActivityDeadlineScope(
            paneID: paneID, windowID: closeTarget.windowID, kind: .unseen,
            generation: closeTarget.generation)
        if factSink != nil { unseenDeadlineScopes[paneID] = scope }
        unseenCloseTasks[paneID] = Task { [weak self] in
            await retirementTask?.value
            guard !Task.isCancelled else { return }
            // This is the old relative sleep's start, after predecessor retirement.
            // Capture before notifying observers so an early clock advance is safe.
            let deadline = deadlineClock.now + duration
            if recordsFacts {
                guard await self?.registerDeadline(scope, at: deadline) == true else { return }
            }
            do {
                try await deadlineClock.sleep(until: deadline)
            } catch {
                if recordsFacts { await self?.closeDeadline(scope, as: .cancelled) }
                return
            }
            let fired = await self?.closeUnseenWindow(target: closeTarget) ?? false
            if recordsFacts { await self?.closeDeadline(scope, as: fired ? .fired : .superseded) }
        }
    }

    func scheduleAgentClose(for paneID: UUID, state: PaneState) {
        cancelAgentCandidate(for: paneID, disposition: .superseded)
        guard let candidate = state.agentCandidate else { return }
        let deadlineClock = self.deadlineClock
        let recordsFacts = factSink != nil
        let duration = agentSettledQuietDuration
        let retirementTask = agentRetirementTasks.removeValue(forKey: paneID)
        let closeTarget = ActivityWindowCloseTarget(
            windowID: candidate.id,
            surfaceID: candidate.surfaceID,
            paneID: candidate.paneID,
            generation: candidate.generation
        )
        let scope = TerminalActivityDeadlineScope(
            paneID: paneID, windowID: closeTarget.windowID, kind: .agentSettled,
            generation: closeTarget.generation)
        if factSink != nil { agentDeadlineScopes[paneID] = scope }
        agentCloseTasks[paneID] = Task { [weak self] in
            await retirementTask?.value
            guard !Task.isCancelled else { return }
            // This is the old relative sleep's start, after predecessor retirement.
            // Capture before notifying observers so an early clock advance is safe.
            let deadline = deadlineClock.now + duration
            if recordsFacts {
                guard await self?.registerDeadline(scope, at: deadline) == true else { return }
            }
            do {
                try await deadlineClock.sleep(until: deadline)
            } catch {
                if recordsFacts { await self?.closeDeadline(scope, as: .cancelled) }
                return
            }
            let fired = await self?.closeAgentCandidate(target: closeTarget) ?? false
            if recordsFacts { await self?.closeDeadline(scope, as: fired ? .fired : .superseded) }
        }
    }

    func cancelTimers(for paneID: UUID) {
        cancelUnseenWindow(for: paneID)
        cancelAgentCandidate(for: paneID)
    }

    func cancelUnseenWindow(for paneID: UUID, disposition: TerminalActivityDeadlineDisposition = .cancelled) {
        guard let closeTask = unseenCloseTasks.removeValue(forKey: paneID) else { return }
        if let scope = unseenDeadlineScopes.removeValue(forKey: paneID) {
            closeDeadline(scope, as: disposition)
        }
        closeTask.cancel()
        let precedingRetirementTask = unseenRetirementTasks[paneID]
        unseenRetirementTasks[paneID] = Task {
            await precedingRetirementTask?.value
            await closeTask.value
        }
    }

    func cancelAgentCandidate(for paneID: UUID, disposition: TerminalActivityDeadlineDisposition = .cancelled) {
        guard let closeTask = agentCloseTasks.removeValue(forKey: paneID) else { return }
        if let scope = agentDeadlineScopes.removeValue(forKey: paneID) {
            closeDeadline(scope, as: disposition)
        }
        closeTask.cancel()
        let precedingRetirementTask = agentRetirementTasks[paneID]
        agentRetirementTasks[paneID] = Task {
            await precedingRetirementTask?.value
            await closeTask.value
        }
    }

    func registerDeadline(_ scope: TerminalActivityDeadlineScope, at deadline: Duration) -> Bool {
        guard let factSink else { return true }
        let current = scope.kind == .unseen ? unseenDeadlineScopes[scope.paneID] : agentDeadlineScopes[scope.paneID]
        guard !Task.isCancelled, current == scope else { return false }
        openDeadlineScopes.insert(scope)
        factSink(scope, .deadlineRegistered(scope.kind, deadline: deadline))
        return true
    }

    func closeDeadline(_ scope: TerminalActivityDeadlineScope, as disposition: TerminalActivityDeadlineDisposition) {
        guard let factSink, openDeadlineScopes.remove(scope) != nil else { return }
        if unseenDeadlineScopes[scope.paneID] == scope { unseenDeadlineScopes[scope.paneID] = nil }
        if agentDeadlineScopes[scope.paneID] == scope { agentDeadlineScopes[scope.paneID] = nil }
        factSink(scope, .deadlineDisposition(scope.kind, disposition))
    }

    func closeAllDeadlineFacts() {
        for scope in Array(openDeadlineScopes) { closeDeadline(scope, as: .cancelled) }
        unseenDeadlineScopes.removeAll()
        agentDeadlineScopes.removeAll()
    }
}
