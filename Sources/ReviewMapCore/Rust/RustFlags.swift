import Foundation

struct RustFlags {
    let b: ChangeReportBuilder
    let indices: [Int]
    init(_ builder: ChangeReportBuilder, pairs: [Int]) { b = builder; indices = pairs }

    func compute() -> [Int: [String]] {
        var out: [Int: Set<String>] = [:]
        for i in indices {
            let p = b.pairs[i], d = b.pairs[i].any.decl
            let base = p.base?.decl, head = p.head?.decl
            let added = base == nil, removed = head == nil
            let structural = added || removed || p.changes.contains(.signature)
            let parent = p.head.flatMap { b.parentPair($0, side: .head) } ?? p.base.flatMap { b.parentPair($0, side: .base) }
            func flag(_ value: String) { out[i, default: []].insert(value) }
            func member(_ value: String) {
                guard let parent, b.pairs[parent].base != nil, b.pairs[parent].head != nil else { return }
                flag(value); out[parent, default: []].insert(value)
            }
            if isPublic(p.head, .head) || isPublic(p.base, .base) {
                if added { flag("api-added") }
                else if removed { flag("api-removed") }
                else if p.changes.contains(.signature) { flag("api-signature-changed") }
            }
            if d.inProtocol && structural { member("trait-item-\(added ? "added" : removed ? "removed" : "changed")") }
            if d.kind == .case && (added || removed) { member("enum-variant-\(added ? "added" : "removed")") }
            if let base, let head {
                if visibility(head.access) < visibility(base.access) { flag("visibility-narrowed") }
                if base.isAsync != head.isAsync { flag(head.isAsync ? "async-added" : "async-removed") }
                for bound in ["Send", "Sync"] where hasBound(bound, base) != hasBound(bound, head) {
                    flag("\(bound.lowercased())-bound-\(hasBound(bound, head) ? "added" : "removed")")
                }
                if base.attributes.contains("non_exhaustive") != head.attributes.contains("non_exhaustive") {
                    flag(head.attributes.contains("non_exhaustive") ? "non-exhaustive-added" : "non-exhaustive-removed")
                }
                if serdeAttributes(base) != serdeAttributes(head) && (!serdeAttributes(base).isEmpty || !serdeAttributes(head).isEmpty) { flag("serde-shape-changed") }
            }
            if !added && !removed && p.changes.contains(.signature),
               [base, head].compactMap({ $0 }).contains(where: { !serdeAttributes($0).isEmpty }) {
                flag("serde-shape-changed")
            }
            if (d.isStored || d.kind == .case) && (structural || p.changes.contains(.modifiers)) {
                var ancestor = parent
                while let index = ancestor {
                    let type = b.pairs[index]
                    if type.base != nil && type.head != nil,
                       [type.base?.decl, type.head?.decl].compactMap({ $0 }).contains(where: { !serdeAttributes($0).isEmpty }) {
                        out[index, default: []].insert("serde-shape-changed")
                        flag("serde-shape-changed")
                    }
                    ancestor = type.head.flatMap { b.parentPair($0, side: .head) } ?? type.base.flatMap { b.parentPair($0, side: .base) }
                }
            }
        }
        return out.mapValues { $0.sorted() }
    }

    private func isPublic(_ location: Located?, _ side: Side) -> Bool {
        guard let location, !location.decl.traits.contains("test") else { return false }
        let enclosing = b.side(side).files[location.file]?.enclosingDeclarations(of: location.decl) ?? []
        return RustLanguage().isPublicAPI(location.decl, enclosing: enclosing)
    }
    private func visibility(_ access: String?) -> Int {
        switch access { case "public": return 3; case "internal": return 2; case "fileprivate": return 1; default: return 0 }
    }
    private func hasBound(_ name: String, _ decl: Declaration) -> Bool {
        decl.signatureCanon.range(of: #"(?:[:+]|\b(?:impl|dyn))\s*(?:[A-Za-z_][A-Za-z0-9_]*\s*::\s*)*"# + name + #"\b"#, options: .regularExpression) != nil
    }
    private func serdeAttributes(_ decl: Declaration) -> [String] {
        decl.attributes.filter { $0.hasPrefix("serde") || ($0.hasPrefix("derive") && ($0.contains("Serialize") || $0.contains("Deserialize"))) }.sorted()
    }

    static func settingFlag(_ key: String) -> String {
        if key.contains("rust-version") { return "rust-version-changed" }
        if key.contains("edition") { return "edition-changed" }
        if key.contains("feature") { return "features-changed" }
        if key.contains("profile") { return "profile-changed" }
        return "settings-changed"
    }
    static func risk(_ flag: String, isInterface: Bool) -> Double {
        if ["features-changed", "edition-changed", "rust-version-changed", "profile-changed", "settings-changed", "api-added"].contains(flag) { return RiskWeight.medium }
        return RiskWeight.high
    }
}
