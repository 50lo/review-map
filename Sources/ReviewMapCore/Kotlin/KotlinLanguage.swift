import Foundation

/// Kotlin source is parsed without running Gradle or the compiler.
struct KotlinLanguage: Language {
    let id = "kotlin"
    let displayName = "Kotlin"

    func isSource(_ path: String) -> Bool {
        (path.hasSuffix(".kt") || path.hasSuffix(".kts")) && !path.hasSuffix(".gradle.kts")
    }
    func parse(path: String, source: String) -> ParsedFile { KotlinExtractor.parse(path: path, source: source) }
    let generatedPatterns = ["**/build/generated/**"]
    func addComponents(root: String, files: [String], options: AnalyzeOptions, layout: inout ComponentLayout) {
        KotlinComponents.add(root: root, files: files, options: options, layout: &layout)
    }
    let platformModules: Set<String> = ["kotlin", "java", "javax", "android", "dalvik"]
    func isPlatformModule(_ module: String) -> Bool { platformModules.contains(String(module.split(separator: ".").first ?? "")) }
    func pinnedPackages(blobs: [String: String], dir: String) -> [String: String] { KotlinComponents.pinnedPackages(blobs: blobs, dir: dir) }
    func package(ofModule module: String, pinned: Set<String>) -> String? { KotlinComponents.package(ofModule: module, pinned: pinned) }
    func contractFlags(_ builder: ChangeReportBuilder, pairs: [Int]) -> [Int: [String]] { KotlinFlags(builder, pairs: pairs).compute() }
    func contractFile(_ path: String) -> (key: String, flag: String)? { KotlinManifest.contractFile(path) }
    func contractFileFlags(key: String, flag: String, basePath: String, headPath: String) -> [String] { KotlinManifest.flags(basePath: basePath, headPath: headPath) }
    func settingFlag(_ key: String) -> String { KotlinFlags.settingFlag(key) }
    func flagRisk(_ flag: String, isInterface: Bool) -> Double { KotlinFlags.risk(flag, isInterface: isInterface) }
    func isViewCode(_ decl: Declaration, inherits: Set<String>) -> Bool { false }
    func isPublicAPI(_ decl: Declaration, enclosing: [Declaration]) -> Bool {
        decl.access == "public" && enclosing.allSatisfy { $0.access == "public" }
    }
    /// JVM entry points, operators, and declarations explicitly registered with common runtimes.
    func isImplicitlyCalled(_ decl: Declaration) -> Bool {
        if decl.kind == .func && (decl.name == "main" || decl.modifiers.contains("operator")) { return true }
        return !Set(decl.attributes).isDisjoint(with: ["Test", "Before", "After", "BeforeEach", "AfterEach", "BeforeAll", "AfterAll",
                                                      "BeforeClass", "AfterClass", "ParameterizedTest", "Provides", "Binds", "Inject", "Preview"])
    }
    func index(options: IndexOptions, repoRoot: String, sides: [IndexSide], log: (String) -> Void) throws -> [Side: SideIndex]? { nil }
}
