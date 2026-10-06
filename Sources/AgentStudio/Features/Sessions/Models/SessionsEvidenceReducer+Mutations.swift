import AgentStudioInfrastructure
import Foundation

extension SessionsEvidenceReducer {
    struct BindingDecision: Sendable {
        let binding: SessionsBindingRecord
        let replaced: [SessionsBindingRecord]
        let disposition: SessionsHookDisposition
    }

    /// Rev 36's rows are evaluated in precedence order, inside the FIFO commit.
    static func decideBinding(for hook: SessionsHookAdmission, context: SessionsRepositoryContext) -> BindingDecision {
        let matching = context.bindings.filter {
            $0.providerIdentifier == hook.providerIdentifier && $0.providerConversationId == hook.sessionId
        }
        let ownActive = matching.first { $0.paneId == hook.paneId && $0.status == .active }
        let elsewhereActive = matching.first { $0.paneId != hook.paneId && $0.status == .active }
        let ownOther = context.bindings.filter {
            $0.paneId == hook.paneId && $0.status == .active && $0.bindingGenerationId != ownActive?.bindingGenerationId
        }
        if hook.eventName == .sessionStart {
            let elsewhereActiveBindings = matching.filter { $0.paneId != hook.paneId && $0.status == .active }
            if let ownActive {
                return .init(binding: ownActive, replaced: elsewhereActiveBindings, disposition: .applied)
            }
            return .init(
                binding: makeBinding(
                    hook, conversationId: context.matchingConversation?.id,
                    retained: matching.first { $0.paneId == hook.paneId }),
                replaced: ownOther + elsewhereActiveBindings, disposition: .bound)
        }
        if let ownActive {
            return .init(binding: ownActive, replaced: [], disposition: .applied)
        }
        if matching.isEmpty {
            return .init(
                binding: makeBinding(hook, conversationId: context.matchingConversation?.id),
                replaced: ownOther, disposition: .bound)
        }
        // A delayed fact may refer to the active binding on another pane or to
        // an ended binding. Neither decision can mutate a pane's status.
        let retained = elsewhereActive ?? matching[0]
        return .init(binding: retained, replaced: [], disposition: .recordedOnly)
    }

    static func reduceHook(_ hook: SessionsHookAdmission, context: SessionsRepositoryContext)
        -> (SessionsRepositoryReduction, BindingDecision)
    {
        let decision = decideBinding(for: hook, context: context)
        let effect: SessionsEvidenceStatusEffect = decision.disposition == .recordedOnly ? .recordedOnly : .applied
        var bindings = decision.replaced.map { replacing($0, status: .ended, endedAt: hook.admittedAt) }
        var sources = context.sources.filter { source in
            decision.replaced.contains { $0.bindingGenerationId == source.bindingGenerationId }
        }.map { replacing($0, status: .ended, endedAt: hook.admittedAt) }
        let binding = decision.binding
        var conversations: [SessionsConversationRecord] = []
        if decision.disposition == .bound {
            conversations = [
                .init(
                    id: binding.conversationId, providerIdentifier: hook.providerIdentifier,
                    providerConversationId: hook.sessionId,
                    createdAt: context.matchingConversation?.createdAt ?? hook.admittedAt,
                    lastReportedAt: hook.admittedAt)
            ]
            bindings.append(binding)
            if let retainedSource = context.sources.first(where: {
                $0.bindingGenerationId == binding.bindingGenerationId
            }) {
                sources.append(
                    replacing(retainedSource, status: .active, endedAt: nil, providerVersion: hook.providerVersion))
            } else {
                sources.append(
                    .init(
                        id: binding.bindingGenerationId, bindingGenerationId: binding.bindingGenerationId,
                        sourceIdentifier: hook.sessionId, sourceGenerationId: binding.sourceGenerationId,
                        providerIdentifier: hook.providerIdentifier, providerVersion: hook.providerVersion,
                        providerMode: "", qualification: "qualified", status: .active, lastCursor: nil,
                        startedAt: hook.admittedAt, endedAt: nil))
            }
        }
        if decision.disposition != .bound,
            let retainedSource = context.sources.first(where: { $0.bindingGenerationId == binding.bindingGenerationId })
        {
            sources.append(
                replacing(
                    retainedSource, status: retainedSource.status,
                    endedAt: retainedSource.endedAt, providerVersion: hook.providerVersion))
        }
        if hook.eventName == .sessionEnd, effect == .applied {
            bindings.append(replacing(binding, status: .ended, endedAt: hook.admittedAt))
            if let source = sources.last(where: { $0.bindingGenerationId == binding.bindingGenerationId })
                ?? context.sources.first(where: { $0.bindingGenerationId == binding.bindingGenerationId })
            {
                sources.append(replacing(source, status: .ended, endedAt: hook.admittedAt))
            }
        }
        let evidence = SessionsEvidenceRecord(
            recordId: hook.recordId, conversationId: binding.conversationId,
            bindingGenerationId: binding.bindingGenerationId, sourceGenerationId: binding.sourceGenerationId,
            turnId: hook.turnId, subject: hook.subject, kind: hook.kind, origin: .reported, statusEffect: effect,
            occurredAt: hook.admittedAt, providerSignal: hook.signal)
        return (
            .init(
                conversationChanges: conversations, bindingChanges: bindings, sourceChanges: sources,
                evidenceChanges: [evidence], outcome: decision.disposition), decision
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
