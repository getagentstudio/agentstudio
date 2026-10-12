/// Immutable component index over already-normalized FSEvents watched paths.
/// Descendant sets are prepared once; a lookup visits only the event's components
/// and the matching paths, rather than scanning every watched root.
struct DarwinFSEventWatchedPathIndex: Sendable {
    private struct PathNode: Sendable {
        var children: [String: Int] = [:]
        var exactPaths: Set<String> = []
        var descendantPaths: Set<String> = []
    }

    private let pathNodes: [PathNode]

    init(normalizedPaths: [String]) {
        var nodes = [PathNode()]
        for path in normalizedPaths {
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

    private static func components(of normalizedPath: String) -> [String] {
        // Preserve the existing lexical normalizer's trailing slash and case
        // semantics. Only '/' is special: it contains every absolute path.
        if normalizedPath == "/" { return [""] }
        return normalizedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    }
}
