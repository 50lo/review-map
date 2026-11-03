import Foundation
import IndexStoreDB

// Index mode: exact references from the compiler's index store instead of name matching.
// Each side's exported tree is built once (xcodebuild on macOS, swift build elsewhere) with
// indexing on; the resulting store is cached per commit, so a base shared by several branches
// is built once. IndexStoreDB then gives, for every reference in a file, the declaration it
// points at. If either build fails, both sides fall back to name matching, so the two sides
// are always resolved the same way.

public struct IndexOptions: Equatable {
    /// Nil follows `index.enabled` in reviewmap.yml.
    public var enabled: Bool?
    /// "xcodebuild" or "swift". Nil picks xcodebuild where it exists (macOS), swift build elsewhere.
    public var builder: String?
    /// The .xcworkspace, .xcodeproj, or package directory to build: relative to the repo root, relative to
    /// `workingDirectory`, or absolute inside the repo.
    public var project: String?
    public var scheme: String?
    /// xcodebuild destination (default "generic/platform=iOS Simulator").
    public var destination: String?
    /// Where built index stores are kept, one per repo and commit.
    public var cacheDir: String
    /// Build again even when a store for the commit is cached.
    public var rebuild: Bool
    /// Where the command was run. A relative --index-project may be relative to it, and auto-detection
    /// prefers projects under it.
    public var workingDirectory: String?

    public init(enabled: Bool? = nil, builder: String? = nil, project: String? = nil, scheme: String? = nil,
                destination: String? = nil, cacheDir: String = IndexOptions.defaultCacheDir, rebuild: Bool = false,
                workingDirectory: String? = nil) {
        self.enabled = enabled
        self.builder = builder
        self.project = project
        self.scheme = scheme
        self.destination = destination
        self.cacheDir = cacheDir
        self.rebuild = rebuild
        self.workingDirectory = workingDirectory
    }

    public static var defaultCacheDir: String {
        (AnnotateOptions.home as NSString).appendingPathComponent(".reviewmap/index")
    }

    /// CLI values win over reviewmap.yml.
    func merged(with config: Config.Index?) -> IndexOptions {
        guard let c = config else { return self }
        var o = self
        o.enabled = o.enabled ?? c.enabled
        o.builder = o.builder ?? c.builder
        o.project = o.project ?? c.project
        o.scheme = o.scheme ?? c.scheme
        o.destination = o.destination ?? c.destination
        return o
    }
}

/// A reference from one line of a file to a declaration in the repo, at one side.
struct IndexedRef: Hashable {
    var line: Int
    /// Repo-relative file and line of the referenced declaration's name.
    var targetFile: String
    var targetLine: Int
    /// The index's name for the symbol ("load()", "Config", "id").
    var name: String
}

/// Exact references for the Swift files of one side. Files missing from `refs` had no index data.
struct SideIndex {
    var refs: [String: [IndexedRef]]
}

struct IndexError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

enum IndexBuilder {
    /// Loads (building if needed) the index of both sides. Throws when either side can't be indexed.
    static func load(options: IndexOptions, repoRoot: String, sides: [(side: Side, sha: String, dir: String, files: [String])],
                     log: (String) -> Void) throws -> [Side: SideIndex] {
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
        /// The directory the sources were built in; index paths start with it.
        var sourceRoot: String
    }

    // MARK: Building

    static func buildIfNeeded(options: IndexOptions, side: Side, sha: String, srcDir: String, repoRoot: String, cache: String, log: (String) -> Void) throws -> BuiltStore {
        let fm = FileManager.default
        let storeDir = cache + "/store"
        let rootFile = cache + "/root.txt"
        if !options.rebuild, fm.fileExists(atPath: storeDir), let root = try? String(contentsOfFile: rootFile, encoding: .utf8) {
            log("Index for \(side.rawValue) \(sha.prefix(8)): cached.")
            return BuiltStore(storePath: storeDir, databasePath: cache + "/db", sourceRoot: root)
        }
        try fm.createDirectory(atPath: cache, withIntermediateDirectories: true)
        let logPath = cache + "/build.log"
        let scratch = (NSTemporaryDirectory() as NSString).appendingPathComponent("reviewmap-build-\(UUID().uuidString)")
        defer { try? fm.removeItem(atPath: scratch) }
        let plan = try BuildPlan.make(options: options, srcDir: srcDir, repoRoot: repoRoot, scratch: scratch,
                                      packageCache: (options.cacheDir as NSString).appendingPathComponent(".packages"))
        log("Building \(side.rawValue) \(sha.prefix(8)) for the index (\(plan.summary)); this runs once per commit…")
        let start = Date()
        let status = try run(plan.command, cwd: plan.cwd, logPath: logPath)
        guard status == 0 else {
            throw IndexError("The \(side.rawValue) build failed (\(plan.summary)). Log: \(logPath)")
        }
        guard let built = findStore(plan.storeSearchRoot) else {
            throw IndexError("The \(side.rawValue) build produced no index store under \(plan.storeSearchRoot). Log: \(logPath)")
        }
        // Replace an earlier store (and its database) only once the new build succeeded.
        try? fm.removeItem(atPath: storeDir)
        try? fm.removeItem(atPath: cache + "/db")
        try fm.moveItem(atPath: built, toPath: storeDir)
        try srcDir.write(toFile: rootFile, atomically: true, encoding: .utf8)
        log("Built \(side.rawValue) in \(Int(Date().timeIntervalSince(start)))s.")
        return BuiltStore(storePath: storeDir, databasePath: cache + "/db", sourceRoot: srcDir)
    }

    struct BuildPlan {
        var command: [String]
        var cwd: String
        var storeSearchRoot: String
        var summary: String

        static func make(options: IndexOptions, srcDir: String, repoRoot: String, scratch: String, packageCache: String) throws -> BuildPlan {
            let fm = FileManager.default
            let hasXcodebuild = (try? Shell.string(["which", "xcodebuild"])).map { !$0.isEmpty } ?? false
            let builder = options.builder ?? (hasXcodebuild ? "xcodebuild" : "swift")
            let cwdRel = options.workingDirectory.flatMap { repoRelative($0, repoRoot: repoRoot) }
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
                throw IndexError("Unknown index builder \(builder). Use xcodebuild or swift.")
            }
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

    /// The index store a build wrote: a "DataStore" directory (Xcode) or "index/store" (SwiftPM).
    static func findStore(_ root: String) -> String? {
        guard let e = FileManager.default.enumerator(atPath: root) else { return nil }
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

    static func run(_ args: [String], cwd: String, logPath: String) throws -> Int32 {
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let logHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        defer { try? logHandle.close() }
        logHandle.write(Data(("$ " + args.joined(separator: " ") + "\n\n").utf8))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.standardOutput = logHandle
        p.standardError = logHandle
        p.standardInput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
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
        let db = try IndexStoreDB(storePath: store.storePath, databasePath: store.databasePath, library: library,
                                  waitUntilDoneInitializing: true, listenToUnitEvents: true)
        // Index paths start with the directory that was built; on macOS it may appear with or without /private.
        let real = URL(fileURLWithPath: store.sourceRoot).resolvingSymlinksInPath().path
        var roots = [store.sourceRoot, real]
        for r in [store.sourceRoot, real] {
            if r.hasPrefix("/private/") { roots.append(String(r.dropFirst("/private".count))) } else { roots.append("/private" + r) }
        }
        roots = Array(Set(roots)).sorted { $0.count > $1.count }
        func relative(_ path: String) -> String? {
            for r in roots where path.hasPrefix(r + "/") { return String(path.dropFirst(r.count + 1)) }
            return nil
        }
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
            for r in roots {
                occurrences = db.symbolOccurrences(inFilePath: r + "/" + file)
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
}

/// Small path helpers shared by the analyzer and the CLI.
public enum Paths {
    /// "feature/login" → "feature-login"; anything outside letters, digits, dot, dash, and underscore becomes a dash.
    public static func slug(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let out = String(s.map { allowed.contains($0) ? $0 : "-" })
        return out.isEmpty || out.allSatisfy({ $0 == "." }) ? "-" : out
    }
}
