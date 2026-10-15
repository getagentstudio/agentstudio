actor HTTPProductControlSequence {
    private var nextRequestSequence = 1

    func takeNextRequestSequence() -> Int {
        defer { nextRequestSequence += 1 }
        return nextRequestSequence
    }
}
