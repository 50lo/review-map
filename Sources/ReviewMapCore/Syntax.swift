import Foundation

/// A declaration found in one source file at one side of the change. Kinds and fields are shared by
/// every language; a language leaves the ones it has no equivalent for at their defaults.
struct Decl {
    var kind: EntityKind
    /// Simple name ("add", "init", "CartService"); for extensions the extended type.
    var name: String
    /// Human-readable qualified name: "CartService.add(item:)", "extension CartService: Sendable".
    var qualifiedName: String
    /// Qualified name of the enclosing type scope ("CartService"), nil at top level.
    var scope: String?
    var parentIndex: Int?
    var isTopLevel: Bool { parentIndex == nil }
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
    var parentKind: EntityKind?
    var startLine: Int
    var endLine: Int
    /// Last line of the declaration's header: the line of the opening brace of its body or members.
    var headerEndLine: Int = 0
    /// Facts a language records for its own contract flags and risk, outside the compared text
    /// (TypeScript: "optional", "jsx").
    var traits: Set<String> = []

    var isContainer: Bool {
        switch kind {
        case .struct, .class, .enum, .actor, .protocol, .extension: return true
        default: return false
        }
    }
}

struct NameRef: Hashable {
    var name: String
    var line: Int
    /// The file the name was imported from, when the language says: relative to the referring file's directory
    /// and without its extension ("./cart" for `import { Cart } from "./cart.js"`). Parses are shared by files
    /// with the same contents, so the core resolves it against each file's own path.
    var source: String? = nil
    /// The module the name was imported from, when the language says ("@shop/core" for
    /// `import { Cart } from "@shop/core/cart"`).
    /// Empty for a name of the file's own module, which never resolves to another component (Go's unqualified names).
    var module: String? = nil
}

struct ParsedFile {
    var path: String
    /// Id of the language that parsed the file.
    var language: String
    var decls: [Decl]
    var imports: [NameRef]
    /// Free identifiers and type names (candidates for cross-component references).
    var typeRefs: [NameRef]
    /// Names used after a dot (`x.foo`), for member-level usage.
    var memberRefs: [NameRef]
    /// Risk-relevant constructs per line (crash points, checks, branches, concurrency).
    var marks: [Int: [LineMark]] = [:]
    /// The file says it is generated (Go's `// Code generated ... DO NOT EDIT.`), on top of the generated patterns.
    var isGenerated = false

    /// Innermost declaration containing `line`.
    func enclosingDecl(line: Int) -> Decl? {
        var best: Decl?
        for d in decls where d.startLine <= line && line <= d.endLine {
            if let b = best {
                if d.endLine - d.startLine <= b.endLine - b.startLine { best = d }
            } else {
                best = d
            }
        }
        return best
    }

    /// Parent declarations, innermost first, excluding the declaration itself.
    func enclosingDeclarations(of decl: Decl) -> [Decl] {
        var result: [Decl] = []
        var current = decl.parentIndex
        while let i = current {
            let parent = decls[i]
            result.append(parent)
            current = parent.parentIndex
        }
        return result
    }

}

/// A construct on one line that matters for risk: a crash point, a check, a branch, a concurrency
/// primitive (a task, a continuation, a lock), or an isolation annotation in code.
struct LineMark: Hashable {
    enum Kind: String { case crash, check, flow, concurrency, isolation }
    var kind: Kind
    var label: String
}

