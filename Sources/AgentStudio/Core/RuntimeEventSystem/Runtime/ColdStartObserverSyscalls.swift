import AgentStudioInfrastructure
import Darwin
import Foundation

/// Wraps a raw `errno` value so it can be the failure side of a `Result`
/// (`Int32` alone does not conform to `Error`).
package struct POSIXErrorNumber: Error, Equatable, Sendable {
    package let rawValue: Int32

    package init(_ rawValue: Int32) {
        self.rawValue = rawValue
    }
}

/// The raw Darwin/zmx calls `ColdStartObserver` makes at its two
/// register-then-check stages (Program Design revision 11, item 3): opening
/// the zmx directory for `EVFILT_VNODE` watching and connecting to the new
/// session for its identity, then reading `KERN_PROCARGS2` for the handoff
/// token, which lives in the leader's **arguments** -- macOS returns no
/// environment to a third-party reader for any process (confirmed against
/// XNU's `kern_sysctl.c` and reproduced independently on macOS 26.5 with SIP
/// on), so only argv is ever read here. A seam so tests can inject a
/// specific failure at each boundary without provoking the real syscall or
/// a real zmx daemon into failing -- "a registration error or unreadable
/// process args, injected at the Darwin call boundary with a test double of
/// the syscall wrapper only" (S3 proof list), and the discovery-connect
/// retry (added 2026-09-30) the same way. The real zmx/process paths stay
/// proven against real zmx and real processes elsewhere; this seam exists
/// only for cases otherwise unreachable in a test.
/// Stage 2's answer to "is the leader this exact incarnation, still alive?"
/// -- added 2026-09-30 after `ColdStartObserver.checkForHandoffAndAdvance`'s
/// register-then-check immediate call was found hardcoding `exitFired:
/// false`, so a leader that had already exited before Stage 2 even
/// registered its watch read as `.unobservable` instead of `.failed`.
/// `kill(pid, 0)` is NOT a valid probe here: measured directly against a
/// real zombie (a child that exited but had not yet been reaped),
/// `kill(pid, 0)` returned 0 ("alive"), while `proc_pidinfo
/// (PROC_PIDTBSDINFO)` correctly failed with `ESRCH`.
package enum ColdStartLeaderState: Equatable, Sendable {
    /// `proc_pidinfo` succeeded and its reported start time matches the
    /// discovered incarnation exactly -- the same process, still alive.
    case sameIncarnationAlive
    /// `proc_pidinfo` failed with `ESRCH` (covers both a zombie and an
    /// already-reaped process), or it succeeded but its start time no
    /// longer matches the discovered incarnation (the pid was recycled onto
    /// a different process). Either way, the original leader is gone.
    case exited
    /// `proc_pidinfo` failed some other way -- genuinely couldn't tell.
    case unverifiable(POSIXErrorNumber)
}

package protocol ColdStartObserverSyscalls: Sendable {
    /// Opens `path` (the zmx directory) for `EVFILT_VNODE` watching.
    /// `.failure(errno)` on failure, for `ColdStartUnobservableReason
    /// .watchRegistrationFailed`. Carries `errno` itself rather than
    /// leaving the caller to read the global `errno` later, since that
    /// value does not survive an actor hop reliably.
    func openDirectoryForWatching(path: String) -> Result<Int32, POSIXErrorNumber>

    /// Reads the raw `KERN_PROCARGS2` buffer for `pid` -- only its argument
    /// vector is used; the buffer's environment section, if any, is never
    /// parsed. `.failure(errno)` on any sysctl failure, mapped to
    /// `ColdStartUnobservableReason.processArgsUnreadable`.
    func readProcessArgumentsBuffer(pid: Int32) -> Result<[UInt8], POSIXErrorNumber>

    /// Connects to the new session's socket at `path` and returns its
    /// identity (Program Design item 3, stage 1, amended twice on
    /// 2026-09-30). `.failure(.connectionRefused)` and `.pendingSetsid` are
    /// both "still discovering," never unobservable -- zmx binds the
    /// socket's filesystem path before it calls `listen` (a connect landing
    /// in that gap is refused, not queued), and forkpty's child calls
    /// `setsid` only after that, before its first exec (a connect landing
    /// before that has run sees `.unexpectedProcessParent`/
    /// `.unexpectedProcessGroup`, surfaced here as `.pendingSetsid` with the
    /// terminal pid to watch). Every other failure reaches
    /// `ColdStartObserver`'s existing discovery-settlement logic unchanged.
    func observeSession(path: String, bootID: String) -> ZmxDiscoveryObservation

    /// Classifies `incarnation`'s leader against its own current OS state --
    /// see `ColdStartLeaderState`'s own doc for why this never falls back to
    /// `kill(pid, 0)`.
    func leaderState(of incarnation: ZmxProcessIncarnation) -> ColdStartLeaderState

    /// Closes `descriptor`, the watched directory's file descriptor
    /// `openDirectoryForWatching` opened. R1 gate (Lead 2026-10-01): routed
    /// through the syscalls seam, symmetric with `openDirectoryForWatching`,
    /// so a test can observe the real close as a typed fact instead of
    /// racing a queue drain against `dispatch_source_cancel`'s own
    /// asynchronous deregistration (source.h:512) -- the cancel handler
    /// libdispatch submits to the target queue is not guaranteed to land
    /// before a `sync {}` issued around the same time.
    func closeWatchedDirectory(_ descriptor: Int32)
}

/// The real Darwin implementation. Kept separate from the protocol so a
/// specific-failure test double never has to touch `sysctl`/`open` at all.
package struct DarwinColdStartObserverSyscalls: ColdStartObserverSyscalls {
    package init() {}

    package func openDirectoryForWatching(path: String) -> Result<Int32, POSIXErrorNumber> {
        let descriptor = open(path, O_EVTONLY)
        return descriptor >= 0 ? .success(descriptor) : .failure(POSIXErrorNumber(errno))
    }

    /// Program Design item 3, stage 2 (amended 2026-09-30): reads once into
    /// a buffer sized from a cached `KERN_ARGMAX`, like `ps` does, instead
    /// of a separate size-query `sysctl` followed by a second data-read
    /// `sysctl`. That two-call shape was a TOCTOU: a real exec landing
    /// between the two calls leaves the second call's size stale against
    /// the now-different process image, and the kernel returns `EIO` --
    /// confirmed empirically against real zmx (30/30 EIO occurrences,
    /// always at a live pid mid-exec, `comm` still `zmx` or `sh`, never the
    /// final shell). An `EIO` from the single read here retries immediately,
    /// up to `AppPolicies.Restore.processArgumentsReadAttempts`, with no
    /// sleep or backoff -- the race is on the order of microseconds, not
    /// milliseconds.
    package func readProcessArgumentsBuffer(pid: Int32) -> Result<[UInt8], POSIXErrorNumber> {
        Self.readProcessArgumentsBuffer(
            pid: pid,
            attempts: AppPolicies.Restore.processArgumentsReadAttempts,
            singleRead: Self.singleProcessArgumentsRead
        )
    }

    /// The retry policy alone, with an injectable single read -- a unit
    /// test scripts `singleRead` (EIO then success; EIO for every attempt)
    /// without touching a real process or `sysctl`.
    package static func readProcessArgumentsBuffer(
        pid: Int32,
        attempts: Int,
        singleRead: (Int32) -> Result<[UInt8], POSIXErrorNumber>
    ) -> Result<[UInt8], POSIXErrorNumber> {
        precondition(attempts > 0, "readProcessArgumentsBuffer requires at least one attempt")
        var lastFailure = POSIXErrorNumber(EIO)
        for _ in 0..<attempts {
            switch singleRead(pid) {
            case .success(let buffer): return .success(buffer)
            case .failure(let errorNumber): lastFailure = errorNumber
            }
        }
        return .failure(lastFailure)
    }

    private static func singleProcessArgumentsRead(pid: Int32) -> Result<[UInt8], POSIXErrorNumber> {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: cachedArgumentsMax)
        var size = buffer.count
        let result = buffer.withUnsafeMutableBytes { pointer -> Int32 in
            sysctl(&mib, 3, pointer.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return .failure(POSIXErrorNumber(errno)) }
        return .success(Array(buffer.prefix(size)))
    }

    /// `KERN_ARGMAX` queried once and cached: the kernel-reported maximum
    /// size of a process's combined argument and environment space, the
    /// same bound `ps`/`sysctl(1)` size their own single read against.
    /// Falls back to 256 KiB (macOS's long-standing `ARG_MAX`) if the query
    /// itself fails, which it never has in practice.
    private static let cachedArgumentsMax: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argumentsMax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctl(&mib, 2, &argumentsMax, &size, nil, 0)
        return result == 0 && argumentsMax > 0 ? Int(argumentsMax) : 256 * 1024
    }()

    package func observeSession(path: String, bootID: String) -> ZmxDiscoveryObservation {
        ZmxSessionControl.observeForDiscovery(path: path, bootID: bootID)
    }

    /// `proc_pidinfo(PROC_PIDTBSDINFO)` only, never `kill(pid, 0)` -- see
    /// `ColdStartLeaderState`'s doc for the measured reason.
    package func leaderState(of incarnation: ZmxProcessIncarnation) -> ColdStartLeaderState {
        var information = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let count = proc_pidinfo(incarnation.pid, PROC_PIDTBSDINFO, 0, &information, size)
        guard count == size else {
            let failureErrno = errno
            return failureErrno == ESRCH ? .exited : .unverifiable(POSIXErrorNumber(failureErrno))
        }
        guard information.pbi_start_tvsec == incarnation.startSeconds,
            information.pbi_start_tvusec == incarnation.startMicroseconds
        else {
            // The pid answered, but it's not the same process anymore --
            // recycled onto a new one after the original leader exited.
            return .exited
        }
        return .sameIncarnationAlive
    }

    package func closeWatchedDirectory(_ descriptor: Int32) {
        close(descriptor)
    }
}
