// The change model: the only contract between the analyzer and the viewer.
// Versioned; consumers must ignore fields they don't know.

public struct ChangeModel: Codable, Equatable {
    public var version: Int = 1
    public var analyzer: AnalyzerInfo
    public var repo: RepoInfo
    public var components: [Component]
    public var edges: [Edge]
    public var externalDeps: [ExternalDepChange]
    public var entities: [Entity]
    public var regions: [Region]
    public var warnings: [Warning]
}

public struct AnalyzerInfo: Codable, Equatable {
    public var version: String
    /// "name-based" (default) or "index" (not implemented yet).
    public var resolution: String
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
    case spmTarget, xcodeTarget, folder, external
}

public struct Component: Codable, Equatable {
    public var id: String
    public var name: String
    public var kind: ComponentKind
    public var layer: String?
    /// Module (Swift module name) the component's code compiles into, if known.
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
    public var contractFlags: [String]
    /// "test", "generated".
    public var tags: [String]
    public var location: Location
    public var baseLocation: Location?
    /// Declarations in other components that reference this entity.
    public var usedBy: [Usage]
    /// Declarations in other components that this entity references.
    public var dependsOn: [Usage]
}

public struct Region: Codable, Equatable {
    public var id: String
    public var entity: String
    public var kind: String
    public var file: String
    public var startLine: Int
    public var endLine: Int
    public var side: Side
    public var risk: Double
    public var reasons: [String]
    public var supports: [String]?
    public var relation: String?
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
