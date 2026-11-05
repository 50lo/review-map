import Foundation

/// What a language plugs into the language-neutral core. The core exports both trees, matches
/// declarations, resolves references, and builds edges, regions, and the model. A language supplies
/// what depends on its syntax, its build system, and its platform.
protocol Language {
    /// Short id, also the prefix of its contract flags ("swift" makes "swift:codable-shape").
    var id: String { get }
    /// Name used in prose, such as the LLM prompt.
    var displayName: String { get }

    // MARK: Parsing

    /// Source files the language parses. Manifests are read by `addComponents`, not parsed.
    func isSource(_ path: String) -> Bool
    func parse(path: String, source: String) -> ParsedFile
    /// Glob patterns of generated source files, on top of the ones in reviewmap.yml.
    var generatedPatterns: [String] { get }

    // MARK: Components

    /// Adds the components the language's manifests declare (targets, packages) and assigns their files
    /// in `layout.fileComponent`. Files left unassigned become folder components.
    func addComponents(root: String, files: [String], options: AnalyzeOptions, layout: inout ComponentLayout)
    /// Modules that come with the platform: importing one is neither an edge nor a warning.
    var platformModules: Set<String> { get }
    /// Versions of third-party packages pinned by the language's lockfiles, by package identity.
    func pinnedPackages(blobs: [String: String], dir: String) -> [String: String]
    /// The pinned package a module belongs to, for modules the manifests list by name only.
    func package(ofModule module: String, pinned: Set<String>) -> String?

    // MARK: Contracts and risk

    /// Contract flags of the language's matched declarations (indices into `builder.pairs`), without the prefix.
    func contractFlags(_ builder: ModelBuilder, pairs: [Int]) -> [Int: [String]]
    /// A non-code file that is part of a contract (a plist, a data model): the path it is reported under,
    /// and its flag.
    func contractFile(_ path: String) -> (key: String, flag: String)?
    /// More flags for a contract file that exists at both sides, read from its two versions.
    func contractFileFlags(key: String, flag: String, basePath: String, headPath: String) -> [String]
    /// The flag of a changed target build setting.
    func settingFlag(_ key: String) -> String
    /// The risk weight of one of the language's contract flags.
    func flagRisk(_ flag: String, isInterface: Bool) -> Double
    /// View code, where control flow is mostly layout. `inherits` holds what the enclosing type and,
    /// for a type, the type itself conform to or inherit from.
    func isViewCode(_ decl: Decl, inherits: Set<String>) -> Bool

    // MARK: Resolution

    /// Exact references for each side, or nil when the language has no index. Throws when a side can't
    /// be indexed, and then the language's files are matched by name at both sides.
    func index(options: IndexOptions, repoRoot: String, sides: [IndexSide], log: (String) -> Void) throws -> [Side: SideIndex]?
}

/// One side to index: its commit, the exported tree, and the language's source files in it.
struct IndexSide {
    var side: Side
    var sha: String
    var dir: String
    var files: [String]
}

/// Risk weights of region signals.
enum RiskWeight {
    static let high = 0.6
    static let medium = 0.3
    static let base = 0.1
}

enum Languages {
    static let all: [Language] = [SwiftLanguage(), TypeScriptLanguage()]

    /// The language that parses `path`, if any.
    static func of(_ path: String) -> Language? {
        all.first { $0.isSource(path) }
    }

    static func named(_ id: String) -> Language? {
        all.first { $0.id == id }
    }

    static func displayName(_ id: String) -> String {
        named(id)?.displayName ?? id
    }

    /// Splits "swift:codable-shape" into the language and the flag; nil when the flag has no known prefix.
    static func split(flag: String) -> (language: Language, name: String)? {
        guard let colon = flag.firstIndex(of: ":"), let lang = named(String(flag[..<colon])) else { return nil }
        return (lang, String(flag[flag.index(after: colon)...]))
    }
}
