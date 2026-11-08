import Foundation

// Kotlin's index: scip-java compiles each Gradle build of a side's exported tree (`clean` and the compile tasks,
// through its init script), then indexes the Kotlin sources with the Kotlin Analysis API. Bazel workspaces go
// through KotlinBazel instead. It is a full build per side, like Swift's. The indexes are cached per commit next to the other languages', in
// `<cache>/<repo>/<sha>/kotlin/`, one per Gradle build.

enum KotlinIndex {
    /// The scip-java release downloaded when none is on the PATH. `REVIEWMAP_SCIP_JAVA` names another command.
    static let scipJavaVersion = "v0.14.1"

    static func load(options: IndexOptions, repoRoot: String, sides: [IndexSide], log: (String) -> Void) throws -> [Side: SideIndex] {
        let repoDir = (options.cacheDir as NSString).appendingPathComponent(Paths.slug((repoRoot as NSString).lastPathComponent))
        var out: [Side: SideIndex] = [:]
        for s in sides {
            // A side without Kotlin has nothing to index.
            if s.files.isEmpty {
                out[s.side] = SideIndex(refs: [:])
                continue
            }
            let cache = (repoDir as NSString).appendingPathComponent("\(s.sha)/kotlin")
            let builds = gradleBuilds(s.dir)
            if options.builder == "bazel" || (builds.isEmpty && hasBazelWorkspace(s.dir)) {
                out[s.side] = try KotlinBazel.load(side: s, cache: cache, options: options, repoRoot: repoRoot, log: log)
                continue
            }
            guard !builds.isEmpty else {
                throw IndexError("Kotlin indexing needs a Gradle build (settings.gradle.kts or build.gradle.kts) at \(s.side.rawValue).")
            }
            var indexes: [SCIP.Index] = []
            for build in builds {
                let indexPath = cache + "/\(cacheName(build)).scip"
                if options.rebuild || !FileManager.default.fileExists(atPath: indexPath) {
                    try gradle(side: s, build: build, indexPath: indexPath, options: options, log: log)
                } else {
                    log("Kotlin index for \(s.side.rawValue) \(s.sha.prefix(8))\(build.isEmpty ? "" : " \(build)"): cached.")
                }
                var index = try SCIP.decode(try Data(contentsOf: URL(fileURLWithPath: indexPath)))
                scopeUnqualifiedSymbols(&index, root: s.dir, build: build)
                // The cached index was written in another export of the tree; its paths are relative to the build.
                index.projectRoot = URL(fileURLWithPath: join(s.dir, build)).absoluteString
                indexes.append(index)
            }
            out[s.side] = SCIP.sideIndex(indexes, sourceRoot: s.dir, known: Set(s.files))
        }
        return out
    }

    static let settingsFiles: Set<String> = ["settings.gradle", "settings.gradle.kts"]
    static let buildFiles: Set<String> = ["build.gradle", "build.gradle.kts"]

    /// The Gradle builds to index, repo-relative ("" for the root): the outermost directories with a settings
    /// file, or, where there is none, the outermost ones with a build file. An included build sits under its
    /// parent and is indexed with it.
    static func gradleBuilds(_ root: String) -> [String] {
        func outermost(_ files: [String]) -> [String] {
            let dirs = Set(files.map { ($0 as NSString).deletingLastPathComponent }).sorted()
            return dirs.filter { d in !dirs.contains { $0 != d && ($0.isEmpty || d.hasPrefix($0 + "/")) } }
        }
        let settings = outermost(ComponentBuilder.findFiles(root: root, where: settingsFiles.contains))
        let builds = outermost(ComponentBuilder.findFiles(root: root, where: buildFiles.contains))
            .filter { d in !settings.contains { $0.isEmpty || d == $0 || d.hasPrefix($0 + "/") } }
        return (settings + builds).sorted()
    }

    /// A file name for a build's index that no other build path maps to: "" is "_root", and everything outside
    /// letters and digits is percent-encoded ("tools/android" and "tools-android" stay apart).
    static func cacheName(_ build: String) -> String {
        build.isEmpty ? "_root" : (build.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? Paths.slug(build))
    }

    /// The prefix scip-java gives a symbol without Maven coordinates.
    static let unqualifiedPrefix = "scip-java maven . . "

    /// scip-java gives a module's own declarations no coordinates when no other module depends on it
    /// ("scip-java maven . . demo/main()."), so two such modules, or two Gradle builds, can declare the same
    /// symbol, and `SCIP.sideIndex` would link one to the other. Those symbols are scoped to the Gradle project
    /// that holds the document: the nearest directory with a build file, up to the build's root. Symbols with
    /// coordinates stay as they are, so references across modules still link.
    static func scopeUnqualifiedSymbols(_ index: inout SCIP.Index, root: String, build: String) {
        let fm = FileManager.default
        var projects: [String: String] = [:]
        func project(ofDir dir: String) -> String {
            if let p = projects[dir] { return p }
            let p: String
            if dir == build || dir.isEmpty || !(build.isEmpty || dir.hasPrefix(build + "/")) {
                p = build
            } else if buildFiles.contains(where: { fm.fileExists(atPath: join(join(root, dir), $0)) }) {
                p = dir
            } else {
                p = project(ofDir: (dir as NSString).deletingLastPathComponent)
            }
            projects[dir] = p
            return p
        }
        for d in index.documents.indices {
            let file = join(build, index.documents[d].path)
            let owner = project(ofDir: (file as NSString).deletingLastPathComponent)
            // A package name in a SCIP symbol escapes a space by doubling it.
            let package = "reviewmap:" + (owner.isEmpty ? "." : owner).replacingOccurrences(of: " ", with: "  ")
            for o in index.documents[d].occurrences.indices {
                let symbol = index.documents[d].occurrences[o].symbol
                guard symbol.hasPrefix(unqualifiedPrefix) else { continue }
                index.documents[d].occurrences[o].symbol = "scip-java maven \(package) . " + symbol.dropFirst(unqualifiedPrefix.count)
            }
        }
    }

    static func hasBazelWorkspace(_ root: String) -> Bool {
        IndexBuilder.BuildPlan.bazelWorkspaceFiles.contains { FileManager.default.fileExists(atPath: join(root, $0)) }
    }

    /// Whether `java` runs. macOS has a stub at /usr/bin/java that is on the PATH without a JDK installed.
    static func hasJava() -> Bool {
        (try? Shell.run(["java", "-version"])) != nil
    }

    private static func gradle(side s: IndexSide, build: String, indexPath: String, options: IndexOptions, log: (String) -> Void) throws {
        let fm = FileManager.default
        let dir = join(s.dir, build)
        let at = build.isEmpty ? "" : " in \(build)"
        let override = ProcessInfo.processInfo.environment["REVIEWMAP_SCIP_JAVA"]
        if override == nil {
            guard hasJava() else { throw IndexError("Kotlin indexing needs a JDK (java on the PATH, version 17 or newer).") }
            guard fm.isExecutableFile(atPath: join(dir, "gradlew")) || Shell.exists("gradle") else {
                throw IndexError("Kotlin indexing needs Gradle: a gradlew in the build or gradle on the PATH.")
            }
        }
        let cache = (indexPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: cache, withIntermediateDirectories: true)
        let logPath = indexPath + ".log"
        let tool = try scipJava(options: options, log: log)
        let output = indexPath + ".tmp"
        try? fm.removeItem(atPath: output)
        let start = Date()
        log("Building and indexing \(s.side.rawValue) \(s.sha.prefix(8))\(at) with Gradle and scip-java…")
        let status = try Shell.runLogged(tool + ["index", "--output", output], cwd: dir, logPath: logPath,
                                         environment: ["TERM": "dumb"])
        guard status == 0, fm.fileExists(atPath: output) else {
            throw IndexError("scip-java failed at \(s.side.rawValue)\(at). Log: \(logPath)")
        }
        try? fm.removeItem(atPath: indexPath)
        try fm.moveItem(atPath: output, toPath: indexPath)
        log("Indexed \(s.side.rawValue)\(at) in \(Int(Date().timeIntervalSince(start)))s.")
    }

    /// scip-java from `REVIEWMAP_SCIP_JAVA`, the PATH, or the cache, where the release launcher is downloaded the
    /// first time and checked against its published SHA-256.
    private static func scipJava(options: IndexOptions, log: (String) -> Void) throws -> [String] {
        if let command = ProcessInfo.processInfo.environment["REVIEWMAP_SCIP_JAVA"] {
            return command.split(separator: " ").map(String.init)
        }
        if Shell.exists("scip-java") { return ["scip-java"] }
        return [try scipJavaLauncher(options: options, log: log)]
    }

    /// The scip-java release launcher in the cache, downloaded the first time and checked against its published
    /// SHA-256. It is a shell script followed by a jar that holds all of scip-java, the Kotlin indexer included.
    static func scipJavaLauncher(options: IndexOptions, log: (String) -> Void) throws -> String {
        let fm = FileManager.default
        let bin = (options.cacheDir as NSString).appendingPathComponent("tools/scip-java-\(scipJavaVersion)")
        let path = bin + "/scip-java"
        if fm.isExecutableFile(atPath: path) { return path }
        try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        log("Downloading scip-java \(scipJavaVersion)…")
        let url = "https://github.com/scip-code/scip-java/releases/download/\(scipJavaVersion)/scip-java-\(scipJavaVersion)"
        let logPath = bin + "/install.log"
        let download = path + ".download"
        guard try Shell.runLogged(["curl", "-fsSL", "-o", download, url], cwd: bin, logPath: logPath) == 0,
              try Shell.runLogged(["curl", "-fsSL", "-o", download + ".sha256", url + ".sha256"], cwd: bin, logPath: logPath, append: true) == 0
        else { throw IndexError("Could not download scip-java. Log: \(logPath)") }
        let expected = (try String(contentsOfFile: download + ".sha256", encoding: .utf8)).split(separator: " ").first.map(String.init) ?? ""
        let actual = (try Shell.string(["shasum", "-a", "256", download])).split(separator: " ").first.map(String.init) ?? ""
        try? fm.removeItem(atPath: download + ".sha256")
        guard !expected.isEmpty, expected == actual else {
            try? fm.removeItem(atPath: download)
            throw IndexError("The downloaded scip-java does not match its SHA-256.")
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: download)
        try fm.moveItem(atPath: download, toPath: path)
        return path
    }
}
