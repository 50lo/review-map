import Foundation

// What the helper sends to the Rust core for one parsed Swift file. The shapes follow the core's
// `parse::ParsedFile` (crates/core/src/parse/mod.rs); change both together and bump `helperVersion`.

/// Part of the syntax cache key: bump it whenever the parse output for the same source can change.
let helperVersion = "swift-helper-1+swift-syntax-602.0.0"

enum ReviewItemKind: String, Codable {
    case `struct`, `class`, `enum`, actor, `protocol`, `extension`
    case `func`, `init`, `var`, `case`, `typealias`
    case file
    case target
}

/// A declaration found in one source file at one side of the change.
struct Declaration: Codable {
    var kind: ReviewItemKind
    /// Simple name ("add", "init", "CartService"); for extensions the extended type.
    var name: String
    /// Human-readable qualified name: "CartService.add(item:)", "extension CartService: Sendable".
    var qualifiedName: String
    /// Qualified name of the enclosing type scope ("CartService"), nil at top level.
    var scope: String?
    var parentIndex: Int?
    /// Name plus argument labels, used to match overloads: "add(item:)".
    var labelsKey: String
    var signatureDisplay: String
    /// Trivia-free header tokens without attributes and modifiers.
    var signatureCanon: String
    /// Trivia-free attributes + modifiers.
    var modifiersCanon: String
    /// Trivia-free body tokens (empty for containers: their members are compared one by one).
    var bodyCanon: String
    /// Raw text of the declaration (header only for containers), used to detect cosmetic-only changes.
    var rawText: String
    var access: String?
    var attributes: [String]
    var modifiers: [String]
    var inherited: [String]
    var isAsync = false
    var isThrows = false
    var throwsType: String?
    var isStored = false
    var isStatic = false
    var typeAnnotation: String?
    /// Declared inside a protocol (a requirement).
    var inProtocol = false
    /// Kind of the enclosing container, if any.
    var parentKind: ReviewItemKind?
    var startLine: Int
    var endLine: Int
    /// Last line of the declaration's header: the line of the opening brace of its body or members.
    var headerEndLine: Int = 0
    var traits: Set<String> = []
}

struct NameRef: Hashable, Codable {
    var name: String
    var line: Int
    var source: String? = nil
    var module: String? = nil
}

/// A construct on one line that matters for risk: a crash point, a check, a branch, a concurrency
/// primitive (a task, a continuation, a lock), or an isolation annotation in code.
struct LineMark: Hashable, Codable {
    enum Kind: String, Codable { case crash, check, flow, concurrency, isolation }
    var kind: Kind
    var label: String
}

struct ParsedFile: Encodable {
    var path: String
    var language: String
    var decls: [Declaration]
    var imports: [NameRef]
    /// Free identifiers and type names (candidates for cross-component references).
    var typeRefs: [NameRef]
    /// Names used after a dot (`x.foo`), for member-level usage.
    var memberRefs: [NameRef]
    /// Risk-relevant constructs per line (crash points, checks, branches, concurrency).
    var marks: [Int: [LineMark]] = [:]

    enum CodingKeys: String, CodingKey { case path, language, decls, imports, typeRefs, memberRefs, marks }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(language, forKey: .language)
        try c.encode(decls, forKey: .decls)
        try c.encode(imports, forKey: .imports)
        try c.encode(typeRefs, forKey: .typeRefs)
        try c.encode(memberRefs, forKey: .memberRefs)
        // Lines as strings, so the JSON object has stable keys on every platform.
        var byLine: [String: [LineMark]] = [:]
        for (line, list) in marks { byLine[String(line)] = list }
        try c.encode(byLine, forKey: .marks)
    }
}
