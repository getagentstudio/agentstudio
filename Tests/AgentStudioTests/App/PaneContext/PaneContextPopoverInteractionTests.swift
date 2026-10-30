import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("Opening-owned message interaction state", .serialized)
struct PaneContextPopoverInteractionTests {
    @Test("F2 filtering away and back retains both an original choice ID and typed reply through real Submit")
    func filterRoundTripKeepsPickAndText() async throws {
        try await withScene { scene in
            var choice = AskFormDraft()
            choice.setChoice("blue", selected: true, allowsMultiple: false)
            var text = AskFormDraft()
            text.text = "The reply survives filtering"
            let input = try scene.bindings()
            // The normal binding port isolates lifetime proof from the separately observed native picker event route.
            input.draft(scene.key(scene.choice)).wrappedValue = choice
            input.draft(scene.key(scene.text)).wrappedValue = text
            try await scene.host.bodyLayoutsPrepared()
            #expect(try scene.bindings().draft(scene.key(scene.choice)).wrappedValue.selectedChoices == ["blue"])
            #expect(try scene.bindings().draft(scene.key(scene.text)).wrappedValue.text == text.text)
            let before = try scene.submitControl(scene.choice)
            try #require(
                before.isAccessibilityEnabled(), "The input binding must enable the real form before hiding it")

            try await scene.filter(8)
            #expect(
                scene.host.native.find(
                    PaneContextPopoverControlProjection.controls().submit.identifier(
                        in: scene.key(scene.choice).controlScope)) == nil)
            try await scene.filter(0)
            try await scene.submit(scene.choice, action: 0)
            try await scene.submit(scene.text, action: 1)

            #expect(try await answer(scene, message: scene.choice) == .choices([try .init("blue")]))
            #expect(try await answer(scene, message: scene.text) == .text("The reply survives filtering"))
        }
    }

    @Test("F2 a selected read target survives filtering its group away and back")
    func filterRoundTripKeepsDetails() async throws {
        try await withScene { scene in
            try await scene.filter(8)
            let more = try #require(
                scene.host.native.find(scene.detailControl(presented: false)) as? any NSAccessibilityProtocol)
            try #require(more.accessibilityPerformPress())
            try await scene.host.bodyLayoutsPrepared()
            try #require(scene.host.native.find(scene.detailControl(presented: true)) != nil)
            try await scene.filter(1)
            #expect(scene.host.native.find(scene.detailControl(presented: true)) != nil)
            try await scene.filter(8)
            #expect(
                scene.host.native.find(scene.detailControl(presented: true)) != nil,
                "Filtering must preserve the reading target beyond the removed row's view lifetime")
        }
    }

    @Test("F2 actual native close releases retained row values and refuses old opening bindings")
    func closeClearsInputsAndFencesOldBindings() async throws {
        try await withScene { scene in
            let key = scene.key(scene.text)
            let old = try scene.bindings()
            var draft = AskFormDraft()
            draft.text = "Discard at close"
            old.draft(key).wrappedValue = draft
            old.details.wrappedValue = try scene.detailsValue(scene.text)
            try #require(scene.host.interactions.retainedRowCount == 1)
            let versions = try #require(scene.host.handle?.atom.latestAcceptedValue).interactions.versions

            try await scene.close()
            #expect(scene.host.interactions.retainedRowCount == 0, "Native retirement must clear the input storage")
            scene.host.interactions.beginOpening(2)
            let next = scene.host.interactions.bindings(versions: versions, opening: 2, currentVersions: { versions })
            #expect(next.draft(key).wrappedValue == .init())
            #expect(next.details.wrappedValue == nil)
            old.draft(key).wrappedValue = draft
            #expect(next.draft(key).wrappedValue == .init(), "An old binding cannot write into another opening")
            scene.host.interactions.close()
        }
    }

    @Test("F2 a returning incompatible typed snapshot hides stale input before any UI cleanup callback")
    func returnedIncompatibleSchemaClearsTheDraft() async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let pane = fixture.ownerId
        let id = AgentMessageId.generateUUIDv7()
        let first = message(pane: pane, id: id, form: .freeText(placeholder: "Original"))
        let changed = message(
            pane: pane, id: id,
            form: .choice(
                options: [.init(id: try .init("new-choice"), label: "New choice")], allowsMultiple: false))
        let family = PaneContextPopoverDetailFamily()
        let state = PaneContextPopoverInteractionState()
        let key = consumer(pane)
        do {
            let atom = try #require(family.materialize(for: key))
            let port = try #require(family.projectionPort(for: key))
            state.beginOpening(1)
            try await publish(snapshot(key, rows: [first], generation: 1), to: port)
            let old = inputs(state, atom: atom)
            let row = MessageRowModel.Key(sourcePaneId: pane.uuid, messageId: id.uuid)
            var draft = AskFormDraft()
            draft.text = "Old schema's input"
            old.draft(row).wrappedValue = draft
            try await publish(snapshot(key, rows: [], generation: 2), to: port)
            state.apply(try #require(atom.latestAcceptedValue).interactions.versions, opening: 1)
            try #require(state.retainedRowCount == 1)

            // Synthetic replacement at the typed snapshot boundary; no Core producer/schema is changed.
            try await publish(snapshot(key, rows: [changed], generation: 3), to: port)
            let current = inputs(state, atom: atom)
            #expect(current.draft(row).wrappedValue == .init(), "A returned incompatible form cannot expose old input")
            old.draft(row).wrappedValue = draft
            #expect(current.draft(row).wrappedValue == .init(), "A late old-schema setter is fenced")
            var replacement = AskFormDraft()
            replacement.setChoice("new-choice", selected: true, allowsMultiple: false)
            current.draft(row).wrappedValue = replacement
            state.apply(try #require(atom.latestAcceptedValue).interactions.versions, opening: 1)
            #expect(current.draft(row).wrappedValue == replacement, "Late cleanup cannot remove new-version input")
            state.close()
            await family.stop()
            try await fixture.close()
        } catch {
            state.close()
            await family.stop()
            try? await fixture.close()
            throw error
        }
    }

    @Test("F2 known settlement clears a retained draft even when it supplied no submit authority")
    func knownSettlementClearsTheDraft() async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let family = PaneContextPopoverDetailFamily()
        let state = PaneContextPopoverInteractionState()
        let pane = fixture.ownerId
        let id = AgentMessageId.generateUUIDv7()
        let request = message(pane: pane, id: id, form: .freeText(placeholder: "Reply"))
        let settled = AgentMessageDetail(
            id: request.id, sourcePaneId: pane, sender: request.sender, sentAt: request.sentAt,
            sourceOccurredAt: nil, importance: request.importance, body: request.body, why: nil, actions: [],
            shape: .ask(.question, .freeText(placeholder: "Reply"), .nonBlocking, .withdrawn))
        let key = consumer(pane)
        do {
            let atom = try #require(family.materialize(for: key))
            let port = try #require(family.projectionPort(for: key))
            state.beginOpening(1)
            try await publish(snapshot(key, rows: [request], generation: 1), to: port)
            let row = MessageRowModel.Key(sourcePaneId: pane.uuid, messageId: id.uuid)
            var draft = AskFormDraft()
            draft.text = "Not sent"
            inputs(state, atom: atom).draft(row).wrappedValue = draft
            try #require(state.retainedRowCount == 1)
            try await publish(snapshot(key, rows: [settled], generation: 2), to: port)
            #expect(inputs(state, atom: atom).draft(row).wrappedValue == .init())
            state.apply(try #require(atom.latestAcceptedValue).interactions.versions, opening: 1)
            #expect(state.retainedRowCount == 0, "An observed settlement must release the stored draft")
            state.close()
            await family.stop()
            try await fixture.close()
        } catch {
            state.close()
            await family.stop()
            try? await fixture.close()
            throw error
        }
    }

    @Test("F2 a real budget-omitted row retains its read target when it returns")
    func budgetOmissionAndReturnKeepsDetails() async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let service = fixture.composition.paneContextService
        let family = PaneContextPopoverDetailFamily()
        let state = PaneContextPopoverInteractionState()
        let pane = fixture.ownerId
        let retained = AgentMessageId.generateUUIDv7()
        let row = MessageRowModel.Key(sourcePaneId: pane.uuid, messageId: retained.uuid)
        let key = consumer(pane)
        do {
            try #require(
                await service.send(
                    .init(
                        paneId: pane, messageId: retained, sender: .pane(pane), sourceOccurredAt: nil,
                        importance: .info,
                        body: String(repeating: "R", count: AppPolicies.PaneContext.maximumBodyBytes),
                        why: String(repeating: "W", count: AppPolicies.PaneContext.maximumWhyBytes), actions: [],
                        shape: .notice))
                    == .created(retained))
            try #require(await service.markRead(messageId: retained, paneId: pane) == .done)
            let first = try await bounded(service, pane: pane)
            try #require(first.messages.contains { $0.id == retained })
            let atom = try #require(family.materialize(for: key))
            let port = try #require(family.projectionPort(for: key))
            state.beginOpening(1)
            try await publish(snapshot(key, detail: first, generation: 1), to: port)
            inputs(state, atom: atom).details.wrappedValue = try detailsValue(atom, key: row)
            var omitted: PaneContextDetail?
            // Each iteration changes real stored input. This drives the byte-budget subject; it is not an async wait.
            for _ in 0..<AppPolicies.PaneContext.maximumUnreadNotices {
                let id = AgentMessageId.generateUUIDv7()
                try #require(
                    await service.send(
                        .init(
                            paneId: pane, messageId: id, sender: .pane(pane), sourceOccurredAt: nil, importance: .info,
                            body: String(repeating: "L", count: AppPolicies.PaneContext.maximumBodyBytes),
                            why: nil, actions: [], shape: .notice)) == .created(id))
                let next = try await bounded(service, pane: pane)
                if !next.messages.contains(where: { $0.id == retained }) {
                    omitted = next
                    break
                }
            }
            let missing = try #require(
                omitted, "The retained-row omission fixture never exhausted the real byte budget")
            #expect(missing.truncation == nil, "The settled-row gap must be real even without a live continuation")
            try await publish(snapshot(key, detail: missing, generation: 2), to: port)
            state.apply(try #require(atom.latestAcceptedValue).interactions.versions, opening: 1)
            #expect(state.retainedRowCount == 1, "Bounded absence cannot retire opening-local state")
            // Return through the existing normal read budget; retiring the live filler would itself
            // fill settled-row slots and could legitimately hide the retained row under retention.
            guard case .detail(let returned) = await service.readDetail(.init(paneId: pane, page: .first)) else {
                throw ProofFailure.noPublication
            }
            try #require(returned.messages.contains { $0.id == retained })
            try await publish(snapshot(key, detail: returned, generation: 3), to: port)
            state.apply(try #require(atom.latestAcceptedValue).interactions.versions, opening: 1)
            #expect(
                inputs(state, atom: atom).details.wrappedValue?.key == .message(row),
                "The same real retained row must recover its read target after a budget omission")
            state.close()
            await family.stop()
            try await fixture.close()
        } catch {
            state.close()
            await family.stop()
            try? await fixture.close()
            throw error
        }
    }

    @Test(
        "D85b unknown-page absence preserves Details, but known prompt or binding replacement retires it",
        arguments: [false, true], [false, true])
    func providerPageAbsenceKeepsDetails(emptyReplacementBinding: Bool, restoreOriginalPage: Bool) async throws {
        let pane = PaneId.generateUUIDv7()
        let key = consumer(pane)
        let family = PaneContextPopoverDetailFamily()
        let state = PaneContextPopoverInteractionState()
        let session = SessionSummary(
            id: UUIDv7.generate(), provider: try .init("codex"), sessionRef: try .init("bounded-provider"),
            bindingGeneration: UUIDv7.generate(), status: .needsYou(.question),
            providerPrompts: [
                .init(
                    reason: .question, observedAt: .distantPast,
                    summary: (1...18).map { "Retained question line \($0)" }.joined(separator: "\n"))
            ])
        let detail = PaneContextPopoverShapingTests.detail(paneId: pane, session: session)
        do {
            let atom = try #require(family.materialize(for: key))
            let port = try #require(family.projectionPort(for: key))
            state.beginOpening(1)
            try await publish(snapshot(key, detail: detail, generation: 1), to: port)
            let value = try #require(atom.value)
            let prompt = try #require(
                value.shape?.messages.groups.flatMap(\.items).compactMap { item in
                    if case .providerPrompt(let prompt) = item { return prompt }
                    return nil
                }.first)
            let originalVersion = try #require(value.interactions.providerVersions[prompt.textBodyKey])
            let originalInputs = inputs(state, atom: atom)
            originalInputs.details.wrappedValue = .init(prompt: prompt)
            // Synthetic reader page omits this source's session metadata; no producer-retirement claim is made.
            try await publish(
                snapshot(key, detail: PaneContextPopoverShapingTests.detail(paneId: pane), generation: 2), to: port)
            let absent = try #require(atom.value)
            state.apply(
                absent.interactions.versions, providerVersions: absent.interactions.providerVersions, opening: 1)
            #expect(absent.interactions.providerVersions[prompt.textBodyKey] == originalVersion)
            #expect(inputs(state, atom: atom).details.wrappedValue?.body == prompt.body)
            if restoreOriginalPage {
                try await publish(snapshot(key, detail: detail, generation: 3), to: port)
                let returned = try #require(atom.value)
                state.apply(
                    returned.interactions.versions, providerVersions: returned.interactions.providerVersions, opening: 1
                )
                #expect(returned.interactions.providerVersions[prompt.textBodyKey] == originalVersion)
                #expect(inputs(state, atom: atom).details.wrappedValue?.body == prompt.body)
            }
            let replacement = SessionSummary(
                id: session.id, provider: session.provider, sessionRef: session.sessionRef,
                bindingGeneration: emptyReplacementBinding ? UUIDv7.generate() : session.bindingGeneration,
                status: session.status,
                providerPrompts: emptyReplacementBinding
                    ? []
                    : [
                        .init(
                            reason: .question, observedAt: .distantPast.addingTimeInterval(1),
                            summary: "A different slot occupant\n" + prompt.body)
                    ])
            try await publish(
                snapshot(
                    key, detail: PaneContextPopoverShapingTests.detail(paneId: pane, session: replacement),
                    generation: 4), to: port)
            #expect(state.retainedRowCount == 1, "Hold the cleanup callback after the new owner value is accepted")
            #expect(
                inputs(state, atom: atom).details.wrappedValue == nil,
                "The binding fences a changed slot before a UI cleanup callback can run")
            let changed = try #require(atom.value)
            #expect(changed.publication.request.inputGeneration == 4, "The replacement reaches the observed value")
            #expect(changed.interactions.providerVersions[prompt.textBodyKey] != originalVersion)
            state.apply(
                changed.interactions.versions, providerVersions: changed.interactions.providerVersions, opening: 1)
            #expect(state.retainedRowCount == 0)
            originalInputs.details.wrappedValue = .init(prompt: prompt)
            #expect(state.retainedRowCount == 0, "An old provider Details action cannot reopen after replacement")
            #expect(inputs(state, atom: atom).details.wrappedValue == nil)
            state.close()
            await family.stop()
        } catch {
            state.close()
            await family.stop()
            throw error
        }
    }

    private func detailsValue(_ atom: PaneContextPopoverDetailAtom, key: MessageRowModel.Key) throws
        -> PaneContextMessageTextValue
    {
        guard case .messages(let model, _) = atom.latestAcceptedValue?.content.body else {
            throw ProofFailure.noPublication
        }
        return .init(row: try #require(model.messageRows.first { $0.key == key }))
    }

    private func bounded(_ service: PaneContextService, pane: PaneId) async throws -> PaneContextDetail {
        guard
            case .detail(let detail) = await service.readDetail(
                .init(paneId: pane, page: .first), maximumDetailBytes: AppPolicies.PaneContext.minimumDetailBytes)
        else {
            throw ProofFailure.noPublication
        }
        return detail
    }

    private func withScene(_ operation: @MainActor (PaneContextInteractionTestScene) async throws -> Void) async throws
    {
        let scene = try await PaneContextInteractionTestScene.make()
        do {
            try await operation(scene)
            try await scene.close()
        } catch {
            try? await scene.close()
            throw error
        }
    }

    private func answer(_ scene: PaneContextInteractionTestScene, message: AgentMessageId) async throws
        -> AskAnswerValue
    {
        guard
            case .found(let detail) = await scene.fixture.composition.paneContextService.readMessage(
                source: scene.fixture.ownerId, message: message),
            case .ask(_, _, _, .answered(_, let value, _)) = detail.shape
        else {
            throw ProofFailure.noStoredAnswer
        }
        return value
    }

    private func consumer(_ pane: PaneId) -> PaneContextPopoverConsumerKey {
        .init(hostId: UUIDv7.generate(), surface: .paneMessages, paneId: pane)
    }

    private func message(pane: PaneId, id: AgentMessageId, form: AskForm) -> AgentMessageDetail {
        .init(
            id: id, sourcePaneId: pane, sender: .pane(pane), sentAt: Date(timeIntervalSince1970: 1_800_000_000),
            sourceOccurredAt: nil, importance: .attention, body: "The same request body", why: nil, actions: [],
            shape: .ask(.question, form, .nonBlocking, .open))
    }

    private func snapshot(_ key: PaneContextPopoverConsumerKey, rows: [AgentMessageDetail], generation: UInt64)
        -> PaneContextPopoverSnapshot
    {
        snapshot(
            key, detail: PaneContextPopoverShapingTests.detail(paneId: key.paneId, messages: rows),
            generation: generation)
    }

    private func snapshot(_ key: PaneContextPopoverConsumerKey, detail: PaneContextDetail, generation: UInt64)
        -> PaneContextPopoverSnapshot
    {
        .init(
            identity: .init(
                key: key, openingEpoch: 1, serviceEpoch: key.hostId, requestGeneration: generation,
                inputGeneration: generation, ageGeneration: 0, pageGeneration: 0, producer: .input(UUIDv7.generate())),
            demand: .init(content: .messages(.top), location: .pane, includingDrawers: true, screenVisibleWidth: 1400),
            capture: .init(observationGeneration: generation, serviceEpoch: key.hostId, sources: [:]),
            state: .ready(.detail(detail, selectedAsk: .none)),
            wallNow: Date(timeIntervalSince1970: 1_800_000_000), frozenWidth: 480)
    }

    private func publish(_ snapshot: PaneContextPopoverSnapshot, to port: PaneContextPopoverProjectionPort) async throws
    {
        switch await port.admit(snapshot) {
        case .published, .equal: break
        case .cancelled, .superseded: throw ProofFailure.noPublication
        }
    }

    private func inputs(_ state: PaneContextPopoverInteractionState, atom: PaneContextPopoverDetailAtom)
        -> MessagesPopoverBindings
    {
        state.bindings(
            versions: atom.latestAcceptedValue?.interactions.versions ?? [:], opening: 1,
            currentVersions: { atom.latestAcceptedValue?.interactions.versions },
            providerVersions: atom.latestAcceptedValue?.interactions.providerVersions ?? [:],
            currentProviderVersions: { atom.latestAcceptedValue?.interactions.providerVersions })
    }

    private enum ProofFailure: Error { case noStoredAnswer, noPublication }
}
