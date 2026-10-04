import AgentStudioInfrastructure
import Foundation
import Testing

/// The first-attempt gate: a re-run of a CI job fails its first step unless its
/// pull request carries the `ci-rerun-approved` label at the time of the re-run.
@Suite("CI first-attempt gate")
struct CIFirstAttemptGateWorkflowTests {
    @Test("every CI job starts with the one anchored first-attempt gate, before checkout")
    func everyCIJobStartsWithTheAnchoredGate() async throws {
        let workflowText = try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)
        // A real YAML parser, so the aliases are resolved exactly as GitHub
        // resolves them. If it cannot parse or resolve them, this throws or the
        // first steps below are not the gate: the test fails, it never skips.
        let workflow = try await parsedWorkflow(at: ".github/workflows/ci.yml")
        let jobs = try #require(workflow["jobs"] as? [String: Any])
        let gateStep = try firstStep(of: "code-quality", in: jobs)
        let anchorDefinitions = workflowText.components(separatedBy: "      - &first-attempt-gate\n").count - 1
        let aliasUses = workflowText.components(separatedBy: "      - *first-attempt-gate\n").count - 1

        #expect(jobs.count == 6)
        #expect(anchorDefinitions == 1)
        #expect(aliasUses == jobs.count - 1)
        #expect(gateStep["name"] as? String == "First-attempt gate")
        for jobName in jobs.keys.sorted() {
            let jobSteps = try steps(of: jobName, in: jobs)
            let jobFirstStep = try #require(jobSteps.first)
            #expect(
                NSDictionary(dictionary: jobFirstStep).isEqual(to: gateStep),
                "\(jobName) does not start with the gate"
            )
            #expect(
                jobSteps.dropFirst().first?["name"] as? String == "Checkout",
                "\(jobName): the gate must precede checkout"
            )
        }
        let permissions = try #require(workflow["permissions"] as? [String: String])
        #expect(permissions["issues"] == "read")
        let gateEnvironment = try #require(gateStep["env"] as? [String: String])
        #expect(gateEnvironment["GH_TOKEN"] == "${{ github.token }}")
        #expect(gateEnvironment["RUN_ATTEMPT"] == "${{ github.run_attempt }}")
        #expect(gateEnvironment["PULL_REQUEST_NUMBER"] == "${{ github.event.pull_request.number }}")
    }

    @Test("the width comparison workflow starts with the same gate, since anchors cannot cross files")
    func widthComparisonWorkflowStartsWithTheSameGate() async throws {
        // A re-run of a dispatch has no pull request to carry the label, so it
        // must fail too; the copy is pinned to the ci.yml step so they cannot drift.
        let ciJobs = try #require(try await parsedWorkflow(at: ".github/workflows/ci.yml")["jobs"] as? [String: Any])
        let widthWorkflow = try await parsedWorkflow(at: ".github/workflows/swift-width-comparison.yml")
        let widthJobs = try #require(widthWorkflow["jobs"] as? [String: Any])
        let gateStep = try firstStep(of: "code-quality", in: ciJobs)
        let widthSteps = try steps(of: "swift-width-comparison", in: widthJobs)
        let widthPermissions = try #require(widthWorkflow["permissions"] as? [String: String])

        #expect(widthJobs.count == 1)
        #expect(NSDictionary(dictionary: try #require(widthSteps.first)).isEqual(to: gateStep))
        #expect(widthSteps.dropFirst().first?["name"] as? String == "Checkout")
        #expect(widthPermissions["issues"] == "read")
    }

    @Test("the gate passes first attempts and labelled re-runs, and fails every other re-run closed")
    func gatePassesFirstAttemptsAndLabelledRerunsOnly() async throws {
        let workflow = try await parsedWorkflow(at: ".github/workflows/ci.yml")
        let jobs = try #require(workflow["jobs"] as? [String: Any])
        let gateScript = try #require(try firstStep(of: "code-quality", in: jobs)["run"] as? String)
        let fixture = try GateFixture(gateScript: gateScript)
        defer { fixture.cleanup() }

        let firstAttempt = try await fixture.run(attempt: 1, event: "pull_request", ghMode: "labels:do not merge")
        let unlabelledRerun = try await fixture.run(attempt: 2, event: "pull_request", ghMode: "labels:do not merge")
        let labelledRerun = try await fixture.run(
            attempt: 2,
            event: "pull_request",
            ghMode: "labels:investigation,ci-rerun-approved"
        )
        let unreadableLabels = try await fixture.run(attempt: 3, event: "pull_request", ghMode: "error")
        let pushRerun = try await fixture.run(attempt: 2, event: "push", ghMode: "labels:ci-rerun-approved")
        let scheduledFirstAttempt = try await fixture.run(attempt: 1, event: "schedule", ghMode: "error")
        let scheduledRerun = try await fixture.run(attempt: 2, event: "schedule", ghMode: "labels:ci-rerun-approved")

        // Attempt 1 never consults the API.
        #expect(firstAttempt.exitCode == 0)
        #expect(!firstAttempt.output.contains("GH_CALLED"))
        // A re-run without the label fails, and the message names the label.
        #expect(unlabelledRerun.exitCode == 1)
        #expect(unlabelledRerun.output.contains("GH_CALLED api --paginate repos/owner/repo/issues/42/labels"))
        #expect(unlabelledRerun.output.contains("Add the 'ci-rerun-approved' label to PR #42"))
        // The label is read live, and only an exact name match passes.
        #expect(labelledRerun.exitCode == 0)
        #expect(labelledRerun.output.contains("allowed by the 'ci-rerun-approved' label"))
        // An API failure fails closed and carries the API's own error.
        #expect(unreadableLabels.exitCode == 1)
        #expect(unreadableLabels.output.contains("fails closed"))
        #expect(unreadableLabels.output.contains("HTTP 403: Resource not accessible by integration"))
        // A re-run of anything but a pull request has no label to read.
        #expect(pushRerun.exitCode == 1)
        #expect(!pushRerun.output.contains("GH_CALLED"))
        #expect(pushRerun.output.contains("'ci-rerun-approved'"))
        #expect(scheduledFirstAttempt.exitCode == 0)
        #expect(!scheduledFirstAttempt.output.contains("GH_CALLED"))
        #expect(scheduledRerun.exitCode == 1)
        #expect(!scheduledRerun.output.contains("GH_CALLED"))
    }
}

/// A fake `gh` on PATH and the gate's `run:` script, extracted from ci.yml.
private struct GateFixture {
    let root: String

    init(gateScript: String) throws {
        root = NSTemporaryDirectory() + "agentstudio-first-attempt-gate-\(UUIDv7.generate())"
        try FileManager.default.createDirectory(atPath: root + "/bin", withIntermediateDirectories: true)
        try gateScript.write(toFile: root + "/gate.sh", atomically: true, encoding: .utf8)
        // FAKE_GH_MODE is `labels:<comma-separated names>` or `error`. The labels
        // are printed one per line, as `--jq '.[].name'` prints them.
        let fakeGitHubCLI = """
            #!/bin/bash
            echo "GH_CALLED $*" >> "$FAKE_GH_CALLS"
            case "$FAKE_GH_MODE" in
              labels:*) printf '%s\\n' "${FAKE_GH_MODE#labels:}" | tr ',' '\\n' ;;
              error) echo "HTTP 403: Resource not accessible by integration" >&2; exit 1 ;;
            esac

            """
        try fakeGitHubCLI.write(toFile: root + "/bin/gh", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root + "/bin/gh")
    }

    func run(attempt: Int, event: String, ghMode: String) async throws -> LaneScriptBashResult {
        let pullRequestNumber = event == "pull_request" ? "42" : ""
        return try await runLaneScriptBash(
            "rm -f '\(root)/calls'; "
                + "PATH='\(root)/bin':$PATH FAKE_GH_MODE='\(ghMode)' FAKE_GH_CALLS='\(root)/calls' "
                + "GH_TOKEN=fake RUN_ATTEMPT=\(attempt) EVENT_NAME=\(event) "
                + "PULL_REQUEST_NUMBER='\(pullRequestNumber)' REPOSITORY=owner/repo "
                + "bash '\(root)/gate.sh'; gate_status=$?; cat '\(root)/calls' 2>/dev/null; exit $gate_status"
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(atPath: root)
    }
}

/// The workflow as GitHub sees it, anchors and aliases resolved, via the
/// system Ruby's YAML parser (present on every macOS host and runner).
private func parsedWorkflow(at path: String) async throws -> [String: Any] {
    let result = try await runLaneScriptBash(
        "/usr/bin/ruby -ryaml -rjson -e 'puts JSON.generate(YAML.load(File.read(ARGV[0])))' '\(path)'"
    )
    guard result.exitCode == 0,
        let json = try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
    else {
        throw GateWorkflowParseError.unparseable(result.output)
    }
    return json
}

private func steps(of jobName: String, in jobs: [String: Any]) throws -> [[String: Any]] {
    let job = try #require(jobs[jobName] as? [String: Any], "missing job \(jobName)")
    return try #require(job["steps"] as? [[String: Any]], "job \(jobName) has no steps")
}

private func firstStep(of jobName: String, in jobs: [String: Any]) throws -> [String: Any] {
    try #require(try steps(of: jobName, in: jobs).first, "job \(jobName) has no first step")
}

private enum GateWorkflowParseError: Error {
    case unparseable(String)
}
