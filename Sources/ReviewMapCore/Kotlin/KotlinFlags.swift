import Foundation

struct KotlinFlags {
    let b: ChangeReportBuilder
    let indices: [Int]
    init(_ builder: ChangeReportBuilder, pairs: [Int]) { b = builder; indices = pairs }

    func compute() -> [Int: [String]] {
        var out: [Int: Set<String>] = [:]
        var knownTypes: [Side: Set<String>] = [:]
        for side in [Side.base, .head] {
            for file in b.side(side).files.values where file.language == "kotlin" {
                knownTypes[side, default: []].formUnion(file.decls.filter(\.isContainer).map { KotlinStructure.qualified(file.packageName, $0.qualifiedName) })
            }
        }
        func supertypes(_ location: Located?, side: Side) -> Set<String> {
            guard let location, let file = b.side(side).files[location.file] else { return [] }
            return Set(location.decl.traits.filter { $0.hasPrefix("supertype:") }.compactMap {
                KotlinStructure.resolveType(String($0.dropFirst("supertype:".count)), in: file,
                                            scope: location.decl.scope, knownTypes: knownTypes[side] ?? [])
            })
        }
        for i in indices {
            let p = b.pairs[i], d = p.any.decl
            let base = p.base?.decl, head = p.head?.decl
            let added = base == nil, removed = head == nil
            let structural = added || removed || p.changes.contains(.signature)
            let parent = p.head.flatMap { b.parentPair($0, side: .head) } ?? p.base.flatMap { b.parentPair($0, side: .base) }
            func flag(_ name: String) { out[i, default: []].insert(name) }
            func member(_ name: String) {
                guard let parent, b.pairs[parent].base != nil, b.pairs[parent].head != nil else { return }
                flag(name); out[parent, default: []].insert(name)
            }
            if isPublic(p.base, .base) || isPublic(p.head, .head) {
                if added { flag("api-added") }
                else if removed { flag("api-removed") }
                else if p.changes.contains(.signature) { flag("api-signature-changed") }
            }
            if d.kind == .case && (added || removed) { member("enum-entry-\(added ? "added" : "removed")") }
            if d.inProtocol && structural { member("interface-member-\(added ? "added" : removed ? "removed" : "changed")") }
            if d.traits.contains("constructor-property"), structural || p.changes.contains(.modifiers),
               let parent, [b.pairs[parent].base?.decl, b.pairs[parent].head?.decl].compactMap({ $0 }).contains(where: { $0.modifiers.contains("data") }) {
                member("data-class-shape-changed")
            }
            if let base, let head {
                if base.modifiers.contains("data") || head.modifiers.contains("data") {
                    if base.modifiers.contains("data") != head.modifiers.contains("data") ||
                        base.traits.filter({ $0.hasPrefix("constructor-shape:") }) != head.traits.filter({ $0.hasPrefix("constructor-shape:") }) {
                        flag("data-class-shape-changed")
                    }
                }
                if visibilityNarrowed(from: base.access, to: head.access) { flag("visibility-narrowed") }
                if base.isAsync != head.isAsync { flag(head.isAsync ? "suspend-added" : "suspend-removed") }
                if nullable(base) != nullable(head) { flag("nullability-changed") }
                for modifier in ["open", "final", "abstract"] where hasModifier(modifier, base) != hasModifier(modifier, head) {
                    flag("\(modifier)-\(hasModifier(modifier, head) ? "added" : "removed")")
                }
                if serialization(base) != serialization(head) { flag("serialized-shape-changed") }
                if persistence(base) != persistence(head) { flag("persisted-shape-changed") }
            }
            if structural || p.changes.contains(.modifiers) {
                for (name, attributes) in [("serialized-shape-changed", serialization), ("persisted-shape-changed", persistence)] {
                    if [base, head].compactMap({ $0 }).contains(where: { !attributes($0).isEmpty }) { flag(name) }
                    if d.kind == .var {
                        var ancestor = parent
                        while let index = ancestor {
                            let owner = b.pairs[index]
                            if owner.base != nil, owner.head != nil,
                               [owner.base?.decl, owner.head?.decl].compactMap({ $0 }).contains(where: { !attributes($0).isEmpty }) {
                                flag(name); out[index, default: []].insert(name)
                            }
                            ancestor = owner.head.flatMap { b.parentPair($0, side: .head) } ?? owner.base.flatMap { b.parentPair($0, side: .base) }
                        }
                    }
                }
            }
            // Sealed subclasses need not be nested in their sealed parent.
            for (side, location, other) in [(Side.base, p.base, p.head), (.head, p.head, p.base)] {
                guard let location else { continue }
                let changedParents = supertypes(location, side: side).subtracting(supertypes(other, side: side == .base ? .head : .base))
                for ancestor in indices {
                    let type = b.pairs[ancestor]
                    guard type.base != nil, type.head != nil,
                          let owner = side == .base ? type.base : type.head,
                          owner.decl.modifiers.contains("sealed"),
                          changedParents.contains(KotlinStructure.qualified(b.side(side).files[owner.file]?.packageName, owner.decl.qualifiedName)),
                          owner.component == location.component,
                          b.side(side).files[owner.file]?.packageName == b.side(side).files[location.file]?.packageName else { continue }
                    let name = "sealed-subclass-\(side == .head ? "added" : "removed")"
                    flag(name); out[ancestor, default: []].insert(name)
                }
            }
        }
        return out.mapValues { $0.sorted() }
    }

    private func isPublic(_ location: Located?, _ side: Side) -> Bool {
        guard let location else { return false }
        let enclosing = b.side(side).files[location.file]?.enclosingDeclarations(of: location.decl) ?? []
        return KotlinLanguage().isPublicAPI(location.decl, enclosing: enclosing)
    }
    private func visibilityNarrowed(from base: String?, to head: String?) -> Bool {
        let base = base ?? "public", head = head ?? "public"
        guard base != head, head != "public", base != "private" else { return false }
        // Internal and protected expose different callers; either transition removes access for some.
        return true
    }
    private func nullable(_ d: Declaration) -> Set<String> { Set(d.traits.filter { $0.hasPrefix("nullable:") }) }
    private func hasModifier(_ modifier: String, _ d: Declaration) -> Bool {
        if modifier == "final" {
            return d.modifiers.contains("final") || (!d.modifiers.contains("open") && !d.modifiers.contains("abstract") && !d.modifiers.contains("sealed") && !d.modifiers.contains("override") && d.kind != .protocol && !d.inProtocol)
        }
        return d.modifiers.contains(modifier)
    }
    private func annotations(_ d: Declaration, names: Set<String>) -> Set<String> {
        Set(d.traits.filter { trait in
            guard trait.hasPrefix("annotation:") else { return false }
            let annotation = String(trait.dropFirst("annotation:".count))
            let name = annotation.components(separatedBy: "(")[0].split(whereSeparator: { $0 == "." || $0 == ":" || $0 == "@" || $0.isWhitespace }).last.map(String.init) ?? ""
            return names.contains(name)
        })
    }
    private func serialization(_ d: Declaration) -> Set<String> { annotations(d, names: ["Serializable", "SerialName", "Json"]) }
    private func persistence(_ d: Declaration) -> Set<String> { annotations(d, names: ["Entity", "ColumnInfo"]) }

    static func settingFlag(_ key: String) -> String {
        if key.contains("minSdk") { return "min-sdk-changed" }
        if key.contains("targetSdk") { return "target-sdk-changed" }
        if key.contains("compileSdk") { return "compile-sdk-changed" }
        if key.contains("jvmTarget") || key.contains("jvmToolchain") { return "jvm-target-changed" }
        if key.contains("kotlin") { return "kotlin-version-changed" }
        return "settings-changed"
    }
    static func risk(_ flag: String, isInterface: Bool) -> Double {
        if ["api-added", "compile-sdk-changed", "jvm-target-changed", "kotlin-version-changed", "settings-changed"].contains(flag) { return RiskWeight.medium }
        return RiskWeight.high
    }
}
