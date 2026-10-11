typealias NilGateScope = String
enum NilGateFact { case started }
typealias NilGateFactSink = (NilGateScope, NilGateFact) -> Void

struct BadNilSinkScopeGate {
    let factSink: NilGateFactSink?

    func recordObservationOnlyScope() {
        if factSink == nil {
            _ = Self.makeScope()
        }
    }

    private static func makeScope() -> NilGateScope { "scope" }
}
