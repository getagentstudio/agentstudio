typealias IgnoredTestScope = String
enum IgnoredTestFact { case opened }
typealias IgnoredTestFactSink = (IgnoredTestScope, IgnoredTestFact) -> Void

struct IgnoredTestSourceOwner {
    let factSink: IgnoredTestFactSink?

    func eagerlyCreatesTestScope() {
        let scope: IgnoredTestScope = "test-only"
        factSink?(scope, .opened)
    }
}
