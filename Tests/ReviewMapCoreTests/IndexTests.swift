import Foundation
import XCTest
import IndexStoreDB
@testable import ReviewMapCore

/// Index mode on Fixtures/indexed, a package that builds anywhere (Foundation only). It has the cases
/// name matching gets wrong: a common member name (`load()` on Store and Cache) and a type name
/// declared in two modules (`Config` in Storage and Settings), used module-qualified.
final class IndexTests: XCTestCase {
    static var repo: String?
    static var cache: String?
    static var indexed: ChangeReport?
    static var named: ChangeReport?

    override class func tearDown() {
        for dir in [repo, cache].compactMap({ $0 }) { try? FileManager.default.removeItem(atPath: dir) }
        super.tearDown()
    }

    func requireIndexStore() throws {
        do { _ = try IndexBuilder.libraryPath() } catch { throw XCTSkip("No libIndexStore in this toolchain: \(error)") }
    }

    func fixtureRepo() throws -> String {
        if let r = Self.repo { return r }
        let repo = try Fixture.repo("indexed")
        Self.repo = repo
        Self.cache = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-index-cache-\(UUID().uuidString)")
        return repo
    }

    func analyze(index: IndexOptions) throws -> ChangeReport {
        try Analyzer.run(AnalyzeOptions(repo: try fixtureRepo(), base: "base", head: "main", index: index))
    }

    func indexedReport() throws -> ChangeReport {
        try requireIndexStore()
        if let m = Self.indexed { return m }
        _ = try fixtureRepo()
        let m = try analyze(index: IndexOptions(enabled: true, builder: "swift", cacheDir: Self.cache!))
        Self.indexed = m
        return m
    }

    func namedReport() throws -> ChangeReport {
        if let m = Self.named { return m }
        let m = try analyze(index: IndexOptions())
        Self.named = m
        return m
    }

    func reviewItem(_ m: ChangeReport, _ name: String) throws -> ReviewItem {
        try XCTUnwrap(m.reviewItems.first { $0.qualifiedName == name }, "no review item \(name)")
    }

    func testResolutionIsRecorded() throws {
        XCTAssertEqual(try indexedReport().analyzer.resolution, "index")
        XCTAssertEqual(try namedReport().analyzer.resolution, "name-based")
        XCTAssertFalse(try indexedReport().warnings.contains { $0.kind.hasPrefix("index-") })
    }

    /// `gradle` is Kotlin's builder; Swift picks its own, so a repo with both languages can pass it.
    func testGradleBuilderLeavesSwiftAlone() throws {
        try requireIndexStore()
        _ = try fixtureRepo()
        // A rebuild, so the builder is actually chosen; it is whatever Swift would pick without one.
        let m = try analyze(index: IndexOptions(enabled: true, builder: "gradle", cacheDir: Self.cache!, rebuild: true))
        XCTAssertFalse(m.warnings.contains { $0.message.contains("Unknown index builder") }, "\(m.warnings)")
    }

    func testCommonMemberNameIsNotCountedAsUse() throws {
        // Feed.cached() calls Cache.load(); name matching counts it as a use of Store.load().
        XCTAssertEqual(Set(try reviewItem(try namedReport(), "Store.load()").usedBy.map(\.symbol)), ["Feed.items()", "Feed.cached()"])
        XCTAssertEqual(try reviewItem(try indexedReport(), "Store.load()").usedBy.map(\.symbol), ["Feed.items()"])
    }

    func testCallerContextIsExact() throws {
        let m = try indexedReport()
        let load = try reviewItem(m, "Store.load()")
        let callers = m.regions.filter { $0.reviewItem == load.id && $0.relation == "caller" }
        XCTAssertEqual(callers.map { $0.reasons[0] }, ["Feed.items()"])
    }

    func testModuleQualifiedReferenceMakesAnEdgeChange() throws {
        // Feed.limit() uses Storage.Config, new at head. Name matching doesn't see it.
        let edge = { (m: ChangeReport) in m.edges.first { $0.from == "spm:Feed" && $0.to == "spm:Storage" } }
        XCTAssertEqual(edge(try namedReport())?.status, .unchanged)
        let e = try XCTUnwrap(edge(try indexedReport()))
        XCTAssertEqual(e.status, .changed)
        XCTAssertEqual(e.symbolsAdded, ["Config"])
        // The other Config (Settings) is used on both sides, so that edge stays unchanged.
        XCTAssertEqual(try indexedReport().edges.first { $0.from == "spm:Feed" && $0.to == "spm:Settings" }?.status, .unchanged)
    }

    func testDependsOnAndDefinitionsPointAtTheRightModule() throws {
        let m = try indexedReport()
        let limit = try reviewItem(m, "Feed.limit()")
        XCTAssertTrue(limit.dependsOn.contains { $0.component == "spm:Storage" && $0.symbol == "Config.limit" })
        XCTAssertFalse(limit.dependsOn.contains { $0.component == "spm:Settings" })
        let defs = m.regions.filter { $0.reviewItem == limit.id && $0.relation == "definition" }
        XCTAssertTrue(defs.contains { $0.reasons[0] == "Config" && $0.file == "Sources/Storage/Config.swift" })
        XCTAssertFalse(defs.contains { $0.file.hasPrefix("Sources/Settings") })
    }

    func testCachedStoreIsReusedWithoutBuilding() throws {
        _ = try indexedReport()
        // An unknown builder would fail if a build were attempted.
        let again = try analyze(index: IndexOptions(enabled: true, builder: "none", cacheDir: Self.cache!))
        XCTAssertEqual(again.analyzer.resolution, "index")
        XCTAssertEqual(again.edges, try indexedReport().edges)
        XCTAssertEqual(again.reviewItems, try indexedReport().reviewItems)
    }

    func testFailedBuildFallsBackToNamesAndKeepsTheCache() throws {
        _ = try indexedReport()
        let failed = try analyze(index: IndexOptions(enabled: true, builder: "none", cacheDir: Self.cache!, rebuild: true))
        XCTAssertEqual(failed.analyzer.resolution, "name-based")
        XCTAssertTrue(failed.warnings.contains { $0.kind == "index-unavailable" })
        XCTAssertEqual(failed.reviewItems, try namedReport().reviewItems)
        // The stores from the earlier build are still there.
        XCTAssertEqual(try analyze(index: IndexOptions(enabled: true, builder: "none", cacheDir: Self.cache!)).analyzer.resolution, "index")
    }

    func testIndexFollowsReviewmapYml() throws {
        try requireIndexStore()
        let repo = try fixtureRepo()
        let config = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-index-\(UUID().uuidString).yml")
        defer { try? FileManager.default.removeItem(atPath: config) }
        try "index:\n  enabled: true\n  builder: swift\n".write(toFile: config, atomically: true, encoding: .utf8)
        let on = try Analyzer.run(AnalyzeOptions(repo: repo, base: "base", head: "main", configPath: config,
                                                 index: IndexOptions(cacheDir: Self.cache!)))
        XCTAssertEqual(on.analyzer.resolution, "index")
        let off = try Analyzer.run(AnalyzeOptions(repo: repo, base: "base", head: "main", configPath: config,
                                                  index: IndexOptions(enabled: false, cacheDir: Self.cache!)))
        XCTAssertEqual(off.analyzer.resolution, "name-based", "--no-index wins over reviewmap.yml")
    }
}

/// Finding the project to build in a monorepo, without building anything.
final class IndexProjectTests: XCTestCase {
    var root = ""

    override func setUpWithError() throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-mono-\(UUID().uuidString)")
        for dir in ["apps/ios/App.xcodeproj", "apps/ios/Pods/Pods.xcodeproj", "tools/Tool.xcodeproj", "web/src"] {
            try FileManager.default.createDirectory(atPath: root + "/" + dir, withIntermediateDirectories: true)
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
    }

    typealias Plan = IndexBuilder.BuildPlan

    func testProjectsInSubdirectoriesAreFound() throws {
        XCTAssertThrowsError(try Plan.findProject(root, builder: "xcodebuild")) { error in
            XCTAssertTrue("\(error)".contains("apps/ios/App.xcodeproj, tools/Tool.xcodeproj"), "\(error)")
        }
        XCTAssertEqual(try Plan.findProject(root, builder: "xcodebuild", under: "apps/ios"), "apps/ios/App.xcodeproj")
        try FileManager.default.removeItem(atPath: root + "/tools")
        XCTAssertEqual(try Plan.findProject(root, builder: "xcodebuild"), "apps/ios/App.xcodeproj", "Pods is skipped")
    }

    func testWorkspaceWinsOverProject() throws {
        try FileManager.default.createDirectory(atPath: root + "/apps/ios/App.xcworkspace", withIntermediateDirectories: true)
        XCTAssertEqual(try Plan.findProject(root, builder: "xcodebuild"), "apps/ios/App.xcworkspace")
    }

    func testGivenProjectPathForms() throws {
        let resolve = { (p: String, wd: String?) in try Plan.resolveProject(p, srcDir: self.root, repoRoot: self.root, workingDirectory: wd) }
        XCTAssertEqual(try resolve("apps/ios/App.xcodeproj", nil), "apps/ios/App.xcodeproj")
        XCTAssertEqual(try resolve("apps/ios/App.xcodeproj/", root + "/web"), "apps/ios/App.xcodeproj", "repo-relative, trailing slash")
        XCTAssertEqual(try resolve("App.xcodeproj", root + "/apps/ios"), "apps/ios/App.xcodeproj", "relative to the current directory")
        XCTAssertEqual(try resolve("./App.xcodeproj/", root + "/apps/ios"), "apps/ios/App.xcodeproj")
        XCTAssertEqual(try resolve(root + "/tools/Tool.xcodeproj", nil), "tools/Tool.xcodeproj", "absolute")
        XCTAssertThrowsError(try resolve("Missing.xcodeproj", root + "/apps/ios")) { error in
            XCTAssertTrue("\(error)".contains("apps/ios/Missing.xcodeproj"), "\(error)")
        }
    }
}

/// The Bazel builder: target discovery from a rules_xcodeproj rule, path mapping, and the build flow with a
/// stand-in `bazel` that answers build, info, and clean with real Swift compiler index outputs.
final class IndexBazelTests: XCTestCase {
    typealias Plan = IndexBuilder.BuildPlan

    static let buildFile = """
    load("@rules_xcodeproj//xcodeproj:defs.bzl", "top_level_target", "xcodeproj")

    xcodeproj(
        name = "xcodeproj",
        project_name = "App-Bazel",
        tags = ["manual"],
        top_level_targets = [
            top_level_target("//ios:App", target_environments = ["simulator", "device"]),
            "//ios:AppTests",
            ":Tool",
        ],
    )
    """

    func testTargetsComeFromTheXcodeprojRule() {
        XCTAssertEqual(Plan.xcodeprojTargets(buildFile: Self.buildFile), ["//ios:App", "//ios:AppTests", "//:Tool"])
        XCTAssertEqual(Plan.xcodeprojTargets(buildFile: "swift_library(name = \"A\")"), [])
    }

    func testWorkspaceIsTheNearestOneUp() throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-bazel-ws-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/mobile/ios", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/web", withIntermediateDirectories: true)
        XCTAssertNil(try Plan.bazelWorkspace(root, under: "mobile/ios"))
        XCTAssertNil(try Plan.bazelWorkspace(root, under: nil))
        // Below the current directory: run from the repo root, the workspace is in a subdirectory.
        FileManager.default.createFile(atPath: root + "/mobile/ios/MODULE.bazel", contents: Data())
        XCTAssertEqual(try Plan.bazelWorkspace(root, under: nil), "mobile/ios")
        XCTAssertEqual(try Plan.bazelWorkspace(root, under: "mobile/ios"), "mobile/ios")
        FileManager.default.createFile(atPath: root + "/web/MODULE.bazel", contents: Data())
        XCTAssertThrowsError(try Plan.bazelWorkspace(root, under: nil), "two workspaces, none above")
        XCTAssertEqual(try Plan.bazelWorkspace(root, under: "mobile"), "mobile/ios")
        try Self.buildFile.write(toFile: root + "/mobile/ios/BUILD.bazel", atomically: true, encoding: .utf8)
        XCTAssertEqual(try Plan.bazelWorkspace(root, under: nil, withTargets: true), "mobile/ios", "only one has an xcodeproj rule")
        // Above the current directory wins.
        FileManager.default.createFile(atPath: root + "/MODULE.bazel", contents: Data())
        XCTAssertEqual(try Plan.bazelWorkspace(root, under: "mobile/ios"), "mobile/ios")
        XCTAssertEqual(try Plan.bazelWorkspace(root, under: "mobile"), ".")
    }

    func testIndexPathsMapToRepoPaths() {
        let roots = IndexBuilder.expandRoots(["/tmp/export", "/ob/execroot/_main\tmobile"])
        let known: Set<String> = ["mobile/ios/App.swift", "web/x.swift"]
        XCTAssertEqual(IndexBuilder.relativePath("/tmp/export/web/x.swift", roots: roots, known: known), "web/x.swift")
        XCTAssertEqual(IndexBuilder.relativePath("/ob/execroot/_main/ios/App.swift", roots: roots, known: known), "mobile/ios/App.swift")
        XCTAssertEqual(IndexBuilder.relativePath("ios/App.swift", roots: roots, known: known), "mobile/ios/App.swift")
        XCTAssertEqual(IndexBuilder.relativePath("./ios/App.swift", roots: roots, known: known), "mobile/ios/App.swift")
        XCTAssertNil(IndexBuilder.relativePath("external/lib/Lib.swift", roots: roots, known: known))
        XCTAssertNil(IndexBuilder.relativePath("/elsewhere/ios/App.swift", roots: roots, known: known))
        let stored = IndexBuilder.storedPaths("mobile/ios/App.swift", roots: roots)
        XCTAssertTrue(stored.contains("/ob/execroot/_main/ios/App.swift"))
        XCTAssertTrue(stored.allSatisfy { $0.hasPrefix("/") })
    }

    /// Compile the same remapped working directory and paths emitted by rules_swift, then
    /// read after deleting the build tree, as happens when a cached store is reused.
    func testRemappedIndexReadsReferencesAndSkipsUncoveredFiles() throws {
        let library = try IndexStoreLibrary(dylibPath: IndexBuilder.libraryPath())
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory() + "rm-remapped-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: tmp) }
        let workspace = tmp + "/execroot"
        try fm.createDirectory(atPath: workspace + "/ios", withIntermediateDirectories: true)
        try "public func greeting() -> String { \"hello\" }\n"
            .write(toFile: workspace + "/ios/Greeting.swift", atomically: true, encoding: .utf8)
        try "public func render() -> String { greeting() }\n"
            .write(toFile: workspace + "/ios/Screen.swift", atomically: true, encoding: .utf8)
        try Shell.run(["swiftc", "-module-name", "App", "-emit-module", "-o", tmp + "/App.swiftmodule",
                       "-index-store-path", tmp + "/store", "-file-prefix-map", "\(workspace)=.",
                       "ios/Greeting.swift", "ios/Screen.swift"], cwd: workspace)
        try fm.removeItem(atPath: workspace)
        for prefix in ["", "mobile/"] {
            let built = IndexBuilder.BuiltStore(storePath: tmp + "/store", databasePath: tmp + "/db-\(prefix.isEmpty)",
                                               sourceRoots: [tmp + "/export", workspace + "\t" + String(prefix.dropLast())])
            let result = try IndexBuilder.read(store: built, library: library,
                files: [prefix + "ios/Greeting.swift", prefix + "ios/Screen.swift", prefix + "ios/Uncovered.swift"],
                log: { _ in }, side: .head)
            let refs = try XCTUnwrap(result.refs[prefix + "ios/Screen.swift"])
            XCTAssertTrue(refs.contains { $0.targetFile == prefix + "ios/Greeting.swift" && $0.targetLine == 1 && $0.line == 1 })
            XCTAssertNil(result.refs[prefix + "ios/Uncovered.swift"])
        }
    }

    func testMergeAddsOnlyMissingRecordsToExistingGlobalStore() throws {
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "rm-merge-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: root) }
        let global = root + "/_global_index_store"
        let existing = global + "/v5/records/AA/shared"
        try fm.createDirectory(atPath: (existing as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "existing record".write(toFile: existing, atomically: true, encoding: .utf8)
        let inode = try fm.attributesOfItem(atPath: existing)[.systemFileNumber] as? NSNumber
        // No declared stores: the global-only fallback stays usable without any copying.
        XCTAssertNil(IndexBuilder.mergeStores(under: root, into: global))
        XCTAssertEqual(IndexBuilder.findStore(global), global)
        let declared = root + "/bin/Dependency.indexstore/v5/records/AA"
        try fm.createDirectory(atPath: declared, withIntermediateDirectories: true)
        try "duplicate must not replace global".write(toFile: declared + "/shared", atomically: true, encoding: .utf8)
        try "cached dependency".write(toFile: declared + "/missing", atomically: true, encoding: .utf8)
        XCTAssertEqual(IndexBuilder.mergeStores(under: root, into: global), global)
        XCTAssertEqual(try String(contentsOfFile: existing, encoding: .utf8), "existing record")
        XCTAssertEqual(try String(contentsOfFile: global + "/v5/records/AA/missing", encoding: .utf8), "cached dependency")
        XCTAssertEqual(try fm.attributesOfItem(atPath: existing)[.systemFileNumber] as? NSNumber, inode)
        let addedInode = try fm.attributesOfItem(atPath: global + "/v5/records/AA/missing")[.systemFileNumber] as? NSNumber
        XCTAssertNil(IndexBuilder.mergeStores(under: root, into: global), "A repeated merge copies nothing")
        XCTAssertEqual(try fm.attributesOfItem(atPath: global + "/v5/records/AA/missing")[.systemFileNumber] as? NSNumber, addedInode)
        let fresh = root + "/merged-store"
        XCTAssertEqual(IndexBuilder.mergeStores(under: root, into: fresh), fresh)
        XCTAssertEqual(try String(contentsOfFile: fresh + "/v5/records/AA/missing", encoding: .utf8), "cached dependency")
    }

    func testObsoleteDatabaseCleanupPreservesStoresAndFailedRebuilds() throws {
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "rm-db-migration-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: root) }
        for name in ["store/v5", "db", "db-absolute-paths-v1"] {
            try fm.createDirectory(atPath: root + "/" + name, withIntermediateDirectories: true)
            try "keep".write(toFile: root + "/" + name + "/marker", atomically: true, encoding: .utf8)
        }
        try root.write(toFile: root + "/root.txt", atomically: true, encoding: .utf8)
        // An invalid builder makes the rebuild fail without replacing any existing cache data.
        XCTAssertThrowsError(try IndexBuilder.buildIfNeeded(options: IndexOptions(builder: "none", rebuild: true),
            side: .head, sha: "test", srcDir: root, repoRoot: root, cache: root, log: { _ in }))
        XCTAssertTrue(fm.fileExists(atPath: root + "/db/marker"))
        let reused = try IndexBuilder.buildIfNeeded(options: IndexOptions(builder: "none"),
            side: .head, sha: "test", srcDir: root, repoRoot: root, cache: root, log: { _ in })
        XCTAssertFalse(fm.fileExists(atPath: root + "/db"))
        XCTAssertEqual(reused.storePath, root + "/store")
        XCTAssertEqual(reused.databasePath, root + "/db-absolute-paths-v1")
        XCTAssertTrue(fm.fileExists(atPath: reused.storePath + "/v5/marker"))
        XCTAssertTrue(fm.fileExists(atPath: reused.databasePath + "/marker"))
    }

    static let fakeBazel = """
    #!/bin/sh
    # Reproduce mixed Bazel output: only the newly compiled Feed is in the global store;
    # dependency indexes, as restored from disk cache, exist only in declared output stores.
    ob=""; cmd=""; fail=no
    for a in "$@"; do
      case "$a" in
        --output_base=*) ob="${a#--output_base=}" ;;
        --fake-fail) fail=yes ;;
        build|info|clean) [ -z "$cmd" ] && cmd="$a" ;;
      esac
    done
    echo "fake bazel $*" >&2
    case "$cmd" in
      build)
        [ "$fail" = yes ] && exit 1
        mkdir -p "$ob/modules" "$ob/out/config/bin"
        for module in Storage Cache Settings Feed; do
          store="$ob/out/config/bin/$module.indexstore"
          [ "$module" = Feed ] && store="$ob/out/_global_index_store"
          swiftc -emit-module -module-name "$module" -I "$ob/modules" \
            -emit-module-path "$ob/modules/$module.swiftmodule" \
            -index-store-path "$store" -file-prefix-map "$(pwd -P)=." \
            Sources/"$module"/*.swift >&2 || exit 1
        done ;;
      info) echo "output_path: $ob/out"; echo "execution_root: $PWD" ;;
      clean) rm -rf "$ob" ;;
    esac
    """

    func testBazelBuildFlow() throws {
        try bazelFlow(subdir: "")
    }

    /// The workspace in ios/ of a monorepo, with reviewmap run from the repo root.
    func testBazelWorkspaceInSubdirectory() throws {
        try bazelFlow(subdir: "ios")
    }

    /// A Kotlin file in the same workspace: Kotlin's Bazel run (which fails against this stand-in) leaves Swift's
    /// build, flags, and references as they were.
    func testKotlinLeavesSwiftBazelBuildAlone() throws {
        try bazelFlow(subdir: "", kotlin: true)
    }

    func bazelFlow(subdir: String, kotlin: Bool = false) throws {
        do { _ = try IndexBuilder.libraryPath() } catch { throw XCTSkip("No libIndexStore in this toolchain: \(error)") }
        let fm = FileManager.default
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-bazel-\(UUID().uuidString)")
        defer { try? fm.removeItem(atPath: tmp) }
        // A bazel on the PATH.
        try fm.createDirectory(atPath: tmp + "/bin", withIntermediateDirectories: true)
        try Self.fakeBazel.write(toFile: tmp + "/bin/bazel", atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp + "/bin/bazel")
        let oldPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", tmp + "/bin:" + oldPath, 1)
        defer { setenv("PATH", oldPath, 1) }

        // Fixtures/indexed as a Bazel workspace whose xcodeproj rule names the targets.
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/indexed", withExtension: nil)).path
        let repo = tmp + "/repo"
        try fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        func git(_ args: String...) throws {
            try Shell.run(["git", "-C", repo, "-c", "user.email=fixture@example.com", "-c", "user.name=fixture"] + args)
        }
        let ws = subdir.isEmpty ? repo : repo + "/" + subdir
        func copyTree(_ side: String) throws {
            for item in try fm.contentsOfDirectory(atPath: repo) where item != ".git" { try fm.removeItem(atPath: repo + "/" + item) }
            try fm.createDirectory(atPath: ws, withIntermediateDirectories: true)
            for item in try fm.contentsOfDirectory(atPath: fixture + "/" + side) {
                try fm.copyItem(atPath: fixture + "/" + side + "/" + item, toPath: ws + "/" + item)
            }
            try "# web app\n".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
            fm.createFile(atPath: ws + "/MODULE.bazel", contents: Data())
            if kotlin {
                try fm.createDirectory(atPath: ws + "/kotlin", withIntermediateDirectories: true)
                try "package demo\n\nfun start() = println(\"\(side)\")\n".write(toFile: ws + "/kotlin/Main.kt", atomically: true, encoding: .utf8)
            }
            try Self.buildFile.replacingOccurrences(of: "\"//ios:AppTests\",\n", with: "").replacingOccurrences(of: ":Tool", with: ":Feed")
                .replacingOccurrences(of: "//ios:App", with: "//Sources:Storage")
                .write(toFile: ws + "/BUILD.bazel", atomically: true, encoding: .utf8)
        }
        try git("init", "-q", "-b", "main")
        try copyTree("base")
        try git("add", "-A")
        try git("commit", "-qm", "base")
        try git("branch", "base")
        try copyTree("head")
        try git("add", "-A")
        try git("commit", "-qm", "head")

        let cache = tmp + "/cache"
        // For the root workspace, invoke from an unrelated platform directory.
        try fm.createDirectory(atPath: repo + "/android", withIntermediateDirectories: true)
        let workingDirectory = subdir.isEmpty ? repo + "/android" : repo
        func analyze(rebuild: Bool = false, args: [String]? = nil, builder: String? = nil) throws -> ChangeReport {
            try Analyzer.run(AnalyzeOptions(repo: repo, base: "base", head: "main",
                index: IndexOptions(enabled: true, builder: builder, bazelArgs: args, cacheDir: cache,
                                    rebuild: rebuild, workingDirectory: workingDirectory)))
        }
        // Successful builds retire the old derived database namespace too.
        for ref in ["base", "main"] {
            let sha = try Shell.string(["git", "-C", repo, "rev-parse", ref])
            try fm.createDirectory(atPath: cache + "/repo/" + sha + "/db", withIntermediateDirectories: true)
        }
        let m = try analyze()
        XCTAssertEqual(m.analyzer.resolution, "index", "\(m.warnings)")
        XCTAssertEqual(try XCTUnwrap(m.reviewItems.first { $0.qualifiedName == "Store.load()" }).usedBy.map(\.symbol), ["Feed.items()"])
        let logs = try fm.subpathsOfDirectory(atPath: cache).filter { $0.hasSuffix("build.log") }
        XCTAssertEqual(logs.count, 2)
        for path in logs {
            XCTAssertFalse(fm.fileExists(atPath: cache + "/" + (path as NSString).deletingLastPathComponent + "/db"))
        }
        let log = try String(contentsOfFile: cache + "/" + logs[0], encoding: .utf8)
        XCTAssertFalse(log.contains("--aspects") || log.contains("reviewmap_kotlin"), log)
        if kotlin {
            XCTAssertTrue(m.warnings.contains { $0.kind == "index-unavailable" && $0.message.contains("Kotlin") }, "\(m.warnings)")
        }
        XCTAssertTrue(log.contains("--features=swift.use_global_index_store"), log)
        XCTAssertTrue(log.contains("--output_groups=+swift_index_store"), log)
        XCTAssertTrue(log.contains("--remote_download_regex=.*[.]indexstore(/.*)?"), log)
        XCTAssertTrue(log.contains("-- //Sources:Storage //:Feed"), log)
        XCTAssertFalse(m.warnings.contains { $0.kind == "index-partial" }, "\(m.warnings)")
        let library = try IndexStoreLibrary(dylibPath: IndexBuilder.libraryPath())
        let files = try fm.subpathsOfDirectory(atPath: ws + "/Sources").filter { $0.hasSuffix(".swift") }
            .map { (subdir.isEmpty ? "" : subdir + "/") + "Sources/" + $0 }
        func references() throws -> [String: [String: [IndexedRef]]] {
            var result: [String: [String: [IndexedRef]]] = [:]
            for path in logs {
                let dir = cache + "/" + (path as NSString).deletingLastPathComponent
                let roots = try String(contentsOfFile: dir + "/root.txt", encoding: .utf8).split(separator: "\n").map(String.init)
                let built = IndexBuilder.BuiltStore(storePath: dir + "/store", databasePath: dir + "/assert-db-\(UUID().uuidString)", sourceRoots: roots)
                result[path] = try IndexBuilder.read(store: built, library: library, files: files, log: { _ in }, side: .head).refs
            }
            return result
        }
        let originalRefs = try references()
        XCTAssertEqual(originalRefs.count, 2)
        for refs in originalRefs.values {
            XCTAssertEqual(Set(refs.keys), Set(files), "Both sides must cover every compiled module")
            let feed = (subdir.isEmpty ? "" : subdir + "/") + "Sources/Feed/Feed.swift"
            XCTAssertTrue(try XCTUnwrap(refs[feed]).contains { $0.name == "load()" && $0.targetFile.hasSuffix("Sources/Storage/Store.swift") })
        }
        // A failed rebuild must preserve both sides' exact references and source-root mappings.
        let failed = try analyze(rebuild: true, args: ["--fake-fail"])
        XCTAssertTrue(failed.warnings.contains { $0.kind == "index-unavailable" })
        let preserved = try analyze(builder: "none")
        XCTAssertEqual(preserved.analyzer.resolution, "index")
        XCTAssertEqual(preserved.reviewItems, m.reviewItems)
        XCTAssertEqual(preserved.regions, m.regions)
        XCTAssertEqual(try references(), originalRefs)
        // Check only this test's output bases; other analyzers may be running concurrently.
        for path in logs {
            let text = try String(contentsOfFile: cache + "/" + path, encoding: .utf8)
            let argument = try XCTUnwrap(text.split(whereSeparator: \.isWhitespace).first { $0.hasPrefix("--output_base=") })
            let outputBase = String(argument.dropFirst("--output_base=".count))
            XCTAssertFalse(fm.fileExists(atPath: outputBase), outputBase)
        }
    }
}

extension IndexProjectTests {
    func testUntrackedProjectIsExplained() throws {
        // The project exists in the working copy (repoRoot) but not in the exported commit (srcDir).
        let src = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: src) }
        XCTAssertThrowsError(try Plan.resolveProject("apps/ios/App.xcodeproj", srcDir: src, repoRoot: root, workingDirectory: nil)) { error in
            XCTAssertTrue("\(error)".contains("not tracked by git"), "\(error)")
        }
    }
}
