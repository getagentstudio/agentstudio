var globalState = 0

struct ProcessState {
    static let shared = ProcessState()
    nonisolated(unsafe) static var counter = 0
    private static var optionalState: Int?
}

struct ComputedSingleton {
    static var shared: ComputedSingleton { ComputedSingleton() }
}
