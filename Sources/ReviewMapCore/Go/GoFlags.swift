import Foundation

/// Go's contract flags: changes to exported API, to interface method sets, and to struct fields that
/// other packages or serialized data depend on.
struct GoFlags {
    let b: ModelBuilder
    /// The Go pairs, as indices into `b.pairs`.
    let indices: [Int]

    init(_ builder: ModelBuilder, pairs: [Int]) {
        b = builder
        indices = pairs
    }

    /// Flags that a member reports on its type too, unless the type itself is new or deleted.
    private static let memberLevel: Set<String> = ["interface-method-added", "interface-method-removed", "interface-method-changed",
                                                   "field-added", "field-removed"]
    /// Struct tag keys that name a field in serialized data.
    static let tagKeys = ["json", "yaml", "xml", "db", "bson", "toml", "protobuf"]

    func compute() -> [Int: [String]] {
        let pairs = b.pairs
        var out: [Int: [String]] = [:]
        var parentFlags: [Int: Set<String>] = [:]
        // Added declarations by component, scope, and name, to tell an exported name that became unexported.
        var addedNames = Set<String>()
        for i in indices where pairs[i].base == nil {
            let h = pairs[i].head!
            addedNames.insert("\(h.component)|\(h.decl.scope ?? "")|\(h.decl.name)")
        }
        for i in indices {
            let p = pairs[i]
            let bd = p.base?.decl, hd = p.head?.decl
            let d = p.any.decl
            let added = bd == nil, removed = hd == nil
            let exported = isExported(d)
            let structural = added || removed || p.changes.contains(.signature)
            var flags: [String] = []
            var toParent: [String] = []

            if d.inProtocol {
                if structural {
                    let f = "interface-method-\(added ? "added" : removed ? "removed" : "changed")"
                    flags.append(f)
                    toParent.append(f)
                }
            } else if d.parentKind == .struct && d.isStored {
                // Exported fields of exported types: other packages can name them.
                if (added || removed) && exported {
                    let f = "field-\(added ? "added" : "removed")"
                    flags.append(f)
                    toParent.append(f)
                }
                if let bd, let hd {
                    for key in Self.tagKeys where Self.tag(key, of: bd) != Self.tag(key, of: hd) {
                        flags.append("field-tag-changed:\(key)")
                    }
                }
            } else if exported && !p.any.file.hasSuffix("_test.go") {
                // Test files' exported names (TestX, ExampleX) aren't API.
                if added { flags.append("api-added") }
                if removed {
                    let lower = d.name.prefix(1).lowercased() + d.name.dropFirst()
                    flags.append(addedNames.contains("\(p.base!.component)|\(d.scope ?? "")|\(lower)") ? "unexported" : "api-removed")
                }
                if !added && !removed && p.changes.contains(.signature) { flags.append("api-signature-changed") }
            }

            let parentIdx = p.head.flatMap { b.parentPair($0, side: .head) } ?? p.base.flatMap { b.parentPair($0, side: .base) }
            if let pi = parentIdx, pairs[pi].base == nil || pairs[pi].head == nil {
                // A member of a new or deleted type: the type carries the change.
                flags.removeAll { Self.memberLevel.contains($0) }
                toParent = []
            }
            out[i] = flags
            if !toParent.isEmpty, let pi = parentIdx { parentFlags[pi, default: []].formUnion(toParent) }
        }
        for (pi, fl) in parentFlags {
            for f in fl.sorted() where !(out[pi] ?? []).contains(f) { out[pi, default: []].append(f) }
        }
        return out
    }

    /// A capitalized name, with a capitalized type for a method or field.
    private func isExported(_ d: Decl) -> Bool {
        isExportedName(d.name) && (d.scope.map(isExportedName) ?? true)
    }

    private func isExportedName(_ s: String) -> Bool { s.first?.isUppercase == true }

    /// The value of `key` in a field's struct tag (`json:"id,omitempty"` -> `id,omitempty`), or nil.
    static func tag(_ key: String, of d: Decl) -> String? {
        guard let raw = d.traits.first(where: { $0.hasPrefix("tag:") })?.dropFirst(4),
              let r = raw.range(of: #"(^|\s)"# + key + #":"([^"]*)""#, options: .regularExpression) else { return nil }
        let match = raw[r]
        guard let open = match.firstIndex(of: "\"") else { return nil }
        return String(match[match.index(after: open)...].dropLast())
    }
}
