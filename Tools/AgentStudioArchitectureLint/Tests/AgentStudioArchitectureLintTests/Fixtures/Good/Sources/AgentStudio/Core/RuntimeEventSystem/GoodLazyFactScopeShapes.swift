typealias GoodObservationScope = String
enum GoodObservationFact { case opened }
typealias GoodObservationFactSink = (GoodObservationScope, GoodObservationFact) -> Void

struct GoodValidationRequest {
    var validationScope: GoodObservationScope { "validation" }
}

struct GoodLazyFactScopeOwner {
    let factSink: GoodObservationFactSink?

    func reportValidation(_ request: GoodValidationRequest) {
        factSink?(request.validationScope, .opened)
    }

    func reportPreparedScope() {
        let scope = makeScope()
        factSink?(scope ?? "", .opened)
    }

    private func makeScope() -> GoodObservationScope? {
        guard let factSink else { return nil }
        let scope = GoodObservationScope()
        factSink(scope, .opened)
        return scope
    }
}
