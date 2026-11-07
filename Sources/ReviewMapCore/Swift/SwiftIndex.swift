import Foundation
import IndexStoreDB

// Swift's index: each side's exported tree is built once (Bazel, xcodebuild, or swift build) with
// indexing on; the resulting store is cached per commit, so a base shared by several branches
// is built once. IndexStoreDB then gives, for every reference in a file, the declaration it
// points at, as the same `SideIndex` a SCIP index gives.

enum IndexBuilder {
    /// Loads (building if needed) the index of both sides. Throws when either side can't be indexed.
    static func load(options: IndexOptions, repoRoot: String, sides: [IndexSide], log: (String) -> Void) throws -> [Side: SideIndex] {
        let library = try IndexStoreLibrary(dylibPath: try libraryPath())
        let repoDir = (options.cacheDir as NSString).appendingPathComponent(Paths.slug((repoRoot as NSString).lastPathComponent))
        var out: [Side: SideIndex] = [:]
        for s in sides {
            let dir = (repoDir as NSString).appendingPathComponent(s.sha)
            let store = try buildIfNeeded(options: options, side: s.side, sha: s.sha, srcDir: s.dir, repoRoot: repoRoot, cache: dir, log: log)
            out[s.side] = try read(store: store, library: library, files: s.files, log: log, side: s.side)
        }
        return out
    }

    struct BuiltStore {
        var storePath: String
        var databasePath: String
        /// Directories index paths may start with: where the sources were built, and Bazel's execution root.
        /// Each line is a directory, optionally followed by a tab and the repo-relative directory it stands for.
        var sourceRoots: [String]
    }

    // MARK: Building

    static func buildIfNeeded(options: IndexOptions, side: Side, sha: String, srcDir: String, repoRoot: String, cache: String, log: (String) -> Void) throws -> BuiltStore {
        let fm = FileManager.default
        let storeDir = cache + "/store"
        let rootFile = cache + "/root.txt"
        // Reimport old stores: databases made before path remapping contain relative keys.
        let databasePath = cache + "/db-absolute-paths-v1"
        if !options.rebuild, fm.fileExists(atPath: storeDir), let roots = try? String(contentsOfFile: rootFile, encoding: .utf8) {
            log("Index for \(side.rawValue) \(sha.prefix(8)): cached.")
            return BuiltStore(storePath: storeDir, databasePath: databasePath,
                              sourceRoots: roots.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
        }
        try fm.createDirectory(atPath: cache, withIntermediateDirectories: true)
        let logPath = cache + "/build.log"
        let scratch = (NSTemporaryDirectory() as NSString).appendingPathComponent("reviewmap-build-\(UUID().uuidString)")
        defer { try? fm.removeItem(atPath: scratch) }
        let plan = try BuildPlan.make(options: options, srcDir: srcDir, repoRoot: repoRoot, scratch: scratch,
                                      packageCache: (options.cacheDir as NSString).appendingPathComponent(".packages"))
        log("Building \(side.rawValue) \(sha.prefix(8)) for the index (\(plan.summary)); this runs once per commit…")
        let start = Date()
        defer { plan.cleanup() }
        let status = try run(plan.command, cwd: plan.cwd, logPath: logPath)
        guard status == 0 else {
            throw IndexError("The \(side.rawValue) build failed (\(plan.summary)). Log: \(logPath)")
        }
        let located = try plan.locate()
        guard let built = located.store else {
            throw IndexError("The \(side.rawValue) build produced no index store (\(plan.summary)). Log: \(logPath)")
        }
        // Replace an earlier store (and its database) only once the new build succeeded.
        try? fm.removeItem(atPath: storeDir)
        try? fm.removeItem(atPath: databasePath)
        try fm.moveItem(atPath: built, toPath: storeDir)
        let roots = [srcDir] + located.extraRoots
        try roots.joined(separator: "\n").write(toFile: rootFile, atomically: true, encoding: .utf8)
        log("Built \(side.rawValue) in \(Int(Date().timeIntervalSince(start)))s.")
        return BuiltStore(storePath: storeDir, databasePath: databasePath, sourceRoots: roots)
    }

    struct BuildPlan {
        var command: [String]
        var cwd: String
        var summary: String
        /// After a successful build: the index store, and other directories its paths may start with.
        var locate: () throws -> (store: String?, extraRoots: [String])
        /// Runs after the build, whatever its outcome.
        var cleanup: () -> Void = {}

        init(command: [String], cwd: String, storeSearchRoot: String, summary: String) {
            self.command = command
            self.cwd = cwd
            self.summary = summary
            self.locate = { (IndexBuilder.findStore(storeSearchRoot), []) }
        }

        init(command: [String], cwd: String, summary: String, locate: @escaping () throws -> (store: String?, extraRoots: [String]),
             cleanup: @escaping () -> Void) {
            self.command = command
            self.cwd = cwd
            self.summary = summary
            self.locate = locate
            self.cleanup = cleanup
        }

        static func make(options: IndexOptions, srcDir: String, repoRoot: String, scratch: String, packageCache: String) throws -> BuildPlan {
            let fm = FileManager.default
            let cwdRel = options.workingDirectory.flatMap { repoRelative($0, repoRoot: repoRoot) }
            let workspace = try bazelWorkspace(srcDir, under: cwdRel, withTargets: options.targets == nil)
            if options.builder == "bazel" || (options.builder == nil && workspace != nil && (options.targets != nil || !xcodeprojTargets(srcDir, workspace: workspace!).isEmpty)) {
                guard let workspace else {
                    throw IndexError("There is no Bazel workspace (MODULE.bazel or WORKSPACE) in the repo for the bazel builder.")
                }
                return try bazel(options: options, srcDir: srcDir, workspace: workspace, scratch: scratch, cacheDir: options.cacheDir)
            }
            let hasXcodebuild = (try? Shell.string(["which", "xcodebuild"])).map { !$0.isEmpty } ?? false
            let builder = options.builder ?? (hasXcodebuild ? "xcodebuild" : "swift")
            let project = try options.project.map { try resolveProject($0, srcDir: srcDir, repoRoot: repoRoot, workingDirectory: options.workingDirectory) }
                ?? findProject(srcDir, builder: builder, under: cwdRel)
            let projectPath = project == "." ? srcDir : (srcDir as NSString).appendingPathComponent(project)
            guard fm.fileExists(atPath: projectPath) else {
                throw IndexError("\(project) does not exist in the repo at this commit.")
            }
            switch builder {
            case "swift":
                let pkg = projectPath.hasSuffix("Package.swift") ? (projectPath as NSString).deletingLastPathComponent : projectPath
                guard fm.fileExists(atPath: pkg + "/Package.swift") else {
                    throw IndexError("swift build needs a package; \(project) has no Package.swift. Pass --index-project.")
                }
                return BuildPlan(command: ["swift", "build", "--package-path", pkg, "--scratch-path", scratch, "--enable-index-store"],
                                 cwd: pkg, storeSearchRoot: scratch, summary: "swift build \(project)")
            case "xcodebuild":
                var cmd = ["xcodebuild", "build"]
                var cwd = srcDir
                var listArgs: [String] = []
                if projectPath.hasSuffix(".xcworkspace") {
                    listArgs = ["-workspace", projectPath]
                } else if projectPath.hasSuffix(".xcodeproj") {
                    listArgs = ["-project", projectPath]
                } else {
                    cwd = projectPath.hasSuffix("Package.swift") ? (projectPath as NSString).deletingLastPathComponent : projectPath
                }
                let scheme = try options.scheme ?? pickScheme(listArgs: listArgs, cwd: cwd, project: project)
                let destination = options.destination ?? "generic/platform=iOS Simulator"
                cmd += listArgs + ["-scheme", scheme, "-destination", destination, "-derivedDataPath", scratch,
                                   "-clonedSourcePackagesDirPath", packageCache, "-skipPackagePluginValidation", "-skipMacroValidation",
                                   "CODE_SIGNING_ALLOWED=NO", "COMPILER_INDEX_STORE_ENABLE=YES"]
                return BuildPlan(command: cmd, cwd: cwd, storeSearchRoot: scratch + "/Index.noindex",
                                 summary: "xcodebuild \(project), scheme \(scheme)")
            default:
                throw IndexError("Unknown index builder \(builder). Use bazel, xcodebuild, or swift.")
            }
        }

        // MARK: Bazel

        static let bazelWorkspaceFiles = ["MODULE.bazel", "WORKSPACE", "WORKSPACE.bazel"]

        /// The Bazel workspace to build, repo-relative ("." for the root), or nil: the nearest directory with
        /// MODULE.bazel or WORKSPACE from the directory the command ran in up to the repo root, or else the
        /// one workspace below it (with `withTargets`, one whose rules_xcodeproj rule names targets).
        static func bazelWorkspace(_ root: String, under cwdRel: String?, withTargets: Bool = false) throws -> String? {
            let fm = FileManager.default
            var dir = cwdRel ?? ""
            while true {
                let abs = dir.isEmpty ? root : root + "/" + dir
                if bazelWorkspaceFiles.contains(where: { fm.fileExists(atPath: abs + "/" + $0) }) {
                    return dir.isEmpty ? "." : dir
                }
                if dir.isEmpty { break }
                dir = (dir as NSString).deletingLastPathComponent
            }
            // In a monorepo the workspace may sit in a subdirectory, such as ios/.
            var found: [String] = []
            ComponentBuilder.walk(root: root, rel: cwdRel ?? "") { rel, name, isDir in
                if !isDir && bazelWorkspaceFiles.contains(name) {
                    let ws = (rel as NSString).deletingLastPathComponent
                    if !found.contains(ws) { found.append(ws) }
                }
                return !name.hasPrefix("bazel-")
            }
            if withTargets { found = found.filter { !xcodeprojTargets(root, workspace: $0).isEmpty } }
            if found.count > 1 {
                throw IndexError("The repo has several Bazel workspaces (\(found.joined(separator: ", "))). Run reviewmap from the one to index, or pass --index-builder.")
            }
            return found.first
        }

        /// `top_level_targets` of the rules_xcodeproj `xcodeproj` rules in the workspace's root BUILD file, as labels.
        static func xcodeprojTargets(_ root: String, workspace: String) -> [String] {
            let dir = workspace == "." ? root : root + "/" + workspace
            for name in ["BUILD.bazel", "BUILD"] {
                if let text = try? String(contentsOfFile: dir + "/" + name, encoding: .utf8) {
                    return xcodeprojTargets(buildFile: text)
                }
            }
            return []
        }

        static func xcodeprojTargets(buildFile text: String) -> [String] {
            var labels: [String] = []
            var rest = Substring(text)
            while let r = rest.range(of: "top_level_targets") {
                rest = rest[r.upperBound...]
                guard let open = rest.firstIndex(of: "[") else { break }
                // Only an assignment: `top_level_targets = [`.
                guard rest[rest.startIndex..<open].allSatisfy({ $0 == " " || $0 == "=" || $0 == "\n" || $0 == "\t" }) else { continue }
                var depth = 0
                var end = open
                for i in rest[open...].indices {
                    if rest[i] == "[" { depth += 1 } else if rest[i] == "]" { depth -= 1; if depth == 0 { end = i; break } }
                }
                let list = rest[open...end]
                var i = list.startIndex
                while let q = list[i...].firstIndex(of: "\"") {
                    guard let close = list[list.index(after: q)...].firstIndex(of: "\"") else { break }
                    let s = String(list[list.index(after: q)..<close])
                    if s.hasPrefix("//") || s.hasPrefix("@") { labels.append(s) } else if s.hasPrefix(":") { labels.append("/" + "/" + s) }
                    i = list.index(after: close)
                }
                rest = rest[end...]
            }
            var seen = Set<String>()
            return labels.filter { seen.insert($0).inserted }
        }

        /// Build with indexing in a temporary output base, sharing downloads and action results.
        /// Request index artifacts explicitly: cache hits do not recreate the global-store side
        /// effect, and Bazel's default download policy omits non-default and transitive outputs.
        static func bazel(options: IndexOptions, srcDir: String, workspace: String, scratch: String, cacheDir: String) throws -> BuildPlan {
            let dir = workspace == "." ? srcDir : srcDir + "/" + workspace
            let targets = options.targets ?? xcodeprojTargets(srcDir, workspace: workspace)
            guard !targets.isEmpty else {
                throw IndexError("No Bazel targets to build. Set index.targets in reviewmap.yml or pass --index-target //path:target.")
            }
            let hasBazel = (try? Shell.string(["which", "bazel"])).map { !$0.isEmpty } ?? false
            let exe = hasBazel ? "bazel" : "bazelisk"
            let startup = [exe, "--output_base=\(scratch)/output_base", "--max_idle_secs=300"]
            let cmd = startup + ["build", "--features=swift.index_while_building", "--features=swift.use_global_index_store",
                                 "--output_groups=+swift_index_store", "--remote_download_regex=.*[.]indexstore(/.*)?",
                                 "--disk_cache=\((cacheDir as NSString).appendingPathComponent(".bazel-disk-cache"))"]
                + (options.bazelArgs ?? []) + ["--"] + targets
            let locate = { () throws -> (store: String?, extraRoots: [String]) in
                let info = String(decoding: try Shell.run(startup + ["info", "output_path", "execution_root"], cwd: dir), as: UTF8.self)
                var values: [String: String] = [:]
                for line in info.split(separator: "\n") {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    values[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                guard let out = values["output_path"] else { return (nil, []) }
                // The execution root mirrors the Bazel workspace, which may be a subdirectory of the repo.
                let roots = values["execution_root"].map { ["\($0)\t\(workspace == "." ? "" : workspace)"] } ?? []
                if let global = IndexBuilder.findStore(out + "/_global_index_store") { return (global, roots) }
                return (IndexBuilder.mergeStores(under: out, into: scratch + "/merged-store"), roots)
            }
            let cleanup = { _ = try? Shell.run(startup + ["clean", "--expunge"], cwd: dir) }
            let summary = "\(exe) build \(targets.joined(separator: " "))\(workspace == "." ? "" : " in \(workspace)")"
            return BuildPlan(command: cmd, cwd: dir, summary: summary, locate: locate, cleanup: cleanup)
        }

        /// `path` relative to the repo root, when it is inside the repo (symlinks resolved).
        static func repoRelative(_ path: String, repoRoot: String) -> String? {
            let real = { (p: String) in URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path }
            let p = real(path), root = real(repoRoot)
            if p == root { return "" }
            return p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : nil
        }

        /// A user-given project path as a repo-relative path that exists in the exported tree. It may be
        /// relative to the directory the command ran in, relative to the repo root, or absolute.
        static func resolveProject(_ given: String, srcDir: String, repoRoot: String, workingDirectory: String?) throws -> String {
            var p = (given as NSString).expandingTildeInPath
            while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
            var tried: [String] = []
            func accept(_ rel: String) -> String? {
                let r = rel.isEmpty ? "." : rel
                if !tried.contains(r) { tried.append(r) }
                return FileManager.default.fileExists(atPath: r == "." ? srcDir : srcDir + "/" + r) ? r : nil
            }
            if p.hasPrefix("/") {
                if let rel = repoRelative(p, repoRoot: repoRoot), let hit = accept(rel) { return hit }
            } else {
                if let wd = workingDirectory, let rel = repoRelative((wd as NSString).appendingPathComponent(p), repoRoot: repoRoot),
                   let hit = accept(rel) { return hit }
                let rel = URL(fileURLWithPath: p, relativeTo: URL(fileURLWithPath: "/")).standardizedFileURL.path.dropFirst()
                if let hit = accept(String(rel)) { return hit }
            }
            // On disk but not in the commit: generated (rules_xcodeproj, XcodeGen, Tuist) or ignored.
            if let rel = tried.first(where: { FileManager.default.fileExists(atPath: $0 == "." ? repoRoot : repoRoot + "/" + $0) }) {
                throw IndexError("\(rel) is in your working copy but not tracked by git, so it isn't in the commits being built (is it generated?). "
                    + "For a rules_xcodeproj project, build with Bazel: --index-builder bazel, with the targets from --index-target or index.targets in reviewmap.yml.")
            }
            throw IndexError("--index-project \(given) is not in the repo at this commit (looked for \(tried.isEmpty ? p : tried.joined(separator: ", ")) "
                + "from the repo root). Give the path relative to the repo root or to the current directory.")
        }

        /// The workspace, project, or package to build when none is given. Workspaces win over projects, and
        /// projects over packages. Anywhere in the repo counts (Pods, build folders, and the like are skipped);
        /// when there are several, the ones under the directory the command ran in are preferred.
        static func findProject(_ root: String, builder: String, under cwdRel: String? = nil) throws -> String {
            let scope = (cwdRel ?? "").isEmpty ? nil : cwdRel!
            func narrow(_ found: [String]) -> [String] {
                guard let scope else { return found }
                let inside = found.filter { $0 == scope || $0.hasPrefix(scope + "/") }
                return inside.isEmpty ? found : inside
            }
            let fm = FileManager.default
            let packageDirs = [scope, "."].compactMap { $0 }.filter { fm.fileExists(atPath: ($0 == "." ? root : root + "/" + $0) + "/Package.swift") }
            if builder == "swift" {
                if let dir = packageDirs.first { return dir }
                throw IndexError("There is no Package.swift at the repo root or in the current directory for swift build. Pass --index-project <package dir>.")
            }
            for suffix in [".xcworkspace", ".xcodeproj"] {
                let found = narrow(ComponentBuilder.findDirs(root: root, suffix: suffix))
                if found.count == 1 { return found[0] }
                if found.count > 1 {
                    throw IndexError("The repo has \(found.joined(separator: ", ")). Pass --index-project to pick one, or run from the directory that holds it.")
                }
            }
            if let dir = packageDirs.first { return dir }
            throw IndexError("No .xcworkspace, .xcodeproj, or Package.swift found in the repo. Pass --index-project.")
        }

        /// The only scheme, or the one named after the project, or a package's "-Package" scheme.
        static func pickScheme(listArgs: [String], cwd: String, project: String) throws -> String {
            let data = try Shell.run(["xcodebuild", "-list", "-json"] + listArgs, cwd: cwd)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let container = (obj?["workspace"] ?? obj?["project"]) as? [String: Any]
            let schemes = container?["schemes"] as? [String] ?? []
            let name = ((project == "." ? cwd : project) as NSString).lastPathComponent
                .replacingOccurrences(of: ".xcworkspace", with: "").replacingOccurrences(of: ".xcodeproj", with: "")
            if schemes.count == 1 { return schemes[0] }
            if let s = schemes.first(where: { $0 == name }) ?? schemes.first(where: { $0 == "\(name)-Package" }) { return s }
            throw IndexError("Pick a scheme with --index-scheme: \(schemes.joined(separator: ", ")).")
        }
    }

    /// The index store a build wrote: `root` itself, or a "DataStore" directory (Xcode) or "index/store" (SwiftPM) under it.
    static func findStore(_ root: String) -> String? {
        let fm = FileManager.default
        if fm.fileExists(atPath: root + "/v5") || fm.fileExists(atPath: root + "/v6") { return root }
        guard let e = fm.enumerator(atPath: root) else { return nil }
        while let rel = e.nextObject() as? String {
            if rel.hasSuffix("DataStore") || rel.hasSuffix("index/store") {
                let path = root + "/" + rel
                if FileManager.default.fileExists(atPath: path + "/v5") || FileManager.default.fileExists(atPath: path + "/v6") {
                    return path
                }
            }
        }
        return nil
    }

    /// Per-target `.indexstore` directories (rules_swift without a global store) copied into one store.
    /// Unit and record file names are content hashes, so stores merge by copying.
    static func mergeStores(under root: String, into dest: String) -> String? {
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: root) else { return nil }
        var stores: [String] = []
        while let rel = e.nextObject() as? String {
            if rel.hasSuffix(".indexstore") {
                stores.append(root + "/" + rel)
                e.skipDescendants()
            }
        }
        var merged = false
        for store in stores {
            for version in ["v5", "v6"] {
                let src = store + "/" + version
                guard let files = fm.enumerator(atPath: src) else { continue }
                while let rel = files.nextObject() as? String {
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: src + "/" + rel, isDirectory: &isDir), !isDir.boolValue else { continue }
                    let target = dest + "/" + version + "/" + rel
                    if fm.fileExists(atPath: target) { continue }
                    try? fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    if (try? fm.copyItem(atPath: src + "/" + rel, toPath: target)) != nil { merged = true }
                }
            }
        }
        return merged ? dest : nil
    }

    static func run(_ args: [String], cwd: String, logPath: String) throws -> Int32 {
        try Shell.runLogged(args, cwd: cwd, logPath: logPath)
    }

    /// libIndexStore from the toolchain that builds: $REVIEWMAP_LIBINDEXSTORE, or next to `swift`.
    static func libraryPath() throws -> String {
        if let env = ProcessInfo.processInfo.environment["REVIEWMAP_LIBINDEXSTORE"], !env.isEmpty { return env }
        var swiftPaths: [String] = []
        if let p = try? Shell.string(["xcrun", "--find", "swift"]), !p.isEmpty { swiftPaths.append(p) }
        if let p = try? Shell.string(["which", "swift"]), !p.isEmpty { swiftPaths.append(p) }
        for p in swiftPaths {
            let lib = (URL(fileURLWithPath: p).resolvingSymlinksInPath().deletingLastPathComponent()
                .deletingLastPathComponent().path as NSString).appendingPathComponent("lib")
            for name in ["libIndexStore.dylib", "libIndexStore.so"] where FileManager.default.fileExists(atPath: lib + "/" + name) {
                return lib + "/" + name
            }
        }
        throw IndexError("Can't find libIndexStore next to the swift toolchain. Set REVIEWMAP_LIBINDEXSTORE to its path.")
    }

    // MARK: Reading

    static func read(store: BuiltStore, library: IndexStoreLibrary, files: [String], log: (String) -> Void, side: Side) throws -> SideIndex {
        // rules_swift maps the execution root to "." in both the unit working directory and
        // source paths. Expand that prefix while importing, before IndexStoreDB canonicalizes
        // paths; querying a relative filename is invalid even when a unit recorded one.
        let workspaceRoot = store.sourceRoots.last { $0.contains("\t") }
            .map { String($0.split(separator: "\t", omittingEmptySubsequences: false)[0]) }
        let mappings = workspaceRoot.map { [PathMapping(original: ".", replacement: $0)] } ?? []
        let db = try IndexStoreDB(storePath: store.storePath, databasePath: store.databasePath, library: library,
                                  waitUntilDoneInitializing: true, listenToUnitEvents: true, prefixMappings: mappings)
        let roots = expandRoots(store.sourceRoots)
        let known = Set(files)
        func relative(_ path: String) -> String? { relativePath(path, roots: roots, known: known) }
        var definitions: [String: (file: String, line: Int)?] = [:]
        func definition(of usr: String) -> (file: String, line: Int)? {
            if let hit = definitions[usr] { return hit }
            let occ = db.occurrences(ofUSR: usr, roles: [.definition]).first ?? db.occurrences(ofUSR: usr, roles: [.declaration]).first
            let found = occ.flatMap { o in relative(o.location.path).map { ($0, o.location.line) } }
            definitions[usr] = found
            return found
        }
        var refs: [String: [IndexedRef]] = [:]
        for file in files {
            var occurrences: [SymbolOccurrence] = []
            for path in storedPaths(file, roots: roots) {
                occurrences = db.symbolOccurrences(inFilePath: path)
                if !occurrences.isEmpty { break }
            }
            if occurrences.isEmpty { continue }
            var out = Set<IndexedRef>()
            for o in occurrences where o.roles.contains(.reference) && !o.roles.contains(.implicit) {
                guard let def = definition(of: o.symbol.usr) else { continue }
                out.insert(IndexedRef(line: o.location.line, targetFile: def.file, targetLine: def.line, name: o.symbol.name))
            }
            refs[file] = out.sorted { ($0.line, $0.targetFile, $0.targetLine) < ($1.line, $1.targetFile, $1.targetLine) }
        }
        return SideIndex(refs: refs)
    }

    /// A build root and the repo-relative directory it stands for ("" for the repo root).
    struct Root: Hashable {
        var path: String
        var prefix: String
    }

    /// The build roots, also with symlinks resolved and with and without /private (macOS), longest first.
    static func expandRoots(_ sourceRoots: [String]) -> [Root] {
        var roots = Set<Root>()
        for line in sourceRoots {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let root = parts[0], prefix = parts.count > 1 ? parts[1] : ""
            let real = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
            for r in [root, real] {
                roots.insert(Root(path: r, prefix: prefix))
                roots.insert(Root(path: r.hasPrefix("/private/") ? String(r.dropFirst("/private".count)) : "/private" + r, prefix: prefix))
            }
        }
        return roots.sorted { ($0.path.count, $0.path) > ($1.path.count, $1.path) }
    }

    /// A path from the index as a repo-relative path. Absolute paths start with a build root; Bazel may also
    /// record paths relative to its execution root ("Sources/App.swift" or "./Sources/App.swift").
    static func relativePath(_ path: String, roots: [Root], known: Set<String>) -> String? {
        for r in roots where path.hasPrefix(r.path + "/") { return join(r.prefix, String(path.dropFirst(r.path.count + 1))) }
        if path.hasPrefix("/") { return nil }
        let rel = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
        for prefix in Set(roots.map(\.prefix)).sorted(by: { $0.count > $1.count }) where known.contains(join(prefix, rel)) {
            return join(prefix, rel)
        }
        return nil
    }

    /// Absolute query paths for a repo-relative file. IndexStoreDB cannot query relative paths.
    static func storedPaths(_ file: String, roots: [Root]) -> [String] {
        var out: [String] = []
        for r in roots {
            if r.prefix.isEmpty {
                out.append(r.path + "/" + file)
            } else if file.hasPrefix(r.prefix + "/") {
                let inner = String(file.dropFirst(r.prefix.count + 1))
                out.append(r.path + "/" + inner)
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }
}
