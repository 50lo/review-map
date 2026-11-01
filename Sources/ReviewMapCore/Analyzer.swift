import Foundation

public struct AnalyzeOptions {
    public var repo: String
    public var base: String
    public var head: String
    public var useMergeBase: Bool
    public var configPath: String?
    /// Max references kept per edge in the output.
    public var maxRefsPerEdge: Int
    /// Evaluate Package.swift with `swift package dump-package` (runs repository code) instead of parsing its syntax.
    public var dumpPackage: Bool

    public init(repo: String, base: String, head: String, useMergeBase: Bool = true,
                configPath: String? = nil, maxRefsPerEdge: Int = 50, dumpPackage: Bool = false) {
        self.repo = repo
        self.base = base
        self.head = head
        self.useMergeBase = useMergeBase
        self.configPath = configPath
        self.maxRefsPerEdge = maxRefsPerEdge
        self.dumpPackage = dumpPackage
    }
}

public enum Analyzer {
    public static let version = "0.1.0"

    /// The top-level directory of the git repo that contains `repo`.
    public static func repoRoot(repo: String) throws -> String {
        try Shell.string(["git", "-C", repo, "rev-parse", "--show-toplevel"])
    }

    /// The branch checked out in the repo, or "HEAD" when it is detached or can't be read.
    public static func currentBranch(repo: String) -> String {
        (try? Shell.string(["git", "-C", repo, "rev-parse", "--abbrev-ref", "HEAD"])).flatMap { $0.isEmpty ? nil : $0 } ?? "HEAD"
    }

    public static func run(_ options: AnalyzeOptions, log: (String) -> Void = { _ in }) throws -> ChangeModel {
        let root = try Shell.string(["git", "-C", options.repo, "rev-parse", "--show-toplevel"])
        let git = GitRepo(root: root)
        let headSha = try git.revParse(options.head)
        let baseRef = try git.revParse(options.base)
        let baseSha = options.useMergeBase ? try git.mergeBase(baseRef, headSha) : baseRef

        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("reviewmap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let baseDir = tmp + "/base"
        let headDir = tmp + "/head"
        log("Exporting \(String(baseSha.prefix(8))) and \(String(headSha.prefix(8)))…")
        try git.export(baseSha, to: baseDir)
        try git.export(headSha, to: headDir)

        var config = Config()
        if let p = options.configPath {
            config = try Config.load(path: p)
        } else if FileManager.default.fileExists(atPath: headDir + "/reviewmap.yml") {
            config = try Config.load(path: headDir + "/reviewmap.yml")
        }

        let baseBlobs = try git.blobs(at: baseSha)
        let headBlobs = try git.blobs(at: headSha)

        log("Parsing Swift files…")
        let parser = ParseCache()
        let baseSide = try SideData.load(side: .base, dir: baseDir, blobs: baseBlobs, config: &config, parser: parser, dumpPackage: options.dumpPackage)
        let headSide = try SideData.load(side: .head, dir: headDir, blobs: headBlobs, config: &config, parser: parser, dumpPackage: options.dumpPackage)

        log("Comparing…")
        var builder = ModelBuilder(base: baseSide, head: headSide, options: options)
        builder.diffExternalDeps(baseBlobs: baseBlobs, headBlobs: headBlobs, baseDir: baseDir, headDir: headDir)
        builder.matchEntities()
        builder.resolveReferences()
        builder.addContractFiles(baseBlobs: baseBlobs, headBlobs: headBlobs, baseDir: baseDir, headDir: headDir)
        builder.addTargetSettings()

        let repo = RepoInfo(root: root, base: options.base, head: options.head, baseSha: baseSha, headSha: headSha,
                            usesMergeBase: options.useMergeBase)
        return builder.finish(repo: repo)
    }
}

// MARK: - Parsing

final class ParseCache: @unchecked Sendable {
    private var cache: [String: ParsedFile] = [:]
    private let lock = NSLock()

    /// Parses every (path, blob) concurrently; identical blobs are parsed once across both sides.
    func parseAll(_ items: [(path: String, blob: String, abs: String)]) -> [String: ParsedFile] {
        var todo: [(path: String, blob: String, abs: String)] = []
        lock.lock()
        var seen = Set<String>()
        for i in items where cache[i.blob] == nil && !seen.contains(i.blob) {
            todo.append(i)
            seen.insert(i.blob)
        }
        lock.unlock()
        DispatchQueue.concurrentPerform(iterations: todo.count) { idx in
            let item = todo[idx]
            let source = (try? String(contentsOfFile: item.abs, encoding: .utf8)) ?? ""
            let parsed = SwiftExtractor.parse(path: item.path, source: source)
            lock.lock()
            cache[item.blob] = parsed
            lock.unlock()
        }
        var result: [String: ParsedFile] = [:]
        lock.lock()
        for i in items {
            var p = cache[i.blob]!
            p.path = i.path
            result[i.path] = p
        }
        lock.unlock()
        return result
    }
}

struct SideData {
    let side: Side
    let dir: String
    let files: [String: ParsedFile]
    let layout: ComponentLayout
    /// Top-level declared name -> components that declare it.
    let declTable: [String: Set<String>]
    let generated: Set<String>

    static func load(side: Side, dir: String, blobs: [String: String], config: inout Config, parser: ParseCache, dumpPackage: Bool) throws -> SideData {
        let excludes = config.excludeMatchers
        let swiftPaths = blobs.keys.filter { path in
            let name = (path as NSString).lastPathComponent
            let isManifest = name == "Package.swift" || name.hasPrefix("Package@swift")
            return path.hasSuffix(".swift") && !isManifest && !excludes.contains(where: { $0.matches(path) })
        }.sorted()
        let files = parser.parseAll(swiftPaths.map { ($0, blobs[$0]!, dir + "/" + $0) })
        let layout = ComponentBuilder.build(root: dir, swiftFiles: swiftPaths, config: &config, dumpPackage: dumpPackage)
        var table: [String: Set<String>] = [:]
        for (path, file) in files {
            guard let comp = layout.fileComponent[path] else { continue }
            for d in file.decls where d.isTopLevel && d.kind != .extension {
                table[d.name, default: []].insert(comp)
            }
        }
        let gen = config.generatedMatchers
        let generated = Set(swiftPaths.filter { p in gen.contains { $0.matches(p) } })
        return SideData(side: side, dir: dir, files: files, layout: layout, declTable: table, generated: generated)
    }
}

// MARK: - Model building

/// A declaration located at one side.
struct Located {
    var decl: Decl
    var file: String
    var index: Int
    var component: String
}

struct DeclKey: Hashable {
    var side: Side
    var file: String
    var index: Int
}

struct Pair {
    var base: Located?
    var head: Located?
    var id: String = ""
    var changes: [ChangeKind] = []
    var flags: [String] = []
    var any: Located { head ?? base! }
}

private let codableNames: Set<String> = ["Codable", "Encodable", "Decodable"]
private let observableAttrs: Set<String> = ["Published", "State", "Observable", "ObservationTracked", "Bindable", "AppStorage", "SceneStorage"]

struct ModelBuilder {
    let base: SideData
    let head: SideData
    let options: AnalyzeOptions

    var pairs: [Pair] = []
    var pairOf: [DeclKey: Int] = [:]
    var fileEntities: [Entity] = []
    var warnings = Set<Warning>()
    /// (side, from, to) -> refs
    var edgeRefs: [Side: [String: [String: [Ref]]]] = [.base: [:], .head: [:]]
    /// pair index -> usages
    var usedBy: [Int: Set<Usage>] = [:]
    var dependsOn: [Int: Set<Usage>] = [:]
    var externalComponents: [String: String] = [:] // id -> name
    var externalDeps: [ExternalDepChange] = []
    /// Package identities pinned on either side (Package.resolved).
    var pinnedPackages = Set<String>()

    init(base: SideData, head: SideData, options: AnalyzeOptions) {
        self.base = base
        self.head = head
        self.options = options
        for w in base.layout.warnings + head.layout.warnings { warnings.insert(w) }
    }

    func side(_ s: Side) -> SideData { s == .base ? base : head }

    // MARK: Matching

    private static func kindGroup(_ k: EntityKind) -> String {
        switch k {
        case .struct, .class, .enum, .actor: return "type"
        case .func, .`init`: return "callable"
        default: return k.rawValue
        }
    }

    private func locatedDecls(_ s: SideData) -> [String: [Located]] {
        var groups: [String: [Located]] = [:]
        for path in s.files.keys.sorted() {
            guard let comp = s.layout.fileComponent[path], let file = s.files[path] else { continue }
            for (i, d) in file.decls.enumerated() {
                let name = d.kind == .extension ? d.qualifiedName : d.name
                let key = "\(comp)|\(Self.kindGroup(d.kind))|\(d.scope ?? "")|\(name)"
                groups[key, default: []].append(Located(decl: d, file: path, index: i, component: comp))
            }
        }
        return groups
    }

    mutating func matchEntities() {
        let bg = locatedDecls(base)
        let hg = locatedDecls(head)
        let keys = Set(bg.keys).union(hg.keys).sorted()
        for key in keys {
            var bs = bg[key] ?? []
            var hs = hg[key] ?? []
            var matched: [(Located?, Located?)] = []
            let passes: [(Decl, Decl) -> Bool] = [
                { $0.signatureCanon == $1.signatureCanon && $0.modifiersCanon == $1.modifiersCanon && $0.bodyCanon == $1.bodyCanon },
                { $0.signatureCanon == $1.signatureCanon && $0.modifiersCanon == $1.modifiersCanon },
                { $0.signatureCanon == $1.signatureCanon },
                { $0.labelsKey == $1.labelsKey },
            ]
            for pass in passes {
                var i = 0
                while i < bs.count {
                    if let j = hs.firstIndex(where: { pass(bs[i].decl, $0.decl) }) {
                        matched.append((bs[i], hs[j]))
                        bs.remove(at: i)
                        hs.remove(at: j)
                    } else {
                        i += 1
                    }
                }
            }
            if bs.count == hs.count {
                for (b, h) in zip(bs, hs) { matched.append((b, h)) }
            } else {
                if !bs.isEmpty && !hs.isEmpty {
                    warnings.insert(Warning(kind: "ambiguous-overloads",
                        message: "Could not pair \(bs.count) base and \(hs.count) head declarations of \(bs[0].decl.qualifiedName); reported as removed and added.",
                        file: hs[0].file, line: hs[0].decl.startLine))
                }
                for b in bs { matched.append((b, nil)) }
                for h in hs { matched.append((nil, h)) }
            }
            for (b, h) in matched {
                var p = Pair(base: b, head: h)
                if let b { pairOf[DeclKey(side: .base, file: b.file, index: b.index)] = pairs.count }
                if let h { pairOf[DeclKey(side: .head, file: h.file, index: h.index)] = pairs.count }
                p.changes = Self.changes(b?.decl, h?.decl)
                pairs.append(p)
            }
        }
        assignIds()
        computeFlags()
    }

    private static func changes(_ b: Decl?, _ h: Decl?) -> [ChangeKind] {
        guard let b else { return [.added] }
        guard let h else { return [.removed] }
        var c: [ChangeKind] = []
        if b.signatureCanon != h.signatureCanon || kindGroup(b.kind) == "type" && b.kind != h.kind { c.append(.signature) }
        if b.modifiersCanon != h.modifiersCanon { c.append(.modifiers) }
        if b.bodyCanon != h.bodyCanon { c.append(.body) }
        if c.isEmpty && !b.isContainer && b.rawText != h.rawText { c.append(.cosmetic) }
        return c
    }

    private mutating func assignIds() {
        var used: [String: Int] = [:]
        // Sort for deterministic duplicate numbering.
        let order = pairs.indices.sorted {
            let a = pairs[$0].any, b = pairs[$1].any
            return (a.component, a.decl.qualifiedName, a.file, a.decl.startLine) < (b.component, b.decl.qualifiedName, b.file, b.decl.startLine)
        }
        for i in order {
            let a = pairs[i].any
            var id = "\(a.component)::\(a.decl.qualifiedName)"
            if let n = used[id] {
                used[id] = n + 1
                id += "#\(n + 1)"
            } else {
                used[id] = 1
            }
            pairs[i].id = id
        }
    }

    func parentPair(_ l: Located, side s: Side) -> Int? {
        guard let pi = l.decl.parentIndex else { return nil }
        return pairOf[DeclKey(side: s, file: l.file, index: pi)]
    }

    private func parentDecl(_ l: Located, side s: Side) -> Decl? {
        guard let pi = l.decl.parentIndex else { return nil }
        return side(s).files[l.file]?.decls[pi]
    }

    /// Types (by component + qualified name) with a given trait on one side, including conformances added in extensions.
    private func typesWhere(_ s: SideData, _ pred: (Decl) -> Bool) -> Set<String> {
        var result = Set<String>()
        for (path, file) in s.files {
            guard let comp = s.layout.fileComponent[path] else { continue }
            for d in file.decls where d.isContainer && pred(d) {
                result.insert("\(comp)|\(d.kind == .extension ? d.name : d.qualifiedName)")
            }
        }
        return result
    }

    /// "@MainActor P" -> "P".
    static func conformanceName(_ s: String) -> String {
        s.split(separator: " ").last.map(String.init) ?? s
    }

    /// Effective conformances per "component|Type": name -> isolation attributes ("" when none).
    private func conformances(_ s: SideData) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for (path, file) in s.files {
            guard let comp = s.layout.fileComponent[path] else { continue }
            for d in file.decls where d.isContainer {
                let key = "\(comp)|\(d.kind == .extension ? d.name : d.qualifiedName)"
                for c in d.inherited {
                    let parts = c.split(separator: " ")
                    let attrs = parts.dropLast().filter { $0 != "@unchecked" && $0 != "@retroactive" && $0 != "@preconcurrency" }.joined(separator: " ")
                    result[key, default: [:]][Self.conformanceName(c)] = attrs
                }
                if d.attributes.contains("Sendable") { result[key, default: [:]]["Sendable"] = "" }
            }
        }
        return result
    }

    private mutating func computeFlags() {
        let isCodable: (Decl) -> Bool = { !codableNames.isDisjoint(with: $0.inherited.map(Self.conformanceName)) }
        let codable = typesWhere(base, isCodable).union(typesWhere(head, isCodable))
        let models = typesWhere(base, { $0.attributes.contains("Model") }).union(typesWhere(head, { $0.attributes.contains("Model") }))
        // With @Observable every stored property is tracked state; with ObservableObject only @Published ones are.
        let isObs: (Decl) -> Bool = { $0.attributes.contains("Observable") }
        let observable = typesWhere(base, isObs).union(typesWhere(head, isObs))

        let baseConf = conformances(base), headConf = conformances(head)
        var typeDeclared = Set<String>()
        for p in pairs where p.any.decl.isContainer && p.any.decl.kind != .extension && p.base != nil && p.head != nil {
            typeDeclared.insert("\(p.any.component)|\(p.any.decl.qualifiedName)")
        }
        var parentFlags: [Int: Set<String>] = [:]
        for i in pairs.indices {
            let p = pairs[i]
            let b = p.base?.decl
            let h = p.head?.decl
            let d = p.any.decl
            let s: Side = p.head != nil ? .head : .base
            var flags: [String] = []
            let added = b == nil, removed = h == nil
            let changed = !p.changes.isEmpty && p.changes != [.cosmetic]

            if let b, let h {
                let ba = b.access ?? "internal", ha = h.access ?? "internal"
                if ba != ha { flags.append("access-changed:\(ba)->\(ha)") }
                if b.isAsync != h.isAsync { flags.append(h.isAsync ? "async-added" : "async-removed") }
                if b.isThrows != h.isThrows { flags.append(h.isThrows ? "throws-added" : "throws-removed") }
                else if b.isThrows && b.throwsType != h.throwsType { flags.append("typed-throws-changed") }
                let bm = b.attributes.contains("MainActor"), hm = h.attributes.contains("MainActor")
                if bm != hm { flags.append(hm ? "mainactor-added" : "mainactor-removed") }
                let bn = b.modifiers.contains { $0.hasPrefix("nonisolated") }, hn = h.modifiers.contains { $0.hasPrefix("nonisolated") }
                if bn != hn { flags.append(hn ? "nonisolated-added" : "nonisolated-removed") }
                if !b.isContainer {
                    let bsend = b.attributes.contains("Sendable"), hsend = h.attributes.contains("Sendable")
                    if bsend != hsend { flags.append(hsend ? "sendable-added" : "sendable-removed") }
                }
                if b.kind != h.kind && Self.kindGroup(b.kind) == "type" { flags.append("kind-changed:\(b.kind.rawValue)->\(h.kind.rawValue)") }
                if b.kind != .extension || !typeDeclared.contains("\(p.any.component)|\(b.name)") {
                    // Conformances are compared per type, across the type and its extensions in the component,
                    // so moving a conformance into an extension is not a change.
                    let key = "\(p.any.component)|\(b.kind == .extension ? b.name : b.qualifiedName)"
                    let bc = baseConf[key] ?? [:], hc = headConf[key] ?? [:]
                    for c in Set(hc.keys).subtracting(bc.keys).subtracting(["Sendable"]).sorted() { flags.append("conformance-added:\(c)") }
                    for c in Set(bc.keys).subtracting(hc.keys).subtracting(["Sendable"]).sorted() { flags.append("conformance-removed:\(c)") }
                    for c in Set(bc.keys).intersection(hc.keys).sorted() where bc[c] != hc[c] {
                        flags.append("conformance-isolation-changed:\(c)")
                    }
                    if (bc["Sendable"] != nil) != (hc["Sendable"] != nil) && !flags.contains(where: { $0.hasPrefix("sendable-") }) {
                        flags.append(hc["Sendable"] != nil ? "sendable-added" : "sendable-removed")
                    }
                }
                let bo = b.attributes.contains("Observable"), ho = h.attributes.contains("Observable")
                if bo != ho { flags.append(ho ? "observable-added" : "observable-removed") }
                let bmodel = b.attributes.contains("Model"), hmodel = h.attributes.contains("Model")
                if bmodel != hmodel { flags.append("swiftdata-model-changed") }
            } else if d.kind == .extension {
                // A new or deleted extension: report conformances that the type gained or lost overall.
                let key = "\(p.any.component)|\(d.name)"
                let bc = baseConf[key] ?? [:], hc = headConf[key] ?? [:]
                for c in d.inherited.map(Self.conformanceName) where c != "Sendable" {
                    if added && bc[c] == nil { flags.append("conformance-added:\(c)") }
                    if removed && hc[c] == nil { flags.append("conformance-removed:\(c)") }
                    if added, let old = bc[c], old != hc[c] { flags.append("conformance-isolation-changed:\(c)") }
                }
            }

            var toParent: [String] = []
            let parentKind = d.parentKind
            if parentKind == .protocol && (added || removed || changed && p.changes.contains(where: { $0 != .body })) {
                let f = added ? "protocol-requirement-added" : removed ? "protocol-requirement-removed" : "protocol-requirement-changed"
                flags.append(f)
                toParent.append(f)
            }
            if d.kind == .case && parentKind == .enum && (added || removed || p.changes.contains(.signature)) {
                let f = added ? "enum-case-added" : removed ? "enum-case-removed" : "enum-case-changed"
                flags.append(f)
                toParent.append(f)
            }
            let scopeKey = "\(p.any.component)|\(d.scope ?? "")"
            let structural = added || removed || p.changes.contains(.signature) || p.changes.contains(.modifiers)
            if d.kind == .var && d.isStored && !d.isStatic && structural {
                if codable.contains(scopeKey) { flags.append("codable-shape"); toParent.append("codable-shape") }
                if models.contains(scopeKey) { flags.append("swiftdata-model-changed"); toParent.append("swiftdata-model-changed") }
                let attrs = Set((b?.attributes ?? []) + (h?.attributes ?? []))
                if !attrs.contains("ObservationIgnored") && (observable.contains(scopeKey) || !attrs.isDisjoint(with: observableAttrs)) {
                    flags.append("observable-state-changed")
                    toParent.append("observable-state-changed")
                }
            }
            // Members of a nested CodingKeys enum shape the parent's encoding.
            if let scope = d.scope, scope.hasSuffix(".CodingKeys"), d.kind == .case, added || removed || changed {
                flags.append("codable-shape")
                let owner = String(scope.dropLast(".CodingKeys".count))
                if let oi = pairs.indices.first(where: { pairs[$0].any.component == p.any.component && pairs[$0].any.decl.qualifiedName == owner && pairs[$0].any.decl.kind != .extension }) {
                    parentFlags[oi, default: []].insert("codable-shape")
                }
            }
            let parentIdx = (p.head ?? p.base).flatMap { parentPair($0, side: s) }
            if let pi = parentIdx, pairs[pi].base == nil || pairs[pi].head == nil {
                // A member of a new or deleted type: the type itself carries the flag; repeating it on every
                // member is noise.
                let memberLevel: Set<String> = ["protocol-requirement-added", "protocol-requirement-removed", "enum-case-added",
                                                "enum-case-removed", "codable-shape", "swiftdata-model-changed", "observable-state-changed"]
                flags.removeAll { memberLevel.contains($0) }
            }
            pairs[i].flags = flags
            if !toParent.isEmpty, let pp = parentIdx, pairs[pp].base != nil, pairs[pp].head != nil {
                parentFlags[pp, default: []].formUnion(toParent)
            }
        }
        for (pi, fl) in parentFlags {
            for f in fl.sorted() where !pairs[pi].flags.contains(f) { pairs[pi].flags.append(f) }
        }
    }

    // MARK: References and edges

    private static let appleModules: Set<String> = [
        "Foundation", "SwiftUI", "UIKit", "AppKit", "Combine", "CoreData", "SwiftData", "Observation", "os", "OSLog",
        "CoreGraphics", "CoreLocation", "MapKit", "AVFoundation", "AVKit", "Photos", "PhotosUI", "StoreKit", "WebKit",
        "XCTest", "Testing", "UserNotifications", "CloudKit", "Security", "CryptoKit", "LocalAuthentication", "Network",
        "Darwin", "Dispatch", "CoreImage", "CoreMedia", "CoreText", "QuartzCore", "SafariServices", "MessageUI",
        "Contacts", "ContactsUI", "EventKit", "EventKitUI", "HealthKit", "WidgetKit", "AppIntents", "ActivityKit",
        "BackgroundTasks", "CoreMotion", "CoreBluetooth", "CoreHaptics", "GameKit", "SpriteKit", "SceneKit", "ARKit",
        "RealityKit", "Metal", "MetalKit", "Vision", "VisionKit", "CoreML", "NaturalLanguage", "Speech", "PassKit",
        "AuthenticationServices", "LinkPresentation", "QuickLook", "PDFKit", "Charts", "TipKit", "Accessibility",
        "MediaPlayer", "MultipeerConnectivity", "NotificationCenter", "SystemConfiguration", "UniformTypeIdentifiers",
        "CoreTransferable", "Intents", "IntentsUI", "Swift", "_Concurrency", "Glibc", "CoreFoundation", "ImageIO",
        "MobileCoreServices", "CoreServices", "AdSupport", "AppTrackingTransparency", "DeviceCheck", "CoreSpotlight",
        "FoundationModels", "SwiftSyntax", "SwiftParser", "RegexBuilder", "Accelerate", "simd", "AudioToolbox",
        "Translation", "JavaScriptCore", "CoreAudio", "CoreVideo", "GameController", "ExtensionKit", "ExtensionFoundation",
        "SensitiveContentAnalysis", "ScreenTime", "FamilyControls", "ManagedSettings", "DeviceActivity", "Social",
        "CoreNFC", "NetworkExtension", "ShazamKit", "MusicKit", "WeatherKit", "Synchronization", "Distributed",
        "UIKit.UIGestureRecognizerSubclass", "ObjectiveC", "AVRouting", "CarPlay", "ClockKit", "WatchKit", "WatchConnectivity",
        "SystemPackage", "XCUIAutomation", "SQLite3", "zlib", "Compression", "libkern", "CommonCrypto", "Cocoa", "ImagePlayground", "Combine", "MediaPlayer", "OSLog",
    ]

    private mutating func addRef(_ s: Side, from: String, to: String, ref: Ref) {
        guard from != to else { return }
        edgeRefs[s]![from, default: [:]][to, default: []].append(ref)
    }

    private mutating func externalComponent(for module: String, layout: ComponentLayout) -> String? {
        var pkg = layout.externalProducts[module]
        if pkg == nil {
            // Products listed by name only: match the module to a pinned package identity
            // ("SwiftSoup" -> "swiftsoup", "Collections" -> "swift-collections").
            let m = module.lowercased()
            func norm(_ s: String) -> String {
                var x = s.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
                for affix in ["swift", "ios", "spm", "kit"] where x.count > affix.count + 2 {
                    if x.hasPrefix(affix) { x.removeFirst(affix.count) }
                    if x.hasSuffix(affix) { x.removeLast(affix.count) }
                }
                return x
            }
            pkg = pinnedPackages.sorted().first { $0 == m || norm($0) == norm(m) }
        }
        guard let pkg else { return nil }
        let id = "ext:\(pkg)"
        externalComponents[id] = pkg
        return id
    }

    mutating func resolveReferences() {
        for s in [Side.base, .head] {
            let data = side(s)
            let layout = data.layout
            // Changed member entities by name, for member-level usage.
            var membersByName: [String: [(component: String, rootType: String, pair: Int)]] = [:]
            for (i, p) in pairs.enumerated() {
                guard let loc = s == .head ? p.head : p.base, let scope = loc.decl.scope, !loc.decl.isContainer,
                      !p.changes.isEmpty, p.changes != [.cosmetic] else { continue }
                let root = String(scope.split(separator: ".").first ?? Substring(scope))
                membersByName[loc.decl.name, default: []].append((loc.component, root, i))
            }
            // Top-level declarations by (component, name) -> pair index, for type-level usage.
            var topLevel: [String: Int] = [:]
            for (i, p) in pairs.enumerated() {
                guard let loc = s == .head ? p.head : p.base, loc.decl.isTopLevel, loc.decl.kind != .extension else { continue }
                topLevel["\(loc.component)|\(loc.decl.name)"] = i
            }

            var ambiguous: [String: Set<String>] = [:]
            for path in data.files.keys.sorted() {
                guard let file = data.files[path], let comp = layout.fileComponent[path] else { continue }
                let module = layout.components[comp]?.module
                var visible = Set(file.imports.map(\.name))
                if let module { visible.insert(module) }
                var resolvedTypes = Set<String>() // "component|TypeName"

                for imp in file.imports {
                    if let target = layout.moduleComponent[imp.name], layout.components[target]?.module != module {
                        addRef(s, from: comp, to: target, ref: Ref(file: path, line: imp.line, symbol: "import \(imp.name)", side: s))
                    } else if let ext = externalComponent(for: imp.name, layout: layout) {
                        addRef(s, from: comp, to: ext, ref: Ref(file: path, line: imp.line, symbol: "import \(imp.name)", side: s))
                    } else if layout.moduleComponent[imp.name] == nil && !Self.appleModules.contains(imp.name) {
                        warnings.insert(Warning(kind: "unresolved-import", message: "import \(imp.name) matches no target or known package product."))
                    }
                }

                var seenRef = Set<NameRef>()
                for ref in file.typeRefs where !seenRef.contains(ref) {
                    seenRef.insert(ref)
                    guard var cands = data.declTable[ref.name], !cands.contains(comp) else { continue }
                    cands = cands.filter { c in
                        guard let m = layout.components[c]?.module else { return true }
                        return visible.contains(m)
                    }
                    if cands.count > 1 {
                        ambiguous[ref.name, default: []].formUnion(cands)
                        continue
                    }
                    guard let target = cands.first else { continue }
                    addRef(s, from: comp, to: target, ref: Ref(file: path, line: ref.line, symbol: ref.name, side: s))
                    resolvedTypes.insert("\(target)|\(ref.name)")
                    let encl = file.enclosingDecl(line: ref.line)
                    if let ti = topLevel["\(target)|\(ref.name)"] {
                        usedBy[ti, default: []].insert(Usage(component: comp, symbol: encl?.qualifiedName ?? "(top level)", file: path, line: ref.line))
                    }
                    if let encl, let idx = file.decls.firstIndex(where: { $0.startLine == encl.startLine && $0.qualifiedName == encl.qualifiedName }),
                       let pi = pairOf[DeclKey(side: s, file: path, index: idx)] {
                        dependsOn[pi, default: []].insert(Usage(component: target, symbol: ref.name, file: path, line: ref.line))
                    }
                }
                for ref in Set(file.memberRefs) {
                    for m in membersByName[ref.name] ?? [] where m.component != comp && resolvedTypes.contains("\(m.component)|\(m.rootType)") {
                        let encl = file.enclosingDecl(line: ref.line)
                        usedBy[m.pair, default: []].insert(Usage(component: comp, symbol: encl?.qualifiedName ?? "(top level)", file: path, line: ref.line))
                    }
                }
            }
            for (name, comps) in ambiguous {
                warnings.insert(Warning(kind: "ambiguous-name",
                    message: "\(name) is declared in \(comps.sorted().joined(separator: ", ")); references to it were not resolved (\(s.rawValue))."))
            }
            for dep in layout.manifestDeps {
                if let target = layout.moduleComponent[dep.module] {
                    addRef(s, from: dep.from, to: target, ref: Ref(file: dep.file, line: 0, symbol: "dependency \(dep.module)", side: s))
                } else if let ext = externalComponent(for: dep.module, layout: layout) {
                    addRef(s, from: dep.from, to: ext, ref: Ref(file: dep.file, line: 0, symbol: "dependency \(dep.module)", side: s))
                }
            }
        }
    }

    // MARK: Non-code contracts

    mutating func addContractFiles(baseBlobs: [String: String], headBlobs: [String: String], baseDir: String, headDir: String) {
        func flag(for path: String) -> (key: String, flag: String)? {
            let name = (path as NSString).lastPathComponent
            if let r = path.range(of: ".xcdatamodeld/") {
                return (String(path[..<r.lowerBound]) + ".xcdatamodeld", "coredata-model-changed")
            }
            if name == "PrivacyInfo.xcprivacy" { return (path, "privacy-manifest-changed") }
            if name.hasSuffix(".entitlements") { return (path, "entitlements-changed") }
            if name == "Info.plist" || name.hasSuffix("-Info.plist") { return (path, "info-plist-changed") }
            return nil
        }
        var groups: [String: (flag: String, base: Bool, head: Bool, changed: Bool)] = [:]
        for path in Set(baseBlobs.keys).union(headBlobs.keys) {
            guard baseBlobs[path] != headBlobs[path], let (key, f) = flag(for: path) else { continue }
            var g = groups[key] ?? (f, false, false, false)
            if baseBlobs[path] != nil { g.base = true }
            if headBlobs[path] != nil { g.head = true }
            g.changed = true
            groups[key] = g
        }
        for (key, g) in groups.sorted(by: { $0.key < $1.key }) {
            let existsBase = baseBlobs.keys.contains { $0 == key || $0.hasPrefix(key + "/") }
            let existsHead = headBlobs.keys.contains { $0 == key || $0.hasPrefix(key + "/") }
            let change: ChangeKind = !existsBase ? .added : !existsHead ? .removed : .body
            var flags = [g.flag]
            if g.flag == "info-plist-changed", existsBase, existsHead,
               Self.urlSchemes(baseDir + "/" + key) != Self.urlSchemes(headDir + "/" + key) {
                flags.append("url-schemes-changed")
            }
            let s: Side = existsHead ? .head : .base
            let comp = nearestComponent(for: key, side: s)
            let lines = (try? String(contentsOfFile: (s == .head ? headDir : baseDir) + "/" + key, encoding: .utf8))?
                .split(separator: "\n", omittingEmptySubsequences: false).count ?? 1
            let loc = Location(file: key, startLine: 1, endLine: max(1, lines), side: s)
            fileEntities.append(Entity(
                id: "\(comp)::\(key)", component: comp, kind: .file, qualifiedName: key, parent: nil,
                isInterface: true, change: change, changes: [change], signature: Signature(base: nil, head: nil),
                contractFlags: flags, tags: [], location: loc, baseLocation: nil, usedBy: [], dependsOn: []))
        }
    }

    mutating func addTargetSettings() {
        let b = base.layout.targetSettings, h = head.layout.targetSettings
        for id in Set(b.keys).intersection(h.keys).sorted() {
            let bs = b[id]!.settings, hs = h[id]!.settings
            let keys = Set(bs.keys).union(hs.keys).filter { bs[$0] != hs[$0] }.sorted()
            guard !keys.isEmpty else { continue }
            var flags = Set<String>()
            for k in keys {
                let lk = k.lowercased()
                if lk.contains("defaultisolation") || lk.contains("default_actor_isolation") { flags.insert("default-isolation-changed") }
                else if lk.contains("strict") && lk.contains("concurrency") || lk.contains("approachable") { flags.insert("strict-concurrency-changed") }
                else if lk.contains("upcomingfeature") || lk.contains("upcoming_feature") || lk.contains("enableexperimentalfeature") { flags.insert("swift-features-changed") }
                else if lk.contains("swift_version") || lk.contains("swiftlanguagemode") { flags.insert("swift-version-changed") }
                else if lk.contains("deployment_target") { flags.insert("deployment-target-changed") }
                else { flags.insert("build-settings-changed") }
            }
            func show(_ m: [String: String]) -> String? {
                let lines = keys.compactMap { k in m[k].map { $0 == "on" ? k : "\(k) = \($0)" } }
                return lines.isEmpty ? nil : lines.joined(separator: "\n")
            }
            let file = h[id]!.file
            let name = head.layout.components[id]?.name ?? id
            fileEntities.append(Entity(
                id: "\(id)::build settings", component: id, kind: .target, qualifiedName: "\(name) build settings", parent: nil,
                isInterface: true, change: .modifiers, changes: [.modifiers],
                signature: Signature(base: show(bs), head: show(hs)), contractFlags: flags.sorted(), tags: [],
                location: Location(file: file, startLine: 1, endLine: 1, side: .head), baseLocation: nil, usedBy: [], dependsOn: []))
        }
    }

    private static func urlSchemes(_ path: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let types = plist["CFBundleURLTypes"] as? [[String: Any]] else { return [] }
        return types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }.sorted()
    }

    /// The component of the Swift file sharing the longest directory prefix with `path`.
    private mutating func nearestComponent(for path: String, side s: Side) -> String {
        let layout = side(s).layout
        let dirs = path.split(separator: "/").dropLast()
        var best: (Int, String)?
        for (f, c) in layout.fileComponent {
            let fd = f.split(separator: "/").dropLast()
            var n = 0
            while n < dirs.count && n < fd.count && dirs[dirs.startIndex + n] == fd[fd.startIndex + n] { n += 1 }
            if n > 0, best == nil || n > best!.0 || (n == best!.0 && c < best!.1) { best = (n, c) }
        }
        if let best { return layout.components[best.1]?.parent ?? best.1 }
        let top = path.split(separator: "/").count > 1 ? String(path.split(separator: "/")[0]) : "."
        return "folder:\(top)"
    }

    // MARK: External packages

    mutating func diffExternalDeps(baseBlobs: [String: String], headBlobs: [String: String], baseDir: String, headDir: String) {
        func pins(_ blobs: [String: String], _ dir: String) -> [String: String] {
            var result: [String: String] = [:]
            for path in blobs.keys.sorted() where path.hasSuffix("Package.resolved") {
                guard let data = FileManager.default.contents(atPath: dir + "/" + path),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let list = (obj["pins"] as? [[String: Any]]) ?? ((obj["object"] as? [String: Any])?["pins"] as? [[String: Any]]) ?? []
                for pin in list {
                    let identity = (pin["identity"] as? String)
                        ?? (pin["repositoryURL"] as? String).map(ComponentBuilder.packageIdentity)
                        ?? (pin["package"] as? String)?.lowercased()
                    guard let identity else { continue }
                    let state = pin["state"] as? [String: Any] ?? [:]
                    let v = (state["version"] as? String) ?? (state["branch"] as? String) ?? (state["revision"] as? String).map { String($0.prefix(8)) } ?? "?"
                    result[identity.lowercased()] = v
                }
            }
            return result
        }
        let b = pins(baseBlobs, baseDir)
        let h = pins(headBlobs, headDir)
        pinnedPackages = Set(b.keys).union(h.keys)
        for name in Set(b.keys).union(h.keys).sorted() {
            switch (b[name], h[name]) {
            case (nil, let to?): externalDeps.append(ExternalDepChange(name: name, change: "added", from: nil, to: to))
            case (let from?, nil): externalDeps.append(ExternalDepChange(name: name, change: "removed", from: from, to: nil))
            case (let from?, let to?) where from != to:
                externalDeps.append(ExternalDepChange(name: name, change: "bumped", from: from, to: to))
            default: break
            }
        }
    }

    // MARK: Output

    func finish(repo: RepoInfo) -> ChangeModel {
        // Entities: everything that changed (containers only when their own header changed or they carry flags).
        var entities: [Entity] = []
        for (i, p) in pairs.enumerated() {
            let d = p.any.decl
            var changes = p.changes
            if d.isContainer {
                changes.removeAll { $0 == .cosmetic }
                if changes.isEmpty && p.flags.isEmpty { continue }
                if changes.isEmpty { changes = [.body] }
            } else if changes.isEmpty {
                continue
            }
            let s: Side = p.head != nil ? .head : .base
            let loc = p.any
            let data = side(s)
            let comp = data.layout.components[loc.component]
            var tags: [String] = []
            if comp?.isTest == true || ComponentBuilder.isTestPath(loc.file) { tags.append("test") }
            if data.generated.contains(loc.file) { tags.append("generated") }
            let parentId = parentPair(loc, side: s).map { pairs[$0].id }
            let used = (usedBy[i] ?? []).sorted { ($0.file, $0.line, $0.symbol) < ($1.file, $1.line, $1.symbol) }
            let deps = (dependsOn[i] ?? []).filter { u in u.line >= loc.decl.startLine && u.line <= loc.decl.endLine }
                .sorted { ($0.component, $0.symbol, $0.line) < ($1.component, $1.symbol, $1.line) }
            entities.append(Entity(
                id: p.id, component: loc.component, kind: d.kind, qualifiedName: d.qualifiedName, parent: parentId,
                isInterface: false, change: changes[0], changes: changes,
                signature: Signature(base: p.base?.decl.signatureDisplay, head: p.head?.decl.signatureDisplay),
                contractFlags: p.flags, tags: tags,
                location: Location(file: loc.file, startLine: d.startLine, endLine: d.endLine, side: s),
                baseLocation: (p.head != nil ? p.base : nil).map {
                    Location(file: $0.file, startLine: $0.decl.startLine, endLine: $0.decl.endLine, side: .base)
                },
                usedBy: used, dependsOn: deps))
        }
        // Interface: public/open/package, used from another component, or a requirement/case of an interface type.
        var interfaceIds = Set<String>()
        for (i, p) in pairs.enumerated() {
            let access = p.head?.decl.access ?? p.base?.decl.access
            let nonTestUse = (usedBy[i] ?? []).contains { u in
                !(head.layout.components[u.component]?.isTest ?? base.layout.components[u.component]?.isTest ?? false)
            }
            if ["public", "open", "package"].contains(access ?? "") || nonTestUse {
                interfaceIds.insert(p.id)
            }
        }
        for (i, p) in pairs.enumerated() {
            let d = p.any.decl
            guard d.parentKind == .protocol || d.kind == .case, let pp = parentPair(p.any, side: p.head != nil ? .head : .base) else { continue }
            if interfaceIds.contains(pairs[pp].id) { interfaceIds.insert(pairs[i].id) }
        }
        for i in entities.indices { entities[i].isInterface = interfaceIds.contains(entities[i].id) }
        entities += fileEntities
        entities.sort { ($0.component, $0.location.file, $0.location.startLine, $0.id) < ($1.component, $1.location.file, $1.location.startLine, $1.id) }

        // Edges.
        var edges: [Edge] = []
        var keys = Set<String>()
        for s in [Side.base, .head] {
            for (from, tos) in edgeRefs[s]! { for to in tos.keys { keys.insert("\(from)\u{1}\(to)") } }
        }
        for key in keys.sorted() {
            let parts = key.split(separator: "\u{1}").map(String.init)
            let (from, to) = (parts[0], parts[1])
            let bRefs = edgeRefs[.base]![from]?[to] ?? []
            let hRefs = edgeRefs[.head]![from]?[to] ?? []
            let bSyms = Set(bRefs.map(\.symbol)), hSyms = Set(hRefs.map(\.symbol))
            let status: EdgeStatus = bRefs.isEmpty ? .added : hRefs.isEmpty ? .removed : bSyms != hSyms ? .changed : .unchanged
            let addedSyms = hSyms.subtracting(bSyms), removedSyms = bSyms.subtracting(hSyms)
            let sortRefs: ([Ref]) -> [Ref] = { $0.sorted { ($0.file, $0.line, $0.symbol) < ($1.file, $1.line, $1.symbol) } }
            var refs = sortRefs(hRefs.filter { addedSyms.contains($0.symbol) }) + sortRefs(bRefs.filter { removedSyms.contains($0.symbol) })
            let rest = status == .removed ? bRefs : hRefs
            refs += sortRefs(rest.filter { !addedSyms.contains($0.symbol) && !removedSyms.contains($0.symbol) })
            edges.append(Edge(from: from, to: to, status: status, symbolsAdded: addedSyms.sorted(), symbolsRemoved: removedSyms.sorted(),
                              refs: Array(refs.prefix(options.maxRefsPerEdge)),
                              refCount: status == .removed ? bRefs.count : hRefs.count))
        }

        // Components.
        var components: [String: Component] = [:]
        for s in [Side.base, .head] {
            let layout = side(s).layout
            for (id, info) in layout.components {
                let files = layout.fileComponent.filter { $0.value == id }.map(\.key)
                var c = components[id] ?? Component(
                    id: id, name: info.name, kind: info.kind, layer: info.layer, module: info.module, parent: info.parent,
                    isTest: info.isTest, paths: [], status: s == .base ? "removed" : "added",
                    changedEntities: 0, interfaceChanges: 0, changeScore: 0)
                if s == .head {
                    c.status = components[id] == nil ? "added" : nil
                    c.name = info.name; c.layer = info.layer; c.module = info.module; c.parent = info.parent; c.isTest = info.isTest
                }
                if s == .head || c.paths.isEmpty { c.paths = Self.minimalDirs(files) }
                components[id] = c
            }
        }
        for (id, name) in externalComponents where components[id] == nil {
            components[id] = Component(id: id, name: name, kind: .external, layer: nil, module: nil, parent: nil, isTest: false,
                                       paths: [], status: nil, changedEntities: 0, interfaceChanges: 0, changeScore: 0)
        }
        for e in entities where components[e.component] == nil {
            components[e.component] = Component(id: e.component, name: String(e.component.split(separator: ":").last ?? ""),
                                                kind: .folder, layer: nil, module: nil, parent: nil, isTest: false,
                                                paths: [], status: nil, changedEntities: 0, interfaceChanges: 0, changeScore: 0)
        }
        var raw: [String: Double] = [:]
        for e in entities where e.change != .cosmetic {
            components[e.component]!.changedEntities += 1
            let structural = e.change == .signature || e.change == .modifiers || e.change == .added || e.change == .removed || !e.contractFlags.isEmpty
            if e.isInterface && structural { components[e.component]!.interfaceChanges += 1 }
            var w = e.change == .body ? 1.0 : 1.5
            if e.isInterface && structural { w += 2 }
            w += Double(e.contractFlags.count)
            if e.tags.contains("test") || e.tags.contains("generated") { w *= 0.2 }
            raw[e.component, default: 0] += w
        }
        for e in edges where e.status != .unchanged {
            raw[e.from, default: 0] += 1
            raw[e.to, default: 0] += 0.5
        }
        let maxScore = raw.values.max() ?? 0
        for (id, v) in raw where components[id] != nil {
            components[id]!.changeScore = maxScore > 0 ? (v / maxScore * 1000).rounded() / 1000 : 0
        }
        externalDepsComponents(&components)
        // Components without Swift files (e.g. only Info.plist changed) take their paths from their entities.
        let entityFiles = Dictionary(grouping: entities.filter { $0.kind != .target }, by: \.component).mapValues { $0.map(\.location.file) }
        for (id, c) in components where c.paths.isEmpty && c.kind != .external {
            components[id]!.paths = Self.minimalDirs(entityFiles[id] ?? [])
        }

        let sortedWarnings = warnings.sorted { ($0.kind, $0.file ?? "", $0.line ?? 0, $0.message) < ($1.kind, $1.file ?? "", $1.line ?? 0, $1.message) }
        return ChangeModel(
            analyzer: AnalyzerInfo(version: Analyzer.version, resolution: "name-based"),
            repo: repo,
            components: components.values.sorted { $0.id < $1.id },
            edges: edges,
            externalDeps: externalDeps,
            entities: entities,
            regions: buildRegions(entities),
            warnings: sortedWarnings)
    }

    private func externalDepsComponents(_ components: inout [String: Component]) {
        for dep in externalDeps {
            let id = "ext:\(dep.name)"
            if components[id] == nil {
                components[id] = Component(id: id, name: dep.name, kind: .external, layer: nil, module: nil, parent: nil,
                                           isTest: false, paths: [], status: nil, changedEntities: 0, interfaceChanges: 0, changeScore: 0)
            }
            if dep.change == "added" { components[id]!.status = "added" }
            if dep.change == "removed" { components[id]!.status = "removed" }
        }
    }

    static func minimalDirs(_ files: [String]) -> [String] {
        let dirs = Set(files.map { ($0 as NSString).deletingLastPathComponent }).sorted()
        var result: [String] = []
        for d in dirs where !result.contains(where: { !$0.isEmpty && (d == $0 || d.hasPrefix($0 + "/")) }) {
            result.append(d.isEmpty ? "." : d)
        }
        return result
    }
}
