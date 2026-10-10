typealias DisjunctionScope = String
enum DisjunctionFact { case started }
typealias DisjunctionFactSink = (DisjunctionScope, DisjunctionFact) -> Void

struct BadDisjunctionSinkGate {
    let factSink: DisjunctionFactSink?

    init(factSink: DisjunctionFactSink? = nil) {
        self.factSink = factSink
    }

    func prepare(shouldContinue: Bool) {
        if factSink != nil || shouldContinue {
            let scope = DisjunctionScope()
            factSink?(scope, .started)
        }
    }
}

extension BadDisjunctionSinkGate {}
