import Foundation
import TOMLDecoder

/// Cargo manifests are parsed without invoking Cargo. Workspace membership and dependency inheritance
/// are evaluated from the exported side, keeping name matching available without a Rust toolchain.
enum RustComponents {
    enum Value {
        case table([String: Value]), array([Value]), string(String), integer(Int64), boolean(Bool), number(Double)
        init(_ value: Any) {
            switch value {
            case let value as [String: Any]: self = .table(value.mapValues(Value.init))
            case let value as [Any]: self = .array(value.map(Value.init))
            case let value as String: self = .string(value)
            case let value as Bool: self = .boolean(value)
            case let value as Int64: self = .integer(value)
            case let value as Double: self = .number(value)
            default: self = .string(String(describing: value))
            }
        }
        var table: [String: Value] { if case .table(let x) = self { return x }; return [:] }
        var array: [Value] { if case .array(let x) = self { return x }; return [] }
        var string: String? { if case .string(let x) = self { return x }; return nil }
        var bool: Bool? { if case .boolean(let x) = self { return x }; return nil }
        subscript(_ key: String) -> Value? { table[key] }
        var canonical: String {
            switch self {
            case .table(let x): return x.keys.sorted().map { $0 + "=" + x[$0]!.canonical }.joined(separator: ";")
            case .array(let x): return "[" + x.map(\.canonical).joined(separator: ",") + "]"
            case .string(let x): return String(reflecting: x)
            case .integer(let x): return String(x)
            case .boolean(let x): return String(x)
            case .number(let x): return String(x)
            }
        }
    }
    struct Crate {
        var manifest: String
        var value: Value
        var workspace: Value?
        var workspaceDir: String?
        var dir: String { (manifest as NSString).deletingLastPathComponent }
        var name: String { value["package"]?["name"]?.string ?? "" }
        var module: String { name.replacingOccurrences(of: "-", with: "_") }
        func inheritsDependency(_ alias: String) -> Bool {
            let tables = [value] + (value["target"]?.table.values.map { $0 } ?? [])
            return tables.contains { table in
                ["dependencies", "dev-dependencies", "build-dependencies"].contains { table[$0]?[alias]?["workspace"]?.bool == true }
            }
        }
        var dependencies: [String: Value] {
            var out: [String: Value] = [:]
            var tables = [value]
            tables += value["target"]?.table.values.map { $0 } ?? []
            for table in tables {
                for kind in ["dependencies", "dev-dependencies", "build-dependencies"] {
                    for (name, dep) in table[kind]?.table ?? [:] {
                        if dep["workspace"]?.bool == true, let inherited = workspace?["workspace"]?["dependencies"]?[name] { out[name] = inherited }
                        else { out[name] = dep }
                    }
                }
            }
            return out
        }
    }
    static func read(_ path: String) -> Value? {
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        guard let table = try? TOMLTable(source: source), let values = try? [String: Any](table) else { return nil }
        return Value(values)
    }
    static func relative(_ path: String, to dir: String) -> String? {
        if dir.isEmpty { return path }
        if path == dir { return "" }
        return path.hasPrefix(dir + "/") ? String(path.dropFirst(dir.count + 1)) : nil
    }
    static func crates(root: String) -> [Crate] {
        let manifests = ComponentBuilder.findFiles(root: root, where: { $0 == "Cargo.toml" })
            .filter { !$0.split(separator: "/").contains("target") }
        let parsed = Dictionary(uniqueKeysWithValues: manifests.compactMap { path in read(join(root, path)).map { (path, $0) } })
        let workspaces = parsed.filter { $0.value["workspace"] != nil }.keys.sorted { $0.count > $1.count }
        return parsed.keys.sorted().compactMap { path in
            let value = parsed[path]!
            guard value["package"]?["name"]?.string != nil else { return nil }
            let dir = (path as NSString).deletingLastPathComponent
            var owner: String?
            for workspace in workspaces {
                let workspaceDir = (workspace as NSString).deletingLastPathComponent
                guard let rel = relative(dir, to: workspaceDir) else { continue }
                let ws = parsed[workspace]!["workspace"]!
                if workspace == path { owner = workspace; break }
                let excluded = ws["exclude"]?.array.compactMap(\.string).contains { Glob($0).matches(rel) } ?? false
                if excluded { return nil }
                let member = ws["members"]?.array.compactMap(\.string).contains { Glob($0).matches(rel) } ?? false
                if member { owner = workspace; break }
                // A nested manifest that is not a member belongs to no component in this workspace.
                return nil
            }
            return Crate(manifest: path, value: value, workspace: owner.flatMap { parsed[$0] }, workspaceDir: owner.map { ($0 as NSString).deletingLastPathComponent })
        }
    }
    struct Target { var name: String; var path: String; var library: Bool }
    static func targets(_ crate: Crate, files: Set<String>) -> [Target] {
        var out: [Target] = []
        let value = crate.value
        let lib = value["lib"]
        let libPath = join(crate.dir, lib?["path"]?.string ?? "src/lib.rs")
        if lib != nil || files.contains(libPath) {
            out.append(Target(name: lib?["name"]?.string ?? crate.module, path: libPath, library: true))
        }
        for bin in value["bin"]?.array ?? [] {
            let name = bin["name"]?.string ?? crate.name
            out.append(Target(name: name, path: join(crate.dir, bin["path"]?.string ?? (name == crate.name ? "src/main.rs" : "src/bin/\(name).rs")), library: false))
        }
        if value["package"]?["autobins"]?.bool != false {
            let main = join(crate.dir, "src/main.rs")
            if files.contains(main), !out.contains(where: { $0.path == main }) { out.append(Target(name: crate.name, path: main, library: false)) }
            for file in files.sorted() {
                guard let rel = relative(file, to: join(crate.dir, "src/bin")) else { continue }
                let parts = rel.split(separator: "/")
                let name: String
                if parts.count == 1 { name = (rel as NSString).deletingPathExtension }
                else if parts.count == 2 && parts[1] == "main.rs" { name = String(parts[0]) }
                else { continue }
                if !out.contains(where: { $0.path == file || $0.name == name }) { out.append(Target(name: name, path: file, library: false)) }
            }
        }
        return out
    }
    /// Follow declared modules from a target root, so a binary's `mod cli;` belongs to the binary.
    static func sourceFiles(target: Target, root: String, files: Set<String>) -> Set<String> {
        var visited = Set<String>()
        func visit(_ path: String, directory: String) {
            guard files.contains(path), visited.insert(path).inserted,
                  let source = try? String(contentsOfFile: join(root, path), encoding: .utf8) else { return }
            let parsed = RustExtractor.parse(path: path, source: source)
            for decl in parsed.decls where decl.traits.contains("rust-file-module") {
                let inline = decl.scope?.replacingOccurrences(of: ".", with: "/") ?? ""
                let dir = join(directory, inline)
                let custom = decl.attributes.first { $0.hasPrefix("path") }.flatMap { $0.split(separator: "\"").dropFirst().first.map(String.init) }
                let candidates: [String]
                if let custom { candidates = [Paths.resolve(custom, from: join(join((path as NSString).deletingLastPathComponent, inline), "_")) ?? ""] }
                else { candidates = [join(dir, decl.name + ".rs"), join(join(dir, decl.name), "mod.rs")] }
                if let child = candidates.first(where: files.contains) {
                    visit(child, directory: child.hasSuffix("/mod.rs") ? (child as NSString).deletingLastPathComponent : (child as NSString).deletingPathExtension)
                }
            }
        }
        visit(target.path, directory: (target.path as NSString).deletingLastPathComponent)
        return visited
    }
    static func add(root: String, files: [String], layout: inout ComponentLayout) {
        let crates = crates(root: root).sorted { $0.dir.count > $1.dir.count }
        let fileSet = Set(files)
        let manifestDirs = ComponentBuilder.findFiles(root: root, where: { $0 == "Cargo.toml" }).map { ($0 as NSString).deletingLastPathComponent }.sorted { $0.count > $1.count }
        for crate in crates {
            let targets = Self.targets(crate, files: fileSet)
            guard !targets.isEmpty else { continue }
            func id(_ t: Target) -> String { "cargo:\(crate.name)" + (targets.count == 1 ? "" : ":\(t.library ? "lib" : "bin"):\(t.name)") }
            let primary = targets.first(where: \.library) ?? targets[0]
            let primaryID = id(primary)
            let owned = Dictionary(uniqueKeysWithValues: targets.map { (id($0), sourceFiles(target: $0, root: root, files: fileSet)) })
            for target in targets {
                let targetID = id(target)
                layout.components[targetID] = ComponentInfo(id: targetID, name: target.name, kind: .cargoCrate,
                    module: target.name, parent: nil, isTest: false, layer: nil)
                layout.targetSettings[targetID] = TargetSettings(file: crate.manifest, settings: settings(crate), language: "rust")
                for (alias, dep) in crate.dependencies {
                    let module = alias.replacingOccurrences(of: "-", with: "_")
                    if let path = dep["path"]?.string {
                        let base = crate.inheritsDependency(alias) ? (crate.workspaceDir ?? crate.dir) : crate.dir
                        let dependencyDir = Paths.resolve(path, from: join(base, "Cargo.toml")) ?? ""
                        if let dependency = crates.first(where: { $0.dir == dependencyDir }),
                           let library = Self.targets(dependency, files: fileSet).first(where: \.library) {
                            layout.moduleAliases[targetID, default: [:]][module] = library.name
                        }
                    }
                    layout.manifestDeps.append(ManifestDep(from: targetID, module: module, file: crate.manifest, language: "rust"))
                    if dep["path"] == nil { layout.externalProducts[module] = dep["package"]?.string ?? alias }
                }
                if !target.library, primary.library {
                    layout.manifestDeps.append(ManifestDep(from: targetID, module: primary.name, file: crate.manifest, language: "rust"))
                }
            }
            if primary.library {
                layout.moduleComponent[primary.name] = primaryID
                if primary.name == crate.module { layout.moduleComponent[crate.module] = primaryID }
            }
            for file in files where layout.fileComponent[file] == nil {
                guard let rel = relative(file, to: crate.dir), manifestDirs.first(where: { relative(file, to: $0) != nil }) == crate.dir else { continue }
                let first = rel.split(separator: "/").first.map(String.init)
                if ["tests", "benches", "examples"].contains(first ?? "") {
                    let testID = "cargo:\(crate.name):tests"
                    layout.components[testID] = ComponentInfo(id: testID, name: crate.name + " tests", kind: .cargoCrate,
                        module: crate.module, parent: nil, isTest: true, layer: nil)
                    layout.fileComponent[file] = testID
                    layout.moduleAliases[testID] = layout.moduleAliases[primaryID]
                    for (alias, _) in crate.dependencies {
                        layout.manifestDeps.append(ManifestDep(from: testID, module: alias.replacingOccurrences(of: "-", with: "_"), file: crate.manifest, language: "rust"))
                    }
                    layout.manifestDeps.append(ManifestDep(from: testID, module: primary.name, file: crate.manifest, language: "rust"))
                } else {
                    let target = targets.first { $0.path == file } ?? targets.first { owned[id($0)]?.contains(file) == true } ?? targets.first { target in
                        let dir = (target.path as NSString).deletingLastPathComponent
                        return !target.library && dir != join(crate.dir, "src") && relative(file, to: dir) != nil
                    } ?? primary
                    layout.fileComponent[file] = id(target)
                }
            }
        }
    }
    static func settings(_ crate: Crate) -> [String: String] {
        var out: [String: String] = [:]
        for key in ["edition", "rust-version"] {
            var value = crate.value["package"]?[key]
            if value?["workspace"]?.bool == true { value = crate.workspace?["workspace"]?["package"]?[key] }
            if let value { out["Cargo.toml \(key)"] = value.canonical }
        }
        for key in ["features", "profile"] {
            if let value = crate.value[key] ?? (key == "profile" ? crate.workspace?[key] : nil) { out["Cargo.toml \(key)"] = value.canonical }
        }
        return out
    }
    static func pinnedPackages(blobs: [String: String], dir: String) -> [String: String] {
        let crates = crates(root: dir)
        let own = Set(crates.map(\.name))
        let requested = Set(crates.flatMap { $0.dependencies.map { alias, dep in dep["package"]?.string ?? alias } }).subtracting(own)
        var versions: [String: Set<String>] = [:]
        for path in blobs.keys where (path as NSString).lastPathComponent == "Cargo.lock" {
            for package in read(join(dir, path))?["package"]?.array ?? [] {
                guard let name = package["name"]?.string, requested.contains(name), let version = package["version"]?.string else { continue }
                versions[name, default: []].insert(version)
            }
        }
        return versions.mapValues { $0.sorted().joined(separator: ", ") }
    }
}
