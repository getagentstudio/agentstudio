package struct PaneMessageChipModel: Equatable, Sendable {
    package let count: Int
    package let tone: PaneContextChipTone
    package let countIncludingInformational: Int
    package let toneIncludingInformational: PaneContextChipTone
    package init(
        count: Int, tone: PaneContextChipTone, countIncludingInformational: Int,
        toneIncludingInformational: PaneContextChipTone
    ) {
        self.count = count
        self.tone = tone
        self.countIncludingInformational = countIncludingInformational
        self.toneIncludingInformational = toneIncludingInformational
    }
}
