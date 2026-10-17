import AgentStudioTestSupport
import Foundation
import Testing

@Suite("Bridge product admission static contract")
struct BridgeProductAdmissionStaticContractTests {
    @Test("pane composition and the installation owner are the only admission gate constructors")
    func paneCompositionSolelyConstructsProductAdmissionGate() throws {
        // Arrange
        let projectRoot = URL(
            fileURLWithPath: TestPathResolver.projectRoot(from: #filePath)
        )
        let constructorsBySource = try bridgeProductAdmissionConstructorCountBySource(
            under: projectRoot.appendingPathComponent(
                "Sources/AgentStudio/Features/Bridge"
            )
        )
        let bootstrapSource = try bridgeProductAdmissionSource(
            projectRoot: projectRoot,
            relativePath:
                "Sources/AgentStudio/Features/Bridge/Runtime/BridgePaneController+Bootstrap.swift"
        )
        let sessionOwnerSource = try bridgeProductAdmissionSource(
            projectRoot: projectRoot,
            relativePath:
                "Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSessionOwner.swift"
        )
        let sessionRouterSource = try bridgeProductAdmissionSource(
            projectRoot: projectRoot,
            relativePath:
                "Sources/AgentStudio/Features/Bridge/Transport/BridgeProductSchemeSessionRouter.swift"
        )
        let adapterSource = try bridgeProductAdmissionSource(
            projectRoot: projectRoot,
            relativePath: "Sources/AgentStudio/Features/Bridge/Transport/BridgeProductSchemeAdapter.swift"
        )

        // Act
        let normalizedBootstrapSource = bridgeProductAdmissionNormalizeWhitespace(bootstrapSource)
        let normalizedSessionOwnerSource = bridgeProductAdmissionNormalizeWhitespace(
            sessionOwnerSource
        )
        let normalizedSessionRouterSource = bridgeProductAdmissionNormalizeWhitespace(
            sessionRouterSource
        )
        // Assert
        #expect(
            constructorsBySource == [
                "Runtime/BridgePaneController+Bootstrap.swift": 1,
                "Runtime/Development/BridgeDevelopmentProductHost+ProductComposition.swift": 1,
                "Transport/BridgePaneProductSessionOwner.swift": 1,
            ],
            "PD:421: pane composition mints pane gates; the session owner alone mints installation gates"
        )
        #expect(normalizedBootstrapSource.contains("let productAdmissionGate = BridgeProductAdmissionGate()"))
        #expect(normalizedSessionOwnerSource.contains("let installationAdmissionGate = BridgeProductAdmissionGate()"))
        #expect(!adapterSource.contains("= BridgeProductAdmissionGate()"))
        #expect(
            !normalizedBootstrapSource.contains(
                "productAdmissionGate: BridgeProductAdmissionGate = BridgeProductAdmissionGate()"
            ),
            "BridgePaneController.makeInitialProductSessionInstallation must require the composed pane gate"
        )
        #expect(
            !normalizedSessionOwnerSource.contains(
                "productAdmissionGate: BridgeProductAdmissionGate = BridgeProductAdmissionGate()"
            ),
            "BridgeProductSessionInstallation.make must require the composed pane gate"
        )
        #expect(
            !normalizedSessionOwnerSource.contains("?? BridgeProductAdmissionGate()"),
            "BridgePaneProductSessionOwner must not synthesize a fallback pane gate"
        )
        #expect(
            !normalizedSessionRouterSource.contains("?? BridgeProductAdmissionGate()"),
            "BridgeProductSchemeSessionRouter must not synthesize a fallback pane gate"
        )
    }

    @Test("adapter product publication has one admission-gated yield boundary")
    func adapterProductPublicationUsesOneAdmissionGatedYieldBoundary() throws {
        // Arrange
        let projectRoot = URL(
            fileURLWithPath: TestPathResolver.projectRoot(from: #filePath)
        )
        let adapterSource = try bridgeProductAdmissionSource(
            projectRoot: projectRoot,
            relativePath:
                "Sources/AgentStudio/Features/Bridge/Transport/BridgeProductSchemeAdapter.swift"
        )

        // Act
        let normalizedAdapterSource = bridgeProductAdmissionNormalizeWhitespace(adapterSource)
        let yieldCount =
            adapterSource.components(separatedBy: "continuation.yield(result)").count - 1

        // Assert
        #expect(
            yieldCount == 1,
            "Every adapter response and frame must publish through one auditable yield boundary"
        )
        #expect(
            normalizedAdapterSource.contains(
                "productAdmission.withValidAdmission({ continuation.yield(result) })"
            ),
            "The sole adapter yield boundary must atomically validate the original admission context"
        )
    }

    @Test("only product ingress owners acquire pane admission")
    func onlyProductIngressOwnersAcquirePaneAdmission() throws {
        // Arrange
        let projectRoot = URL(
            fileURLWithPath: TestPathResolver.projectRoot(from: #filePath)
        )
        let agentStudioSources = projectRoot.appendingPathComponent(
            "Sources/AgentStudio"
        )

        // Act
        let acquisitionCountBySource = try bridgeProductAdmissionAcquisitionCountBySource(
            under: agentStudioSources
        )
        let diffCommandsSource = bridgeProductAdmissionNormalizeWhitespace(
            try bridgeProductAdmissionSource(
                projectRoot: projectRoot,
                relativePath:
                    "Sources/AgentStudio/Features/Bridge/Runtime/BridgePaneController+DiffCommands.swift"
            )
        )
        let ipcProjectionSource = bridgeProductAdmissionNormalizeWhitespace(
            try bridgeProductAdmissionSource(
                projectRoot: projectRoot,
                relativePath:
                    "Sources/AgentStudio/Features/Bridge/Runtime/BridgePaneController+IPCProjection.swift"
            )
        )
        let refreshAdmissionSource = bridgeProductAdmissionNormalizeWhitespace(
            try bridgeProductAdmissionSource(
                projectRoot: projectRoot,
                relativePath:
                    "Sources/AgentStudio/Features/Bridge/Runtime/BridgePaneController+RefreshAdmission.swift"
            )
        )
        let installationCompositionCountBySource = [
            "DiffCommands": diffCommandsSource.components(
                separatedBy: "withInstallation(installation.gate)"
            ).count - 1,
            "IPCProjection": ipcProjectionSource.components(
                separatedBy: "withInstallation(installation.gate)"
            ).count - 1,
            "RefreshAdmission": refreshAdmissionSource.components(
                separatedBy: "withInstallation(installation.gate)"
            ).count - 1,
        ]

        // Assert
        #expect(
            acquisitionCountBySource == [
                "Features/Bridge/Runtime/Development/BridgeDevelopmentProductHost+ProductComposition.swift": 1,
                "Features/Bridge/Runtime/Development/BridgeDevelopmentProductHost.swift": 1,
                "Features/Bridge/Runtime/BridgePaneController.swift": 1,
                "Features/Bridge/Runtime/BridgePaneController+Bootstrap.swift": 1,
                "Features/Bridge/Runtime/BridgePaneController+DiffCommands.swift": 1,
                "Features/Bridge/Runtime/BridgePaneController+IPCProjection.swift": 2,
                "Features/Bridge/Runtime/BridgePaneController+RefreshAdmission.swift": 2,
                "Features/Bridge/Runtime/BridgePaneController+SurfaceSelection.swift": 2,
                "Features/Bridge/Transport/BridgeProductSchemeAdapter.swift": 1,
            ],
            "Downstream product owners must carry the original context instead of reacquiring pane admission"
        )
        #expect(
            installationCompositionCountBySource == [
                "DiffCommands": 1,
                "IPCProjection": 2,
                "RefreshAdmission": 1,
            ],
            "Each existing Review ingress carries its single pane acquisition composed with the current E1"
        )
        let routerSource = bridgeProductAdmissionNormalizeWhitespace(
            try bridgeProductAdmissionSource(
                projectRoot: projectRoot,
                relativePath: "Sources/AgentStudio/Features/Bridge/Transport/BridgeProductSchemeSessionRouter.swift"
            )
        )
        let adapterSource = bridgeProductAdmissionNormalizeWhitespace(
            try bridgeProductAdmissionSource(
                projectRoot: projectRoot,
                relativePath: "Sources/AgentStudio/Features/Bridge/Transport/BridgeProductSchemeAdapter.swift"
            )
        )
        #expect(
            adapterSource.contains("productAdmissionGate.acquire()?.withInstallation(installationAdmissionGate)"),
            "The one product-ingress acquisition composes the pane and captured installation gates"
        )
        #expect(routerSource.components(separatedBy: "activeInstallation.productAdapter.acquireAdmission()").count == 2)
        let ingressStart = try #require(routerSource.range(of: "func claimActiveAdapter("))
        let ingressEnd = try #require(routerSource.range(of: "func metadataStreamHasEnded("))
        let ingress = String(routerSource[ingressStart.lowerBound..<ingressEnd.lowerBound])
        let admission = try #require(ingress.range(of: "activeInstallation.productAdapter.acquireAdmission()"))
        let claim = try #require(ingress.range(of: "activeTransportClaimIds.insert(claimId)"))
        #expect(admission.lowerBound < claim.lowerBound, "Admission precedes any route, operation or producer claim")
        #expect(ingress.contains("productAdmission: productAdmission"))
        #expect(
            routerSource.contains(
                "await adapter.route( request, productAdmission: productAdmission, continuation: continuation,"),
            "The captured claim forwards its original composed context, without another acquisition"
        )
    }

    @Test("frame observation settles from transport facts without a wall-clock deadline")
    func frameObservationHasNoWallClockDeadline() throws {
        // Arrange
        let projectRoot = URL(
            fileURLWithPath: TestPathResolver.projectRoot(from: #filePath)
        )
        let sessionSource = try bridgeProductAdmissionSource(
            projectRoot: projectRoot,
            relativePath:
                "Sources/AgentStudio/Features/Bridge/Transport/BridgeProductSession.swift"
        )
        let framePumpSource = try bridgeProductAdmissionSource(
            projectRoot: projectRoot,
            relativePath:
                "Sources/AgentStudio/Features/Bridge/Transport/BridgeProductSchemeFramePump.swift"
        )

        // Act
        let observationOwnerSource = sessionSource + framePumpSource

        // Assert
        #expect(
            !observationOwnerSource.contains("frameObservationTimeout"),
            "Frame observation must settle from acknowledgement, cancellation, reset, or producer retirement instead of elapsed time"
        )
        #expect(
            !observationOwnerSource.contains("frameObservationDelay"),
            "Frame observation must not introduce a deadline scheduler"
        )
        #expect(
            !observationOwnerSource.contains("waitWithFrameObservationTimeout"),
            "The frame-observation owner must not race exact transport facts against wall-clock time"
        )
    }
}

private func bridgeProductAdmissionSource(
    projectRoot: URL,
    relativePath: String
) throws -> String {
    try String(
        contentsOf: projectRoot.appendingPathComponent(relativePath),
        encoding: .utf8
    )
}

private func bridgeProductAdmissionNormalizeWhitespace(_ source: String) -> String {
    source.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
}

private func bridgeProductAdmissionConstructorCountBySource(
    under directory: URL
) throws -> [String: Int] {
    guard
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        )
    else {
        throw CocoaError(.fileReadUnknown)
    }
    var constructorsBySource: [String: Int] = [:]
    for element in enumerator {
        guard let fileURL = element as? URL,
            fileURL.pathExtension == "swift"
        else {
            continue
        }
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        let count = source.components(separatedBy: "BridgeProductAdmissionGate()").count - 1
        guard count > 0 else { continue }
        let relativePath = String(fileURL.path.dropFirst(directory.path.count + 1))
        constructorsBySource[relativePath] = count
    }
    return constructorsBySource
}

private func bridgeProductAdmissionAcquisitionCountBySource(
    under directory: URL
) throws -> [String: Int] {
    guard
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        )
    else {
        throw CocoaError(.fileReadUnknown)
    }
    var acquisitionCountBySource: [String: Int] = [:]
    for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        let acquisitionCount =
            source.components(separatedBy: "productAdmissionGate.acquire()").count - 1
        guard acquisitionCount > 0 else { continue }
        let relativePath = String(fileURL.path.dropFirst(directory.path.count + 1))
        acquisitionCountBySource[relativePath] = acquisitionCount
    }
    return acquisitionCountBySource
}
