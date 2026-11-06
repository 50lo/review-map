// The change model: the only contract between the analyzer and the viewer.
// Versioned; consumers must ignore fields they don't know.

public struct ChangeModel: Codable, Equatable {
    /// 2: contract flags carry their language's prefix ("swift:codable-shape").
    /// 3: structural review findings; region annotations no longer carry notes or removal candidates.
    public var version: Int = 3
    public var analyzer: AnalyzerInfo
    public var repo: RepoInfo
    public var components: [Component]
    public var edges: [Edge]
    public var externalDeps: [ExternalDepChange]
    public var entities: [Entity]
    public var regions: [Region]
    public var warnings: [Warning]
    /// Structural review: the deterministic checks' findings, then the LLM review's.
    public var findings: [Finding] = []
    /// Set when the LLM annotator ran.
    public var llm: LLMRun? = nil

    enum CodingKeys: String, CodingKey {
        case version, analyzer, repo, components, edges, externalDeps, entities, regions, warnings, findings, llm
    }

    public init(version: Int = 3, analyzer: AnalyzerInfo, repo: RepoInfo, components: [Component], edges: [Edge],
                externalDeps: [ExternalDepChange], entities: [Entity], regions: [Region], warnings: [Warning],
                findings: [Finding] = [], llm: LLMRun? = nil) {
        self.version = version
        self.analyzer = analyzer
        self.repo = repo
        self.components = components
        self.edges = edges
        self.externalDeps = externalDeps
        self.entities = entities
        self.regions = regions
        self.warnings = warnings
        self.findings = findings
        self.llm = llm
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        analyzer = try c.decode(AnalyzerInfo.self, forKey: .analyzer)
        repo = try c.decode(RepoInfo.self, forKey: .repo)
        components = try c.decode([Component].self, forKey: .components)
        edges = try c.decode([Edge].self, forKey: .edges)
        externalDeps = try c.decode([ExternalDepChange].self, forKey: .externalDeps)
        entities = try c.decode([Entity].self, forKey: .entities)
        regions = try c.decode([Region].self, forKey: .regions)
        warnings = try c.decode([Warning].self, forKey: .warnings)
        // Models written before structural review have no findings.
        findings = try c.decodeIfPresent([Finding].self, forKey: .findings) ?? []
        llm = try c.decodeIfPresent(LLMRun.self, forKey: .llm)
    }
}

/// Something the structural review found, anchored to the parts of the map it is about.
public struct Finding: Codable, Equatable {
    /// "<check>:<n>", stable within one model.
    public var id: String
    /// "check" for the deterministic checks, "llm" for the LLM review.
    public var source: String
    /// Deterministic: "cycle", "layering", "new-external", "unused-api", "orphaned", "conformers", "untested".
    /// LLM: "intent", "placement", "missing", "duplicate", "complexity".
    public var kind: String
    /// "high", "medium", or "low".
    public var severity: String
    /// One sentence: what was found.
    public var message: String
    /// The facts behind it, one per line ("the only caller is @MainActor, so this lock guards nothing").
    public var evidence: [String]
    /// What to remove, simplify, or add, when the finding suggests something.
    public var suggestion: String?
    /// Where it shows on the map; the first anchor is the main one.
    public var anchors: [Anchor]
    /// The code it is about, when that is one declaration.
    public var location: Location? = nil
}

/// A component, an edge (from and to), or an entity.
public struct Anchor: Codable, Equatable, Hashable {
    public var component: String?
    public var from: String?
    public var to: String?
    public var entity: String?

    public static func component(_ id: String) -> Anchor { Anchor(component: id) }
    public static func edge(_ from: String, _ to: String) -> Anchor { Anchor(from: from, to: to) }
    public static func entity(_ id: String) -> Anchor { Anchor(entity: id) }
}

/// How the LLM annotator ran. Annotations themselves sit on components, entities, and regions.
public struct LLMRun: Codable, Equatable {
    /// "claude" or "codex".
    public var tool: String
    /// The model passed to the CLI; missing means the CLI's default.
    public var model: String?
    /// File name of the executable that stood in for the tool (--llm-command), such as a fake for tests.
    public var command: String?
    public var promptVersion: String
    /// Batches (one or more per component), how many came fully from the cache, and how many were rejected.
    public var batches: Int
    public var cached: Int
    public var failed: Int
    /// True when the target repo has a REVIEW.md that went into the prompt.
    public var reviewNotes: Bool
    /// The structural review of the whole change: "ok", "cached", "rejected", or "skipped" (nothing to review).
    public var review: String? = nil
    /// Where the change's description came from: "file", "pr" (gh pr view), "commits", or nil when there was none.
    public var description: String? = nil
}

/// A one-line behavior summary written by the LLM.
public struct LLMSummary: Codable, Equatable {
    public var summary: String
}

/// LLM annotation of a region. Review and removed regions get `risk`; context regions get `keep`
/// and, when kept, `rank` (1 is the most needed).
public struct RegionLLM: Codable, Equatable {
    public var risk: Double?
    public var keep: Bool?
    public var rank: Int?
}

public struct AnalyzerInfo: Codable, Equatable {
    public var version: String
    /// "name-based" (default), or "index" when index mode resolved at least one language.
    public var resolution: String
    /// Ids of the languages with source files in the change ("swift").
    public var languages: [String]?
}

public struct RepoInfo: Codable, Equatable {
    public var root: String
    public var base: String
    public var head: String
    public var baseSha: String
    public var headSha: String
    /// True when baseSha is the merge-base of base and head (PR semantics).
    public var usesMergeBase: Bool
}

public enum ComponentKind: String, Codable {
    case spmTarget, xcodeTarget, npmPackage, tsconfig, goPackage, folder, external
}

public struct Component: Codable, Equatable {
    public var id: String
    public var name: String
    public var kind: ComponentKind
    public var layer: String?
    /// Module the component's code compiles into, if known.
    public var module: String?
    /// For components split out of a large target: the target component they came from.
    public var parent: String?
    public var isTest: Bool
    public var paths: [String]
    /// "added" / "removed" when the component exists on one side only.
    public var status: String?
    public var changedEntities: Int
    public var interfaceChanges: Int
    /// 0..1, drives emphasis on the map.
    public var changeScore: Double
    public var llm: LLMSummary? = nil
}

public enum EdgeStatus: String, Codable {
    case added, removed, changed, unchanged
}

public struct Edge: Codable, Equatable {
    public var from: String
    public var to: String
    public var status: EdgeStatus
    /// Referenced symbols that appear only at head / only at base.
    public var symbolsAdded: [String]
    public var symbolsRemoved: [String]
    /// The references that create this edge (capped; differing symbols first).
    public var refs: [Ref]
    public var refCount: Int
}

public enum Side: String, Codable {
    case base, head
}

public struct Ref: Codable, Equatable, Hashable {
    public var file: String
    /// 0 means the reference comes from a manifest (Package.swift / project file) rather than a source line.
    public var line: Int
    public var symbol: String
    public var side: Side
}

public enum EntityKind: String, Codable {
    case `struct`, `class`, `enum`, actor, `protocol`, `extension`
    case `func`, `init`, `var`, `case`, `typealias`
    /// Non-code contract file: Info.plist, entitlements, privacy manifest, Core Data model.
    case file
    /// Target-level build settings (Package.swift swiftSettings, Xcode build settings).
    case target
}

public enum ChangeKind: String, Codable {
    case added, removed, signature, body, modifiers, cosmetic
}

public struct Location: Codable, Equatable {
    public var file: String
    public var startLine: Int
    public var endLine: Int
    public var side: Side
}

public struct Signature: Codable, Equatable {
    public var base: String?
    public var head: String?
}

/// A reference from code in another component to an entity (or from an entity to another component).
public struct Usage: Codable, Equatable, Hashable {
    public var component: String
    /// Qualified name of the declaration that contains the reference (or the referenced declaration for dependsOn).
    public var symbol: String
    public var file: String
    public var line: Int
    /// usedBy: the isolation the reference runs in, when its declaration or an enclosing type says
    /// ("@MainActor", "actor CartStore", "nonisolated").
    public var isolation: String? = nil
    /// usedBy: "base" for a use that only exists at base (a caller the change removed or moved); missing at head.
    public var side: Side? = nil
}

public struct Entity: Codable, Equatable {
    public var id: String
    public var component: String
    public var kind: EntityKind
    public var qualifiedName: String
    /// Entity id of the enclosing declaration, if any (may refer to an unchanged entity that is not listed).
    public var parent: String?
    public var isInterface: Bool
    public var change: ChangeKind
    /// Every aspect that changed, most significant first (e.g. ["signature", "body"]).
    public var changes: [ChangeKind]
    public var signature: Signature
    /// Contract flags, each prefixed with its language's id ("swift:mainactor-added").
    public var contractFlags: [String]
    /// "test", "generated".
    public var tags: [String]
    public var location: Location
    public var baseLocation: Location?
    /// Declarations in other components that reference this entity.
    public var usedBy: [Usage]
    /// Declarations in other components that this entity references.
    public var dependsOn: [Usage]
    /// Added entities: existing declarations with similar names, which the new code may duplicate.
    public var similar: [Usage]? = nil
    public var llm: LLMSummary? = nil
}

/// A line range the reviewer should read. `review` regions are changed head lines, `removed`
/// regions are deleted base lines, and `context` regions are unchanged code that helps to
/// understand the review regions they support.
public struct Region: Codable, Equatable {
    /// "<entity id>/r<n>" for review and removed regions, "<entity id>/c<n>" for context.
    public var id: String
    /// The changed entity the region belongs to (for context: the entity it explains).
    public var entity: String
    /// "review", "removed", or "context".
    public var kind: String
    public var file: String
    public var startLine: Int
    public var endLine: Int
    public var side: Side
    /// 0..1, deterministic. Context regions are 0.
    public var risk: Double
    /// Why the region is risky, most significant first (contract flags verbatim, or short phrases).
    /// For context regions: the declaration shown.
    public var reasons: [String]
    /// Context: the review regions it supports.
    public var supports: [String]?
    /// Context: "definition", "caller", "conformer", "override", or "state".
    public var relation: String?
    /// Context: the component the code belongs to.
    public var component: String?
    /// Context: the lines that matter (signature and referencing lines). Missing means all of them.
    public var lines: [Int]?
    /// Removed regions inside a changed entity: the head line the removed code followed.
    public var anchor: Int?
    public var llm: RegionLLM? = nil
}

public struct ExternalDepChange: Codable, Equatable {
    public var name: String
    public var change: String // added | removed | bumped
    public var from: String?
    public var to: String?
}

public struct Warning: Codable, Equatable, Hashable {
    public var kind: String
    public var message: String
    public var file: String?
    public var line: Int?

    public init(kind: String, message: String, file: String? = nil, line: Int? = nil) {
        self.kind = kind
        self.message = message
        self.file = file
        self.line = line
    }
}
