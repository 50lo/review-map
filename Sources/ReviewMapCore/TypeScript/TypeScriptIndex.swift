import Foundation

// TypeScript's index: each side's exported tree gets its dependencies installed (without running their
// scripts), then scip-typescript type-checks it and writes a SCIP index. Nothing is compiled. The index is
// cached per commit next to Swift's, in `<cache>/<repo>/<sha>/typescript/`.

enum TypeScriptIndex {
    /// The scip-typescript release `npx` runs. `REVIEWMAP_SCIP_TYPESCRIPT` names another command.
    static let scipTypeScript = "@sourcegraph/scip-typescript@0.4.0"

    static func load(options: IndexOptions, repoRoot: String, sides: [IndexSide], log: (String) -> Void) throws -> [Side: SideIndex] {
        let repoDir = (options.cacheDir as NSString).appendingPathComponent(Paths.slug((repoRoot as NSString).lastPathComponent))
        var out: [Side: SideIndex] = [:]
        for s in sides {
            // A side without TypeScript (before the first file was added) has nothing to index.
            if s.files.isEmpty {
                out[s.side] = SideIndex(refs: [:])
                continue
            }
            let cache = (repoDir as NSString).appendingPathComponent("\(s.sha)/typescript")
            let indexPath = cache + "/index.scip"
            let notesPath = cache + "/notes.txt"
            if options.rebuild || !FileManager.default.fileExists(atPath: indexPath) {
                try build(side: s, cache: cache, log: log)
            } else {
                log("TypeScript index for \(s.side.rawValue) \(s.sha.prefix(8)): cached.")
            }
            let index = try SCIP.decode(try Data(contentsOf: URL(fileURLWithPath: indexPath)))
            // scip-typescript runs at the root of the exported tree, so its project root is that tree, wherever it was.
            let root = index.projectRoot.flatMap { URL(string: $0)?.path } ?? s.dir
            var side = SCIP.sideIndex([index], sourceRoot: root, known: Set(s.files))
            if let notes = try? String(contentsOfFile: notesPath, encoding: .utf8), !notes.isEmpty {
                side.warnings.append(Warning(kind: "index-partial", message: "TypeScript at \(s.side.rawValue): \(notes)"))
            }
            out[s.side] = side
        }
        return out
    }

    private static func build(side s: IndexSide, cache: String, log: (String) -> Void) throws {
        let fm = FileManager.default
        guard Shell.exists("node") else {
            throw IndexError("TypeScript indexing needs Node.js (node and npx on the PATH).")
        }
        try fm.createDirectory(atPath: cache, withIntermediateDirectories: true)
        let logPath = cache + "/build.log"
        _ = fm.createFile(atPath: logPath, contents: nil)
        var notes: [String] = []
        let start = Date()

        for dir in installDirs(s.dir) {
            guard let install = installCommand(join(s.dir, dir)) else { continue }
            let at = dir.isEmpty ? "" : " in \(dir)"
            log("Installing \(s.side.rawValue) \(s.sha.prefix(8)) dependencies\(at) for the TypeScript index (\(install.command.prefix(2).joined(separator: " ")))…")
            let status = try Shell.runLogged(install.command, cwd: join(s.dir, dir), logPath: logPath, append: true, environment: install.environment)
            if status != 0 {
                // Local references don't need third-party types, so indexing goes on without them.
                notes.append("dependencies\(at) could not be installed, so references through third-party types may be missing. Log: \(logPath)")
            }
        }

        let projects = projectDirs(s.dir)
        let tool = ProcessInfo.processInfo.environment["REVIEWMAP_SCIP_TYPESCRIPT"].map { $0.split(separator: " ").map(String.init) }
            ?? ["npx", "--yes", scipTypeScript]
        let output = cache + "/index.scip.tmp"
        try? fm.removeItem(atPath: output)
        let command = tool + ["index", "--output", output] + (projects.isEmpty ? ["--infer-tsconfig"] : projects)
        log("Indexing \(s.side.rawValue) \(s.sha.prefix(8)) with scip-typescript…")
        let status = try Shell.runLogged(command, cwd: s.dir, logPath: logPath, append: true)
        guard status == 0, fm.fileExists(atPath: output) else {
            throw IndexError("scip-typescript failed at \(s.side.rawValue). Log: \(logPath)")
        }
        let indexPath = cache + "/index.scip"
        try? fm.removeItem(atPath: indexPath)
        try fm.moveItem(atPath: output, toPath: indexPath)
        try notes.joined(separator: " ").write(toFile: cache + "/notes.txt", atomically: true, encoding: .utf8)
        log("Indexed \(s.side.rawValue) in \(Int(Date().timeIntervalSince(start)))s.")
    }

    /// The directories of the `tsconfig.json` files to index: the outermost ones, and the ones right under a
    /// project with `references` (a solution-style root).
    static func projectDirs(_ root: String) -> [String] {
        let dirs = ComponentBuilder.findFiles(root: root, where: { $0 == "tsconfig.json" })
            .map { ($0 as NSString).deletingLastPathComponent }
            .sorted { ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1) }
        var kept: [String] = []
        for dir in dirs {
            let nearest = kept.filter { $0.isEmpty || dir.hasPrefix($0 + "/") }.max { $0.count < $1.count }
            if nearest.map({ hasReferences(join(root, join($0, "tsconfig.json"))) }) ?? true {
                kept.append(dir)
            }
        }
        return kept.map { $0.isEmpty ? "." : $0 }.sorted()
    }

    private static func hasReferences(_ path: String) -> Bool {
        (TypeScriptComponents.readJSON(path)?["references"] as? [Any])?.isEmpty == false
    }

    static let lockfiles: Set<String> = ["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb"]

    /// Where to install: the outermost directories with a lockfile, or, when there is none, the outermost
    /// ones with a package.json. A workspace root installs its packages too.
    static func installDirs(_ root: String) -> [String] {
        func outermost(_ files: [String]) -> [String] {
            let dirs = Set(files.map { ($0 as NSString).deletingLastPathComponent }).sorted()
            return dirs.filter { d in !dirs.contains { $0 != d && ($0.isEmpty || d.hasPrefix($0 + "/")) } }
        }
        let locked = outermost(ComponentBuilder.findFiles(root: root, where: lockfiles.contains))
        return locked.isEmpty ? outermost(ComponentBuilder.findFiles(root: root, where: { $0 == "package.json" })) : locked
    }

    /// The package manager's install for the lockfile in `root`, with scripts off. Nil when there is no
    /// package.json.
    static func installCommand(_ root: String) -> (command: [String], environment: [String: String])? {
        let fm = FileManager.default
        guard let pkg = TypeScriptComponents.readJSON(join(root, "package.json")) else { return nil }
        let manager = (pkg["packageManager"] as? String).map { String($0.split(separator: "+").first ?? "") }
        func tool(_ name: String) -> [String] {
            if Shell.exists(name) { return [name] }
            if Shell.exists("corepack") { return ["corepack", name] }
            return ["npx", "--yes", manager?.hasPrefix(name + "@") == true ? manager! : name]
        }
        let has = { (name: String) in fm.fileExists(atPath: join(root, name)) }
        if has("bun.lock") || has("bun.lockb") {
            return (tool("bun") + ["install", "--frozen-lockfile", "--ignore-scripts"], [:])
        }
        if has("pnpm-lock.yaml") {
            return (tool("pnpm") + ["install", "--frozen-lockfile", "--ignore-scripts"], [:])
        }
        if has("yarn.lock") {
            let berry = has(".yarnrc.yml") || (manager.map { $0.hasPrefix("yarn@") && !$0.hasPrefix("yarn@1.") } ?? false)
            if berry {
                return (tool("yarn") + ["install", "--immutable"], ["YARN_ENABLE_SCRIPTS": "false"])
            }
            return (tool("yarn") + ["install", "--frozen-lockfile", "--ignore-scripts", "--non-interactive"], [:])
        }
        if has("package-lock.json") {
            return (["npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund"], [:])
        }
        return (["npm", "install", "--ignore-scripts", "--no-audit", "--no-fund", "--no-package-lock"], [:])
    }
}
