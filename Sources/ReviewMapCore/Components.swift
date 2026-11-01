import Foundation
import PathKit
import SwiftParser
import SwiftSyntax
import XcodeProj

struct ComponentInfo {
    var id: String
    var name: String
    var kind: ComponentKind
    var module: String?
    var parent: String?
    var isTest: Bool
    var layer: String?
}

/// A module-level dependency declared in a manifest (Package.swift or the Xcode project).
struct ManifestDep {
    var from: String        // component id
    var module: String      // target/module name or product name
    var file: String        // manifest path, relative to repo root
}

/// How one side's source tree is cut into components.
struct ComponentLayout {
    var components: [String: ComponentInfo] = [:]
    var fileComponent: [String: String] = [:]
    /// Swift module name -> the target-level component that owns it.
    var moduleComponent: [String: String] = [:]
    var manifestDeps: [ManifestDep] = []
    /// Target-level build settings that change how code compiles (component id -> manifest file and settings).
    var targetSettings: [String: (file: String, settings: [String: String])] = [:]
    /// External product name -> package identity.
    var externalProducts: [String: String] = [:]
    var warnings: [Warning] = []
}

enum ComponentBuilder {
    static let skipDirs: Set<String> = [".git", ".build", "Pods", "Carthage", "DerivedData", "node_modules", ".swiftpm", "SourcePackages"]

    static func build(root: String, swiftFiles: [String], config: inout Config, dumpPackage: Bool = false) -> ComponentLayout {
        var layout = ComponentLayout()
        var targetFiles: [String: [String]] = [:] // target component id -> files
        var claimedDirs: [(dir: String, id: String)] = []

        // 1. SPM targets.
        for manifest in findFiles(root: root, where: { $0 == "Package.swift" }) {
            let pkgDir = (manifest as NSString).deletingLastPathComponent
            for t in spmTargets(root: root, packageDir: pkgDir, dumpPackage: dumpPackage, layout: &layout) {
                var id = "spm:\(t.name)"
                if layout.components[id] != nil { id = "spm:\(pkgDir)/\(t.name)" }
                layout.components[id] = ComponentInfo(id: id, name: t.name, kind: .spmTarget, module: t.name,
                                                      parent: nil, isTest: t.isTest, layer: nil)
                layout.moduleComponent[t.name] = layout.moduleComponent[t.name] ?? id
                claimedDirs.append((join(pkgDir, t.path), id))
                layout.targetSettings[id] = (join(pkgDir, "Package.swift"), t.settings)
                for d in t.deps {
                    layout.manifestDeps.append(ManifestDep(from: id, module: d.name, file: join(pkgDir, "Package.swift")))
                    if let pkg = d.package { layout.externalProducts[d.name] = pkg }
                }
            }
        }
        // Longest directory prefix wins (nested packages).
        claimedDirs.sort { $0.dir.count > $1.dir.count }

        var unassigned: [String] = []
        for f in swiftFiles {
            if let c = claimedDirs.first(where: { $0.dir.isEmpty || f.hasPrefix($0.dir + "/") }) {
                layout.fileComponent[f] = c.id
                targetFiles[c.id, default: []].append(f)
            } else {
                unassigned.append(f)
            }
        }

        // 2. Xcode targets.
        let unassignedSet = Set(unassigned)
        var xcodeClaims: [String: [(id: String, priority: Int)]] = [:]
        for proj in findDirs(root: root, suffix: ".xcodeproj") {
            xcodeTargets(root: root, projPath: proj, unassigned: unassignedSet, layout: &layout, claims: &xcodeClaims)
        }
        var multiTarget = 0
        for f in unassigned {
            guard let claims = xcodeClaims[f], !claims.isEmpty else { continue }
            if claims.count > 1 { multiTarget += 1 }
            let best = claims.sorted { ($0.priority, $0.id) < ($1.priority, $1.id) }[0]
            layout.fileComponent[f] = best.id
            targetFiles[best.id, default: []].append(f)
        }
        if multiTarget > 0 {
            layout.warnings.append(Warning(kind: "multi-target-files",
                message: "\(multiTarget) files belong to more than one Xcode target; each was assigned to its main app target."))
        }

        // 3. Remaining files: folder components by top-level directory.
        for f in unassigned where layout.fileComponent[f] == nil {
            let parts = f.split(separator: "/")
            let top = parts.count > 1 ? String(parts[0]) : "."
            let id = "folder:\(top)"
            if layout.components[id] == nil {
                layout.components[id] = ComponentInfo(id: id, name: top == "." ? "(root)" : top, kind: .folder,
                                                      module: nil, parent: nil, isTest: isTestPath(top), layer: nil)
            }
            layout.fileComponent[f] = id
            targetFiles[id, default: []].append(f)
        }

        // 4. Split large targets by folder.
        for (id, files) in targetFiles {
            guard let info = layout.components[id], info.kind != .folder || info.parent == nil else { continue }
            split(parent: info, files: files, depth: 1, config: config, layout: &layout)
        }

        // 5. reviewmap.yml rules override everything.
        if let rules = config.components, !rules.isEmpty {
            let matchers = rules.map { ($0, $0.paths.map(Glob.init)) }
            for f in swiftFiles {
                guard let (rule, _) = matchers.first(where: { $0.1.contains { $0.matches(f) } }) else { continue }
                let id = "cfg:\(rule.name)"
                let original = layout.fileComponent[f].flatMap { layout.components[$0] }
                if layout.components[id] == nil {
                    layout.components[id] = ComponentInfo(id: id, name: rule.name, kind: .folder,
                                                          module: original?.module, parent: nil,
                                                          isTest: original?.isTest ?? false, layer: rule.layer)
                }
                layout.fileComponent[f] = id
            }
        }

        // A module root left with no files and no children (all its files moved by config rules)
        // hands its role to the component holding most of the module's files.
        let used = Set(layout.fileComponent.values)
        let parents = Set(layout.components.values.compactMap(\.parent))
        for (module, rootId) in layout.moduleComponent where !used.contains(rootId) && !parents.contains(rootId) {
            var counts: [String: Int] = [:]
            for c in layout.fileComponent.values where layout.components[c]?.module == module { counts[c, default: 0] += 1 }
            guard let best = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key else { continue }
            layout.moduleComponent[module] = best
            for i in layout.manifestDeps.indices where layout.manifestDeps[i].from == rootId {
                layout.manifestDeps[i].from = best
            }
        }
        // Drop components that ended up with no files, except module roots (they anchor import edges).
        let moduleRoots = Set(layout.moduleComponent.values)
        layout.components = layout.components.filter { used.contains($0.key) || parents.contains($0.key) || moduleRoots.contains($0.key) }
        return layout
    }

    // MARK: Splitting

    private static func split(parent: ComponentInfo, files: [String], depth: Int, config: Config, layout: inout ComponentLayout) {
        guard files.count > config.splitThreshold, depth <= config.splitMaxDepth else { return }
        // Root: the common directory, descending while one folder holds at least 80% of the files
        // (a few stray files elsewhere shouldn't push the root up to the repo root).
        var rootDir = commonDir(files)
        while true {
            var counts: [String: Int] = [:]
            for f in files where rootDir.isEmpty || f.hasPrefix(rootDir + "/") {
                let rel = rootDir.isEmpty ? f : String(f.dropFirst(rootDir.count + 1))
                let parts = rel.split(separator: "/")
                if parts.count > 2 { counts[String(parts[0]), default: 0] += 1 }
            }
            guard let top = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }),
                  Double(top.value) >= 0.8 * Double(files.count) else { break }
            rootDir = join(rootDir, top.key)
        }
        var groups: [String: [String]] = [:]
        for f in files where rootDir.isEmpty || f.hasPrefix(rootDir + "/") {
            let rel = rootDir.isEmpty ? f : String(f.dropFirst(rootDir.count + 1))
            let parts = rel.split(separator: "/")
            if parts.count > 1 { groups[String(parts[0]), default: []].append(f) }
        }
        // Splitting only helps when there are at least two folders.
        guard groups.count >= 2 else { return }
        for (folder, gfiles) in groups {
            // Name by the folder path under the parent's root, collapsing a leading folder named like the target
            // ("IceCubesApp" target, "IceCubesApp/App/Router" folder -> "IceCubesApp/App/Router", not ".../IceCubesApp/...").
            let label = folder
            let id = "\(parent.id)/\(label)"
            let info = ComponentInfo(id: id, name: "\(parent.name)/\(label)", kind: .folder, module: parent.module,
                                     parent: parent.id, isTest: parent.isTest || isTestPath(folder), layer: parent.layer)
            layout.components[id] = info
            for f in gfiles { layout.fileComponent[f] = id }
            split(parent: info, files: gfiles, depth: depth + 1, config: config, layout: &layout)
        }
    }

    private static func commonDir(_ files: [String]) -> String {
        guard var prefix = files.first.map({ $0.split(separator: "/").dropLast().map(String.init) }) else { return "" }
        for f in files.dropFirst() {
            let dirs = f.split(separator: "/").dropLast().map(String.init)
            var n = 0
            while n < prefix.count && n < dirs.count && prefix[n] == dirs[n] { n += 1 }
            prefix = Array(prefix.prefix(n))
        }
        return prefix.joined(separator: "/")
    }

    static func isTestPath(_ p: String) -> Bool {
        p.split(separator: "/").contains { $0.hasSuffix("Tests") || $0 == "Tests" || $0.hasSuffix("Test") }
    }

    // MARK: SPM

    struct SPMTarget {
        var name: String
        var path: String
        var isTest: Bool
        var deps: [(name: String, package: String?)]
        /// swiftSettings / plugins entries, one key per entry.
        var settings: [String: String] = [:]
    }

    /// Reads a package's targets. By default the manifest is parsed as syntax, which is fast and never runs
    /// repository code. With `dumpPackage` it is evaluated by `swift package dump-package` (exact, but it
    /// compiles and runs Package.swift), falling back to syntax on failure.
    static func spmTargets(root: String, packageDir: String, dumpPackage: Bool, layout: inout ComponentLayout) -> [SPMTarget] {
        let absDir = join(root, packageDir)
        if dumpPackage {
            if let json = try? Shell.run(["swift", "package", "dump-package", "--package-path", absDir]),
               let targets = parseDumpPackage(json) {
                return targets
            }
            layout.warnings.append(Warning(kind: "manifest-parsed-syntactically",
                message: "`swift package dump-package` failed; read targets from Package.swift syntax instead.",
                file: join(packageDir, "Package.swift")))
        }
        guard let text = try? String(contentsOfFile: join(absDir, "Package.swift"), encoding: .utf8) else { return [] }
        return parseManifestSyntax(text)
    }

    static func parseDumpPackage(_ data: Data) -> [SPMTarget]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let targets = obj["targets"] as? [[String: Any]] else { return nil }
        var result: [SPMTarget] = []
        for t in targets {
            guard let name = t["name"] as? String else { continue }
            let type = t["type"] as? String ?? "regular"
            if type == "plugin" || type == "binary" || type == "system" { continue }
            let isTest = type == "test"
            let path = t["path"] as? String ?? (isTest ? "Tests/\(name)" : "Sources/\(name)")
            var deps: [(String, String?)] = []
            for d in t["dependencies"] as? [[String: Any]] ?? [] {
                if let byName = d["byName"] as? [Any], let n = byName.first as? String { deps.append((n, nil)) }
                if let target = d["target"] as? [Any], let n = target.first as? String { deps.append((n, nil)) }
                if let product = d["product"] as? [Any], let n = product.first as? String {
                    deps.append((n, (product.count > 1 ? product[1] as? String : nil)?.lowercased()))
                }
            }
            var settings: [String: String] = [:]
            for st in t["settings"] as? [[String: Any]] ?? [] {
                if let d = try? JSONSerialization.data(withJSONObject: st, options: [.sortedKeys]) {
                    settings[String(decoding: d, as: UTF8.self)] = "on"
                }
            }
            result.append(SPMTarget(name: name, path: path, isTest: isTest, deps: deps, settings: settings))
        }
        return result
    }

    /// Fallback: read `.target(name:path:dependencies:)` calls from the manifest's syntax.
    static func parseManifestSyntax(_ text: String) -> [SPMTarget] {
        let tree = Parser.parse(source: text)
        var result: [SPMTarget] = []
        final class V: SyntaxVisitor {
            var calls: [FunctionCallExprSyntax] = []
            override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
                calls.append(node)
                return .visitChildren
            }
        }
        let v = V(viewMode: .sourceAccurate)
        v.walk(tree)
        func stringArg(_ call: FunctionCallExprSyntax, _ label: String) -> String? {
            call.arguments.first { $0.label?.text == label }?.expression.as(StringLiteralExprSyntax.self)?
                .segments.trimmedDescription
        }
        for call in v.calls {
            guard let member = call.calledExpression.as(MemberAccessExprSyntax.self) else { continue }
            let kind = member.declName.baseName.text
            guard ["target", "executableTarget", "testTarget", "macro"].contains(kind),
                  let name = stringArg(call, "name"),
                  !isInsideDependencies(call) else { continue }
            let isTest = kind == "testTarget"
            var deps: [(String, String?)] = []
            if let arr = call.arguments.first(where: { $0.label?.text == "dependencies" })?.expression.as(ArrayExprSyntax.self) {
                for el in arr.elements {
                    if let s = el.expression.as(StringLiteralExprSyntax.self) {
                        deps.append((s.segments.trimmedDescription, nil))
                    } else if let c = el.expression.as(FunctionCallExprSyntax.self),
                              let n = stringArg(c, "name") {
                        deps.append((n, stringArg(c, "package")?.lowercased()))
                    }
                }
            }
            let path = stringArg(call, "path") ?? (isTest ? "Tests/\(name)" : "Sources/\(name)")
            var settings: [String: String] = [:]
            for label in ["swiftSettings", "plugins"] {
                guard let arg = call.arguments.first(where: { $0.label?.text == label }) else { continue }
                if let arr = arg.expression.as(ArrayExprSyntax.self) {
                    for el in arr.elements { settings["\(label): " + el.expression.trimmedDescription] = "on" }
                } else {
                    // A variable or computed expression: track its text.
                    settings["\(label): " + arg.expression.trimmedDescription] = "on"
                }
            }
            result.append(SPMTarget(name: name, path: path, isTest: isTest, deps: deps, settings: settings))
        }
        return result
    }

    /// `.target(name:)` is also how a target dependency is written; those sit inside a `dependencies:` argument.
    private static func isInsideDependencies(_ node: some SyntaxProtocol) -> Bool {
        var cur = node.parent
        while let n = cur {
            if let labeled = n.as(LabeledExprSyntax.self), labeled.label?.text == "dependencies" { return true }
            cur = n.parent
        }
        return false
    }

    // MARK: Xcode

    static func xcodeTargets(root: String, projPath: String, unassigned: Set<String>, layout: inout ComponentLayout,
                             claims: inout [String: [(id: String, priority: Int)]]) {
        let projDir = (projPath as NSString).deletingLastPathComponent
        let absProjDir = join(root, projDir)
        let proj: XcodeProj
        do {
            proj = try XcodeProj(path: Path(join(root, projPath)))
        } catch {
            layout.warnings.append(Warning(kind: "xcodeproj-unreadable", message: "\(error)", file: projPath))
            return
        }
        let rootPrefix = (root as NSString).standardizingPath + "/"
        func rel(_ abs: String) -> String {
            let s = (abs as NSString).standardizingPath
            return s.hasPrefix(rootPrefix) ? String(s.dropFirst(rootPrefix.count)) : s
        }
        for target in proj.pbxproj.nativeTargets {
            let name = target.name
            let isTest = target.productType == .unitTestBundle || target.productType == .uiTestBundle
            let priority: Int
            switch target.productType {
            case .application: priority = 0
            case .framework, .staticLibrary, .staticFramework, .dynamicLibrary: priority = 1
            case .unitTestBundle, .uiTestBundle: priority = 3
            default: priority = 2
            }
            var id = "xcode:\(name)"
            if layout.components[id] != nil { id = "xcode:\(projDir)/\(name)" }
            let module = moduleName(target) ?? sanitize(name)
            layout.components[id] = ComponentInfo(id: id, name: name, kind: .xcodeTarget, module: module,
                                                  parent: nil, isTest: isTest, layer: nil)
            layout.moduleComponent[module] = layout.moduleComponent[module] ?? id

            layout.targetSettings[id] = (projPath, buildSettings(project: proj, target: target))

            var files: [String] = []
            for bf in (try? target.sourcesBuildPhase())??.files ?? [] {
                if let fe = bf.file, let p = try? fe.fullPath(sourceRoot: Path(absProjDir)) {
                    files.append(rel(p.string))
                }
            }
            for group in target.fileSystemSynchronizedGroups ?? [] {
                guard let p = try? group.fullPath(sourceRoot: Path(absProjDir)) else { continue }
                let dir = rel(p.string)
                var excluded = Set<String>()
                for ex in group.exceptions ?? [] {
                    if let set = ex as? PBXFileSystemSynchronizedBuildFileExceptionSet, set.target === target {
                        for m in set.membershipExceptions ?? [] { excluded.insert(join(dir, m)) }
                    }
                }
                for f in unassigned where f.hasPrefix(dir + "/") && !excluded.contains(f) {
                    files.append(f)
                }
            }
            for f in files where unassigned.contains(f) {
                claims[f, default: []].append((id, priority))
            }
            for dep in target.dependencies {
                if let t = dep.target?.name ?? dep.name {
                    layout.manifestDeps.append(ManifestDep(from: id, module: sanitize(t), file: projPath))
                }
            }
            for product in target.packageProductDependencies ?? [] {
                layout.manifestDeps.append(ManifestDep(from: id, module: product.productName, file: projPath))
                if let url = product.package?.repositoryURL {
                    layout.externalProducts[product.productName] = packageIdentity(url)
                }
            }
        }
    }

    /// Build settings that change how Swift code compiles or where it runs, per configuration,
    /// with target values overriding project values.
    static let trackedSettings: Set<String> = [
        "SWIFT_DEFAULT_ACTOR_ISOLATION", "SWIFT_STRICT_CONCURRENCY", "SWIFT_VERSION", "SWIFT_APPROACHABLE_CONCURRENCY",
        "OTHER_SWIFT_FLAGS", "SWIFT_ACTIVE_COMPILATION_CONDITIONS", "IPHONEOS_DEPLOYMENT_TARGET", "MACOSX_DEPLOYMENT_TARGET",
        "SWIFT_TREAT_WARNINGS_AS_ERRORS", "SWIFT_ENABLE_BARE_SLASH_REGEX", "CODE_SIGN_ENTITLEMENTS", "INFOPLIST_FILE",
        "PRODUCT_BUNDLE_IDENTIFIER",
    ]

    private static func buildSettings(project: XcodeProj, target: PBXNativeTarget) -> [String: String] {
        func values(_ list: XCConfigurationList?) -> [String: String] {
            var out: [String: String] = [:]
            for config in list?.buildConfigurations ?? [] {
                for (key, value) in config.buildSettings
                where trackedSettings.contains(key) || key.hasPrefix("SWIFT_UPCOMING_FEATURE_") {
                    let v: String
                    switch value {
                    case .string(let s): v = s
                    case .array(let a): v = a.joined(separator: " ")
                    }
                    out["\(config.name): \(key)"] = v
                }
            }
            return out
        }
        let projectLevel = values(project.pbxproj.rootObject?.buildConfigurationList)
        return projectLevel.merging(values(target.buildConfigurationList)) { _, t in t }
    }

    private static func moduleName(_ target: PBXNativeTarget) -> String? {
        for config in target.buildConfigurationList?.buildConfigurations ?? [] {
            if let m = config.buildSettings["PRODUCT_MODULE_NAME"], case .string(let s) = m, !s.contains("$") {
                return s
            }
        }
        return nil
    }

    static func sanitize(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
    }

    static func packageIdentity(_ url: String) -> String {
        var s = url
        if s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        return (s.split(separator: "/").last.map(String.init) ?? s).lowercased()
    }

    // MARK: File system

    static func findFiles(root: String, where match: (String) -> Bool) -> [String] {
        var result: [String] = []
        walk(root: root, rel: "") { rel, name, isDir in
            if !isDir && match(name) { result.append(rel) }
            return true
        }
        return result.sorted()
    }

    static func findDirs(root: String, suffix: String) -> [String] {
        var result: [String] = []
        walk(root: root, rel: "") { rel, name, isDir in
            if isDir && name.hasSuffix(suffix) {
                result.append(rel)
                return false
            }
            return true
        }
        return result.sorted()
    }

    /// Calls `visit(relPath, name, isDir)`; returning false skips a directory's contents.
    static func walk(root: String, rel: String, visit: (String, String, Bool) -> Bool) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: join(root, rel)) else { return }
        for name in names.sorted() {
            if skipDirs.contains(name) { continue }
            let r = join(rel, name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: join(root, r), isDirectory: &isDir)
            if visit(r, name, isDir.boolValue) && isDir.boolValue && !name.hasSuffix(".xcodeproj") && !name.hasSuffix(".xcworkspace") {
                walk(root: root, rel: r, visit: visit)
            }
        }
    }
}

func join(_ a: String, _ b: String) -> String {
    if a.isEmpty || a == "." { return b }
    if b.isEmpty { return a }
    return a + "/" + b
}
