import Foundation

// Index mode: exact references from a language's index instead of name matching. Each language
// that has one (Swift's index store, SCIP from a language's indexer) turns it into a `SideIndex`
// per side. If either side of a language can't be indexed, that language's files are matched by
// name at both sides, so the two sides are always resolved the same way.

public struct IndexOptions: Equatable {
    /// Nil follows `index.enabled` in reviewmap.yml.
    public var enabled: Bool?
    /// "bazel", "xcodebuild", or "swift". Nil picks Bazel for a Bazel workspace with targets (given or from a
    /// rules_xcodeproj rule), else xcodebuild where it exists (macOS), else swift build.
    public var builder: String?
    /// The .xcworkspace, .xcodeproj, or package directory to build: relative to the repo root, relative to
    /// `workingDirectory`, or absolute inside the repo.
    public var project: String?
    public var scheme: String?
    /// xcodebuild destination (default "generic/platform=iOS Simulator").
    public var destination: String?
    /// Bazel targets to build.
    public var targets: [String]?
    /// Extra arguments for `bazel build`.
    public var bazelArgs: [String]?
    /// Where built index stores are kept, one per repo and commit.
    public var cacheDir: String
    /// Build again even when a store for the commit is cached.
    public var rebuild: Bool
    /// Where the command was run. A relative --index-project may be relative to it, and auto-detection
    /// prefers projects under it.
    public var workingDirectory: String?

    public init(enabled: Bool? = nil, builder: String? = nil, project: String? = nil, scheme: String? = nil,
                destination: String? = nil, targets: [String]? = nil, bazelArgs: [String]? = nil,
                cacheDir: String = IndexOptions.defaultCacheDir, rebuild: Bool = false, workingDirectory: String? = nil) {
        self.enabled = enabled
        self.builder = builder
        self.project = project
        self.scheme = scheme
        self.destination = destination
        self.targets = targets
        self.bazelArgs = bazelArgs
        self.cacheDir = cacheDir
        self.rebuild = rebuild
        self.workingDirectory = workingDirectory
    }

    public static var defaultCacheDir: String {
        (AnnotateOptions.home as NSString).appendingPathComponent(".reviewmap/index")
    }

    /// CLI values win over reviewmap.yml.
    func merged(with config: Config.Index?) -> IndexOptions {
        guard let c = config else { return self }
        var o = self
        o.enabled = o.enabled ?? c.enabled
        o.builder = o.builder ?? c.builder
        o.project = o.project ?? c.project
        o.scheme = o.scheme ?? c.scheme
        o.destination = o.destination ?? c.destination
        o.targets = o.targets ?? c.targets
        o.bazelArgs = o.bazelArgs ?? c.bazelArgs
        return o
    }
}

/// A reference from one line of a file to a declaration in the repo, at one side.
struct IndexedRef: Hashable {
    var line: Int
    /// Repo-relative file and line of the referenced declaration's name.
    var targetFile: String
    var targetLine: Int
    /// The index's name for the symbol ("load()", "Config", "id").
    var name: String
}

/// Exact references for the source files of one side. Files missing from `refs` had no index data.
struct SideIndex {
    var refs: [String: [IndexedRef]]
    /// What the index is missing, such as dependencies that couldn't be installed.
    var warnings: [Warning] = []
}

struct IndexError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

/// Small path helpers shared by the analyzer and the CLI.
public enum Paths {
    /// "feature/login" → "feature-login"; anything outside letters, digits, dot, dash, and underscore becomes a dash.
    public static func slug(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let out = String(s.map { allowed.contains($0) ? $0 : "-" })
        return out.isEmpty || out.allSatisfy({ $0 == "." }) ? "-" : out
    }
}
