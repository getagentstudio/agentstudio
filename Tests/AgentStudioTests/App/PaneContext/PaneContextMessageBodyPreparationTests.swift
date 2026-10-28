import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("Prepared message body counts", .serialized)
struct PaneContextMessageBodyPreparationTests {
    enum ChangedInput: Sendable, CaseIterable { case body, width, font }

    struct ChoiceScenario: Sendable {
        let labels: [String]
        let multiple: Bool
        let presentation: AskChoicePresentation
        let displayed: [String]
    }
    private nonisolated static let choiceScenarios: [ChoiceScenario] = [
        .init(labels: ["éclair"], multiple: false, presentation: .radio, displayed: ["Éclair"]),
        .init(
            labels: ["iOS", "eBay", "two", "four"], multiple: false, presentation: .radio,
            displayed: ["iOS", "eBay", "Two", "Four"]),
        .init(
            labels: ["one", "two", "three", "four", "five"], multiple: false, presentation: .picker,
            displayed: ["One", "Two", "Three", "Four", "Five"]),
        .init(
            labels: [String(repeating: "a", count: 32), "b", "c", "d", "e"], multiple: false, presentation: .picker,
            displayed: ["A" + String(repeating: "a", count: 31), "B", "C", "D", "E"]),
        .init(
            labels: [String(repeating: "a", count: 33), "b", "c", "d", "e"], multiple: false, presentation: .radio,
            displayed: ["A" + String(repeating: "a", count: 32), "B", "C", "D", "E"]),
        .init(
            labels: ["a", "b", "c", "d", "e", "f"], multiple: true, presentation: .checkboxes,
            displayed: ["A", "B", "C", "D", "E", "F"]),
    ]

    @Test("F1 choice preparation keeps IDs while classifying controls and display labels", arguments: choiceScenarios)
    private func choiceDescriptorsArePrepared(_ scenario: ChoiceScenario) throws {
        let options = try scenario.labels.enumerated().map {
            try AskChoice(id: .init("original-\($0.offset)"), label: $0.element)
        }
        let prepared = PaneContextPopoverShapingKernel.form(
            .choice(options: options, allowsMultiple: scenario.multiple))
        guard case .choice(let rendered, let presentation) = prepared else {
            Issue.record("The real shaping kernel lost the choice form")
            return
        }
        #expect(presentation == scenario.presentation)
        #expect(rendered.map(\.label) == scenario.displayed)
        #expect(rendered.map(\.id) == options.map { $0.id.value })
        #expect(rendered.map(\.control.label) == scenario.displayed)
    }

    @Test(
        "F1 body, effective width and resolved font each invalidate the scalar memo", arguments: ChangedInput.allCases)
    func changedInputRemeasures(_ changed: ChangedInput) async throws {
        let key = makeKey()
        let context = EnvironmentValues().fontResolutionContext
        let performance = PaneContextPopoverPerformance(recorder: nil)
        let firstRow = row(key, characters: 700, pointSize: 11)
        let firstGeometry = PaneContextMessageBodyGeometry(effectiveWidth: 320, fontContext: context)
        let first = await measure(firstRow, geometry: firstGeometry, previous: nil, performance: performance, key: key)
        #expect(performance.textLayoutCount == 1)
        let characters = changed == .body ? 1400 : 700
        let size: CGFloat = changed == .font ? 22 : 11
        let width: CGFloat = changed == .width ? 478 : 320
        let nextRow = row(key, characters: characters, pointSize: size)
        let nextGeometry = PaneContextMessageBodyGeometry(effectiveWidth: width, fontContext: context)
        let next = await measure(
            nextRow, geometry: nextGeometry, previous: first, performance: performance, key: key)
        #expect(performance.textLayoutCount == 2, "Each changed layout input must cause one actual TextKit layout")
        let advance = ("W" as NSString).size(withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        ]).width
        let columns = Int(floor(width / advance))
        try #require(columns > 0)
        #expect(next.visualLines == Int(ceil(Double(characters) / Double(columns))) + 1)
        #expect(next.visualLines != first.visualLines)
        let repeated = await measure(
            nextRow, geometry: nextGeometry, previous: next, performance: performance, key: key)
        #expect(repeated == next)
        #expect(performance.textLayoutCount == 2, "Identical inputs reuse the completed scalar result")
    }

    @Test("F1 the owner sends geometry without a read/deadline and its age tick performs zero new layouts")
    func realOwnerAgeReusesTheCompletedLayout() async throws {
        let pane = PaneId.generateUUIDv7()
        let message = try PaneContextPopoverShapingTests.message(
            paneId: pane, shape: .notice(.unread), importance: .info, sentAt: 1_800_000_000)
        let harness = PopoverOwnerHarness(
            detail: PaneContextPopoverShapingTests.detail(paneId: pane, messages: [message]))
        let family = PaneContextPopoverDetailFamily()
        do {
            let atom = try #require(family.materialize(for: harness.key))
            let port = try #require(family.projectionPort(for: harness.key))
            let opening = try #require(
                await harness.owner.open(
                    harness.key,
                    demand: .init(
                        content: .messages(.top), location: .pane, includingDrawers: true, screenVisibleWidth: 1400),
                    projection: port))
            #expect(try await harness.completed(opening.initialExecution) == .published)
            let beforeGeometry = try await harness.timer()
            #expect(family.textLayoutCount == 0)
            let operation = UUIDv7.generate()
            await harness.owner.receiveBodyGeometry(
                .init(
                    sequence: 1,
                    geometry: .init(effectiveWidth: 320, fontContext: EnvironmentValues().fontResolutionContext)),
                row: .init(sourcePaneId: pane.uuid, messageId: message.id.uuid),
                for: harness.key, opening: opening.epoch, operation: operation)
            let scope = PopoverOwnerProofScope(channel: .owner(.input(operation)))
            try await harness.bridge.facts.expectNext(in: scope, .owner(.observed))
            try await harness.bridge.facts.expectNext(in: scope, .owner(.published))
            try await harness.bridge.facts.expectNext(in: scope, .owner(.inputFinished))
            #expect(family.textLayoutCount == 1)
            #expect(await harness.ports.requests.count == 1, "Width delivery cannot reread the service")
            #expect(
                await harness.owner.scheduledWake()?.sequence == beforeGeometry.sequence,
                "Width delivery cannot replace the useful deadline")
            harness.clock.advance(by: .seconds(60))
            await beforeGeometry.task.value
            let tick = try #require(await harness.owner.latestExecution(for: harness.key))
            try #require(tick.id != opening.initialExecution.id)
            #expect(try await harness.completed(tick) == .published)
            #expect(atom.value?.shape?.messages.messageRows.first?.age.text == "1 min ago")
            #expect(family.textLayoutCount == 1, "An age-only owner publication performs zero new TextKit layouts")
            #expect(await harness.ports.requests.count == 1)
            try await harness.finish()
            await family.stop()
        } catch {
            try? await harness.finish()
            await family.stop()
            throw error
        }
    }

    @Test("F1 a completed old-width candidate cannot replace the newer family baseline")
    func completedOldLayoutIsRejected() async throws {
        let key = makeKey()
        let epoch = UUIDv7.generate()
        let message = try PaneContextPopoverShapingTests.message(
            paneId: key.paneId, shape: .notice(.unread), importance: .info, sentAt: 1_800_000_000)
        let context = EnvironmentValues().fontResolutionContext
        let old = snapshot(
            key, epoch: epoch, message: message, geometry: .init(effectiveWidth: 320, fontContext: context),
            generation: 1)
        let current = snapshot(
            key, epoch: epoch, message: message, geometry: .init(effectiveWidth: 478, fontContext: context),
            generation: 2)
        // Finish the real pure projection before letting the newer family admission publish.
        let oldValue = await project(old)
        let oldCandidate = PaneContextPopoverProjectionCandidate(
            identity: old.identity, baselineToken: nil, disposition: .changed(oldValue))
        let family = PaneContextPopoverDetailFamily()
        do {
            let atom = try #require(family.materialize(for: key))
            let port = try #require(family.projectionPort(for: key))
            guard case .published = await port.admit(current) else { throw ProofFailure.noCurrentPublication }
            let accepted = try #require(atom.value)
            guard case .rejected = family.classify(oldCandidate) else {
                Issue.record("The completed stale width result advanced the real family's accepted baseline")
                throw ProofFailure.staleLayoutAccepted
            }
            #expect(atom.value === accepted)
            #expect(atom.isCurrent(current.identity))
            // A second equal admission proves the rejected candidate did not replace the private baseline.
            let next = snapshot(
                key, epoch: epoch, message: message, geometry: .init(effectiveWidth: 478, fontContext: context),
                generation: 3)
            guard case .equal = await port.admit(next) else { throw ProofFailure.staleLayoutAccepted }
            #expect(family.textLayoutCount == 1)
            await family.stop()
        } catch {
            await family.stop()
            throw error
        }
    }

    private func makeKey() -> PaneContextPopoverConsumerKey {
        .init(hostId: UUIDv7.generate(), surface: .paneMessages, paneId: .generateUUIDv7())
    }

    private func row(_ key: PaneContextPopoverConsumerKey, characters: Int, pointSize: CGFloat) -> MessageRowModel {
        .init(
            id: UUIDv7.generate(), sourcePaneId: key.paneId.uuid, sourceLabel: nil, sender: .pane(key.paneId.uuid),
            sentAt: .distantPast, sourceOccurredAt: nil, body: String(repeating: "W", count: characters) + "\nEnd",
            bodyFont: .monospaced(pointSize: pointSize), why: nil, importance: .info, shape: .notice(.unread),
            actions: [], kind: .notice(.info), kindIcon: .system("info.circle"), age: .init(text: "Now"),
            isDimmed: false, settledLabel: nil, availability: .noticeActions)
    }

    private func snapshot(
        _ key: PaneContextPopoverConsumerKey, epoch: UUID, message: AgentMessageDetail,
        geometry: PaneContextMessageBodyGeometry, generation: UInt64
    ) -> PaneContextPopoverSnapshot {
        .init(
            identity: .init(
                key: key, openingEpoch: 1, serviceEpoch: epoch, requestGeneration: generation,
                inputGeneration: 0, ageGeneration: 0, pageGeneration: 0, producer: .input(UUIDv7.generate()),
                layoutGeneration: generation),
            demand: .init(content: .messages(.top), location: .pane, includingDrawers: true, screenVisibleWidth: 1400),
            capture: .init(observationGeneration: 1, serviceEpoch: epoch, sources: [:]),
            state: .ready(
                .detail(
                    PaneContextPopoverShapingTests.detail(paneId: key.paneId, messages: [message]), selectedAsk: .none)),
            wallNow: Date(timeIntervalSince1970: 1_800_000_000), frozenWidth: 480,
            bodyGeometry: [.init(sourcePaneId: key.paneId.uuid, messageId: message.id.uuid): geometry])
    }

    @concurrent nonisolated private func measure(
        _ row: MessageRowModel, geometry: PaneContextMessageBodyGeometry,
        previous: PaneContextMessageBodyMeasurement?, performance: PaneContextPopoverPerformance,
        key: PaneContextPopoverConsumerKey
    ) async -> PaneContextMessageBodyMeasurement {
        PaneContextMessageBodyMeasurement.prepare(
            row: row, geometry: geometry, previous: previous,
            performance: performance, consumer: key)
    }

    @concurrent nonisolated private func project(_ snapshot: PaneContextPopoverSnapshot) async -> PopoverDetail {
        PaneContextPopoverDetailProjection.project(snapshot)
    }

    private enum ProofFailure: Error { case noCurrentPublication, staleLayoutAccepted }
}
