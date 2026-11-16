//! A revision's TypeScript projects, read from its tree: npm packages (`package.json`), `tsconfig` files
//! with their `extends` chain, `paths` aliases, `baseUrl` and project references, and the package-manager
//! roots that indexing installs. It answers which file or package an import specifier names, as the
//! TypeScript compiler would resolve it in that revision. Everything is read from committed content, so
//! the answer is the same for the preliminary view and for indexing.

use crate::paths::{file_name, is_under, join, parent, strip_dir};
use serde_json::{Map, Value};
use std::collections::{BTreeMap, BTreeSet, HashMap};

/// Extensions of TypeScript source files.
pub const SOURCE_EXTENSIONS: &[&str] = &["ts", "tsx", "mts", "cts"];
/// Lockfiles that mark the root of a package-manager project.
pub const LOCKFILES: &[&str] = &["yarn.lock", "pnpm-lock.yaml", "package-lock.json", "bun.lock", "bun.lockb"];

/// Node's built-in modules (`node:fs` is reported as `fs`).
pub const NODE_BUILTINS: &[&str] = &[
    "assert", "async_hooks", "buffer", "child_process", "cluster", "console", "constants", "crypto", "dgram", "diagnostics_channel", "dns", "domain",
    "events", "fs", "http", "http2", "https", "inspector", "module", "net", "os", "path", "perf_hooks", "process", "punycode", "querystring",
    "readline", "repl", "stream", "string_decoder", "sys", "test", "timers", "tls", "trace_events", "tty", "url", "util", "v8", "vm", "wasi",
    "worker_threads", "zlib", "sqlite", "sea",
];

/// Extensions of files that a bundler imports but that hold no TypeScript declarations (images, styles,
/// fonts, media, text and data). TypeScript types such imports through wildcard modules (`declare module
/// '*.svg'`), so the index can miss nothing behind them.
const ASSET_EXTENSIONS: &[&str] = &[
    "svg", "png", "jpg", "jpeg", "gif", "webp", "avif", "ico", "bmp", "css", "scss", "sass", "less", "styl",
    "pcss", "html", "md", "mdx", "txt", "wasm", "woff", "woff2", "ttf", "otf", "eot", "mp3", "mp4", "webm",
    "wav", "ogg", "glsl", "wgsl", "yaml", "yml", "toml", "graphql", "gql", "csv", "xml", "pdf",
];

/// Whether a specifier names an asset, not code: a file with an asset extension, or one with a bundler
/// query (`./shader.txt?raw`, `./worker.ts?worker`).
pub fn is_asset(spec: &str) -> bool {
    if spec.contains('?') {
        return true;
    }
    let file = spec.rsplit('/').next().unwrap_or(spec);
    file.rsplit_once('.').is_some_and(|(stem, ext)| !stem.is_empty() && ASSET_EXTENSIONS.contains(&ext.to_ascii_lowercase().as_str()))
}

pub fn is_node_builtin(module: &str) -> bool {
    module.starts_with("node:") || NODE_BUILTINS.contains(&module.split('/').next().unwrap_or(""))
}

/// The package a bare import specifier names: "@scope/pkg/sub" -> "@scope/pkg", "node:fs" -> "fs". None
/// for relative specifiers, path aliases (`@/`, `~`, `#`, `$`) and other schemes (`bun:`, `virtual:`).
pub fn package_name(spec: &str) -> Option<String> {
    if let Some(rest) = spec.strip_prefix("node:") {
        return rest.split('/').next().map(str::to_string);
    }
    if spec.starts_with('.') || spec.starts_with('/') || spec.contains(':') || spec.starts_with("@/") || spec.starts_with('~') || spec.starts_with('#') || spec.starts_with('$') {
        return None;
    }
    let mut parts = spec.split('/');
    let first = parts.next().filter(|s| !s.is_empty())?;
    if first.starts_with('@') {
        let second = parts.next().filter(|s| !s.is_empty())?;
        return Some(format!("{first}/{second}"));
    }
    Some(first.to_string())
}

/// The module a type-only package types: `@types/node` -> "node", `@types/babel__core` -> "@babel/core".
pub fn typed_module(package: &str) -> Option<String> {
    let typed = package.strip_prefix("@types/")?;
    Some(match typed.split_once("__") {
        Some((scope, name)) => format!("@{scope}/{name}"),
        None => typed.to_string(),
    })
}

pub fn is_relative(spec: &str) -> bool {
    spec == "." || spec == ".." || spec.starts_with("./") || spec.starts_with("../") || spec.starts_with('/')
}

/// Reads JSON that may carry comments and trailing commas, as `tsconfig.json` does.
pub fn read_json(bytes: &[u8]) -> Option<Value> {
    if let Ok(v) = serde_json::from_slice::<Value>(bytes) {
        return Some(v);
    }
    serde_json::from_str(&strip_json_comments(&String::from_utf8_lossy(bytes))).ok()
}

pub fn strip_json_comments(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    let mut in_string = false;
    while i < chars.len() {
        let c = chars[i];
        if in_string {
            out.push(c);
            if c == '\\' && i + 1 < chars.len() {
                out.push(chars[i + 1]);
                i += 2;
                continue;
            }
            if c == '"' {
                in_string = false;
            }
            i += 1;
            continue;
        }
        if c == '"' {
            in_string = true;
            out.push(c);
            i += 1;
            continue;
        }
        if c == '/' && chars.get(i + 1) == Some(&'/') {
            while i < chars.len() && chars[i] != '\n' {
                i += 1;
            }
            continue;
        }
        if c == '/' && chars.get(i + 1) == Some(&'*') {
            i += 2;
            while i + 1 < chars.len() && !(chars[i] == '*' && chars[i + 1] == '/') {
                i += 1;
            }
            i += 2;
            continue;
        }
        if c == ',' {
            // A comma that only whitespace separates from a closing bracket goes.
            let mut j = i + 1;
            while j < chars.len() && chars[j].is_whitespace() {
                j += 1;
            }
            if j < chars.len() && (chars[j] == '}' || chars[j] == ']') {
                i += 1;
                continue;
            }
        }
        out.push(c);
        i += 1;
    }
    out
}

/// "a/./b/../c" -> "a/c". None when the path climbs out of the repository.
pub fn normalize(path: &str) -> Option<String> {
    let mut parts: Vec<&str> = Vec::new();
    for p in path.split('/') {
        match p {
            "" | "." => {}
            ".." => {
                parts.pop()?;
            }
            other => parts.push(other),
        }
    }
    Some(parts.join("/"))
}

#[derive(Clone, Debug)]
pub struct Package {
    /// The package's name, if its package.json has one.
    pub name: Option<String>,
    /// Repo-relative directory ("" for the root).
    pub dir: String,
    pub manifest: String,
    pub json: Value,
}

impl Package {
    pub fn field(&self, key: &str) -> Option<&Value> {
        self.json.get(key)
    }

    /// Whether this package.json is a workspace root (it lists workspaces), which is no component of its own.
    pub fn is_workspace_root(&self) -> bool {
        self.json.get("workspaces").is_some()
    }

    pub fn dependencies(&self, fields: &[&str]) -> BTreeSet<String> {
        fields.iter().filter_map(|f| self.json.get(*f).and_then(Value::as_object)).flat_map(|m| m.keys().cloned()).collect()
    }

    /// Lifecycle scripts that an install with scripts off skips.
    pub fn install_scripts(&self) -> Vec<String> {
        let Some(scripts) = self.json.get("scripts").and_then(Value::as_object) else { return Vec::new() };
        ["preinstall", "install", "postinstall", "prepare"].iter().filter(|s| scripts.contains_key(**s)).map(|s| s.to_string()).collect()
    }
}

/// A tsconfig with its `extends` chain applied. Paths are repo-relative.
#[derive(Clone, Debug, Default)]
pub struct TsConfig {
    pub path: String,
    pub dir: String,
    /// The merged compiler options.
    pub options: Map<String, Value>,
    /// The tsconfig's own compiler options, without the ones it extends: what its project changes.
    pub own_options: Map<String, Value>,
    /// The directory non-relative specifiers resolve against, when `baseUrl` is set.
    pub base_url: Option<String>,
    /// `paths` patterns in the order the config lists them, with their targets repo-relative.
    pub paths: Vec<(String, Vec<String>)>,
    /// Directories of the projects it references.
    pub references: Vec<String>,
    /// Whether the config names inputs (`files`, `include`), or only references other projects.
    pub has_inputs: bool,
}

/// What a module specifier names, in one revision.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Resolved {
    /// A TypeScript source file of the revision.
    File(String),
    /// A package by name. `workspace` says it is one of the repository's own packages; then `file` is the
    /// source file its entry resolves to, or None when the entry names nothing in the tree (such as an
    /// unbuilt `dist/`).
    Package { name: String, workspace: bool, file: Option<String> },
    /// A built-in module of Node.
    Platform,
    /// A relative specifier or a `paths` alias that should name a file of the repository, but no TypeScript
    /// file of the revision matches it (generated code, a JavaScript file, a typo).
    Missing,
    /// A specifier the project says nothing about (an unknown alias or scheme).
    Unknown,
}

/// The roots that package managers install, and which manager each uses.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Manager {
    YarnClassic,
    YarnBerry,
    Pnpm,
    Npm,
    Bun,
    /// A package.json with no lockfile and no `packageManager`.
    Unknown,
}

impl Manager {
    pub fn describe(&self) -> &'static str {
        match self {
            Manager::YarnClassic => "Yarn Classic",
            Manager::YarnBerry => "Yarn Berry",
            Manager::Pnpm => "pnpm",
            Manager::Npm => "npm",
            Manager::Bun => "Bun",
            Manager::Unknown => "no package manager",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InstallRoot {
    /// Repo-relative directory ("" for the root).
    pub dir: String,
    pub manager: Manager,
    /// Why the manager was chosen ("yarn.lock with a __metadata header", "packageManager yarn@1.22.22").
    pub evidence: String,
    pub has_lockfile: bool,
    /// The `packageManager` field, when it names Yarn.
    pub yarn_pin: Option<String>,
}

#[derive(Default)]
pub struct Project {
    /// Every path of the revision's tree.
    paths: BTreeSet<String>,
    pub packages: Vec<Package>,
    /// Workspace package name -> index in `packages`.
    by_name: HashMap<String, usize>,
    /// tsconfig.json directory -> config.
    pub tsconfigs: BTreeMap<String, TsConfig>,
    pub roots: Vec<InstallRoot>,
}

const TS_EXTENSIONS_IN_ORDER: &[&str] = &[".ts", ".tsx", ".d.ts", ".mts", ".d.mts", ".cts", ".d.cts"];

fn under_node_modules(path: &str) -> bool {
    path.split('/').any(|p| p == "node_modules")
}

impl Project {
    /// Reads the projects of a revision. `paths` are every file of its tree; `read` gives a file's bytes.
    pub fn build<'a>(paths: impl IntoIterator<Item = &'a String>, read: &dyn Fn(&str) -> Option<Vec<u8>>) -> Project {
        let mut project = Project { paths: paths.into_iter().filter(|p| !under_node_modules(p)).cloned().collect(), ..Default::default() };
        let manifests: Vec<String> = project.paths.iter().filter(|p| file_name(p) == "package.json").cloned().collect();
        for manifest in manifests {
            let Some(json) = read(&manifest).and_then(|b| read_json(&b)).filter(Value::is_object) else { continue };
            let name = json.get("name").and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string);
            let package = Package { name: name.clone(), dir: parent(&manifest).to_string(), manifest: manifest.clone(), json };
            if let Some(name) = name {
                // Two packages with one name: the shallower one owns it, as the workspace root's hoisting would.
                let index = project.packages.len();
                project.by_name.entry(name).or_insert(index);
            }
            project.packages.push(package);
        }
        let configs: Vec<String> = project.paths.iter().filter(|p| file_name(p) == "tsconfig.json").cloned().collect();
        for path in configs {
            let config = project.load_tsconfig(&path, read, 0);
            project.tsconfigs.insert(parent(&path).to_string(), config);
        }
        project.roots = project.find_roots(read);
        project
    }

    pub fn exists(&self, path: &str) -> bool {
        self.paths.contains(path)
    }

    pub fn workspace_package(&self, name: &str) -> Option<&Package> {
        self.by_name.get(name).map(|i| &self.packages[*i])
    }

    /// The innermost package.json at or above a file's directory.
    pub fn package_of(&self, path: &str) -> Option<&Package> {
        self.packages.iter().filter(|p| is_under(path, &p.dir)).max_by_key(|p| p.dir.len())
    }

    /// The tsconfig.json that applies to a file: the nearest one at or above its directory.
    pub fn tsconfig_of(&self, path: &str) -> Option<&TsConfig> {
        let mut dir = parent(path).to_string();
        loop {
            if let Some(c) = self.tsconfigs.get(&dir) {
                return Some(c);
            }
            if dir.is_empty() {
                return None;
            }
            dir = parent(&dir).to_string();
        }
    }

    fn load_tsconfig(&self, path: &str, read: &dyn Fn(&str) -> Option<Vec<u8>>, depth: usize) -> TsConfig {
        let dir = parent(path).to_string();
        let mut config = TsConfig { path: path.to_string(), dir: dir.clone(), ..Default::default() };
        let Some(json) = read(path).and_then(|b| read_json(&b)) else { return config };
        // `extends`: one config or, since TypeScript 5.0, several; later ones win.
        let extends: Vec<String> = match json.get("extends") {
            Some(Value::String(s)) => vec![s.clone()],
            Some(Value::Array(list)) => list.iter().filter_map(|v| v.as_str().map(str::to_string)).collect(),
            _ => Vec::new(),
        };
        if depth < 8 {
            for spec in extends {
                let Some(parent_path) = self.extends_path(&dir, &spec) else { continue };
                let base = self.load_tsconfig(&parent_path, read, depth + 1);
                for (k, v) in base.options {
                    config.options.insert(k, v);
                }
                if base.base_url.is_some() {
                    config.base_url = base.base_url;
                }
                if !base.paths.is_empty() {
                    config.paths = base.paths;
                }
            }
        }
        let own = json.get("compilerOptions").and_then(Value::as_object).cloned().unwrap_or_default();
        for (k, v) in &own {
            config.options.insert(k.clone(), v.clone());
        }
        // `baseUrl` and `paths` are relative to the config that sets them.
        if let Some(base) = own.get("baseUrl").and_then(Value::as_str) {
            config.base_url = normalize(&join(&dir, base));
        }
        if let Some(paths) = own.get("paths").and_then(Value::as_object) {
            let anchor = config.base_url.clone().unwrap_or_else(|| dir.clone());
            config.paths = paths
                .iter()
                .map(|(pattern, targets)| {
                    let list = targets.as_array().map(|a| a.iter().filter_map(Value::as_str).filter_map(|t| normalize(&join(&anchor, t))).collect()).unwrap_or_default();
                    (pattern.clone(), list)
                })
                .collect();
        }
        config.own_options = own;
        if let Some(refs) = json.get("references").and_then(Value::as_array) {
            for r in refs {
                let Some(p) = r.get("path").and_then(Value::as_str) else { continue };
                let Some(target) = normalize(&join(&dir, p)) else { continue };
                // A reference names a directory or a tsconfig file in it.
                let target = if target.ends_with(".json") { parent(&target).to_string() } else { target };
                config.references.push(target);
            }
        }
        config.has_inputs = json.get("files").and_then(Value::as_array).map(|a| !a.is_empty()).unwrap_or(false)
            || json.get("include").is_some()
            || json.get("files").is_none();
        config
    }

    /// The file an `extends` names: a relative path, or a file in a workspace package.
    fn extends_path(&self, dir: &str, spec: &str) -> Option<String> {
        let with_json = |p: String| if p.ends_with(".json") { p } else { format!("{p}.json") };
        if is_relative(spec) {
            let p = normalize(&join(dir, spec))?;
            if self.exists(&p) {
                return Some(p);
            }
            let p = with_json(p);
            return self.exists(&p).then_some(p);
        }
        let name = package_name(spec)?;
        let package = self.workspace_package(&name)?;
        let sub = spec[name.len()..].trim_start_matches('/');
        let p = if sub.is_empty() { join(&package.dir, "tsconfig.json") } else { with_json(join(&package.dir, sub)) };
        self.exists(&p).then_some(p)
    }

    /// The outermost directories that a package manager installs: the ones with a lockfile, or, without
    /// any lockfile, the outermost ones with a package.json.
    fn find_roots(&self, read: &dyn Fn(&str) -> Option<Vec<u8>>) -> Vec<InstallRoot> {
        let outermost = |dirs: BTreeSet<String>| -> Vec<String> {
            dirs.iter().filter(|d| !dirs.iter().any(|o| o != *d && is_under(d, o))).cloned().collect()
        };
        let locked: BTreeSet<String> = self.paths.iter().filter(|p| LOCKFILES.contains(&file_name(p))).map(|p| parent(p).to_string()).collect();
        let dirs = if locked.is_empty() { outermost(self.packages.iter().map(|p| p.dir.clone()).collect()) } else { outermost(locked) };
        dirs.into_iter()
            .map(|dir| {
                let has = |name: &str| self.exists(&join(&dir, name));
                let pin = self
                    .packages
                    .iter()
                    .find(|p| p.dir == dir)
                    .and_then(|p| p.field("packageManager"))
                    .and_then(Value::as_str)
                    .map(|s| s.split('+').next().unwrap_or(s).to_string());
                let yarn_pin = pin.clone().filter(|p| p.starts_with("yarn@"));
                let berry_pin = yarn_pin.as_deref().map(|p| !p.starts_with("yarn@1.") && p != "yarn@1").unwrap_or(false);
                let (manager, evidence) = if has("yarn.lock") || yarn_pin.is_some() {
                    let lock_berry = has("yarn.lock")
                        && read(&join(&dir, "yarn.lock")).map(|b| String::from_utf8_lossy(&b).lines().take(20).any(|l| l.trim_start().starts_with("__metadata:"))).unwrap_or(false);
                    if lock_berry {
                        (Manager::YarnBerry, "its yarn.lock has a __metadata header".to_string())
                    } else if has(".yarnrc.yml") {
                        (Manager::YarnBerry, "it has a .yarnrc.yml".to_string())
                    } else if berry_pin {
                        (Manager::YarnBerry, format!("package.json pins {}", yarn_pin.clone().unwrap_or_default()))
                    } else if has("yarn.lock") {
                        (Manager::YarnClassic, "yarn.lock".to_string())
                    } else {
                        (Manager::YarnClassic, format!("package.json pins {}", yarn_pin.clone().unwrap_or_default()))
                    }
                } else if has("pnpm-lock.yaml") || pin.as_deref().map(|p| p.starts_with("pnpm@")).unwrap_or(false) {
                    (Manager::Pnpm, "pnpm-lock.yaml".to_string())
                } else if has("bun.lock") || has("bun.lockb") {
                    (Manager::Bun, "bun.lock".to_string())
                } else if has("package-lock.json") || pin.as_deref().map(|p| p.starts_with("npm@")).unwrap_or(false) {
                    (Manager::Npm, "package-lock.json".to_string())
                } else {
                    (Manager::Unknown, "a package.json without a lockfile".to_string())
                };
                let has_lockfile = LOCKFILES.iter().any(|l| has(l));
                InstallRoot { dir, manager, evidence, has_lockfile, yarn_pin }
            })
            .collect()
    }

    /// The install root a file belongs to.
    pub fn root_of(&self, path: &str) -> Option<&InstallRoot> {
        self.roots.iter().filter(|r| is_under(path, &r.dir)).max_by_key(|r| r.dir.len())
    }

    // MARK: Resolution

    /// What `spec`, imported from `from`, names: the way TypeScript's bundler and node16 resolution find
    /// it, through relative paths, `paths` aliases and `baseUrl`, the package's own `imports`, and workspace
    /// packages' `exports` and entry fields.
    pub fn resolve(&self, from: &str, spec: &str) -> Resolved {
        if is_relative(spec) {
            return match normalize(&join(parent(from), spec)).and_then(|p| self.source_file(&p)) {
                Some(f) => Resolved::File(f),
                None => Resolved::Missing,
            };
        }
        let mut aliased = false;
        if let Some(config) = self.tsconfig_of(from) {
            if let Some(targets) = best_pattern(config.paths.iter().map(|(k, v)| (k.as_str(), v)), spec) {
                aliased = true;
                for target in targets {
                    if let Some(f) = normalize(&target).and_then(|p| self.source_file(&p)) {
                        return Resolved::File(f);
                    }
                }
            }
            if let Some(base) = &config.base_url {
                if let Some(f) = normalize(&join(base, spec)).and_then(|p| self.source_file(&p)) {
                    return Resolved::File(f);
                }
            }
        }
        if spec.starts_with('#') {
            // Subpath imports of the file's own package.
            if let Some(package) = self.package_of(from) {
                if let Some(target) = package.field("imports").and_then(|i| subpath_target(i, spec)) {
                    return match normalize(&join(&package.dir, &target)).and_then(|p| self.source_file(&p)) {
                        Some(f) => Resolved::File(f),
                        None => Resolved::Missing,
                    };
                }
            }
        }
        if let Some(name) = package_name(spec) {
            if let Some(package) = self.workspace_package(&name) {
                let sub = &spec[name.len()..];
                return Resolved::Package { name: name.clone(), workspace: true, file: self.package_entry(package, sub) };
            }
            if is_node_builtin(spec) {
                return Resolved::Platform;
            }
            // A `paths` alias that matched names the repository's own files, even when it looks like a package.
            if aliased {
                return Resolved::Missing;
            }
            return Resolved::Package { name, workspace: false, file: None };
        }
        if aliased {
            Resolved::Missing
        } else {
            Resolved::Unknown
        }
    }

    /// The source file a workspace package's entry names for a subpath ("" or "/sub").
    pub fn package_entry(&self, package: &Package, sub: &str) -> Option<String> {
        let at = |p: &str| normalize(&join(&package.dir, p)).and_then(|f| self.source_file(&f));
        if let Some(exports) = package.field("exports") {
            let key = format!(".{sub}");
            return subpath_target(exports, &key).and_then(|t| at(&t));
        }
        if sub.is_empty() {
            for field in ["types", "typings", "main", "module"] {
                if let Some(f) = package.field(field).and_then(Value::as_str).and_then(at) {
                    return Some(f);
                }
            }
            return at("index");
        }
        at(sub.trim_start_matches('/'))
    }

    /// The TypeScript file a path names, as module resolution tries it: the path itself, a `.js` path's
    /// TypeScript source, the path with a TypeScript extension, and a directory's package.json entry or
    /// index file.
    pub fn source_file(&self, path: &str) -> Option<String> {
        let ts = |p: &str| SOURCE_EXTENSIONS.iter().any(|e| p.ends_with(&format!(".{e}")));
        if ts(path) && self.exists(path) {
            return Some(path.to_string());
        }
        // "./cart.js" is `cart.ts` once compiled.
        for (js, list) in [(".js", &[".ts", ".tsx", ".d.ts"][..]), (".jsx", &[".tsx"][..]), (".mjs", &[".mts", ".d.mts"][..]), (".cjs", &[".cts", ".d.cts"][..])] {
            if let Some(stem) = path.strip_suffix(js) {
                if let Some(f) = list.iter().map(|e| format!("{stem}{e}")).find(|p| self.exists(p)) {
                    return Some(f);
                }
            }
        }
        if let Some(f) = TS_EXTENSIONS_IN_ORDER.iter().map(|e| format!("{path}{e}")).find(|p| self.exists(p)) {
            return Some(f);
        }
        if let Some(package) = self.packages.iter().find(|p| p.dir == path) {
            for field in ["types", "typings", "main"] {
                if let Some(target) = package.field(field).and_then(Value::as_str) {
                    if let Some(f) = normalize(&join(path, target)).filter(|t| t != path).and_then(|t| self.source_file(&t)) {
                        return Some(f);
                    }
                }
            }
        }
        TS_EXTENSIONS_IN_ORDER.iter().map(|e| format!("{}{e}", join(path, "index"))).find(|p| self.exists(p))
    }

    /// The tsconfig.json directories to index: the outermost ones under `dir`, and the ones a solution-style
    /// config references (a root config without inputs of its own).
    pub fn index_projects(&self, dir: &str) -> Vec<String> {
        let mut dirs: Vec<&String> = self.tsconfigs.keys().filter(|d| is_under(d, dir)).collect();
        dirs.sort_by_key(|d| (d.split('/').filter(|s| !s.is_empty()).count(), d.to_string()));
        let mut kept: Vec<String> = Vec::new();
        for d in dirs {
            let nearest = kept.iter().filter(|k| is_under(d, k)).max_by_key(|k| k.len());
            let keep = match nearest {
                None => true,
                Some(k) => {
                    let config = &self.tsconfigs[k];
                    !config.references.is_empty() || !config.has_inputs
                }
            };
            if keep {
                kept.push(d.clone());
            }
        }
        kept.into_iter()
            .map(|d| if d == dir { ".".to_string() } else { strip_dir(&d, dir).map(|s| if s.is_empty() { ".".to_string() } else { s.to_string() }).unwrap_or(d) })
            .collect()
    }
}

/// The targets of the `paths` pattern that matches best: an exact key, else the wildcard key with the
/// longest prefix, with `*` replaced by what it matched.
fn best_pattern<'a>(patterns: impl Iterator<Item = (&'a str, &'a Vec<String>)>, spec: &str) -> Option<Vec<String>> {
    let mut best: Option<(usize, Vec<String>)> = None;
    for (pattern, targets) in patterns {
        if pattern == spec {
            return Some(targets.clone());
        }
        let Some((prefix, suffix)) = pattern.split_once('*') else { continue };
        if spec.len() >= prefix.len() + suffix.len() && spec.starts_with(prefix) && spec.ends_with(suffix) {
            let matched = &spec[prefix.len()..spec.len() - suffix.len()];
            if best.as_ref().map(|(len, _)| prefix.len() > *len).unwrap_or(true) {
                best = Some((prefix.len(), targets.iter().map(|t| t.replacen('*', matched, 1)).collect()));
            }
        }
    }
    best.map(|(_, t)| t)
}

/// Conditions in the order they are tried. TypeScript tries a package's conditions in the order the
/// package lists them; JSON objects here don't keep that order, so the type-bearing ones go first.
const CONDITIONS: &[&str] = &["types", "typescript", "import", "module", "node", "require", "default"];

fn condition_target(value: &Value) -> Option<String> {
    match value {
        Value::String(s) => Some(s.clone()),
        Value::Array(list) => list.iter().find_map(condition_target),
        Value::Object(map) => CONDITIONS.iter().filter_map(|c| map.get(*c)).find_map(condition_target),
        _ => None,
    }
}

/// The target an `exports` or `imports` map gives for a key ("." / "./sub" / "#internal").
pub fn subpath_target(map: &Value, key: &str) -> Option<String> {
    let entries: Map<String, Value> = match map {
        Value::Object(m) if m.keys().any(|k| k.starts_with('.') || k.starts_with('#')) => m.clone(),
        // Conditions or a plain target: they stand for ".".
        other => {
            if key != "." {
                return None;
            }
            return condition_target(other);
        }
    };
    if let Some(v) = entries.get(key) {
        return condition_target(v);
    }
    let mut best: Option<(usize, String)> = None;
    for (pattern, v) in &entries {
        let Some((prefix, suffix)) = pattern.split_once('*') else { continue };
        if key.len() >= prefix.len() + suffix.len() && key.starts_with(prefix) && key.ends_with(suffix) {
            let matched = &key[prefix.len()..key.len() - suffix.len()];
            if best.as_ref().map(|(len, _)| prefix.len() > *len).unwrap_or(true) {
                if let Some(t) = condition_target(v) {
                    best = Some((prefix.len(), t.replace('*', matched)));
                }
            }
        }
    }
    best.map(|(_, t)| t)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn project(files: &[(&str, &str)]) -> Project {
        let map: BTreeMap<String, String> = files.iter().map(|(p, t)| (p.to_string(), t.to_string())).collect();
        let paths: Vec<String> = map.keys().cloned().collect();
        Project::build(paths.iter(), &|p: &str| map.get(p).map(|t| t.as_bytes().to_vec()))
    }

    #[test]
    fn assets() {
        assert!(is_asset("./icons/swift.svg"));
        assert!(is_asset("../styles/App.module.CSS"));
        assert!(is_asset("./shader.glsl?raw"));
        assert!(!is_asset("./store"));
        assert!(!is_asset("./foo.service"));
        assert!(!is_asset("./generated/version"));
        assert!(!is_asset("@demo/lib"));
        assert!(!is_asset("./data.json"), "TypeScript reads JSON modules itself");
    }

    #[test]
    fn specifiers() {
        assert_eq!(package_name("@scope/pkg/sub").as_deref(), Some("@scope/pkg"));
        assert_eq!(package_name("node:fs/promises").as_deref(), Some("fs"));
        assert_eq!(package_name("lodash/fp").as_deref(), Some("lodash"));
        assert_eq!(package_name("@/components"), None);
        assert_eq!(package_name("virtual:config"), None);
        assert_eq!(typed_module("@types/babel__core").as_deref(), Some("@babel/core"));
        assert_eq!(normalize("a/./b/../c").as_deref(), Some("a/c"));
        assert_eq!(normalize("../x"), None);
        assert_eq!(strip_json_comments("{\n // c\n \"a\": [1, 2,], /* x */ \"b\": \"//\",\n}"), "{\n \n \"a\": [1, 2],  \"b\": \"//\"\n}");
    }

    #[test]
    fn resolution() {
        let p = project(&[
            ("package.json", r#"{"private": true, "workspaces": ["packages/*"]}"#),
            ("yarn.lock", "# yarn lockfile v1\n"),
            ("tsconfig.base.json", r#"{"compilerOptions": {"baseUrl": ".", "paths": {"@app/*": ["packages/app/src/*"], "@shared": ["packages/shared/index.ts"]}}}"#),
            ("packages/app/tsconfig.json", "{\n  // comments are allowed\n  \"extends\": \"../../tsconfig.base.json\",\n  \"references\": [{\"path\": \"../lib\"}],\n}"),
            ("packages/app/package.json", r##"{"name": "@demo/app", "imports": {"#util/*": "./src/util/*.ts"}}"##),
            ("packages/app/src/main.ts", ""),
            ("packages/app/src/view.tsx", ""),
            ("packages/app/src/util/strings.ts", ""),
            ("packages/app/src/models/index.ts", ""),
            ("packages/lib/package.json", r#"{"name": "@demo/lib", "exports": {".": {"import": "./src/index.ts", "types": "./src/index.ts"}, "./cache": "./src/cache.ts", "./feature/*": "./src/features/*.ts"}}"#),
            ("packages/lib/src/index.ts", ""),
            ("packages/lib/src/cache.ts", ""),
            ("packages/lib/src/features/a.ts", ""),
            ("packages/built/package.json", r#"{"name": "@demo/built", "types": "dist/index.d.ts"}"#),
            ("packages/built/src/index.ts", ""),
            ("packages/shared/index.ts", ""),
        ]);
        let from = "packages/app/src/main.ts";
        assert_eq!(p.resolve(from, "./view.js"), Resolved::File("packages/app/src/view.tsx".into()));
        assert_eq!(p.resolve(from, "./models"), Resolved::File("packages/app/src/models/index.ts".into()));
        assert_eq!(p.resolve(from, "./generated/schema"), Resolved::Missing);
        assert_eq!(p.resolve(from, "@app/view"), Resolved::File("packages/app/src/view.tsx".into()), "a paths alias from the extended config");
        assert_eq!(p.resolve(from, "@shared"), Resolved::File("packages/shared/index.ts".into()));
        assert_eq!(p.resolve(from, "@app/nothing"), Resolved::Missing, "an alias that matches nothing");
        assert_eq!(p.resolve(from, "#util/strings"), Resolved::File("packages/app/src/util/strings.ts".into()));
        let lib = |file: &str| Resolved::Package { name: "@demo/lib".into(), workspace: true, file: Some(file.into()) };
        assert_eq!(p.resolve(from, "@demo/lib"), lib("packages/lib/src/index.ts"));
        assert_eq!(p.resolve(from, "@demo/lib/cache"), lib("packages/lib/src/cache.ts"));
        assert_eq!(p.resolve(from, "@demo/lib/feature/a"), lib("packages/lib/src/features/a.ts"));
        assert_eq!(p.resolve(from, "@demo/built"), Resolved::Package { name: "@demo/built".into(), workspace: true, file: None }, "an unbuilt dist");
        assert_eq!(p.resolve(from, "react"), Resolved::Package { name: "react".into(), workspace: false, file: None });
        assert_eq!(p.resolve(from, "fs"), Resolved::Platform);
        assert_eq!(p.resolve(from, "node:path"), Resolved::Platform);
        assert_eq!(p.resolve(from, "~/x"), Resolved::Unknown);
        assert_eq!(p.tsconfigs["packages/app"].references, vec!["packages/lib".to_string()]);
        assert_eq!(p.roots, vec![InstallRoot { dir: String::new(), manager: Manager::YarnClassic, evidence: "yarn.lock".into(), has_lockfile: true, yarn_pin: None }]);
    }

    #[test]
    fn managers() {
        let berry = project(&[("package.json", "{}"), ("yarn.lock", "# This file is generated\n\n__metadata:\n  version: 6\n")]);
        assert_eq!(berry.roots[0].manager, Manager::YarnBerry);
        let rc = project(&[("web/package.json", "{}"), ("web/yarn.lock", "# yarn lockfile v1\n"), ("web/.yarnrc.yml", "nodeLinker: node-modules\n")]);
        assert_eq!((rc.roots[0].dir.as_str(), &rc.roots[0].manager), ("web", &Manager::YarnBerry));
        let pinned = project(&[("package.json", r#"{"packageManager": "yarn@4.5.0+sha512.abc"}"#)]);
        assert_eq!(pinned.roots[0].manager, Manager::YarnBerry);
        let classic = project(&[("package.json", r#"{"packageManager": "yarn@1.22.22"}"#)]);
        assert_eq!((&classic.roots[0].manager, classic.roots[0].yarn_pin.as_deref()), (&Manager::YarnClassic, Some("yarn@1.22.22")));
        assert_eq!(project(&[("package.json", "{}"), ("pnpm-lock.yaml", "")]).roots[0].manager, Manager::Pnpm);
        assert_eq!(project(&[("package.json", "{}")]).roots[0].manager, Manager::Unknown);
    }

    #[test]
    fn projects_to_index() {
        let p = project(&[
            ("tsconfig.json", r#"{"files": [], "references": [{"path": "./a"}, {"path": "./b"}]}"#),
            ("a/tsconfig.json", "{}"),
            ("b/tsconfig.json", "{}"),
            ("b/nested/tsconfig.json", "{}"),
            ("tools/x/tsconfig.json", "{}"),
        ]);
        assert_eq!(p.index_projects(""), vec![".".to_string(), "a".to_string(), "b".to_string(), "tools/x".to_string()]);
        let q = project(&[("web/tsconfig.json", "{}"), ("web/sub/tsconfig.json", "{}")]);
        assert_eq!(q.index_projects("web"), vec![".".to_string()]);
    }
}
