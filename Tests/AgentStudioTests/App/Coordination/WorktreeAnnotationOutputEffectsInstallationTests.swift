import AgentStudioInfrastructure
import AgentStudioTestHarness
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

@MainActor
extension WorktreeAnnotationOutputEffectsTests {
    @Test(
        "real E1 fence prevents a prepared output effect before session actor revoke",
        arguments: [BridgePaneProductSessionRetirementReason.paneDisposal, .pageReload, .workerReplacement])
    func installationFencePreventsPreparedOutput(reason: BridgePaneProductSessionRetirementReason) async throws {
        let harness = try await outputInstallationHarness()
        let boundary = HeldStep<Void>("prepared export before effect admission")
        let writer = RecordingJSONWriter()
        let pasteboard = RejectingAnnotationPasteboard()
        let effect = WorktreeAnnotationOutputEffects(
            pasteboard: pasteboard,
            writeJSONData: { data, destination, filename in
                await writer.record(data: data, destination: destination, filename: filename)
            })
        let request = outputRequest(
            kind: .jsonFile, exactBytes: Data("{}".utf8),
            destinationPath: "/tmp/e1-fenced-export.json", productAdmission: harness.claim.productAdmission)
        let operation = Task {
            try await boundary.arrive(())
            return await effect.perform(request)
        }
        try await boundary.firstArrival()
        if reason == .paneDisposal { harness.owner.productAdmissionGate.close() }
        let ended = harness.owner.closeActiveInstallation()
        // No session-actor retirement has run; this is the real synchronous ingress handle.
        boundary.release()
        #expect(try await operation.value == .cancelled)
        #expect(await writer.writeCount == 0)
        #expect(
            await effect.perform(
                outputRequest(
                    kind: .clipboardMarkdown,
                    exactBytes: Data("closed".utf8), productAdmission: harness.claim.productAdmission)) == .cancelled)
        #expect(!pasteboard.didClearContents)
        await harness.claim.finish()
        #expect(await harness.owner.retire(reason: reason, installation: ended) == .retired)
        _ = await harness.owner.retire(reason: .paneDisposal)
    }

    @Test("picker observes E1 close once and a closed E1 never launches a panel")
    func pickerFollowsInstallationFenceExactlyOnce() async throws {
        let harness = try await outputInstallationHarness()
        let panel = HoldingJSONFolderPanel()
        let preference = InMemoryWorktreeAnnotationOutputFolderPreference(
            folderURL: URL(filePath: "/tmp/original-e1-folder"))
        let effect = WorktreeAnnotationOutputEffects(makeFolderPanel: { panel }, folderPreference: preference)
        var beginnings = panel.beginnings.makeAsyncIterator()
        let choice = Task { await effect.chooseJSONDestination(productAdmission: harness.claim.productAdmission) }
        _ = await beginnings.next()
        let ended = harness.owner.closeActiveInstallation()
        #expect(await choice.value == .cancelled)
        ended.close()
        choice.cancel()
        panel.complete(.OK)
        #expect(panel.cancelCount == 1)
        #expect(preference.folderURL.path == "/tmp/original-e1-folder")
        let neverLaunched = TestJSONFolderPanel(response: .OK, selectedURL: URL(filePath: "/tmp/never"))
        let closedEffect = WorktreeAnnotationOutputEffects(
            makeFolderPanel: { neverLaunched }, folderPreference: preference)
        #expect(
            await closedEffect.chooseJSONDestination(productAdmission: harness.claim.productAdmission) == .cancelled)
        #expect(!neverLaunched.didBegin)
        await harness.claim.finish()
        _ = await harness.owner.retire(reason: .paneDisposal)
    }

    @Test("write admitted with real E1 context finishes after fence and task cancellation")
    func begunInstallationWriteFinishes() async throws {
        let harness = try await outputInstallationHarness()
        let writing = HeldStep<Void>("admitted application writer", cancellation: .holdThroughCancellation)
        let effect = WorktreeAnnotationOutputEffects(writeJSONData: { _, destination, _ in
            try await writing.arrive(())
            return destination
        })
        let operation = Task {
            await effect.perform(
                outputRequest(
                    kind: .jsonFile, exactBytes: Data("{}".utf8),
                    destinationPath: "/tmp/e1-begun.json", productAdmission: harness.claim.productAdmission))
        }
        try await writing.firstArrival()
        _ = harness.owner.closeActiveInstallation()
        operation.cancel()
        writing.release()
        #expect(await operation.value == .succeeded(destinationPath: "/tmp/e1-begun.json"))
        await harness.claim.finish()
        _ = await harness.owner.retire(reason: .paneDisposal)
    }

    @Test("late A picker callbacks and close never cancel B's picker or accept A's folder")
    func latePickerDoesNotAffectSuccessor() async throws {
        let harness = try await outputInstallationHarness()
        let oldPanel = HoldingJSONFolderPanel()
        let originalFolder = URL(filePath: "/tmp/original-picker-a")
        let preference = InMemoryWorktreeAnnotationOutputFolderPreference(folderURL: originalFolder)
        let oldEffect = WorktreeAnnotationOutputEffects(makeFolderPanel: { oldPanel }, folderPreference: preference)
        var oldBeginnings = oldPanel.beginnings.makeAsyncIterator()
        let oldChoice = Task { await oldEffect.chooseJSONDestination(productAdmission: harness.claim.productAdmission) }
        _ = await oldBeginnings.next()
        // OK has arrived from AppKit, but its acceptance task has not yet run.
        oldPanel.complete(.OK)
        let ended = harness.owner.closeActiveInstallation()
        #expect(await oldChoice.value == .cancelled)
        #expect(preference.folderURL == originalFolder)
        let pane = try #require(harness.owner.productAdmissionGate.acquire())
        let successor = try await harness.owner.prepareCandidate(productAdmission: pane)
        #expect(
            await harness.owner.activatePreparedCandidate(successor, productAdmission: pane, replacing: ended)
                == .activated)
        let nextAdmission = try #require(successor.productAdapter.acquireAdmission())
        let nextPanel = HoldingJSONFolderPanel()
        let nextEffect = WorktreeAnnotationOutputEffects(makeFolderPanel: { nextPanel })
        var nextBeginnings = nextPanel.beginnings.makeAsyncIterator()
        let nextChoice = Task { await nextEffect.chooseJSONDestination(productAdmission: nextAdmission) }
        _ = await nextBeginnings.next()
        ended.close()
        oldPanel.complete(.OK)
        oldChoice.cancel()
        nextPanel.complete(.OK)
        #expect(await nextChoice.value == .selected(path: "/tmp/late-selection"))
        #expect(nextPanel.cancelCount == 0)
        // AppKit already returned OK; late close/cancel must not cancel that completed panel.
        #expect(oldPanel.cancelCount == 0)
        #expect(preference.folderURL == originalFolder)
        await harness.claim.finish()
        _ = await harness.owner.retire(reason: .paneDisposal)
    }

    @Test("close between logical write admission and writer launch cannot discard the admitted write")
    func closeAfterPermitStillLaunchesWriter() async throws {
        let harness = try await outputInstallationHarness()
        let writer = RecordingJSONWriter()
        let owner = harness.owner
        let effect = WorktreeAnnotationOutputEffects(
            writeJSONData: { data, destination, filename in
                await writer.record(data: data, destination: destination, filename: filename)
            }, didAdmitJSONWrite: { _ = owner.closeActiveInstallation() })
        let result = await effect.perform(
            outputRequest(
                kind: .jsonFile, exactBytes: Data("{}".utf8),
                destinationPath: "/tmp/e1-permit.json", productAdmission: harness.claim.productAdmission))
        #expect(result == .succeeded(destinationPath: "/tmp/e1-permit.json"))
        #expect(await writer.writeCount == 1)
        #expect(harness.claim.productAdmission.withValidAdmission { true } == nil)
        await harness.claim.finish()
        _ = await owner.retire(reason: .paneDisposal)
    }

}
