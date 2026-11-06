import Foundation

/// What a language plugs into the language-neutral core. The core exports both trees, matches
/// declarations, resolves references, and builds edges, regions, and the change report. A language supplies
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
    /// Whether importing `module` is importing the platform. The default looks it up in `platformModules`.
    func isPlatformModule(_ module: String) -> Bool
    /// Versions of third-party packages pinned by the language's lockfiles, by package identity.
    func pinnedPackages(blobs: [String: String], dir: String) -> [String: String]
    /// The pinned package a module belongs to, for modules the manifests list by name only.
    func package(ofModule module: String, pinned: Set<String>) -> String?

    // MARK: Contracts and risk

    /// Contract flags of the language's matched declarations (indices into `builder.pairs`), without the prefix.
    func contractFlags(_ builder: ChangeReportBuilder, pairs: [Int]) -> [Int: [String]]
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
    func isViewCode(_ decl: Declaration, inherits: Set<String>) -> Bool

    // MARK: Structural review

    /// Whether this declaration is public API. `enclosing` is its parent chain, innermost first;
    /// it excludes the declaration itself. This classifies API for unused-code checks, not usage.
    func isPublicAPI(_ decl: Declaration, enclosing: [Declaration]) -> Bool
    /// Whether a runtime, framework, or language convention may call this declaration without naming
    /// it, by its name or attributes (Swift's `@objc` or `body`, TypeScript's `constructor`). Unused-code
    /// checks skip these, and so do similar-name suggestions. Rules that follow from the shared
    /// declaration shape (initializers, overrides, protocol requirements, possible witnesses) stay in the core.
    func isImplicitlyCalled(_ decl: Declaration) -> Bool
    /// Head declarations that conform to the matched interface. `builder` contains both sides,
    /// all components, and their matched declaration pairs: implicit conformances may need the
    /// base interface's method set even when a type no longer conforms at head.
    /// `requirement` identifies the changed member, or is nil for whole-interface context.
    /// The inheritance-based default preserves the existing check and context lookup rules;
    /// implicit conformance need not require an import.
    /// Implementations are supplied by the language so method-set matching can consider arity.
    func conformers(of interface: Pair, requirement: Pair?, in builder: ChangeReportBuilder,
                    for use: ConformanceUse) -> [Conformer]
    /// The isolation of a reference at a 1-based line, from the language's parsed file facts.
    /// The default is no known isolation.
    func isolation(in file: ParsedFile, line: Int) -> String?

    // MARK: Resolution

    /// Exact references for each side, or nil when the language has no index. Throws when a side can't
    /// be indexed, and then the language's files are matched by name at both sides.
    func index(options: IndexOptions, repoRoot: String, sides: [IndexSide], log: (String) -> Void) throws -> [Side: SideIndex]?
}

extension Language {
    func conformers(of interface: Pair, requirement: Pair?, in builder: ChangeReportBuilder,
                    for use: ConformanceUse) -> [Conformer] {
        let name: String
        switch use {
        case .check: name = interface.any.decl.qualifiedName
        case .context:
            // Preserve the existing lookup spellings: a whole-interface context uses its simple
            // name, while a requirement context uses its enclosing scope (which may be qualified).
            name = requirement.map { $0.any.decl.scope ?? "" } ?? interface.any.decl.name
        }
        if use == .check, let member = requirement?.head?.decl {
            let abstract = interface.any.decl.kind == .class && member.modifiers.contains("abstract")
            // An existing default implementation covers every explicit conformer.
            if !abstract, (builder.headMembers["\(name)|\(member.name)"] ?? []).contains(where: { implementation in
                guard let parent = implementation.decl.parentIndex else { return false }
                return builder.head.files[implementation.file]?.decls[parent].kind == .extension
            }) { return [] }
        }
        var result: [Conformer] = []
        for candidate in builder.inheritors[name] ?? [] {
            if use == .check {
                let component = interface.any.component
                guard candidate.component == component || builder.edgeRefs[.head]?[candidate.component]?[component] != nil else { continue }
            }
            let type = candidate.decl.kind == .extension ? candidate.decl.name : candidate.decl.qualifiedName
            var implementations: [Located] = []
            if let member = requirement?.head?.decl {
                implementations = (builder.headMembers["\(type)|\(member.name)"] ?? []).filter { implementation in
                    switch use {
                    case .check:
                        return implementation.decl.kind == member.kind || ChangeReportBuilder.kindGroup(implementation.decl.kind) == ChangeReportBuilder.kindGroup(member.kind)
                    case .context:
                        return implementation.component == candidate.component
                    }
                }
            }
            result.append(Conformer(declaration: candidate, implementations: implementations))
        }
        return result
    }

    func isolation(in file: ParsedFile, line: Int) -> String? { nil }

    func isPlatformModule(_ module: String) -> Bool { platformModules.contains(module) }
}

/// The two existing consumers use different visibility and member matching rules.
enum ConformanceUse: Hashable { case check, context }

/// A head conformer and its implementations of the requested requirement. An empty implementation
/// list means the requirement is missing; the core never rematches methods the language rejected.
struct Conformer {
    var declaration: Located
    var implementations: [Located]
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
    static let all: [Language] = [SwiftLanguage(), TypeScriptLanguage(), GoLanguage(), RustLanguage()]

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
