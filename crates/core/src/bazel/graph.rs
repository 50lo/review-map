//! The build graph of one side, as Bazel reports it: targets with the source files they own, their
//! declared dependencies, and their configuration.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
pub struct TargetNode {
    /// Relative to its workspace for the workspace's own targets ("//app:App"); canonical for external ones.
    pub label: String,
    pub rule_class: String,
    /// Source files the target lists, relative to the workspace. Only the workspace's own files.
    pub srcs: Vec<String>,
    /// Labels in the target's dependency attributes, as written in the BUILD file's terms.
    pub deps: Vec<String>,
    /// The Swift module the target compiles into, when it is a Swift target.
    pub module_name: Option<String>,
    pub testonly: bool,
    /// Checksums of the configurations the target was analyzed in; empty for an unconfigured graph.
    pub configs: Vec<String>,
    /// Attributes that change how the code compiles (compiler options, deployment targets), as text.
    pub settings: BTreeMap<String, String>,
    /// The BUILD file that declares the target, relative to the workspace.
    pub build_file: String,
    /// The line of `build_file` where the target's rule is declared; 0 when Bazel did not say.
    #[serde(default)]
    pub build_line: u32,
    pub external: bool,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
pub struct WorkspaceGraph {
    /// Repo-relative directory of the workspace ("" for the root).
    pub workspace: String,
    pub targets: BTreeMap<String, TargetNode>,
    /// The targets that define the review scope, and where they came from ("explicit", "xcodeproj", "all").
    pub scope_targets: Vec<String>,
    pub scope: String,
    /// True when the graph came from a configured query (cquery).
    pub configured: bool,
}

/// The graphs of the workspaces in scope at one side.
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
pub struct SideGraph {
    pub workspaces: Vec<WorkspaceGraph>,
}

impl SideGraph {
    pub fn workspace(&self, dir: &str) -> Option<&WorkspaceGraph> {
        self.workspaces.iter().find(|w| w.workspace == dir)
    }
}

/// "@@rules_swift_package_manager++swift_deps+swiftpkg_alamofire//:Alamofire" -> "alamofire";
/// "@maven//:com_squareup_okhttp3_okhttp" -> "com_squareup_okhttp3_okhttp".
pub fn external_name(label: &str) -> String {
    let trimmed = label.trim_start_matches('@');
    let (repo, rest) = trimmed.split_once("//").unwrap_or((trimmed, ""));
    // Bzlmod canonical names join the module, the extension, and the repo with "+" (or "~" before Bazel 8).
    let repo = repo.rsplit(['+', '~']).find(|s| !s.is_empty()).unwrap_or(repo);
    let target = rest.rsplit(':').next().unwrap_or("");
    if repo.contains("maven") && !target.is_empty() {
        return target.to_string();
    }
    repo.strip_prefix("swiftpkg_").unwrap_or(repo).to_string()
}

/// rules_swift derives a module name from a label when `module_name` is not set: the package and the
/// name joined by "_", with every character outside letters, digits, and "_" replaced by "_".
pub fn derived_module_name(label: &str) -> String {
    let body = label.trim_start_matches('@');
    let (_, path) = body.split_once("//").unwrap_or(("", body));
    let (package, name) = path.split_once(':').unwrap_or((path, path.rsplit('/').next().unwrap_or(path)));
    let joined = if package.is_empty() { name.to_string() } else { format!("{package}_{name}") };
    let mut out: String = joined.chars().map(|c| if c.is_ascii_alphanumeric() || c == '_' { c } else { '_' }).collect();
    if out.chars().next().map(|c| c.is_ascii_digit()).unwrap_or(false) {
        out.insert(0, '_');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names() {
        assert_eq!(external_name("@@rules_swift_package_manager++swift_deps+swiftpkg_alamofire//:Alamofire"), "alamofire");
        assert_eq!(external_name("@maven//:com_squareup_okhttp3_okhttp"), "com_squareup_okhttp3_okhttp");
        assert_eq!(external_name("@@rules_jvm_external++maven+maven//:androidx_core_core"), "androidx_core_core");
        assert_eq!(external_name("@@abseil-cpp+//absl/strings:strings"), "abseil-cpp");
        assert_eq!(derived_module_name("//Sources/Core:Core"), "Sources_Core_Core");
        assert_eq!(derived_module_name("//:App"), "App");
    }
}
