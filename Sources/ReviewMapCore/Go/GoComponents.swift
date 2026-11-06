import Foundation

/// Go's components: a package is a directory, named by its import path, inside the module of the nearest
/// `go.mod` above it. A package's `_test.go` files go to a test component of their own. `go.mod` is read as
/// text, so no Go toolchain is needed.
enum GoComponents {
    struct Module {
        var dir: String
        var path: String
        var manifest: String
        var goVersion: String?
        var toolchain: String?
        /// Module path -> version, from `require`.
        var requires: [String: String] = [:]
        /// "old[@version]" -> "new[ version]", from `replace`.
        var replaces: [String: String] = [:]
    }

    static func add(root: String, files: [String], layout: inout ComponentLayout) {
        let modules = Self.modules(root: root).sorted { $0.dir.count > $1.dir.count }
        var packages: [String: (module: Module, importPath: String)] = [:]
        for f in files {
            let dir = (f as NSString).deletingLastPathComponent
            guard let m = modules.first(where: { $0.dir.isEmpty || dir == $0.dir || dir.hasPrefix($0.dir + "/") }) else { continue }
            let rel = m.dir.isEmpty ? dir : String(dir.dropFirst(m.dir.count).drop { $0 == "/" })
            let importPath = rel.isEmpty ? m.path : m.path + "/" + rel
            let id = "go:\(importPath)"
            packages[id] = (m, importPath)
            if f.hasSuffix("_test.go") {
                let testId = id + ":tests"
                if layout.components[testId] == nil {
                    layout.components[testId] = ComponentInfo(id: testId, name: importPath + " tests", kind: .goPackage,
                                                              module: importPath, parent: nil, isTest: true, layer: nil)
                }
                layout.fileComponent[f] = testId
            } else {
                layout.fileComponent[f] = id
            }
        }
        for (id, p) in packages {
            // A directory with only tests still anchors its import path.
            layout.components[id] = ComponentInfo(id: id, name: p.importPath, kind: .goPackage, module: p.importPath,
                                                  parent: nil, isTest: false, layer: nil)
            layout.moduleComponent[p.importPath] = id
        }
        // A module's settings belong to its root package, which anchors the module's import path even without Go files.
        for m in modules where packages.values.contains(where: { $0.module.dir == m.dir }) {
            let id = "go:\(m.path)"
            if layout.components[id] == nil {
                layout.components[id] = ComponentInfo(id: id, name: m.path, kind: .goPackage, module: m.path,
                                                      parent: nil, isTest: false, layer: nil)
                layout.moduleComponent[m.path] = id
            }
            layout.targetSettings[id] = TargetSettings(file: m.manifest, settings: settings(m), language: "go")
        }
    }

    /// Every `go.mod` outside `vendor` and `testdata`. A `go.work` lists modules that have a `go.mod` of their
    /// own, so they are found the same way.
    static func modules(root: String) -> [Module] {
        ComponentBuilder.findFiles(root: root, where: { $0 == "go.mod" }).compactMap { manifest in
            guard GoLanguage.isPackagePath(manifest),
                  let text = try? String(contentsOfFile: join(root, manifest), encoding: .utf8) else { return nil }
            return parse(text, dir: (manifest as NSString).deletingLastPathComponent, manifest: manifest)
        }
    }

    static func parse(_ text: String, dir: String, manifest: String) -> Module? {
        var m = Module(dir: dir, path: "", manifest: manifest)
        var block: String?
        for raw in text.split(separator: "\n") {
            // Without its comment (`// indirect`).
            let content = (raw.range(of: "//").map { String(raw[..<$0.lowerBound]) } ?? String(raw)).trimmingCharacters(in: .whitespaces)
            if content.isEmpty { continue }
            if content == ")" { block = nil; continue }
            var words = content.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if let b = block {
                words.insert(b, at: 0)
            } else if words.count == 2, words[1] == "(" {
                block = words[0]
                continue
            }
            guard let directive = words.first else { continue }
            let args = Array(words.dropFirst()).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            switch directive {
            case "module": if let p = args.first { m.path = p }
            case "go": m.goVersion = args.first
            case "toolchain": m.toolchain = args.first
            case "require" where args.count >= 2: m.requires[args[0]] = args[1]
            case "replace":
                guard let arrow = args.firstIndex(of: "=>") else { continue }
                m.replaces[args[..<arrow].joined(separator: "@")] = args[(arrow + 1)...].joined(separator: " ")
            default: break
            }
        }
        return m.path.isEmpty ? nil : m
    }

    /// Settings are keyed "go.mod <directive>", one per replaced module.
    static func settings(_ m: Module) -> [String: String] {
        var out: [String: String] = [:]
        if let v = m.goVersion { out["go.mod go"] = v }
        if let v = m.toolchain { out["go.mod toolchain"] = v }
        for (from, to) in m.replaces { out["go.mod replace \(from)"] = to }
        return out
    }

    // MARK: Pins

    /// Versions of the modules that any `go.mod` requires, direct and indirect, except the repo's own modules.
    static func pinnedPackages(blobs: [String: String], dir: String) -> [String: String] {
        var modules: [Module] = []
        for path in blobs.keys.sorted() where (path as NSString).lastPathComponent == "go.mod" && GoLanguage.isPackagePath(path) {
            guard let text = try? String(contentsOfFile: join(dir, path), encoding: .utf8),
                  let m = parse(text, dir: (path as NSString).deletingLastPathComponent, manifest: path) else { continue }
            modules.append(m)
        }
        let own = Set(modules.map(\.path))
        var versions: [String: Set<String>] = [:]
        for m in modules {
            for (path, version) in m.requires where !own.contains(path) { versions[path, default: []].insert(version) }
        }
        return versions.mapValues { $0.sorted().joined(separator: ", ") }
    }
}
