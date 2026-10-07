import HTTPTypes
import Hummingbird

/// A test recorder that receives a Hummingbird response body.
///
/// Recorders stay actors so tests can await frames. They do not conform to
/// `ResponseBodyWriter` themselves: its `finish` is `consuming`, and Swift 6.4
/// (Xcode 27) crashes in SILGen ("leaked owned value") building an actor's
/// witness for that requirement. A value-type writer forwards to them instead.
protocol RecordingResponseBodySink: Actor {
    func write(_ buffer: ByteBuffer) async throws
    func finish(_ trailingHeaders: HTTPFields?) async throws
}

/// Forwards a response body into a `RecordingResponseBodySink` recorder.
struct ForwardingResponseBodyWriter<Sink: RecordingResponseBodySink>: ResponseBodyWriter {
    let sink: Sink

    mutating func write(_ buffer: ByteBuffer) async throws {
        try await sink.write(buffer)
    }

    consuming func finish(_ trailingHeaders: HTTPFields?) async throws {
        try await sink.finish(trailingHeaders)
    }
}
