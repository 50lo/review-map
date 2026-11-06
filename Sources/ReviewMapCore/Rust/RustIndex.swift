import Foundation

/// Cargo workspaces are indexed in exported commit trees, never in the user's checkout.
enum RustIndex {
    static func load(options: IndexOptions, repoRoot: String, sides: [IndexSide], log: (String) -> Void) throws -> [Side: SideIndex] {
        let repoCache = join(options.cacheDir, Paths.slug((repoRoot as NSString).lastPathComponent))
        var result: [Side: SideIndex] = [:]
        for side in sides {
            if side.files.isEmpty {
                result[side.side] = SideIndex(refs: [:])
                continue
            }
            guard Shell.exists("cargo") else { throw IndexError("Rust indexing needs the Cargo toolchain (cargo on the PATH).") }
            let roots = try workspaceDirs(side.dir)
            guard !roots.isEmpty else { throw IndexError("Rust indexing needs a Cargo.toml at \(side.side.rawValue).") }
            var indexes: [SCIP.Index] = []
            var notes: [String] = []
            for root in roots {
                let cache = join(repoCache, "\(side.sha)/rust/workspaces/\(root.isEmpty ? "root" : "nested/" + root)")
                let path = join(cache, "index.scip")
                if options.rebuild || !FileManager.default.fileExists(atPath: path) {
                    try build(side: side, root: root, cache: cache, log: log)
                } else {
                    log("Rust index for \(side.side.rawValue) \(side.sha.prefix(8)): cached.")
                }
                var index = try SCIP.decode(Data(contentsOf: URL(fileURLWithPath: path)))
                index.projectRoot = URL(fileURLWithPath: join(side.dir, root)).absoluteString
                indexes.append(index)
                if let note = try? String(contentsOfFile: join(cache, "notes.txt"), encoding: .utf8), !note.isEmpty { notes.append(note) }
            }
            var indexed = SCIP.sideIndex(indexes, sourceRoot: side.dir, known: Set(side.files))
            if !notes.isEmpty { indexed.warnings.append(Warning(kind: "index-partial", message: "Rust at \(side.side.rawValue): \(notes.joined(separator: " "))")) }
            result[side.side] = indexed
        }
        return result
    }

    /// Index outermost Cargo projects; their metadata includes workspace members. Nested
    /// fixture manifests are not standalone projects to build.
    static func workspaceDirs(_ root: String) throws -> [String] {
        let canonical = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        var roots: Set<String> = []
        let manifests = ComponentBuilder.findFiles(root: root, where: { $0 == "Cargo.toml" })
        let directories = manifests.map { ($0 as NSString).deletingLastPathComponent }
        let outermost = directories.filter { dir in !directories.contains { $0 != dir && ($0.isEmpty || dir.hasPrefix($0 + "/")) } }
        for directory in outermost {
            let manifest = join(directory, "Cargo.toml")
            let data = try Shell.run(["cargo", "metadata", "--format-version", "1", "--no-deps", "--manifest-path", join(root, manifest)], cwd: root)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let workspace = json["workspace_root"] as? String else {
                throw IndexError("Cargo metadata did not identify the workspace for \(manifest).")
            }
            let path = URL(fileURLWithPath: workspace).resolvingSymlinksInPath().path
            guard path == canonical || path.hasPrefix(canonical + "/") else { throw IndexError("Cargo workspace is outside the exported commit: \(manifest).") }
            roots.insert(path == canonical ? "" : String(path.dropFirst(canonical.count + 1)))
        }
        return roots.sorted()
    }

    private static func build(side: IndexSide, root: String, cache: String, log: (String) -> Void) throws {
        let tool = ProcessInfo.processInfo.environment["REVIEWMAP_RUST_ANALYZER"] ?? "rust-analyzer"
        guard Shell.exists(tool), (try? Shell.run([tool, "--version"])) != nil else {
            throw IndexError("Rust indexing needs rust-analyzer (rustup component add rust-analyzer rust-src).")
        }
        let fm = FileManager.default
        try fm.createDirectory(atPath: cache, withIntermediateDirectories: true)
        let logPath = join(cache, "build.log")
        let directory = join(side.dir, root)
        let start = Date()
        log("Indexing \(side.side.rawValue) \(side.sha.prefix(8)) with rust-analyzer…")
        let metadata = try Shell.runLogged(["cargo", "metadata", "--format-version", "1"], cwd: directory, logPath: logPath)
        let output = join(cache, "index.scip.tmp")
        try? fm.removeItem(atPath: output)
        let status = try Shell.runLogged([tool, "scip", directory, "--output", output], cwd: directory,
                                        logPath: logPath, append: true,
                                        environment: ["RA_LOG": "warn,load_cargo=debug"])
        guard status == 0, fm.fileExists(atPath: output) else { throw IndexError("rust-analyzer scip failed at \(side.side.rawValue). Log: \(logPath)") }
        // rust-analyzer can emit a useful index and exit successfully after build-script or macro failures.
        let transcript = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        let partial = metadata != 0 || hasPartialDiagnostics(transcript)
        let note = partial ? "some dependencies, build scripts, macros, or symbols could not be indexed completely. Log: \(logPath)" : ""
        try note.write(toFile: join(cache, "notes.txt"), atomically: true, encoding: .utf8)
        let path = join(cache, "index.scip")
        try? fm.removeItem(atPath: path)
        try fm.moveItem(atPath: output, toPath: path)
        log("Indexed Rust \(side.side.rawValue) in \(String(format: "%.2f", Date().timeIntervalSince(start)))s.")
    }

    static func hasPartialDiagnostics(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("errors occurred while running build scripts")
            || lower.contains("failed to start proc-macro server")
            || (lower.contains("proc-macro loading for") && lower.contains("failed"))
            || lower.contains("proc-macro server failed") || lower.contains("failed to load proc-macro")
            || lower.contains("failed to load proc macro") || lower.contains("cargo metadata` failed")
            || lower.contains("encountered duplicate scip symbols") || lower.contains(" error ")
    }
}
