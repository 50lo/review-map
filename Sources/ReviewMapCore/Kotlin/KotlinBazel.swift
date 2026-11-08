import Foundation

// Kotlin's index for a Bazel workspace that builds Kotlin with rules_kotlin. scip-java's own Bazel aspect only
// covers javac, so Review Map drives the Kotlin indexer itself:
//
// 1. A small aspect, written into the exported tree, lists each rules_kotlin target's Kotlin sources and compile
//    classpath in a JSON manifest. Building its output group builds the classpath jars too.
// 2. The Kotlin indexer in the scip-java launcher (`org.scip_code.scip_java.kotlin_analysis.MainKt`) indexes each
//    target's sources against its classpath into one target root.
// 3. `scip-java aggregate` merges the shards into one SCIP index per workspace, cached per commit next to the
//    Gradle ones, with the targets beside it for scoping.
//
// Bazel runs in a temporary output base that is expunged afterwards, sharing Review Map's disk cache with Swift's
// Bazel builds. It is a separate Bazel invocation, so Swift's flags and outputs are never touched.

enum KotlinBazel {
    /// The aspect's package in the exported tree. It is removed again after the build.
    static let aspectPackage = ".reviewmap_kotlin"
    static let outputGroup = "reviewmap_kotlin"
    static let manifestSuffix = ".reviewmap_kotlin.json"
    static let indexerMainClass = "org.scip_code.scip_java.kotlin_analysis.MainKt"

    /// A rules_kotlin target as the aspect lists it.
    struct Target: Codable, Equatable {
        /// Such as "@@//app:app".
        var label: String
        /// Relative to the Bazel workspace.
        var sources: [String]
        /// Relative to the execution root.
        var classpath: [String]
        /// The workspace's own targets whose jars are on the classpath.
        var deps: [String]
    }

    static func load(side s: IndexSide, cache: String, options: IndexOptions, repoRoot: String, log: (String) -> Void) throws -> SideIndex {
        let cwdRel = options.workingDirectory.flatMap { IndexBuilder.BuildPlan.repoRelative($0, repoRoot: repoRoot) }
        guard let workspace = try IndexBuilder.BuildPlan.bazelWorkspace(s.dir, under: cwdRel) else {
            throw IndexError("Kotlin indexing with Bazel needs a Bazel workspace (MODULE.bazel or WORKSPACE) at \(s.side.rawValue).")
        }
        let ws = workspace == "." ? "" : workspace
        let name = "bazel-" + KotlinIndex.cacheName(ws)
        let indexPath = cache + "/\(name).scip"
        let targetsPath = cache + "/\(name).targets.json"
        let fm = FileManager.default
        if options.rebuild || !fm.fileExists(atPath: indexPath) || !fm.fileExists(atPath: targetsPath) {
            try build(side: s, workspace: ws, indexPath: indexPath, targetsPath: targetsPath, options: options, log: log)
        } else {
            log("Kotlin index for \(s.side.rawValue) \(s.sha.prefix(8)) (Bazel\(ws.isEmpty ? "" : " in \(ws)")): cached.")
        }
        var index = try SCIP.decode(try Data(contentsOf: URL(fileURLWithPath: indexPath)))
        let targets = try JSONDecoder().decode([Target].self, from: try Data(contentsOf: URL(fileURLWithPath: targetsPath)))
        scopeDuplicateSymbols(&index, targets: targets)
        index.projectRoot = URL(fileURLWithPath: join(s.dir, ws)).absoluteString
        return SCIP.sideIndex([index], sourceRoot: s.dir, known: Set(s.files))
    }

    /// The Bazel command: `REVIEWMAP_BAZEL`, else bazel, else bazelisk, as for Swift.
    static func bazelCommand() -> String? {
        if let command = ProcessInfo.processInfo.environment["REVIEWMAP_BAZEL"] {
            return Shell.exists(command) ? command : nil
        }
        return ["bazel", "bazelisk"].first(where: Shell.exists)
    }

    private static func build(side s: IndexSide, workspace ws: String, indexPath: String, targetsPath: String,
                              options: IndexOptions, log: (String) -> Void) throws {
        let fm = FileManager.default
        let at = ws.isEmpty ? "" : " in \(ws)"
        guard let bazel = bazelCommand() else {
            throw IndexError("Kotlin indexing with Bazel needs bazel or bazelisk on the PATH.")
        }
        guard KotlinIndex.hasJava() else { throw IndexError("Kotlin indexing needs a JDK (java on the PATH, version 17 or newer).") }
        let cache = (indexPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: cache, withIntermediateDirectories: true)
        let logPath = indexPath + ".log"
        FileManager.default.createFile(atPath: logPath, contents: nil)

        let dir = join(s.dir, ws)
        let aspectDir = join(dir, aspectPackage)
        try fm.createDirectory(atPath: aspectDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: aspectDir) }
        fm.createFile(atPath: aspectDir + "/BUILD.bazel", contents: Data())
        try aspect(rulesKotlin: rulesKotlinRepo(dir)).write(toFile: aspectDir + "/kotlin_index.bzl", atomically: true, encoding: .utf8)

        let scratch = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-kt-\(UUID().uuidString.prefix(8))")
        let startup = [bazel, "--output_base=\(scratch)/output_base", "--max_idle_secs=60"]
        defer {
            _ = try? Shell.runLogged(startup + ["clean", "--expunge"], cwd: dir, logPath: logPath, append: true)
            try? fm.removeItem(atPath: scratch)
        }
        let targets = options.targets ?? ["//..."]
        let start = Date()
        log("Building \(s.side.rawValue) \(s.sha.prefix(8))\(at) with Bazel for the Kotlin index…")
        let command = startup + ["build", "--lockfile_mode=off",
                                 "--aspects=//\(aspectPackage):kotlin_index.bzl%reviewmap_kotlin",
                                 "--output_groups=\(outputGroup)",
                                 "--disk_cache=\((options.cacheDir as NSString).appendingPathComponent(".bazel-disk-cache"))"]
            + (options.bazelArgs ?? []) + ["--"] + targets
        guard try Shell.runLogged(command, cwd: dir, logPath: logPath, append: true) == 0 else {
            throw IndexError("The Bazel build for the Kotlin index failed at \(s.side.rawValue)\(at). Log: \(logPath)")
        }
        let info = try Shell.string(startup + ["info", "--lockfile_mode=off", "execution_root", "bazel-bin"] + (options.bazelArgs ?? []), cwd: dir)
        var values: [String: String] = [:]
        for line in info.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            values[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let execRoot = values["execution_root"], let bin = values["bazel-bin"] else {
            throw IndexError("bazel info gave no execution root at \(s.side.rawValue)\(at). Log: \(logPath)")
        }
        let manifests = try readManifests(bin: bin)
        guard !manifests.isEmpty else {
            throw IndexError("No rules_kotlin targets with Kotlin sources in \(targets.joined(separator: " "))\(at) at \(s.side.rawValue).")
        }

        let launcher = try scipJava(options: options, log: log)
        let targetRoot = indexPath + ".targetroot"
        try? fm.removeItem(atPath: targetRoot)
        defer { try? fm.removeItem(atPath: targetRoot) }
        for t in manifests {
            let classpath = t.classpath.map { join(execRoot, $0) }.joined(separator: ":")
            let status = try Shell.runLogged(["java", "-cp", launcher, indexerMainClass, "--sourceroot", dir, "--targetroot", targetRoot]
                                             + (classpath.isEmpty ? [] : ["--classpath", classpath]) + t.sources.map { join(dir, $0) },
                                             cwd: dir, logPath: logPath, append: true)
            guard status == 0 else {
                throw IndexError("The Kotlin indexer failed for \(t.label) at \(s.side.rawValue). Log: \(logPath)")
            }
        }
        let output = indexPath + ".tmp"
        try? fm.removeItem(atPath: output)
        guard try Shell.runLogged(["java", "-jar", launcher, "aggregate", "--output", output, targetRoot], cwd: dir,
                                  logPath: logPath, append: true) == 0, fm.fileExists(atPath: output) else {
            throw IndexError("scip-java aggregate failed at \(s.side.rawValue)\(at). Log: \(logPath)")
        }
        try JSONEncoder().encode(manifests).write(to: URL(fileURLWithPath: targetsPath))
        try? fm.removeItem(atPath: indexPath)
        try fm.moveItem(atPath: output, toPath: indexPath)
        log("Indexed \(s.side.rawValue)\(at) (\(manifests.count) Kotlin targets) in \(Int(Date().timeIntervalSince(start)))s.")
    }

    /// The scip-java launcher jar: `REVIEWMAP_SCIP_JAVA` when it names a file, else the pinned release in the cache.
    /// A scip-java on the PATH isn't used, since it may be a wrapper script rather than the jar.
    private static func scipJava(options: IndexOptions, log: (String) -> Void) throws -> String {
        if let path = ProcessInfo.processInfo.environment["REVIEWMAP_SCIP_JAVA"] {
            guard FileManager.default.fileExists(atPath: path) else {
                throw IndexError("REVIEWMAP_SCIP_JAVA (\(path)) must name the scip-java launcher jar for Bazel workspaces.")
            }
            return path
        }
        return try KotlinIndex.scipJavaLauncher(options: options, log: log)
    }

    static func readManifests(bin: String) throws -> [Target] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: bin) else { return [] }
        var out: [Target] = []
        while let rel = walker.nextObject() as? String {
            guard rel.hasSuffix(manifestSuffix) else { continue }
            out.append(try JSONDecoder().decode(Target.self, from: try Data(contentsOf: URL(fileURLWithPath: join(bin, rel)))))
        }
        return out.sorted { $0.label < $1.label }
    }

    /// The name the workspace gives rules_kotlin: a `repo_name` on its `bazel_dep`, else "rules_kotlin".
    static func rulesKotlinRepo(_ dir: String) -> String {
        guard let text = try? String(contentsOfFile: join(dir, "MODULE.bazel"), encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"bazel_dep\(\s*name\s*=\s*"rules_kotlin"[^)]*?repo_name\s*=\s*"([^"]+)""#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return "rules_kotlin" }
        return String(text[range])
    }

    /// The aspect. It follows dependency edges and passes the manifests up, so a target set like `//app:app` also
    /// indexes the libraries it uses. Only the workspace's own sources are listed, and a target's own jars stay off
    /// its classpath.
    static func aspect(rulesKotlin repo: String) -> String {
        """
        \"\"\"Written by Review Map: the Kotlin sources and compile classpath of each rules_kotlin target.\"\"\"

        load("@\(repo)//kotlin/internal:defs.bzl", "KtJvmInfo")

        _ATTRS = ["deps", "exports", "associates", "runtime_deps"]

        _Manifests = provider(fields = ["files"])

        def _main_repo(f):
            return not f.short_path.startswith("../")

        def _impl(target, ctx):
            # The dependencies' manifests and jars, so that building the top-level targets builds them all.
            transitive = []
            for attr in _ATTRS:
                for dep in getattr(ctx.rule.attr, attr, []) or []:
                    if type(dep) == "Target" and _Manifests in dep:
                        transitive.append(dep[_Manifests].files)
            srcs = []
            if KtJvmInfo in target:
                srcs = [f for f in target[KtJvmInfo].srcs if f.extension == "kt" and f.is_source and _main_repo(f)]
            if srcs:
                jars = target[KtJvmInfo].transitive_compile_time_jars
                classpath = [j for j in jars.to_list() if j.owner != target.label]
                manifest = ctx.actions.declare_file(target.label.name + "\(manifestSuffix)")
                ctx.actions.write(manifest, json.encode({
                    "label": str(target.label),
                    "sources": [f.path for f in srcs],
                    "classpath": [j.path for j in classpath],
                    "deps": sorted({str(j.owner): True for j in classpath if j.owner and _main_repo(j)}.keys()),
                }))
                transitive.append(depset([manifest], transitive = [jars]))
            files = depset(transitive = transitive)
            return [_Manifests(files = files), OutputGroupInfo(\(outputGroup) = files)]

        reviewmap_kotlin = aspect(
            implementation = _impl,
            attr_aspects = _ATTRS,
        )

        """
    }

    /// Symbols without Maven coordinates ("scip-java maven . . demo/start().") are the same in every target that
    /// declares them, and rules_kotlin jars carry no coordinates, so a symbol that two targets declare (`main()` in
    /// two binaries, say) would link one to the other. Only such symbols are scoped, to the target that declares
    /// them: in a declaring target's own files, to that target; elsewhere, to the declaring target it depends on.
    /// Every other symbol stays as it is, so references across targets still link.
    static func scopeDuplicateSymbols(_ index: inout SCIP.Index, targets: [Target]) {
        var owner: [String: Target] = [:]
        for t in targets {
            for f in t.sources where owner[f] == nil { owner[f] = t }
        }
        let prefix = KotlinIndex.unqualifiedPrefix
        var declaredBy: [String: Set<String>] = [:]
        for doc in index.documents {
            guard let t = owner[doc.path] else { continue }
            for o in doc.occurrences where o.isDefinition && o.symbol.hasPrefix(prefix) {
                declaredBy[o.symbol, default: []].insert(t.label)
            }
        }
        for d in index.documents.indices {
            guard let t = owner[index.documents[d].path] else { continue }
            for o in index.documents[d].occurrences.indices {
                let symbol = index.documents[d].occurrences[o].symbol
                guard let labels = declaredBy[symbol], labels.count > 1 else { continue }
                guard let scope = labels.contains(t.label) ? t.label : t.deps.first(where: labels.contains) else { continue }
                let package = "reviewmap:" + scope.replacingOccurrences(of: " ", with: "  ")
                index.documents[d].occurrences[o].symbol = "scip-java maven \(package) . " + symbol.dropFirst(prefix.count)
            }
        }
    }
}
