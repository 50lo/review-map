import Foundation

// Go's index: each module of a side's exported tree gets its dependencies downloaded, then scip-go type-checks
// it and writes a SCIP index. Nothing is built. The indexes are cached per commit next to the other languages',
// in `<cache>/<repo>/<sha>/go/`, one per module.

enum GoIndex {
    /// The scip-go release installed when none is on the PATH. `REVIEWMAP_SCIP_GO` names another command.
    static let scipGoModule = "github.com/scip-code/scip-go/cmd/scip-go@v0.2.9"

    static func load(options: IndexOptions, repoRoot: String, sides: [IndexSide], log: (String) -> Void) throws -> [Side: SideIndex] {
        let repoDir = (options.cacheDir as NSString).appendingPathComponent(Paths.slug((repoRoot as NSString).lastPathComponent))
        var out: [Side: SideIndex] = [:]
        for s in sides {
            // A side without Go has nothing to index.
            if s.files.isEmpty {
                out[s.side] = SideIndex(refs: [:])
                continue
            }
            let cache = (repoDir as NSString).appendingPathComponent("\(s.sha)/go")
            var indexes: [SCIP.Index] = []
            var notes: [String] = []
            for module in GoComponents.modules(root: s.dir).map(\.dir).sorted() {
                let indexPath = cache + "/\(Paths.slug(module.isEmpty ? "root" : module)).scip"
                let notesPath = indexPath + ".notes.txt"
                if options.rebuild || !FileManager.default.fileExists(atPath: indexPath) {
                    try build(side: s, module: module, indexPath: indexPath, options: options, log: log)
                } else {
                    log("Go index for \(s.side.rawValue) \(s.sha.prefix(8))\(module.isEmpty ? "" : " \(module)"): cached.")
                }
                var index = try SCIP.decode(try Data(contentsOf: URL(fileURLWithPath: indexPath)))
                // The cached index was written in another export of the tree; its paths are relative to the module.
                index.projectRoot = URL(fileURLWithPath: join(s.dir, module)).absoluteString
                indexes.append(index)
                if let n = try? String(contentsOfFile: notesPath, encoding: .utf8), !n.isEmpty { notes.append(n) }
            }
            guard !indexes.isEmpty else { throw IndexError("Go indexing needs a go.mod at \(s.side.rawValue).") }
            var side = SCIP.sideIndex(indexes, sourceRoot: s.dir, known: Set(s.files))
            if !notes.isEmpty {
                side.warnings.append(Warning(kind: "index-partial", message: "Go at \(s.side.rawValue): \(notes.joined(separator: " "))"))
            }
            out[s.side] = side
        }
        return out
    }

    private static func build(side s: IndexSide, module: String, indexPath: String, options: IndexOptions, log: (String) -> Void) throws {
        let fm = FileManager.default
        guard Shell.exists("go") else {
            throw IndexError("Go indexing needs the Go toolchain (go on the PATH).")
        }
        let cache = (indexPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: cache, withIntermediateDirectories: true)
        let logPath = indexPath + ".log"
        _ = fm.createFile(atPath: logPath, contents: nil)
        let dir = join(s.dir, module)
        let at = module.isEmpty ? "" : " in \(module)"
        let start = Date()

        log("Downloading \(s.side.rawValue) \(s.sha.prefix(8)) Go modules\(at) for the index…")
        var notes = ""
        if try Shell.runLogged(["go", "mod", "download"], cwd: dir, logPath: logPath, append: true) != 0 {
            // Local references don't need third-party types, so indexing goes on without them.
            notes = "modules\(at) could not be downloaded, so references through third-party types may be missing. Log: \(logPath)"
        }

        let tool = try scipGo(options: options, log: log)
        let output = indexPath + ".tmp"
        try? fm.removeItem(atPath: output)
        log("Indexing \(s.side.rawValue) \(s.sha.prefix(8))\(at) with scip-go…")
        let status = try Shell.runLogged(tool + ["index", "--quiet", "--output", output, "./..."], cwd: dir, logPath: logPath, append: true)
        guard status == 0, fm.fileExists(atPath: output) else {
            throw IndexError("scip-go failed at \(s.side.rawValue)\(at). Log: \(logPath)")
        }
        try? fm.removeItem(atPath: indexPath)
        try fm.moveItem(atPath: output, toPath: indexPath)
        try notes.write(toFile: indexPath + ".notes.txt", atomically: true, encoding: .utf8)
        log("Indexed \(s.side.rawValue)\(at) in \(Int(Date().timeIntervalSince(start)))s.")
    }

    /// scip-go from `REVIEWMAP_SCIP_GO`, the PATH, or the cache, where it is installed the first time.
    private static func scipGo(options: IndexOptions, log: (String) -> Void) throws -> [String] {
        if let command = ProcessInfo.processInfo.environment["REVIEWMAP_SCIP_GO"] {
            return command.split(separator: " ").map(String.init)
        }
        if Shell.exists("scip-go") { return ["scip-go"] }
        let version = String(scipGoModule.split(separator: "@").last ?? "")
        let bin = (options.cacheDir as NSString).appendingPathComponent("tools/scip-go-\(version)")
        let path = bin + "/scip-go"
        if !FileManager.default.isExecutableFile(atPath: path) {
            try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
            log("Installing scip-go \(version)…")
            let logPath = bin + "/install.log"
            let status = try Shell.runLogged(["go", "install", scipGoModule], cwd: bin, logPath: logPath,
                                             environment: ["GOBIN": bin])
            guard status == 0 else { throw IndexError("Could not install scip-go. Log: \(logPath)") }
        }
        return [path]
    }
}
