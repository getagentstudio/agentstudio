/// The hook's give-up limit is distinct from the warm-call performance budget.
package enum CLIPolicy {
    package static let hookCallLimit: Duration = .seconds(2)
    package static let synchronousLifecycleHookLimit: Duration = .milliseconds(250)
    package static let noticeQueueReserve: Duration = .milliseconds(250)
    package static let ordinaryCallLimit: Duration = .seconds(5)
    package static let defaultAskTimeout: Duration = .seconds(60)
    package static let permissionApprovalWindow: Duration = .seconds(60)
    package static var permissionCallLimit: Duration { permissionApprovalWindow + .seconds(2) }
    package static var permissionHookTimeoutSeconds: Double { permissionApprovalWindow / .seconds(1) + 5 }
}
