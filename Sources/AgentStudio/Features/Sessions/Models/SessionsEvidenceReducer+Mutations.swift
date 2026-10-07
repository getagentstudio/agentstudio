import AgentStudioInfrastructure
import Foundation

extension SessionsEvidenceReducer {
    enum BindingDecision: Sendable {
        case ignored
        case accepted(
            binding: SessionsBindingRecord,
            disposition: SessionsHookDisposition,
            supersededBinding: SessionsBindingRecord?
        )
    }

    /// Rev 36's rows are evaluated in precedence order, inside the FIFO commit.
    static func decideBinding(
        for hook: SessionsHookAdmission,
        context: SessionsRepositoryContext,
        confirmedLiveMain: Bool
    ) -> BindingDecision {
        let ownBindings = context.bindings.filter { $0.paneId == hook.paneId }
        let ownMatching = ownBindings.first {
            $0.providerIdentifier == hook.providerIdentifier && $0.providerConversationId == hook.sessionId
        }
        let liveMain = ownBindings.first { $0.status == .active }

        if let liveMain, liveMain.bindingGenerationId == ownMatching?.bindingGenerationId {
            return .accepted(binding: liveMain, disposition: .applied, supersededBinding: nil)
        }
        if let ownMatching, ownMatching.status == .ended, hook.eventName != .sessionStart {
            return .accepted(binding: ownMatching, disposition: .recordedOnly, supersededBinding: nil)
        }
        if hook.eventName == .sessionStart, liveMain == nil || !confirmedLiveMain {
            return .accepted(
                binding: makeBinding(hook, conversationId: ownMatching?.conversationId, retained: ownMatching),
                disposition: .bound,
                supersededBinding: liveMain)
        }
        if let liveMain, !confirmedLiveMain {
            return .accepted(
                binding: makeBinding(hook, conversationId: context.matchingConversation?.id),
                disposition: .bound,
                supersededBinding: liveMain)
        }
        if liveMain != nil {
            return .ignored
        }
        return .accepted(
            binding: makeBinding(hook, conversationId: context.matchingConversation?.id),
            disposition: .bound,
            supersededBinding: nil)
    }

    static func reduceHook(_ hook: SessionsHookAdmission, context: SessionsRepositoryContext)
        -> (SessionsRepositoryReduction?, BindingDecision)
    {
        reduceHook(hook, context: context, confirmedLiveMain: true)
    }

    static func reduceHook(
        _ hook: SessionsHookAdmission,
        context: SessionsRepositoryContext,
        confirmedLiveMain: Bool
    ) -> (SessionsRepositoryReduction?, BindingDecision) {
        let decision = decideBinding(for: hook, context: context, confirmedLiveMain: confirmedLiveMain)
        guard case .accepted(let binding, let disposition, let supersededBinding) = decision
        else { return (nil, decision) }
        let effect: SessionsEvidenceStatusEffect = disposition == .recordedOnly ? .recordedOnly : .applied
        var committedBinding = binding
        var conversations: [SessionsConversationRecord] = []
        var bindingChanges: [SessionsBindingRecord] = []
        var sourceChanges: [SessionsSourceRecord] = []
        if let supersededBinding {
            bindingChanges.append(replacing(supersededBinding, status: .ended, endedAt: hook.admittedAt))
            if let supersededSource = context.sources.first(where: {
                $0.bindingGenerationId == supersededBinding.bindingGenerationId
            }) {
                sourceChanges.append(replacing(supersededSource, status: .ended, endedAt: hook.admittedAt))
            }
        }
        if disposition == .bound {
            conversations = [
                .init(
                    id: binding.conversationId, providerIdentifier: hook.providerIdentifier,
                    providerConversationId: hook.sessionId,
                    createdAt: context.matchingConversation?.createdAt ?? hook.admittedAt,
                    lastReportedAt: hook.admittedAt)
            ]
            bindingChanges.append(binding)
        }

        var source = context.sources.first(where: {
            $0.bindingGenerationId == binding.bindingGenerationId
        })
        if disposition == .bound {
            if let retainedSource = source {
                source = replacing(retainedSource, status: .active, endedAt: nil, providerVersion: hook.providerVersion)
            } else {
                source = .init(
                    id: binding.bindingGenerationId, bindingGenerationId: binding.bindingGenerationId,
                    sourceIdentifier: hook.sessionId, sourceGenerationId: binding.sourceGenerationId,
                    providerIdentifier: hook.providerIdentifier, providerVersion: hook.providerVersion,
                    providerMode: "", qualification: "qualified", status: .active, lastCursor: nil,
                    startedAt: hook.admittedAt, endedAt: nil)
            }
        } else if let retainedSource = source {
            source = replacing(
                retainedSource, status: retainedSource.status,
                endedAt: retainedSource.endedAt, providerVersion: hook.providerVersion)
        }
        if hook.eventName == .sessionEnd, effect == .applied {
            committedBinding = replacing(binding, status: .ended, endedAt: hook.admittedAt)
            bindingChanges = [committedBinding]
            if let activeSource = source {
                source = replacing(activeSource, status: .ended, endedAt: hook.admittedAt)
            }
        }
        let evidence = SessionsEvidenceRecord(
            recordId: hook.recordId, conversationId: binding.conversationId,
            bindingGenerationId: binding.bindingGenerationId, sourceGenerationId: binding.sourceGenerationId,
            turnId: hook.turnId, subject: hook.subject, kind: hook.kind, origin: .reported, statusEffect: effect,
            occurredAt: hook.admittedAt, providerSignal: hook.signal)
        if let source { sourceChanges.append(source) }
        return (
            .init(
                conversationChanges: conversations, bindingChanges: bindingChanges,
                sourceChanges: sourceChanges, evidenceChanges: [evidence], outcome: disposition),
            decision
        )
    }

    private static func makeBinding(
        _ hook: SessionsHookAdmission, conversationId: UUID?, retained: SessionsBindingRecord? = nil
    ) -> SessionsBindingRecord {
        if let retained { return replacing(retained, status: .active, endedAt: nil) }
        let identity = UUIDv7.generate()
        return .init(
            bindingGenerationId: identity, paneId: hook.paneId, conversationId: conversationId ?? UUIDv7.generate(),
            providerIdentifier: hook.providerIdentifier, providerConversationId: hook.sessionId,
            sourceGenerationId: identity, transitionOccurrenceId: hook.recordId, origin: .reported, status: .active,
            startedAt: hook.admittedAt, endedAt: nil, resumeHint: hook.resumeHint, ownerPaneId: hook.ownerPaneId)
    }
}
