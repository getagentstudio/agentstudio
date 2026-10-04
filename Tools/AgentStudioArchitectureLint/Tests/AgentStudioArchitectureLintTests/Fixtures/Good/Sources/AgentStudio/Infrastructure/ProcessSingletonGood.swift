let globalValue = "constant"

struct ScopedValues {
    static let tags: Set<String> = ["tag"]
    static let title = "title"
    static let count = 1
    static var computedValue: Int { 1 }
    @TaskLocal static var requestContext: String?
    var instanceState = 0
    func work() { var localState = 0 }
}
