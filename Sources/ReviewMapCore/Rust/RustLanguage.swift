import Foundation

struct RustLanguage: Language {
    let id = "rust"
    let displayName = "Rust"
    func isSource(_ path: String) -> Bool { path.hasSuffix(".rs") }
    func parse(path: String, source: String) -> ParsedFile { RustExtractor.parse(path: path, source: source) }
    let generatedPatterns = ["**/target/**", "target/**"]
    let platformModules: Set<String> = ["std", "core", "alloc", "proc_macro", "test"]
    func addComponents(root: String, files: [String], options: AnalyzeOptions, layout: inout ComponentLayout) { RustComponents.add(root: root, files: files, layout: &layout) }
    func pinnedPackages(blobs: [String: String], dir: String) -> [String: String] { RustComponents.pinnedPackages(blobs: blobs, dir: dir) }
    func package(ofModule module: String, pinned: Set<String>) -> String? { pinned.first { $0.replacingOccurrences(of: "-", with: "_") == module } }
    func contractFlags(_ builder: ChangeReportBuilder, pairs: [Int]) -> [Int: [String]] { RustFlags(builder, pairs: pairs).compute() }
    func contractFile(_ path: String) -> (key: String, flag: String)? { nil }
    func contractFileFlags(key: String, flag: String, basePath: String, headPath: String) -> [String] { [] }
    func settingFlag(_ key: String) -> String { RustFlags.settingFlag(key) }
    func flagRisk(_ flag: String, isInterface: Bool) -> Double { RustFlags.risk(flag, isInterface: isInterface) }
    func isViewCode(_ decl: Declaration, inherits: Set<String>) -> Bool { false }
    func isPublicAPI(_ decl: Declaration, enclosing: [Declaration]) -> Bool {
        guard decl.access == "public" else { return false }
        return enclosing.allSatisfy { $0.access == "public" || ($0.kind == .extension && !$0.traits.contains("rust-module")) }
    }
    func isImplicitlyCalled(_ decl: Declaration) -> Bool { decl.name == "main" || decl.attributes.contains { $0 == "test" || $0 == "bench" } }
    func conformers(of interface: Pair, requirement: Pair?, in builder: ChangeReportBuilder, for use: ConformanceUse) -> [Conformer] {
        RustConformance(b: builder).conformers(of: interface, requirement: requirement, for: use)
    }
    func index(options: IndexOptions, repoRoot: String, sides: [IndexSide], log: (String) -> Void) throws -> [Side: SideIndex]? { nil }
}
