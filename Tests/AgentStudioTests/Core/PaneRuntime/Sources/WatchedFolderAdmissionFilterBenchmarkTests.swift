import CoreServices
import Dispatch
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

/// Diagnostic source-filter measurements; correctness never depends on machine speed.
@Suite("Watched folder admission filter benchmark", .serialized)
struct WatchedFolderAdmissionFilterBenchmarkTests {
    @Test("filter reports routine and structural callback cost at owner scale")
    func admissionFilterBenchmark() async throws {
        // Arrange: 270 known checkouts at depth three, matching the owner's watch scale.
        let root = FileManager.default.temporaryDirectory.appending(
            path: "watched-filter-benchmark-\(UUIDv7.generate())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = try FilesystemSourceConfiguration.registerRoot(
            from: .hostAuthorized(
                .init(
                    registration: .init(
                        sourceID: .init(kind: .watchedParentMembership, rootID: UUIDv7.generate()),
                        registrationGeneration: 1, rootGeneration: 1),
                    authorizedBoundary: root, registeredRoot: root)))
        let groups = (0..<270).map { index in
            RepoScanner.RepoScanGroup(
                clonePath: root.appending(path: "org-\(index % 10)/team-\(index % 27)/repo-\(index)"),
                linkedWorktreePaths: [])
        }
        let snapshot = WatchedFolderAdmissionSnapshot(root: descriptor, knownGroups: groups)
        let callbackID = UUIDv7.generate()
        for routine in [true, false] {
            let paths = (0..<300).map { index in
                routine
                    ? groups[index % groups.count].clonePath.appending(path: "Sources/generated-\(index)").path
                    : root.appending(path: "incoming-\(index % 10)/candidate-\(index)").path
            }
            let batch = FSEventBatch(
                worktreeId: callbackID, paths: paths,
                observations: paths.enumerated().map { index, path in
                    .init(
                        path: path, eventID: UInt64(index + 1),
                        flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated))
                })
            var samples: [UInt64] = []
            // Act: each sample measures exactly one source-filter invocation, excluding the oracle.
            for _ in 0..<200 {
                let began = DispatchTime.now().uptimeNanoseconds
                let filtered = WatchedFolderTopologyAdmission.filterBatch(batch, snapshot: snapshot)
                let finished = DispatchTime.now().uptimeNanoseconds
                samples.append(finished - began)
                // Assert: literal relevance oracle; no timing assertion.
                if routine {
                    #expect(filtered == nil)
                } else {
                    #expect(filtered?.paths == paths)
                    #expect(filtered?.observations == batch.observations)
                }
            }
            let summary = await summarizeWatchedFilterMeasurements(samples)
            let scenario = routine ? "routine" : "outside_structure"
            print(
                "WATCHED_FILTER_BENCHMARK scenario=\(scenario) checkouts=270 paths=300 "
                    + "samples=\(summary.sampleCount) median_ns=\(summary.medianNanoseconds) "
                    + "p95_ns=\(summary.p95Nanoseconds)")
        }
    }
}

private struct WatchedFilterMeasurementSummary: Sendable {
    let sampleCount: Int
    let medianNanoseconds: UInt64
    let p95Nanoseconds: UInt64
}

@concurrent
private func summarizeWatchedFilterMeasurements(_ samples: [UInt64]) async -> WatchedFilterMeasurementSummary {
    let ordered = samples.sorted()
    return .init(
        sampleCount: ordered.count, medianNanoseconds: ordered[ordered.count / 2],
        p95Nanoseconds: ordered[ordered.count * 95 / 100])
}
