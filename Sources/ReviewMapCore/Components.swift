import Foundation

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
    var language: String
}

/// Target-level build settings that change how code compiles, and the manifest that sets them.
struct TargetSettings {
    var file: String
    var settings: [String: String]
    var language: String
}

/// How one side's source tree is cut into components.
struct ComponentLayout {
    var components: [String: ComponentInfo] = [:]
    var fileComponent: [String: String] = [:]
    /// Module name -> the target-level component that owns it.
    var moduleComponent: [String: String] = [:]
    var manifestDeps: [ManifestDep] = []
    /// Component id -> its build settings.
    var targetSettings: [String: TargetSettings] = [:]
    /// External product name -> package identity.
    var externalProducts: [String: String] = [:]
    var warnings: [Warning] = []
}

enum ComponentBuilder {
    static let skipDirs: Set<String> = [".git", ".build", "Pods", "Carthage", "DerivedData", "node_modules", ".swiftpm", "SourcePackages"]

    static func build(root: String, files: [String], languages: [Language], config: inout Config, options: AnalyzeOptions) -> ComponentLayout {
        var layout = ComponentLayout()

        // 1. Components from each language's manifests.
        for lang in languages {
            lang.addComponents(root: root, files: files.filter(lang.isSource), options: options, layout: &layout)
        }

        // 2. Remaining files: folder components by top-level directory.
        for f in files where layout.fileComponent[f] == nil {
            let parts = f.split(separator: "/")
            let top = parts.count > 1 ? String(parts[0]) : "."
            let id = "folder:\(top)"
            if layout.components[id] == nil {
                layout.components[id] = ComponentInfo(id: id, name: top == "." ? "(root)" : top, kind: .folder,
                                                      module: nil, parent: nil, isTest: isTestPath(top), layer: nil)
            }
            layout.fileComponent[f] = id
        }

        // 3. Split large targets by folder.
        let targetFiles = Dictionary(grouping: files, by: { layout.fileComponent[$0]! })
        for (id, files) in targetFiles {
            guard let info = layout.components[id], info.kind != .folder || info.parent == nil else { continue }
            split(parent: info, files: files, depth: 1, config: config, layout: &layout)
        }

        // 4. reviewmap.yml rules override everything.
        if let rules = config.components, !rules.isEmpty {
            let matchers = rules.map { ($0, $0.paths.map(Glob.init)) }
            for f in files {
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

        // 5. Layers that name components take them (and their split folders) unless a rule already gave one.
        for layer in config.layers ?? [] {
            let globs = (layer.components ?? []).map(Glob.init)
            guard !globs.isEmpty else { continue }
            for (id, info) in layout.components where info.layer == nil && info.kind != .external {
                if globs.contains(where: { $0.matches(info.name) }) { layout.components[id]!.layer = layer.name }
            }
        }
        for (id, info) in layout.components where info.layer == nil {
            var p = info.parent
            while let pid = p, let parent = layout.components[pid] {
                if let l = parent.layer { layout.components[id]!.layer = l; break }
                p = parent.parent
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

    /// Test folders (`Tests`, `FooTests`, `__tests__`, `test`, `e2e`) and test files (`cart.test.ts`, `cart.spec.ts`).
    static func isTestPath(_ p: String) -> Bool {
        let parts = p.split(separator: "/")
        if parts.contains(where: { ["test", "tests", "__tests__", "__mocks__", "e2e"].contains($0) }) { return true }
        if let name = parts.last, name.contains(".test.") || name.contains(".spec.") { return true }
        return parts.contains { $0.hasSuffix("Tests") || $0 == "Tests" || $0.hasSuffix("Test") }
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
