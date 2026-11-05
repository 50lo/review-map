import Foundation

// The LLM annotator. It only annotates facts the analyzer produced: it re-ranks review and removed
// regions, prunes and ranks context regions, and writes one-line summaries for components and changed
// entities, in one batch or more per component. Then one structural review of the whole change looks
// at its shape (see StructuralReview.swift). It runs a coding-agent CLI (`claude -p` or `codex exec`),
// validates every reply strictly against the model, and caches accepted results. A batch that fails
// validation leaves the deterministic scores in place.

public struct AnnotateOptions {
    /// "claude" or "codex".
    public var tool: String
    /// Executable to run instead of the tool's own name (for example a fake for tests).
    public var command: String?
    /// Model passed to the CLI. Nil uses the CLI's default.
    public var model: String?
    /// Cache directory. Must be outside the target repo.
    public var cacheDir: String
    /// Batches run at the same time.
    public var jobs: Int
    /// Seconds before a CLI call is stopped.
    public var timeout: TimeInterval
    /// Prompt size per batch, in characters of entity material.
    public var maxBatchChars: Int
    /// A file with the change's description (a PR's title and body). Without one, the annotator asks
    /// `gh pr view` about the head branch, then falls back to the commit messages.
    public var descriptionFile: String?
    /// Skip the structural review of the whole change.
    public var noReview: Bool

    public init(tool: String = "claude", command: String? = nil, model: String? = nil,
                cacheDir: String = AnnotateOptions.defaultCacheDir, jobs: Int = 4, timeout: TimeInterval = 300,
                maxBatchChars: Int = 60_000, descriptionFile: String? = nil, noReview: Bool = false) {
        self.tool = tool
        self.command = command
        self.model = model
        self.cacheDir = cacheDir
        self.jobs = jobs
        self.timeout = timeout
        self.maxBatchChars = maxBatchChars
        self.descriptionFile = descriptionFile
        self.noReview = noReview
    }

    public static var defaultCacheDir: String {
        (AnnotateOptions.home as NSString).appendingPathComponent(".reviewmap/cache")
    }

    /// $HOME when set, so `~` means the same here as in the shell.
    public static var home: String {
        ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
    }
}

public enum Annotator {
    /// Bump when the prompt or the reply format changes, so cached results are not reused.
    public static let promptVersion = "2"

    public static func run(_ model: ChangeModel, options: AnnotateOptions, log: @escaping (String) -> Void = { _ in }) throws -> ChangeModel {
        guard ["claude", "codex"].contains(options.tool) else {
            throw AnnotatorError("Unknown LLM tool \(options.tool). Use claude or codex.")
        }
        let root = (model.repo.root as NSString).standardizingPath
        let cacheDir = (options.cacheDir as NSString).standardizingPath
        if cacheDir == root || cacheDir.hasPrefix(root + "/") {
            throw AnnotatorError("The cache directory \(cacheDir) is inside the target repo. Choose one outside it.")
        }
        try FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)

        let sources = SourceReader(git: GitRepo(root: model.repo.root), baseSha: model.repo.baseSha, headSha: model.repo.headSha)
        let reviewNotes = sources.text(.head, "REVIEW.md").map { String($0.prefix(20_000)) }
        let builder = PromptBuilder(model: model, sources: sources, reviewNotes: reviewNotes)
        let fingerprint = [promptVersion, options.tool, options.model ?? "", reviewNotes ?? ""].joined(separator: "\u{1}")
        let cache = AnnotationCache(dir: cacheDir)

        var batches: [Batch] = []
        var fromCache: [String: EntityReply] = [:]
        var componentFromCache: [String: String] = [:]
        var cachedBatches = 0
        for comp in model.components where comp.kind != .external && !comp.isTest {
            let entities = builder.entities(of: comp.id)
            if entities.isEmpty { continue }
            let blocks = entities.map { e in (e, builder.entityBlock(e)) }
            let keys = Dictionary(uniqueKeysWithValues: blocks.map { ($0.0.id, Hash.hex(fingerprint + "\u{2}" + $0.1)) })
            let compKey = Hash.hex(fingerprint + "\u{3}" + builder.componentHeader(comp) + blocks.map { keys[$0.0.id]! }.joined())
            var misses: [(Entity, String)] = []
            for (e, block) in blocks {
                if let hit = cache.entity(keys[e.id]!), validate(hit, against: e, builder: builder).isEmpty {
                    fromCache[e.id] = hit
                } else {
                    misses.append((e, block))
                }
            }
            let compSummary = cache.component(compKey)
            if let compSummary { componentFromCache[comp.id] = compSummary }
            if misses.isEmpty && compSummary != nil {
                cachedBatches += 1
                continue
            }
            // Split large components into batches of whole entities. The first batch also asks
            // for the component summary.
            var chunk: [(Entity, String)] = []
            var size = 0
            var chunks: [[(Entity, String)]] = []
            for m in misses {
                if !chunk.isEmpty && size + m.1.count > options.maxBatchChars {
                    chunks.append(chunk)
                    chunk = []
                    size = 0
                }
                chunk.append(m)
                size += m.1.count
            }
            if !chunk.isEmpty || chunks.isEmpty { chunks.append(chunk) }
            for (i, c) in chunks.enumerated() {
                batches.append(Batch(component: comp, entities: c.map(\.0), blocks: c.map(\.1),
                                     wantsSummary: i == 0 && compSummary == nil, part: i + 1, parts: chunks.count,
                                     entityKeys: keys, componentKey: compKey))
            }
        }

        // The structural review of the whole change, unless its reply for the same prompt is cached.
        let description = try ChangeDescription.load(model: model, file: options.descriptionFile)
        let review = options.noReview ? nil : StructuralReview(model: model, sources: sources, reviewNotes: reviewNotes, description: description)
        let reviewPrompt = review?.prompt()
        let reviewKey = reviewPrompt.map { Hash.hex(fingerprint + "\u{4}" + $0) }
        let cachedReview = reviewKey.flatMap { key in cache.review(key).flatMap { review!.validate($0).isEmpty ? $0 : nil } }

        log("LLM annotator: \(batches.count) batch\(batches.count == 1 ? "" : "es") to run with \(options.tool)\(options.model.map { " (\($0))" } ?? ""), \(cachedBatches) component\(cachedBatches == 1 ? "" : "s") from cache…")

        let runner = CLIRunner(options: options)
        let results = ResultBox(count: batches.count)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = max(1, options.jobs)
        for (i, batch) in batches.enumerated() {
            queue.addOperation {
                if results.unavailable { return }
                let prompt = builder.prompt(batch)
                let outcome = runBatch(batch, prompt: prompt, runner: runner, builder: builder)
                results.set(i, outcome)
                switch outcome {
                case .accepted(let reply):
                    for e in reply.entities { cache.store(entity: e, key: batch.entityKeys[e.id]!) }
                    if let s = reply.component?.summary { cache.store(component: s, key: batch.componentKey) }
                    log("  \(batch.label): ok")
                case .rejected(let errors):
                    log("  \(batch.label): rejected, deterministic scores kept (\(errors.prefix(3).joined(separator: "; ")))")
                case .unavailable:
                    break
                }
            }
        }
        final class ReviewBox: @unchecked Sendable { var outcome: StructuralReview.Outcome? }
        let reviewBox = ReviewBox()
        if let review, let reviewPrompt, let reviewKey, cachedReview == nil {
            log("LLM annotator: structural review of the whole change…")
            queue.addOperation {
                if results.unavailable { return }
                let outcome = review.run(prompt: reviewPrompt, runner: runner)
                reviewBox.outcome = outcome
                switch outcome {
                case .accepted(let reply):
                    cache.store(review: reply, key: reviewKey)
                    log("  structural review: \(reply.findings.count) finding\(reply.findings.count == 1 ? "" : "s")")
                case .rejected(let errors):
                    log("  structural review: rejected (\(errors.prefix(3).joined(separator: "; ")))")
                case .unavailable:
                    break
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()

        var out = model
        var entityReplies = fromCache
        var componentSummaries = componentFromCache
        var failed = 0
        var unavailable: String?
        for (i, outcome) in results.all.enumerated() {
            let batch = batches[i]
            switch outcome {
            case .accepted(let reply)?:
                for e in reply.entities { entityReplies[e.id] = e }
                if let s = reply.component?.summary { componentSummaries[batch.component.id] = s }
            case .rejected(let errors)?:
                failed += 1
                out.warnings.append(Warning(kind: "llm-rejected",
                                            message: "LLM reply for \(batch.label) failed validation, deterministic scores kept: \(errors.prefix(5).joined(separator: "; "))"))
            case .unavailable(let message)?:
                unavailable = message
            case nil:
                break
            }
        }
        var reviewStatus: String? = review == nil ? nil : "skipped"
        var reviewReply = cachedReview
        if cachedReview != nil { reviewStatus = "cached" }
        switch reviewBox.outcome {
        case .accepted(let reply)?:
            reviewReply = reply
            reviewStatus = "ok"
        case .rejected(let errors)?:
            reviewStatus = "rejected"
            out.warnings.append(Warning(kind: "llm-rejected",
                                        message: "LLM structural review failed validation: \(errors.prefix(5).joined(separator: "; "))"))
        case .unavailable(let message)?:
            unavailable = message
        case nil:
            break
        }
        if let unavailable {
            log(unavailable)
            out.warnings.append(Warning(kind: "llm-unavailable", message: unavailable))
            if entityReplies.isEmpty && reviewReply == nil { return out }
        }
        apply(&out, entities: entityReplies, components: componentSummaries)
        out.findings.removeAll { $0.source == "llm" }
        if let reviewReply { out.findings += StructuralReview.findings(reviewReply) }
        out.llm = LLMRun(tool: options.tool, model: options.model,
                         command: options.command.map { ($0 as NSString).lastPathComponent }, promptVersion: promptVersion,
                         batches: batches.count + cachedBatches, cached: cachedBatches, failed: failed,
                         reviewNotes: reviewNotes != nil, review: reviewStatus, description: description?.source)
        log("LLM annotator: \(entityReplies.count) entities annotated, \(failed) batch\(failed == 1 ? "" : "es") rejected.")
        return out
    }

    // MARK: - One batch

    enum Outcome {
        case accepted(BatchReply)
        case rejected([String])
        case unavailable(String)
    }

    static func runBatch(_ batch: Batch, prompt: String, runner: CLIRunner, builder: PromptBuilder) -> Outcome {
        var errors: [String] = []
        // One retry with the errors, because a CLI agent sometimes wraps or truncates its reply.
        for attempt in 0..<2 {
            let p = attempt == 0 ? prompt : prompt + "\n\nYour previous reply was rejected: " + errors.prefix(10).joined(separator: "; ")
                + ".\nReply again with only the completed JSON object."
            let text: String
            switch runner.run(prompt: p) {
            case .success(let t): text = t
            case .failure(let e):
                if e.unavailable { return .unavailable(e.message) }
                errors = [e.message]
                continue
            }
            switch parseReply(text) {
            case .failure(let e): errors = [e.message]
            case .success(let reply):
                errors = validate(reply, batch: batch, builder: builder)
                if errors.isEmpty { return .accepted(normalize(reply)) }
            }
        }
        return .rejected(errors)
    }

    static func parseReply(_ text: String) -> Result<BatchReply, AnnotatorError> {
        parseJSON(text, as: BatchReply.self)
    }

    static func parseJSON<T: Decodable>(_ text: String, as: T.Type) -> Result<T, AnnotatorError> {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return .failure(AnnotatorError("reply has no JSON object"))
        }
        let json = String(text[start...end])
        do {
            return .success(try JSONDecoder().decode(T.self, from: Data(json.utf8)))
        } catch let DecodingError.keyNotFound(key, ctx) {
            return .failure(AnnotatorError("missing \(key.stringValue) at \(path(ctx))"))
        } catch let DecodingError.typeMismatch(_, ctx), let DecodingError.valueNotFound(_, ctx) {
            return .failure(AnnotatorError("wrong or null value at \(path(ctx))"))
        } catch {
            return .failure(AnnotatorError("reply is not valid JSON"))
        }
    }

    private static func path(_ ctx: DecodingError.Context) -> String {
        ctx.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
    }

    // MARK: - Validation

    /// Checks the reply against the batch: the same entities and regions, values in range, one-line text.
    static func validate(_ reply: BatchReply, batch: Batch, builder: PromptBuilder) -> [String] {
        var errors: [String] = []
        if batch.wantsSummary {
            if let s = reply.component?.summary { errors += checkText(s, "component summary", max: 200) }
            else { errors.append("component summary missing") }
        }
        let expected = Set(batch.entities.map(\.id))
        let got = reply.entities.map(\.id)
        if Set(got).count != got.count { errors.append("an entity appears twice") }
        for id in Set(got).subtracting(expected) { errors.append("unknown entity \(id)") }
        for id in expected.subtracting(got) { errors.append("entity \(id) missing") }
        let byId = Dictionary(reply.entities.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for e in batch.entities {
            if let r = byId[e.id] { errors += validate(r, against: e, builder: builder) }
        }
        return errors
    }

    static func validate(_ r: EntityReply, against e: Entity, builder: PromptBuilder) -> [String] {
        var errors = checkText(r.summary, "summary of \(e.id)", max: 200)
        let own = Set(builder.reviewRegions(e.id).map(\.id))
        let ctx = Set(builder.contextRegions(e.id).map(\.id))
        let regionIds = r.regions.map(\.id)
        if Set(regionIds).count != regionIds.count { errors.append("a region of \(e.id) appears twice") }
        for id in Set(regionIds).subtracting(own) { errors.append("unknown region \(id)") }
        for id in own.subtracting(regionIds) { errors.append("region \(id) missing") }
        for g in r.regions where own.contains(g.id) {
            if !(0...1).contains(g.risk) || g.risk.isNaN { errors.append("risk of \(g.id) is outside 0...1") }
        }
        let contextIds = (r.context ?? []).map(\.id)
        if Set(contextIds).count != contextIds.count { errors.append("a context region of \(e.id) appears twice") }
        for id in Set(contextIds).subtracting(ctx) { errors.append("unknown context region \(id)") }
        for id in ctx.subtracting(contextIds) { errors.append("context region \(id) missing") }
        for c in r.context ?? [] where c.keep {
            if (c.rank ?? 0) < 1 { errors.append("kept context region \(c.id) needs a rank from 1") }
        }
        return errors
    }

    static func checkText(_ s: String, _ what: String, max: Int) -> [String] {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return ["\(what) is empty"] }
        if t.contains("\n") { return ["\(what) is more than one line"] }
        if t.count > max { return ["\(what) is longer than \(max) characters"] }
        return []
    }

    /// Trims text and numbers kept context regions 1, 2, 3… in the order the LLM ranked them.
    static func normalize(_ reply: BatchReply) -> BatchReply {
        var r = reply
        r.component = r.component.map { BatchReply.ComponentReply(summary: $0.summary.trimmingCharacters(in: .whitespacesAndNewlines)) }
        r.entities = r.entities.map { e in
            var e = e
            e.summary = e.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if var ctx = e.context {
                let kept = ctx.enumerated().filter { $0.element.keep }.sorted { ($0.element.rank ?? 0, $0.offset) < ($1.element.rank ?? 0, $1.offset) }
                for (n, k) in kept.enumerated() { ctx[k.offset].rank = n + 1 }
                for i in ctx.indices where !ctx[i].keep { ctx[i].rank = nil }
                e.context = ctx
            }
            return e
        }
        return r
    }

    // MARK: - Applying

    static func apply(_ m: inout ChangeModel, entities: [String: EntityReply], components: [String: String]) {
        var regionReply: [String: EntityReply.RegionReply] = [:]
        var contextReply: [String: EntityReply.ContextReply] = [:]
        for e in entities.values {
            for g in e.regions { regionReply[g.id] = g }
            for c in e.context ?? [] { contextReply[c.id] = c }
        }
        for i in m.components.indices {
            m.components[i].llm = components[m.components[i].id].map(LLMSummary.init(summary:))
        }
        for i in m.entities.indices {
            m.entities[i].llm = entities[m.entities[i].id].map { LLMSummary(summary: $0.summary) }
        }
        for i in m.regions.indices {
            let id = m.regions[i].id
            if let g = regionReply[id] {
                m.regions[i].llm = RegionLLM(risk: (g.risk * 100).rounded() / 100)
            } else if let c = contextReply[id] {
                m.regions[i].llm = RegionLLM(keep: c.keep, rank: c.rank)
            } else {
                m.regions[i].llm = nil
            }
        }
    }
}

public struct AnnotatorError: Error, CustomStringConvertible {
    public var message: String
    var unavailable = false
    init(_ message: String, unavailable: Bool = false) {
        self.message = message
        self.unavailable = unavailable
    }
    public var description: String { message }
}

// MARK: - Reply format

struct BatchReply: Codable {
    struct ComponentReply: Codable {
        var summary: String
    }
    var component: ComponentReply?
    var entities: [EntityReply]
}

struct EntityReply: Codable, Equatable {
    struct RegionReply: Codable, Equatable {
        var id: String
        var risk: Double
    }
    struct ContextReply: Codable, Equatable {
        var id: String
        var keep: Bool
        var rank: Int?
    }
    var id: String
    var summary: String
    var regions: [EntityReply.RegionReply]
    var context: [EntityReply.ContextReply]?
}

struct Batch {
    var component: Component
    var entities: [Entity]
    var blocks: [String]
    var wantsSummary: Bool
    var part: Int
    var parts: Int
    var entityKeys: [String: String]
    var componentKey: String

    var label: String { parts > 1 ? "\(component.name) (part \(part) of \(parts))" : component.name }
}

private final class ResultBox: @unchecked Sendable {
    private var items: [Annotator.Outcome?]
    private let lock = NSLock()
    private(set) var unavailable = false
    init(count: Int) { items = Array(repeating: nil, count: count) }
    func set(_ i: Int, _ o: Annotator.Outcome) {
        lock.lock()
        items[i] = o
        if case .unavailable = o { unavailable = true }
        lock.unlock()
    }
    var all: [Annotator.Outcome?] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

// MARK: - Prompt

/// Builds the prompt for a batch. Each entity's block is also what its cache key hashes, so a
/// result is reused only when everything the LLM saw about the entity is the same.
struct PromptBuilder: @unchecked Sendable {
    let model: ChangeModel
    let sources: SourceReader
    let reviewNotes: String?
    private let regionsByEntity: [String: [Region]]
    private let contextByEntity: [String: [Region]]
    private let componentById: [String: Component]
    private let entitiesByComponent: [String: [Entity]]

    /// Whole entity code is included up to this many lines; longer entities show their regions with a margin.
    static let maxWholeLines = 150
    static let margin = 3

    init(model: ChangeModel, sources: SourceReader, reviewNotes: String?) {
        self.model = model
        self.sources = sources
        self.reviewNotes = reviewNotes
        var own: [String: [Region]] = [:]
        var ctx: [String: [Region]] = [:]
        for r in model.regions {
            if r.kind == "context" { ctx[r.entity, default: []].append(r) } else { own[r.entity, default: []].append(r) }
        }
        regionsByEntity = own
        contextByEntity = ctx
        componentById = Dictionary(model.components.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let low = Set(model.components.filter(\.isTest).map(\.id))
        entitiesByComponent = Dictionary(grouping: model.entities.filter { e in
            e.change != .cosmetic && !low.contains(e.component) && !e.tags.contains("test") && !e.tags.contains("generated")
        }, by: \.component)
    }

    func entities(of component: String) -> [Entity] { entitiesByComponent[component] ?? [] }
    func reviewRegions(_ entity: String) -> [Region] { regionsByEntity[entity] ?? [] }
    func contextRegions(_ entity: String) -> [Region] { contextByEntity[entity] ?? [] }

    func componentHeader(_ c: Component) -> String {
        var parts = [kindName(c.kind)]
        if let l = c.layer { parts.append("layer \(l)") }
        if let m = c.module, m != c.name { parts.append("module \(m)") }
        if let s = c.status { parts.append(s) }
        var out = "Component \(c.name) (\(parts.joined(separator: ", ")))"
        if !c.paths.isEmpty { out += "\nPaths: " + c.paths.joined(separator: ", ") }
        return out
    }

    private func kindName(_ k: ComponentKind) -> String {
        switch k {
        case .spmTarget: return "SPM target"
        case .xcodeTarget: return "Xcode target"
        case .npmPackage: return "npm package"
        case .tsconfig: return "tsconfig project"
        case .folder: return "folder"
        case .external: return "external package"
        }
    }

    func entityBlock(_ e: Entity) -> String {
        var out = "### Entity \(e.id)\n"
        out += "\(e.kind.rawValue) \(e.qualifiedName), change: \(e.changes.map(\.rawValue).joined(separator: ", "))"
        out += e.isInterface ? ", interface\n" : ", internal\n"
        if !e.contractFlags.isEmpty { out += "Contract flags: \(e.contractFlags.joined(separator: ", "))\n" }
        if let b = e.signature.base, b != e.signature.head { out += "Base signature: \(b)\n" }
        if let h = e.signature.head { out += "Head signature: \(h)\n" }
        if !e.usedBy.isEmpty {
            let comps = Set(e.usedBy.map(\.component)).sorted().map { componentById[$0]?.name ?? $0 }
            out += "Used by \(e.usedBy.count) declaration\(e.usedBy.count == 1 ? "" : "s") in \(comps.joined(separator: ", "))\n"
        }
        if !e.dependsOn.isEmpty {
            out += "Depends on: " + Array(Set(e.dependsOn.map(\.symbol))).sorted().prefix(12).joined(separator: ", ") + "\n"
        }
        let own = reviewRegions(e.id)
        if e.change != .removed {
            out += code(side: e.location.side, loc: e.location, title: "Head code", regions: own.filter { $0.side == e.location.side })
        }
        if let b = e.change == .removed ? e.location : e.baseLocation, e.change != .added {
            out += code(side: .base, loc: b, title: "Base code", regions: own.filter { $0.side == .base })
        }
        out += "Regions:\n"
        for r in own {
            out += "- \(r.id) \(r.kind), \(r.side.rawValue) lines \(r.startLine)-\(r.endLine)"
            if let a = r.anchor { out += " (after head line \(a))" }
            out += ", deterministic risk \(String(format: "%.2f", r.risk)): \(r.reasons.joined(separator: "; "))\n"
        }
        let ctx = contextRegions(e.id)
        if !ctx.isEmpty {
            out += "Context regions (unchanged code):\n"
            for c in ctx {
                let comp = c.component.flatMap { componentById[$0]?.name } ?? ""
                out += "- \(c.id) \(c.relation ?? "context")\(comp.isEmpty || c.component == e.component ? "" : " in \(comp)"): "
                out += "\(c.reasons.first ?? "") at \(c.file):\(c.startLine)-\(c.endLine), supports \((c.supports ?? []).joined(separator: ", "))\n"
                let lines = sources.lines(c.side, c.file)
                let wanted = (c.lines ?? Array(c.startLine...min(c.endLine, c.startLine + 11))).prefix(12)
                for n in wanted where n >= 1 && n <= lines.count {
                    out += "    \(n)| \(lines[n - 1])\n"
                }
            }
        }
        return out
    }

    private func code(side: Side, loc: Location, title: String, regions: [Region]) -> String {
        let lines = sources.lines(side, loc.file)
        guard !lines.isEmpty, loc.startLine >= 1 else { return "\(title): not available\n" }
        let end = min(loc.endLine, lines.count)
        guard loc.startLine <= end else { return "\(title): not available\n" }
        var shown: [ClosedRange<Int>]
        if end - loc.startLine + 1 <= Self.maxWholeLines {
            shown = [loc.startLine...end]
        } else {
            // A long declaration shows its first lines and its regions; a type's members are entities of their own.
            shown = [loc.startLine...min(end, loc.startLine + 2)]
            for r in regions {
                let last = min(r.endLine, r.startLine + Self.maxWholeLines - 1)
                shown.append(max(loc.startLine, r.startLine - Self.margin)...min(end, last + Self.margin))
            }
        }
        shown.sort { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Int>] = []
        for r in shown {
            if let last = merged.last, r.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        var out = "\(title) (\(loc.file), lines \(loc.startLine)-\(end)):\n"
        var prev: Int?
        for r in merged {
            if let p = prev, r.lowerBound > p + 1 { out += "    …\n" }
            for n in r { out += "    \(n)| \(lines[n - 1])\n" }
            prev = r.upperBound
        }
        if let p = prev, p < end { out += "    …\n" }
        return out
    }

    func prompt(_ b: Batch) -> String {
        let languages = (model.analyzer.languages ?? ["swift"]).map(Languages.displayName).joined(separator: " and ")
        var out = """
        You are helping a reviewer read a \(languages.isEmpty ? "code" : languages) change. A deterministic analyzer already found the changed \
        declarations (entities) of one component, cut them into review regions with a risk score, and collected \
        unchanged context regions that may explain them. You only annotate these facts: never add entities, \
        regions, or ids, and never drop any.

        Tasks:
        1. Every review and removed region: a risk from 0 to 1 for how closely a reviewer must read it to catch \
        a real problem (callers that break, persisted or network data that no longer decodes, isolation or \
        concurrency mistakes, removed checks, changed behavior). The deterministic risk is a hint, not an anchor.
        2. Every context region: keep true only when the reviewer needs it to understand the region it supports, \
        and rank the kept ones of each entity from 1 (most needed). Use rank null when keep is false.
        3. A one-line behavior summary, at most 20 words, for each entity\(b.wantsSummary ? " and for the component" : ""): \
        what the code does now that it didn't before, not which lines changed.

        Reply with only the JSON object in <reply-template>, filled in: replace every null risk and keep and \
        every empty summary, and set rank where it applies. Keep every id and the structure exactly. No prose \
        and no code fences.

        """
        if let notes = reviewNotes {
            out += "\n<review-notes>\nThe repository's REVIEW.md, its own notes on what matters:\n\(notes)\n</review-notes>\n"
        }
        out += "\n## " + componentHeader(b.component) + "\n"
        if b.parts > 1 {
            out += "This is part \(b.part) of \(b.parts) of the component's changed entities.\n"
        }
        let others = entities(of: b.component.id).filter { e in !b.entities.contains { $0.id == e.id } }
        if b.wantsSummary && !others.isEmpty {
            out += "Other changed entities in this component, not part of this batch:\n"
            for e in others.prefix(60) { out += "- \(e.kind.rawValue) \(e.qualifiedName) (\(e.change.rawValue))\n" }
        }
        out += "\n" + b.blocks.joined(separator: "\n")
        out += "\n<reply-template>\n" + template(b) + "\n</reply-template>\n"
        return out
    }

    /// The reply skeleton with every id filled in, one value line per region, so the reply only has to fill values.
    func template(_ b: Batch) -> String {
        func q(_ s: String) -> String {
            let data = try! JSONEncoder().encode(s)
            return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
        }
        var lines = ["{"]
        if b.wantsSummary { lines.append("  \"component\": {\"id\": \(q(b.component.id)), \"summary\": \"\"},") }
        lines.append("  \"entities\": [")
        for (i, e) in b.entities.enumerated() {
            lines.append("    {")
            lines.append("      \"id\": \(q(e.id)),")
            lines.append("      \"summary\": \"\",")
            lines.append("      \"regions\": [")
            let own = reviewRegions(e.id)
            for (j, r) in own.enumerated() {
                lines.append("        {\"id\": \(q(r.id)), \"risk\": null}" + (j < own.count - 1 ? "," : ""))
            }
            lines.append("      ],")
            lines.append("      \"context\": [")
            let ctx = contextRegions(e.id)
            for (j, c) in ctx.enumerated() {
                lines.append("        {\"id\": \(q(c.id)), \"keep\": null, \"rank\": null}" + (j < ctx.count - 1 ? "," : ""))
            }
            lines.append("      ]")
            lines.append("    }" + (i < b.entities.count - 1 ? "," : ""))
        }
        lines.append("  ]")
        lines.append("}")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Sources

/// File contents at base and head, read with `git show` so the working copy is never touched.
final class SourceReader: @unchecked Sendable {
    let git: GitRepo
    let baseSha: String
    let headSha: String
    private var cache: [String: [String]] = [:]
    private let lock = NSLock()

    init(git: GitRepo, baseSha: String, headSha: String) {
        self.git = git
        self.baseSha = baseSha
        self.headSha = headSha
    }

    func text(_ side: Side, _ file: String) -> String? {
        let sha = side == .base ? baseSha : headSha
        guard let data = try? Shell.run(["git", "-C", git.root, "show", "\(sha):\(file)"]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func lines(_ side: Side, _ file: String) -> [String] {
        let key = "\(side.rawValue):\(file)"
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let lines = text(side, file).map { $0.components(separatedBy: "\n") } ?? []
        lock.lock()
        cache[key] = lines
        lock.unlock()
        return lines
    }
}

// MARK: - Cache

/// Accepted results under <cache>/<key>.json, one file per entity and one per component summary.
struct AnnotationCache: @unchecked Sendable {
    let dir: String

    func entity(_ key: String) -> EntityReply? {
        guard let data = FileManager.default.contents(atPath: path(key)) else { return nil }
        return try? JSONDecoder().decode(EntityReply.self, from: data)
    }

    func component(_ key: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path(key)) else { return nil }
        return (try? JSONDecoder().decode(BatchReply.ComponentReply.self, from: data))?.summary
    }

    func review(_ key: String) -> StructuralReview.Reply? {
        guard let data = FileManager.default.contents(atPath: path("review-" + key)) else { return nil }
        return try? JSONDecoder().decode(StructuralReview.Reply.self, from: data)
    }

    func store(review: StructuralReview.Reply, key: String) {
        write(try? JSONEncoder().encode(review), "review-" + key)
    }

    func store(entity: EntityReply, key: String) {
        write(try? JSONEncoder().encode(entity), key)
    }

    func store(component summary: String, key: String) {
        write(try? JSONEncoder().encode(BatchReply.ComponentReply(summary: summary)), key)
    }

    private func write(_ data: Data?, _ key: String) {
        guard let data else { return }
        let tmp = path(key) + ".\(UUID().uuidString).tmp"
        // Write and rename, so a concurrent run never reads half a file.
        if FileManager.default.createFile(atPath: tmp, contents: data), rename(tmp, path(key)) != 0 {
            try? FileManager.default.removeItem(atPath: tmp)
        }
    }

    private func path(_ key: String) -> String { dir + "/" + key + ".json" }
}

/// A 128-bit FNV-1a hash in hex, enough to key a local cache without a crypto dependency.
enum Hash {
    static func hex(_ s: String) -> String {
        var a: UInt64 = 0xcbf2_9ce4_8422_2325
        var b: UInt64 = 0x6c62_272e_07bb_0142
        for byte in s.utf8 {
            a = (a ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            b = (b ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            b = b ^ (b >> 29)
        }
        return String(format: "%016llx%016llx", a, b)
    }
}

// MARK: - CLI

/// Runs `claude -p --output-format json` or `codex exec` with the prompt on stdin, in an empty
/// temporary directory so the agent never sees or touches the target repo.
struct CLIRunner: @unchecked Sendable {
    let options: AnnotateOptions

    func run(prompt: String) -> Result<String, AnnotatorError> {
        let fm = FileManager.default
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("reviewmap-llm-\(UUID().uuidString)")
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }
        let exe = options.command ?? options.tool
        var args: [String]
        let lastMessage = dir + "/last-message.txt"
        if options.tool == "codex" {
            args = [exe, "exec", "--skip-git-repo-check", "--sandbox", "read-only", "--color", "never",
                    "--output-last-message", lastMessage]
            if let m = options.model { args += ["--model", m] }
            args.append("-")
        } else {
            args = [exe, "-p", "--output-format", "json", "--tools", "", "--no-session-persistence"]
            if let m = options.model { args += ["--model", m] }
        }
        let result: (status: Int32, out: Data, err: Data, timedOut: Bool)
        do {
            result = try Self.exec(args, stdin: Data(prompt.utf8), cwd: dir, timeout: options.timeout)
        } catch {
            return .failure(AnnotatorError("Could not run \(exe): \(error). The LLM annotator was skipped.", unavailable: true))
        }
        if result.timedOut { return .failure(AnnotatorError("\(exe) did not answer within \(Int(options.timeout)) seconds")) }
        if result.status == 127 {
            return .failure(AnnotatorError("\(exe) was not found. Install it, pass --llm-command, or use --no-llm. The LLM annotator was skipped.", unavailable: true))
        }
        let stderr = String(decoding: result.err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status != 0 {
            return .failure(AnnotatorError("\(exe) exited with \(result.status): \(String(stderr.suffix(300)))"))
        }
        if options.tool == "codex" {
            guard let text = try? String(contentsOfFile: lastMessage, encoding: .utf8) else {
                return .failure(AnnotatorError("codex wrote no last message"))
            }
            return .success(text)
        }
        // claude -p --output-format json prints one result object; its `result` holds the reply text.
        let out = result.out
        if let obj = try? JSONSerialization.jsonObject(with: out) as? [String: Any], let text = obj["result"] as? String {
            if (obj["is_error"] as? Bool) == true { return .failure(AnnotatorError("claude reported an error: \(String(text.prefix(300)))")) }
            return .success(text)
        }
        return .success(String(decoding: out, as: UTF8.self))
    }

    static func exec(_ args: [String], stdin: Data, cwd: String, timeout: TimeInterval) throws -> (status: Int32, out: Data, err: Data, timedOut: Bool) {
        signal(SIGPIPE, SIG_IGN)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        final class Box: @unchecked Sendable { var data = Data() }
        let outBox = Box(), errBox = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        DispatchQueue.global().async {
            // A CLI that exits without reading its input must not take the analyzer down with SIGPIPE.
            try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
            try? inPipe.fileHandleForWriting.close()
        }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            p.waitUntilExit()
            done.signal()
        }
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            done.wait()
        }
        group.wait()
        return (p.terminationStatus, outBox.data, errBox.data, timedOut)
    }
}
