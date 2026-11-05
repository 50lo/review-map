import Foundation

// The LLM's structural review: one pass over the whole change. Its input is what a CI agent reading
// the diff doesn't have: the change's description, the edge diff with sample references, the interface
// diff, usage of the changed code (callers, how many, their isolation, the lines at the call sites),
// existing declarations with names like the new ones, and the deterministic findings. It asks whether
// the shape of the change matches its intent, and flags misplaced responsibilities, gaps, duplicates,
// and complexity the usage data shows isn't needed. Every finding cites its evidence and is anchored
// to a component, an edge, or an entity, so the viewer can show it on the map.

/// What the change says it does: a PR's title and body, or its commit messages.
struct ChangeDescription {
    var text: String
    /// "file", "pr", or "commits".
    var source: String

    static let maxChars = 8_000

    static func load(model: ChangeModel, file: String?) throws -> ChangeDescription? {
        if let file {
            let text = file == "-" ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                : try String(contentsOfFile: file, encoding: .utf8)
            return ChangeDescription(text: String(text.prefix(maxChars)), source: "file")
        }
        let root = model.repo.root
        // gh knows the PR of a branch; a detached head or a sha has none.
        if !model.repo.head.isEmpty, model.repo.head != "HEAD", model.repo.head != model.repo.headSha,
           let r = try? CLIRunner.exec(["gh", "pr", "view", model.repo.head, "--json", "title,body"], stdin: Data(), cwd: root, timeout: 20),
           r.status == 0, !r.timedOut,
           let obj = try? JSONSerialization.jsonObject(with: r.out) as? [String: Any], let title = obj["title"] as? String {
            let body = (obj["body"] as? String) ?? ""
            return ChangeDescription(text: String((title + "\n\n" + body).prefix(maxChars)), source: "pr")
        }
        let log = (try? Shell.string(["git", "-C", root, "log", "--format=%s%n%n%b", "\(model.repo.baseSha)..\(model.repo.headSha)"])) ?? ""
        let text = log.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : ChangeDescription(text: String(text.prefix(maxChars)), source: "commits")
    }
}

struct StructuralReview: @unchecked Sendable {
    let model: ChangeModel
    let sources: SourceReader
    let reviewNotes: String?
    let description: ChangeDescription?

    static let kinds = ["intent", "placement", "missing", "duplicate", "complexity"]
    static let maxFindings = 12
    /// Characters of changed code in the prompt; the riskiest regions go first.
    static let maxCodeChars = 80_000

    struct Reply: Codable, Equatable {
        struct Item: Codable, Equatable {
            var kind: String
            var severity: String
            var message: String
            var evidence: [String]
            var suggestion: String?
            var anchors: [Anchor]
        }
        var findings: [Item]
    }

    enum Outcome {
        case accepted(Reply)
        case rejected([String])
        case unavailable(String)
    }

    private var componentById: [String: Component] {
        Dictionary(model.components.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func name(_ id: String) -> String { componentById[id]?.name ?? id }

    /// Entities the review looks at: not cosmetic, test, or generated.
    private var reviewed: [Entity] {
        let tests = Set(model.components.filter(\.isTest).map(\.id))
        return model.entities.filter { e in
            e.change != .cosmetic && !tests.contains(e.component) && !e.tags.contains("test") && !e.tags.contains("generated")
        }
    }

    var isEmpty: Bool { reviewed.isEmpty && !model.edges.contains { $0.status != .unchanged } }

    // MARK: Prompt

    func prompt() -> String? {
        if isEmpty { return nil }
        let languages = (model.analyzer.languages ?? ["swift"]).map(Languages.displayName).joined(separator: " and ")
        var out = """
        You are reviewing the structure of a \(languages.isEmpty ? "code" : languages) change, not its lines. CI review agents \
        already read the diff. You have what they don't: both sides of the whole repo reduced to a dependency graph, \
        the interface diff, and how the changed code is used. Answer:

        - Does the shape of the change match its intent (the description below)? (kind "intent")
        - Do responsibilities sit in the right component, type, or layer? (kind "placement")
        - What's missing: a caller, a conformer, a test, a migration, an error path the change implies? (kind "missing")
        - What's duplicated: new code that re-implements an existing declaration or helper (see "Similar existing \
        declarations")? (kind "duplicate")
        - What's more complex than the usage shows it needs to be? (kind "complexity") In particular:
          - checks that can't fail: nil checks, guards, and validation for states the types or every caller already \
        rule out, and catch blocks for errors nothing throws;
          - concurrency protection for impossible scenarios: locks, actors, queues, or atomics around state only one \
        isolation domain touches;
          - algorithms and data structures beyond what the input needs: caches, memoization, or indexes for small \
        inputs or one-shot calls;
          - abstractions without a second use: protocols with one implementation, generics, factories, and options \
        nobody sets;
          - retries, fallbacks, and timeouts for failures that can't happen on that path;
          - re-implementations of helpers the repo already has.

        Rules:
        - Report only what the facts below support. Every finding cites its evidence from them, such as "the only \
        caller is @MainActor, so this lock guards nothing" or "3 callers, all pass a non-nil value".
        - Say what to remove, simplify, move, or add in "suggestion".
        - Anchor each finding to 1 to 3 things it is about, using ids exactly as listed: {"entity": "<entity id>"}, \
        {"component": "<component id>"}, or {"from": "<component id>", "to": "<component id>"} for a dependency edge.
        - Don't repeat the deterministic findings listed below; build on them only when you add something.
        - At most \(Self.maxFindings) findings, most important first. Fewer is better than weak ones; an empty list is fine.
        - severity: "high" (likely a defect or a design problem that will spread), "medium" (worth changing in this PR), \
        or "low" (worth knowing).
        - message: one sentence, at most 200 characters. Each evidence item and the suggestion: one line, at most 300.

        Reply with only a JSON object, no prose and no code fences:
        {"findings": [{"kind": "complexity", "severity": "medium", "message": "...", "evidence": ["..."], "suggestion": "...", "anchors": [{"entity": "..."}]}]}

        """
        if let d = description {
            out += "\n<description source=\"\(d.source == "pr" ? "pull request" : d.source == "commits" ? "commit messages" : "provided")\">\n\(d.text)\n</description>\n"
        } else {
            out += "\nThe change has no description; judge intent from the change itself.\n"
        }
        if let notes = reviewNotes {
            out += "\n<review-notes>\nThe repository's REVIEW.md, its own notes on what matters:\n\(notes)\n</review-notes>\n"
        }
        out += components() + edgeDiff() + interfaceDiff() + usage() + similar() + checks() + code()
        return out
    }

    private func components() -> String {
        let changed = model.components.filter { c in
            c.kind != .external && (c.changedEntities > 0 || c.status != nil || model.edges.contains { $0.status != .unchanged && ($0.from == c.id || $0.to == c.id) })
        }
        guard !changed.isEmpty else { return "" }
        var out = "\n## Components\n"
        for c in changed.sorted(by: { $0.changeScore > $1.changeScore }) {
            var facts = [c.kind.rawValue]
            if let l = c.layer { facts.append("layer \(l)") }
            if c.isTest { facts.append("tests") }
            if let p = c.parent { facts.append("part of \(name(p))") }
            if let s = c.status { facts.append(s) }
            facts.append("\(c.changedEntities) changed entities")
            out += "- \(c.id) \"\(c.name)\": \(facts.joined(separator: ", "))\n"
        }
        return out
    }

    private func edgeDiff() -> String {
        let changed = model.edges.filter { $0.status != .unchanged }
        guard !changed.isEmpty else { return "" }
        var out = "\n## Dependency edges that changed (from uses to)\n"
        for e in changed.prefix(80) {
            out += "- \(e.from) → \(e.to) (\(name(e.from)) → \(name(e.to))): \(e.status.rawValue)"
            if !e.symbolsAdded.isEmpty { out += ", now uses \(e.symbolsAdded.prefix(10).joined(separator: ", "))" }
            if !e.symbolsRemoved.isEmpty { out += ", no longer uses \(e.symbolsRemoved.prefix(10).joined(separator: ", "))" }
            out += ", \(e.refCount) refs\n"
            for r in e.refs.prefix(3) {
                if r.line == 0 { out += "    \(r.file) (manifest): \(r.symbol)\n"; continue }
                let text = sources.lines(r.side, r.file).dropFirst(r.line - 1).first?.trimmingCharacters(in: .whitespaces) ?? ""
                out += "    \(r.side == .base ? "base " : "")\(r.file):\(r.line): \(String(text.prefix(160)))\n"
            }
        }
        if changed.count > 80 { out += "- and \(changed.count - 80) more\n" }
        return out
    }

    private func interfaceDiff() -> String {
        let iface = reviewed.filter(\.isInterface)
        guard !iface.isEmpty else { return "" }
        var out = "\n## Interface diff\n"
        for e in iface.prefix(120) {
            out += "- \(e.id): \(e.kind.rawValue), \(e.changes.map(\.rawValue).joined(separator: ", "))"
            if !e.contractFlags.isEmpty { out += ", flags \(e.contractFlags.joined(separator: ", "))" }
            out += "\n"
            if let b = e.signature.base, b != e.signature.head { out += "    base: \(b.replacingOccurrences(of: "\n", with: " "))\n" }
            if let h = e.signature.head { out += "    head: \(h.replacingOccurrences(of: "\n", with: " "))\n" }
        }
        if iface.count > 120 { out += "- and \(iface.count - 120) more\n" }
        return out
    }

    private func usage() -> String {
        let used = reviewed.filter { !$0.usedBy.isEmpty || !$0.dependsOn.isEmpty }
        let internalOnly = reviewed.filter { $0.usedBy.isEmpty && !$0.isInterface }
        var out = "\n## Usage of the changed entities\n"
        out += "Used by lists callers in other components at head, with the isolation the call runs in when known.\n"
        for e in used.prefix(100) {
            out += "- \(e.id)"
            if !e.usedBy.isEmpty {
                let comps = Set(e.usedBy.map(\.component)).sorted().map(name)
                let iso = Dictionary(grouping: e.usedBy, by: { $0.isolation ?? "unknown isolation" }).map { "\($0.value.count) \($0.key)" }.sorted()
                out += ": used by \(e.usedBy.count) in \(comps.joined(separator: ", ")) (\(iso.joined(separator: ", ")))\n"
                for u in e.usedBy.prefix(4) {
                    let text = sources.lines(.head, u.file).dropFirst(u.line - 1).first?.trimmingCharacters(in: .whitespaces) ?? ""
                    out += "    \(u.symbol) at \(u.file):\(u.line): \(String(text.prefix(160)))\n"
                }
            } else {
                out += ": no callers in other components\n"
            }
            if !e.dependsOn.isEmpty {
                out += "    depends on \(Array(Set(e.dependsOn.map { "\($0.symbol) (\(name($0.component)))" })).sorted().prefix(10).joined(separator: ", "))\n"
            }
        }
        if !internalOnly.isEmpty {
            out += "No callers in other components: \(internalOnly.prefix(60).map(\.qualifiedName).joined(separator: ", "))\(internalOnly.count > 60 ? ", …" : "")\n"
        }
        return out
    }

    private func similar() -> String {
        let items = reviewed.filter { !($0.similar ?? []).isEmpty }
        guard !items.isEmpty else { return "" }
        var out = "\n## Similar existing declarations (for added entities)\n"
        for e in items.prefix(60) {
            out += "- \(e.id) resembles " + e.similar!.map { "\($0.symbol) in \(name($0.component)) (\($0.file):\($0.line))" }.joined(separator: "; ") + "\n"
        }
        return out
    }

    private func checks() -> String {
        let found = model.findings.filter { $0.source == "check" }
        guard !found.isEmpty else { return "\n## Deterministic findings\nNone.\n" }
        var out = "\n## Deterministic findings (already reported)\n"
        for f in found.prefix(60) { out += "- \(f.kind): \(f.message)\n" }
        return out
    }

    /// The changed code itself, riskiest regions first, with a little context, until the budget runs out.
    private func code() -> String {
        let ids = Set(reviewed.map(\.id))
        let regions = model.regions.filter { $0.kind != "context" && ids.contains($0.entity) }
            .sorted { ($0.risk, $1.id) > ($1.risk, $0.id) }
        guard !regions.isEmpty else { return "" }
        var out = "\n## Changed code, riskiest first\n"
        var used = 0
        var left = 0
        for r in regions {
            let lines = sources.lines(r.side, r.file)
            let lo = max(1, r.startLine - 2), hi = min(lines.count, r.endLine + 2, r.startLine + 80)
            guard lo <= hi else { continue }
            var block = "\n### \(r.entity) (\(r.kind == "removed" ? "removed from base" : "head"), \(r.file):\(r.startLine)-\(r.endLine))\n"
            for n in lo...hi { block += "    \(n)| \(lines[n - 1])\n" }
            if used + block.count > Self.maxCodeChars { left += 1; continue }
            out += block
            used += block.count
        }
        if left > 0 { out += "\n(\(left) lower-risk regions left out.)\n" }
        return out
    }

    // MARK: Run and validate

    func run(prompt: String, runner: CLIRunner) -> Outcome {
        var errors: [String] = []
        for attempt in 0..<2 {
            let p = attempt == 0 ? prompt : prompt + "\n\nYour previous reply was rejected: " + errors.prefix(10).joined(separator: "; ")
                + ".\nReply again with only the corrected JSON object."
            let text: String
            switch runner.run(prompt: p) {
            case .success(let t): text = t
            case .failure(let e):
                if e.unavailable { return .unavailable(e.message) }
                errors = [e.message]
                continue
            }
            switch Annotator.parseJSON(text, as: Reply.self) {
            case .failure(let e): errors = [e.message]
            case .success(let reply):
                errors = validate(reply)
                if errors.isEmpty { return .accepted(Self.normalize(reply)) }
            }
        }
        return .rejected(errors)
    }

    func validate(_ reply: Reply) -> [String] {
        var errors: [String] = []
        if reply.findings.count > Self.maxFindings + 3 { errors.append("more than \(Self.maxFindings) findings") }
        let components = Set(model.components.map(\.id))
        let entities = Set(model.entities.map(\.id))
        let edges = Set(model.edges.map { "\($0.from)\u{1}\($0.to)" })
        for (i, f) in reply.findings.enumerated() {
            let at = "finding \(i + 1)"
            if !Self.kinds.contains(f.kind) { errors.append("kind of \(at) must be one of \(Self.kinds.joined(separator: ", "))") }
            if !["high", "medium", "low"].contains(f.severity) { errors.append("severity of \(at) must be high, medium, or low") }
            errors += Annotator.checkText(f.message, "message of \(at)", max: 300)
            if f.evidence.isEmpty { errors.append("\(at) cites no evidence") }
            for (j, ev) in f.evidence.prefix(8).enumerated() { errors += Annotator.checkText(ev, "evidence \(j + 1) of \(at)", max: 400) }
            if let s = f.suggestion, !s.trimmingCharacters(in: .whitespaces).isEmpty { errors += Annotator.checkText(s, "suggestion of \(at)", max: 400) }
            if f.anchors.isEmpty { errors.append("\(at) has no anchor") }
            for a in f.anchors {
                if let id = a.entity {
                    if !entities.contains(id) { errors.append("unknown entity \(id) in \(at)") }
                } else if let id = a.component {
                    if !components.contains(id) { errors.append("unknown component \(id) in \(at)") }
                } else if let from = a.from, let to = a.to {
                    if !edges.contains("\(from)\u{1}\(to)") { errors.append("no edge \(from) → \(to) in \(at)") }
                } else {
                    errors.append("an anchor of \(at) names no entity, component, or edge")
                }
            }
        }
        return errors
    }

    static func normalize(_ reply: Reply) -> Reply {
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return Reply(findings: reply.findings.prefix(maxFindings).map { f in
            let s = f.suggestion.map(trim)
            return Reply.Item(kind: f.kind, severity: f.severity, message: trim(f.message), evidence: f.evidence.prefix(8).map(trim),
                              suggestion: s?.isEmpty == true ? nil : s, anchors: Array(f.anchors.prefix(4)))
        })
    }

    static func findings(_ reply: Reply) -> [Finding] {
        var counts: [String: Int] = [:]
        return reply.findings.map { f in
            counts[f.kind, default: 0] += 1
            return Finding(id: "\(f.kind):\(counts[f.kind]!)", source: "llm", kind: f.kind, severity: f.severity, message: f.message,
                           evidence: f.evidence, suggestion: f.suggestion, anchors: f.anchors)
        }
    }
}
