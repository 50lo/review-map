import Foundation

public struct AnalyzeOptions {
    public var repo: String
    public var base: String
    public var head: String
    public var useMergeBase: Bool
    public var configPath: String?
    /// Max references kept per edge in the output.
    public var maxRefsPerEdge: Int
    /// Evaluate Package.swift with `swift package dump-package` (runs repository code) instead of parsing its syntax.
    public var dumpPackage: Bool
    /// Exact references from a build's index store instead of name matching.
    public var index: IndexOptions

    public init(repo: String, base: String, head: String, useMergeBase: Bool = true,
                configPath: String? = nil, maxRefsPerEdge: Int = 50, dumpPackage: Bool = false, index: IndexOptions = IndexOptions()) {
        self.repo = repo
        self.base = base
        self.head = head
        self.useMergeBase = useMergeBase
        self.configPath = configPath
        self.maxRefsPerEdge = maxRefsPerEdge
        self.dumpPackage = dumpPackage
        self.index = index
    }
}

public enum Analyzer {
    public static let version = "0.1.0"

    /// The top-level directory of the git repo that contains `repo`.
    public static func repoRoot(repo: String) throws -> String {
        try Shell.string(["git", "-C", repo, "rev-parse", "--show-toplevel"])
    }

    /// The branch checked out in the repo, or "HEAD" when it is detached or can't be read.
    public static func currentBranch(repo: String) -> String {
        (try? Shell.string(["git", "-C", repo, "rev-parse", "--abbrev-ref", "HEAD"])).flatMap { $0.isEmpty ? nil : $0 } ?? "HEAD"
    }

    public static func run(_ options: AnalyzeOptions, log: (String) -> Void = { _ in }) throws -> ChangeModel {
        let root = try Shell.string(["git", "-C", options.repo, "rev-parse", "--show-toplevel"])
        let git = GitRepo(root: root)
        let headSha = try git.revParse(options.head)
        let baseRef = try git.revParse(options.base)
        let baseSha = options.useMergeBase ? try git.mergeBase(baseRef, headSha) : baseRef

        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("reviewmap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let baseDir = tmp + "/base"
        let headDir = tmp + "/head"
        log("Exporting \(String(baseSha.prefix(8))) and \(String(headSha.prefix(8)))…")
        try git.export(baseSha, to: baseDir)
        try git.export(headSha, to: headDir)

        var config = Config()
        if let p = options.configPath {
            config = try Config.load(path: p)
        } else if FileManager.default.fileExists(atPath: headDir + "/reviewmap.yml") {
            config = try Config.load(path: headDir + "/reviewmap.yml")
        }

        let baseBlobs = try git.blobs(at: baseSha)
        let headBlobs = try git.blobs(at: headSha)

        // The languages with source files at either side.
        let languages = Languages.all.filter { lang in baseBlobs.keys.contains(where: lang.isSource) || headBlobs.keys.contains(where: lang.isSource) }
        log("Parsing \(languages.isEmpty ? "source" : languages.map(\.displayName).joined(separator: " and ")) files…")
        let parser = ParseCache()
        let baseSide = try SideData.load(side: .base, dir: baseDir, blobs: baseBlobs, languages: languages, config: &config, parser: parser, options: options)
        let headSide = try SideData.load(side: .head, dir: headDir, blobs: headBlobs, languages: languages, config: &config, parser: parser, options: options)

        var builder = ModelBuilder(base: baseSide, head: headSide, languages: languages, options: options)
        let indexOptions = options.index.merged(with: config.index)
        if indexOptions.enabled == true {
            for lang in languages {
                let files = { (s: SideData) in s.files.filter { $0.value.language == lang.id }.keys.sorted() }
                do {
                    guard let index = try lang.index(
                        options: indexOptions, repoRoot: root,
                        sides: [IndexSide(side: .head, sha: headSha, dir: headDir, files: files(headSide)),
                                IndexSide(side: .base, sha: baseSha, dir: baseDir, files: files(baseSide))],
                        log: log) else { continue }
                    builder.addIndex(index, language: lang)
                } catch {
                    log("Index mode is off for \(lang.displayName) in this run: \(error)")
                    builder.warnings.insert(Warning(kind: "index-unavailable",
                        message: "\(lang.displayName) references were matched by name because the index could not be built: \(error)"))
                }
            }
        }

        log("Comparing…")
        builder.diffExternalDeps(baseBlobs: baseBlobs, headBlobs: headBlobs, baseDir: baseDir, headDir: headDir)
        builder.matchEntities()
        builder.resolveReferences()
        builder.addContractFiles(baseBlobs: baseBlobs, headBlobs: headBlobs, baseDir: baseDir, headDir: headDir)
        builder.addTargetSettings()

        let repo = RepoInfo(root: root, base: options.base, head: options.head, baseSha: baseSha, headSha: headSha,
                            usesMergeBase: options.useMergeBase)
        return builder.finish(repo: repo)
    }
}

// MARK: - Parsing

final class ParseCache: @unchecked Sendable {
    private var cache: [String: ParsedFile] = [:]
    private let lock = NSLock()

    /// Parses every (path, blob) concurrently; identical blobs are parsed once across both sides.
    func parseAll(_ items: [(path: String, blob: String, abs: String)]) -> [String: ParsedFile] {
        var todo: [(path: String, blob: String, abs: String)] = []
        lock.lock()
        var seen = Set<String>()
        for i in items where cache[i.blob] == nil && !seen.contains(i.blob) {
            todo.append(i)
            seen.insert(i.blob)
        }
        lock.unlock()
        DispatchQueue.concurrentPerform(iterations: todo.count) { idx in
            let item = todo[idx]
            let source = (try? String(contentsOfFile: item.abs, encoding: .utf8)) ?? ""
            let parsed = Languages.of(item.path)!.parse(path: item.path, source: source)
            lock.lock()
            cache[item.blob] = parsed
            lock.unlock()
        }
        var result: [String: ParsedFile] = [:]
        lock.lock()
        for i in items {
            var p = cache[i.blob]!
            p.path = i.path
            result[i.path] = p
        }
        lock.unlock()
        return result
    }
}

struct SideData {
    let side: Side
    let dir: String
    let files: [String: ParsedFile]
    let layout: ComponentLayout
    /// Top-level declared name -> components that declare it.
    let declTable: [String: Set<String>]
    let generated: Set<String>

    static func load(side: Side, dir: String, blobs: [String: String], languages: [Language], config: inout Config,
                     parser: ParseCache, options: AnalyzeOptions) throws -> SideData {
        let excludes = config.excludeMatchers
        let paths = blobs.keys.filter { path in
            languages.contains { $0.isSource(path) } && !excludes.contains(where: { $0.matches(path) })
        }.sorted()
        let files = parser.parseAll(paths.map { ($0, blobs[$0]!, dir + "/" + $0) })
        let layout = ComponentBuilder.build(root: dir, files: paths, languages: languages, config: &config, options: options)
        var table: [String: Set<String>] = [:]
        for (path, file) in files {
            guard let comp = layout.fileComponent[path] else { continue }
            for d in file.decls where d.isTopLevel && d.kind != .extension {
                table[d.name, default: []].insert(comp)
            }
        }
        let gen = config.generatedMatchers + languages.flatMap(\.generatedPatterns).map(Glob.init)
        let generated = Set(paths.filter { p in gen.contains { $0.matches(p) } })
        return SideData(side: side, dir: dir, files: files, layout: layout, declTable: table, generated: generated)
    }
}

// MARK: - Model building

/// A declaration located at one side.
struct Located {
    var decl: Decl
    var file: String
    var index: Int
    var component: String
}

struct DeclKey: Hashable {
    var side: Side
    var file: String
    var index: Int
}

struct Pair {
    var base: Located?
    var head: Located?
    var id: String = ""
    var changes: [ChangeKind] = []
    var flags: [String] = []
    var any: Located { head ?? base! }
}

struct ModelBuilder {
    let base: SideData
    let head: SideData
    let languages: [Language]
    let options: AnalyzeOptions

    var pairs: [Pair] = []
    var pairOf: [DeclKey: Int] = [:]
    var fileEntities: [Entity] = []
    var warnings = Set<Warning>()
    /// (side, from, to) -> refs
    var edgeRefs: [Side: [String: [String: [Ref]]]] = [.base: [:], .head: [:]]
    /// pair index -> usages
    var usedBy: [Int: Set<Usage>] = [:]
    var dependsOn: [Int: Set<Usage>] = [:]
    var externalComponents: [String: String] = [:] // id -> name
    var externalDeps: [ExternalDepChange] = []
    /// Package identities pinned on either side (Package.resolved).
    var pinnedPackages = Set<String>()
    /// Exact references per side, for the files of the languages that index mode built at both sides.
    var index: [Side: SideIndex] = [:]
    /// Index mode: every head reference to a changed declaration, same component included (for caller context).
    var indexCallers: [Int: [Usage]] = [:]

    init(base: SideData, head: SideData, languages: [Language], options: AnalyzeOptions) {
        self.base = base
        self.head = head
        self.languages = languages
        self.options = options
        for w in base.layout.warnings + head.layout.warnings { warnings.insert(w) }
    }

    func side(_ s: Side) -> SideData { s == .base ? base : head }

    /// The language of a parsed source file.
    func language(of file: String) -> Language {
        Languages.of(file)!
    }

    // MARK: Matching

    static func kindGroup(_ k: EntityKind) -> String {
        switch k {
        case .struct, .class, .enum, .actor: return "type"
        case .func, .`init`: return "callable"
        default: return k.rawValue
        }
    }

    private func locatedDecls(_ s: SideData) -> [String: [Located]] {
        var groups: [String: [Located]] = [:]
        for path in s.files.keys.sorted() {
            guard let comp = s.layout.fileComponent[path], let file = s.files[path] else { continue }
            for (i, d) in file.decls.enumerated() {
                let name = d.kind == .extension ? d.qualifiedName : d.name
                let key = "\(comp)|\(Self.kindGroup(d.kind))|\(d.scope ?? "")|\(name)"
                groups[key, default: []].append(Located(decl: d, file: path, index: i, component: comp))
            }
        }
        return groups
    }

    mutating func matchEntities() {
        let bg = locatedDecls(base)
        let hg = locatedDecls(head)
        let keys = Set(bg.keys).union(hg.keys).sorted()
        for key in keys {
            var bs = bg[key] ?? []
            var hs = hg[key] ?? []
            var matched: [(Located?, Located?)] = []
            let passes: [(Decl, Decl) -> Bool] = [
                { $0.signatureCanon == $1.signatureCanon && $0.modifiersCanon == $1.modifiersCanon && $0.bodyCanon == $1.bodyCanon },
                { $0.signatureCanon == $1.signatureCanon && $0.modifiersCanon == $1.modifiersCanon },
                { $0.signatureCanon == $1.signatureCanon },
                { $0.labelsKey == $1.labelsKey },
            ]
            for pass in passes {
                var i = 0
                while i < bs.count {
                    if let j = hs.firstIndex(where: { pass(bs[i].decl, $0.decl) }) {
                        matched.append((bs[i], hs[j]))
                        bs.remove(at: i)
                        hs.remove(at: j)
                    } else {
                        i += 1
                    }
                }
            }
            if bs.count == hs.count {
                for (b, h) in zip(bs, hs) { matched.append((b, h)) }
            } else {
                if !bs.isEmpty && !hs.isEmpty {
                    warnings.insert(Warning(kind: "ambiguous-overloads",
                        message: "Could not pair \(bs.count) base and \(hs.count) head declarations of \(bs[0].decl.qualifiedName); reported as removed and added.",
                        file: hs[0].file, line: hs[0].decl.startLine))
                }
                for b in bs { matched.append((b, nil)) }
                for h in hs { matched.append((nil, h)) }
            }
            for (b, h) in matched {
                var p = Pair(base: b, head: h)
                if let b { pairOf[DeclKey(side: .base, file: b.file, index: b.index)] = pairs.count }
                if let h { pairOf[DeclKey(side: .head, file: h.file, index: h.index)] = pairs.count }
                p.changes = Self.changes(b?.decl, h?.decl)
                pairs.append(p)
            }
        }
        assignIds()
        computeFlags()
    }

    private static func changes(_ b: Decl?, _ h: Decl?) -> [ChangeKind] {
        guard let b else { return [.added] }
        guard let h else { return [.removed] }
        var c: [ChangeKind] = []
        if b.signatureCanon != h.signatureCanon || kindGroup(b.kind) == "type" && b.kind != h.kind { c.append(.signature) }
        if b.modifiersCanon != h.modifiersCanon { c.append(.modifiers) }
        if b.bodyCanon != h.bodyCanon { c.append(.body) }
        if c.isEmpty && !b.isContainer && b.rawText != h.rawText { c.append(.cosmetic) }
        return c
    }

    private mutating func assignIds() {
        var used: [String: Int] = [:]
        // Sort for deterministic duplicate numbering.
        let order = pairs.indices.sorted {
            let a = pairs[$0].any, b = pairs[$1].any
            return (a.component, a.decl.qualifiedName, a.file, a.decl.startLine) < (b.component, b.decl.qualifiedName, b.file, b.decl.startLine)
        }
        for i in order {
            let a = pairs[i].any
            var id = "\(a.component)::\(a.decl.qualifiedName)"
            if let n = used[id] {
                used[id] = n + 1
                id += "#\(n + 1)"
            } else {
                used[id] = 1
            }
            pairs[i].id = id
        }
    }

    func parentPair(_ l: Located, side s: Side) -> Int? {
        guard let pi = l.decl.parentIndex else { return nil }
        return pairOf[DeclKey(side: s, file: l.file, index: pi)]
    }

    private func parentDecl(_ l: Located, side s: Side) -> Decl? {
        guard let pi = l.decl.parentIndex else { return nil }
        return side(s).files[l.file]?.decls[pi]
    }

    /// "@MainActor P" -> "P".
    static func conformanceName(_ s: String) -> String {
        s.split(separator: " ").last.map(String.init) ?? s
    }

    /// Each language's contract flags, with its prefix.
    private mutating func computeFlags() {
        let byLanguage = Dictionary(grouping: pairs.indices, by: { language(of: pairs[$0].any.file).id })
        for lang in languages {
            for (i, flags) in lang.contractFlags(self, pairs: byLanguage[lang.id] ?? []) {
                pairs[i].flags = flags.map { "\(lang.id):\($0)" }
            }
        }
    }

    // MARK: References and edges

    private mutating func addRef(_ s: Side, from: String, to: String, ref: Ref) {
        guard from != to else { return }
        edgeRefs[s]![from, default: [:]][to, default: []].append(ref)
    }

    private mutating func externalComponent(for module: String, language: Language, layout: ComponentLayout) -> String? {
        guard let pkg = layout.externalProducts[module] ?? language.package(ofModule: module, pinned: pinnedPackages) else { return nil }
        let id = "ext:\(pkg)"
        externalComponents[id] = pkg
        return id
    }

    /// Adds a language's exact references, and records how much of each side they cover; uncovered files
    /// fall back to name matching. Test files are left out of the count, because a scheme's build action
    /// often doesn't build test targets.
    mutating func addIndex(_ sides: [Side: SideIndex], language lang: Language) {
        for (s, idx) in sides {
            index[s, default: SideIndex(refs: [:])].refs.merge(idx.refs) { a, _ in a }
            let layout = side(s).layout
            let all = side(s).files.filter { $0.value.language == lang.id }.keys.filter { path in
                guard !side(s).generated.contains(path), let c = layout.fileComponent[path] else { return false }
                return layout.components[c]?.isTest != true && !ComponentBuilder.isTestPath(path)
            }
            let missing = all.filter { idx.refs[$0] == nil }.sorted()
            if !missing.isEmpty {
                warnings.insert(Warning(kind: "index-partial",
                    message: "\(missing.count) of \(all.count) \(lang.displayName) files had no index data at \(s.rawValue), so their references were matched by name (first: \(missing.prefix(3).joined(separator: ", ")))."))
            }
        }
    }

    /// The declaration whose name sits at `line` of `file`: the innermost one around it, preferring one whose
    /// name matches the index's symbol name.
    func declAt(_ s: Side, file: String, line: Int, name: String) -> (index: Int, decl: Decl)? {
        guard let parsed = side(s).files[file] else { return nil }
        let base = String(name.prefix { $0 != "(" })
        var best: (Int, Decl)?
        var bestNamed: (Int, Decl)?
        for (i, d) in parsed.decls.enumerated() where d.startLine <= line && line <= d.endLine {
            if best == nil || d.endLine - d.startLine <= best!.1.endLine - best!.1.startLine { best = (i, d) }
            if d.name == base, bestNamed == nil || d.endLine - d.startLine <= bestNamed!.1.endLine - bestNamed!.1.startLine { bestNamed = (i, d) }
        }
        return bestNamed ?? best
    }

    /// The top-level declaration that contains a declaration (itself when it is top level).
    func topLevelDecl(_ s: Side, file: String, index i: Int) -> Decl? {
        guard let parsed = side(s).files[file] else { return nil }
        var cur = i
        while let p = parsed.decls[cur].parentIndex { cur = p }
        return parsed.decls[cur]
    }

    /// Index mode for one file: each reference resolves to the exact declaration it points at.
    private mutating func resolveIndexed(_ s: Side, path: String, file: ParsedFile, comp: String, refs: [IndexedRef]) {
        let layout = side(s).layout
        var seen = Set<String>()
        for ref in refs {
            guard let targetComp = layout.fileComponent[ref.targetFile],
                  let target = declAt(s, file: ref.targetFile, line: ref.targetLine, name: ref.name) else { continue }
            let encl = file.enclosingDecl(line: ref.line)
            // References to parts of the enclosing declaration itself (its parameters, local names) are not uses.
            if ref.targetFile == path, let encl, target.decl.startLine >= encl.startLine && target.decl.endLine <= encl.endLine { continue }
            let key = "\(ref.line)|\(ref.targetFile)|\(target.index)"
            guard seen.insert(key).inserted else { continue }
            let usage = Usage(component: comp, symbol: encl?.qualifiedName ?? "(top level)", file: path, line: ref.line)
            let targetPair = pairOf[DeclKey(side: s, file: ref.targetFile, index: target.index)]
            if s == .head, let tp = targetPair { indexCallers[tp, default: []].append(usage) }
            guard targetComp != comp else { continue }
            let top = topLevelDecl(s, file: ref.targetFile, index: target.index)
            addRef(s, from: comp, to: targetComp, ref: Ref(file: path, line: ref.line, symbol: top?.name ?? target.decl.name, side: s))
            if let tp = targetPair { usedBy[tp, default: []].insert(usage) }
            if let encl, let idx = file.decls.firstIndex(where: { $0.startLine == encl.startLine && $0.qualifiedName == encl.qualifiedName }),
               let pi = pairOf[DeclKey(side: s, file: path, index: idx)] {
                dependsOn[pi, default: []].insert(Usage(component: targetComp, symbol: target.decl.qualifiedName, file: path, line: ref.line))
            }
        }
    }

    mutating func resolveReferences() {
        for s in [Side.base, .head] {
            let data = side(s)
            let layout = data.layout
            // Changed member entities by name, for member-level usage.
            var membersByName: [String: [(component: String, rootType: String, pair: Int)]] = [:]
            for (i, p) in pairs.enumerated() {
                guard let loc = s == .head ? p.head : p.base, let scope = loc.decl.scope, !loc.decl.isContainer,
                      !p.changes.isEmpty, p.changes != [.cosmetic] else { continue }
                let root = String(scope.split(separator: ".").first ?? Substring(scope))
                membersByName[loc.decl.name, default: []].append((loc.component, root, i))
            }
            // Top-level declarations by (component, name) -> pair index, for type-level usage.
            var topLevel: [String: Int] = [:]
            for (i, p) in pairs.enumerated() {
                guard let loc = s == .head ? p.head : p.base, loc.decl.isTopLevel, loc.decl.kind != .extension else { continue }
                topLevel["\(loc.component)|\(loc.decl.name)"] = i
            }

            var ambiguous: [String: Set<String>] = [:]
            for path in data.files.keys.sorted() {
                guard let file = data.files[path], let comp = layout.fileComponent[path] else { continue }
                let lang = language(of: path)
                let module = layout.components[comp]?.module
                var visible = Set(file.imports.map(\.name))
                if let module { visible.insert(module) }
                var resolvedTypes = Set<String>() // "component|TypeName"

                for imp in file.imports {
                    if let target = layout.moduleComponent[imp.name], layout.components[target]?.module != module {
                        addRef(s, from: comp, to: target, ref: Ref(file: path, line: imp.line, symbol: "import \(imp.name)", side: s))
                    } else if let ext = externalComponent(for: imp.name, language: lang, layout: layout) {
                        addRef(s, from: comp, to: ext, ref: Ref(file: path, line: imp.line, symbol: "import \(imp.name)", side: s))
                    } else if layout.moduleComponent[imp.name] == nil && !lang.platformModules.contains(imp.name) {
                        warnings.insert(Warning(kind: "unresolved-import", message: "import \(imp.name) matches no target or known package product."))
                    }
                }

                if let refs = index[s]?.refs[path] {
                    resolveIndexed(s, path: path, file: file, comp: comp, refs: refs)
                    continue
                }

                var seenRef = Set<NameRef>()
                for ref in file.typeRefs where !seenRef.contains(ref) {
                    seenRef.insert(ref)
                    guard var cands = data.declTable[ref.name], !cands.contains(comp) else { continue }
                    cands = cands.filter { c in
                        guard let m = layout.components[c]?.module else { return true }
                        return visible.contains(m)
                    }
                    if cands.count > 1 {
                        ambiguous[ref.name, default: []].formUnion(cands)
                        continue
                    }
                    guard let target = cands.first else { continue }
                    addRef(s, from: comp, to: target, ref: Ref(file: path, line: ref.line, symbol: ref.name, side: s))
                    resolvedTypes.insert("\(target)|\(ref.name)")
                    let encl = file.enclosingDecl(line: ref.line)
                    if let ti = topLevel["\(target)|\(ref.name)"] {
                        usedBy[ti, default: []].insert(Usage(component: comp, symbol: encl?.qualifiedName ?? "(top level)", file: path, line: ref.line))
                    }
                    if let encl, let idx = file.decls.firstIndex(where: { $0.startLine == encl.startLine && $0.qualifiedName == encl.qualifiedName }),
                       let pi = pairOf[DeclKey(side: s, file: path, index: idx)] {
                        dependsOn[pi, default: []].insert(Usage(component: target, symbol: ref.name, file: path, line: ref.line))
                    }
                }
                for ref in Set(file.memberRefs) {
                    for m in membersByName[ref.name] ?? [] where m.component != comp && resolvedTypes.contains("\(m.component)|\(m.rootType)") {
                        let encl = file.enclosingDecl(line: ref.line)
                        usedBy[m.pair, default: []].insert(Usage(component: comp, symbol: encl?.qualifiedName ?? "(top level)", file: path, line: ref.line))
                    }
                }
            }
            for (name, comps) in ambiguous {
                warnings.insert(Warning(kind: "ambiguous-name",
                    message: "\(name) is declared in \(comps.sorted().joined(separator: ", ")); references to it were not resolved (\(s.rawValue))."))
            }
            for dep in layout.manifestDeps {
                if let target = layout.moduleComponent[dep.module] {
                    addRef(s, from: dep.from, to: target, ref: Ref(file: dep.file, line: 0, symbol: "dependency \(dep.module)", side: s))
                } else if let ext = externalComponent(for: dep.module, language: Languages.named(dep.language)!, layout: layout) {
                    addRef(s, from: dep.from, to: ext, ref: Ref(file: dep.file, line: 0, symbol: "dependency \(dep.module)", side: s))
                }
            }
        }
    }

    // MARK: Non-code contracts

    /// Changed non-code files that a language counts as part of a contract, as `file` entities.
    mutating func addContractFiles(baseBlobs: [String: String], headBlobs: [String: String], baseDir: String, headDir: String) {
        func flag(for path: String) -> (key: String, flag: String, language: Language)? {
            for lang in languages { if let (key, f) = lang.contractFile(path) { return (key, f, lang) } }
            return nil
        }
        var groups: [String: (flag: String, language: Language)] = [:]
        for path in Set(baseBlobs.keys).union(headBlobs.keys) {
            guard baseBlobs[path] != headBlobs[path], let (key, f, lang) = flag(for: path) else { continue }
            groups[key] = (f, lang)
        }
        for (key, g) in groups.sorted(by: { $0.key < $1.key }) {
            let existsBase = baseBlobs.keys.contains { $0 == key || $0.hasPrefix(key + "/") }
            let existsHead = headBlobs.keys.contains { $0 == key || $0.hasPrefix(key + "/") }
            let change: ChangeKind = !existsBase ? .added : !existsHead ? .removed : .body
            var flags = [g.flag]
            if existsBase, existsHead {
                flags += g.language.contractFileFlags(key: key, flag: g.flag, basePath: baseDir + "/" + key, headPath: headDir + "/" + key)
            }
            flags = flags.map { "\(g.language.id):\($0)" }
            let s: Side = existsHead ? .head : .base
            let comp = nearestComponent(for: key, side: s)
            let lines = (try? String(contentsOfFile: (s == .head ? headDir : baseDir) + "/" + key, encoding: .utf8))?
                .split(separator: "\n", omittingEmptySubsequences: false).count ?? 1
            let loc = Location(file: key, startLine: 1, endLine: max(1, lines), side: s)
            fileEntities.append(Entity(
                id: "\(comp)::\(key)", component: comp, kind: .file, qualifiedName: key, parent: nil,
                isInterface: true, change: change, changes: [change], signature: Signature(base: nil, head: nil),
                contractFlags: flags, tags: [], location: loc, baseLocation: nil, usedBy: [], dependsOn: []))
        }
    }

    mutating func addTargetSettings() {
        let b = base.layout.targetSettings, h = head.layout.targetSettings
        for id in Set(b.keys).intersection(h.keys).sorted() {
            let bs = b[id]!.settings, hs = h[id]!.settings
            let keys = Set(bs.keys).union(hs.keys).filter { bs[$0] != hs[$0] }.sorted()
            guard !keys.isEmpty, let lang = Languages.named(h[id]!.language) else { continue }
            let flags = Set(keys.map { "\(lang.id):\(lang.settingFlag($0))" })
            func show(_ m: [String: String]) -> String? {
                let lines = keys.compactMap { k in m[k].map { $0 == "on" ? k : "\(k) = \($0)" } }
                return lines.isEmpty ? nil : lines.joined(separator: "\n")
            }
            let file = h[id]!.file
            let name = head.layout.components[id]?.name ?? id
            fileEntities.append(Entity(
                id: "\(id)::build settings", component: id, kind: .target, qualifiedName: "\(name) build settings", parent: nil,
                isInterface: true, change: .modifiers, changes: [.modifiers],
                signature: Signature(base: show(bs), head: show(hs)), contractFlags: flags.sorted(), tags: [],
                location: Location(file: file, startLine: 1, endLine: 1, side: .head), baseLocation: nil, usedBy: [], dependsOn: []))
        }
    }

    /// The component of the source file sharing the longest directory prefix with `path`.
    private mutating func nearestComponent(for path: String, side s: Side) -> String {
        let layout = side(s).layout
        let dirs = path.split(separator: "/").dropLast()
        var best: (Int, String)?
        for (f, c) in layout.fileComponent {
            let fd = f.split(separator: "/").dropLast()
            var n = 0
            while n < dirs.count && n < fd.count && dirs[dirs.startIndex + n] == fd[fd.startIndex + n] { n += 1 }
            if n > 0, best == nil || n > best!.0 || (n == best!.0 && c < best!.1) { best = (n, c) }
        }
        if let best { return layout.components[best.1]?.parent ?? best.1 }
        let top = path.split(separator: "/").count > 1 ? String(path.split(separator: "/")[0]) : "."
        return "folder:\(top)"
    }

    // MARK: External packages

    mutating func diffExternalDeps(baseBlobs: [String: String], headBlobs: [String: String], baseDir: String, headDir: String) {
        func pins(_ blobs: [String: String], _ dir: String) -> [String: String] {
            languages.reduce(into: [:]) { result, lang in result.merge(lang.pinnedPackages(blobs: blobs, dir: dir)) { a, _ in a } }
        }
        let b = pins(baseBlobs, baseDir)
        let h = pins(headBlobs, headDir)
        pinnedPackages = Set(b.keys).union(h.keys)
        for name in Set(b.keys).union(h.keys).sorted() {
            switch (b[name], h[name]) {
            case (nil, let to?): externalDeps.append(ExternalDepChange(name: name, change: "added", from: nil, to: to))
            case (let from?, nil): externalDeps.append(ExternalDepChange(name: name, change: "removed", from: from, to: nil))
            case (let from?, let to?) where from != to:
                externalDeps.append(ExternalDepChange(name: name, change: "bumped", from: from, to: to))
            default: break
            }
        }
    }

    // MARK: Output

    func finish(repo: RepoInfo) -> ChangeModel {
        // Entities: everything that changed (containers only when their own header changed or they carry flags).
        var entities: [Entity] = []
        for (i, p) in pairs.enumerated() {
            let d = p.any.decl
            var changes = p.changes
            if d.isContainer {
                changes.removeAll { $0 == .cosmetic }
                if changes.isEmpty && p.flags.isEmpty { continue }
                if changes.isEmpty { changes = [.body] }
            } else if changes.isEmpty {
                continue
            }
            let s: Side = p.head != nil ? .head : .base
            let loc = p.any
            let data = side(s)
            let comp = data.layout.components[loc.component]
            var tags: [String] = []
            if comp?.isTest == true || ComponentBuilder.isTestPath(loc.file) { tags.append("test") }
            if data.generated.contains(loc.file) { tags.append("generated") }
            let parentId = parentPair(loc, side: s).map { pairs[$0].id }
            let used = (usedBy[i] ?? []).sorted { ($0.file, $0.line, $0.symbol) < ($1.file, $1.line, $1.symbol) }
            let deps = (dependsOn[i] ?? []).filter { u in u.line >= loc.decl.startLine && u.line <= loc.decl.endLine }
                .sorted { ($0.component, $0.symbol, $0.line) < ($1.component, $1.symbol, $1.line) }
            entities.append(Entity(
                id: p.id, component: loc.component, kind: d.kind, qualifiedName: d.qualifiedName, parent: parentId,
                isInterface: false, change: changes[0], changes: changes,
                signature: Signature(base: p.base?.decl.signatureDisplay, head: p.head?.decl.signatureDisplay),
                contractFlags: p.flags, tags: tags,
                location: Location(file: loc.file, startLine: d.startLine, endLine: d.endLine, side: s),
                baseLocation: (p.head != nil ? p.base : nil).map {
                    Location(file: $0.file, startLine: $0.decl.startLine, endLine: $0.decl.endLine, side: .base)
                },
                usedBy: used, dependsOn: deps))
        }
        // Interface: public/open/package, used from another component, or a requirement/case of an interface type.
        var interfaceIds = Set<String>()
        for (i, p) in pairs.enumerated() {
            let access = p.head?.decl.access ?? p.base?.decl.access
            let nonTestUse = (usedBy[i] ?? []).contains { u in
                !(head.layout.components[u.component]?.isTest ?? base.layout.components[u.component]?.isTest ?? false)
            }
            if ["public", "open", "package"].contains(access ?? "") || nonTestUse {
                interfaceIds.insert(p.id)
            }
        }
        for (i, p) in pairs.enumerated() {
            let d = p.any.decl
            guard d.parentKind == .protocol || d.kind == .case, let pp = parentPair(p.any, side: p.head != nil ? .head : .base) else { continue }
            if interfaceIds.contains(pairs[pp].id) { interfaceIds.insert(pairs[i].id) }
        }
        for i in entities.indices { entities[i].isInterface = interfaceIds.contains(entities[i].id) }
        entities += fileEntities
        entities.sort { ($0.component, $0.location.file, $0.location.startLine, $0.id) < ($1.component, $1.location.file, $1.location.startLine, $1.id) }

        // Edges.
        var edges: [Edge] = []
        var keys = Set<String>()
        for s in [Side.base, .head] {
            for (from, tos) in edgeRefs[s]! { for to in tos.keys { keys.insert("\(from)\u{1}\(to)") } }
        }
        for key in keys.sorted() {
            let parts = key.split(separator: "\u{1}").map(String.init)
            let (from, to) = (parts[0], parts[1])
            let bRefs = edgeRefs[.base]![from]?[to] ?? []
            let hRefs = edgeRefs[.head]![from]?[to] ?? []
            let bSyms = Set(bRefs.map(\.symbol)), hSyms = Set(hRefs.map(\.symbol))
            let status: EdgeStatus = bRefs.isEmpty ? .added : hRefs.isEmpty ? .removed : bSyms != hSyms ? .changed : .unchanged
            let addedSyms = hSyms.subtracting(bSyms), removedSyms = bSyms.subtracting(hSyms)
            let sortRefs: ([Ref]) -> [Ref] = { $0.sorted { ($0.file, $0.line, $0.symbol) < ($1.file, $1.line, $1.symbol) } }
            var refs = sortRefs(hRefs.filter { addedSyms.contains($0.symbol) }) + sortRefs(bRefs.filter { removedSyms.contains($0.symbol) })
            let rest = status == .removed ? bRefs : hRefs
            refs += sortRefs(rest.filter { !addedSyms.contains($0.symbol) && !removedSyms.contains($0.symbol) })
            edges.append(Edge(from: from, to: to, status: status, symbolsAdded: addedSyms.sorted(), symbolsRemoved: removedSyms.sorted(),
                              refs: Array(refs.prefix(options.maxRefsPerEdge)),
                              refCount: status == .removed ? bRefs.count : hRefs.count))
        }

        // Components.
        var components: [String: Component] = [:]
        for s in [Side.base, .head] {
            let layout = side(s).layout
            for (id, info) in layout.components {
                let files = layout.fileComponent.filter { $0.value == id }.map(\.key)
                var c = components[id] ?? Component(
                    id: id, name: info.name, kind: info.kind, layer: info.layer, module: info.module, parent: info.parent,
                    isTest: info.isTest, paths: [], status: s == .base ? "removed" : "added",
                    changedEntities: 0, interfaceChanges: 0, changeScore: 0)
                if s == .head {
                    c.status = components[id] == nil ? "added" : nil
                    c.name = info.name; c.layer = info.layer; c.module = info.module; c.parent = info.parent; c.isTest = info.isTest
                }
                if s == .head || c.paths.isEmpty { c.paths = Self.minimalDirs(files) }
                components[id] = c
            }
        }
        for (id, name) in externalComponents where components[id] == nil {
            components[id] = Component(id: id, name: name, kind: .external, layer: nil, module: nil, parent: nil, isTest: false,
                                       paths: [], status: nil, changedEntities: 0, interfaceChanges: 0, changeScore: 0)
        }
        for e in entities where components[e.component] == nil {
            components[e.component] = Component(id: e.component, name: String(e.component.split(separator: ":").last ?? ""),
                                                kind: .folder, layer: nil, module: nil, parent: nil, isTest: false,
                                                paths: [], status: nil, changedEntities: 0, interfaceChanges: 0, changeScore: 0)
        }
        var raw: [String: Double] = [:]
        for e in entities where e.change != .cosmetic {
            components[e.component]!.changedEntities += 1
            let structural = e.change == .signature || e.change == .modifiers || e.change == .added || e.change == .removed || !e.contractFlags.isEmpty
            if e.isInterface && structural { components[e.component]!.interfaceChanges += 1 }
            var w = e.change == .body ? 1.0 : 1.5
            if e.isInterface && structural { w += 2 }
            w += Double(e.contractFlags.count)
            if e.tags.contains("test") || e.tags.contains("generated") { w *= 0.2 }
            raw[e.component, default: 0] += w
        }
        for e in edges where e.status != .unchanged {
            raw[e.from, default: 0] += 1
            raw[e.to, default: 0] += 0.5
        }
        let maxScore = raw.values.max() ?? 0
        for (id, v) in raw where components[id] != nil {
            components[id]!.changeScore = maxScore > 0 ? (v / maxScore * 1000).rounded() / 1000 : 0
        }
        externalDepsComponents(&components)
        // Components without source files (e.g. only Info.plist changed) take their paths from their entities.
        let entityFiles = Dictionary(grouping: entities.filter { $0.kind != .target }, by: \.component).mapValues { $0.map(\.location.file) }
        for (id, c) in components where c.paths.isEmpty && c.kind != .external {
            components[id]!.paths = Self.minimalDirs(entityFiles[id] ?? [])
        }

        let sortedWarnings = warnings.sorted { ($0.kind, $0.file ?? "", $0.line ?? 0, $0.message) < ($1.kind, $1.file ?? "", $1.line ?? 0, $1.message) }
        return ChangeModel(
            analyzer: AnalyzerInfo(version: Analyzer.version, resolution: index.isEmpty ? "name-based" : "index",
                                   languages: languages.map(\.id)),
            repo: repo,
            components: components.values.sorted { $0.id < $1.id },
            edges: edges,
            externalDeps: externalDeps,
            entities: entities,
            regions: buildRegions(entities),
            warnings: sortedWarnings)
    }

    private func externalDepsComponents(_ components: inout [String: Component]) {
        for dep in externalDeps {
            let id = "ext:\(dep.name)"
            if components[id] == nil {
                components[id] = Component(id: id, name: dep.name, kind: .external, layer: nil, module: nil, parent: nil,
                                           isTest: false, paths: [], status: nil, changedEntities: 0, interfaceChanges: 0, changeScore: 0)
            }
            if dep.change == "added" { components[id]!.status = "added" }
            if dep.change == "removed" { components[id]!.status = "removed" }
        }
    }

    static func minimalDirs(_ files: [String]) -> [String] {
        let dirs = Set(files.map { ($0 as NSString).deletingLastPathComponent }).sorted()
        var result: [String] = []
        for d in dirs where !result.contains(where: { !$0.isEmpty && (d == $0 || d.hasPrefix($0 + "/")) }) {
            result.append(d.isEmpty ? "." : d)
        }
        return result
    }
}
