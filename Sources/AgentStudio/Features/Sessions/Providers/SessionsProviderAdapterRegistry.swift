import Foundation

package enum SessionsProviderCapability: String, Sendable, Codable, Equatable, Hashable {
    case sessionStart
    case sessionEnd
    case turnStart
    case turnDone
    case turnAbort
    case turnFailed
    case permission
    case question
    case elicitation
    case elicitationResult
    case toolCompleted
    case toolFailed
    case toolActivity
    case subagentActivity
}

package struct SessionsProviderProfile: Sendable, Equatable {
    package let providerIdentifier: String
    package let exactVersion: String
    package let operatingMode: String
    package let qualifiedCapabilities: Set<SessionsProviderCapability>

    package init(
        providerIdentifier: String,
        exactVersion: String,
        operatingMode: String,
        qualifiedCapabilities: Set<SessionsProviderCapability>
    ) {
        self.providerIdentifier = providerIdentifier
        self.exactVersion = exactVersion
        self.operatingMode = operatingMode
        self.qualifiedCapabilities = qualifiedCapabilities
    }
}

package enum SessionsProviderQualification: Sendable, Equatable {
    case qualified(SessionsProviderProfile)
    case unverified
    case unavailable
}

package struct SessionsProviderIdentity: Sendable, Equatable {
    package let providerIdentifier: String
    package let exactVersion: String
    package let operatingMode: String

    package init(providerIdentifier: String, exactVersion: String, operatingMode: String) {
        self.providerIdentifier = providerIdentifier
        self.exactVersion = exactVersion
        self.operatingMode = operatingMode
    }
}

package struct SessionsBindingSourceIdentity: Sendable, Equatable {
    package let paneId: UUID
    package let providerConversationId: String
    package let sourceId: String
    package let sourceGenerationId: UUID
    package let occurrenceId: UUID

    package init(
        paneId: UUID,
        providerConversationId: String,
        sourceId: String,
        sourceGenerationId: UUID,
        occurrenceId: UUID
    ) {
        self.paneId = paneId
        self.providerConversationId = providerConversationId
        self.sourceId = sourceId
        self.sourceGenerationId = sourceGenerationId
        self.occurrenceId = occurrenceId
    }
}

package struct SessionsAdmittedEvidenceContext: Sendable, Equatable {
    package let reportContext: SessionsReportContext
    package let origin: SessionsEvidenceOrigin
    package let freshness: SessionsEvidenceFreshness

    fileprivate init(
        reportContext: SessionsReportContext,
        origin: SessionsEvidenceOrigin,
        freshness: SessionsEvidenceFreshness
    ) {
        self.reportContext = reportContext
        self.origin = origin
        self.freshness = freshness
    }
}

package struct SessionsProviderEvidenceAdmission: Sendable, Equatable {
    package let providerIdentifier: String
    package let exactVersion: String
    package let operatingMode: String
    package let capability: SessionsProviderCapability
    package let paneId: UUID
    package let sourceGenerationId: UUID
    package let freshness: SessionsEvidenceFreshness

    package init(
        provider: SessionsProviderIdentity,
        capability: SessionsProviderCapability,
        paneId: UUID,
        sourceGenerationId: UUID,
        freshness: SessionsEvidenceFreshness
    ) {
        providerIdentifier = provider.providerIdentifier
        exactVersion = provider.exactVersion
        operatingMode = provider.operatingMode
        self.capability = capability
        self.paneId = paneId
        self.sourceGenerationId = sourceGenerationId
        self.freshness = freshness
    }
}

package struct SessionsQualifiedSessionStartAdmission: Sendable, Equatable {
    package let providerIdentifier: String
    package let exactVersion: String
    package let operatingMode: String
    package let paneId: UUID
    package let providerConversationId: String
    package let sourceId: String
    package let sourceGenerationId: UUID
    package let occurrenceId: UUID
    package let freshness: SessionsEvidenceFreshness
    package let reportedAt: Date

    package init(
        provider: SessionsProviderIdentity,
        source: SessionsBindingSourceIdentity,
        freshness: SessionsEvidenceFreshness,
        reportedAt: Date
    ) {
        providerIdentifier = provider.providerIdentifier
        exactVersion = provider.exactVersion
        operatingMode = provider.operatingMode
        paneId = source.paneId
        providerConversationId = source.providerConversationId
        sourceId = source.sourceId
        sourceGenerationId = source.sourceGenerationId
        occurrenceId = source.occurrenceId
        self.freshness = freshness
        self.reportedAt = reportedAt
    }
}

/// Exact provider evidence is supplied by package composition. An empty or nearby
/// profile never grants provider-reported authority.
package struct SessionsProviderAdapterRegistry: Sendable {
    private let profilesByIdentity: [String: SessionsProviderProfile]

    package init(profiles: [SessionsProviderProfile]) {
        profilesByIdentity = Dictionary(
            uniqueKeysWithValues: profiles.map { profile in
                (Self.identityKey(profile: profile), profile)
            }
        )
    }

    package func qualification(
        providerIdentifier: String,
        exactVersion: String,
        operatingMode: String,
        capability: SessionsProviderCapability
    ) -> SessionsProviderQualification {
        let key = Self.identityKey(
            providerIdentifier: providerIdentifier,
            exactVersion: exactVersion,
            operatingMode: operatingMode
        )
        guard let profile = profilesByIdentity[key] else { return .unverified }
        guard profile.qualifiedCapabilities.contains(capability) else { return .unavailable }
        return .qualified(profile)
    }

    package func admitProviderEvidence(
        _ admission: SessionsProviderEvidenceAdmission
    ) -> SessionsAdmittedEvidenceContext? {
        guard
            case .qualified = qualification(
                providerIdentifier: admission.providerIdentifier,
                exactVersion: admission.exactVersion,
                operatingMode: admission.operatingMode,
                capability: admission.capability
            )
        else {
            return nil
        }
        return SessionsAdmittedEvidenceContext(
            reportContext: .sourceGeneration(
                paneId: admission.paneId,
                sourceGenerationId: admission.sourceGenerationId
            ),
            origin: .reported,
            freshness: admission.freshness
        )
    }

    package func qualifiedSessionStartBind(
        _ admission: SessionsQualifiedSessionStartAdmission,
        qualifyingCapability: SessionsProviderCapability = .sessionStart
    ) -> SessionsBindMutation? {
        guard
            case .qualified = qualification(
                providerIdentifier: admission.providerIdentifier,
                exactVersion: admission.exactVersion,
                operatingMode: admission.operatingMode,
                capability: qualifyingCapability
            )
        else {
            return nil
        }
        return SessionsBindMutation(
            paneId: admission.paneId,
            providerIdentifier: admission.providerIdentifier,
            providerVersion: admission.exactVersion,
            providerMode: admission.operatingMode,
            providerConversationId: admission.providerConversationId,
            sourceId: admission.sourceId,
            sourceGenerationId: admission.sourceGenerationId,
            transition: .qualifiedSessionStart(occurrenceId: admission.occurrenceId),
            freshness: admission.freshness,
            reportedAt: admission.reportedAt
        )
    }
}

extension SessionsProviderAdapterRegistry {
    fileprivate static func identityKey(profile: SessionsProviderProfile) -> String {
        identityKey(
            providerIdentifier: profile.providerIdentifier,
            exactVersion: profile.exactVersion,
            operatingMode: profile.operatingMode
        )
    }

    fileprivate static func identityKey(
        providerIdentifier: String,
        exactVersion: String,
        operatingMode: String
    ) -> String {
        "\(providerIdentifier)\u{1F}\(exactVersion)\u{1F}\(operatingMode)"
    }
}
