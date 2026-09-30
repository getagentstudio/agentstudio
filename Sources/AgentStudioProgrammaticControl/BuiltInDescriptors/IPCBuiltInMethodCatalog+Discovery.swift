import Foundation

extension IPCBuiltInMethodExampleContext {
    package init(illustrativeIdentifier: UUID) {
        self.init(
            runtimeId: illustrativeIdentifier, windowId: illustrativeIdentifier, workspaceId: illustrativeIdentifier,
            repositoryId: illustrativeIdentifier, worktreeId: illustrativeIdentifier, tabId: illustrativeIdentifier,
            paneId: illustrativeIdentifier, commandId: illustrativeIdentifier, correlationId: illustrativeIdentifier,
            subscriptionId: illustrativeIdentifier
        )
    }
}

extension IPCBuiltInMethodCatalog {
    package static func bootstrapDescriptors(examples: IPCBuiltInMethodExampleContext) throws
        -> [IPCAnyMethodDescriptor]
    {
        try IPCSystemAndAuthMethodDescriptors(examples: examples).erased
    }

    /// Offline classification cannot read the live catalog, so an unreachable
    /// app is answered from the compiled notification descriptors. Only these
    /// methods carry offline eligibility, so no other descriptor is needed.
    package static func offlineNotificationDescriptors(
        examples: IPCBuiltInMethodExampleContext
    ) throws -> [IPCAnyMethodDescriptor] {
        try IPCSessionMethodDescriptors(examples: examples).erased
    }

    /// The methods the CLI can invoke straight from its own compiled contracts.
    ///
    /// R-10 makes the compiled descriptor the CLI's source of truth, so fetching
    /// the whole self-describing catalog to reach a method it already holds
    /// buys nothing: the request still carries the compiled catalog identity and
    /// the server's existing version-skew error still answers a mismatch. It
    /// costs a great deal, because the catalog is the largest response the app
    /// composes and the provider hooks that call these methods run under short
    /// timeouts several times a turn.
    ///
    /// `command.list` and `command.execute` are deliberately absent: their
    /// arguments are defined by the running app, not by this binary.
    package static func locallyResolvableDescriptors(
        examples: IPCBuiltInMethodExampleContext
    ) throws -> [IPCAnyMethodDescriptor] {
        try bootstrapDescriptors(examples: examples)
            + IPCSessionMethodDescriptors(examples: examples).erased
    }

    /// Whether these arguments name one of `descriptors`, either by method name
    /// or by a model call it declares, using the same prefix match the
    /// invocation parser applies.
    package static func resolvesLocally(
        _ arguments: [String],
        descriptors: [IPCAnyMethodDescriptor]
    ) -> Bool {
        guard let invocationName = arguments.first else { return false }
        if descriptors.contains(where: { $0.metadata.name == invocationName }) { return true }
        return descriptors.contains { descriptor in
            descriptor.metadata.modelCalls.contains { modelCall in
                arguments.starts(with: modelCall.variant.rawValue.split(separator: " ").map(String.init))
            }
        }
    }

    package static func matchingDiscoveredMethods(
        _ catalog: IPCMethodCatalogResult,
        examples: IPCBuiltInMethodExampleContext
    ) throws -> [IPCAnyMethodDescriptor] {
        guard catalog.compatibility == .current,
            Set(catalog.methods.map(\.name)).count == catalog.methods.count
        else { throw incompatibleCatalog() }
        let methods = Dictionary(uniqueKeysWithValues: catalog.methods.map { ($0.name, $0) })
        let maximumWait: Double
        if let wait = methods["terminal.wait"] {
            guard case .object(let fields) = wait.parameterSchema,
                case .number(_, let maximum) = fields.first(where: { $0.name == "timeoutSeconds" })?.schema,
                let maximum
            else { throw incompatibleCatalog() }
            maximumWait = maximum
        } else {
            // This descriptor is filtered out below; no absent method supplies invocation policy.
            maximumWait = 0
        }
        let inputs = IPCBuiltInMethodCatalogInputs(
            terminalWaitMaximumSeconds: maximumWait,
            relationships: .init(
                paneFocus: methods["pane.focus"]?.commandRelationship ?? .noInteractiveIdentity,
                paneClose: methods["pane.close"]?.commandRelationship ?? .noInteractiveIdentity,
                drawerToggle: methods["drawer.toggle"]?.commandRelationship ?? .noInteractiveIdentity,
                drawerAddPane: methods["drawer.addPane"]?.commandRelationship ?? .noInteractiveIdentity,
                bridgeDiffLoad: methods["bridge.diff.load"]?.commandRelationship ?? .noInteractiveIdentity,
                bridgeFileViewOpen: methods["bridge.fileView.open"]?.commandRelationship ?? .noInteractiveIdentity
            ), examples: examples
        )
        let recognizedHiddenNames = Set(catalog.recognizedUnexposedMethods.map(\.name))
        return try IPCBuiltInMethodCatalog(inputs: inputs).erasedDescriptors.compactMap { descriptor in
            guard let advertised = methods[descriptor.metadata.name] else {
                // A method the app recognizes but this channel hides has no
                // advertised contract. The compiled one still types the
                // request, and the app refuses it by name before validating.
                return recognizedHiddenNames.contains(descriptor.metadata.name) ? descriptor : nil
            }
            let compiled = descriptor.metadata
            guard compiled.parameterSchema == advertised.parameterSchema,
                compiled.resultSchema == advertised.resultSchema,
                compiled.responseDelivery == advertised.responseDelivery,
                compiled.correlationPolicy == advertised.correlationPolicy,
                compiled.commandRelationship == advertised.commandRelationship,
                compiled.offlineEligibility == advertised.offlineEligibility,
                compiled.modelCalls == advertised.modelCalls,
                compiled.requiredPrivileges == advertised.requiredPrivileges,
                compiled.allowedTargetKinds == advertised.allowedTargetKinds,
                compiled.dataScope == advertised.dataScope,
                compiled.exposure == advertised.exposure
            else { throw incompatibleCatalog() }
            return descriptor
        }
    }

    private static func incompatibleCatalog() -> IPCSchemaValidationError {
        IPCSchemaValidationError(
            fieldPath: "$.methods", reason: .invalidDefinition, expected: "compatible compiled method contracts")
    }
}
