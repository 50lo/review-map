import Foundation

/// Swift: SwiftSyntax for parsing and risk marks, SPM and Xcode for components, Package.resolved for
/// pins, the Apple platform's non-code contracts, and the compiler's index store for exact references.
struct SwiftLanguage: Language {
    let id = "swift"
    let displayName = "Swift"

    func isSource(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return path.hasSuffix(".swift") && name != "Package.swift" && !name.hasPrefix("Package@swift")
    }

    func parse(path: String, source: String) -> ParsedFile {
        SwiftExtractor.parse(path: path, source: source)
    }

    let generatedPatterns = ["**/*.generated.swift", "**/R.generated.swift", "**/*+CoreDataProperties.swift", "**/*.pb.swift", "**/*.grpc.swift"]

    func addComponents(root: String, files: [String], options: AnalyzeOptions, layout: inout ComponentLayout) {
        SwiftComponents.add(root: root, files: files, dumpPackage: options.dumpPackage, layout: &layout)
    }

    let platformModules: Set<String> = [
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
        "SystemPackage", "XCUIAutomation", "SQLite3", "zlib", "Compression", "libkern", "CommonCrypto", "Cocoa", "ImagePlayground",
    ]

    /// Package.resolved pins, by package identity.
    func pinnedPackages(blobs: [String: String], dir: String) -> [String: String] {
        var result: [String: String] = [:]
        for path in blobs.keys.sorted() where path.hasSuffix("Package.resolved") {
            guard let data = FileManager.default.contents(atPath: dir + "/" + path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let list = (obj["pins"] as? [[String: Any]]) ?? ((obj["object"] as? [String: Any])?["pins"] as? [[String: Any]]) ?? []
            for pin in list {
                let identity = (pin["identity"] as? String)
                    ?? (pin["repositoryURL"] as? String).map(SwiftComponents.packageIdentity)
                    ?? (pin["package"] as? String)?.lowercased()
                guard let identity else { continue }
                let state = pin["state"] as? [String: Any] ?? [:]
                let v = (state["version"] as? String) ?? (state["branch"] as? String) ?? (state["revision"] as? String).map { String($0.prefix(8)) } ?? "?"
                result[identity.lowercased()] = v
            }
        }
        return result
    }

    /// Products listed by name only: the module matched to a pinned package identity
    /// ("SwiftSoup" -> "swiftsoup", "Collections" -> "swift-collections").
    func package(ofModule module: String, pinned: Set<String>) -> String? {
        func norm(_ s: String) -> String {
            var x = s.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
            for affix in ["swift", "ios", "spm", "kit"] where x.count > affix.count + 2 {
                if x.hasPrefix(affix) { x.removeFirst(affix.count) }
                if x.hasSuffix(affix) { x.removeLast(affix.count) }
            }
            return x
        }
        let m = module.lowercased()
        return pinned.sorted().first { $0 == m || norm($0) == norm(m) }
    }

    // MARK: Contracts and risk

    func contractFlags(_ builder: ModelBuilder, pairs: [Int]) -> [Int: [String]] {
        SwiftFlags(builder, pairs: pairs).compute()
    }

    func contractFile(_ path: String) -> (key: String, flag: String)? {
        let name = (path as NSString).lastPathComponent
        if let r = path.range(of: ".xcdatamodeld/") {
            return (String(path[..<r.lowerBound]) + ".xcdatamodeld", "coredata-model-changed")
        }
        if name == "PrivacyInfo.xcprivacy" { return (path, "privacy-manifest-changed") }
        if name.hasSuffix(".entitlements") { return (path, "entitlements-changed") }
        if name == "Info.plist" || name.hasSuffix("-Info.plist") { return (path, "info-plist-changed") }
        return nil
    }

    func contractFileFlags(key: String, flag: String, basePath: String, headPath: String) -> [String] {
        guard flag == "info-plist-changed", Self.urlSchemes(basePath) != Self.urlSchemes(headPath) else { return [] }
        return ["url-schemes-changed"]
    }

    private static func urlSchemes(_ path: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let types = plist["CFBundleURLTypes"] as? [[String: Any]] else { return [] }
        return types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }.sorted()
    }

    func settingFlag(_ key: String) -> String {
        let lk = key.lowercased()
        if lk.contains("defaultisolation") || lk.contains("default_actor_isolation") { return "default-isolation-changed" }
        if lk.contains("strict") && lk.contains("concurrency") || lk.contains("approachable") { return "strict-concurrency-changed" }
        if lk.contains("upcomingfeature") || lk.contains("upcoming_feature") || lk.contains("enableexperimentalfeature") { return "swift-features-changed" }
        if lk.contains("swift_version") || lk.contains("swiftlanguagemode") { return "swift-version-changed" }
        if lk.contains("deployment_target") { return "deployment-target-changed" }
        return "build-settings-changed"
    }

    private static let concurrencyFlags = ["mainactor-", "nonisolated-", "sendable-", "async-", "conformance-isolation-changed",
                                           "kind-changed", "default-isolation-changed", "strict-concurrency-changed"]
    private static let persistenceFlags: Set<String> = ["codable-shape", "swiftdata-model-changed", "coredata-model-changed"]
    private static let configFlags: Set<String> = ["info-plist-changed", "build-settings-changed", "deployment-target-changed",
                                                   "swift-version-changed", "swift-features-changed"]

    /// Concurrency and persisted-model flags are high, configuration flags medium, and the rest high on
    /// an interface and medium elsewhere.
    func flagRisk(_ flag: String, isInterface: Bool) -> Double {
        if Self.concurrencyFlags.contains(where: { flag.hasPrefix($0) }) || Self.persistenceFlags.contains(flag) { return RiskWeight.high }
        if Self.configFlags.contains(flag) { return RiskWeight.medium }
        return isInterface ? RiskWeight.high : RiskWeight.medium
    }

    /// SwiftUI: a `View` or `ViewModifier` type, or a declaration of `some View`.
    func isViewCode(_ d: Declaration, inherits: Set<String>) -> Bool {
        d.signatureDisplay.contains("some View") || (d.typeAnnotation ?? "").contains("View")
            || inherits.contains("View") || inherits.contains("ViewModifier")
    }

    // MARK: Structural review

    func isPublicAPI(_ decl: Declaration, enclosing: [Declaration]) -> Bool {
        ["public", "open", "package"].contains(decl.access ?? "")
    }

    /// Special members, operators, and declarations a runtime or framework calls: `@objc`,
    /// Interface Builder, `@main`, C entry points, and inlinable code that clients compile in.
    func isImplicitlyCalled(_ decl: Declaration) -> Bool {
        if Self.implicitNames.contains(decl.name) || !(decl.name.first.map { $0.isLetter || $0 == "_" || $0 == "$" } ?? false) { return true }
        return decl.attributes.contains { Self.entryAttributes.contains($0) || $0.hasPrefix("IB") }
    }

    private static let implicitNames: Set<String> = ["init", "deinit", "subscript", "body", "main"]
    private static let entryAttributes: Set<String> = [
        "objc", "main", "UIApplicationMain", "NSApplicationMain", "_cdecl", "_silgen_name", "_spi",
        "usableFromInline", "inlinable", "dynamicCallable", "dynamicMemberLookup",
    ]

    /// The isolation code at `line` runs in, from the innermost declaration around it that says:
    /// a global actor attribute ("@MainActor"), `nonisolated`, an actor ("actor CartStore"), or a SwiftUI view.
    func isolation(in file: ParsedFile, line: Int) -> String? {
        var cur: Int? = nil
        var size = Int.max
        for (i, d) in file.decls.enumerated() where d.startLine <= line && line <= d.endLine && d.endLine - d.startLine <= size {
            cur = i
            size = d.endLine - d.startLine
        }
        while let i = cur {
            let d = file.decls[i]
            if d.modifiers.contains(where: { $0.hasPrefix("nonisolated") }) { return "nonisolated" }
            if let a = d.attributes.first(where: { $0.hasSuffix("Actor") }) { return "@" + a }
            if d.kind == .actor { return "actor \(d.qualifiedName)" }
            // SwiftUI's View is @MainActor, and so are the types that conform to it.
            if d.isContainer && d.inherited.contains(where: { ModelBuilder.conformanceName($0) == "View" }) {
                return "@MainActor"
            }
            cur = d.parentIndex
        }
        return nil
    }

    // MARK: Resolution

    func index(options: IndexOptions, repoRoot: String, sides: [IndexSide], log: (String) -> Void) throws -> [Side: SideIndex]? {
        try IndexBuilder.load(options: options, repoRoot: repoRoot, sides: sides, log: log)
    }
}
