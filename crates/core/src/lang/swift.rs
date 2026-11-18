//! Swift: the Apple platform's modules and non-code contracts, Package.resolved pins, contract flags,
//! and isolation. A port of the prototype's `SwiftLanguage.swift` and `SwiftFlags.swift`.

use super::{inherited_names, risk, Language};
use crate::analyze::{conformance_name, kind_group, Builder, SideData, SideSource};
use crate::model::{ChangeKind, ItemKind, Side};
use crate::parse::{Declaration, ParsedFile};
use crate::paths::file_name;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

pub struct SwiftLanguage;

const PLATFORM_MODULES: &[&str] = &[
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
];

const CONCURRENCY_FLAGS: &[&str] = &[
    "mainactor-", "nonisolated-", "sendable-", "async-", "conformance-isolation-changed", "kind-changed", "default-isolation-changed",
    "strict-concurrency-changed",
];
const PERSISTENCE_FLAGS: &[&str] = &["codable-shape", "swiftdata-model-changed", "coredata-model-changed"];
const CONFIG_FLAGS: &[&str] =
    &["info-plist-changed", "build-settings-changed", "deployment-target-changed", "swift-version-changed", "swift-features-changed"];
const IMPLICIT_NAMES: &[&str] = &["init", "deinit", "subscript", "body", "main"];
const ENTRY_ATTRIBUTES: &[&str] = &[
    "objc", "main", "UIApplicationMain", "NSApplicationMain", "_cdecl", "_silgen_name", "_spi", "usableFromInline", "inlinable",
    "dynamicCallable", "dynamicMemberLookup",
];
const CODABLE_NAMES: &[&str] = &["Codable", "Encodable", "Decodable"];
const OBSERVABLE_ATTRS: &[&str] = &["Published", "State", "Observable", "ObservationTracked", "Bindable", "AppStorage", "SceneStorage"];

/// "https://github.com/apple/swift-collections.git" -> "swift-collections".
pub fn package_identity(url: &str) -> String {
    let trimmed = url.trim_end_matches('/');
    let last = trimmed.rsplit(['/', ':']).next().unwrap_or(trimmed);
    last.trim_end_matches(".git").to_lowercase()
}

fn url_schemes(bytes: Option<Vec<u8>>) -> Vec<String> {
    let Some(bytes) = bytes else { return Vec::new() };
    let Ok(value) = plist::Value::from_reader(std::io::Cursor::new(bytes)) else { return Vec::new() };
    let mut out = Vec::new();
    if let Some(types) = value.as_dictionary().and_then(|d| d.get("CFBundleURLTypes")).and_then(|v| v.as_array()) {
        for t in types {
            if let Some(schemes) = t.as_dictionary().and_then(|d| d.get("CFBundleURLSchemes")).and_then(|v| v.as_array()) {
                out.extend(schemes.iter().filter_map(|s| s.as_string().map(str::to_string)));
            }
        }
    }
    out.sort();
    out
}

impl Language for SwiftLanguage {
    fn id(&self) -> &'static str {
        "swift"
    }

    fn display_name(&self) -> &'static str {
        "Swift"
    }

    fn is_source(&self, path: &str) -> bool {
        let name = file_name(path);
        path.ends_with(".swift") && name != "Package.swift" && !name.starts_with("Package@swift")
    }

    fn generated_patterns(&self) -> &'static [&'static str] {
        &["**/*.generated.swift", "**/R.generated.swift", "**/*+CoreDataProperties.swift", "**/*.pb.swift", "**/*.grpc.swift"]
    }

    fn is_platform_module(&self, module: &str) -> bool {
        PLATFORM_MODULES.contains(&module)
    }

    /// Package.resolved pins, by package identity.
    fn pinned_packages(&self, side: &SideSource) -> BTreeMap<String, String> {
        let mut result = BTreeMap::new();
        for path in side.tree.keys().filter(|p| p.ends_with("Package.resolved")) {
            let Some(bytes) = side.bytes(path) else { continue };
            let Ok(obj) = serde_json::from_slice::<serde_json::Value>(&bytes) else { continue };
            let list = obj.get("pins").and_then(|v| v.as_array()).or_else(|| obj.get("object").and_then(|o| o.get("pins")).and_then(|v| v.as_array()));
            for pin in list.into_iter().flatten() {
                let identity = pin
                    .get("identity")
                    .and_then(|v| v.as_str())
                    .map(str::to_string)
                    .or_else(|| pin.get("repositoryURL").and_then(|v| v.as_str()).map(package_identity))
                    .or_else(|| pin.get("package").and_then(|v| v.as_str()).map(|s| s.to_lowercase()));
                let Some(identity) = identity else { continue };
                let state = pin.get("state");
                let get = |k: &str| state.and_then(|s| s.get(k)).and_then(|v| v.as_str());
                let version = get("version")
                    .map(str::to_string)
                    .or_else(|| get("branch").map(str::to_string))
                    .or_else(|| get("revision").map(|r| r.chars().take(8).collect()))
                    .unwrap_or_else(|| "?".to_string());
                result.insert(identity.to_lowercase(), version);
            }
        }
        result
    }

    /// Products listed by name only: the module matched to a pinned package identity
    /// ("SwiftSoup" -> "swiftsoup", "Collections" -> "swift-collections").
    fn package_of_module(&self, module: &str, pinned: &BTreeSet<String>) -> Option<String> {
        fn norm(s: &str) -> String {
            let mut x = s.replace(['-', '_'], "");
            for affix in ["swift", "ios", "spm", "kit"] {
                if x.len() > affix.len() + 2 {
                    if x.starts_with(affix) {
                        x = x[affix.len()..].to_string();
                    }
                    if x.ends_with(affix) && x.len() >= affix.len() {
                        x.truncate(x.len() - affix.len());
                    }
                }
            }
            x
        }
        let m = module.to_lowercase();
        pinned.iter().find(|p| **p == m || norm(p) == norm(&m)).cloned()
    }

    fn contract_flags(&self, builder: &Builder, pairs: &[usize]) -> HashMap<usize, Vec<String>> {
        flags(builder, pairs)
    }

    fn contract_file(&self, path: &str) -> Option<(String, String)> {
        let name = file_name(path);
        if let Some(i) = path.find(".xcdatamodeld/") {
            return Some((format!("{}.xcdatamodeld", &path[..i]), "coredata-model-changed".to_string()));
        }
        if name == "PrivacyInfo.xcprivacy" {
            return Some((path.to_string(), "privacy-manifest-changed".to_string()));
        }
        if name.ends_with(".entitlements") {
            return Some((path.to_string(), "entitlements-changed".to_string()));
        }
        if name == "Info.plist" || name.ends_with("-Info.plist") {
            return Some((path.to_string(), "info-plist-changed".to_string()));
        }
        None
    }

    fn contract_file_flags(&self, key: &str, flag: &str, base: &SideSource, head: &SideSource) -> Vec<String> {
        if flag == "info-plist-changed" && url_schemes(base.bytes(key)) != url_schemes(head.bytes(key)) {
            return vec!["url-schemes-changed".to_string()];
        }
        Vec::new()
    }

    fn setting_flag(&self, key: &str) -> String {
        let lk = key.to_lowercase();
        let flag = if lk.contains("defaultisolation") || lk.contains("default_actor_isolation") || lk.contains("default-isolation") {
            "default-isolation-changed"
        } else if (lk.contains("strict") && lk.contains("concurrency")) || lk.contains("approachable") {
            "strict-concurrency-changed"
        } else if lk.contains("upcomingfeature") || lk.contains("upcoming_feature") || lk.contains("upcoming-feature") || lk.contains("experimental-feature")
            || lk.contains("enableexperimentalfeature")
        {
            "swift-features-changed"
        } else if lk.contains("swift_version") || lk.contains("swift-version") || lk.contains("swiftlanguagemode") {
            "swift-version-changed"
        } else if lk.contains("deployment_target") || lk.contains("minimum_os_version") || lk.contains("minimum_deployment_os_version") {
            "deployment-target-changed"
        } else {
            "build-settings-changed"
        };
        flag.to_string()
    }

    /// Concurrency and persisted-model flags are high, configuration flags medium, and the rest high on
    /// an interface and medium elsewhere.
    fn flag_risk(&self, flag: &str, is_interface: bool) -> f64 {
        if CONCURRENCY_FLAGS.iter().any(|p| flag.starts_with(p)) || PERSISTENCE_FLAGS.contains(&flag) {
            return risk::HIGH;
        }
        if CONFIG_FLAGS.contains(&flag) {
            return risk::MEDIUM;
        }
        if is_interface {
            risk::HIGH
        } else {
            risk::MEDIUM
        }
    }

    /// SwiftUI: a `View` or `ViewModifier` type, or a declaration of `some View`.
    fn is_view_code(&self, d: &Declaration, inherits: &HashSet<String>) -> bool {
        d.signature_display.contains("some View")
            || d.type_annotation.as_deref().unwrap_or("").contains("View")
            || inherits.contains("View")
            || inherits.contains("ViewModifier")
    }

    fn is_public_api(&self, decl: &Declaration, _enclosing: &[&Declaration]) -> bool {
        matches!(decl.access.as_deref(), Some("public") | Some("open") | Some("package"))
    }

    /// Special members, operators, and declarations a runtime or framework calls: `@objc`,
    /// Interface Builder, `@main`, C entry points, and inlinable code that clients compile in.
    fn is_implicitly_called(&self, decl: &Declaration) -> bool {
        let starts_like_name = decl.name.chars().next().map(|c| c.is_alphabetic() || c == '_' || c == '$').unwrap_or(false);
        if IMPLICIT_NAMES.contains(&decl.name.as_str()) || !starts_like_name {
            return true;
        }
        decl.attributes.iter().any(|a| ENTRY_ATTRIBUTES.contains(&a.as_str()) || a.starts_with("IB"))
    }

    /// The isolation code at `line` runs in, from the innermost declaration around it that says:
    /// a global actor attribute ("@MainActor"), `nonisolated`, an actor ("actor CartStore"), or a SwiftUI view.
    fn isolation(&self, file: &ParsedFile, line: u32) -> Option<String> {
        let mut cur: Option<usize> = None;
        let mut size = u32::MAX;
        for (i, d) in file.decls.iter().enumerate() {
            if d.start_line <= line && line <= d.end_line && d.end_line - d.start_line <= size {
                cur = Some(i);
                size = d.end_line - d.start_line;
            }
        }
        while let Some(i) = cur {
            let d = &file.decls[i];
            if d.modifiers.iter().any(|m| m.starts_with("nonisolated")) {
                return Some("nonisolated".to_string());
            }
            if let Some(a) = d.attributes.iter().find(|a| a.ends_with("Actor")) {
                return Some(format!("@{a}"));
            }
            if d.kind == ItemKind::Actor {
                return Some(format!("actor {}", d.qualified_name));
            }
            // SwiftUI's View is @MainActor, and so are the types that conform to it.
            if d.is_container() && inherited_names(d).any(|n| n == "View") {
                return Some("@MainActor".to_string());
            }
            cur = d.parent_index;
        }
        None
    }
}

// MARK: Contract flags

/// Types (by component + qualified name) with a given trait on one side, including conformances added in extensions.
fn types_where(s: &SideData, pred: &dyn Fn(&Declaration) -> bool) -> HashSet<String> {
    let mut result = HashSet::new();
    for (path, file) in s.files() {
        if file.language != "swift" {
            continue;
        }
        let Some(comp) = s.layout.file_component.get(path) else { continue };
        for d in &file.decls {
            if d.is_container() && pred(d) {
                result.insert(format!("{comp}|{}", d.type_name()));
            }
        }
    }
    result
}

/// Effective conformances per "component|Type": name -> isolation attributes ("" when none).
fn conformances(s: &SideData) -> HashMap<String, BTreeMap<String, String>> {
    let mut result: HashMap<String, BTreeMap<String, String>> = HashMap::new();
    for (path, file) in s.files() {
        if file.language != "swift" {
            continue;
        }
        let Some(comp) = s.layout.file_component.get(path) else { continue };
        for d in &file.decls {
            if !d.is_container() {
                continue;
            }
            let key = format!("{comp}|{}", d.type_name());
            for c in &d.inherited {
                let parts: Vec<&str> = c.split(' ').filter(|p| !p.is_empty()).collect();
                let attrs: Vec<&str> = parts[..parts.len().saturating_sub(1)]
                    .iter()
                    .copied()
                    .filter(|p| *p != "@unchecked" && *p != "@retroactive" && *p != "@preconcurrency")
                    .collect();
                result.entry(key.clone()).or_default().insert(conformance_name(c).to_string(), attrs.join(" "));
            }
            if d.attributes.iter().any(|a| a == "Sendable") {
                result.entry(key.clone()).or_default().insert("Sendable".to_string(), String::new());
            }
        }
    }
    result
}

fn has_attr(d: &Declaration, name: &str) -> bool {
    d.attributes.iter().any(|a| a == name)
}

/// Swift's contract flags: changes to declarations that callers, persisted data, or isolation depend on.
fn flags(builder: &Builder, indices: &[usize]) -> HashMap<usize, Vec<String>> {
    let pairs = &builder.pairs;
    let is_codable = |d: &Declaration| inherited_names(d).any(|n| CODABLE_NAMES.contains(&n));
    let union = |pred: &dyn Fn(&Declaration) -> bool| -> HashSet<String> {
        let mut a = types_where(builder.base, pred);
        a.extend(types_where(builder.head, pred));
        a
    };
    let codable = union(&is_codable);
    let models = union(&|d: &Declaration| has_attr(d, "Model"));
    // With @Observable every stored property is tracked state; with ObservableObject only @Published ones are.
    let observable = union(&|d: &Declaration| has_attr(d, "Observable"));

    let base_conf = conformances(builder.base);
    let head_conf = conformances(builder.head);
    let empty: BTreeMap<String, String> = BTreeMap::new();
    let mut type_declared: HashSet<String> = HashSet::new();
    for &i in indices {
        let p = &pairs[i];
        let d = p.any().decl();
        if d.is_container() && d.kind != ItemKind::Extension && p.base.is_some() && p.head.is_some() {
            type_declared.insert(format!("{}|{}", p.any().component, d.qualified_name));
        }
    }
    let mut out: HashMap<usize, Vec<String>> = HashMap::new();
    let mut parent_flags: BTreeMap<usize, BTreeSet<String>> = BTreeMap::new();
    for &i in indices {
        let p = &pairs[i];
        let b = p.base.as_ref().map(|l| l.decl());
        let h = p.head.as_ref().map(|l| l.decl());
        let d = p.any().decl();
        let s = p.side();
        let comp = &p.any().component;
        let mut flags: Vec<String> = Vec::new();
        let added = b.is_none();
        let removed = h.is_none();
        let changed = p.is_changed();

        if let (Some(b), Some(h)) = (b, h) {
            let ba = b.access.as_deref().unwrap_or("internal");
            let ha = h.access.as_deref().unwrap_or("internal");
            if ba != ha {
                flags.push(format!("access-changed:{ba}->{ha}"));
            }
            if b.is_async != h.is_async {
                flags.push(if h.is_async { "async-added" } else { "async-removed" }.to_string());
            }
            if b.is_throws != h.is_throws {
                flags.push(if h.is_throws { "throws-added" } else { "throws-removed" }.to_string());
            } else if b.is_throws && b.throws_type != h.throws_type {
                flags.push("typed-throws-changed".to_string());
            }
            let (bm, hm) = (has_attr(b, "MainActor"), has_attr(h, "MainActor"));
            if bm != hm {
                flags.push(if hm { "mainactor-added" } else { "mainactor-removed" }.to_string());
            }
            let bn = b.modifiers.iter().any(|m| m.starts_with("nonisolated"));
            let hn = h.modifiers.iter().any(|m| m.starts_with("nonisolated"));
            if bn != hn {
                flags.push(if hn { "nonisolated-added" } else { "nonisolated-removed" }.to_string());
            }
            if !b.is_container() {
                let (bs, hs) = (has_attr(b, "Sendable"), has_attr(h, "Sendable"));
                if bs != hs {
                    flags.push(if hs { "sendable-added" } else { "sendable-removed" }.to_string());
                }
            }
            if b.kind != h.kind && kind_group(b.kind) == "type" {
                flags.push(format!("kind-changed:{}->{}", b.kind.raw(), h.kind.raw()));
            }
            if b.kind != ItemKind::Extension || !type_declared.contains(&format!("{comp}|{}", b.name)) {
                // Conformances are compared per type, across the type and its extensions in the component,
                // so moving a conformance into an extension is not a change.
                let key = format!("{comp}|{}", b.type_name());
                let bc = base_conf.get(&key).unwrap_or(&empty);
                let hc = head_conf.get(&key).unwrap_or(&empty);
                for c in hc.keys().filter(|c| !bc.contains_key(*c) && *c != "Sendable") {
                    flags.push(format!("conformance-added:{c}"));
                }
                for c in bc.keys().filter(|c| !hc.contains_key(*c) && *c != "Sendable") {
                    flags.push(format!("conformance-removed:{c}"));
                }
                for c in bc.keys().filter(|c| hc.contains_key(*c)) {
                    if bc.get(c) != hc.get(c) {
                        flags.push(format!("conformance-isolation-changed:{c}"));
                    }
                }
                if bc.contains_key("Sendable") != hc.contains_key("Sendable") && !flags.iter().any(|f| f.starts_with("sendable-")) {
                    flags.push(if hc.contains_key("Sendable") { "sendable-added" } else { "sendable-removed" }.to_string());
                }
            }
            let (bo, ho) = (has_attr(b, "Observable"), has_attr(h, "Observable"));
            if bo != ho {
                flags.push(if ho { "observable-added" } else { "observable-removed" }.to_string());
            }
            if has_attr(b, "Model") != has_attr(h, "Model") {
                flags.push("swiftdata-model-changed".to_string());
            }
        } else if d.kind == ItemKind::Extension {
            // A new or deleted extension: report conformances that the type gained or lost overall.
            let key = format!("{comp}|{}", d.name);
            let bc = base_conf.get(&key).unwrap_or(&empty);
            let hc = head_conf.get(&key).unwrap_or(&empty);
            for c in inherited_names(d).filter(|c| *c != "Sendable") {
                if added && !bc.contains_key(c) {
                    flags.push(format!("conformance-added:{c}"));
                }
                if removed && !hc.contains_key(c) {
                    flags.push(format!("conformance-removed:{c}"));
                }
                if added {
                    if let Some(old) = bc.get(c) {
                        if Some(old) != hc.get(c) {
                            flags.push(format!("conformance-isolation-changed:{c}"));
                        }
                    }
                }
            }
        }

        let mut to_parent: Vec<String> = Vec::new();
        let parent_kind = d.parent_kind;
        if parent_kind == Some(ItemKind::Protocol) && (added || removed || (changed && p.changes.iter().any(|c| *c != ChangeKind::Body))) {
            let f = if added {
                "protocol-requirement-added"
            } else if removed {
                "protocol-requirement-removed"
            } else {
                "protocol-requirement-changed"
            };
            flags.push(f.to_string());
            to_parent.push(f.to_string());
        }
        if d.kind == ItemKind::Case && parent_kind == Some(ItemKind::Enum) && (added || removed || p.changes.contains(&ChangeKind::Signature)) {
            let f = if added {
                "enum-case-added"
            } else if removed {
                "enum-case-removed"
            } else {
                "enum-case-changed"
            };
            flags.push(f.to_string());
            to_parent.push(f.to_string());
        }
        let scope_key = format!("{comp}|{}", d.scope.as_deref().unwrap_or(""));
        let structural = added || removed || p.changes.contains(&ChangeKind::Signature) || p.changes.contains(&ChangeKind::Modifiers);
        if d.kind == ItemKind::Var && d.is_stored && !d.is_static && structural {
            if codable.contains(&scope_key) {
                flags.push("codable-shape".to_string());
                to_parent.push("codable-shape".to_string());
            }
            if models.contains(&scope_key) {
                flags.push("swiftdata-model-changed".to_string());
                to_parent.push("swiftdata-model-changed".to_string());
            }
            let attrs: HashSet<&str> =
                b.into_iter().chain(h).flat_map(|x| x.attributes.iter().map(String::as_str)).collect();
            if !attrs.contains("ObservationIgnored") && (observable.contains(&scope_key) || attrs.iter().any(|a| OBSERVABLE_ATTRS.contains(a))) {
                flags.push("observable-state-changed".to_string());
                to_parent.push("observable-state-changed".to_string());
            }
        }
        // Members of a nested CodingKeys enum shape the parent's encoding.
        if let Some(scope) = &d.scope {
            if scope.ends_with(".CodingKeys") && d.kind == ItemKind::Case && (added || removed || changed) {
                flags.push("codable-shape".to_string());
                let owner = &scope[..scope.len() - ".CodingKeys".len()];
                if let Some(&oi) = indices.iter().find(|&&x| {
                    let o = pairs[x].any();
                    o.component == *comp && o.decl().qualified_name == owner && o.decl().kind != ItemKind::Extension
                }) {
                    parent_flags.entry(oi).or_default().insert("codable-shape".to_string());
                }
            }
        }
        let parent_idx = builder.parent_pair(p.any(), s);
        if let Some(pi) = parent_idx {
            if pairs[pi].base.is_none() || pairs[pi].head.is_none() {
                // A member of a new or deleted type: the type itself carries the flag; repeating it on every
                // member is noise.
                const MEMBER_LEVEL: &[&str] = &[
                    "protocol-requirement-added", "protocol-requirement-removed", "enum-case-added", "enum-case-removed", "codable-shape",
                    "swiftdata-model-changed", "observable-state-changed",
                ];
                flags.retain(|f| !MEMBER_LEVEL.contains(&f.as_str()));
            }
        }
        out.insert(i, flags);
        if !to_parent.is_empty() {
            if let Some(pp) = parent_idx {
                if pairs[pp].base.is_some() && pairs[pp].head.is_some() {
                    parent_flags.entry(pp).or_default().extend(to_parent);
                }
            }
        }
    }
    for (pi, fl) in parent_flags {
        let list = out.entry(pi).or_default();
        for f in fl {
            if !list.contains(&f) {
                list.push(f);
            }
        }
    }
    let _ = Side::Base;
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identities_and_settings() {
        assert_eq!(package_identity("https://github.com/apple/swift-collections.git"), "swift-collections");
        assert_eq!(package_identity("git@github.com:kylef/PathKit.git"), "pathkit");
        let l = SwiftLanguage;
        assert_eq!(l.setting_flag("copts -strict-concurrency=complete"), "strict-concurrency-changed");
        assert_eq!(l.setting_flag("minimum_os_version"), "deployment-target-changed");
        let pinned: BTreeSet<String> = ["swift-collections".to_string(), "swiftsoup".to_string()].into();
        assert_eq!(l.package_of_module("Collections", &pinned).as_deref(), Some("swift-collections"));
        assert_eq!(l.package_of_module("SwiftSoup", &pinned).as_deref(), Some("swiftsoup"));
    }
}
