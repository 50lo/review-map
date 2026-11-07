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

    public static func run(_ options: AnalyzeOptions, log: (String) -> Void = { _ in }) throws -> ChangeReport {
        try run(options, log: log, index: nil)
    }

    /// `index`, for tests, stands in for the languages' indexers: given a language and the two sides'
    /// exported trees, it returns that language's references, or nil for none.
    static func run(_ options: AnalyzeOptions, log: (String) -> Void = { _ in },
                    index injected: ((Language, _ baseDir: String, _ headDir: String) -> [Side: SideIndex]?)?) throws -> ChangeReport {
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

        var builder = ChangeReportBuilder(base: baseSide, head: headSide, languages: languages, options: options)
        let indexOptions = options.index.merged(with: config.index)
        if let injected {
            for lang in languages { if let idx = injected(lang, baseDir, headDir) { builder.addIndex(idx, language: lang) } }
        } else if indexOptions.enabled == true {
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
        builder.matchReviewItems()
        builder.resolveReferences()
        builder.addContractFiles(baseBlobs: baseBlobs, headBlobs: headBlobs, baseDir: baseDir, headDir: headDir)
        builder.addTargetSettings()

        let repo = RepoInfo(root: root, base: options.base, head: options.head, baseSha: baseSha, headSha: headSha,
                            usesMergeBase: options.useMergeBase)
        log("Running structural checks…")
        return builder.finish(repo: repo, config: config)
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
        RustModules.resolve(&result)
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
    /// Import paths -> source file: each file without its extension ("src/cart" for "src/cart.ts"), and a
    /// directory for its index file ("src/models" for "src/models/index.ts"). See `NameRef.source`.
    let modulePaths: [String: String]

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
        let generated = Set(paths.filter { p in gen.contains { $0.matches(p) } || files[p]?.isGenerated == true })
        var modulePaths: [String: String] = [:]
        for path in paths {
            var key = (path as NSString).deletingPathExtension
            if key.hasSuffix(".d") { key = String(key.dropLast(2)) }
            if modulePaths[key] == nil || !path.hasSuffix(".d.ts") { modulePaths[key] = path }
            if (key as NSString).lastPathComponent == "index" {
                let dir = (key as NSString).deletingLastPathComponent
                if modulePaths[dir] == nil { modulePaths[dir] = path }
            }
        }
        return SideData(side: side, dir: dir, files: files, layout: layout, declTable: table, generated: generated,
                        modulePaths: modulePaths)
    }
}

// MARK: - Change report building

/// A declaration located at one side.
struct Located {
    var decl: Declaration
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

struct ChangeReportBuilder {
    let base: SideData
    let head: SideData
    let languages: [Language]
    let options: AnalyzeOptions
    /// Head containers by their explicit inherited names, in source order. Languages with implicit
    /// conformance replace this lookup through their `conformers` hook. Region override context
    /// also uses this syntax-based table; it does not infer implicit conformances.
    let inheritors: [String: [Located]]
    /// "Type|member" -> head declarations, in source order, across every file and component.
    /// The default conformance check preserves its global name lookup. RegionBuilder separately
    /// groups all members by component and scope for definition, override, and state context.
    let headMembers: [String: [Located]]

    var pairs: [Pair] = []
    var pairOf: [DeclKey: Int] = [:]
    var fileReviewItems: [ReviewItem] = []
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
    /// Ids of the languages whose references came from an index.
    var indexedLanguages = Set<String>()

    init(base: SideData, head: SideData, languages: [Language], options: AnalyzeOptions) {
        self.base = base
        self.head = head
        self.languages = languages
        self.options = options
        var inheritors: [String: [Located]] = [:]
        var headMembers: [String: [Located]] = [:]
        for path in head.files.keys.sorted() {
            guard let file = head.files[path], let component = head.layout.fileComponent[path] else { continue }
            for (i, decl) in file.decls.enumerated() {
                let located = Located(decl: decl, file: path, index: i, component: component)
                if decl.isContainer {
                    for name in decl.inherited.map(Self.conformanceName) { inheritors[name, default: []].append(located) }
                }
                if let scope = decl.scope { headMembers["\(scope)|\(decl.name)", default: []].append(located) }
            }
        }
        self.inheritors = inheritors
        self.headMembers = headMembers
        for w in base.layout.warnings + head.layout.warnings { warnings.insert(w) }
    }

    func side(_ s: Side) -> SideData { s == .base ? base : head }

    /// The language of a parsed source file.
    func language(of file: String) -> Language {
        languages.first { $0.isSource(file) }!
    }

    // MARK: Matching

    static func kindGroup(_ k: ReviewItemKind) -> String {
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

    mutating func matchReviewItems() {
        let bg = locatedDecls(base)
        let hg = locatedDecls(head)
        let keys = Set(bg.keys).union(hg.keys).sorted()
        for key in keys {
            var bs = bg[key] ?? []
            var hs = hg[key] ?? []
            var matched: [(Located?, Located?)] = []
            let passes: [(Declaration, Declaration) -> Bool] = [
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

    private static func changes(_ b: Declaration?, _ h: Declaration?) -> [ChangeKind] {
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

    private func parentDecl(_ l: Located, side s: Side) -> Declaration? {
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
        indexedLanguages.insert(lang.id)
        for (s, idx) in sides {
            index[s, default: SideIndex(refs: [:])].refs.merge(idx.refs) { a, _ in a }
            for w in idx.warnings { warnings.insert(w) }
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
    func declAt(_ s: Side, file: String, line: Int, name: String) -> (index: Int, decl: Declaration)? {
        guard let parsed = side(s).files[file] else { return nil }
        let base = String(name.prefix { $0 != "(" })
        var best: (Int, Declaration)?
        var bestNamed: (Int, Declaration)?
        for (i, d) in parsed.decls.enumerated() where d.startLine <= line && line <= d.endLine {
            if best == nil || d.endLine - d.startLine <= best!.1.endLine - best!.1.startLine { best = (i, d) }
            if d.name == base, bestNamed == nil || d.endLine - d.startLine <= bestNamed!.1.endLine - bestNamed!.1.startLine { bestNamed = (i, d) }
        }
        return bestNamed ?? best
    }

    /// The top-level declaration that contains a declaration (itself when it is top level).
    func topLevelDecl(_ s: Side, file: String, index i: Int) -> Declaration? {
        guard let parsed = side(s).files[file] else { return nil }
        var cur = i
        while let p = parsed.decls[cur].parentIndex { cur = p }
        return parsed.decls[cur]
    }

    /// Index mode for one file: each reference resolves to the exact declaration it points at.
    private mutating func resolveIndexed(_ s: Side, path: String, file: ParsedFile, comp: String, refs: [IndexedRef]) {
        let layout = side(s).layout
        let lang = language(of: path)
        var seen = Set<String>()
        for ref in refs {
            guard let targetComp = layout.fileComponent[ref.targetFile],
                  let target = declAt(s, file: ref.targetFile, line: ref.targetLine, name: ref.name) else { continue }
            let encl = file.enclosingDecl(line: ref.line)
            // References to parts of the enclosing declaration itself (its parameters, local names) are not uses.
            if ref.targetFile == path, let encl, target.decl.startLine >= encl.startLine && target.decl.endLine <= encl.endLine { continue }
            let key = "\(ref.line)|\(ref.targetFile)|\(target.index)"
            guard seen.insert(key).inserted else { continue }
            let usage = Usage(component: comp, symbol: encl?.qualifiedName ?? "(top level)", file: path, line: ref.line,
                              isolation: lang.isolation(in: file, line: ref.line), side: s)
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
            // Changed member review items by name, for member-level usage.
            var membersByName: [String: [(component: String, rootType: String, pair: Int, package: String?)]] = [:]
            for (i, p) in pairs.enumerated() {
                guard let loc = s == .head ? p.head : p.base, let scope = loc.decl.scope, !loc.decl.isContainer,
                      !p.changes.isEmpty, p.changes != [.cosmetic] else { continue }
                let root = String(scope.split(separator: ".").first ?? Substring(scope))
                membersByName[loc.decl.name, default: []].append((loc.component, root, i, data.files[loc.file]?.packageName))
            }
            // Top-level declarations by (component, name) -> pair index, for type-level usage.
            var topLevel: [String: Int] = [:]
            for (i, p) in pairs.enumerated() {
                guard let loc = s == .head ? p.head : p.base, loc.decl.isTopLevel, loc.decl.kind != .extension else { continue }
                topLevel["\(loc.component)|\(loc.decl.name)"] = i
            }

            // Source packages can span build-system modules, and a module can contain many packages.
            // Index by package AND declared name so unrelated packages never become visible together.
            var packageDeclarations: [String: [String: Set<String>]] = [:]
            var packageComponents: [String: Set<String>] = [:]
            var packageTopLevel: [String: Int] = [:]
            for (path, file) in data.files {
                guard let package = file.packageName, let component = layout.fileComponent[path] else { continue }
                packageComponents[package, default: []].insert(component)
                for decl in file.decls where decl.isTopLevel {
                    packageDeclarations[package, default: [:]][decl.name, default: []].insert(component)
                }
            }
            for (i, pair) in pairs.enumerated() {
                guard let loc = s == .head ? pair.head : pair.base, loc.decl.isTopLevel,
                      let package = data.files[loc.file]?.packageName else { continue }
                packageTopLevel["\(package)|\(loc.component)|\(loc.decl.name)"] = i
            }
            func packageBinding(_ qualified: String) -> (package: String, name: String)? {
                guard let package = packageComponents.keys.filter({ !$0.isEmpty && qualified.hasPrefix($0 + ".") })
                    .max(by: { $0.count < $1.count }) else { return nil }
                let name = qualified.dropFirst(package.count + 1).split(separator: ".").first.map(String.init) ?? ""
                return (package, name)
            }
            var ambiguous: [String: Set<String>] = [:]
            for path in data.files.keys.sorted() {
                guard let file = data.files[path], let comp = layout.fileComponent[path] else { continue }
                let lang = language(of: path)
                let module = layout.components[comp]?.module
                let aliases = layout.aliases(for: comp)
                var visible = Set(file.imports.map { aliases[$0.name] ?? $0.name })
                if let module { visible.insert(module) }
                var resolvedTypes = Set<String>() // "component|TypeName"

                for imp in file.imports {
                    if file.packageName != nil {
                        let targets: Set<String>
                        if file.wildcardImports.contains(imp.name) {
                            targets = packageComponents[imp.name] ?? []
                        } else if let binding = packageBinding(imp.name) {
                            targets = packageDeclarations[binding.package]?[binding.name] ?? []
                        } else { targets = [] }
                        if !targets.isEmpty {
                            for target in targets where target != comp {
                                addRef(s, from: comp, to: target, ref: Ref(file: path, line: imp.line, symbol: "import \(imp.name)", side: s))
                            }
                        } else if !lang.isPlatformModule(imp.name) {
                            if let ext = externalComponent(for: imp.name, language: lang, layout: layout) {
                                addRef(s, from: comp, to: ext, ref: Ref(file: path, line: imp.line, symbol: "import \(imp.name)", side: s))
                            } else {
                                warnings.insert(Warning(kind: "unresolved-import", message: "import \(imp.name) matches no target or known package product."))
                            }
                        }
                        continue
                    }
                    let importName = aliases[imp.name] ?? imp.name
                    if let target = layout.moduleComponent[importName], layout.components[target]?.module != module {
                        addRef(s, from: comp, to: target, ref: Ref(file: path, line: imp.line, symbol: "import \(imp.name)", side: s))
                    } else if let ext = externalComponent(for: imp.name, language: lang, layout: layout) {
                        addRef(s, from: comp, to: ext, ref: Ref(file: path, line: imp.line, symbol: "import \(imp.name)", side: s))
                    } else if layout.moduleComponent[importName] == nil && !lang.isPlatformModule(imp.name) {
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
                    let target: String
                    var resolvedName = ref.name
                    var resolvedPackage: String?
                    if let ownPackage = file.packageName {
                        var choices: [(package: String, component: String, name: String)] = []
                        func addChoices(_ package: String, _ name: String) {
                            for component in packageDeclarations[package]?[name] ?? [] {
                                choices.append((package, component, name))
                            }
                        }
                        if let module = ref.module {
                            if let binding = packageBinding(module.isEmpty ? ref.name : module + "." + ref.name) {
                                addChoices(binding.package, binding.name)
                            }
                        } else {
                            addChoices(ownPackage, ref.name)
                            if choices.isEmpty {
                                for package in Set(file.wildcardImports) { addChoices(package, ref.name) }
                            }
                        }
                        guard !choices.contains(where: { $0.component == comp }) else { continue }
                        if choices.count > 1 {
                            ambiguous[ref.name, default: []].formUnion(choices.map { $0.component })
                            continue
                        }
                        guard let choice = choices.first else { continue }
                        target = choice.component
                        resolvedName = choice.name
                        resolvedPackage = choice.package
                    } else if let source = ref.source.flatMap({ Paths.resolve($0, from: path) }), let sourceFile = data.modulePaths[source],
                       let c = layout.fileComponent[sourceFile] {
                        // The language says which file the name comes from.
                        guard c != comp else { continue }
                        target = c
                    } else {
                        guard var cands = data.declTable[ref.name], !cands.contains(comp) else { continue }
                        cands = cands.filter { c in
                            guard let m = layout.components[c]?.module else { return true }
                            return visible.contains(m)
                        }
                        // A name imported from a module is that module's, or no component's (a third-party package).
                        // An unqualified name is the file's own module's first (a Go test uses its package's names).
                        if let module = ref.module {
                            cands = cands.filter { layout.components[$0]?.module == (aliases[module] ?? module) }
                        } else if let module {
                            let own = cands.filter { layout.components[$0]?.module == module }
                            if !own.isEmpty { cands = own }
                        }
                        if cands.count > 1 {
                            ambiguous[ref.name, default: []].formUnion(cands)
                            continue
                        }
                        guard let only = cands.first else { continue }
                        target = only
                    }
                    addRef(s, from: comp, to: target, ref: Ref(file: path, line: ref.line, symbol: ref.name, side: s))
                    resolvedTypes.insert((resolvedPackage.map { $0 + "|" } ?? "") + "\(target)|\(resolvedName)")
                    let encl = file.enclosingDecl(line: ref.line)
                    let referencedPair = resolvedPackage.flatMap { packageTopLevel["\($0)|\(target)|\(resolvedName)"] } ?? topLevel["\(target)|\(resolvedName)"]
                    if let ti = referencedPair {
                        usedBy[ti, default: []].insert(Usage(component: comp, symbol: encl?.qualifiedName ?? "(top level)", file: path, line: ref.line,
                                                             isolation: lang.isolation(in: file, line: ref.line), side: s))
                    }
                    if let encl, let idx = file.decls.firstIndex(where: { $0.startLine == encl.startLine && $0.qualifiedName == encl.qualifiedName }),
                       let pi = pairOf[DeclKey(side: s, file: path, index: idx)] {
                        dependsOn[pi, default: []].insert(Usage(component: target, symbol: ref.name, file: path, line: ref.line))
                    }
                }
                for ref in Set(file.memberRefs) {
                    for m in membersByName[ref.name] ?? [] where m.component != comp && resolvedTypes.contains((m.package.map { $0 + "|" } ?? "") + "\(m.component)|\(m.rootType)") {
                        let encl = file.enclosingDecl(line: ref.line)
                        usedBy[m.pair, default: []].insert(Usage(component: comp, symbol: encl?.qualifiedName ?? "(top level)", file: path, line: ref.line,
                                                                 isolation: lang.isolation(in: file, line: ref.line), side: s))
                    }
                }
            }
            for (name, comps) in ambiguous {
                warnings.insert(Warning(kind: "ambiguous-name",
                    message: "\(name) is declared in \(comps.sorted().joined(separator: ", ")); references to it were not resolved (\(s.rawValue))."))
            }
            for dep in layout.manifestDeps {
                if let target = layout.moduleComponent[layout.aliases(for: dep.from)[dep.module] ?? dep.module] {
                    addRef(s, from: dep.from, to: target, ref: Ref(file: dep.file, line: 0, symbol: "dependency \(dep.module)", side: s))
                } else if let ext = externalComponent(for: dep.module, language: Languages.named(dep.language)!, layout: layout) {
                    addRef(s, from: dep.from, to: ext, ref: Ref(file: dep.file, line: 0, symbol: "dependency \(dep.module)", side: s))
                }
            }
        }
    }

    // MARK: Non-code contracts

    /// Changed non-code files that a language counts as part of a contract, as `file` review items.
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
            fileReviewItems.append(ReviewItem(
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
            fileReviewItems.append(ReviewItem(
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

    func finish(repo: RepoInfo, config: Config = Config()) -> ChangeReport {
        // Review items: everything that changed (containers only when their own header changed or they carry flags).
        var reviewItems: [ReviewItem] = []
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
            if d.traits.contains("test") || comp?.isTest == true || ComponentBuilder.isTestPath(loc.file) { tags.append("test") }
            if data.generated.contains(loc.file) { tags.append("generated") }
            let parentId = parentPair(loc, side: s).map { pairs[$0].id }
            // A use seen at both sides counts once, as a head use. Uses only at base keep side "base".
            var uses: [String: Usage] = [:]
            for var u in usedBy[i] ?? [] {
                let key = "\(u.component)|\(u.symbol)|\(u.file)|\(u.line)"
                if u.side == .head { u.side = nil }
                if let have = uses[key], have.side == nil { continue }
                uses[key] = u
            }
            let used = uses.values.sorted { ($0.file, $0.line, $0.symbol, $0.component) < ($1.file, $1.line, $1.symbol, $1.component) }
            let deps = (dependsOn[i] ?? []).filter { u in u.line >= loc.decl.startLine && u.line <= loc.decl.endLine }
                .sorted { ($0.component, $0.symbol, $0.line) < ($1.component, $1.symbol, $1.line) }
            reviewItems.append(ReviewItem(
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
        for i in reviewItems.indices { reviewItems[i].isInterface = interfaceIds.contains(reviewItems[i].id) }
        let similar = similarDeclarations(reviewItems)
        for i in reviewItems.indices { reviewItems[i].similar = similar[reviewItems[i].id] }
        reviewItems += fileReviewItems
        reviewItems.sort { ($0.component, $0.location.file, $0.location.startLine, $0.id) < ($1.component, $1.location.file, $1.location.startLine, $1.id) }

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
                    changedReviewItems: 0, interfaceChanges: 0, changeScore: 0)
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
                                       paths: [], status: nil, changedReviewItems: 0, interfaceChanges: 0, changeScore: 0)
        }
        for e in reviewItems where components[e.component] == nil {
            components[e.component] = Component(id: e.component, name: String(e.component.split(separator: ":").last ?? ""),
                                                kind: .folder, layer: nil, module: nil, parent: nil, isTest: false,
                                                paths: [], status: nil, changedReviewItems: 0, interfaceChanges: 0, changeScore: 0)
        }
        var raw: [String: Double] = [:]
        for e in reviewItems where e.change != .cosmetic {
            components[e.component]!.changedReviewItems += 1
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
        // Components without source files (e.g. only Info.plist changed) take their paths from their review items.
        let reviewItemFiles = Dictionary(grouping: reviewItems.filter { $0.kind != .target }, by: \.component).mapValues { $0.map(\.location.file) }
        for (id, c) in components where c.paths.isEmpty && c.kind != .external {
            components[id]!.paths = Self.minimalDirs(reviewItemFiles[id] ?? [])
        }

        let findings = StructuralChecks(self, reviewItems: reviewItems, edges: edges, config: config).run()
        let sortedWarnings = warnings.sorted { ($0.kind, $0.file ?? "", $0.line ?? 0, $0.message) < ($1.kind, $1.file ?? "", $1.line ?? 0, $1.message) }
        return ChangeReport(
            analyzer: AnalyzerInfo(version: Analyzer.version, resolution: index.isEmpty ? "name-based" : "index",
                                   languages: languages.map(\.id)),
            repo: repo,
            components: components.values.sorted { $0.id < $1.id },
            edges: edges,
            externalDeps: externalDeps,
            reviewItems: reviewItems,
            regions: buildRegions(reviewItems),
            warnings: sortedWarnings,
            findings: findings)
    }

    private func externalDepsComponents(_ components: inout [String: Component]) {
        for dep in externalDeps {
            let id = "ext:\(dep.name)"
            if components[id] == nil {
                components[id] = Component(id: id, name: dep.name, kind: .external, layer: nil, module: nil, parent: nil,
                                           isTest: false, paths: [], status: nil, changedReviewItems: 0, interfaceChanges: 0, changeScore: 0)
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
