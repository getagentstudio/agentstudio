import AgentStudioCore
import Foundation

extension BridgePaneProductMetadataCoordinator {
    /// Pane-lifetime preparation may target this pane's stream; downstream work retains its captured E1.
    func admittedPanePublicationStream(
        for producerAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) -> ActiveStream? {
        guard let stream = activeStream,
            stream.productAdmission.matches(producerAdmission)
                || producerAdmission.isCanonicalPaneAuthority(for: stream.productAdmission),
            isCurrentPanePublicationStream(
                stream, producerAdmission: producerAdmission, foregroundWorkAdmission: foregroundWorkAdmission)
        else { return nil }
        return stream
    }

    func isCurrentPanePublicationStream(
        _ stream: ActiveStream,
        producerAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) -> Bool {
        activeStream?.lease == stream.lease
            && activeStream?.productAdmission.matches(stream.productAdmission) == true
            && producerAdmission.withValidAdmission({ true }) == true
            && stream.productAdmission.withValidAdmission({ true }) == true
            && foregroundWorkAdmission.withValidAdmission({ true }) == true
    }

    func publish(
        status: GitWorkingTreeStatus,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async -> BridgePaneProductFileRefreshPublicationDisposition {
        guard activeStream != nil else { return .notRequired }
        guard
            let stream = admittedPanePublicationStream(
                for: productAdmission, foregroundWorkAdmission: foregroundWorkAdmission)
        else { return .stale }
        let emissions = await fileMetadataSource.publish(
            status: status,
            productAdmission: stream.productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission
        )
        return await publishFileRefreshSnapshots(
            emissions, stream: stream, producerAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission)
    }

    func publish(
        changeset: FileChangeset,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async -> BridgePaneProductFileRefreshPublicationDisposition {
        guard activeStream != nil else { return .notRequired }
        guard
            let stream = admittedPanePublicationStream(
                for: productAdmission, foregroundWorkAdmission: foregroundWorkAdmission)
        else { return .stale }
        do {
            let emissions = try await fileMetadataSource.publish(
                changeset: changeset,
                productAdmission: stream.productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission
            )
            return await publishFileRefreshSnapshots(
                emissions, stream: stream, producerAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission)
        } catch {
            return isCurrentPanePublicationStream(
                stream, producerAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission)
                ? Self.fileRefreshDisposition(for: error) : .stale
        }
    }

    private func publishFileRefreshSnapshots(
        _ emissions: [BridgePaneProductFileMetadataEmission],
        stream: ActiveStream,
        producerAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async -> BridgePaneProductFileRefreshPublicationDisposition {
        guard
            isCurrentPanePublicationStream(
                stream, producerAdmission: producerAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission)
        else { return .stale }
        guard !emissions.isEmpty else { return .notRequired }
        do {
            for subscriptionId in Set(emissions.map(\.subscriptionId)).sorted() {
                guard
                    isCurrentPanePublicationStream(
                        stream, producerAdmission: producerAdmission,
                        foregroundWorkAdmission: foregroundWorkAdmission)
                else { return .stale }
                _ = try await publishFileViewCapture(
                    subscriptionId: subscriptionId, productAdmission: stream.productAdmission)
                guard
                    isCurrentPanePublicationStream(
                        stream, producerAdmission: producerAdmission,
                        foregroundWorkAdmission: foregroundWorkAdmission)
                else { return .stale }
            }
            return .applied
        } catch {
            return isCurrentPanePublicationStream(
                stream, producerAdmission: producerAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission)
                ? Self.fileRefreshDisposition(for: error) : .stale
        }
    }
}
