import AgentStudioInfrastructure
import AgentStudioTestHarness
import Darwin
import Dispatch
import Foundation
import Synchronization

enum ForegroundFIFOTransferFailure: Error, Equatable {
    case zeroProgressWrite(bytesWritten: Int, expectedBytes: Int)
    case prematureEOF(bytesRead: Int, expectedBytes: Int)
    case unexpectedJobControlReply(expected: String, actual: String)
    case ownerExited(Int32)
    case ownerObservationEnded
    case protocolProducerExited
    case frameTooLarge
}

/// Holding both ends makes open finite. Reads still retire on the actual producer's terminal fact.
@concurrent nonisolated func openForegroundFIFO(path: String) async throws -> Int32 {
    let descriptor = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return descriptor
}

@concurrent nonisolated func writeForegroundFIFO(descriptor: Int32, bytes: Data) async throws {
    // These are small protocol frames, not a general stream writer.
    guard bytes.count <= 256 else { throw ForegroundFIFOTransferFailure.frameTooLarge }
    let count = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    guard count == bytes.count else {
        throw ForegroundFIFOTransferFailure.zeroProgressWrite(bytesWritten: count, expectedBytes: bytes.count)
    }
}

@concurrent nonisolated func readForegroundBytes(
    descriptor: Int32, byteCount: Int, owner: ResumeZmxProcessDriver
) async throws -> Data {
    guard byteCount > 0, byteCount <= 256 else { throw ForegroundFIFOTransferFailure.frameTooLarge }
    let transfer = try ForegroundFIFORead(descriptor: descriptor, byteCount: byteCount)
    let retirement = Task {
        for await status in owner.observeExit() {
            transfer.fail(ForegroundFIFOTransferFailure.ownerExited(status))
            return
        }
        if !Task.isCancelled { transfer.fail(ForegroundFIFOTransferFailure.ownerObservationEnded) }
    }
    do {
        let result = try await transfer.value()
        retirement.cancel()
        await retirement.value
        return result
    } catch {
        retirement.cancel()
        await retirement.value
        throw error
    }
}

/// State is mutex-protected. value() returns only after native source cancellation acknowledges retirement.
private final class ForegroundFIFORead: @unchecked Sendable {
    private struct ReadState {
        var bytes = Data()
        var result: Result<Data, any Error>?
    }
    private enum ReadFact: Sendable { case completed(Result<Data, any Error>) }
    private let scope = UUIDv7.generate()
    private let facts: FactRecorder<UUID, ReadFact>
    private let factSource: LocalFactSource<UUID, ReadFact>
    private let descriptor: Int32
    private let byteCount: Int
    private let source: any DispatchSourceRead
    private let state = Mutex(ReadState())

    init(descriptor: Int32, byteCount: Int) throws {
        factSource = LocalFactSource(
            vocabulary: FactVocabulary<UUID, ReadFact>(
                describeScope: { $0.uuidString },
                describeFact: { _ in "FIFO transfer completed after native cancellation" },
                isClosing: { _, _ in true }))
        facts = try factSource.attach()
        self.descriptor = descriptor
        self.byteCount = byteCount
        source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor, queue: DispatchQueue(label: "r3-foreground-fifo", qos: .utility))
        source.setEventHandler { [weak self] in self?.readAvailableBytes() }
        source.setCancelHandler { [weak self] in self?.sourceDidCancel() }
    }

    func value() async throws -> Data {
        // Cancellation requests native retirement; this retained reception must
        // still join its acknowledgement before the descriptor can be closed.
        let reception = Task { [facts, scope] in
            try await facts.expectNext(in: scope, where: { _ in true }, "owned FIFO read retirement")
        }
        return try await withTaskCancellationHandler {
            // Even an early owner exit cancels a source that still needs its one resume.
            source.resume()
            do {
                let fact = try await reception.value
                try await facts.finish()
                switch fact {
                case .completed(let result): return try result.get()
                }
            } catch {
                try? await facts.finish()
                throw error
            }
        } onCancel: {
            self.fail(CancellationError())
        }
    }

    func fail(_ error: any Error) { complete(.failure(error)) }

    private func complete(_ result: Result<Data, any Error>) {
        let first = state.withLock { state in
            guard state.result == nil else { return false }
            state.result = result
            return true
        }
        if first { source.cancel() }
    }

    private func sourceDidCancel() {
        let result = state.withLock { $0.result ?? .failure(CancellationError()) }
        factSource.sink(scope, .completed(result))
    }

    private func readAvailableBytes() {
        // Every iteration consumes bytes; EAGAIN returns to the native readiness source.
        while true {
            let remaining = state.withLock { state in state.result == nil ? byteCount - state.bytes.count : 0 }
            guard remaining > 0 else { return }
            var bytes = [UInt8](repeating: 0, count: remaining)
            let count = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                guard !bytes.prefix(count).contains(0) else {
                    fail(ForegroundFIFOTransferFailure.protocolProducerExited)
                    return
                }
                let result = state.withLock { state -> Data? in
                    guard state.result == nil else { return nil }
                    state.bytes.append(contentsOf: bytes.prefix(count))
                    return state.bytes.count == byteCount ? state.bytes : nil
                }
                if let result {
                    complete(.success(result))
                    return
                }
            } else if count == 0 {
                let received = state.withLock { $0.bytes.count }
                fail(ForegroundFIFOTransferFailure.prematureEOF(bytesRead: received, expectedBytes: byteCount))
                return
            } else if errno == EAGAIN {
                return
            } else {
                fail(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                return
            }
        }
    }
}

final class ForegroundFIFOGroup: Sendable {
    private let handles = Mutex<[ForegroundFIFOHandle]>([])
    func add(_ handle: ForegroundFIFOHandle) { handles.withLock { $0.append(handle) } }
    func closeAll() {
        let owned = handles.withLock { handles in
            defer { handles.removeAll() }
            return handles
        }
        for handle in owned { handle.closeOnce() }
    }
}

final class ForegroundFIFOHandle: Sendable {
    private let state: Mutex<Int32?>
    init(_ descriptor: Int32) { state = Mutex(descriptor) }
    deinit { closeOnce() }
    func descriptor() throws -> Int32 {
        try state.withLock { descriptor in
            guard let descriptor else { throw POSIXError(.EBADF) }
            return descriptor
        }
    }
    func closeOnce() {
        let descriptor = state.withLock { descriptor in
            defer { descriptor = nil }
            return descriptor
        }
        if let descriptor { close(descriptor) }
    }
}
