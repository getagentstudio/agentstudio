import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

private let sandboxArgumentsCall = "$(swift_package_sandbox_arguments)"
private let sandboxScriptPath = "scripts/swift-package-sandbox.sh"
/// Runs only on Linux (it exits elsewhere), where SwiftPM has no sandbox.
private let linuxOnlyScripts: Set<String> = ["install-ci-lint-tools.sh"]

@Suite("Swift package nested sandbox arguments")
struct SwiftPackageSandboxScriptTests {
    @Test("SwiftPM keeps its sandbox where one can be applied, and drops it where one cannot")
    func sandboxArgumentsFollowTheProbe() async throws {
        let fakeToolDirectory = NSTemporaryDirectory() + "agentstudio-sandbox-probe-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: fakeToolDirectory) }
        let output = try await runLaneScriptBash(
            "mkdir -p '\(fakeToolDirectory)'; source \(sandboxScriptPath); "
                + "PATH='\(fakeToolDirectory)':\"$PATH\"; "
                + "printf '#!/bin/sh\\nexit 0\\n' > '\(fakeToolDirectory)/sandbox-exec'; "
                + "chmod +x '\(fakeToolDirectory)/sandbox-exec'; "
                + "echo \"APPLIABLE=[$(swift_package_sandbox_arguments)]\"; "
                + "printf '#!/bin/sh\\necho denied >&2\\nexit 71\\n' > '\(fakeToolDirectory)/sandbox-exec'; "
                + "echo \"NESTED=[$(swift_package_sandbox_arguments)]\"; "
                + "unset CLANG_MODULE_CACHE_PATH; TMPDIR=/private/tmp/agent-tmp/ source \(sandboxScriptPath); "
                + "echo \"MODULE_CACHE=[$CLANG_MODULE_CACHE_PATH]\"; "
                + "printf '#!/bin/sh\\necho Linux\\n' > '\(fakeToolDirectory)/uname'; "
                + "chmod +x '\(fakeToolDirectory)/uname'; "
                + "echo \"LINUX=[$(swift_package_sandbox_arguments)]\""
        )

        #expect(output.exitCode == 0, Comment(rawValue: output.output))
        #expect(output.output.contains("APPLIABLE=[]"), Comment(rawValue: output.output))
        #expect(output.output.contains("NESTED=[--disable-sandbox]"), Comment(rawValue: output.output))
        #expect(output.output.contains("LINUX=[]"), Comment(rawValue: output.output))
        #expect(
            output.output.contains("MODULE_CACHE=[/private/tmp/agent-tmp/agentstudio-clang-module-cache]"),
            Comment(rawValue: output.output)
        )
    }

    @Test("inside a real confining sandbox, SwiftPM's own sandbox is disabled")
    func realConfiningSandboxDisablesSwiftPackageSandbox() async throws {
        // A deny-default profile reproduces the agent sandbox's refusal of a
        // nested sandbox_apply. When this test already runs inside such an
        // agent sandbox, the outer profile cannot be applied either, and the
        // helper is asked directly: both paths are the same claim.
        let confiningProfile =
            "(version 1)(deny default)(allow process-exec)(allow process-fork)(allow file-read*)"
            + "(allow sysctl-read)(allow mach-lookup)(allow signal (target self))"
        let output = try await runLaneScriptBash(
            "if sandbox-exec -p '(version 1)(allow default)' /usr/bin/true >/dev/null 2>&1; then "
                + "sandbox-exec -p '\(confiningProfile)' /bin/bash -c "
                + "'source \(sandboxScriptPath); echo \"CONFINED=[$(swift_package_sandbox_arguments)]\"'; "
                + "else source \(sandboxScriptPath); echo \"CONFINED=[$(swift_package_sandbox_arguments)]\"; fi"
        )

        #expect(output.output.contains("CONFINED=[--disable-sandbox]"), Comment(rawValue: output.output))
    }

    @Test("every SwiftPM call passes the sandbox arguments from a sourced helper")
    func everySwiftPackageCallPassesSandboxArguments() throws {
        // A SwiftPM call on one line: `swift build` / `swift test` followed by a
        // flag, a variable, or a line continuation. Log strings ("requested swift
        // test args") and case patterns (`*"swift test"*`) are not calls.
        let swiftPackageCallPattern = #/(?:^|[^\w-])swift (build|test)(?=\s+(?:--|-c\s|\\\s*$|\$\{|\$\()|\s*\\?\s*$)/#
        var unguardedCalls: [String] = []
        var unsourcedOwners: [String] = []
        let scriptsDirectory = URL(fileURLWithPath: "scripts")
        let scriptNames = try FileManager.default.contentsOfDirectory(atPath: scriptsDirectory.path)
            .filter { $0.hasSuffix(".sh") && !linuxOnlyScripts.contains($0) }
            .sorted()
        var ownersToCheck: [(name: String, text: String)] = []
        for scriptName in scriptNames {
            let text = try String(contentsOf: scriptsDirectory.appending(path: scriptName), encoding: .utf8)
            ownersToCheck.append((name: "scripts/\(scriptName)", text: text))
        }
        let miseConfig = try String(contentsOfFile: ".mise.toml", encoding: .utf8)
        for taskBlock in miseConfig.components(separatedBy: "\n[") {
            let taskName = taskBlock.prefix(while: { $0 != "\n" })
            ownersToCheck.append((name: ".mise.toml [\(taskName)", text: taskBlock))
        }

        for owner in ownersToCheck {
            let callLines = owner.text.components(separatedBy: "\n").filter { line in
                !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") && line.contains(swiftPackageCallPattern)
            }
            guard !callLines.isEmpty else { continue }
            for line in callLines where !line.contains(sandboxArgumentsCall) {
                unguardedCalls.append("\(owner.name): \(line.trimmingCharacters(in: .whitespaces))")
            }
            if !owner.text.contains(sandboxScriptPath) && !owner.text.contains("/swift-package-sandbox.sh") {
                unsourcedOwners.append(owner.name)
            }
        }

        #expect(unguardedCalls.isEmpty, Comment(rawValue: unguardedCalls.joined(separator: "\n")))
        #expect(unsourcedOwners.isEmpty, Comment(rawValue: unsourcedOwners.joined(separator: "\n")))
    }
}
