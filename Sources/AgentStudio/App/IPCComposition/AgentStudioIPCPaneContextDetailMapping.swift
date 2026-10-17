import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioProgrammaticControl
import Foundation

extension PaneContextIPCMapping {
    static func page(_ value: IPCPaneContextReadPage) -> PaneContextReadPage {
        switch value {
        case .first: .first
        case .more(let source, let after):
            .more(
                source: PaneId(existingUUID: source),
                after: LiveMessageCursor(rank: after.rank, position: after.position))
        case .moreSources(let after): .moreSources(after: PaneId(existingUUID: after))
        }
    }

    static func detail(_ result: PaneContextReadResult) throws -> IPCPaneContextGetResult {
        switch result {
        case .paneGone: throw AppIPCPaneContextError(reason: .paneGone)
        case .sourceNotInView: throw AppIPCPaneContextError(reason: .sourceNotInView)
        case .unavailable: throw AppIPCPaneContextError(reason: .unavailable)
        case .detail(let value):
            try IPCPaneNumericCoding.requireSafe(value.revision.value)
            return IPCPaneContextGetResult(
                paneId: value.paneId.uuid, revision: value.revision.value, agentTitle: value.agentTitle,
                agentLine: value.agentLine.map(line), session: value.session.map(session),
                messages: value.messages.map(message),
                drawerMessages: value.drawerMessages.map { group in
                    IPCPaneDrawerMessageGroup(
                        sourcePaneId: group.sourcePaneId.uuid, messages: group.messages.map(message))
                },
                links: .unknown, pullRequests: pullRequests(value.pullRequests),
                truncation: try value.truncation.map(truncation))
        }
    }

    static func truncation(_ value: DetailTruncation) throws -> IPCPaneDetailTruncation {
        try IPCPaneNumericCoding.requireSafe(value.remainingLiveSources)
        let omitted = try value.omitted.map { source in
            try IPCPaneNumericCoding.requireSafe(source.next.position)
            try IPCPaneNumericCoding.requireSafe(source.next.rank)
            try IPCPaneNumericCoding.requireSafe(source.openAsks)
            try IPCPaneNumericCoding.requireSafe(source.unreadNotices)
            return IPCPaneOmittedLiveMessages(
                source: source.source.uuid, openAsks: source.openAsks, unreadNotices: source.unreadNotices,
                next: IPCPaneLiveMessageCursor(rank: source.next.rank, position: source.next.position))
        }
        return IPCPaneDetailTruncation(
            omitted: omitted, remainingLiveSources: value.remainingLiveSources,
            nextSourcesAfter: value.nextSourcesAfter?.uuid)
    }

    static func sender(_ value: AgentMessageSender) -> IPCPaneMessageSender {
        switch value {
        case .pane(let pane): .pane(paneId: pane.uuid)
        case .session(let provider, let sessionRef, let generation):
            .session(provider: provider.value, conversationId: sessionRef.value, bindingGeneration: generation)
        }
    }

    static func message(_ value: AgentMessageDetail) -> IPCPaneMessageDetail {
        let shape: IPCPaneMessageShape
        switch value.shape {
        case .notice(let value): shape = .notice(state: noticeState(value))
        case .ask(let why, let askForm, let askWaiting, let askState):
            shape = .ask(reason: reason(why), form: form(askForm), waiting: waiting(askWaiting), state: state(askState))
        }
        return IPCPaneMessageDetail(
            id: value.id.uuid, sourcePaneId: value.sourcePaneId.uuid, sender: sender(value.sender),
            sentAt: value.sentAt, sourceOccurredAt: value.sourceOccurredAt, importance: importance(value.importance),
            body: value.body, why: value.why, actions: value.actions.map(action), shape: shape)
    }

    static func importance(_ value: MessageImportance) -> IPCPaneMessageImportance {
        switch value {
        case .info: .info
        case .attention: .attention
        case .done: .done
        case .failure: .failure
        }
    }

    static func action(_ value: MessageAction) -> IPCPaneMessageAction {
        switch value {
        case .openFile(let path, let line): .openFile(path: path, line: line)
        case .goToPane(let pane): .goToPane(paneId: pane.uuid)
        case .openPullRequest(let identity):
            .openPullRequest(
                identity: IPCPanePullRequestIdentity(
                    host: identity.host, owner: identity.owner, repository: identity.repository, number: identity.number
                ))
        }
    }

    static func form(_ value: AskForm) -> IPCPaneAskForm {
        switch value {
        case .choice(let options, let multiple):
            return .choice(
                options: options.map { IPCPaneAskChoice(id: $0.id.value, label: $0.label) }, allowsMultiple: multiple)
        case .freeText(let placeholder): return .freeText(placeholder: placeholder)
        case .elicitation(let schema):
            return .elicitation(
                schema: IPCPaneElicitationSchema(
                    properties: schema.properties.map { property in
                        IPCPaneElicitationProperty(
                            name: property.name, title: property.title, description: property.description,
                            type: propertyType(property.type))
                    }, required: schema.required))
        }
    }

    static func propertyType(_ value: ElicitationPropertyType) -> IPCPaneElicitationPropertyType {
        switch value {
        case .string(let constraints):
            return .string(
                choices: constraints.choices, minLength: constraints.minLength, maxLength: constraints.maxLength,
                format: constraints.format.map(stringFormat))
        case .number(let constraints): return .number(minimum: constraints.minimum, maximum: constraints.maximum)
        case .integer(let constraints): return .integer(minimum: constraints.minimum, maximum: constraints.maximum)
        case .boolean: return .boolean
        }
    }

    static func stringFormat(_ value: ElicitationStringFormat) -> IPCPaneElicitationStringFormat {
        switch value {
        case .email: .email
        case .uri: .uri
        case .date: .date
        }
    }

    static func waiting(_ value: AskWaiting) -> IPCPaneAskWaiting {
        switch value {
        case .nonBlocking: .nonBlocking
        case .blocking(let deadline): .blocking(deadline: deadline)
        }
    }

    static func noticeState(_ value: NoticeState) -> IPCPaneNoticeState {
        switch value {
        case .unread: .unread
        case .read: .read
        case .dismissed: .dismissed
        case .withdrawn: .withdrawn
        }
    }

    static func receipt(_ value: AnswerReceipt) -> IPCPaneAnswerReceipt {
        switch value {
        case .notYetConfirmed: .notYetConfirmed
        case .confirmed(let at): .confirmed(at: at)
        case .unconfirmed: .unconfirmed
        }
    }

    static func state(_ value: AskState) -> IPCPaneAskState {
        switch value {
        case .open: .open
        case .answered(_, let value, let receiptValue):
            .answered(by: .localUser, value: answer(value), receipt: receipt(receiptValue))
        case .handedBack: .handedBack
        case .dismissed: .dismissed
        case .expired: .expired
        case .withdrawn: .withdrawn
        case .stale: .stale
        }
    }

    static func terminal(_ value: AskOrNoticeTerminal) -> IPCPaneTerminalState {
        switch value {
        case .ask(let value):
            let state: IPCPaneAskTerminalState
            switch value {
            case .answered(_, let value, let receiptValue):
                state = .answered(by: .localUser, value: answer(value), receipt: receipt(receiptValue))
            case .handedBack: state = .handedBack
            case .dismissed: state = .dismissed
            case .expired: state = .expired
            case .withdrawn: state = .withdrawn
            case .stale: state = .stale
            }
            return .ask(state: state)
        case .notice(let value):
            switch value {
            case .dismissed: return .notice(state: .dismissed)
            case .withdrawn: return .notice(state: .withdrawn)
            }
        }
    }

    static func line(_ value: AgentLineDetail) -> IPCPaneAgentLineDetail {
        IPCPaneAgentLineDetail(
            summary: value.summary, work: work(value.work), detail: value.detail,
            refs: value.refs.map(action), lifetime: lifetime(value.lifetime), writer: sender(value.writer),
            updatedAt: value.updatedAt, stale: value.stale)
    }

    static func work(_ value: AgentLineWork) -> IPCPaneAgentLineWork {
        switch value {
        case .working(let progress):
            switch progress {
            case .indeterminate: return .working(progress: .indeterminate)
            case .step(let current, let total): return .working(progress: .step(current: current, total: total))
            }
        case .monitoring(let target): return .monitoring(target: target)
        case .blockedOnYou(let action): return .blockedOnYou(action: action)
        case .done: return .done
        case .failed(let summary): return .failed(summary: summary)
        }
    }

    static func lifetime(_ value: AgentLineLifetime) -> IPCPaneAgentLineLifetime {
        switch value {
        case .untilReplaced: .untilReplaced
        case .expires(let at): .expires(at: at)
        }
    }

    static func session(_ value: SessionSummary) -> IPCPaneSessionSummary {
        IPCPaneSessionSummary(
            id: value.id, provider: value.provider.value, conversationId: value.sessionRef.value,
            bindingGeneration: value.bindingGeneration, status: status(value.status),
            providerPrompts: value.providerPrompts.map { prompt in
                IPCPaneProviderPromptSummary(
                    reason: reason(prompt.reason), observedAt: prompt.observedAt, summary: prompt.summary)
            }, omittedPromptCount: value.omittedPromptCount)
    }

    static func status(_ value: AgentSessionStatus) -> IPCPaneSessionStatus {
        switch value {
        case .needsYou(let value): return .needsYou(reason: reason(value))
        case .failed(let value): return .failed(category: value.category)
        case .unknown: return .unknown
        case .working(let value):
            switch value {
            case .active: return .working(state: .active)
            case .monitoring: return .working(state: .monitoring)
            }
        case .idle(let value):
            switch value {
            case .done: return .idle(state: .done)
            case .ready: return .idle(state: .ready)
            case .interrupted: return .idle(state: .interrupted)
            case .ended: return .idle(state: .ended)
            }
        }
    }

    static func pullRequests(_ value: PullRequestSummaryDetail) -> IPCPanePullRequestSummaryDetail {
        switch value {
        case .notApplicable: return .notApplicable
        case .summary(let summary):
            let state: IPCPanePullRequestSummaryState
            switch summary.state {
            case .needsAttention(let count): state = .needsAttention(count: count)
            case .running: state = .running
            case .allGood: state = .allGood
            case .noInfo: state = .noInfo
            }
            return .summary(
                value: IPCPanePullRequestSummary(
                    state: state,
                    members: summary.members.map { member in
                        switch member {
                        case .noPullRequest(let id): .noPullRequest(worktreeId: id)
                        case .unknown(let id): .unknown(worktreeId: id)
                        case .pullRequest(let id, let number, let checks, let review):
                            .pullRequest(
                                worktreeId: id, number: number, checks: checkStatus(checks),
                                review: reviewStatus(review))
                        }
                    }))
        }
    }

    static func checkStatus(_ value: PullRequestCheckStatus) -> IPCPanePullRequestCheckStatus {
        switch value {
        case .passed: .passed
        case .running: .running
        case .failed: .failed
        case .unknown: .unknown
        }
    }

    static func reviewStatus(_ value: PullRequestReviewStatus) -> IPCPanePullRequestReviewStatus {
        switch value {
        case .approved: .approved
        case .changesRequested: .changesRequested
        case .reviewRequired: .reviewRequired
        case .unknown: .unknown
        }
    }
}
