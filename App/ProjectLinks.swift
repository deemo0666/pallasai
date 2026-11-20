import Foundation

enum ProjectLinks {
    /// This Swift project's GitHub `owner/repo`: the one place it is written. Issues, Discussions,
    /// Releases and the update check all derive from it.
    static let slug = "deemo0666/pallas-agent"
    static let repository = URL(string: "https://github.com/" + slug)!
    static let issues = repository.appending(path: "issues")
    static let newIssue = repository.appending(path: "issues/new")
    static let releases = repository.appending(path: "releases")
    static let api = "https://api.github.com/repos/" + slug
    /// Corresponding source for the GPL/LGPL parts the app ships: QEMU, its libraries and the Linux guest.
    static let componentSlug = "deemo0666/pallas-vm"
    static let componentSources = URL(string: "https://github.com/" + componentSlug)!
}
