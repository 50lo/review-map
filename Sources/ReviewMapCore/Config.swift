import Foundation
import Yams

/// Optional `reviewmap.yml` in the target repo (read from the head tree) or passed with --config.
///
///     components:
///       - name: Checkout
///         paths: ["App/Features/Checkout/**"]
///         layer: domain
///     split:
///       threshold: 30   # targets with more source files than this are split by folder
///       maxDepth: 3
///     layers:           # top to bottom: a component may use its own layer and the ones below it
///       - name: app
///         components: ["App", "App/*"]   # component names, as globs
///       - name: domain               # also gets the components whose rule above says `layer: domain`
///       - name: core
///         components: ["Networking", "Persistence"]
///     exclude: ["**/Pods/**"]
///     generated: ["**/*.generated.swift"]
///     index:            # exact references from a build (see IndexOptions)
///       enabled: true
///       project: App.xcworkspace
///       scheme: App
///       destination: "generic/platform=iOS Simulator"
///       targets: ["//ios:App"]   # Bazel
public struct Config: Codable, Equatable {
    public struct ComponentRule: Codable, Equatable {
        public var name: String
        public var paths: [String]
        public var layer: String?
    }
    public struct Layer: Codable, Equatable {
        public var name: String
        /// Component names (globs) that belong to the layer, on top of rules that name it.
        public var components: [String]?
    }
    public struct Split: Codable, Equatable {
        public var threshold: Int?
        public var maxDepth: Int?
    }
    public struct Index: Codable, Equatable {
        public var enabled: Bool?
        public var builder: String?
        public var project: String?
        public var scheme: String?
        public var destination: String?
        /// Bazel targets to build (default: top_level_targets of the repo's rules_xcodeproj `xcodeproj` rule).
        public var targets: [String]?
        /// Extra arguments for `bazel build`, such as a config: ["--config=sim"].
        public var bazelArgs: [String]?
    }

    public var components: [ComponentRule]?
    public var layers: [Layer]?
    public var split: Split?
    public var exclude: [String]?
    public var generated: [String]?
    public var index: Index?

    public init() {}

    public static func load(path: String) throws -> Config {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return Config() }
        return try YAMLDecoder().decode(Config.self, from: text)
    }

    /// The position of a layer, 0 at the top; nil when `layers` doesn't list it.
    func layerRank(_ name: String?) -> Int? {
        guard let name else { return nil }
        return layers?.firstIndex { $0.name == name }
    }

    var splitThreshold: Int { split?.threshold ?? 30 }
    var splitMaxDepth: Int { split?.maxDepth ?? 3 }

    static let defaultExcludes = [
        "**/.build/**", "**/Pods/**", "**/Carthage/**", "**/DerivedData/**", "**/node_modules/**",
        "**/SourcePackages/**", "**/.swiftpm/**",
    ]
    /// Each language adds its own generated-file patterns.
    static let defaultGenerated = ["**/Generated/**"]

    lazy var excludeMatchers: [Glob] = (Config.defaultExcludes + (exclude ?? [])).map(Glob.init)
    lazy var generatedMatchers: [Glob] = (Config.defaultGenerated + (generated ?? [])).map(Glob.init)

    enum CodingKeys: String, CodingKey {
        case components, layers, split, exclude, generated, index
    }
}

/// Minimal glob: `**` matches any number of path segments, `*` anything but `/`, `?` one character.
struct Glob: Equatable {
    let pattern: String
    let regex: NSRegularExpression

    init(_ pattern: String) {
        self.pattern = pattern
        var re = "^"
        var chars = Array(pattern)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "*" {
                if i + 1 < chars.count && chars[i + 1] == "*" {
                    // "**/" matches zero or more directories
                    if i + 2 < chars.count && chars[i + 2] == "/" {
                        re += "(?:.*/)?"
                        i += 3
                        continue
                    }
                    re += ".*"
                    i += 2
                    continue
                }
                re += "[^/]*"
            } else if c == "?" {
                re += "[^/]"
            } else {
                re += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        re += "$"
        chars.removeAll()
        // swiftlint:disable:next force_try
        regex = try! NSRegularExpression(pattern: re)
    }

    func matches(_ path: String) -> Bool {
        regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    static func == (a: Glob, b: Glob) -> Bool { a.pattern == b.pattern }
}
