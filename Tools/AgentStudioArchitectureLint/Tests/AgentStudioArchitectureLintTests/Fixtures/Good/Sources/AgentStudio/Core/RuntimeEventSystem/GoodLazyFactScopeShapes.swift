enum GoodObservationScope {
    case opened, validation
    case attempt(Int)
}
enum GoodObservationFact { case opened }
typealias GoodObservationFactSink = (GoodObservationScope, GoodObservationFact) -> Void

struct GoodValidationRequest {
    var validationScope: GoodObservationScope { .validation }
}

struct GoodLazyFactScopeOwner {
    let factSink: GoodObservationFactSink?

    func reportValidation(_ request: GoodValidationRequest) {
        factSink?(request.validationScope, .opened)
    }

    func reportPreparedScope() {
        let scope = makeScope()
        factSink?(scope ?? .opened, .opened)
    }

    func reportScopeAfterGuard() {
        guard let factSink else { return }
        let scope: GoodObservationScope = .attempt(2)
        factSink(scope, .opened)
    }

    func reportScopeInsideIf() {
        if let factSink {
            let scope: GoodObservationScope = .attempt(3)
            factSink(scope, .opened)
        }
    }

    func reportScopeAsSinkArgument() {
        factSink?(GoodObservationScope.attempt(4), .opened)
    }

    func reportScopeFromOptionalMap() {
        let scope = factSink.map { _ in GoodObservationScope.attempt(5) }
        _ = scope
    }

    private func makeScope() -> GoodObservationScope? {
        guard let factSink else { return nil }
        let scope = GoodObservationScope.attempt(1)
        factSink(scope, .opened)
        return scope
    }
}

struct GoodStoreScope {
    let generation: Int
}

enum GoodStoreFact { case saved }
typealias GoodStoreFactSink = (GoodStoreScope, GoodStoreFact) -> Void

struct GoodStoreScopeOwner {
    let factSink: GoodStoreFactSink?

    func saveAfterGuard() {
        guard let factSink else { return }
        let scope = GoodStoreScope(generation: 1)
        factSink(scope, .saved)
    }

    func saveInsideIf() {
        if let factSink {
            let scope: GoodStoreScope = .init(generation: 2)
            factSink(scope, .saved)
        }
    }

    func saveAsSinkArgument() {
        factSink?(GoodStoreScope(generation: 3), .saved)
    }
}
