import Foundation

/// TypeScript's contract flags: changes to declarations that importers and implementers depend on.
struct TypeScriptFlags {
    let b: ChangeReportBuilder
    /// The TypeScript pairs, as indices into `b.pairs`.
    let indices: [Int]

    init(_ builder: ChangeReportBuilder, pairs: [Int]) {
        b = builder
        indices = pairs
    }

    /// Flags that a member reports on its type too, unless the type itself is new or deleted.
    private static let memberLevel: Set<String> = ["interface-member-added", "interface-member-removed", "interface-member-changed",
                                                   "enum-member-added", "enum-member-removed", "enum-member-changed",
                                                   "abstract-member-added", "abstract-member-removed", "abstract-member-changed"]

    func compute() -> [Int: [String]] {
        let pairs = b.pairs
        var out: [Int: [String]] = [:]
        var parentFlags: [Int: Set<String>] = [:]
        for i in indices {
            let p = pairs[i]
            let bd = p.base?.decl, hd = p.head?.decl
            let d = p.any.decl
            let s: Side = p.head != nil ? .head : .base
            let added = bd == nil, removed = hd == nil
            var flags: [String] = []

            if let bd, let hd {
                func toggled(_ name: String, _ has: (Declaration) -> Bool) {
                    if has(bd) != has(hd) { flags.append("\(name)-\(has(hd) ? "added" : "removed")") }
                }
                if d.isTopLevel { toggled("export") { $0.modifiers.contains("export") } }
                if d.parentKind == .class {
                    let ba = bd.access ?? "public", ha = hd.access ?? "public"
                    if ba != ha { flags.append("access-changed:\(ba)->\(ha)") }
                }
                toggled("async") { $0.isAsync }
                toggled("readonly") { $0.modifiers.contains("readonly") }
                toggled("optional") { $0.traits.contains("optional") }
                toggled("static") { $0.isStatic }
                toggled("abstract") { $0.modifiers.contains("abstract") }
                if bd.isContainer {
                    for t in Set(hd.inherited).subtracting(bd.inherited).sorted() { flags.append("supertype-added:\(t)") }
                    for t in Set(bd.inherited).subtracting(hd.inherited).sorted() { flags.append("supertype-removed:\(t)") }
                }
                if bd.kind == .enum && bd.modifiers.contains("const") != hd.modifiers.contains("const") { flags.append("const-enum-changed") }
            }

            var toParent: [String] = []
            let structural = added || removed || p.changes.contains(where: { $0 != .body && $0 != .cosmetic })
            func member(_ prefix: String) {
                let f = "\(prefix)-member-\(added ? "added" : removed ? "removed" : "changed")"
                flags.append(f)
                toParent.append(f)
            }
            if d.parentKind == .protocol && structural { member("interface") }
            if d.kind == .case && d.parentKind == .enum && (added || removed || p.changes.contains(.signature)) { member("enum") }
            if d.parentKind == .class && structural && (bd ?? hd)!.modifiers.contains("abstract") && !d.isContainer { member("abstract") }

            let parentIdx = (p.head ?? p.base).flatMap { self.b.parentPair($0, side: s) }
            if let pi = parentIdx, pairs[pi].base == nil || pairs[pi].head == nil {
                // A member of a new or deleted type: the type carries the change.
                flags.removeAll { Self.memberLevel.contains($0) }
            }
            out[i] = flags
            if !toParent.isEmpty, let pp = parentIdx, pairs[pp].base != nil, pairs[pp].head != nil {
                parentFlags[pp, default: []].formUnion(toParent)
            }
        }
        for (pi, fl) in parentFlags {
            for f in fl.sorted() where !(out[pi] ?? []).contains(f) { out[pi, default: []].append(f) }
        }
        return out
    }
}
