import Foundation

enum ScrollbackConsoleFailure: Error, LocalizedError {
    case outputEndedBeforeMarker(marker: Data, observed: Data)
    case producerExitedBeforeFIFO(name: String)

    var errorDescription: String? {
        switch self {
        case .outputEndedBeforeMarker(let marker, let observed):
            let awaited = String(reflecting: String(data: marker, encoding: .utf8) ?? "<non-UTF8 marker>")
            let received = String(reflecting: String(data: observed, encoding: .utf8) ?? "<non-UTF8 output>")
            return "Console producer ended before marker \(awaited); observed \(observed.count) bytes: \(received)"
        case .producerExitedBeforeFIFO(let name):
            return "Console producer exited before FIFO rendezvous \(name)"
        }
    }
}
