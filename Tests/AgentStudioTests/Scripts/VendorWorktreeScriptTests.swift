import Darwin
import Foundation
import Testing

@Suite("Vendor worktree helper")
struct VendorWorktreeScriptTests {
    @Test("primary and shared roles work in registered worktrees whose paths contain spaces")
    func primaryAndSharedRolesWithSpaces() async throws {
        // Arrange
        let fixture = try await VendorWorktreeFixture()
        defer { fixture.cleanup() }
        let primaryBefore = try fixture.primaryOutputSnapshot()
        let trackedTerminfoBefore = try Data(contentsOf: fixture.primaryTrackedTerminfoURL)

        // Act
        let primaryRole = try await fixture.runHelper("role", in: fixture.primaryRoot)
        let initialLinkedRole = try await fixture.runHelper("role", in: fixture.linkedRoot)
        let setup = try await fixture.runHelper("setup-shared", in: fixture.linkedRoot)
        let sharedRole = try await fixture.runHelper("role", in: fixture.linkedRoot)
        let verification = try await fixture.runHelper("verify", in: fixture.linkedRoot)

        // Assert
        #expect(primaryRole.exitCode == 0)
        #expect(primaryRole.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "primary")
        #expect(initialLinkedRole.exitCode == 0)
        #expect(initialLinkedRole.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "partial")
        #expect(setup.exitCode == 0, Comment(rawValue: setup.stderr))
        #expect(sharedRole.exitCode == 0)
        #expect(sharedRole.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "shared")
        #expect(verification.exitCode == 0, Comment(rawValue: verification.stderr))
        try fixture.expectExactSharedProjection()
        #expect(try fixture.primaryOutputSnapshot() == primaryBefore)
        #expect(try Data(contentsOf: fixture.primaryTrackedTerminfoURL) == trackedTerminfoBefore)
        #expect(try await fixture.gitStatus(in: fixture.linkedRoot).isEmpty)
    }

    @Test("shared setup is idempotent and repairs stale regular resource copies")
    func sharedSetupRepairsStaleCopies() async throws {
        // Arrange
        let fixture = try await VendorWorktreeFixture()
        defer { fixture.cleanup() }
        try fixture.requireSuccess(await fixture.runHelper("setup-shared", in: fixture.linkedRoot))
        let firstProjection = try fixture.sharedProjectionSnapshot()
        try Data("stale shell integration".utf8).write(
            to: fixture.linkedGhosttyResourcesURL.appending(path: "shell-integration/ghostty.sh"))

        // Act
        let staleVerification = try await fixture.runHelper("verify", in: fixture.linkedRoot)
        let repair = try await fixture.runHelper("setup-shared", in: fixture.linkedRoot)
        let repairedVerification = try await fixture.runHelper("verify", in: fixture.linkedRoot)
        let secondSetup = try await fixture.runHelper("setup-shared", in: fixture.linkedRoot)

        // Assert
        #expect(staleVerification.exitCode != 0)
        #expect(repair.exitCode == 0, Comment(rawValue: repair.stderr))
        #expect(repairedVerification.exitCode == 0, Comment(rawValue: repairedVerification.stderr))
        #expect(secondSetup.exitCode == 0, Comment(rawValue: secondSetup.stderr))
        #expect(try fixture.sharedProjectionSnapshot() == firstProjection)
        try fixture.expectExactSharedProjection()
    }

    @Test("pin mismatches fail without changing primary outputs")
    func pinMismatchesFailWithoutPrimaryMutation() async throws {
        for mismatch in VendorPinMismatch.allCases {
            // Arrange
            let fixture = try await VendorWorktreeFixture()
            defer { fixture.cleanup() }
            try fixture.requireSuccess(await fixture.runHelper("setup-shared", in: fixture.linkedRoot))
            let primaryBefore = try fixture.primaryOutputSnapshot()
            try await fixture.apply(mismatch)

            // Act
            let verification = try await fixture.runHelper("verify", in: fixture.linkedRoot)

            // Assert
            #expect(
                verification.exitCode != 0,
                "Expected \(mismatch.rawValue) to fail verification")
            #expect(verification.stderr.contains(fixture.primaryRoot.path))
            #expect(verification.stderr.contains("running plain 'mise run setup' in the primary worktree"))
            #expect(verification.stderr.contains("rerun plain 'mise run setup' in this linked worktree"))
            #expect(try fixture.primaryOutputSnapshot() == primaryBefore)
        }
    }

    @Test("a framework without a slice header fails preflight by name")
    func frameworkWithoutSliceHeaderFailsPreflightByName() async throws {
        // Arrange — an XCFramework directory that has the library but no header.
        // This is what an interrupted or partial vendor build leaves behind, and
        // it used to pass preflight and fail much later as
        // "The file ghostty.h couldn't be opened" from GhosttyEventRoutingCoverageTests.
        let fixture = try await VendorWorktreeFixture()
        defer { fixture.cleanup() }
        try fixture.apply(.missingFrameworkSliceHeader)

        // Act
        let setup = try await fixture.runHelper("setup-shared", in: fixture.linkedRoot)

        // Assert — the preflight names the exact missing path.
        #expect(setup.exitCode != 0)
        #expect(setup.stderr.contains("GhosttyKit XCFramework has no slice header"))
        #expect(setup.stderr.contains("Headers/ghostty.h"))
    }

    @Test("invalid primary source types fail without replacing linked collisions")
    func invalidPrimarySourcesAndCollisionsFailClosed() async throws {
        for invalidSource in VendorInvalidPrimarySource.allCases {
            // Arrange
            let fixture = try await VendorWorktreeFixture()
            defer { fixture.cleanup() }
            try fixture.apply(invalidSource)
            let primaryBefore = try fixture.primaryOutputSnapshot(allowMissing: true)

            // Act
            let setup = try await fixture.runHelper("setup-shared", in: fixture.linkedRoot)

            // Assert
            #expect(setup.exitCode != 0, "Expected \(invalidSource.rawValue) to fail setup")
            #expect(setup.stderr.contains(fixture.primaryRoot.path))
            #expect(setup.stderr.contains("running plain 'mise run setup' in the primary worktree"))
            #expect(setup.stderr.contains("rerun plain 'mise run setup' in this linked worktree"))
            #expect(try fixture.primaryOutputSnapshot(allowMissing: true) == primaryBefore)
            #expect(!FileManager.default.fileExists(atPath: fixture.linkedFrameworkURL.path))
        }

        // Arrange
        let collisionFixture = try await VendorWorktreeFixture()
        defer { collisionFixture.cleanup() }
        try FileManager.default.createDirectory(
            at: collisionFixture.linkedFrameworkURL,
            withIntermediateDirectories: true)
        let sentinel = collisionFixture.linkedFrameworkURL.appending(path: "keep-me")
        try Data("collision".utf8).write(to: sentinel)

        // Act
        let collisionSetup = try await collisionFixture.runHelper("setup-shared", in: collisionFixture.linkedRoot)

        // Assert
        #expect(collisionSetup.exitCode != 0)
        #expect(try Data(contentsOf: sentinel) == Data("collision".utf8))
    }

    @Test("shared setup never hydrates submodules or invokes Zig")
    func sharedSetupDoesNotHydrateOrInvokeZig() async throws {
        // Arrange
        let fixture = try await VendorWorktreeFixture()
        defer { fixture.cleanup() }
        let commandLog = fixture.temporaryRoot.appending(path: "command log.txt")
        let spyDirectory = try await fixture.makeCommandSpies(logURL: commandLog)

        // Act
        let setup = try await fixture.runHelper(
            "setup-shared",
            in: fixture.linkedRoot,
            environment: ["PATH": "\(spyDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin"])

        // Assert
        #expect(setup.exitCode == 0, Comment(rawValue: setup.stderr))
        let log = try String(contentsOf: commandLog, encoding: .utf8)
        #expect(!log.contains("submodule update"))
        #expect(!log.contains("\nzig "))
        #expect(!FileManager.default.fileExists(atPath: fixture.linkedRoot.appending(path: "vendor/ghostty/.git").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.linkedRoot.appending(path: "vendor/zmx/.git").path))
    }

    @Test("producer guard resolves the superproject when invoked inside a partial zmx submodule")
    func producerGuardRejectsPartialStateFromNestedSubmodule() async throws {
        // Arrange
        let fixture = try await VendorWorktreeFixture()
        defer { fixture.cleanup() }
        try fixture.requireSuccess(
            await VendorWorktreeFixture.runGit(
                ["submodule", "update", "--init", "--", "vendor/ghostty", "vendor/zmx"],
                in: fixture.linkedRoot))
        let nestedZmxRoot = fixture.linkedRoot.appending(path: "vendor/zmx")

        // Act
        let guardResult = try await fixture.runHelper(
            "require-producer",
            in: fixture.linkedRoot,
            currentDirectory: nestedZmxRoot)

        // Assert
        #expect(guardResult.exitCode != 0)
        #expect(guardResult.stderr.contains("vendor producer is unavailable in a partial worktree"))
        #expect(!FileManager.default.fileExists(atPath: fixture.linkedZmxOutputURL.path))
    }

    @Test("explicit local setup builds divergent committed vendor pins without mutating primary")
    func localSetupSupportsDivergentPins() async throws {
        // Arrange
        let fixture = try await VendorWorktreeFixture()
        defer { fixture.cleanup() }
        let primaryBefore = try fixture.primaryOutputSnapshot()
        try await fixture.apply(.linkedGhosttyGitlink)
        let spyDirectory = try fixture.makeLocalProducerSpies()

        // Act
        let conversion = try await fixture.runHelper(
            "setup-local",
            in: fixture.linkedRoot,
            environment: [
                "PATH": "\(spyDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "GIT_ALLOW_PROTOCOL": "file",
            ])
        let verification = try await fixture.runHelper("verify", in: fixture.linkedRoot)

        // Assert
        #expect(conversion.exitCode == 0, Comment(rawValue: conversion.stderr))
        #expect(verification.exitCode == 0, Comment(rawValue: verification.stderr))
        #expect(
            try await fixture.checkedOutRevision(path: "vendor/ghostty", in: fixture.linkedRoot)
                == fixture.ghosttySecondCommit)
        #expect(
            try await fixture.checkedOutRevision(path: "vendor/ghostty", in: fixture.primaryRoot)
                == fixture.ghosttyFirstCommit)
        #expect(try fixture.primaryOutputSnapshot() == primaryBefore)
    }

    @Test("local setup rejects partial output and resource collisions before mutation")
    func localSetupRejectsPartialCollisionsBeforeMutation() async throws {
        // Arrange
        let outputFixture = try await VendorWorktreeFixture()
        defer { outputFixture.cleanup() }
        let frameworkSentinel = outputFixture.linkedFrameworkURL.appending(path: "keep-me")
        try FileManager.default.createDirectory(
            at: outputFixture.linkedFrameworkURL,
            withIntermediateDirectories: true)
        try Data("user-owned framework".utf8).write(to: frameworkSentinel)
        let outputSpies = try outputFixture.makeLocalProducerSpies()

        // Act
        let outputCollision = try await outputFixture.runHelper(
            "setup-local",
            in: outputFixture.linkedRoot,
            environment: ["PATH": "\(outputSpies.path):/usr/bin:/bin:/usr/sbin:/sbin"])

        // Assert
        #expect(outputCollision.exitCode != 0)
        #expect(try Data(contentsOf: frameworkSentinel) == Data("user-owned framework".utf8))
        #expect(
            !FileManager.default.fileExists(
                atPath: outputFixture.linkedRoot.appending(path: "vendor/ghostty/.git").path))

        // Arrange
        let resourceFixture = try await VendorWorktreeFixture()
        defer { resourceFixture.cleanup() }
        try FileManager.default.createDirectory(
            at: resourceFixture.linkedGhosttyTerminfoURL,
            withIntermediateDirectories: true)
        let terminfoSentinel = resourceFixture.linkedGhosttyTerminfoURL.appending(path: "keep-me")
        try Data("user-owned terminfo".utf8).write(to: terminfoSentinel)
        let resourceSpies = try resourceFixture.makeLocalProducerSpies()

        // Act
        let resourceCollision = try await resourceFixture.runHelper(
            "setup-local",
            in: resourceFixture.linkedRoot,
            environment: ["PATH": "\(resourceSpies.path):/usr/bin:/bin:/usr/sbin:/sbin"])

        // Assert
        #expect(resourceCollision.exitCode != 0)
        #expect(try Data(contentsOf: terminfoSentinel) == Data("user-owned terminfo".utf8))
        #expect(!FileManager.default.fileExists(atPath: resourceFixture.linkedFrameworkURL.path))
        #expect(!FileManager.default.fileExists(atPath: resourceFixture.linkedZmxOutputURL.path))
    }

    @Test("flagged setup repairs an interrupted hydrated local transition")
    func localSetupRepairsInterruptedHydratedTransition() async throws {
        // Arrange
        let fixture = try await VendorWorktreeFixture()
        defer { fixture.cleanup() }
        try fixture.requireSuccess(
            await VendorWorktreeFixture.runGit(
                ["submodule", "update", "--init", "--", "vendor/ghostty", "vendor/zmx"],
                in: fixture.linkedRoot))
        let partialFramework = fixture.linkedFrameworkURL.appending(path: "partial-output")
        try FileManager.default.createDirectory(
            at: fixture.linkedFrameworkURL,
            withIntermediateDirectories: true)
        try Data("interrupted producer".utf8).write(to: partialFramework)
        let primaryBefore = try fixture.primaryOutputSnapshot()
        let producerSpies = try fixture.makeLocalProducerSpies()

        // Act
        let recovery = try await fixture.runHelper(
            "setup-local",
            in: fixture.linkedRoot,
            environment: ["PATH": "\(producerSpies.path):/usr/bin:/bin:/usr/sbin:/sbin"])

        // Assert
        #expect(recovery.exitCode == 0, Comment(rawValue: recovery.stderr))
        try fixture.expectCompleteLocalProjection()
        #expect(try fixture.primaryOutputSnapshot() == primaryBefore)
    }

    @Test("local setup rejects symlinked destination ancestors before external mutation")
    func localSetupRejectsDestinationAncestorEscape() async throws {
        // Arrange
        let fixture = try await VendorWorktreeFixture()
        defer { fixture.cleanup() }
        let linkedTerminfo67 = fixture.linkedRoot.appending(
            path: "Sources/AgentStudio/Resources/terminfo/67")
        let externalTerminfo67 = fixture.temporaryRoot.appending(path: "external terminfo 67")
        try FileManager.default.createDirectory(
            at: externalTerminfo67,
            withIntermediateDirectories: true)
        let externalSentinel = externalTerminfo67.appending(path: "ghostty")
        try Data("external sentinel".utf8).write(to: externalSentinel)
        try FileManager.default.createDirectory(
            at: linkedTerminfo67.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: linkedTerminfo67,
            withDestinationURL: externalTerminfo67)
        let producerSpies = try fixture.makeLocalProducerSpies()

        // Act
        let conversion = try await fixture.runHelper(
            "setup-local",
            in: fixture.linkedRoot,
            environment: ["PATH": "\(producerSpies.path):/usr/bin:/bin:/usr/sbin:/sbin"])

        // Assert
        #expect(conversion.exitCode != 0)
        #expect(try Data(contentsOf: externalSentinel) == Data("external sentinel".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.linkedFrameworkURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.linkedZmxOutputURL.path))
    }

    @Test("shared setup rejects wrong resource types before projection mutation")
    func sharedSetupRejectsWrongResourceTypesBeforeMutation() async throws {
        // Arrange
        let resourcesFixture = try await VendorWorktreeFixture()
        defer { resourcesFixture.cleanup() }
        try FileManager.default.createDirectory(
            at: resourcesFixture.linkedGhosttyResourcesURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("user-owned resource file".utf8).write(
            to: resourcesFixture.linkedGhosttyResourcesURL)

        // Act
        let resourcesFailure = try await resourcesFixture.runHelper(
            "setup-shared",
            in: resourcesFixture.linkedRoot)

        // Assert
        #expect(resourcesFailure.exitCode != 0)
        #expect(
            try Data(contentsOf: resourcesFixture.linkedGhosttyResourcesURL)
                == Data("user-owned resource file".utf8))
        #expect(!FileManager.default.fileExists(atPath: resourcesFixture.linkedFrameworkURL.path))
        #expect(!FileManager.default.fileExists(atPath: resourcesFixture.linkedZmxOutputURL.path))

        // Arrange
        let terminfoFixture = try await VendorWorktreeFixture()
        defer { terminfoFixture.cleanup() }
        try FileManager.default.createDirectory(
            at: terminfoFixture.linkedGhosttyTerminfoURL,
            withIntermediateDirectories: true)
        let terminfoSentinel = terminfoFixture.linkedGhosttyTerminfoURL.appending(path: "keep-me")
        try Data("user-owned terminfo directory".utf8).write(to: terminfoSentinel)

        // Act
        let terminfoFailure = try await terminfoFixture.runHelper(
            "setup-shared",
            in: terminfoFixture.linkedRoot)

        // Assert
        #expect(terminfoFailure.exitCode != 0)
        #expect(
            try Data(contentsOf: terminfoSentinel)
                == Data("user-owned terminfo directory".utf8))
        #expect(!FileManager.default.fileExists(atPath: terminfoFixture.linkedFrameworkURL.path))
        #expect(!FileManager.default.fileExists(atPath: terminfoFixture.linkedZmxOutputURL.path))
    }

    @Test("shared setup rejects primary source paths that escape through symlinked ancestors")
    func sharedSetupRejectsPrimarySourceAncestorEscapes() async throws {
        // Arrange
        let frameworkFixture = try await VendorWorktreeFixture()
        defer { frameworkFixture.cleanup() }
        let foreignFrameworks = frameworkFixture.temporaryRoot.appending(path: "foreign Frameworks")
        try FileManager.default.moveItem(
            at: frameworkFixture.primaryRoot.appending(path: "Frameworks"),
            to: foreignFrameworks)
        try FileManager.default.createSymbolicLink(
            at: frameworkFixture.primaryRoot.appending(path: "Frameworks"),
            withDestinationURL: foreignFrameworks)

        // Act
        let frameworkEscape = try await frameworkFixture.runHelper(
            "setup-shared",
            in: frameworkFixture.linkedRoot)

        // Assert
        #expect(frameworkEscape.exitCode != 0)
        #expect(frameworkEscape.stderr.contains("vendor source escapes its worktree root"))
        #expect(!FileManager.default.fileExists(atPath: frameworkFixture.linkedFrameworkURL.path))

        // Arrange
        let zmxFixture = try await VendorWorktreeFixture()
        defer { zmxFixture.cleanup() }
        let primaryZmxBin = zmxFixture.primaryZmxOutputURL.appending(path: "bin")
        let foreignZmxBin = zmxFixture.temporaryRoot.appending(path: "foreign zmx bin")
        try FileManager.default.moveItem(at: primaryZmxBin, to: foreignZmxBin)
        try FileManager.default.createSymbolicLink(
            at: primaryZmxBin,
            withDestinationURL: foreignZmxBin)

        // Act
        let zmxEscape = try await zmxFixture.runHelper("setup-shared", in: zmxFixture.linkedRoot)

        // Assert
        #expect(zmxEscape.exitCode != 0)
        #expect(zmxEscape.stderr.contains("vendor source escapes its worktree root"))
        #expect(!FileManager.default.fileExists(atPath: zmxFixture.linkedFrameworkURL.path))
    }

    @Test("GitHub Actions verification accepts workflow-owned resources without local terminfo projection")
    func githubActionsVerificationMatchesWorkflowOutputs() async throws {
        // Arrange
        let fixture = try await VendorWorktreeFixture()
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.primaryGhosttyTerminfoURL)

        // Act
        let workflowVerification = try await fixture.runHelper(
            "verify",
            in: fixture.primaryRoot,
            environment: ["GITHUB_ACTIONS": "true"])
        try FileManager.default.removeItem(at: fixture.primaryFrameworkURL)
        let missingFrameworkVerification = try await fixture.runHelper(
            "verify",
            in: fixture.primaryRoot,
            environment: ["GITHUB_ACTIONS": "true"])

        // Assert
        #expect(workflowVerification.exitCode == 0, Comment(rawValue: workflowVerification.stderr))
        #expect(missingFrameworkVerification.exitCode != 0)
    }

    @Test("producer guard rejects symlinked primary sources outputs and ancestors")
    func producerGuardRejectsSymlinkedPrimaryPaths() async throws {
        // Arrange: generated zmx output is a symlink.
        let zmxOutputFixture = try await VendorWorktreeFixture()
        defer { zmxOutputFixture.cleanup() }
        let externalZmxOutput = zmxOutputFixture.temporaryRoot.appending(path: "external zmx output")
        try FileManager.default.createDirectory(at: externalZmxOutput, withIntermediateDirectories: true)
        let zmxSentinel = externalZmxOutput.appending(path: "keep-me")
        try Data("zmx sentinel".utf8).write(to: zmxSentinel)
        try FileManager.default.removeItem(at: zmxOutputFixture.primaryZmxOutputURL)
        try FileManager.default.createSymbolicLink(
            at: zmxOutputFixture.primaryZmxOutputURL,
            withDestinationURL: externalZmxOutput)

        // Act
        let zmxOutputGuard = try await zmxOutputFixture.runHelper(
            "require-producer",
            in: zmxOutputFixture.primaryRoot)

        // Assert
        #expect(zmxOutputGuard.exitCode != 0)
        #expect(try Data(contentsOf: zmxSentinel) == Data("zmx sentinel".utf8))

        // Arrange: zmx's exact installation directory is a symlink.
        let zmxBinFixture = try await VendorWorktreeFixture()
        defer { zmxBinFixture.cleanup() }
        let externalZmxBin = zmxBinFixture.temporaryRoot.appending(path: "external zmx bin")
        try FileManager.default.createDirectory(at: externalZmxBin, withIntermediateDirectories: true)
        let zmxBinSentinel = externalZmxBin.appending(path: "keep-me")
        try Data("zmx bin sentinel".utf8).write(to: zmxBinSentinel)
        let primaryZmxBin = zmxBinFixture.primaryZmxOutputURL.appending(path: "bin")
        try FileManager.default.removeItem(at: primaryZmxBin)
        try FileManager.default.createSymbolicLink(
            at: primaryZmxBin,
            withDestinationURL: externalZmxBin)

        // Act
        let zmxBinGuard = try await zmxBinFixture.runHelper(
            "require-producer",
            in: zmxBinFixture.primaryRoot)

        // Assert
        #expect(zmxBinGuard.exitCode != 0)
        #expect(try Data(contentsOf: zmxBinSentinel) == Data("zmx bin sentinel".utf8))

        // Arrange: the zmx submodule root is a symlink.
        let zmxSourceFixture = try await VendorWorktreeFixture()
        defer { zmxSourceFixture.cleanup() }
        let externalZmxSource = zmxSourceFixture.temporaryRoot.appending(path: "external zmx source")
        try FileManager.default.createDirectory(at: externalZmxSource, withIntermediateDirectories: true)
        let sourceSentinel = externalZmxSource.appending(path: "keep-me")
        try Data("source sentinel".utf8).write(to: sourceSentinel)
        try FileManager.default.removeItem(
            at: zmxSourceFixture.primaryRoot.appending(path: "vendor/zmx"))
        try FileManager.default.createSymbolicLink(
            at: zmxSourceFixture.primaryRoot.appending(path: "vendor/zmx"),
            withDestinationURL: externalZmxSource)

        // Act
        let zmxSourceGuard = try await zmxSourceFixture.runHelper(
            "require-producer",
            in: zmxSourceFixture.primaryRoot)

        // Assert
        #expect(zmxSourceGuard.exitCode != 0)
        #expect(try Data(contentsOf: sourceSentinel) == Data("source sentinel".utf8))

        // Arrange: Ghostty's exact adaptation file is a symlink.
        let ghosttySourceFixture = try await VendorWorktreeFixture()
        defer { ghosttySourceFixture.cleanup() }
        let externalLibtoolStep = ghosttySourceFixture.temporaryRoot.appending(path: "external LibtoolStep.zig")
        try Data("ghostty source sentinel".utf8).write(to: externalLibtoolStep)
        let primaryLibtoolStep =
            ghosttySourceFixture.primaryRoot
            .appending(path: "vendor/ghostty/src/build/LibtoolStep.zig")
        try FileManager.default.createDirectory(
            at: primaryLibtoolStep.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: primaryLibtoolStep,
            withDestinationURL: externalLibtoolStep)

        // Act
        let ghosttySourceGuard = try await ghosttySourceFixture.runHelper(
            "require-producer",
            in: ghosttySourceFixture.primaryRoot)

        // Assert
        #expect(ghosttySourceGuard.exitCode != 0)
        #expect(
            try Data(contentsOf: externalLibtoolStep)
                == Data("ghostty source sentinel".utf8))

        // Arrange: a generated-output ancestor is a symlink.
        let frameworkFixture = try await VendorWorktreeFixture()
        defer { frameworkFixture.cleanup() }
        let externalFrameworks = frameworkFixture.temporaryRoot.appending(path: "external Frameworks")
        try FileManager.default.createDirectory(at: externalFrameworks, withIntermediateDirectories: true)
        let frameworkSentinel = externalFrameworks.appending(path: "keep-me")
        try Data("framework sentinel".utf8).write(to: frameworkSentinel)
        try FileManager.default.removeItem(
            at: frameworkFixture.primaryFrameworkURL.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(
            at: frameworkFixture.primaryFrameworkURL.deletingLastPathComponent(),
            withDestinationURL: externalFrameworks)

        // Act
        let frameworkGuard = try await frameworkFixture.runHelper(
            "require-producer",
            in: frameworkFixture.primaryRoot)

        // Assert
        #expect(frameworkGuard.exitCode != 0)
        #expect(try Data(contentsOf: frameworkSentinel) == Data("framework sentinel".utf8))
    }

    @Test("failed shared copy publication removes only its temporary artifact")
    func failedSharedCopyPublicationCleansTemporaryArtifact() async throws {
        // Arrange
        let fixture = try await VendorWorktreeFixture()
        defer { fixture.cleanup() }
        let copySpies = try fixture.makeFailingCopySpy()

        // Act
        let setup = try await fixture.runHelper(
            "setup-shared",
            in: fixture.linkedRoot,
            environment: ["PATH": "\(copySpies.path):/usr/bin:/bin:/usr/sbin:/sbin"])

        // Assert
        #expect(setup.exitCode != 0)
        let resourcesParent = fixture.linkedGhosttyResourcesURL.deletingLastPathComponent()
        let parentEntries =
            (try? FileManager.default.contentsOfDirectory(atPath: resourcesParent.path)) ?? []
        #expect(!parentEntries.contains { $0.hasPrefix(".vendor-worktree-copy.") })
    }

    @Test("local conversion removes only exact shared links and plain setup preserves local state")
    func localConversionAndPreservation() async throws {
        // Arrange
        let fixture = try await VendorWorktreeFixture()
        defer { fixture.cleanup() }
        try fixture.requireSuccess(await fixture.runHelper("setup-shared", in: fixture.linkedRoot))
        let unrelatedSentinel = fixture.linkedRoot.appending(path: "unrelated-link")
        try FileManager.default.createSymbolicLink(
            at: unrelatedSentinel,
            withDestinationURL: fixture.primaryFrameworkURL)
        let primaryBefore = try fixture.primaryOutputSnapshot()
        let spyDirectory = try fixture.makeLocalProducerSpies()

        // Act
        let conversion = try await fixture.runHelper(
            "setup-local",
            in: fixture.linkedRoot,
            environment: [
                "PATH": "\(spyDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "GIT_ALLOW_PROTOCOL": "file",
            ])
        let localRole = try await fixture.runHelper("role", in: fixture.linkedRoot)
        let localSnapshot = try fixture.localProjectionSnapshot()
        let laterSetup = try await fixture.runHelper(
            "setup-shared",
            in: fixture.linkedRoot,
            environment: ["PATH": "\(spyDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin"])

        // Assert
        #expect(conversion.exitCode == 0, Comment(rawValue: conversion.stderr))
        #expect(localRole.exitCode == 0)
        #expect(localRole.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "local")
        #expect(FileManager.default.fileExists(atPath: unrelatedSentinel.path))
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: unrelatedSentinel.path)
                == fixture.primaryFrameworkURL.path)
        try fixture.expectCompleteLocalProjection()
        #expect(laterSetup.exitCode == 0, Comment(rawValue: laterSetup.stderr))
        #expect(try fixture.localProjectionSnapshot() == localSnapshot)
        #expect(try fixture.primaryOutputSnapshot() == primaryBefore)
    }
}
