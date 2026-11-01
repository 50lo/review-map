import Foundation
import Yams

/// Optional `reviewmap.yml` in the target repo (read from the head tree) or passed with --config.
///
///     components:
///       - name: Checkout
///         paths: ["App/Features/Checkout/**"]
///         layer: domain
///     split:
///       threshold: 30   # targets with more Swift files than this are split by folder
///       maxDepth: 3
///     exclude: ["**/Pods/**"]
///     generated: ["**/*.generated.swift"]
public struct Config: Codable, Equatable {
    public struct ComponentRule: Codable, Equatable {
        public var name: String
        public var paths: [String]
        public var layer: String?
    }
    public struct Split: Codable, Equatable {
        public var threshold: Int?
        public var maxDepth: Int?
    }

    public var components: [ComponentRule]?
    public var split: Split?
    public var exclude: [String]?
    public var generated: [String]?

    public init() {}

    public static func load(path: String) throws -> Config {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return Config() }
        return try YAMLDecoder().decode(Config.self, from: text)
    }

    var splitThreshold: Int { split?.threshold ?? 30 }
    var splitMaxDepth: Int { split?.maxDepth ?? 3 }

    static let defaultExcludes = [
        "**/.build/**", "**/Pods/**", "**/Carthage/**", "**/DerivedData/**", "**/node_modules/**",
        "**/SourcePackages/**", "**/.swiftpm/**",
    ]
    static let defaultGenerated = [
        "**/Generated/**", "**/*.generated.swift", "**/R.generated.swift", "**/*+CoreDataProperties.swift",
        "**/*.pb.swift", "**/*.grpc.swift",
    ]

    lazy var excludeMatchers: [Glob] = (Config.defaultExcludes + (exclude ?? [])).map(Glob.init)
    lazy var generatedMatchers: [Glob] = (Config.defaultGenerated + (generated ?? [])).map(Glob.init)

    enum CodingKeys: String, CodingKey {
        case components, split, exclude, generated
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
