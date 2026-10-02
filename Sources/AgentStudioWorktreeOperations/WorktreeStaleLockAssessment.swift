import AgentStudioGit
import Foundation

package enum WorktreeGitProcessProbeResult: Sendable, Equatable {
    case found
    case notFound
    case unavailable
}

package protocol WorktreeGitProcessProbing: Sendable {
    func probe() -> WorktreeGitProcessProbeResult
}

package struct WorktreeStaleLockAssessmentResult: Sendable {
    package let observation: WorktreeLockObservation
    fileprivate let fileIdentity: FileIdentity?

    fileprivate struct FileIdentity: Sendable, Equatable {
        let device: UInt64
        let inode: UInt64
        let modificationDate: Date
    }
}

package struct WorktreeStaleLockAssessment: Sendable {
    private let processProbe: any WorktreeGitProcessProbing

    package init(processProbe: any WorktreeGitProcessProbing = SystemWorktreeGitProcessProbe()) {
        self.processProbe = processProbe
    }

    package func inspect(
        _ fact: GitLockFact,
        now: Date = Date()
    ) -> WorktreeStaleLockAssessmentResult {
        let lockPath = fact.path.standardizedFileURL
        let identity = Self.fileIdentity(at: lockPath)
        let processResult = processProbe.probe()
        let ageSeconds = identity.map { Self.ageSeconds(since: $0.modificationDate, now: now) } ?? 0
        let looksStale =
            identity != nil
            && processResult == .notFound
            && Duration.seconds(ageSeconds) >= WorktreeLifecyclePolicy.staleLockAge
        return WorktreeStaleLockAssessmentResult(
            observation: WorktreeLockObservation(
                path: lockPath.path,
                resource: fact.resource,
                ageSeconds: ageSeconds,
                gitProcessFound: processResult == .found,
                looksStale: looksStale
            ),
            fileIdentity: identity
        )
    }

    package func removeIfStillStale(
        _ assessment: WorktreeStaleLockAssessmentResult,
        lockPath: URL,
        now: Date = Date()
    ) -> Bool {
        guard assessment.observation.looksStale,
            let expectedIdentity = assessment.fileIdentity,
            processProbe.probe() == .notFound,
            let currentIdentity = Self.fileIdentity(at: lockPath.standardizedFileURL),
            currentIdentity == expectedIdentity,
            Duration.seconds(Self.ageSeconds(since: currentIdentity.modificationDate, now: now))
                >= WorktreeLifecyclePolicy.staleLockAge
        else {
            return false
        }

        do {
            try FileManager.default.removeItem(at: lockPath.standardizedFileURL)
            return true
        } catch {
            return false
        }
    }

    private static func fileIdentity(at path: URL) -> WorktreeStaleLockAssessmentResult.FileIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            let modificationDate = attributes[.modificationDate] as? Date
        else {
            return nil
        }
        return WorktreeStaleLockAssessmentResult.FileIdentity(
            device: device,
            inode: inode,
            modificationDate: modificationDate
        )
    }

    private static func ageSeconds(since modificationDate: Date, now: Date) -> Int64 {
        Int64(max(0, now.timeIntervalSince(modificationDate).rounded(.down)))
    }
}

private struct SystemWorktreeGitProcessProbe: WorktreeGitProcessProbing {
    func probe() -> WorktreeGitProcessProbeResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "git"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .unavailable
        }

        switch process.terminationStatus {
        case 0:
            return .found
        case 1:
            return .notFound
        default:
            return .unavailable
        }
    }
}
