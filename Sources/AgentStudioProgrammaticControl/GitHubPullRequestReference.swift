import Foundation

package enum GitHubPullRequestReference {
    package enum Refusal: Error, Equatable {
        case notPullRequest(String)

        package var line: String {
            switch self {
            case .notPullRequest(let input): "not a GitHub pull request: \(input)"
            }
        }
    }

    package static func parse(_ input: String) throws(Refusal) -> IPCPanePullRequestIdentity {
        let owner: String
        let repository: String
        let numberText: String
        if let url = URLComponents(string: input), let scheme = url.scheme {
            guard ["http", "https"].contains(scheme.lowercased()), url.host?.lowercased() == "github.com" else {
                throw .notPullRequest(input)
            }
            let path = url.path.split(separator: "/", omittingEmptySubsequences: false)
            guard path.count >= 5, path[0].isEmpty, path[3] == "pull" else { throw .notPullRequest(input) }
            owner = String(path[1])
            repository = String(path[2])
            numberText = String(path[4])
        } else {
            let reference = input.split(separator: "#", omittingEmptySubsequences: false)
            guard reference.count == 2 else { throw .notPullRequest(input) }
            let slug = reference[0].split(separator: "/", omittingEmptySubsequences: false)
            guard slug.count == 2 else { throw .notPullRequest(input) }
            owner = String(slug[0])
            repository = String(slug[1])
            numberText = String(reference[1])
        }
        guard isRepositoryComponent(owner), isRepositoryComponent(repository),
            !numberText.isEmpty, numberText.utf8.allSatisfy({ (48...57).contains($0) }),
            let number = Int(numberText), number > 0
        else { throw .notPullRequest(input) }
        return IPCPanePullRequestIdentity(
            host: "github.com", owner: owner.lowercased(), repository: repository.lowercased(), number: number)
    }

    private static func isRepositoryComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255
            && value.utf8.allSatisfy { byte in
                (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                    || byte == 45 || byte == 46 || byte == 95
            }
    }
}
