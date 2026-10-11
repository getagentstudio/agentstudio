typealias OwnerObservationScope = String
enum OwnerObservationFact { case started }
typealias OwnerObservationFactSink = (OwnerObservationScope, OwnerObservationFact) -> Void

struct OwnerWithNoOpFactSinkDefault {
    let factSink: OwnerObservationFactSink

    init(factSink: @escaping OwnerObservationFactSink = { _, _ in }) {
        self.factSink = factSink
    }
}

extension OwnerWithNoOpFactSinkDefault {}
