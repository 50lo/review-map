import Foundation
import TOMLDecoder

/// Reads the literal parts of Gradle's two DSLs. It never evaluates build scripts or resolves versions.
enum KotlinComponents {
    struct Module {
        var path: String
        var dir: String
        var manifest: String
        var id: String { "gradle:" + path }
    }
    struct Dependency {
        var name: String
        var version: String?
        var isTest: Bool
    }
    struct Catalog {
        var libraries: [String: (name: String, version: String?)] = [:]
        var versions: [String: String] = [:]
        var plugins: [String: (id: String, version: String?)] = [:]
        var bundles: [String: [String]] = [:]
    }
    struct Token {
        var value: String
        var literal = false
    }

    static func add(root: String, files: [String], options: AnalyzeOptions, layout: inout ComponentLayout) {
        let modules = modules(root: root)
        let byDepth = modules.sorted {
            if $0.dir.count != $1.dir.count { return $0.dir.count > $1.dir.count }
            return $0.path > $1.path // An explicit projectDir at the root takes precedence over the root project.
        }
        let catalog = catalog(root: root)
        let rootSettings = settings(tokens(read(join(root, buildFile(root: root, dir: "")))), catalog: catalog)
        for module in modules {
            layout.components[module.id] = ComponentInfo(id: module.id, name: module.path, kind: .gradleModule,
                                                         module: nil, parent: nil, isTest: false, layer: nil)
            // Gradle project paths are manifest identities, not Kotlin package names.
            layout.moduleComponent[module.path] = module.id
        }
        func testComponent(_ module: Module) -> String {
            let id = module.id + ":tests"
            layout.components[id] = ComponentInfo(id: id, name: module.path + " tests", kind: .gradleModule,
                                                  module: nil, parent: nil, isTest: true, layer: nil)
            return id
        }
        for file in files {
            guard let module = byDepth.first(where: { $0.dir.isEmpty || file.hasPrefix($0.dir + "/") }) else { continue }
            let relative = module.dir.isEmpty ? file : String(file.dropFirst(module.dir.count + 1))
            layout.fileComponent[file] = isTestPath(relative) ? testComponent(module) : module.id
        }
        for module in modules {
            let script = tokens(read(join(root, module.manifest)))
            for dependency in dependencies(script, catalog: catalog, modules: modules) {
                let from = dependency.isTest ? testComponent(module) : module.id
                layout.manifestDeps.append(ManifestDep(from: from, module: dependency.name, file: module.manifest, language: "kotlin"))
                if !dependency.name.hasPrefix(":") { layout.externalProducts[dependency.name] = dependency.name }
            }
            let testID = module.id + ":tests"
            if layout.components[testID] != nil {
                layout.manifestDeps.append(ManifestDep(from: testID, module: module.path, file: module.manifest, language: "kotlin"))
            }
            var values = settings(script, catalog: catalog)
            if values["gradle kotlin"] == nil { values["gradle kotlin"] = rootSettings["gradle kotlin"] }
            layout.targetSettings[module.id] = TargetSettings(file: module.manifest, settings: values, language: "kotlin")
        }
    }

    static func isTestPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        if let src = parts.firstIndex(of: "src"), parts.indices.contains(src + 1) {
            let name = String(parts[src + 1])
            return ["test", "androidTest", "testFixtures"].contains(name) || name.hasSuffix("Test")
        }
        return false
    }

    static func modules(root: String) -> [Module] {
        let fm = FileManager.default
        let settingsPath = ["settings.gradle.kts", "settings.gradle"].first { fm.fileExists(atPath: join(root, $0)) }
        guard let settingsPath else {
            let builds = ComponentBuilder.findFiles(root: root) { $0 == "build.gradle.kts" || $0 == "build.gradle" }
                .filter { !$0.split(separator: "/").contains("build") && !$0.split(separator: "/").contains(".gradle") }
            guard builds.count == 1, let build = builds.first else { return [] }
            return [Module(path: ":", dir: (build as NSString).deletingLastPathComponent, manifest: build)]
        }
        let input = tokens(read(join(root, settingsPath)))
        var paths = Set<String>()
        var overrides: [String: String] = [:]
        for i in input.indices where !input[i].literal {
            if input[i].value == "include" {
                var j = i + 1
                let parenthesized = j < input.count && input[j].value == "("
                if parenthesized { j += 1 }
                let firstArgument = j
                while j < input.count && input[j].value != ")" && (parenthesized || input[j].value != "\n") {
                    var next = j + 1
                    while parenthesized && next < input.count && input[next].value == "\n" { next += 1 }
                    var previous = j - 1
                    while previous >= firstArgument && input[previous].value == "\n" { previous -= 1 }
                    let startsArgument = previous < firstArgument || input[previous].value == ","
                    let endsArgument = next == input.count || [",", ")", "\n", ";"].contains(input[next].value)
                    if startsArgument, endsArgument, input[j].literal, let path = projectPath(input[j].value) { paths.insert(path) }
                    j += 1
                }
            }
            if input[i].value == "project", i + 6 < input.count,
               input[i + 1].value == "(", input[i + 2].literal, input[i + 3].value == ")",
               input[i + 4].value == ".", input[i + 5].value == "projectDir", input[i + 6].value == "=",
               let path = projectPath(input[i + 2].value) {
                let end = input[(i + 7)...].firstIndex { $0.value == "\n" || $0.value == ";" } ?? input.count
                let expression = Array(input[(i + 7)..<end])
                let values = expression.filter(\.literal)
                let shape = expression.map { $0.literal ? "<string>" : $0.value }
                let literalForms = [["<string>"], ["file", "(", "<string>", ")"],
                                    ["File", "(", "rootDir", ",", "<string>", ")"],
                                    ["new", "File", "(", "rootDir", ",", "<string>", ")"]]
                if values.count == 1, literalForms.contains(shape), let dir = safeDirectory(values[0].value) { overrides[path] = dir }
            }
        }
        let rootBuild = buildFile(root: root, dir: "")
        if fm.fileExists(atPath: join(root, rootBuild)) { paths.insert(":") }
        return paths.sorted().map { path in
            let dir = overrides[path] ?? path.split(separator: ":").joined(separator: "/")
            return Module(path: path, dir: dir, manifest: buildFile(root: root, dir: dir))
        }
    }

    private static func projectPath(_ value: String) -> String? {
        guard !value.isEmpty, !value.contains("$"), !value.contains("/"), !value.contains("..") else { return nil }
        return value.hasPrefix(":") ? value : ":" + value
    }
    private static func safeDirectory(_ value: String) -> String? {
        guard !value.hasPrefix("/"), !value.contains("$"), !value.split(separator: "/").contains("..") else { return nil }
        let normalized = (value as NSString).standardizingPath
        return normalized == "." ? "" : normalized
    }
    private static func buildFile(root: String, dir: String) -> String {
        let kotlin = join(dir, "build.gradle.kts")
        return FileManager.default.fileExists(atPath: join(root, kotlin)) ? kotlin : join(dir, "build.gradle")
    }
    private static func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    static func catalog(root: String) -> Catalog {
        guard let table = try? TOMLTable(source: read(join(root, "gradle/libs.versions.toml"))),
              let values = try? [String: Any](table) else { return Catalog() }
        var result = Catalog()
        for (name, value) in values["versions"] as? [String: Any] ?? [:] {
            if let string = value as? String { result.versions[accessor(name)] = string }
            else if let version = value as? [String: Any], let string = version["strictly"] as? String ?? version["require"] as? String {
                result.versions[accessor(name)] = string
            }
        }
        func version(_ value: Any?) -> String? {
            if let string = value as? String { return string }
            guard let value = value as? [String: Any] else { return nil }
            if let ref = value["ref"] as? String { return result.versions[accessor(ref)] }
            return value["strictly"] as? String ?? value["require"] as? String
        }
        for (alias, value) in values["libraries"] as? [String: Any] ?? [:] {
            if let string = value as? String, let library = coordinate(string) {
                result.libraries[accessor(alias)] = library
            } else if let fields = value as? [String: Any] {
                let name = fields["module"] as? String ?? ((fields["group"] as? String).flatMap { group in
                    (fields["name"] as? String).map { group + ":" + $0 }
                })
                if let name { result.libraries[accessor(alias)] = (name, version(fields["version"])) }
            }
        }
        for (alias, value) in values["plugins"] as? [String: [String: Any]] ?? [:] {
            if let id = value["id"] as? String { result.plugins[accessor(alias)] = (id, version(value["version"])) }
        }
        for (alias, value) in values["bundles"] as? [String: [String]] ?? [:] { result.bundles[accessor(alias)] = value.map(accessor) }
        return result
    }
    private static func accessor(_ alias: String) -> String { alias.replacingOccurrences(of: "-", with: ".").replacingOccurrences(of: "_", with: ".") }
    private static func projectAccessor(_ path: String) -> String {
        path.split(separator: ":").map { segment in
            let words = segment.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
            return (words.first ?? "") + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        }.joined(separator: ".")
    }
    private static func coordinate(_ value: String) -> (name: String, version: String?)? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty, !value.contains("$"), !value.contains(" ") else { return nil }
        return (parts.prefix(2).joined(separator: ":"), parts.count > 2 && !parts[2].isEmpty ? String(parts[2]) : nil)
    }

    static func dependencies(_ input: [Token], catalog: Catalog, modules: [Module]) -> [Dependency] {
        var result: [Dependency] = []
        // Restrict dependency matching to dependencies blocks, including KMP source-set blocks.
        for start in input.indices where input[start].value == "dependencies" && !input[start].literal {
            guard start + 1 < input.count, input[start + 1].value == "{" else { continue }
            var depth = 1
            var i = start + 2
            while i < input.count && depth > 0 {
                let token = input[i]
                if !token.literal && token.value == "{" { depth += 1 }
                if !token.literal && token.value == "}" { depth -= 1 }
                let lower = token.value.lowercased()
                let configuration = ["implementation", "api", "compileonly", "runtimeonly", "compile", "runtime", "kapt", "ksp", "annotationprocessor"]
                    .contains { lower == $0 || lower.hasSuffix($0) }
                guard depth == 1, !token.literal, configuration else { i += 1; continue }
                var end = i + 1
                var parens = 0
                while end < input.count {
                    let value = input[end].value
                    if !input[end].literal {
                        if value == "(" { parens += 1 }
                        if value == ")" { parens -= 1 }
                        if parens <= 0 && ["\n", ";", "}"].contains(value) { break }
                    }
                    end += 1
                }
                let args = Array(input[(i + 1)..<end])
                let isTest = lower.contains("test") || isTestBlock(input, before: start)
                var j = 0
                while j < args.count {
                    if args[j].value == "project", !args[j].literal, j + 2 < args.count,
                       args[j + 1].value == "(", args[j + 2].literal, let path = projectPath(args[j + 2].value) {
                        result.append(Dependency(name: path, isTest: isTest))
                        j += 3
                    } else if args[j].value == "projects", !args[j].literal {
                        let (name, next) = dotted(args, from: j)
                        if let module = modules.first(where: { "projects." + projectAccessor($0.path) == name }) {
                            result.append(Dependency(name: module.path, isTest: isTest))
                        }
                        j = next
                    } else if args[j].value == "libs", !args[j].literal {
                        let (name, next) = dotted(args, from: j)
                        let key = String(name.dropFirst("libs.".count))
                        let keys = key.hasPrefix("bundles.") ? catalog.bundles[String(key.dropFirst("bundles.".count))] ?? [] : [key]
                        for key in keys {
                            if let library = catalog.libraries[key] { result.append(Dependency(name: library.name, version: library.version, isTest: isTest)) }
                        }
                        j = next
                    } else {
                        if args[j].literal, let library = coordinate(args[j].value) { result.append(Dependency(name: library.name, version: library.version, isTest: isTest)) }
                        j += 1
                    }
                }
                i = end
            }
        }
        return result
    }

    private static func isTestBlock(_ input: [Token], before end: Int) -> Bool {
        var scopes: [Bool] = []
        var statement: [String] = []
        for token in input.prefix(end) {
            if !token.literal && token.value == "{" {
                scopes.append((scopes.last ?? false) || statement.contains { $0 == "test" || $0 == "testFixtures" || $0.hasSuffix("Test") })
                statement = []
            } else if !token.literal && token.value == "}" {
                if !scopes.isEmpty { scopes.removeLast() }
                statement = []
            } else if token.value == "\n" || token.value == ";" { statement = [] }
            else { statement.append(token.value) }
        }
        return (scopes.last ?? false) || statement.contains { $0.hasSuffix("Test") }
    }

    static func settings(_ input: [Token], catalog: Catalog) -> [String: String] {
        var result: [String: String] = [:]
        for i in input.indices where !input[i].literal {
            let key = input[i].value
            if ["minSdk", "minSdkVersion", "targetSdk", "targetSdkVersion", "compileSdk", "compileSdkVersion", "jvmTarget", "jvmToolchain"].contains(key) {
                var j = i + 1
                if j + 2 < input.count, input[j].value == ".", input[j + 1].value == "set", input[j + 2].value == "(" { j += 3 }
                while j < input.count && ["=", "(", "\n"].contains(input[j].value) { j += 1 }
                guard j < input.count else { continue }
                var value: String?
                if input[j].literal || Int(input[j].value) != nil { value = input[j].value }
                else if input[j].value == "libs" {
                    let (name, _) = dotted(input, from: j)
                    let reference = name.replacingOccurrences(of: "libs.versions.", with: "").replacingOccurrences(of: ".get", with: "")
                    value = catalog.versions[reference]
                } else if input[j].value == "JvmTarget" || input[j].value == "JavaVersion" {
                    let (name, _) = dotted(input, from: j)
                    value = name.split(separator: ".").last.map { String($0).replacingOccurrences(of: "JVM_", with: "").replacingOccurrences(of: "VERSION_", with: "").replacingOccurrences(of: "_", with: ".") }
                }
                if let value, !value.contains("$") {
                    let normalized = key.replacingOccurrences(of: "Version", with: "")
                    result["gradle " + (key == "jvmToolchain" ? "jvmTarget" : normalized)] = value
                }
            }
            if key == "libs" {
                let (name, _) = dotted(input, from: i)
                if name.hasPrefix("libs.plugins."), let plugin = catalog.plugins[String(name.dropFirst("libs.plugins.".count))], plugin.id.hasPrefix("org.jetbrains.kotlin.") {
                    result["gradle kotlin"] = plugin.version
                }
            }
            if ["kotlin", "id"].contains(key) {
                var end = i + 1
                while end < input.count && !["\n", "}"].contains(input[end].value) { end += 1 }
                let args = Array(input[(i + 1)..<end])
                let isKotlin = key == "kotlin" || args.contains { $0.literal && $0.value.hasPrefix("org.jetbrains.kotlin.") }
                if isKotlin, let version = args.firstIndex(where: { !$0.literal && $0.value == "version" }) {
                    let values = args.dropFirst(version + 1).drop { ["(", "="].contains($0.value) }
                    if let value = values.first, value.literal, !value.value.contains("$") { result["gradle kotlin"] = value.value }
                }
            }
        }
        return result
    }

    static func pinnedPackages(blobs: [String: String], dir: String) -> [String: String] {
        let modules = modules(root: dir)
        let catalog = catalog(root: dir)
        var versions: [String: Set<String>] = [:]
        for module in modules where blobs[module.manifest] != nil {
            for dependency in dependencies(tokens(read(join(dir, module.manifest))), catalog: catalog, modules: modules) {
                if let version = dependency.version { versions[dependency.name, default: []].insert(version) }
            }
        }
        return versions.mapValues { $0.sorted().joined(separator: ", ") }
    }

    static func package(ofModule module: String, pinned: Set<String>) -> String? {
        if pinned.contains(module) { return module }
        let matches = pinned.filter {
            let group = $0.split(separator: ":").first.map(String.init) ?? ""
            return !group.isEmpty && (module == group || module.hasPrefix(group + "."))
        }
        // Prefer the most specific group; artifacts in the same group remain indistinguishable.
        let longest = matches.map { $0.split(separator: ":")[0].count }.max()
        let specific = matches.filter { $0.split(separator: ":")[0].count == longest }
        if specific.count == 1 { return specific.first }
        let parts = module.split(separator: ".")
        return parts.isEmpty ? nil : parts.prefix(2).joined(separator: ".")
    }

    private static func dotted(_ input: [Token], from start: Int) -> (String, Int) {
        var value = input[start].value
        var end = start + 1
        while end + 1 < input.count && input[end].value == "." && !input[end + 1].literal && input[end + 1].value != "\n" {
            value += "." + input[end + 1].value
            end += 2
        }
        return (value, end)
    }

    /// A small lexer keeps comments and quoted strings from becoming fake Gradle declarations.
    static func tokens(_ source: String) -> [Token] {
        let chars = Array(source)
        var result: [Token] = []
        var i = 0
        while i < chars.count {
            let char = chars[i]
            if char == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
            } else if char == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                var depth = 1
                while i + 1 < chars.count && depth > 0 {
                    if chars[i] == "/" && chars[i + 1] == "*" { depth += 1; i += 2 }
                    else if chars[i] == "*" && chars[i + 1] == "/" { depth -= 1; i += 2 }
                    else { i += 1 }
                }
            } else if char == "\"" || char == "'" {
                let quote = char
                i += 1
                var value = ""
                while i < chars.count && chars[i] != quote {
                    if chars[i] == "\\", i + 1 < chars.count { i += 1 }
                    value.append(chars[i]); i += 1
                }
                if i < chars.count { i += 1 }
                result.append(Token(value: value, literal: true))
            } else if char == "\n" { result.append(Token(value: "\n")); i += 1 }
            else if char.isWhitespace { i += 1 }
            else if char.isLetter || char.isNumber || char == "_" {
                let start = i
                while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") { i += 1 }
                result.append(Token(value: String(chars[start..<i])))
            } else { result.append(Token(value: String(char))); i += 1 }
        }
        return result
    }
}
