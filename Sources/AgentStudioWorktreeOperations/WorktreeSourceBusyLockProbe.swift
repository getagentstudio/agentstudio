import Darwin
import Foundation

package enum WorktreeSourceBusyLockProbe {
    /// URLs are concrete files. Pattern expansion belongs to the SDK-backed caller.
    @concurrent
    package static func refusal(lockFiles: [URL]) async -> WorktreeCreationStop? {
        for path in lockFiles {
            let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else {
                let code = errno
                if code == ENOENT {
                    var metadata = stat()
                    if lstat(path.path, &metadata) != 0, errno == ENOENT { continue }
                }
                return .sourceBusyUnknown(path: path.path, errno: code)
            }
            let result = flock(descriptor, LOCK_EX | LOCK_NB)
            let code = errno
            if result == 0 { _ = flock(descriptor, LOCK_UN) }
            _ = close(descriptor)
            if result != 0 {
                return code == EWOULDBLOCK
                    ? .sourceBusy(path: path.path) : .sourceBusyUnknown(path: path.path, errno: code)
            }
        }
        return nil
    }
}
