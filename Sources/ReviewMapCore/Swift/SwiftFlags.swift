import Foundation

private let codableNames: Set<String> = ["Codable", "Encodable", "Decodable"]
private let observableAttrs: Set<String> = ["Published", "State", "Observable", "ObservationTracked", "Bindable", "AppStorage", "SceneStorage"]

/// Swift's contract flags: changes to declarations that callers, persisted data, or isolation depend on.
struct SwiftFlags {
    let b: ChangeReportBuilder
    /// The Swift pairs, as indices into `b.pairs`.
    let indices: [Int]

    init(_ builder: ChangeReportBuilder, pairs: [Int]) {
        b = builder
        indices = pairs
    }

    /// Types (by component + qualified name) with a given trait on one side, including conformances added in extensions.
    private func typesWhere(_ s: SideData, _ pred: (Declaration) -> Bool) -> Set<String> {
        var result = Set<String>()
        for (path, file) in s.files where file.language == "swift" {
            guard let comp = s.layout.fileComponent[path] else { continue }
            for d in file.decls where d.isContainer && pred(d) {
                result.insert("\(comp)|\(d.kind == .extension ? d.name : d.qualifiedName)")
            }
        }
        return result
    }

    /// Effective conformances per "component|Type": name -> isolation attributes ("" when none).
    private func conformances(_ s: SideData) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for (path, file) in s.files where file.language == "swift" {
            guard let comp = s.layout.fileComponent[path] else { continue }
            for d in file.decls where d.isContainer {
                let key = "\(comp)|\(d.kind == .extension ? d.name : d.qualifiedName)"
                for c in d.inherited {
                    let parts = c.split(separator: " ")
                    let attrs = parts.dropLast().filter { $0 != "@unchecked" && $0 != "@retroactive" && $0 != "@preconcurrency" }.joined(separator: " ")
                    result[key, default: [:]][ChangeReportBuilder.conformanceName(c)] = attrs
                }
                if d.attributes.contains("Sendable") { result[key, default: [:]]["Sendable"] = "" }
            }
        }
        return result
    }

    func compute() -> [Int: [String]] {
        let pairs = b.pairs
        let isCodable: (Declaration) -> Bool = { !codableNames.isDisjoint(with: $0.inherited.map(ChangeReportBuilder.conformanceName)) }
        let codable = typesWhere(b.base, isCodable).union(typesWhere(b.head, isCodable))
        let models = typesWhere(b.base, { $0.attributes.contains("Model") }).union(typesWhere(b.head, { $0.attributes.contains("Model") }))
        // With @Observable every stored property is tracked state; with ObservableObject only @Published ones are.
        let isObs: (Declaration) -> Bool = { $0.attributes.contains("Observable") }
        let observable = typesWhere(b.base, isObs).union(typesWhere(b.head, isObs))

        let baseConf = conformances(b.base), headConf = conformances(b.head)
        var typeDeclared = Set<String>()
        for i in indices {
            let p = pairs[i]
            if p.any.decl.isContainer && p.any.decl.kind != .extension && p.base != nil && p.head != nil {
                typeDeclared.insert("\(p.any.component)|\(p.any.decl.qualifiedName)")
            }
        }
        var out: [Int: [String]] = [:]
        var parentFlags: [Int: Set<String>] = [:]
        for i in indices {
            let p = pairs[i]
            let b = p.base?.decl
            let h = p.head?.decl
            let d = p.any.decl
            let s: Side = p.head != nil ? .head : .base
            var flags: [String] = []
            let added = b == nil, removed = h == nil
            let changed = !p.changes.isEmpty && p.changes != [.cosmetic]

            if let b, let h {
                let ba = b.access ?? "internal", ha = h.access ?? "internal"
                if ba != ha { flags.append("access-changed:\(ba)->\(ha)") }
                if b.isAsync != h.isAsync { flags.append(h.isAsync ? "async-added" : "async-removed") }
                if b.isThrows != h.isThrows { flags.append(h.isThrows ? "throws-added" : "throws-removed") }
                else if b.isThrows && b.throwsType != h.throwsType { flags.append("typed-throws-changed") }
                let bm = b.attributes.contains("MainActor"), hm = h.attributes.contains("MainActor")
                if bm != hm { flags.append(hm ? "mainactor-added" : "mainactor-removed") }
                let bn = b.modifiers.contains { $0.hasPrefix("nonisolated") }, hn = h.modifiers.contains { $0.hasPrefix("nonisolated") }
                if bn != hn { flags.append(hn ? "nonisolated-added" : "nonisolated-removed") }
                if !b.isContainer {
                    let bsend = b.attributes.contains("Sendable"), hsend = h.attributes.contains("Sendable")
                    if bsend != hsend { flags.append(hsend ? "sendable-added" : "sendable-removed") }
                }
                if b.kind != h.kind && ChangeReportBuilder.kindGroup(b.kind) == "type" { flags.append("kind-changed:\(b.kind.rawValue)->\(h.kind.rawValue)") }
                if b.kind != .extension || !typeDeclared.contains("\(p.any.component)|\(b.name)") {
                    // Conformances are compared per type, across the type and its extensions in the component,
                    // so moving a conformance into an extension is not a change.
                    let key = "\(p.any.component)|\(b.kind == .extension ? b.name : b.qualifiedName)"
                    let bc = baseConf[key] ?? [:], hc = headConf[key] ?? [:]
                    for c in Set(hc.keys).subtracting(bc.keys).subtracting(["Sendable"]).sorted() { flags.append("conformance-added:\(c)") }
                    for c in Set(bc.keys).subtracting(hc.keys).subtracting(["Sendable"]).sorted() { flags.append("conformance-removed:\(c)") }
                    for c in Set(bc.keys).intersection(hc.keys).sorted() where bc[c] != hc[c] {
                        flags.append("conformance-isolation-changed:\(c)")
                    }
                    if (bc["Sendable"] != nil) != (hc["Sendable"] != nil) && !flags.contains(where: { $0.hasPrefix("sendable-") }) {
                        flags.append(hc["Sendable"] != nil ? "sendable-added" : "sendable-removed")
                    }
                }
                let bo = b.attributes.contains("Observable"), ho = h.attributes.contains("Observable")
                if bo != ho { flags.append(ho ? "observable-added" : "observable-removed") }
                let bmodel = b.attributes.contains("Model"), hmodel = h.attributes.contains("Model")
                if bmodel != hmodel { flags.append("swiftdata-model-changed") }
            } else if d.kind == .extension {
                // A new or deleted extension: report conformances that the type gained or lost overall.
                let key = "\(p.any.component)|\(d.name)"
                let bc = baseConf[key] ?? [:], hc = headConf[key] ?? [:]
                for c in d.inherited.map(ChangeReportBuilder.conformanceName) where c != "Sendable" {
                    if added && bc[c] == nil { flags.append("conformance-added:\(c)") }
                    if removed && hc[c] == nil { flags.append("conformance-removed:\(c)") }
                    if added, let old = bc[c], old != hc[c] { flags.append("conformance-isolation-changed:\(c)") }
                }
            }

            var toParent: [String] = []
            let parentKind = d.parentKind
            if parentKind == .protocol && (added || removed || changed && p.changes.contains(where: { $0 != .body })) {
                let f = added ? "protocol-requirement-added" : removed ? "protocol-requirement-removed" : "protocol-requirement-changed"
                flags.append(f)
                toParent.append(f)
            }
            if d.kind == .case && parentKind == .enum && (added || removed || p.changes.contains(.signature)) {
                let f = added ? "enum-case-added" : removed ? "enum-case-removed" : "enum-case-changed"
                flags.append(f)
                toParent.append(f)
            }
            let scopeKey = "\(p.any.component)|\(d.scope ?? "")"
            let structural = added || removed || p.changes.contains(.signature) || p.changes.contains(.modifiers)
            if d.kind == .var && d.isStored && !d.isStatic && structural {
                if codable.contains(scopeKey) { flags.append("codable-shape"); toParent.append("codable-shape") }
                if models.contains(scopeKey) { flags.append("swiftdata-model-changed"); toParent.append("swiftdata-model-changed") }
                let attrs = Set((b?.attributes ?? []) + (h?.attributes ?? []))
                if !attrs.contains("ObservationIgnored") && (observable.contains(scopeKey) || !attrs.isDisjoint(with: observableAttrs)) {
                    flags.append("observable-state-changed")
                    toParent.append("observable-state-changed")
                }
            }
            // Members of a nested CodingKeys enum shape the parent's encoding.
            if let scope = d.scope, scope.hasSuffix(".CodingKeys"), d.kind == .case, added || removed || changed {
                flags.append("codable-shape")
                let owner = String(scope.dropLast(".CodingKeys".count))
                if let oi = indices.first(where: { pairs[$0].any.component == p.any.component && pairs[$0].any.decl.qualifiedName == owner && pairs[$0].any.decl.kind != .extension }) {
                    parentFlags[oi, default: []].insert("codable-shape")
                }
            }
            let parentIdx = (p.head ?? p.base).flatMap { self.b.parentPair($0, side: s) }
            if let pi = parentIdx, pairs[pi].base == nil || pairs[pi].head == nil {
                // A member of a new or deleted type: the type itself carries the flag; repeating it on every
                // member is noise.
                let memberLevel: Set<String> = ["protocol-requirement-added", "protocol-requirement-removed", "enum-case-added",
                                                "enum-case-removed", "codable-shape", "swiftdata-model-changed", "observable-state-changed"]
                flags.removeAll { memberLevel.contains($0) }
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
