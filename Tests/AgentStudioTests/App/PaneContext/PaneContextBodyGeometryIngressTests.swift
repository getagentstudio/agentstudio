import AgentStudioSharedComponents
import AgentStudioTestHarness
import AppKit
import Foundation
import Synchronization
import Testing

@testable import AgentStudio

@MainActor
@Suite("Pane context capture-order geometry admission", .serialized)
struct PaneContextBodyGeometryIngressTests {
    @Test("UI1 a held older actual forwarder cannot replace the latest native row width or hide disclosure")
    func lateOlderForwarderKeepsNewestGeometryAndNativeDisclosure() async throws {
        let scene = try await PaneContextInteractionTestScene.make()
        let olderArrived = HeldStep<Void>("UI1 actual older geometry forwarding delivery")
        let olderOperation = Mutex<UUID?>(nil)
        var deliveries: [Task<Void, Never>] = []
        var producerEnd: Task<Void, Never>?
        do {
            try await scene.filter(4)
            let handle = try #require(scene.host.handle)
            let target = scene.key(scene.notice)
            let value = try #require(scene.host.value)
            guard case .messages(let model, _) = value.content.body else {
                throw GeometryFailure.nativeWidthNotPrepared
            }
            let row = try #require(model.messageRows.first { $0.key == target })
            guard case .ready(let newest, _, let more?, _) = row.bodyLayout else {
                throw GeometryFailure.nativeWidthNotPrepared
            }
            try #require(scene.host.native.find(scene.detailControl(presented: false)) != nil)
            try #require(!more.label.isEmpty)
            let older = PaneContextMessageBodyGeometry(
                effectiveWidth: newest.effectiveWidth - 24, fontContext: newest.fontContext)
            try #require(older.effectiveWidth > 0)
            let owner = scene.host.bindings.owner
            let inputs = scene.host.bindings.inputs
            inputs.connectGeometry { key, opening, row, capture, operation in
                if row == .message(target), capture.geometry == older {
                    olderOperation.withLock { $0 = operation }
                    do { try await olderArrived.arrive(()) } catch { return }
                }
                await owner.receiveBodyGeometry(capture, row: row, for: key, opening: opening, operation: operation)
            }
            let first = try #require(
                inputs.forwardBodyGeometry(older, row: .message(target), for: handle.key, opening: handle.opening.epoch)
            )
            deliveries.append(first)
            producerEnd = Task {
                await first.value
                olderArrived.retire()
            }
            try await olderArrived.firstArrival()
            let second = try #require(
                inputs.forwardBodyGeometry(
                    newest, row: .message(target), for: handle.key, opening: handle.opening.epoch))
            deliveries.append(second)
            await second.value
            #expect(
                scene.host.value?.bodyMeasurements[.message(target)]?.key.effectiveWidth
                    == Double(newest.effectiveWidth))
            olderArrived.release()
            await first.value
            await producerEnd?.value
            let operation = try #require(olderOperation.withLock { $0 })
            try #require(scene.host.bridge.didFinish(.input(operation)), "The older producer must close its own input")
            let scope = PopoverOwnerProofScope(channel: .owner(.input(operation)))
            try await scene.host.bridge.facts.expectNext(in: scope, .owner(.superseded))
            try await scene.host.bridge.facts.expectNext(in: scope, .owner(.inputFinished))
            try await scene.host.rendered()
            #expect(
                scene.host.value?.bodyMeasurements[.message(target)]?.key.effectiveWidth
                    == Double(newest.effectiveWidth),
                "Late capture A must not supersede capture B, even when B equals the previously accepted geometry")
            #expect(
                scene.host.native.find(scene.detailControl(presented: false)) != nil,
                "The real disclosure must remain available for the native row's current geometry")
            try await scene.close()
        } catch {
            olderArrived.retire()
            for delivery in deliveries { delivery.cancel() }
            for delivery in deliveries { await delivery.value }
            await producerEnd?.value
            try? await scene.close()
            throw error
        }
    }

    private enum GeometryFailure: Error { case nativeWidthNotPrepared }
}
