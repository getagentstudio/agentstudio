import Dispatch

struct NativeProcessExitSourceMaker: ProcessExitSourceMaking {
    private let queue = DispatchQueue(label: "com.agentstudio.foreground-exit", qos: .utility)
    init() {}
    func makeSource(pid: Int32) throws -> any ProcessExitSource {
        NativeProcessExitSource(
            source: DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue))
    }
}

/// Dispatch owns callback serialization. The watcher owns resume/cancel, each
/// once; the watcher guards callbacks already delivered before cancellation.
private final class NativeProcessExitSource: ProcessExitSource, @unchecked Sendable {
    private let source: any DispatchSourceProcess
    init(source: any DispatchSourceProcess) { self.source = source }
    func setRegistrationHandler(_ handler: @escaping @Sendable () -> Void) {
        source.setRegistrationHandler(handler: handler)
    }
    func setEventHandler(_ handler: @escaping @Sendable () -> Void) { source.setEventHandler(handler: handler) }
    func setCancelHandler(_ handler: @escaping @Sendable () -> Void) { source.setCancelHandler(handler: handler) }
    func resume() { source.resume() }
    func cancel() { source.cancel() }
}
