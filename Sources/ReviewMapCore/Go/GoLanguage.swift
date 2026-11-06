import Foundation

/// Go: tree-sitter for parsing and risk marks, `go.mod` modules and their package directories for components,
/// `go.mod` requirements for pins, and scip-go for exact references.
struct GoLanguage: Language {
    let id = "go"
    let displayName = "Go"

    func isSource(_ path: String) -> Bool {
        path.hasSuffix(".go") && Self.isPackagePath(path)
    }

    /// Paths outside `vendor` (copies of dependencies) and `testdata` (inputs the go tool ignores).
    static func isPackagePath(_ path: String) -> Bool {
        !path.split(separator: "/").dropLast().contains { $0 == "vendor" || $0 == "testdata" }
    }

    func parse(path: String, source: String) -> ParsedFile {
        GoExtractor.parse(path: path, source: source)
    }

    /// Files with the standard `// Code generated ... DO NOT EDIT.` header are generated too; see `isGenerated(source:)`.
    let generatedPatterns = ["**/*.pb.go", "**/*_gen.go", "**/zz_generated*.go"]

    /// The header `go generate` tools write, before the package clause.
    static func isGenerated(source: String) -> Bool {
        for line in source.split(separator: "\n", omittingEmptySubsequences: false).prefix(50) {
            if line.hasPrefix("package ") { return false }
            if line.hasPrefix("// Code generated ") && line.hasSuffix("DO NOT EDIT.") { return true }
        }
        return false
    }

    func addComponents(root: String, files: [String], options: AnalyzeOptions, layout: inout ComponentLayout) {
        GoComponents.add(root: root, files: files, layout: &layout)
    }

    let platformModules: Set<String> = []

    /// The standard library: an import path whose first element has no dot ("fmt", "net/http").
    func isPlatformModule(_ module: String) -> Bool {
        !(module.split(separator: "/").first?.contains(".") ?? true)
    }

    func pinnedPackages(blobs: [String: String], dir: String) -> [String: String] {
        GoComponents.pinnedPackages(blobs: blobs, dir: dir)
    }

    /// The pinned module with the longest path that the import path is in.
    func package(ofModule module: String, pinned: Set<String>) -> String? {
        pinned.filter { module == $0 || module.hasPrefix($0 + "/") }.max { $0.count < $1.count }
    }

    // MARK: Contracts and risk

    func contractFlags(_ builder: ModelBuilder, pairs: [Int]) -> [Int: [String]] {
        GoFlags(builder, pairs: pairs).compute()
    }

    func contractFile(_ path: String) -> (key: String, flag: String)? { nil }

    func contractFileFlags(key: String, flag: String, basePath: String, headPath: String) -> [String] { [] }

    func settingFlag(_ key: String) -> String {
        if key == "go.mod go" { return "go-version-changed" }
        if key == "go.mod toolchain" { return "toolchain-changed" }
        if key.hasPrefix("go.mod replace ") { return "replace-changed" }
        return "settings-changed"
    }

    private static let highFlags: Set<String> = ["api-removed", "unexported", "interface-method-added", "interface-method-removed",
                                                 "interface-method-changed", "field-tag-changed"]

    /// `go.mod` directives are medium. Removing or narrowing API and changing an interface or a serialized
    /// field are high; other declaration-level flags are high on an interface and medium elsewhere.
    func flagRisk(_ flag: String, isInterface: Bool) -> Double {
        if ["go-version-changed", "toolchain-changed", "replace-changed", "settings-changed"].contains(flag) { return RiskWeight.medium }
        if Self.highFlags.contains(String(flag.split(separator: ":").first ?? "")) { return RiskWeight.high }
        return isInterface ? RiskWeight.high : RiskWeight.medium
    }

    func isViewCode(_ decl: Declaration, inherits: Set<String>) -> Bool { false }

    // MARK: Structural review

    /// Exported names: capitalized, with a capitalized type for a method or field.
    func isPublicAPI(_ decl: Declaration, enclosing: [Declaration]) -> Bool {
        guard decl.name.first?.isUppercase == true else { return false }
        return decl.scope.map { $0.first?.isUppercase == true } ?? true
    }

    /// Methods the standard library calls through its interfaces.
    static let wellKnownMethods: Set<String> = [
        "String", "GoString", "Error", "Unwrap", "Is", "As", "Format", "ServeHTTP", "MarshalJSON", "UnmarshalJSON",
        "MarshalText", "UnmarshalText", "MarshalBinary", "UnmarshalBinary", "MarshalYAML", "UnmarshalYAML",
        "Len", "Less", "Swap", "Push", "Pop", "Read", "Write", "Close", "Scan", "Value",
    ]

    /// `main` and `init`, test functions the go tool runs, methods of standard interfaces, and embedded
    /// fields, which are used through the methods and fields they promote.
    func isImplicitlyCalled(_ decl: Declaration) -> Bool {
        if decl.traits.contains("embedded") { return true }
        if decl.scope != nil { return decl.kind == .func && Self.wellKnownMethods.contains(decl.name) }
        if decl.name == "main" || decl.name == "init" { return true }
        return ["Test", "Benchmark", "Example", "Fuzz"].contains { prefix in
            decl.name.hasPrefix(prefix) && !(decl.name.dropFirst(prefix.count).first?.isLowercase ?? false)
        }
    }

    /// Go interfaces are implicit: see `GoConformance`.
    func conformers(of interface: Pair, requirement: Pair?, in builder: ModelBuilder,
                    for use: ConformanceUse) -> [Conformer] {
        GoConformance(builder).conformers(of: interface, requirement: requirement, for: use)
    }

    // MARK: Resolution

    func index(options: IndexOptions, repoRoot: String, sides: [IndexSide], log: (String) -> Void) throws -> [Side: SideIndex]? {
        try GoIndex.load(options: options, repoRoot: repoRoot, sides: sides, log: log)
    }
}
