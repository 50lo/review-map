import Foundation

// Review, removed, and context regions: where in each changed entity the reviewer should look,
// how risky each place is, and which unchanged code explains it. Everything here is
// deterministic; the weights follow the brief's starting table and are meant to be tuned.

private let high = 0.6
private let medium = 0.3
private let base = 0.1

private let concurrencyFlags = ["mainactor-", "nonisolated-", "sendable-", "async-", "conformance-isolation-changed",
                                "kind-changed", "default-isolation-changed", "strict-concurrency-changed"]
private let persistenceFlags = ["codable-shape", "swiftdata-model-changed", "coredata-model-changed"]
private let configFlags = ["info-plist-changed", "build-settings-changed", "deployment-target-changed",
                           "swift-version-changed", "swift-features-changed"]

private struct Signal {
    var weight: Double
    var reason: String
}

/// A run of changed lines in one entity: head lines, removed base lines, or both.
struct ChangeBlock: Equatable {
    var head: ClosedRange<Int>?
    var base: ClosedRange<Int>?
    /// The last unchanged head line before the block.
    var anchor: Int
}

private struct Indexed {
    var component: String
    var file: String
    var index: Int
    var decl: Decl
}

private struct ContextItem {
    var file: String
    var startLine: Int
    var endLine: Int
    var relation: String
    var label: String
    var component: String
    var lines: [Int]?
    var supports: [String]
}

extension ModelBuilder {
    func buildRegions(_ entities: [Entity]) -> [Region] {
        let ctx = RegionBuilder(self)
        var pairById: [String: Int] = [:]
        for (i, p) in pairs.enumerated() { pairById[p.id] = i }
        var out: [Region] = []
        for e in entities where e.change != .cosmetic {
            out += ctx.regions(for: e, pair: pairById[e.id].map { pairs[$0] })
        }
        return out
    }
}

private final class RegionBuilder {
    let b: ModelBuilder
    private var lineCache: [String: [String]] = [:]
    /// "component|scope" -> head declarations directly inside that type scope (members and extensions' members).
    private var members: [String: [Indexed]] = [:]
    /// Top-level head declarations by simple name (no extensions).
    private var topLevel: [String: [Indexed]] = [:]
    /// Type name -> head types and extensions that list it in their inheritance clause.
    private var inheritors: [String: [Indexed]] = [:]
    /// "component|Type" -> head type declarations (not extensions).
    private var types: [String: [Indexed]] = [:]
    private var viewTypes = Set<String>()
    /// Head declarations whose entity changed.
    private var changedHead = Set<DeclKey>()

    init(_ b: ModelBuilder) {
        self.b = b
        for path in b.head.files.keys.sorted() {
            guard let file = b.head.files[path], let comp = b.head.layout.fileComponent[path] else { continue }
            for (i, d) in file.decls.enumerated() {
                let item = Indexed(component: comp, file: path, index: i, decl: d)
                if let scope = d.scope { members["\(comp)|\(scope)", default: []].append(item) }
                if d.isTopLevel && d.kind != .extension { topLevel[d.name, default: []].append(item) }
                if d.isContainer {
                    let typeName = d.kind == .extension ? d.name : d.qualifiedName
                    if d.kind != .extension { types["\(comp)|\(typeName)", default: []].append(item) }
                    for c in d.inherited.map(ModelBuilder.conformanceName) {
                        inheritors[c, default: []].append(item)
                        if c == "View" || c == "ViewModifier" { viewTypes.insert("\(comp)|\(typeName)") }
                    }
                }
            }
        }
        for p in b.pairs where !p.changes.isEmpty && p.changes != [.cosmetic] {
            if let h = p.head { changedHead.insert(DeclKey(side: .head, file: h.file, index: h.index)) }
        }
    }

    private func lines(_ side: Side, _ file: String) -> [String] {
        let key = "\(side.rawValue):\(file)"
        if let l = lineCache[key] { return l }
        let text = (try? String(contentsOfFile: b.side(side).dir + "/" + file, encoding: .utf8)) ?? ""
        let l = text.components(separatedBy: "\n")
        lineCache[key] = l
        return l
    }

    private func slice(_ side: Side, _ file: String, _ r: ClosedRange<Int>) -> [String] {
        let all = lines(side, file)
        let lo = max(1, r.lowerBound), hi = min(all.count, r.upperBound)
        return lo <= hi ? Array(all[(lo - 1)...(hi - 1)]) : []
    }

    // MARK: Review regions

    func regions(for e: Entity, pair: Pair?) -> [Region] {
        let isLow = e.tags.contains("test") || e.tags.contains("generated")
        guard let pair, e.kind != .file, e.kind != .target else {
            // Non-code contracts: one region over the file or setting, scored by its flags.
            var signals = flagSignals(e)
            signals.append(Signal(weight: base, reason: e.change == .added ? "new file" : e.change == .removed ? "removed file" : "changed"))
            let r = Region(id: "\(e.id)/r1", entity: e.id, kind: e.change == .removed ? "removed" : "review",
                           file: e.location.file, startLine: e.location.startLine, endLine: e.location.endLine,
                           side: e.location.side, risk: score(signals, low: isLow), reasons: reasons(signals, e: e, low: isLow))
            return [r]
        }
        let hd = pair.head, bd = pair.base
        let range: (Decl) -> ClosedRange<Int> = { d in d.startLine...(d.isContainer ? max(d.startLine, d.headerEndLine) : d.endLine) }
        let header: (Decl) -> ClosedRange<Int> = { d in d.startLine...max(d.startLine, d.headerEndLine) }

        var blocks: [ChangeBlock] = []
        if let hd, let bd {
            blocks = Self.blocks(base: slice(.base, bd.file, range(bd.decl)), baseStart: bd.decl.startLine,
                                 head: slice(.head, hd.file, range(hd.decl)), headStart: hd.decl.startLine)
        } else if let hd {
            blocks = [ChangeBlock(head: range(hd.decl), base: nil, anchor: hd.decl.startLine - 1)]
        } else if let bd {
            blocks = [ChangeBlock(head: nil, base: range(bd.decl), anchor: 0)]
        }
        let isHeader: (ChangeBlock) -> Bool = { blk in
            if let h = blk.head, let hd, h.overlaps(header(hd.decl)) { return true }
            if blk.head == nil, let bb = blk.base, let bd, bb.overlaps(header(bd.decl)) { return true }
            return false
        }
        var headerIndex = blocks.firstIndex(where: isHeader)
        if headerIndex == nil, let hd, blocks.isEmpty || !e.contractFlags.isEmpty {
            // Flags that come from members or extensions (a Codable shape, a conformance) belong on the declaration line.
            blocks.insert(ChangeBlock(head: header(hd.decl), base: nil, anchor: hd.decl.startLine - 1), at: 0)
            headerIndex = 0
        }

        let ui = isUI(e, hd)
        let usedFrom = Set(e.usedBy.map(\.component).filter { b.head.layout.components[$0]?.isTest != true && $0 != e.component }).count
        var out: [Region] = []
        for (n, blk) in blocks.enumerated() {
            var signals: [Signal] = []
            if n == headerIndex {
                signals += flagSignals(e)
                if e.isInterface && e.contractFlags.isEmpty && e.changes.contains(.signature) && bd != nil && hd != nil {
                    signals.append(Signal(weight: medium, reason: "interface signature changed"))
                }
                if hd == nil && e.isInterface { signals.append(Signal(weight: medium, reason: "interface removed")) }
            }
            signals += markSignals(blk, head: hd, base: bd, ui: ui)
            if usedFrom > 0 && e.isInterface {
                signals.append(Signal(weight: 0.05 * Double(min(usedFrom, 4)), reason: "used from \(usedFrom) component\(usedFrom == 1 ? "" : "s")"))
            }
            let fallback = hd == nil ? "removed declaration" : bd == nil ? "new declaration"
                : blk.head == nil ? "removed lines" : n == headerIndex && e.changes.contains(.signature) ? "signature changed"
                : n == headerIndex && e.changes.contains(.modifiers) ? "modifiers changed" : "changed lines"
            signals.append(Signal(weight: base, reason: fallback))
            let risk = score(signals, low: isLow)
            let why = reasons(signals, e: e, low: isLow)
            if let h = blk.head, let hd {
                out.append(Region(id: "", entity: e.id, kind: "review", file: hd.file, startLine: h.lowerBound, endLine: h.upperBound,
                                  side: .head, risk: risk, reasons: why))
            } else if let bb = blk.base, let bd {
                out.append(Region(id: "", entity: e.id, kind: "removed", file: bd.file, startLine: bb.lowerBound, endLine: bb.upperBound,
                                  side: .base, risk: risk, reasons: why, anchor: hd != nil ? blk.anchor : nil))
            }
        }
        for i in out.indices { out[i].id = "\(e.id)/r\(i + 1)" }
        if isLow || hd == nil { return out }
        let headerId = headerIndex.map { out[$0].id } ?? out.first?.id
        return out + context(for: e, pair: pair, regions: out, headerId: headerId)
    }

    private func flagSignals(_ e: Entity) -> [Signal] {
        e.contractFlags.map { f in
            if concurrencyFlags.contains(where: { f.hasPrefix($0) }) || persistenceFlags.contains(f) { return Signal(weight: high, reason: f) }
            if configFlags.contains(f) { return Signal(weight: medium, reason: f) }
            return Signal(weight: e.isInterface ? high : medium, reason: f)
        }
    }

    private func marks(_ side: Side, _ file: String, _ r: ClosedRange<Int>?) -> [LineMark: Int] {
        guard let r, let parsed = b.side(side).files[file] else { return [:] }
        var counts: [LineMark: Int] = [:]
        for line in r { for m in parsed.marks[line] ?? [] { counts[m, default: 0] += 1 } }
        return counts
    }

    private func markSignals(_ blk: ChangeBlock, head: Located?, base bd: Located?, ui: Bool) -> [Signal] {
        // A deleted declaration is judged by what used it, not by the checks it contained.
        if head == nil { return [] }
        let hm = head.map { marks(.head, $0.file, blk.head) } ?? [:]
        let bm = bd.map { marks(.base, $0.file, blk.base) } ?? [:]
        var signals: [Signal] = []
        func labels(_ kind: LineMark.Kind, _ pred: (Int, Int) -> Bool) -> [String] {
            Set(hm.keys).union(bm.keys).filter { $0.kind == kind && pred(hm[$0] ?? 0, bm[$0] ?? 0) }.map(\.label).sorted()
        }
        let removedChecks = labels(.check) { h, b in b > h }
        if !removedChecks.isEmpty { signals.append(Signal(weight: high, reason: removedChecks.map { "\($0) removed" }.joined(separator: ", "))) }
        // Isolation annotations in code are high; tasks, continuations, and locks are medium.
        let isAnnotation: (String) -> Bool = { $0.hasPrefix("@") || $0.hasPrefix("nonisolated") }
        let addedConc = labels(.concurrency) { h, b in h > b }
        let removedConc = labels(.concurrency) { h, b in b > h }
        if !addedConc.isEmpty {
            signals.append(Signal(weight: addedConc.contains(where: isAnnotation) ? high : medium, reason: "concurrency: " + addedConc.joined(separator: ", ")))
        }
        if !removedConc.isEmpty {
            signals.append(Signal(weight: removedConc.contains(where: isAnnotation) ? high : medium, reason: "concurrency removed: " + removedConc.joined(separator: ", ")))
        }
        let crashes = labels(.crash) { h, b in h > b }
        if !crashes.isEmpty { signals.append(Signal(weight: medium, reason: crashes.map { "new \($0)" }.joined(separator: ", "))) }
        let flow = labels(.flow) { h, b in h + b > 0 }
        if !flow.isEmpty {
            signals.append(Signal(weight: ui ? base * 1.5 : medium, reason: (ui ? "view control flow: " : "control flow: ") + flow.prefix(4).joined(separator: ", ")))
        }
        return signals
    }

    private func isUI(_ e: Entity, _ hd: Located?) -> Bool {
        if b.head.layout.components[e.component]?.layer == "ui" { return true }
        guard let d = hd?.decl else { return false }
        if d.signatureDisplay.contains("some View") || (d.typeAnnotation ?? "").contains("View") { return true }
        if let scope = d.scope, viewTypes.contains("\(hd!.component)|\(scope)") { return true }
        return d.isContainer && viewTypes.contains("\(hd!.component)|\(d.kind == .extension ? d.name : d.qualifiedName)")
    }

    private func score(_ signals: [Signal], low: Bool) -> Double {
        let r = 1 - signals.reduce(1.0) { $0 * (1 - $1.weight) }
        return ((low ? r * 0.2 : r) * 1000).rounded() / 1000
    }

    private func reasons(_ signals: [Signal], e: Entity, low: Bool) -> [String] {
        var sorted = signals.enumerated().sorted { ($0.element.weight, -$0.offset) > ($1.element.weight, -$1.offset) }.map(\.element)
        // The fallback only explains a region that has no other reason.
        if sorted.count > 1 { sorted.removeAll { $0.weight == base && ["new declaration", "removed declaration", "removed lines", "signature changed", "modifiers changed", "changed lines", "changed", "new file", "removed file"].contains($0.reason) } }
        var out = sorted.map(\.reason)
        if low { out.append(e.tags.contains("generated") ? "generated code" : "test code") }
        return out
    }

    /// Changed blocks between the base and head lines of one entity, ignoring indentation,
    /// spacing, and blank lines.
    static func blocks(base: [String], baseStart: Int, head: [String], headStart: Int) -> [ChangeBlock] {
        func norm(_ s: String) -> String {
            s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).joined(separator: " ")
        }
        let bf = base.enumerated().map { ($0.offset, norm($0.element)) }.filter { !$0.1.isEmpty }
        let hf = head.enumerated().map { ($0.offset, norm($0.element)) }.filter { !$0.1.isEmpty }
        let pairs = lcs(bf.map(\.1), hf.map(\.1))
        var out: [ChangeBlock] = []
        var pb = -1, ph = -1
        for (i, j) in pairs + [(bf.count, hf.count)] {
            let bRange = pb + 1 < i ? (baseStart + bf[pb + 1].0)...(baseStart + bf[i - 1].0) : nil
            let hRange = ph + 1 < j ? (headStart + hf[ph + 1].0)...(headStart + hf[j - 1].0) : nil
            if bRange != nil || hRange != nil {
                out.append(ChangeBlock(head: hRange, base: bRange, anchor: ph >= 0 ? headStart + hf[ph].0 : headStart - 1))
            }
            pb = i
            ph = j
        }
        return out
    }

    /// Longest common subsequence as index pairs. Common prefix and suffix are matched first;
    /// a middle too large to compare is treated as fully replaced.
    static func lcs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        var pre = 0
        while pre < n && pre < m && a[pre] == b[pre] { pre += 1 }
        var suf = 0
        while suf < n - pre && suf < m - pre && a[n - 1 - suf] == b[m - 1 - suf] { suf += 1 }
        var out: [(Int, Int)] = (0..<pre).map { ($0, $0) }
        let an = n - pre - suf, bm = m - pre - suf
        if an > 0 && bm > 0 && an * bm <= 4_000_000 {
            let w = bm + 1
            var t = [Int32](repeating: 0, count: (an + 1) * w)
            for i in stride(from: an - 1, through: 0, by: -1) {
                for j in stride(from: bm - 1, through: 0, by: -1) {
                    t[i * w + j] = a[pre + i] == b[pre + j] ? t[(i + 1) * w + j + 1] + 1 : max(t[(i + 1) * w + j], t[i * w + j + 1])
                }
            }
            var i = 0, j = 0
            while i < an && j < bm {
                if a[pre + i] == b[pre + j] {
                    out.append((pre + i, pre + j))
                    i += 1
                    j += 1
                } else if t[(i + 1) * w + j] >= t[i * w + j + 1] {
                    i += 1
                } else {
                    j += 1
                }
            }
        }
        out += (0..<suf).map { (n - suf + $0, m - suf + $0) }
        return out
    }

    // MARK: Context regions

    private func context(for e: Entity, pair: Pair, regions: [Region], headerId: String?) -> [Region] {
        guard let hd = pair.head else { return [] }
        let d = hd.decl
        var items: [ContextItem] = []
        var keys: [String: Int] = [:]
        func add(_ it: ContextItem) {
            // Never point at the entity itself.
            if it.file == hd.file && it.startLine == d.startLine { return }
            // One snippet per declaration; a specific relation (override, conformer) wins over caller.
            let key = "\(it.file)|\(it.startLine)|\(it.endLine)"
            if let i = keys[key] {
                for s in it.supports where !items[i].supports.contains(s) { items[i].supports.append(s) }
                if items[i].relation == "caller" && (it.relation == "override" || it.relation == "conformer") {
                    items[i].relation = it.relation
                    items[i].lines = it.lines
                }
                return
            }
            keys[key] = items.count
            items.append(it)
        }
        func declItem(_ x: Indexed, relation: String, supports: [String], extraLines: [Int] = []) -> ContextItem {
            let span = x.decl.endLine - x.decl.startLine + 1
            var lines: [Int]?
            if span > 12 || !extraLines.isEmpty {
                let head = Array(x.decl.startLine...min(max(x.decl.startLine, x.decl.headerEndLine), x.decl.startLine + 2))
                lines = Array(Set(head + extraLines)).sorted()
                if span <= 12 && relation != "caller" { lines = nil }
            }
            return ContextItem(file: x.file, startLine: x.decl.startLine, endLine: x.decl.endLine, relation: relation,
                               label: x.decl.qualifiedName, component: x.component, lines: lines, supports: supports)
        }
        let headerSupports = headerId.map { [$0] } ?? []
        let reviewRegions = regions.filter { $0.kind == "review" }

        // Definitions of what the changed lines reference.
        var definitions = 0
        let parsed = b.head.files[hd.file]
        // Index mode: the exact declarations the changed lines reference.
        if let refs = b.index[.head]?.refs[hd.file] {
            for r in reviewRegions where definitions < 6 {
                var perRegion = 0
                for ref in refs where ref.line >= r.startLine && ref.line <= r.endLine && perRegion < 4 && definitions < 6 {
                    guard let comp = b.head.layout.fileComponent[ref.targetFile],
                          let t = b.declAt(.head, file: ref.targetFile, line: ref.targetLine, name: ref.name) else { continue }
                    let x = Indexed(component: comp, file: ref.targetFile, index: t.index, decl: t.decl)
                    // Not the entity or its own parts, nothing that changed (it has its own entity), and no
                    // stored properties of the same type (state context shows those).
                    if x.file == hd.file && x.decl.startLine >= d.startLine && x.decl.endLine <= d.endLine { continue }
                    if x.file == hd.file && d.startLine >= x.decl.startLine && d.endLine <= x.decl.endLine { continue }
                    if changedHead.contains(DeclKey(side: .head, file: x.file, index: x.index)) { continue }
                    if x.decl.kind == .var && x.decl.isStored && x.decl.scope != nil && x.decl.scope == d.scope { continue }
                    let before = items.count
                    add(declItem(x, relation: "definition", supports: [r.id]))
                    if items.count > before { perRegion += 1; definitions += 1 }
                }
            }
        }
        for r in reviewRegions where definitions < 6 && b.index[.head]?.refs[hd.file] == nil {
            var names: [(String, Bool)] = []
            var seen = Set<String>()
            let refs = ((parsed?.typeRefs ?? []).map { ($0, false) } + (parsed?.memberRefs ?? []).map { ($0, true) })
                .filter { $0.0.line >= r.startLine && $0.0.line <= r.endLine }
                .sorted { ($0.0.line, $0.0.name) < ($1.0.line, $1.0.name) }
            for (ref, isMember) in refs where !seen.contains(ref.name) && ref.name != d.name {
                seen.insert(ref.name)
                names.append((ref.name, isMember))
            }
            var perRegion = 0
            for (name, isMember) in names where perRegion < 4 && definitions < 6 {
                guard let x = definition(of: name, member: isMember, from: hd, entityRange: d.startLine...d.endLine),
                      !changedHead.contains(DeclKey(side: .head, file: x.file, index: x.index)) else { continue }
                let before = items.count
                add(declItem(x, relation: "definition", supports: [r.id]))
                if items.count > before { perRegion += 1; definitions += 1 }
            }
        }

        // Callers, for changes that reach them.
        if e.isInterface || e.changes.contains(.signature) || e.changes.contains(.modifiers) || !e.contractFlags.isEmpty {
            for it in callers(of: e, hd: hd, supports: headerSupports) { add(it) }
        }

        // Other conformers of a changed protocol, and their implementations of a changed requirement.
        if d.kind == .protocol || d.parentKind == .protocol {
            let proto = d.kind == .protocol ? d.name : (d.scope ?? "")
            let requirement = d.kind == .protocol ? nil : d.name
            var n = 0
            for t in inheritors[proto] ?? [] where n < 5 {
                let typeName = t.decl.kind == .extension ? t.decl.name : t.decl.qualifiedName
                if let req = requirement {
                    let impls = (members["\(t.component)|\(typeName)"] ?? []).filter { $0.decl.name == req }
                    guard let impl = impls.first else { continue }
                    add(declItem(impl, relation: "conformer", supports: headerSupports))
                } else {
                    var it = declItem(t, relation: "conformer", supports: headerSupports)
                    it.lines = Array(t.decl.startLine...max(t.decl.startLine, t.decl.headerEndLine))
                    add(it)
                }
                n += 1
            }
        }

        // Overrides of a changed method, and the method a changed override overrides.
        if (d.kind == .func || d.kind == .var), let scope = d.scope, d.parentKind == .class || d.modifiers.contains("override") {
            var n = 0
            for sub in inheritors[scope] ?? [] where n < 5 {
                let subName = sub.decl.kind == .extension ? sub.decl.name : sub.decl.qualifiedName
                for m in members["\(sub.component)|\(subName)"] ?? [] where m.decl.labelsKey == d.labelsKey && m.decl.modifiers.contains("override") {
                    add(declItem(m, relation: "override", supports: headerSupports))
                    n += 1
                }
            }
            if d.modifiers.contains("override"),
               let owner = types["\(hd.component)|\(scope)"]?.first, let superName = owner.decl.inherited.first.map(ModelBuilder.conformanceName) {
                for (key, ms) in members where key.hasSuffix("|\(superName)") {
                    for m in ms where m.decl.labelsKey == d.labelsKey { add(declItem(m, relation: "override", supports: headerSupports)) }
                }
            }
        }

        // The stored properties of the enclosing type, which carry the invariants a changed body relies on.
        let isBody = d.kind == .func || d.kind == .`init` || (d.kind == .var && !d.isStored)
        if isBody, let scope = d.scope, d.parentKind != .protocol, e.changes.contains(.body) || e.change == .added {
            let props = (members["\(hd.component)|\(scope)"] ?? []).filter { $0.decl.kind == .var && $0.decl.isStored && !$0.decl.isStatic }
            for (file, ps) in Dictionary(grouping: props, by: \.file).sorted(by: { $0.key < $1.key }) {
                let lines = ps.flatMap { Array($0.decl.startLine...$0.decl.endLine) }.sorted()
                add(ContextItem(file: file, startLine: lines.first!, endLine: lines.last!, relation: "state",
                                label: "stored properties of \(scope)", component: hd.component, lines: lines,
                                supports: regions.map(\.id)))
            }
        }

        return items.enumerated().map { i, it in
            Region(id: "\(e.id)/c\(i + 1)", entity: e.id, kind: "context", file: it.file, startLine: it.startLine, endLine: it.endLine,
                   side: .head, risk: 0, reasons: [it.label], supports: it.supports, relation: it.relation,
                   component: it.component, lines: it.lines)
        }
    }

    /// The unchanged declaration a name in changed code refers to, when it can be told by name.
    private func definition(of name: String, member: Bool, from hd: Located, entityRange: ClosedRange<Int>) -> Indexed? {
        let d = hd.decl
        let comp = hd.component
        // Members of the same type: `helper()`, `self.helper()`. Stored properties are covered by state context.
        if let scope = d.scope ?? (d.isContainer ? (d.kind == .extension ? d.name : d.qualifiedName) : nil) {
            let same = (members["\(comp)|\(scope)"] ?? []).filter { $0.decl.name == name && !($0.decl.kind == .var && $0.decl.isStored) && !$0.decl.isContainer }
            if let x = same.first { return x }
        }
        let file = b.head.files[hd.file]
        let visibleModules = Set((file?.imports ?? []).map(\.name))
        let visible: (String) -> Bool = { c in
            c == comp || (self.b.head.layout.components[c]?.module).map { visibleModules.contains($0) } ?? false
        }
        if !member {
            let cands = (topLevel[name] ?? []).filter { visible($0.component) }
            if Set(cands.map(\.component)).count == 1 { return cands.first }
            return nil
        }
        // `x.foo`: a member of a type the entity mentions, if exactly one such type declares it.
        var typeNames = Set<String>()
        for ref in file?.typeRefs ?? [] where entityRange.contains(ref.line) && ref.name.first?.isUppercase == true { typeNames.insert(ref.name) }
        if let scope = d.scope {
            for p in (members["\(comp)|\(scope)"] ?? []) where p.decl.isStored {
                for ref in b.head.files[p.file]?.typeRefs ?? [] where (p.decl.startLine...p.decl.endLine).contains(ref.line) { typeNames.insert(ref.name) }
            }
        }
        var found: [Indexed] = []
        var owners = Set<String>()
        for t in typeNames {
            for c in (topLevel[t] ?? []).map(\.component) where visible(c) {
                let ms = (members["\(c)|\(t)"] ?? []).filter { $0.decl.name == name && !$0.decl.isContainer }
                if !ms.isEmpty { found += ms; owners.insert("\(c)|\(t)") }
            }
        }
        return owners.count == 1 ? found.first : nil
    }

    /// Declarations that reference the entity: other components first (from usedBy), then the
    /// entity's own component, tests last. At most five.
    private func callers(of e: Entity, hd: Located, supports: [String]) -> [ContextItem] {
        let d = hd.decl
        var byDecl: [String: (x: Indexed, lines: [Int], rank: Int)] = [:]
        var order: [String] = []
        func note(_ comp: String, _ file: String, _ line: Int) {
            guard let parsed = b.head.files[file], let encl = parsed.enclosingDecl(line: line),
                  let idx = parsed.decls.firstIndex(where: { $0.startLine == encl.startLine && $0.qualifiedName == encl.qualifiedName }) else { return }
            if file == hd.file && encl.startLine >= d.startLine && encl.endLine <= d.endLine { return }
            let key = "\(file)|\(encl.startLine)"
            if byDecl[key] == nil {
                let isTest = b.head.layout.components[comp]?.isTest == true || ComponentBuilder.isTestPath(file)
                byDecl[key] = (Indexed(component: comp, file: file, index: idx, decl: encl), [], isTest ? 2 : comp == e.component ? 1 : 0)
                order.append(key)
            }
            if !byDecl[key]!.lines.contains(line) { byDecl[key]!.lines.append(line) }
        }
        // Index mode: every exact reference, in any component.
        if !b.index.isEmpty, let pi = b.pairOf[DeclKey(side: .head, file: hd.file, index: hd.index)] {
            for u in b.indexCallers[pi] ?? [] { note(u.component, u.file, u.line) }
        } else {
            for u in e.usedBy { note(u.component, u.file, u.line) }
        }
        // Same-component references by name; members only count in files that mention their type.
        if b.index.isEmpty && !d.isContainer && d.name.count >= 4 && d.name != "init" {
            // The innermost type must be named in the file, or the reference must come from inside that type.
            let owner = d.scope.map { String($0.split(separator: ".").last ?? "") }
            for (path, file) in b.head.files.sorted(by: { $0.key < $1.key }) where b.head.layout.fileComponent[path] == e.component {
                let mentionsType = owner == nil || (file.typeRefs + file.memberRefs).contains { $0.name == owner }
                let refs = owner == nil ? file.typeRefs : file.memberRefs + file.typeRefs
                for ref in refs where ref.name == d.name {
                    let inside = d.scope != nil && file.enclosingDecl(line: ref.line).map { ($0.scope ?? "") == d.scope! || $0.qualifiedName == d.scope! } == true
                    if mentionsType || inside { note(e.component, path, ref.line) }
                }
            }
        }
        let ranked = order.enumerated().sorted { (byDecl[$0.element]!.rank, $0.offset) < (byDecl[$1.element]!.rank, $1.offset) }.map(\.element)
        return ranked.prefix(5).map { key in
            let v = byDecl[key]!
            let lines = Array(Set([v.x.decl.startLine] + v.lines)).sorted()
            return ContextItem(file: v.x.file, startLine: v.x.decl.startLine, endLine: v.x.decl.endLine, relation: "caller",
                               label: v.x.decl.qualifiedName, component: v.x.component, lines: lines, supports: supports)
        }
    }
}
