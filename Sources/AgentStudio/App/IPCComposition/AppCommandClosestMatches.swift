/// Suggestions contain visible command identifiers only, ordered by distance
/// then name. The caller's raw identifier is never included as a suggestion.
enum AppCommandClosestMatches {
    private struct RankedCommandName {
        let name: String
        let distance: Int
    }

    private static let maximumSuggestionCount = 5

    static func find(for identifier: String, visibleNames: [String]) -> [String] {
        let candidates: [String] = visibleNames.filter { $0 != identifier }
        let ranked: [RankedCommandName] = candidates.map { name in
            RankedCommandName(name: name, distance: editDistance(identifier, name))
        }
        let ordered: [RankedCommandName] = ranked.sorted { lhs, rhs in
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            return lhs.name < rhs.name
        }
        return ordered.prefix(Self.maximumSuggestionCount).map { $0.name }
    }

    private static func editDistance(_ first: String, _ second: String) -> Int {
        let firstCharacters = Array(first)
        let secondCharacters = Array(second)
        var previous = Array(0...secondCharacters.count)
        for (firstIndex, firstCharacter) in firstCharacters.enumerated() {
            var current = [firstIndex + 1]
            for (secondIndex, secondCharacter) in secondCharacters.enumerated() {
                current.append(
                    min(
                        min(current[secondIndex] + 1, previous[secondIndex + 1] + 1),
                        previous[secondIndex] + (firstCharacter == secondCharacter ? 0 : 1)))
            }
            previous = current
        }
        return previous[secondCharacters.count]
    }
}
