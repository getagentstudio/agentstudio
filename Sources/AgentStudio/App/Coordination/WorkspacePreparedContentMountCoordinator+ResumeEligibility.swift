import AgentStudioCore
import AgentStudioTerminal
import Foundation

typealias TerminalRestoreClassificationSink = @Sendable (PaneId, TerminalRestoreKind, ZmxSessionInventory) async -> Void
typealias TerminalRestoreClassifier =
    @Sendable ([TerminalActivationDescriptor], TerminalRestoreClassificationSink) async -> Void
typealias ColdResumePlanResolution =
    @Sendable (PaneId, TerminalColdRestorePlan, ZmxSessionInventory) async -> TerminalColdRestorePlan

extension WorkspacePreparedContentMountCoordinator {
    @concurrent nonisolated static func classifyAndReleaseTerminals(
        entries: [TerminalActivationDescriptor], scheduler: TerminalActivationScheduler,
        classify: TerminalRestoreClassifier?,
        resolveKinds:
            @escaping @MainActor @Sendable ([TerminalActivationDescriptor]) async -> [PaneId: TerminalRestoreKind],
        resolveResume: ColdResumePlanResolution?
    ) async {
        guard let classify else {
            let kinds = await resolveKinds(entries)
            await scheduler.enqueueRestoreKinds(kinds, for: entries.map(\.paneID))
            await withTaskGroup(of: Void.self) { group in
                for entry in entries {
                    if case .cold(let plan) = kinds[entry.paneID] {
                        group.addTask {
                            await scheduler.releaseAwaitingResumeReadiness([entry.paneID: plan]) { paneID, original in
                                await resolveResume?(paneID, original, .unavailable(.unparsable)) ?? original
                            }
                        }
                    }
                }
            }
            return
        }
        let (stream, continuation) = AsyncStream.makeStream(
            of: (PaneId, TerminalRestoreKind, ZmxSessionInventory).self, bufferingPolicy: .unbounded)
        async let producer: Void = publishClassifications(
            entries, into: continuation, classify: classify)
        await withTaskGroup(of: Void.self) { group in
            var classified: Set<PaneId> = []
            for await (paneID, kind, inventory) in stream {
                guard classified.insert(paneID).inserted else { continue }
                await scheduler.enqueueRestoreKind(kind, for: paneID)
                if case .cold(let plan) = kind {
                    group.addTask {
                        await scheduler.releaseAwaitingResumeReadiness([paneID: plan]) { paneID, original in
                            await resolveResume?(paneID, original, inventory) ?? original
                        }
                    }
                }
            }
            let unclassified = entries.filter { !classified.contains($0.paneID) }.map(\.paneID)
            await scheduler.enqueueRestoreKinds([:], for: unclassified)
        }
        await producer
    }

    @concurrent nonisolated private static func publishClassifications(
        _ entries: [TerminalActivationDescriptor],
        into continuation: AsyncStream<(PaneId, TerminalRestoreKind, ZmxSessionInventory)>.Continuation,
        classify: TerminalRestoreClassifier
    ) async {
        defer { continuation.finish() }
        await classify(entries) { paneID, kind, inventory in continuation.yield((paneID, kind, inventory)) }
    }
}
