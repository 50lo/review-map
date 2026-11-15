//! Bazel queries for the build graph: which targets own which source files, what they depend on, and
//! how they are configured.
//!
//! With targets that define the review scope (from reviewmap.yml, the launch, or rules_xcodeproj's
//! `top_level_targets`), the graph is the configured closure of those targets: `cquery deps(...)`, with
//! the build configuration of `index.bazelArgs`. When that fails, the unconfigured `query deps(...)`
//! stands in. Without a scope, every rule of the workspace is listed with `query //...`, which loads
//! packages but analyzes and fetches nothing beyond that.

use super::graph::{derived_module_name, TargetNode, WorkspaceGraph};
use super::workspace::BazelEnv;
use crate::proc::{Cancel, Cmd, Log};
use anyhow::{anyhow, Result};
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

/// The targets that define the review scope of one workspace.
#[derive(Clone, Debug, PartialEq)]
pub struct Scope {
    pub targets: Vec<String>,
    /// "explicit", "xcodeproj", or "all".
    pub kind: String,
}

/// Attributes that carry a target's dependencies on other code.
const DEP_ATTRS: &[&str] = &[
    "deps", "private_deps", "implementation_deps", "exports", "associates", "runtime_deps", "test_host", "frameworks", "extensions", "watch_application",
    "app_clips", "actual", "tests", "plugins", "srcs",
];
/// Attributes that change how a target's code compiles. Their values are compared between the two sides.
const SETTING_ATTRS: &[&str] = &[
    "copts", "swiftcopts", "defines", "features", "minimum_os_version", "minimum_deployment_os_version", "kotlinc_opts", "javac_opts", "jvm_target",
    "api_version", "language_version",
];
const OTHER_ATTRS: &[&str] = &["module_name", "testonly"];

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct ProtoAttribute {
    #[serde(default)]
    name: String,
    #[serde(default)]
    string_value: Option<String>,
    #[serde(default)]
    string_list_value: Vec<String>,
    #[serde(default)]
    boolean_value: Option<bool>,
    #[serde(default)]
    int_value: Option<i64>,
    #[serde(default)]
    explicitly_specified: Option<bool>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct ProtoRule {
    #[serde(default)]
    name: String,
    #[serde(default)]
    rule_class: String,
    #[serde(default)]
    location: Option<String>,
    #[serde(default)]
    attribute: Vec<ProtoAttribute>,
}

#[derive(Deserialize, Default)]
struct ProtoTarget {
    #[serde(default)]
    rule: Option<ProtoRule>,
}

#[derive(Deserialize, Default)]
struct ProtoConfiguration {
    #[serde(default)]
    checksum: Option<String>,
}

#[derive(Deserialize, Default)]
struct ProtoConfigured {
    #[serde(default)]
    target: Option<ProtoTarget>,
    #[serde(default)]
    configuration: Option<ProtoConfiguration>,
}

#[derive(Deserialize, Default)]
struct ProtoResults {
    #[serde(default)]
    results: Vec<ProtoConfigured>,
}

/// "@@//app:App" and "@//app:App" are the workspace's own "//app:App"; other repositories keep their name.
pub fn normalize_label(label: &str) -> String {
    let stripped = label.trim_start_matches('@');
    if stripped.starts_with("//") {
        stripped.to_string()
    } else {
        label.to_string()
    }
}

fn is_external(label: &str) -> bool {
    !label.starts_with("//")
}

/// "//app/ui:Sources/View.swift" -> "app/ui/Sources/View.swift".
fn label_path(label: &str) -> Option<String> {
    let body = label.strip_prefix("//")?;
    let (package, name) = body.split_once(':').unwrap_or((body, body.rsplit('/').next().unwrap_or(body)));
    Some(if package.is_empty() { name.to_string() } else { format!("{package}/{name}") })
}

fn attr_names() -> String {
    let all: BTreeSet<&str> = DEP_ATTRS.iter().chain(SETTING_ATTRS).chain(OTHER_ATTRS).copied().collect();
    all.into_iter().collect::<Vec<_>>().join(",")
}

fn node_of(rule: ProtoRule, workspace_dir: &Path, config: Option<String>) -> TargetNode {
    let label = normalize_label(&rule.name);
    let mut node = TargetNode { label: label.clone(), rule_class: rule.rule_class, external: is_external(&label), ..Default::default() };
    if let Some(c) = config {
        node.configs.push(c);
    }
    if let Some(location) = rule.location {
        // "/abs/workspace/app/BUILD.bazel:3:14"
        let file = location.split(':').next().unwrap_or("");
        if let Ok(rel) = Path::new(file).strip_prefix(workspace_dir) {
            node.build_file = rel.to_string_lossy().to_string();
        }
    }
    if node.build_file.is_empty() && !node.external {
        let package = label.trim_start_matches("//").split(':').next().unwrap_or("");
        node.build_file = if package.is_empty() { "BUILD.bazel".to_string() } else { format!("{package}/BUILD.bazel") };
    }
    let mut module_name: Option<String> = None;
    for a in rule.attribute {
        let name = a.name.as_str();
        if name == "srcs" {
            for l in &a.string_list_value {
                let l = normalize_label(l);
                if let (false, Some(path)) = (is_external(&l), label_path(&l)) {
                    node.srcs.push(path);
                }
                // A label in srcs may also be a rule (a filegroup, generated sources); it is followed like a dependency.
                node.deps.push(l);
            }
        } else if DEP_ATTRS.contains(&name) {
            if let Some(v) = &a.string_value {
                if !v.is_empty() {
                    node.deps.push(normalize_label(v));
                }
            }
            node.deps.extend(a.string_list_value.iter().map(|l| normalize_label(l)));
        } else if name == "module_name" {
            module_name = a.string_value.clone().filter(|s| !s.is_empty());
        } else if name == "testonly" {
            node.testonly = a.boolean_value.unwrap_or(false) || a.string_value.as_deref() == Some("true");
        } else if SETTING_ATTRS.contains(&name) && a.explicitly_specified != Some(false) {
            let value = if !a.string_list_value.is_empty() {
                a.string_list_value.join(" ")
            } else if let Some(v) = &a.string_value {
                v.clone()
            } else if let Some(v) = a.int_value {
                v.to_string()
            } else {
                String::new()
            };
            if !value.is_empty() {
                node.settings.insert(name.to_string(), value);
            }
        }
    }
    if node.rule_class.starts_with("swift_") {
        node.module_name = Some(module_name.unwrap_or_else(|| derived_module_name(&label)));
    }
    node.deps.sort();
    node.deps.dedup();
    node
}

fn merge(targets: &mut BTreeMap<String, TargetNode>, node: TargetNode) {
    match targets.get_mut(&node.label) {
        // The same label in another configuration: one map node, the union of what each configuration lists.
        Some(have) => {
            for s in node.srcs {
                if !have.srcs.contains(&s) {
                    have.srcs.push(s);
                }
            }
            for d in node.deps {
                if !have.deps.contains(&d) {
                    have.deps.push(d);
                }
            }
            for c in node.configs {
                if !have.configs.contains(&c) {
                    have.configs.push(c);
                }
            }
            for (k, v) in node.settings {
                have.settings.entry(k).or_insert(v);
            }
        }
        None => {
            targets.insert(node.label.clone(), node);
        }
    }
}

/// A filegroup in `srcs` stands for its files: the target that lists it owns them.
fn expand_filegroups(targets: &mut BTreeMap<String, TargetNode>) {
    let groups: BTreeMap<String, Vec<String>> =
        targets.values().filter(|t| t.rule_class == "filegroup" && !t.external).map(|t| (t.label.clone(), t.srcs.clone())).collect();
    if groups.is_empty() {
        return;
    }
    for t in targets.values_mut().filter(|t| t.rule_class != "filegroup") {
        let mut extra: Vec<String> = Vec::new();
        let mut seen: BTreeSet<&str> = BTreeSet::new();
        let mut queue: Vec<&str> = t.deps.iter().map(String::as_str).filter(|d| groups.contains_key(*d)).collect();
        while let Some(g) = queue.pop() {
            if !seen.insert(g) {
                continue;
            }
            for s in &groups[g] {
                extra.push(s.clone());
                // A filegroup that lists another filegroup names it by label, which reads as a path here.
                if let Some(label) = groups.keys().find(|k| label_path(k).as_deref() == Some(s.as_str())) {
                    queue.push(label.as_str());
                }
            }
        }
        for s in extra {
            if !t.srcs.contains(&s) {
                t.srcs.push(s);
            }
        }
    }
}

/// The graph of one workspace at one side. `log` gets a line per attempt.
pub fn load_graph(env: &BazelEnv, workspace: &str, scope: &Scope, cancel: &Cancel, log: Log) -> Result<WorkspaceGraph> {
    let mut graph = WorkspaceGraph { workspace: workspace.to_string(), scope_targets: scope.targets.clone(), scope: scope.kind.clone(), ..Default::default() };
    let attrs = format!("--proto:output_rule_attrs={}", attr_names());
    let common = |command: &str| -> Cmd { env.command(command).arg("--keep_going").arg("--noimplicit_deps").arg("--notool_deps").arg(attrs.clone()) };
    let expression = format!("deps(set({}))", scope.targets.join(" "));
    let mut errors: Vec<String> = Vec::new();

    if scope.kind != "all" {
        // Configured: what the selected application and tests really build, select() branches resolved.
        log(format!("Querying the configured build graph of {}", scope.targets.join(" ")));
        let cmd = common("cquery").arg("--output=jsonproto").args(env.args.iter().cloned()).arg(expression.clone());
        match run_query(&cmd, cancel) {
            Ok(out) => match serde_json::from_slice::<ProtoResults>(&out) {
                Ok(parsed) if !parsed.results.is_empty() => {
                    for r in parsed.results {
                        let config = r.configuration.and_then(|c| c.checksum);
                        if let Some(rule) = r.target.and_then(|t| t.rule) {
                            merge(&mut graph.targets, node_of(rule, &env.dir, config));
                        }
                    }
                    graph.configured = true;
                }
                Ok(_) => errors.push("cquery returned no targets".to_string()),
                Err(e) => errors.push(format!("cquery output could not be read: {e}")),
            },
            Err(e) => {
                cancel.check()?;
                errors.push(format!("{e}"));
            }
        }
    }
    if graph.targets.is_empty() {
        let (what, expr) = if scope.kind == "all" { ("every target of the workspace".to_string(), "//...".to_string()) } else { (scope.targets.join(" "), expression) };
        log(format!("Querying the build graph of {what}"));
        let cmd = common("query").arg("--output=streamed_jsonproto").arg(expr);
        match run_query(&cmd, cancel) {
            Ok(out) => {
                for line in out.split(|b| *b == b'\n').filter(|l| !l.is_empty()) {
                    if let Ok(t) = serde_json::from_slice::<ProtoTarget>(line) {
                        if let Some(rule) = t.rule {
                            merge(&mut graph.targets, node_of(rule, &env.dir, None));
                        }
                    }
                }
            }
            Err(e) => {
                cancel.check()?;
                errors.push(format!("{e}"));
            }
        }
    }
    if graph.targets.is_empty() {
        return Err(anyhow!("Bazel could not report the build graph{}: {}", if workspace.is_empty() { String::new() } else { format!(" of {workspace}") }, errors.join("; ")));
    }
    expand_filegroups(&mut graph.targets);
    Ok(graph)
}

/// Runs a query. With `--keep_going`, Bazel exits non-zero when some targets failed and still prints
/// the rest, so output counts even then.
fn run_query(cmd: &Cmd, cancel: &Cancel) -> Result<Vec<u8>> {
    match cmd.output(cancel) {
        Ok(out) => Ok(out),
        Err(e) => {
            cancel.check()?;
            match cmd.output_lenient(cancel) {
                Ok(out) if !out.is_empty() => Ok(out),
                _ => Err(e),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labels() {
        assert_eq!(normalize_label("@@//app:App"), "//app:App");
        assert_eq!(normalize_label("@@rules_swift+//x:y"), "@@rules_swift+//x:y");
        assert_eq!(label_path("//app/ui:Sources/View.swift").as_deref(), Some("app/ui/Sources/View.swift"));
        assert_eq!(label_path("//:Main.kt").as_deref(), Some("Main.kt"));
    }

    #[test]
    fn reads_a_rule() {
        let json = r#"{"results":[{"target":{"type":"RULE","rule":{"name":"//app:AppLib","ruleClass":"swift_library","location":"/ws/app/BUILD.bazel:3:14","attribute":[
            {"name":"srcs","type":"LABEL_LIST","stringListValue":["//app:Sources/App.swift","//app:srcs"],"explicitlySpecified":true},
            {"name":"deps","type":"LABEL_LIST","stringListValue":["//core:Core","@@swiftpkg+//:Alamofire"],"explicitlySpecified":true},
            {"name":"copts","type":"STRING_LIST","stringListValue":["-strict-concurrency=complete"],"explicitlySpecified":true},
            {"name":"testonly","type":"BOOLEAN","booleanValue":false}]}},"configuration":{"checksum":"abc"}},
            {"target":{"type":"RULE","rule":{"name":"//app:srcs","ruleClass":"filegroup","attribute":[{"name":"srcs","stringListValue":["//app:Sources/More.swift"]}]}},"configuration":{"checksum":"abc"}}]}"#;
        let parsed: ProtoResults = serde_json::from_str(json).unwrap();
        let mut targets = BTreeMap::new();
        for r in parsed.results {
            let config = r.configuration.and_then(|c| c.checksum);
            merge(&mut targets, node_of(r.target.unwrap().rule.unwrap(), Path::new("/ws"), config));
        }
        expand_filegroups(&mut targets);
        let lib = &targets["//app:AppLib"];
        assert_eq!(lib.build_file, "app/BUILD.bazel");
        assert_eq!(lib.module_name.as_deref(), Some("app_AppLib"));
        assert!(lib.srcs.contains(&"app/Sources/App.swift".to_string()));
        assert!(lib.srcs.contains(&"app/Sources/More.swift".to_string()));
        assert!(lib.deps.contains(&"//core:Core".to_string()));
        assert_eq!(lib.settings["copts"], "-strict-concurrency=complete");
        assert_eq!(lib.configs, vec!["abc".to_string()]);
    }
}
