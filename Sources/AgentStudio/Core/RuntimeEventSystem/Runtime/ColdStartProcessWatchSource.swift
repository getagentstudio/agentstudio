import Dispatch

/// A3 (test technique, Lead 2026-10-01): the minimal process-watch source
/// surface `ColdStartObserver.beginSetsidWatch`/`beginHandoffWatch` actually
/// use — narrower than the full `DispatchSourceProtocol`, so a test double
/// can implement it directly and record `resume()`/`cancel()`/handler
/// installs, proving source ownership (who got cancelled, who got created,
/// in what order) as a direct fact instead of inferring it from real kernel
/// or queue timing, which the SDK does not specify precisely enough to test
/// against (source.h says nothing about an already-submitted registration
/// handler's fate after `cancel()`).
///
/// `setEventHandler`'s handler receives `exitFired` directly — whether the
/// event that fired included `NOTE_EXIT` — matching exactly how
/// `ColdStartObserver`'s own handlers already read `source.data.contains(.exit)`
/// at the moment their event fires.
package protocol ColdStartProcessWatchSource: AnyObject, Sendable {
    func setEventHandler(_ handler: @escaping @Sendable (_ exitFired: Bool) -> Void)
    func setCancelHandler(_ handler: @escaping @Sendable () -> Void)
    func setRegistrationHandler(_ handler: @escaping @Sendable () -> Void)
    func resume()
    func cancel()
}

/// Creates one process-watch source. Injected into `ColdStartObserver` so a
/// test can supply a double; production's own default wraps the real
/// `DispatchSource.makeProcessSource`.
package typealias ColdStartProcessWatchSourceMaker =
    @Sendable (
        _ identifier: Int32, _ eventMask: DispatchSource.ProcessEvent, _ queue: DispatchQueue
    ) -> any ColdStartProcessWatchSource

/// Production's own `ColdStartProcessWatchSource`: a thin adapter over a
/// real `DispatchSourceProcess`, delegating every call — the exact shape
/// `ColdStartObserver` already used before this seam existed.
private final class RealColdStartProcessWatchSource: ColdStartProcessWatchSource, @unchecked Sendable {
    private let source: DispatchSourceProcess

    init(identifier: Int32, eventMask: DispatchSource.ProcessEvent, queue: DispatchQueue) {
        source = DispatchSource.makeProcessSource(identifier: identifier, eventMask: eventMask, queue: queue)
    }

    func setEventHandler(_ handler: @escaping @Sendable (Bool) -> Void) {
        source.setEventHandler { [source] in handler(source.data.contains(.exit)) }
    }

    func setCancelHandler(_ handler: @escaping @Sendable () -> Void) {
        source.setCancelHandler(handler: handler)
    }

    func setRegistrationHandler(_ handler: @escaping @Sendable () -> Void) {
        source.setRegistrationHandler(handler: handler)
    }

    func resume() {
        source.resume()
    }

    func cancel() {
        source.cancel()
    }
}

/// Production default for `ColdStartObserver`'s injected
/// `processWatchSourceMaker`. A named function, not a closure literal --
/// swift-format and SwiftLint disagreed over every line-wrapped closure
/// form tried here (swift-format wraps the parameter list onto its own
/// line past the width limit; SwiftLint's closure_parameter_position then
/// rejects that exact wrapping), so this sidesteps the conflict entirely.
package func makeDefaultColdStartProcessWatchSource(
    identifier: Int32, eventMask: DispatchSource.ProcessEvent, queue: DispatchQueue
) -> any ColdStartProcessWatchSource {
    RealColdStartProcessWatchSource(identifier: identifier, eventMask: eventMask, queue: queue)
}

package let defaultColdStartProcessWatchSourceMaker: ColdStartProcessWatchSourceMaker =
    makeDefaultColdStartProcessWatchSource
