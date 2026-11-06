import Foundation

/// TypeScript: tree-sitter for parsing and risk marks, npm packages and `tsconfig` projects for components,
/// lockfiles for pins, and scip-typescript for exact references.
struct TypeScriptLanguage: Language {
    let id = "typescript"
    let displayName = "TypeScript"

    static let extensions = ["ts", "tsx", "mts", "cts"]
    /// Extensions an import may name for a TypeScript file (`./cart.js` is `cart.ts` once compiled).
    static let importExtensions: Set<String> = ["ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs"]

    func isSource(_ path: String) -> Bool {
        Self.extensions.contains((path as NSString).pathExtension)
    }

    func parse(path: String, source: String) -> ParsedFile {
        TypeScriptExtractor.parse(path: path, source: source)
    }

    let generatedPatterns = ["**/*.generated.ts", "**/*.generated.tsx", "**/__generated__/**", "**/*.gen.ts", "**/*_pb.ts", "**/*.pb.ts"]

    func addComponents(root: String, files: [String], options: AnalyzeOptions, layout: inout ComponentLayout) {
        TypeScriptComponents.add(root: root, files: files, layout: &layout)
    }

    /// Node's built-in modules (`node:fs` is reported as `fs`).
    let platformModules: Set<String> = [
        "assert", "async_hooks", "buffer", "child_process", "cluster", "console", "constants", "crypto", "dgram",
        "diagnostics_channel", "dns", "domain", "events", "fs", "http", "http2", "https", "inspector", "module", "net",
        "os", "path", "perf_hooks", "process", "punycode", "querystring", "readline", "repl", "stream", "string_decoder",
        "sys", "test", "timers", "tls", "trace_events", "tty", "url", "util", "v8", "vm", "wasi", "worker_threads", "zlib",
        "sqlite", "sea",
    ]

    func pinnedPackages(blobs: [String: String], dir: String) -> [String: String] {
        TypeScriptComponents.pinnedPackages(blobs: blobs, dir: dir)
    }

    /// npm package names are their own identities.
    func package(ofModule module: String, pinned: Set<String>) -> String? {
        pinned.contains(module) ? module : nil
    }

    // MARK: Contracts and risk

    func contractFlags(_ builder: ModelBuilder, pairs: [Int]) -> [Int: [String]] {
        TypeScriptFlags(builder, pairs: pairs).compute()
    }

    func contractFile(_ path: String) -> (key: String, flag: String)? { nil }

    func contractFileFlags(key: String, flag: String, basePath: String, headPath: String) -> [String] { [] }

    /// Settings are keyed "package.json <field>" and "tsconfig <compiler option>".
    func settingFlag(_ key: String) -> String {
        let parts = key.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "settings-changed" }
        let name = parts[1]
        if parts[0] == "package.json" {
            if name == "engines" { return "engines-changed" }
            return "package-exports-changed"
        }
        let lower = name.lowercased()
        if lower.hasPrefix("strict") || lower.hasPrefix("noimplicit") || lower.hasPrefix("nounchecked") || lower == "exactoptionalpropertytypes" {
            return "strictness-changed"
        }
        if ["target", "lib", "jsx"].contains(lower) { return "target-changed" }
        if ["module", "moduleresolution", "paths", "baseurl", "rootdir", "rootdirs", "esmoduleinterop", "verbatimmodulesyntax",
            "isolatedmodules", "allowsyntheticdefaultimports", "resolvejsonmodule", "moduledetection", "types", "typeroots"].contains(lower) {
            return "module-resolution-changed"
        }
        return "compiler-options-changed"
    }

    private static let configFlags: Set<String> = ["strictness-changed", "target-changed", "module-resolution-changed",
                                                   "compiler-options-changed", "engines-changed", "settings-changed"]

    /// Compiler settings are medium; a package's entry points and every declaration-level flag are high on an
    /// interface and medium elsewhere.
    func flagRisk(_ flag: String, isInterface: Bool) -> Double {
        if Self.configFlags.contains(flag) { return RiskWeight.medium }
        if flag == "package-exports-changed" { return RiskWeight.high }
        return isInterface ? RiskWeight.high : RiskWeight.medium
    }

    /// React components: declarations that return JSX, members of class components, and declarations typed
    /// as components or elements.
    func isViewCode(_ d: Decl, inherits: Set<String>) -> Bool {
        if d.traits.contains("jsx") || inherits.contains("Component") || inherits.contains("PureComponent") { return true }
        let types = d.signatureDisplay + " " + (d.typeAnnotation ?? "")
        return ["JSX.Element", "ReactNode", "ReactElement", "FC<", "FunctionComponent", "ComponentType"].contains(where: types.contains)
    }

    // MARK: Structural review

    /// Named exports and their public members; default exports keep their existing exclusion.
    func isPublicAPI(_ decl: Decl, enclosing: [Decl]) -> Bool {
        if decl.modifiers.contains("default") { return false }
        guard !decl.isTopLevel else { return decl.modifiers.contains("export") }
        if let access = decl.access, access != "public" { return false }
        guard let top = enclosing.first(where: \.isTopLevel) else { return false }
        return top.modifiers.contains("export") && !top.modifiers.contains("default")
    }

    /// Constructors, default exports, and names that aren't plain identifiers (`#private`, computed keys).
    func isImplicitlyCalled(_ decl: Decl) -> Bool {
        ["constructor", "default"].contains(decl.name) || !(decl.name.first.map { $0.isLetter || $0 == "_" || $0 == "$" } ?? false)
    }

    // MARK: Resolution

    func index(options: IndexOptions, repoRoot: String, sides: [IndexSide], log: (String) -> Void) throws -> [Side: SideIndex]? {
        try TypeScriptIndex.load(options: options, repoRoot: repoRoot, sides: sides, log: log)
    }

    // MARK: Module specifiers

    /// The package a bare import specifier names: "@scope/pkg/sub" -> "@scope/pkg", "node:fs" -> "fs". Nil for
    /// path aliases (`@/`, `~`, `#`, `$`) and other schemes (`bun:`, `virtual:`), which name no package.
    static func packageName(_ spec: String) -> String? {
        if spec.hasPrefix("node:") { return String(spec.dropFirst("node:".count).split(separator: "/").first ?? "") }
        if spec.contains(":") || spec.hasPrefix("@/") || spec.hasPrefix("~") || spec.hasPrefix("#") || spec.hasPrefix("$") { return nil }
        let parts = spec.split(separator: "/")
        guard let first = parts.first else { return nil }
        if first.hasPrefix("@") { return parts.count > 1 ? "\(first)/\(parts[1])" : nil }
        return String(first)
    }

    /// A relative import without the extension it may name: "./cart.js" -> "./cart" (`cart.ts` once compiled).
    static func importPath(_ spec: String) -> String {
        let ext = (spec as NSString).pathExtension
        return importExtensions.contains(ext) ? (spec as NSString).deletingPathExtension : spec
    }
}
