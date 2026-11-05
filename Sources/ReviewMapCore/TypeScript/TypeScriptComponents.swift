import Foundation
import Yams

/// TypeScript's components: npm packages (every `package.json` with a name, except a workspace root) and
/// `tsconfig` projects outside them. A component's test files go to a test component of their own.
enum TypeScriptComponents {
    struct Project {
        var id: String
        var dir: String
        var name: String
        var kind: ComponentKind
        var module: String?
        /// The manifest the component's dependencies and settings come from.
        var manifest: String
        var package: [String: Any]?
    }

    static let dependencyFields = ["dependencies", "peerDependencies", "optionalDependencies"]

    static func add(root: String, files: [String], layout: inout ComponentLayout) {
        let projects = Self.projects(root: root)
        let byDepth = projects.sorted { $0.dir.count > $1.dir.count }
        var used = Set<String>()
        for f in files {
            guard let p = byDepth.first(where: { $0.dir.isEmpty || f.hasPrefix($0.dir + "/") }) else { continue }
            let rel = p.dir.isEmpty ? f : String(f.dropFirst(p.dir.count + 1))
            if ComponentBuilder.isTestPath(rel) {
                let id = p.id + ":tests"
                if layout.components[id] == nil {
                    layout.components[id] = ComponentInfo(id: id, name: p.name + " tests", kind: p.kind, module: p.module,
                                                          parent: nil, isTest: true, layer: nil)
                }
                layout.fileComponent[f] = id
            } else {
                layout.fileComponent[f] = p.id
            }
            used.insert(p.id)
        }
        let workspaceNames = Set(projects.compactMap(\.module))
        for p in projects {
            // A package without TypeScript files is still a module other packages can depend on.
            guard used.contains(p.id) || p.package != nil else { continue }
            layout.components[p.id] = ComponentInfo(id: p.id, name: p.name, kind: p.kind, module: p.module,
                                                    parent: nil, isTest: ComponentBuilder.isTestPath(p.dir), layer: nil)
            if let m = p.module { layout.moduleComponent[m] = layout.moduleComponent[m] ?? p.id }
            if let pkg = p.package {
                for field in dependencyFields + ["devDependencies"] {
                    for name in (pkg[field] as? [String: Any] ?? [:]).keys.sorted() where !workspaceNames.contains(name) {
                        layout.externalProducts[name] = name
                        // Type-only packages: `@types/node` types "node", `@types/babel__core` types "@babel/core".
                        if name.hasPrefix("@types/") {
                            let typed = String(name.dropFirst("@types/".count))
                            let module = typed.contains("__") ? "@" + typed.replacingOccurrences(of: "__", with: "/") : typed
                            if layout.externalProducts[module] == nil { layout.externalProducts[module] = name }
                        }
                    }
                }
                for field in dependencyFields {
                    for name in (pkg[field] as? [String: Any] ?? [:]).keys.sorted() {
                        layout.manifestDeps.append(ManifestDep(from: p.id, module: name, file: p.manifest, language: "typescript"))
                    }
                }
            }
            let settings = Self.settings(root: root, project: p)
            if !settings.isEmpty {
                layout.targetSettings[p.id] = TargetSettings(file: p.manifest, settings: settings, language: "typescript")
            }
        }
    }

    /// Packages, then `tsconfig.json` directories that no package covers.
    static func projects(root: String) -> [Project] {
        var out: [Project] = []
        let workspaceRoot = FileManager.default.fileExists(atPath: join(root, "pnpm-workspace.yaml"))
        for manifest in ComponentBuilder.findFiles(root: root, where: { $0 == "package.json" }) {
            let dir = (manifest as NSString).deletingLastPathComponent
            guard let pkg = readJSON(join(root, manifest)) else { continue }
            if dir.isEmpty && (pkg["workspaces"] != nil || workspaceRoot) { continue }
            guard let name = pkg["name"] as? String ?? (dir.isEmpty ? "(root)" : nil) else { continue }
            var id = "npm:\(name)"
            if out.contains(where: { $0.id == id }) { id = "npm:\(dir)/\(name)" }
            out.append(Project(id: id, dir: dir, name: name, kind: .npmPackage, module: pkg["name"] as? String,
                               manifest: manifest, package: pkg))
        }
        let packages = out
        for config in ComponentBuilder.findFiles(root: root, where: { $0 == "tsconfig.json" }) {
            let dir = (config as NSString).deletingLastPathComponent
            // A tsconfig.json in or above a package (such as a workspace root's base config) is no project of its own.
            guard !packages.contains(where: { $0.dir.isEmpty || dir.isEmpty || dir == $0.dir || dir.hasPrefix($0.dir + "/") || $0.dir.hasPrefix(dir + "/") })
            else { continue }
            out.append(Project(id: "tsconfig:\(dir.isEmpty ? "." : dir)", dir: dir, name: dir.isEmpty ? "(root)" : dir,
                               kind: .tsconfig, module: nil, manifest: config, package: nil))
        }
        return out
    }

    /// A package's entry points and engines, and the compiler options of the project's own `tsconfig.json`.
    private static func settings(root: String, project p: Project) -> [String: String] {
        var out: [String: String] = [:]
        if let pkg = p.package {
            for field in ["type", "main", "module", "types", "typings", "exports", "bin", "sideEffects", "engines"] {
                if let v = pkg[field] { out["package.json \(field)"] = stringify(v) }
            }
        }
        if let config = readJSON(join(root, join(p.dir, "tsconfig.json"))),
           let options = config["compilerOptions"] as? [String: Any] {
            for (k, v) in options { out["tsconfig \(k)"] = stringify(v) }
        }
        return out
    }

    private static func stringify(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .fragmentsAllowed]) {
            return String(decoding: d, as: UTF8.self)
        }
        return "\(v)"
    }

    // MARK: Lockfiles

    /// Versions of the packages listed in any package.json, from package-lock.json, pnpm-lock.yaml,
    /// yarn.lock, or bun.lock. Transitive packages are left out: a regenerated lockfile would otherwise list
    /// hundreds of bumps.
    static func pinnedPackages(blobs: [String: String], dir: String) -> [String: String] {
        let paths = blobs.keys.filter { !$0.split(separator: "/").contains("node_modules") }.sorted()
        var direct = Set<String>()
        for path in paths where (path as NSString).lastPathComponent == "package.json" {
            guard let pkg = readJSON(join(dir, path)) else { continue }
            for field in dependencyFields + ["devDependencies"] {
                direct.formUnion((pkg[field] as? [String: Any] ?? [:]).keys)
            }
        }
        var versions: [String: Set<String>] = [:]
        func pin(_ name: String, _ version: String) {
            guard direct.contains(name), !version.isEmpty, !version.hasPrefix("link:"), !version.hasPrefix("workspace:") else { return }
            versions[name, default: []].insert(version)
        }
        for path in paths {
            let file = join(dir, path)
            switch (path as NSString).lastPathComponent {
            case "package-lock.json":
                guard let lock = readJSON(file) else { continue }
                for (key, value) in lock["packages"] as? [String: Any] ?? [:] {
                    // Only packages hoisted to the top: "node_modules/react", "node_modules/@scope/pkg".
                    guard key.hasPrefix("node_modules/") else { continue }
                    let name = String(key.dropFirst("node_modules/".count))
                    guard !name.contains("node_modules/") else { continue }
                    if let v = (value as? [String: Any])?["version"] as? String { pin(name, v) }
                }
                for (name, value) in lock["dependencies"] as? [String: Any] ?? [:] {
                    if let v = (value as? [String: Any])?["version"] as? String { pin(name, v) }
                }
            case "pnpm-lock.yaml":
                // pnpm 10 and later put the lockfile of pnpm itself in a first YAML document.
                guard let text = try? String(contentsOfFile: file, encoding: .utf8),
                      let documents = try? Yams.load_all(yaml: text) else { continue }
                for case let lock as [String: Any] in documents {
                    let importers = (lock["importers"] as? [String: Any])?.values.compactMap { $0 as? [String: Any] } ?? [lock]
                    for importer in importers {
                        for field in dependencyFields + ["devDependencies"] {
                            for (name, value) in importer[field] as? [String: Any] ?? [:] {
                                let raw = (value as? [String: Any])?["version"] ?? value
                                pin(name, String(describing: raw).split(separator: "(").first.map(String.init) ?? "")
                            }
                        }
                    }
                }
            case "yarn.lock":
                guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
                var names: [String] = []
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    if !line.hasPrefix(" ") && line.hasSuffix(":") && !line.hasPrefix("#") {
                        // `"react@^18.0.0", react@^18.2.0:` or `"react@npm:^18.2.0":`
                        names = line.dropLast().split(separator: ",").map { d in
                            let s = d.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                            let at = s.dropFirst().firstIndex(of: "@") ?? s.endIndex
                            return String(s[..<at])
                        }
                    } else if let r = line.range(of: #"^\s+version:? "?([^"]+)"?$"#, options: .regularExpression) {
                        let v = line[r].trimmingCharacters(in: .whitespaces).dropFirst("version".count)
                            .trimmingCharacters(in: CharacterSet(charactersIn: ": \""))
                        for n in names { pin(n, v) }
                        names = []
                    }
                }
            case "bun.lock":
                guard let lock = readJSON(file) else { continue }
                for (name, value) in lock["packages"] as? [String: Any] ?? [:] {
                    guard let spec = (value as? [Any])?.first as? String, let at = spec.dropFirst().lastIndex(of: "@") else { continue }
                    pin(name, String(spec[spec.index(after: at)...]))
                }
            default:
                break
            }
        }
        return versions.mapValues { $0.sorted().joined(separator: ", ") }
    }

    // MARK: JSON

    /// Reads JSON that may carry comments and trailing commas, as `tsconfig.json` and `bun.lock` do.
    static func readJSON(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return obj }
        let cleaned = stripJSONComments(String(decoding: data, as: UTF8.self))
        return (try? JSONSerialization.jsonObject(with: Data(cleaned.utf8))) as? [String: Any]
    }

    static func stripJSONComments(_ text: String) -> String {
        var out = ""
        let chars = Array(text)
        var i = 0
        var inString = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if c == "\\", i + 1 < chars.count { out.append(chars[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; out.append(c); i += 1; continue }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            if c == "," {
                // Drop a comma that only whitespace separates from a closing bracket.
                var j = i + 1
                while j < chars.count && chars[j].isWhitespace { j += 1 }
                if j < chars.count && (chars[j] == "}" || chars[j] == "]") { i += 1; continue }
            }
            out.append(c)
            i += 1
        }
        return out
    }
}
