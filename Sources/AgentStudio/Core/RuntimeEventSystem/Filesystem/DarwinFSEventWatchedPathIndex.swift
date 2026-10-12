/// Immutable component and lexical-prefix indexes over normalized FSEvents paths.
/// Matching sets are prepared once rather than scanning every watched path per event.
struct DarwinFSEventWatchedPathIndex: Sendable {
    private struct PathNode: Sendable {
        var children: [String: Int] = [:]
        var exactPaths: Set<String> = []
        var descendantPaths: Set<String> = []
    }

    private let pathNodes: [PathNode]
    private let strictDescendantPathsByAncestor: [String: Set<String>]

    init(normalizedPaths: [String]) {
        var nodes = [PathNode()]
        var strictPathsByAncestor: [String: Set<String>] = [:]
        for path in normalizedPaths {
            for ancestorPath in Self.lexicalAncestorPaths(of: path) {
                strictPathsByAncestor[ancestorPath, default: []].insert(path)
            }
            var nodeIndex = 0
            nodes[nodeIndex].descendantPaths.insert(path)
            for component in Self.components(of: path) {
                let childIndex: Int
                if let existingIndex = nodes[nodeIndex].children[component] {
                    childIndex = existingIndex
                } else {
                    childIndex = nodes.count
                    nodes.append(PathNode())
                    nodes[nodeIndex].children[component] = childIndex
                }
                nodeIndex = childIndex
                nodes[nodeIndex].descendantPaths.insert(path)
            }
            nodes[nodeIndex].exactPaths.insert(path)
        }
        pathNodes = nodes
        strictDescendantPathsByAncestor = strictPathsByAncestor
    }

    func ancestors(of normalizedPath: String) -> Set<String> {
        lookup(normalizedPath, includingDescendants: false)
    }

    func descendants(of normalizedPath: String) -> Set<String> {
        var nodeIndex = 0
        for component in Self.components(of: normalizedPath) {
            guard let childIndex = pathNodes[nodeIndex].children[component] else { return [] }
            nodeIndex = childIndex
        }
        let matchingPaths = pathNodes[nodeIndex].descendantPaths
        // The lexical rule treats '' as a prefix of absolute paths, but '/' does
        // not contain ''. They share the absolute component node, not equality.
        return normalizedPath == "/" ? matchingPaths.subtracting([""]) : matchingPaths
    }

    func intersectingPaths(with normalizedPath: String) -> Set<String> {
        lookup(normalizedPath, includingDescendants: true)
    }

    /// Matches the exact-item observer's literal `path + "/"` prefix rule.
    func strictDescendants(of normalizedPath: String) -> Set<String> {
        strictDescendantPathsByAncestor[normalizedPath] ?? []
    }

    func containsAncestor(of normalizedPath: String) -> Bool {
        if normalizedPath.isEmpty {
            guard let absoluteNodeIndex = pathNodes[0].children[""] else { return false }
            return pathNodes[absoluteNodeIndex].exactPaths.contains("")
        }
        var nodeIndex = 0
        for component in Self.components(of: normalizedPath) {
            guard let childIndex = pathNodes[nodeIndex].children[component] else { return false }
            nodeIndex = childIndex
            if !pathNodes[nodeIndex].exactPaths.isEmpty { return true }
        }
        return false
    }

    private func lookup(_ normalizedPath: String, includingDescendants: Bool) -> Set<String> {
        var nodeIndex = 0
        var matchingPaths: Set<String> = []
        for component in Self.components(of: normalizedPath) {
            guard let childIndex = pathNodes[nodeIndex].children[component] else { return matchingPaths }
            nodeIndex = childIndex
            matchingPaths.formUnion(pathNodes[nodeIndex].exactPaths)
        }
        if normalizedPath.isEmpty { matchingPaths.remove("/") }
        if includingDescendants { matchingPaths.formUnion(pathNodes[nodeIndex].descendantPaths) }
        return matchingPaths
    }

    private static func lexicalAncestorPaths(of normalizedPath: String) -> [String] {
        let pathScalars = normalizedPath.unicodeScalars
        return pathScalars.indices.compactMap { scalarIndex in
            guard pathScalars[scalarIndex] == "/" else { return nil }
            // A Prepend scalar can join '/', so Character splitting misses it.
            // Extend/ZWJ after '/' can prevent the original prefix from matching.
            let prefix = String(pathScalars[...scalarIndex])
            guard normalizedPath.hasPrefix(prefix) else { return nil }
            return String(pathScalars[..<scalarIndex])
        }
    }

    private static func components(of normalizedPath: String) -> [String] {
        // Preserve the existing lexical normalizer's trailing slash and case
        // semantics. Only '/' is special: it contains every absolute path.
        if normalizedPath == "/" { return [""] }
        return normalizedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    }
}
