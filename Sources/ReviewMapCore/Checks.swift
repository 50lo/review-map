import Foundation

// Structural review, deterministic part. The analyzer has both sides of the whole repo, the
// dependency graph, and usage, so it can check what a review of the diff alone can't: new cycles,
// edges against the declared layering, new external dependencies, new public API nobody calls,
// code its callers left behind, conformers a changed protocol missed, and changed code no test
// references. Each finding is anchored to the components, edges, or entities it is about.
//
// Without an index, "is X referenced" means "does the identifier X appear outside its own
// declaration". That over-counts uses, so the unused-code checks err towards saying nothing.

/// Where a declaration's name occurs on one side, outside the declaration itself.
private struct Occurrence {
    var file: String
    var line: Int
    var isTest: Bool
}

/// Identifier occurrences per side, built on first use.
private final class WordIndex {
    private var words: [String: [(file: Int, line: Int32)]] = [:]
    private var files: [(path: String, isTest: Bool)] = []

    init(_ data: SideData) {
        for path in data.files.keys.sorted() where !data.generated.contains(path) {
            guard let text = try? String(contentsOfFile: data.dir + "/" + path, encoding: .utf8) else { continue }
            let comp = data.layout.fileComponent[path].flatMap { data.layout.components[$0] }
            let fi = files.count
            files.append((path, comp?.isTest == true || ComponentBuilder.isTestPath(path)))
            var line: Int32 = 1
            var word: [UInt8] = []
            func flush() {
                guard !word.isEmpty else { return }
                // `$x` (a projected value, or a TypeScript name) and `_x` (a backing store) use `x` too.
                var w = word
                while let f = w.first, f == UInt8(ascii: "$") || f == UInt8(ascii: "_"), w.count > 1 { w.removeFirst() }
                if let s = String(bytes: w, encoding: .utf8), !(s.first?.isNumber ?? true) { words[s, default: []].append((fi, line)) }
                word.removeAll(keepingCapacity: true)
            }
            for byte in text.utf8 {
                switch byte {
                case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                     UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "$"):
                    word.append(byte)
                default:
                    flush()
                    if byte == UInt8(ascii: "\n") { line += 1 }
                }
            }
            flush()
        }
    }

    func occurrences(_ name: String) -> [Occurrence] {
        (words[name] ?? []).map { Occurrence(file: files[$0.file].path, line: Int($0.line), isTest: files[$0.file].isTest) }
    }
}

private let implicitNames: Set<String> = ["init", "deinit", "subscript", "default", "constructor", "body", "main"]
/// Attributes whose declarations are called by a runtime or a framework, not by name.
private let entryAttributes: Set<String> = ["objc", "IBAction", "IBOutlet", "IBInspectable", "main", "UIApplicationMain", "NSApplicationMain",
                                            "_cdecl", "_silgen_name", "_spi", "usableFromInline", "inlinable", "dynamicCallable", "dynamicMemberLookup"]

private let severityOrder = ["high": 0, "medium": 1, "low": 2]

struct StructuralChecks {
    let b: ModelBuilder
    let entities: [Entity]
    let edges: [Edge]
    let config: Config
    private let words: [Side: WordIndex]
    /// Index mode: (side, file, decl index) -> the places that reference the declaration.
    private let indexed: [Side: [DeclKey: [Occurrence]]]
    private let entityIds: Set<String>
    private var pairId: [DeclKey: String] = [:]

    init(_ b: ModelBuilder, entities: [Entity], edges: [Edge], config: Config) {
        self.b = b
        self.entities = entities
        self.edges = edges
        self.config = config
        words = [.base: WordIndex(b.base), .head: WordIndex(b.head)]
        var idx: [Side: [DeclKey: [Occurrence]]] = [:]
        for s in [Side.base, .head] {
            guard let refs = b.index[s]?.refs else { continue }
            let data = b.side(s)
            var map: [DeclKey: [Occurrence]] = [:]
            for (path, list) in refs {
                let comp = data.layout.fileComponent[path].flatMap { data.layout.components[$0] }
                let isTest = comp?.isTest == true || ComponentBuilder.isTestPath(path)
                for r in list {
                    guard let t = b.declAt(s, file: r.targetFile, line: r.targetLine, name: r.name) else { continue }
                    map[DeclKey(side: s, file: r.targetFile, index: t.index), default: []].append(Occurrence(file: path, line: r.line, isTest: isTest))
                }
            }
            idx[s] = map
        }
        indexed = idx
        entityIds = Set(entities.map(\.id))
        for p in b.pairs {
            if let h = p.head { pairId[DeclKey(side: .head, file: h.file, index: h.index)] = p.id }
            if let x = p.base { pairId[DeclKey(side: .base, file: x.file, index: x.index)] = p.id }
        }
    }

    func run() -> [Finding] {
        var out = cycles() + layering() + newExternals() + unusedAPI() + orphaned() + conformers() + untested()
        out.sort { (severityOrder[$0.severity] ?? 3, $0.kind) < (severityOrder[$1.severity] ?? 3, $1.kind) }
        var counts: [String: Int] = [:]
        for i in out.indices {
            counts[out[i].kind, default: 0] += 1
            out[i].id = "\(out[i].kind):\(counts[out[i].kind]!)"
        }
        return out
    }

    // MARK: Helpers

    private func name(_ id: String) -> String {
        b.head.layout.components[id]?.name ?? b.base.layout.components[id]?.name ?? (id.hasPrefix("ext:") ? String(id.dropFirst(4)) : id)
    }

    private func isTestComponent(_ id: String) -> Bool {
        (b.head.layout.components[id] ?? b.base.layout.components[id])?.isTest == true
    }

    /// The target a split folder belongs to.
    private func root(_ id: String, _ s: Side) -> String {
        var cur = id
        while let p = b.side(s).layout.components[cur]?.parent { cur = p }
        return cur
    }

    private func isLow(_ l: Located, _ s: Side) -> Bool {
        b.side(s).layout.components[l.component]?.isTest == true || ComponentBuilder.isTestPath(l.file) || b.side(s).generated.contains(l.file)
    }

    private func decl(_ s: Side, _ file: String, _ i: Int?) -> Decl? {
        guard let i else { return nil }
        return b.side(s).files[file]?.decls[i]
    }

    /// Public API: Swift's public, open, and package; TypeScript's exports (named, not default) and their public members.
    private func isPublic(_ l: Located, _ s: Side) -> Bool {
        let d = l.decl
        if b.language(of: l.file).id == "swift" { return ["public", "open", "package"].contains(d.access ?? "") }
        if d.modifiers.contains("default") { return false }
        guard !d.isTopLevel else { return d.modifiers.contains("export") }
        if let a = d.access, a != "public" { return false }
        var cur = d.parentIndex
        while let i = cur, let p = decl(s, l.file, i) {
            if p.isTopLevel { return p.modifiers.contains("export") && !p.modifiers.contains("default") }
            cur = p.parentIndex
        }
        return false
    }

    /// Declarations that something calls without naming them: initializers, overrides, entry points,
    /// protocol requirements, and members of a type or extension that conforms to something (they may be witnesses).
    private func calledImplicitly(_ l: Located, _ s: Side) -> Bool {
        let d = l.decl
        if implicitNames.contains(d.name) || !(d.name.first.map { $0.isLetter || $0 == "_" || $0 == "$" } ?? false) { return true }
        if d.kind == .extension || d.kind == .`init` || d.inProtocol { return true }
        if d.modifiers.contains("override") { return true }
        if d.attributes.contains(where: { entryAttributes.contains($0) || $0.hasPrefix("IB") }) { return true }
        if let p = decl(s, l.file, d.parentIndex), !p.inherited.isEmpty || p.kind == .protocol { return true }
        return false
    }

    /// Places that reference a declaration at one side, outside the declaration itself.
    private func references(_ l: Located, _ s: Side) -> [Occurrence] {
        let d = l.decl
        let lang = b.language(of: l.file).id
        if b.indexedLanguages.contains(lang), let map = indexed[s] {
            return (map[DeclKey(side: s, file: l.file, index: l.index)] ?? []).filter { o in
                !(o.file == l.file && d.startLine <= o.line && o.line <= d.endLine)
            }
        }
        // Lines that name the declaration without using it: the declaration itself and extension headers of the type.
        var own: [String: [ClosedRange<Int>]] = [l.file: [d.startLine...d.endLine]]
        if d.isContainer {
            for (path, file) in b.side(s).files {
                for x in file.decls where x.kind == .extension && x.name == d.name {
                    own[path, default: []].append(x.startLine...max(x.startLine, x.headerEndLine))
                }
            }
        }
        return words[s]!.occurrences(d.name).filter { o in !(own[o.file] ?? []).contains { $0.contains(o.line) } }
    }

    private func at(_ o: Occurrence, _ s: Side) -> String {
        let encl = b.side(s).files[o.file]?.enclosingDecl(line: o.line)?.qualifiedName
        return "\(encl.map { "\($0) (" } ?? "")\(o.file):\(o.line)\(encl == nil ? "" : ")")"
    }

    private func location(_ l: Located, _ s: Side) -> Location {
        Location(file: l.file, startLine: l.decl.startLine, endLine: l.decl.endLine, side: s)
    }

    private func refLine(_ refs: [Ref]) -> String {
        guard let r = refs.first else { return "" }
        return r.line == 0 ? " (\(r.symbol), \(r.file))" : " (\(r.symbol) at \(r.file):\(r.line))"
    }

    // MARK: Cycles

    /// Strongly connected components with more than one node.
    private static func cyclic(_ graph: [String: Set<String>]) -> [[String]] {
        var index = 0
        var indices: [String: Int] = [:], low: [String: Int] = [:]
        var stack: [String] = [], onStack = Set<String>()
        var out: [[String]] = []
        func visit(_ v: String) {
            indices[v] = index; low[v] = index; index += 1
            stack.append(v); onStack.insert(v)
            for w in (graph[v] ?? []).sorted() {
                if indices[w] == nil {
                    visit(w)
                    low[v] = min(low[v]!, low[w]!)
                } else if onStack.contains(w) {
                    low[v] = min(low[v]!, indices[w]!)
                }
            }
            if low[v] == indices[v] {
                var scc: [String] = []
                while let w = stack.popLast() {
                    onStack.remove(w)
                    scc.append(w)
                    if w == v { break }
                }
                if scc.count > 1 { out.append(scc.sorted()) }
            }
        }
        for v in graph.keys.sorted() where indices[v] == nil { visit(v) }
        return out
    }

    /// The target-level graph of one side: split folders count as their target, external packages are left out.
    private func graph(_ s: Side) -> [String: Set<String>] {
        var g: [String: Set<String>] = [:]
        for (from, tos) in b.edgeRefs[s]! where !from.hasPrefix("ext:") {
            for to in tos.keys where !to.hasPrefix("ext:") {
                let a = root(from, s), c = root(to, s)
                if a != c { g[a, default: []].insert(c) }
            }
        }
        return g
    }

    private func cycles() -> [Finding] {
        let hg = graph(.head), bg = graph(.base)
        var baseScc: [String: Int] = [:]
        for (i, scc) in Self.cyclic(bg).enumerated() { for v in scc { baseScc[v] = i } }
        var out: [Finding] = []
        for scc in Self.cyclic(hg) {
            if let first = baseScc[scc[0]], scc.allSatisfy({ baseScc[$0] == first }) { continue }
            let members = Set(scc)
            // The shortest cycle through an edge that is new at head.
            let newEdges = scc.flatMap { a in (hg[a] ?? []).filter { members.contains($0) && !(bg[a]?.contains($0) ?? false) }.sorted().map { (a, $0) } }
            guard let (a, c) = newEdges.first ?? scc.flatMap({ a in (hg[a] ?? []).filter(members.contains).sorted().map { (a, $0) } }).first,
                  let back = Self.path(hg, from: c, to: a, within: members) else { continue }
            let cycle = [a] + back
            var anchors: [Anchor] = []
            var evidence: [String] = []
            for (x, y) in zip(cycle, cycle.dropFirst()) {
                let parts = edges.filter { root($0.from, .head) == x && root($0.to, .head) == y && $0.status != .removed }
                    .sorted { ($0.status == .unchanged ? 1 : 0, $0.from, $0.to) < ($1.status == .unchanged ? 1 : 0, $1.from, $1.to) }
                anchors += parts.map { .edge($0.from, $0.to) }
                let isNew = !(bg[x]?.contains(y) ?? false)
                evidence.append("\(name(x)) → \(name(y))\(isNew ? " (new)" : "")\(refLine(parts.first?.refs ?? []))")
            }
            out.append(Finding(
                id: "", source: "check", kind: "cycle", severity: "high",
                message: "New dependency cycle: \(cycle.map(name).joined(separator: " → ")).",
                evidence: evidence,
                suggestion: "Break the cycle at the new edge: move the shared code down, or invert the dependency with an interface.",
                anchors: anchors + scc.map(Anchor.component)))
        }
        return out
    }

    /// The nodes after `from` on a shortest path from `from` to `to`, ending with `to`.
    private static func path(_ g: [String: Set<String>], from: String, to: String, within: Set<String>) -> [String]? {
        var prev: [String: String] = [:]
        var queue = [from], seen: Set<String> = [from]
        while !queue.isEmpty {
            let v = queue.removeFirst()
            if v == to {
                var p = [to]
                while let q = prev[p[0]] { p.insert(q, at: 0) }
                return p
            }
            for w in (g[v] ?? []).sorted() where within.contains(w) && seen.insert(w).inserted {
                prev[w] = v
                queue.append(w)
            }
        }
        return nil
    }

    // MARK: Layering

    private func layer(_ id: String, _ s: Side) -> String? {
        b.side(s).layout.components[id]?.layer
    }

    private func layering() -> [Finding] {
        guard let layers = config.layers, !layers.isEmpty else { return [] }
        // Violations grouped by the targets at their ends, so a manifest dependency and the code under it are one finding.
        var groups: [String: [(edge: Edge, brokeBefore: Bool)]] = [:]
        for e in edges where e.status != .removed && !e.to.hasPrefix("ext:") && !isTestComponent(e.from) {
            guard let lf = layer(e.from, .head), let lt = layer(e.to, .head),
                  let rf = config.layerRank(lf), let rt = config.layerRank(lt), rt < rf else { continue }
            let brokeBefore = e.status != .added && {
                guard let bf = config.layerRank(layer(e.from, .base)), let bt = config.layerRank(layer(e.to, .base)) else { return false }
                return bt < bf
            }()
            if brokeBefore && e.symbolsAdded.isEmpty { continue }
            groups["\(root(e.from, .head))\u{1}\(root(e.to, .head))", default: []].append((e, brokeBefore))
        }
        var out: [Finding] = []
        for key in groups.keys.sorted() {
            // Code edges first: they say what crosses the boundary.
            let group = groups[key]!.sorted { ($0.edge.refs.allSatisfy { $0.line == 0 } ? 1 : 0, $0.edge.from) < ($1.edge.refs.allSatisfy { $0.line == 0 } ? 1 : 0, $1.edge.from) }
            let e = group[0].edge
            let lf = layer(e.from, .head)!, lt = layer(e.to, .head)!
            let brokeBefore = group.allSatisfy(\.brokeBefore)
            var evidence = ["\(name(e.from)) is in \(lf), \(name(e.to)) is in \(lt), which sits above it in reviewmap.yml."]
            if brokeBefore {
                let syms = Array(Set(group.flatMap(\.edge.symbolsAdded))).sorted()
                evidence.append("The dependency already broke the layering at base; it now also uses \(syms.joined(separator: ", ")).")
            }
            let refs = group.flatMap { $0.edge.refs.filter { $0.side == .head } }
            evidence += refs.prefix(3).map { $0.line == 0 ? "\($0.symbol) in \($0.file)" : "\($0.symbol) at \($0.file):\($0.line)" }
            out.append(Finding(
                id: "", source: "check", kind: "layering", severity: brokeBefore ? "medium" : "high",
                message: "\(name(e.from)) (\(lf)) depends on \(name(e.to)) (\(lt)), against the declared layering.",
                evidence: evidence,
                suggestion: "Move the code that needs \(name(e.to)) up into \(lt), or pass what it needs down through an interface in \(lf).",
                anchors: group.map { .edge($0.edge.from, $0.edge.to) } + [.component(e.from), .component(e.to)]))
        }
        return out
    }

    // MARK: New external dependencies

    private func newExternals() -> [Finding] {
        var byPackage: [String: [Edge]] = [:]
        for e in edges where e.status == .added && e.to.hasPrefix("ext:") && !e.from.hasPrefix("ext:") {
            byPackage[e.to, default: []].append(e)
        }
        let added = Dictionary(b.externalDeps.filter { $0.change == "added" }.map { ("ext:\($0.name)", $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Finding] = []
        for id in Set(byPackage.keys).union(added.keys).sorted() {
            let users = (byPackage[id] ?? []).sorted { $0.from < $1.from }
            let pkg = name(id)
            let version = added[id]?.to.map { " at \($0)" } ?? ""
            var evidence: [String] = []
            if added[id] != nil { evidence.append("\(pkg) is new in the lockfile\(version).") }
            evidence += users.prefix(5).map { "\(name($0.from)) → \(pkg)\(refLine($0.refs))" }
            let onlyTests = !users.isEmpty && users.allSatisfy { isTestComponent($0.from) }
            let who = users.isEmpty ? "The change adds \(pkg)\(version)"
                : "\(users.prefix(3).map { name($0.from) }.joined(separator: ", "))\(users.count > 3 ? " and \(users.count - 3) more" : "") now depend\(users.count == 1 ? "s" : "") on \(pkg)"
            out.append(Finding(
                id: "", source: "check", kind: "new-external", severity: onlyTests ? "low" : added[id] != nil ? "medium" : "low",
                message: "\(who)\(added[id] != nil && !users.isEmpty ? ", a new package" : "").",
                evidence: evidence, suggestion: nil,
                anchors: users.map { .edge($0.from, $0.to) } + [.component(id)]))
        }
        return out
    }

    // MARK: Unused new API

    private func unusedAPI() -> [Finding] {
        var reported = Set<DeclKey>()
        var out: [Finding] = []
        let added = b.pairs.filter { $0.base == nil && $0.head != nil }
            .sorted { ($0.head!.file, $0.head!.decl.startLine) < ($1.head!.file, $1.head!.decl.startLine) }
        for p in added {
            let h = p.head!
            guard !isLow(h, .head), h.decl.kind != .case, isPublic(h, .head), !calledImplicitly(h, .head) else { continue }
            // A member of a new type that is reported already goes with it.
            if let pi = h.decl.parentIndex, reported.contains(DeclKey(side: .head, file: h.file, index: pi)) { continue }
            let refs = references(h, .head)
            guard !refs.contains(where: { !$0.isTest }) else { continue }
            reported.insert(DeclKey(side: .head, file: h.file, index: h.index))
            let tests = refs.filter(\.isTest)
            let exact = b.indexedLanguages.contains(b.language(of: h.file).id)
            var evidence = [tests.isEmpty
                ? (exact ? "The index has no reference to it." : "The name \(h.decl.name) appears nowhere else in the repo.")
                : "Only tests use it: \(tests.prefix(3).map { at($0, .head) }.joined(separator: ", "))."]
            if let a = h.decl.access { evidence.append("Declared \(a).") }
            out.append(Finding(
                id: "", source: "check", kind: "unused-api", severity: "medium",
                message: "New public \(h.decl.kind.rawValue) \(h.decl.qualifiedName) has no callers outside tests.",
                evidence: evidence,
                suggestion: "Keep it internal until something outside needs it, or drop it.",
                anchors: [entityIds.contains(p.id) ? .entity(p.id) : .component(h.component)],
                location: location(h, .head)))
        }
        return out
    }

    // MARK: Code its callers left behind

    private func orphaned() -> [Finding] {
        var reported = Set<String>()
        var out: [Finding] = []
        let both = b.pairs.filter { $0.base != nil && $0.head != nil }
            .sorted { ($0.head!.file, $0.head!.decl.startLine) < ($1.head!.file, $1.head!.decl.startLine) }
        for p in both {
            let h = p.head!, bl = p.base!
            guard !isLow(h, .head), !isPublic(h, .head), !calledImplicitly(h, .head) else { continue }
            if let pi = h.decl.parentIndex, let parent = pairId[DeclKey(side: .head, file: h.file, index: pi)], reported.contains(parent) { continue }
            let before = references(bl, .base).filter { !$0.isTest }
            guard !before.isEmpty, !references(h, .head).contains(where: { !$0.isTest }) else { continue }
            reported.insert(p.id)
            // Base callers that are gone or changed, and the entities they are.
            var callers: [Anchor] = []
            for o in before {
                guard let file = b.base.files[o.file], let encl = file.enclosingDecl(line: o.line),
                      let i = file.decls.firstIndex(where: { $0.startLine == encl.startLine && $0.qualifiedName == encl.qualifiedName }),
                      let id = pairId[DeclKey(side: .base, file: o.file, index: i)], entityIds.contains(id) else { continue }
                if !callers.contains(.entity(id)) { callers.append(.entity(id)) }
            }
            let main: Anchor = entityIds.contains(p.id) ? .entity(p.id) : .component(h.component)
            out.append(Finding(
                id: "", source: "check", kind: "orphaned", severity: "medium",
                message: "\(h.decl.kind.rawValue) \(h.decl.qualifiedName) is no longer used: the change removed its last callers.",
                evidence: ["At base it was used from \(before.prefix(3).map { at($0, .base) }.joined(separator: ", "))\(before.count > 3 ? " and \(before.count - 3) more" : "")."],
                suggestion: "Delete it, unless a caller is still to come.",
                anchors: [main] + callers.prefix(5),
                location: location(h, .head)))
        }
        return out
    }

    // MARK: Conformers of a changed protocol

    private func conformers() -> [Finding] {
        // Head containers by the names they conform to or inherit from.
        var inheritors: [String: [Located]] = [:]
        // "Type|member" -> head members, across every file and component.
        var members: [String: [Located]] = [:]
        for path in b.head.files.keys.sorted() {
            guard let file = b.head.files[path], let comp = b.head.layout.fileComponent[path] else { continue }
            for (i, d) in file.decls.enumerated() {
                let l = Located(decl: d, file: path, index: i, component: comp)
                if d.isContainer { for c in d.inherited.map(ModelBuilder.conformanceName) { inheritors[c, default: []].append(l) } }
                if let scope = d.scope { members["\(scope)|\(d.name)", default: []].append(l) }
            }
        }
        let changedHead = Set(b.pairs.compactMap { p -> String? in
            guard let h = p.head, !p.changes.isEmpty, p.changes != [.cosmetic] else { return nil }
            return "\(h.file)|\(h.index)"
        })
        var out: [Finding] = []
        for p in b.pairs {
            guard let h = p.head, !isLow(h, .head), let parent = decl(.head, h.file, h.decl.parentIndex) else { continue }
            let abstract = parent.kind == .class && h.decl.modifiers.contains("abstract")
            guard h.decl.inProtocol || abstract, p.changes.contains(.added) || p.changes.contains(.signature) else { continue }
            let proto = parent.qualifiedName
            // Default implementations in an extension of the protocol cover every conformer.
            if !abstract, (members["\(proto)|\(h.decl.name)"] ?? []).contains(where: { decl(.head, $0.file, $0.decl.parentIndex)?.kind == .extension }) { continue }
            var missing: [Located] = [], stale: [Located] = []
            for c in inheritors[proto] ?? [] where c.decl.kind != .protocol && !(c.decl.kind == .extension && c.decl.name == proto) && !isLow(c, .head) {
                // Only conformers that can see the protocol: the same component, or one that depends on it.
                guard c.component == h.component || b.edgeRefs[.head]![c.component]?[h.component] != nil else { continue }
                let type = c.decl.kind == .extension ? c.decl.name : c.decl.qualifiedName
                let impl = (members["\(type)|\(h.decl.name)"] ?? []).filter { $0.decl.kind == h.decl.kind || ModelBuilder.kindGroup($0.decl.kind) == ModelBuilder.kindGroup(h.decl.kind) }
                if impl.isEmpty {
                    if !(missing.contains { $0.decl.qualifiedName == c.decl.qualifiedName }) { missing.append(c) }
                } else if p.changes.contains(.signature) && !impl.contains(where: { changedHead.contains("\($0.file)|\($0.index)") }) {
                    if !(stale.contains { $0.decl.qualifiedName == c.decl.qualifiedName }) { stale.append(c) }
                }
            }
            guard !missing.isEmpty || !stale.isEmpty else { continue }
            let what = p.changes.contains(.added) ? "New requirement" : "Changed requirement"
            let typeName = { (c: Located) in c.decl.kind == .extension ? c.decl.name : c.decl.qualifiedName }
            var evidence: [String] = []
            if !missing.isEmpty { evidence.append("No \(h.decl.name) in \(missing.map(typeName).joined(separator: ", ")), and no default implementation in an extension of \(proto).") }
            if !stale.isEmpty { evidence.append("\(stale.map { "\(typeName($0)).\(h.decl.name)" }.joined(separator: ", ")) didn't change with it.") }
            let all = missing + stale
            out.append(Finding(
                id: "", source: "check", kind: "conformers", severity: missing.isEmpty ? "medium" : "high",
                message: "\(what) \(h.decl.qualifiedName): \(all.count) conformer\(all.count == 1 ? " wasn't" : "s weren't") updated.",
                evidence: evidence,
                suggestion: missing.isEmpty ? "Check that each implementation still does what the new signature promises." : "Implement it in each conformer, or add a default implementation.",
                anchors: [entityIds.contains(p.id) ? .entity(p.id) : .component(h.component)] + Array(Set(all.map(\.component))).sorted().map(Anchor.component),
                location: all.first.map { location($0, .head) }))
        }
        return out
    }

    // MARK: Changed code no test references

    private func untested() -> [Finding] {
        let hasTests = b.head.files.keys.contains { path in
            ComponentBuilder.isTestPath(path) || b.head.layout.fileComponent[path].flatMap { b.head.layout.components[$0] }?.isTest == true
        }
        guard hasTests else { return [] }
        // Only components that tests reach at all: ones a test component depends on, or with test files of their own.
        // A component no test touches (a scripts folder) would only repeat that it has no tests.
        var tested = Set<String>()
        for (from, tos) in b.edgeRefs[.head]! where isTestComponent(from) { tested.formUnion(tos.keys.map { root($0, .head) }) }
        for (path, comp) in b.head.layout.fileComponent where ComponentBuilder.isTestPath(path) { tested.insert(root(comp, .head)) }
        var pairOfId: [String: Pair] = [:]
        for p in b.pairs { pairOfId[p.id] = p }
        var byComponent: [String: [Entity]] = [:]
        for e in entities where e.change != .cosmetic && e.change != .removed && [.func, .`init`, .var].contains(e.kind)
            && !e.tags.contains("test") && !e.tags.contains("generated") && !isTestComponent(e.component) && tested.contains(root(e.component, .head)) {
            guard let p = pairOfId[e.id], let h = p.head else { continue }
            let d = h.decl
            if ["private", "fileprivate", "#private", "protected"].contains(d.access ?? "") { continue }
            let parent = decl(.head, h.file, d.parentIndex)
            let inherits = Set((parent?.inherited ?? []).map(ModelBuilder.conformanceName))
            if b.language(of: h.file).isViewCode(d, inherits: inherits) { continue }
            // An initializer is used through its type's name.
            var probe = h
            if d.kind == .`init`, let parent, let pi = d.parentIndex { probe = Located(decl: parent, file: h.file, index: pi, component: h.component) }
            if references(probe, .head).contains(where: \.isTest) { continue }
            byComponent[e.component, default: []].append(e)
        }
        return byComponent.keys.sorted().map { comp in
            let list = byComponent[comp]!
            return Finding(
                id: "", source: "check", kind: "untested", severity: "low",
                message: "No test references \(list.count == 1 ? list[0].qualifiedName : "\(list.count) changed entities") in \(name(comp)).",
                evidence: list.prefix(10).map { "\($0.kind.rawValue) \($0.qualifiedName) (\($0.change.rawValue))" } + (list.count > 10 ? ["and \(list.count - 10) more"] : []),
                suggestion: nil,
                anchors: [.component(comp)] + list.map { .entity($0.id) })
        }
    }
}

// MARK: - Similar names

extension ModelBuilder {
    /// "loadCartItems" -> ["load", "cart", "items"]; "load_cart" -> ["load", "cart"].
    static func nameWords(_ name: String) -> [String] {
        var words: [String] = []
        var cur = ""
        var prevLower = false
        for ch in name {
            if ch == "_" || ch == "$" || !(ch.isLetter || ch.isNumber) {
                if !cur.isEmpty { words.append(cur.lowercased()); cur = "" }
                prevLower = false
                continue
            }
            if ch.isUppercase && prevLower && !cur.isEmpty { words.append(cur.lowercased()); cur = "" }
            cur.append(ch)
            prevLower = ch.isLowercase || ch.isNumber
        }
        if !cur.isEmpty { words.append(cur.lowercased()) }
        return words
    }

    /// For each added entity, existing head declarations whose names are close: the same name in another
    /// scope, most of the same words, or a near-identical spelling. Up to 5 each, closest first.
    func similarDeclarations(_ entities: [Entity]) -> [String: [Usage]] {
        struct Candidate { var located: Located; var words: Set<String> }
        var byWord: [String: [Int]] = [:]
        var candidates: [Candidate] = []
        let addedHead = Set(pairs.compactMap { p in p.base == nil ? p.head.map { "\($0.file)|\($0.index)" } : nil })
        for path in head.files.keys.sorted() where !head.generated.contains(path) && !ComponentBuilder.isTestPath(path) {
            guard let file = head.files[path], let comp = head.layout.fileComponent[path], head.layout.components[comp]?.isTest != true else { continue }
            for (i, d) in file.decls.enumerated() where d.kind != .extension && !addedHead.contains("\(path)|\(i)") && !implicitNames.contains(d.name) {
                let w = Set(Self.nameWords(d.name))
                guard !w.isEmpty else { continue }
                for x in w { byWord[x, default: []].append(candidates.count) }
                candidates.append(Candidate(located: Located(decl: d, file: path, index: i, component: comp), words: w))
            }
        }
        var pairById: [String: Pair] = [:]
        for p in pairs { pairById[p.id] = p }
        var out: [String: [Usage]] = [:]
        for e in entities where e.change == .added && !e.tags.contains("test") && !e.tags.contains("generated") {
            guard let h = pairById[e.id]?.head, h.decl.kind != .case, !implicitNames.contains(h.decl.name) else { continue }
            let name = h.decl.name
            let words = Set(Self.nameWords(name))
            var scored: [(Double, Located)] = []
            var seen = Set<Int>()
            for w in words { for ci in byWord[w] ?? [] where seen.insert(ci).inserted {
                let c = candidates[ci]
                guard Self.kindGroup(c.located.decl.kind) == Self.kindGroup(h.decl.kind) else { continue }
                let cn = c.located.decl.name
                var score = 0.0
                if cn == name {
                    // A short common name ("load", "id") in another type says little.
                    if words.count >= 2 || name.count >= 8 { score = 1 }
                } else {
                    let jaccard = Double(words.intersection(c.words).count) / Double(words.union(c.words).count)
                    if words.count >= 2 && jaccard >= 0.66 { score = jaccard * 0.9 }
                    if name.count >= 6, abs(cn.count - name.count) <= 2, Self.editDistance(cn.lowercased(), name.lowercased()) <= 2 { score = max(score, 0.8) }
                }
                if score > 0 { scored.append((score, c.located)) }
            } }
            guard !scored.isEmpty else { continue }
            scored.sort { ($0.0, $1.1.decl.qualifiedName) > ($1.0, $0.1.decl.qualifiedName) }
            out[e.id] = scored.prefix(5).map { Usage(component: $0.1.component, symbol: $0.1.decl.qualifiedName, file: $0.1.file, line: $0.1.decl.startLine) }
        }
        return out
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
