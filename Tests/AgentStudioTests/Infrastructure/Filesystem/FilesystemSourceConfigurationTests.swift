import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite("Filesystem source-authorized root configuration")
struct FilesystemSourceConfigurationTests {
    @Test("host-authorized root preserves lexical and once-resolved aliases")
    func hostAuthorizedRootPreservesAliases() throws {
        let fixture = try RootAuthorityFixture()
        defer { fixture.remove() }

        let descriptor = try FilesystemSourceConfiguration.registerRoot(
            from: .hostAuthorized(
                FilesystemHostAuthorizedRootInput(
                    registration: fixture.registration,
                    authorizedBoundary: fixture.authorizedBoundary,
                    registeredRoot: fixture.lexicalAlias
                )
            )
        )

        #expect(descriptor.registration == fixture.registration)
        #expect(descriptor.sourceID == fixture.registration.sourceID)
        #expect(descriptor.aliases.standardizedLexical.path == fixture.lexicalAlias.path)
        #expect(descriptor.aliases.onceResolvedCanonical.path == fixture.canonicalRoot.path)
        #expect(descriptor.aliases.standardizedLexical.components.last == "alias")
        #expect(descriptor.aliases.onceResolvedCanonical.components.last == "canonical")
        #expect(descriptor.volumeSemantics.isLocal)
        #expect(descriptor.volumeSemantics.unicodePolicy == .canonicalEquivalent)
        #expect(descriptor.volumeSemantics.componentPolicy == .absolutePOSIX)
    }

    @Test("case-insensitive volume admits case-varied lexical containment")
    func caseInsensitiveVolumeAdmitsCaseVariedLexicalContainment() throws {
        let fixture = try RootAuthorityFixture()
        defer { fixture.remove() }
        let baselineDescriptor = try FilesystemSourceConfiguration.registerRoot(
            from: .hostAuthorized(
                FilesystemHostAuthorizedRootInput(
                    registration: fixture.registration,
                    authorizedBoundary: fixture.authorizedBoundary,
                    registeredRoot: fixture.canonicalRoot
                )
            )
        )
        try #require(
            baselineDescriptor.volumeSemantics.casePolicy == .caseInsensitive,
            "The macOS test volume must report case-insensitive semantics"
        )
        let caseVariedRoot = fixture.fixtureRoot
            .appending(path: "AUTHORIZED")
            .appending(path: "CANONICAL")

        let descriptor = try FilesystemSourceConfiguration.registerRoot(
            from: .hostAuthorized(
                FilesystemHostAuthorizedRootInput(
                    registration: fixture.registration,
                    authorizedBoundary: fixture.authorizedBoundary,
                    registeredRoot: caseVariedRoot
                )
            )
        )

        #expect(descriptor.registration == fixture.registration)
        #expect(descriptor.volumeSemantics == baselineDescriptor.volumeSemantics)
    }

    @Test("untrusted evidence cannot construct root authority")
    func untrustedEvidenceCannotConstructAuthority() {
        let rawEvidence = FilesystemUntrustedRootEvidence(path: "/tmp/raw")
        let scannerEvidence = FilesystemUntrustedRootEvidence(path: "/tmp/scanner")
        let gitEvidence = FilesystemUntrustedRootEvidence(path: "/tmp/git-metadata")
        let callbackEvidence = FilesystemUntrustedRootEvidence(path: "/tmp/callback")

        #expect(throws: FilesystemSourceConfigurationError.untrustedAuthority(.rawPath)) {
            try FilesystemSourceConfiguration.registerRoot(from: .rawPath(rawEvidence))
        }
        #expect(throws: FilesystemSourceConfigurationError.untrustedAuthority(.scannerResult)) {
            try FilesystemSourceConfiguration.registerRoot(
                from: .scannerResult(scannerEvidence)
            )
        }
        #expect(throws: FilesystemSourceConfigurationError.untrustedAuthority(.gitMetadata)) {
            try FilesystemSourceConfiguration.registerRoot(from: .gitMetadata(gitEvidence))
        }
        #expect(throws: FilesystemSourceConfigurationError.untrustedAuthority(.callbackPayload)) {
            try FilesystemSourceConfiguration.registerRoot(
                from: .callbackPayload(callbackEvidence)
            )
        }
    }

    @Test("relative and outside roots fail closed")
    func relativeAndOutsideRootsFailClosed() throws {
        let fixture = try RootAuthorityFixture()
        defer { fixture.remove() }

        let relativeURL = try #require(URL(string: "relative/root"))
        let relativeInput = FilesystemHostAuthorizedRootInput(
            registration: fixture.registration,
            authorizedBoundary: fixture.authorizedBoundary,
            registeredRoot: relativeURL
        )
        #expect(throws: FilesystemSourceConfigurationError.registeredRootNotAbsoluteFileURL) {
            try FilesystemSourceConfiguration.registerRoot(from: .hostAuthorized(relativeInput))
        }

        let outsideInput = FilesystemHostAuthorizedRootInput(
            registration: fixture.registration,
            authorizedBoundary: fixture.authorizedBoundary,
            registeredRoot: fixture.outsideRoot
        )
        #expect(throws: FilesystemSourceConfigurationError.registeredRootOutsideAuthorizedBoundary) {
            try FilesystemSourceConfiguration.registerRoot(from: .hostAuthorized(outsideInput))
        }
    }

    @Test("a symlink cannot widen authority outside the authorized boundary")
    func symlinkCannotWidenAuthority() throws {
        let fixture = try RootAuthorityFixture()
        defer { fixture.remove() }
        let escapingAlias = fixture.authorizedBoundary.appending(path: "escaping-alias")
        try FileManager.default.createSymbolicLink(
            at: escapingAlias,
            withDestinationURL: fixture.outsideRoot
        )

        let input = FilesystemHostAuthorizedRootInput(
            registration: fixture.registration,
            authorizedBoundary: fixture.authorizedBoundary,
            registeredRoot: escapingAlias
        )

        #expect(throws: FilesystemSourceConfigurationError.registeredRootOutsideAuthorizedBoundary) {
            try FilesystemSourceConfiguration.registerRoot(from: .hostAuthorized(input))
        }
    }

    @Test("descriptor rejects a mismatched registration generation")
    func descriptorRejectsMismatchedRegistrationGeneration() throws {
        let fixture = try RootAuthorityFixture()
        defer { fixture.remove() }
        let descriptor = try FilesystemSourceConfiguration.registerRoot(
            from: .hostAuthorized(
                FilesystemHostAuthorizedRootInput(
                    registration: fixture.registration,
                    authorizedBoundary: fixture.authorizedBoundary,
                    registeredRoot: fixture.canonicalRoot
                )
            )
        )
        let mismatchedRegistration = FSEventRegistrationToken(
            sourceID: fixture.registration.sourceID,
            registrationGeneration: fixture.registration.registrationGeneration + 1,
            rootGeneration: fixture.registration.rootGeneration
        )

        #expect(
            throws: FilesystemSourceConfigurationError.registrationMismatch(
                expected: fixture.registration,
                submitted: mismatchedRegistration
            )
        ) {
            try descriptor.requireExactRegistration(mismatchedRegistration)
        }
    }
}

private struct RootAuthorityFixture {
    let fixtureRoot: URL
    let authorizedBoundary: URL
    let canonicalRoot: URL
    let lexicalAlias: URL
    let outsideRoot: URL
    let registration: FSEventRegistrationToken

    init() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-root-authority-" + UUIDv7.generate().uuidString)
        let authorizedBoundary = fixtureRoot.appending(path: "authorized")
        let canonicalRoot = authorizedBoundary.appending(path: "canonical")
        let lexicalAlias = authorizedBoundary.appending(path: "alias")
        let outsideRoot = fixtureRoot.appending(path: "outside")

        try FileManager.default.createDirectory(
            at: canonicalRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outsideRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: lexicalAlias,
            withDestinationURL: canonicalRoot
        )

        self.fixtureRoot = fixtureRoot
        self.authorizedBoundary = authorizedBoundary
        self.canonicalRoot = canonicalRoot
        self.lexicalAlias = lexicalAlias
        self.outsideRoot = outsideRoot
        self.registration = FSEventRegistrationToken(
            sourceID: FilesystemSourceID(
                kind: .watchedParentMembership,
                rootID: UUIDv7.generate()
            ),
            registrationGeneration: 11,
            rootGeneration: 7
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: fixtureRoot)
    }
}
