import Foundation

/// The result of one `zmx list` probe against the whole zmx directory
/// (SR1, SR2; Program Design item 1). `.complete` names every session the
/// probe positively classified; a session absent from a `.complete`
/// inventory is proven absent, never merely unseen. `.unavailable` means the
/// probe itself could not be trusted, so nothing in it may be read as proof
/// of anything — every pane becomes `.unverified` (never `.cold`) on this
/// outcome.
package enum ZmxSessionInventory: Equatable, Sendable {
    case complete([ZmxSessionID: ZmxInventoryEntry])
    case unavailable(ZmxInventoryFailure)
}

/// One session's classification inside a `.complete` inventory. `.alive` and
/// `.refused` are proof (SR2: only proof means dead); `.unresponsive` is not
/// proof of either liveness or death, so a pane that maps to it becomes
/// `.unverified`, never `.cold`.
package enum ZmxInventoryEntry: Equatable, Sendable {
    /// `pid=` from `zmx list`: zmx's pty wrapper process. The shell zmx
    /// spawned is this process's child, never this pid itself.
    case alive(wrapperPid: Int32)
    /// zmx reported `status=cleaning up`: the daemon's socket connection was
    /// definitively refused (`ConnectionRefused`). Proof of death.
    case refused
    /// zmx reported `status=unreachable`: a timeout or an unexpected error
    /// probing that one session. The daemon may simply be busy — not proof
    /// of anything.
    case unresponsive
}

/// Why the whole probe could not produce a `.complete` inventory. None of
/// these describes any individual session; every pane in this launch
/// becomes `.unverified`.
package enum ZmxInventoryFailure: Equatable, Sendable {
    case timedOut
    case exitedNonZero(Int32)
    case unparsable
}

/// Pure parser for `zmx list`'s non-short stdout (SR1, SR2; Program Design
/// item 1). Classifies a successful run's text only: a failed launch,
/// timeout or nonzero exit is `ZmxSessionInventoryProbe`'s concern (S2),
/// never reaches this parser.
///
/// Ground truth is zmx's own `writeSessionLine`
/// (`vendor/zmx/src/util.zig:942-990`, confirmed against the built binary's
/// source 2026-09-30). It prints one line per session, always tab-separated
/// `key=value` tokens with no embedded tabs:
///   - alive: `name=<id>\tpid=<pid>\tclients=<n>\tcreated=<epoch>` then optional
///     `[\tcwd=<cwd>][\tcmd=<cmd>][\tended=<n>[\texit_code=<n>]]`
///     (`name`, `pid`, `clients` and `created` are always present for a
///     successfully probed session; the rest are optional and ignored here)
///   - error: `name=<id>\terr=<ErrorName>\tstatus=cleaning up|unreachable`
///
/// `status=cleaning up` is printed only for `ConnectionRefused`; every other
/// probe error (a timeout, an unexpected error) prints `status=unreachable`
/// (`util.zig:964-977`). The expected classification comes from that
/// mapping, not from this parser re-deriving it.
///
/// When run from inside an existing zmx session, `writeSessionLine` prefixes
/// the current session's line with an arrow, and every other line with two
/// spaces (`util.zig:948-953`). `ZmxSessionInventoryProbe` never runs inside
/// an attached session, so this should never appear in practice, but the
/// parser strips it defensively rather than fail a real inventory over an
/// unexpected prefix.
///
/// A line matching neither shape means the output can't be trusted: the
/// whole inventory becomes `.unavailable(.unparsable)` rather than a
/// `.complete` inventory that silently omits a session it couldn't read
/// (SR2: only proof means dead — an inventory that might be incomplete is
/// not proof of anything).
enum ZmxSessionInventoryParser {
    static func parse(stdout: String) -> ZmxSessionInventory {
        var entries: [ZmxSessionID: ZmxInventoryEntry] = [:]
        for rawLine in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let (sessionID, entry) = parseLine(line) else {
                return .unavailable(.unparsable)
            }
            entries[sessionID] = entry
        }
        return .complete(entries)
    }

    private static func parseLine(_ line: String) -> (ZmxSessionID, ZmxInventoryEntry)? {
        let rawTokens = line.split(separator: "\t").map(String.init)
        guard !rawTokens.isEmpty else { return nil }

        var fields: [String: String] = [:]
        for (index, rawToken) in rawTokens.enumerated() {
            let token = index == 0 ? strippingCurrentSessionPrefix(rawToken) : rawToken
            guard let equalsIndex = token.firstIndex(of: "=") else { return nil }
            let key = String(token[token.startIndex..<equalsIndex])
            let value = String(token[token.index(after: equalsIndex)...])
            fields[key] = value
        }

        guard let name = fields["name"], let sessionID = ZmxSessionID(restoring: name) else { return nil }

        if let status = fields["status"] {
            switch status {
            case "cleaning up":
                return (sessionID, .refused)
            case "unreachable":
                return (sessionID, .unresponsive)
            default:
                return nil
            }
        }

        guard let pidText = fields["pid"], let wrapperPid = Int32(pidText),
            fields["clients"] != nil, fields["created"] != nil
        else { return nil }
        return (sessionID, .alive(wrapperPid: wrapperPid))
    }

    /// Drops a leading `"→ "` or `"  "` current-session marker so the first
    /// token still starts at `name=`. Returns the token unchanged when no
    /// `name=` substring is found, so a genuinely malformed first token still
    /// fails to parse instead of being silently accepted.
    private static func strippingCurrentSessionPrefix(_ token: String) -> String {
        guard let range = token.range(of: "name=") else { return token }
        return String(token[range.lowerBound...])
    }
}
