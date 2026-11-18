//! The shared Bazel foundation: workspace discovery, app-owned reusable workspaces, and queries for
//! target dependencies, source ownership, and configuration.

pub mod cache;
pub mod graph;
pub mod jobs;
pub mod query;
pub mod workspace;

use crate::git::Tree;
use crate::paths::{file_name, is_under, parent};
use std::collections::BTreeSet;

pub const WORKSPACE_FILES: &[&str] = &["MODULE.bazel", "WORKSPACE", "WORKSPACE.bazel"];
pub const BUILD_FILES: &[&str] = &["BUILD.bazel", "BUILD"];

/// Every Bazel workspace in a tree, repo-relative ("" for the root), nested ones included.
pub fn discover_workspaces(tree: &Tree) -> Vec<String> {
    let mut found: BTreeSet<String> = BTreeSet::new();
    for path in tree.keys() {
        if WORKSPACE_FILES.contains(&file_name(path)) {
            found.insert(parent(path).to_string());
        }
    }
    found.into_iter().collect()
}

/// The innermost workspace that contains `path`.
pub fn workspace_of<'a>(workspaces: &'a [String], path: &str) -> Option<&'a str> {
    workspaces.iter().filter(|w| is_under(path, w)).max_by_key(|w| w.len()).map(String::as_str)
}

/// The Bazel package of a file: the nearest directory at or above it that has a BUILD file, inside its
/// workspace. Repo-relative; None when no BUILD file is above the file in its workspace.
pub fn package_of(tree: &Tree, workspace: &str, path: &str) -> Option<String> {
    let mut dir = parent(path).to_string();
    loop {
        if BUILD_FILES.iter().any(|b| tree.contains_key(&crate::paths::join(&dir, b))) {
            return Some(dir);
        }
        if dir == workspace || dir.is_empty() || !is_under(&dir, workspace) {
            return None;
        }
        dir = parent(&dir).to_string();
    }
}

/// `top_level_targets` of the rules_xcodeproj `xcodeproj` rules in a BUILD file, as labels.
pub fn xcodeproj_targets(build_file: &str) -> Vec<String> {
    let mut labels: Vec<String> = Vec::new();
    let mut rest = build_file;
    while let Some(i) = rest.find("top_level_targets") {
        rest = &rest[i + "top_level_targets".len()..];
        let Some(open) = rest.find('[') else { break };
        // Only an assignment: `top_level_targets = [`.
        if !rest[..open].chars().all(|c| c == ' ' || c == '=' || c == '\n' || c == '\t') {
            continue;
        }
        let mut depth = 0i32;
        let mut end = open;
        for (j, c) in rest[open..].char_indices() {
            if c == '[' {
                depth += 1;
            } else if c == ']' {
                depth -= 1;
                if depth == 0 {
                    end = open + j;
                    break;
                }
            }
        }
        let list = &rest[open..=end];
        let mut pos = 0;
        while let Some(q) = list[pos..].find('"') {
            let start = pos + q + 1;
            let Some(close) = list[start..].find('"') else { break };
            let s = &list[start..start + close];
            if s.starts_with("//") || s.starts_with('@') {
                labels.push(s.to_string());
            } else if s.starts_with(':') {
                labels.push(format!("//{s}"));
            }
            pos = start + close + 1;
        }
        rest = &rest[end..];
    }
    let mut seen = BTreeSet::new();
    labels.into_iter().filter(|l| seen.insert(l.clone())).collect()
}

/// The name a workspace gives a Bazel module: a `repo_name` on its `bazel_dep`, else the module's own name.
pub fn module_repo_name(module_bazel: &str, module: &str) -> String {
    let deps = regex::Regex::new(r"bazel_dep\s*\(([^)]*)\)").unwrap();
    let value = |key: &str, args: &str| -> Option<String> {
        let re = regex::Regex::new(&format!(r#"(?:^|[^\w]){key}\s*=\s*(?:"([^"]*)"|'([^']*)')"#)).ok()?;
        let caps = re.captures(args)?;
        caps.get(1).or_else(|| caps.get(2)).map(|m| m.as_str().to_string())
    };
    for caps in deps.captures_iter(module_bazel) {
        let args = &caps[1];
        if value("name", args).as_deref() == Some(module) {
            return value("repo_name", args).unwrap_or_else(|| module.to_string());
        }
    }
    module.to_string()
}

/// The modules a MODULE.bazel depends on, with their versions ("" when it has none, as with an override).
pub fn module_deps(module_bazel: &str) -> Vec<(String, String)> {
    let deps = regex::Regex::new(r"bazel_dep\s*\(([^)]*)\)").unwrap();
    let value = |key: &str, args: &str| -> Option<String> {
        let re = regex::Regex::new(&format!(r#"(?:^|[^\w]){key}\s*=\s*(?:"([^"]*)"|'([^']*)')"#)).ok()?;
        let caps = re.captures(args)?;
        caps.get(1).or_else(|| caps.get(2)).map(|m| m.as_str().to_string())
    };
    let mut out = Vec::new();
    for caps in deps.captures_iter(module_bazel) {
        let args = &caps[1];
        if let Some(name) = value("name", args) {
            out.push((name, value("version", args).unwrap_or_default()));
        }
    }
    out
}

/// Whether a workspace depends on a Bazel module: a `bazel_dep` in its MODULE.bazel or in a file that one
/// includes, or the module's name in a WORKSPACE file. `read` gives the text of a file by its path relative
/// to the workspace.
pub fn uses_module(read: &dyn Fn(&str) -> Option<String>, module: &str) -> bool {
    let include = regex::Regex::new(r#"include\s*\(\s*["']//([^"':]*):([^"']+)["']\s*\)"#).unwrap();
    let mut seen: BTreeSet<String> = BTreeSet::new();
    let mut queue = vec!["MODULE.bazel".to_string()];
    while let Some(path) = queue.pop() {
        if !seen.insert(path.clone()) {
            continue;
        }
        let Some(text) = read(&path) else { continue };
        if module_deps(&text).iter().any(|(name, _)| name == module) {
            return true;
        }
        for caps in include.captures_iter(&text) {
            queue.push(crate::paths::join(&caps[1], &caps[2]));
        }
    }
    ["WORKSPACE", "WORKSPACE.bazel"].iter().any(|f| read(f).map(|text| text.contains(module)).unwrap_or(false))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn xcodeproj_rule_targets() {
        let text = "xcodeproj(\n    name = \"xcodeproj\",\n    top_level_targets = [\n        \"//App:App\",\n        top_level_target(\":Tests\", target_environments = [\"simulator\"]),\n    ],\n)\n";
        assert_eq!(xcodeproj_targets(text), vec!["//App:App".to_string(), "//:Tests".to_string()]);
    }

    #[test]
    fn module_names() {
        let text = "bazel_dep(name = \"rules_java\", version = \"9.9.0\")\nbazel_dep(version = '2.4.21', repo_name = 'io_bazel_rules_kotlin', name = 'rules_kotlin')\n";
        assert_eq!(module_repo_name(text, "rules_kotlin"), "io_bazel_rules_kotlin");
        assert_eq!(module_repo_name(text, "rules_swift"), "rules_swift");
        assert_eq!(module_deps(text), vec![("rules_java".to_string(), "9.9.0".to_string()), ("rules_kotlin".to_string(), "2.4.21".to_string())]);
    }

    #[test]
    fn modules_a_workspace_uses() {
        let files = |path: &str| -> Option<String> {
            match path {
                "MODULE.bazel" => Some("bazel_dep(name = \"rules_swift\", version = \"3.6.1\")\ninclude(\"//bazel:jvm.MODULE.bazel\")\n".to_string()),
                "bazel/jvm.MODULE.bazel" => Some("bazel_dep(name = \"rules_kotlin\", version = \"2.4.21\")\n".to_string()),
                _ => None,
            }
        };
        assert!(uses_module(&files, "rules_swift"));
        assert!(uses_module(&files, "rules_kotlin"), "through the included file");
        assert!(!uses_module(&files, "rules_go"));
        let legacy = |path: &str| (path == "WORKSPACE").then(|| "http_archive(name = \"rules_kotlin\")\n".to_string());
        assert!(uses_module(&legacy, "rules_kotlin"));
    }
}
