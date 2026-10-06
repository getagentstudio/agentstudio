/// The hook's give-up limit is distinct from the warm-call performance budget.
package enum CLIPolicy {
    package static let hookCallLimit: Duration = .seconds(2)
}
