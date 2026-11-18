//! The optional `reviewmap.yml` of the reviewed repository, read from the head commit's tree (never from
//! the working tree; CORE-002). The shape follows the prototype's `Config.swift`.
//!
//! ```yaml
//! components:
//!   - name: Checkout
//!     paths: ["App/Features/Checkout/**"]
//!     layer: domain
//! layers:               # top to bottom: a component may use its own layer and the ones below it
//!   - name: app
//!     components: ["App", "App/*"]
//! split: { threshold: 30, maxDepth: 3 }
//! exclude: ["**/Pods/**"]
//! generated: ["**/*.generated.swift"]
//! index:
//!   enabled: true
//!   targets: ["//ios:App"]        # the Bazel targets that define the review scope
//!   bazelArgs: ["--config=sim"]   # extra arguments for Bazel queries and builds
//! ```

use regex::Regex;
use serde::Deserialize;

#[derive(Deserialize, Clone, Debug, Default, PartialEq)]
pub struct ComponentRule {
    pub name: String,
    #[serde(default)]
    pub paths: Vec<String>,
    #[serde(default)]
    pub layer: Option<String>,
}

#[derive(Deserialize, Clone, Debug, Default, PartialEq)]
pub struct Layer {
    pub name: String,
    /// Component names (globs) that belong to the layer, on top of rules that name it.
    #[serde(default)]
    pub components: Option<Vec<String>>,
}

#[derive(Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Split {
    pub threshold: Option<usize>,
    pub max_depth: Option<usize>,
}

#[derive(Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct IndexConfig {
    pub enabled: Option<bool>,
    /// Bazel targets that define the review scope.
    pub targets: Option<Vec<String>>,
    /// Extra arguments for Bazel queries and builds, such as a config: ["--config=sim"].
    pub bazel_args: Option<Vec<String>>,
}

#[derive(Deserialize, Clone, Debug, Default, PartialEq)]
pub struct Config {
    #[serde(default)]
    pub components: Option<Vec<ComponentRule>>,
    #[serde(default)]
    pub layers: Option<Vec<Layer>>,
    #[serde(default)]
    pub split: Option<Split>,
    #[serde(default)]
    pub exclude: Option<Vec<String>>,
    #[serde(default)]
    pub generated: Option<Vec<String>>,
    #[serde(default)]
    pub index: Option<IndexConfig>,
}

pub const DEFAULT_EXCLUDES: &[&str] = &[
    "**/.build/**",
    "**/Pods/**",
    "**/Carthage/**",
    "**/DerivedData/**",
    "**/node_modules/**",
    "**/SourcePackages/**",
    "**/.swiftpm/**",
];
/// Each language adds its own generated-file patterns.
pub const DEFAULT_GENERATED: &[&str] = &["**/Generated/**"];

impl Config {
    pub fn parse(text: &str) -> anyhow::Result<Config> {
        if text.trim().is_empty() {
            return Ok(Config::default());
        }
        Ok(serde_yaml_ng::from_str(text)?)
    }

    /// The position of a layer, 0 at the top; None when `layers` doesn't list it.
    pub fn layer_rank(&self, name: Option<&str>) -> Option<usize> {
        let name = name?;
        self.layers.as_ref()?.iter().position(|l| l.name == name)
    }

    pub fn split_threshold(&self) -> usize {
        self.split.as_ref().and_then(|s| s.threshold).unwrap_or(30)
    }

    pub fn split_max_depth(&self) -> usize {
        self.split.as_ref().and_then(|s| s.max_depth).unwrap_or(3)
    }

    pub fn exclude_matchers(&self) -> Vec<Glob> {
        DEFAULT_EXCLUDES
            .iter()
            .map(|s| s.to_string())
            .chain(self.exclude.clone().unwrap_or_default())
            .map(|p| Glob::new(&p))
            .collect()
    }

    pub fn generated_matchers(&self) -> Vec<Glob> {
        DEFAULT_GENERATED
            .iter()
            .map(|s| s.to_string())
            .chain(self.generated.clone().unwrap_or_default())
            .map(|p| Glob::new(&p))
            .collect()
    }
}

/// Minimal glob: `**` matches any number of path segments, `*` anything but `/`, `?` one character.
#[derive(Clone, Debug)]
pub struct Glob {
    pub pattern: String,
    regex: Regex,
}

impl Glob {
    pub fn new(pattern: &str) -> Glob {
        let chars: Vec<char> = pattern.chars().collect();
        let mut re = String::from("^");
        let mut i = 0;
        while i < chars.len() {
            let c = chars[i];
            if c == '*' {
                if i + 1 < chars.len() && chars[i + 1] == '*' {
                    // "**/" matches zero or more directories.
                    if i + 2 < chars.len() && chars[i + 2] == '/' {
                        re.push_str("(?:.*/)?");
                        i += 3;
                        continue;
                    }
                    re.push_str(".*");
                    i += 2;
                    continue;
                }
                re.push_str("[^/]*");
            } else if c == '?' {
                re.push_str("[^/]");
            } else {
                re.push_str(&regex::escape(&c.to_string()));
            }
            i += 1;
        }
        re.push('$');
        Glob { pattern: pattern.to_string(), regex: Regex::new(&re).expect("an escaped glob is a valid regex") }
    }

    pub fn matches(&self, path: &str) -> bool {
        self.regex.is_match(path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn globs() {
        assert!(Glob::new("**/Pods/**").matches("ios/Pods/A/b.swift"));
        assert!(Glob::new("**/Pods/**").matches("Pods/A/b.swift"));
        assert!(!Glob::new("**/Pods/**").matches("ios/Podsx/A/b.swift"));
        assert!(Glob::new("**/*.generated.swift").matches("a/b/C.generated.swift"));
        assert!(Glob::new("App/*").matches("App/Router"));
        assert!(!Glob::new("App/*").matches("App/Router/Deep"));
    }

    #[test]
    fn parses_index_settings() {
        let c = Config::parse("index:\n  targets: [\"//ios:App\"]\n  bazelArgs: [\"--config=sim\"]\nsplit:\n  threshold: 10\n").unwrap();
        assert_eq!(c.index.as_ref().unwrap().targets.as_ref().unwrap(), &vec!["//ios:App".to_string()]);
        assert_eq!(c.index.clone().unwrap().bazel_args.unwrap(), vec!["--config=sim".to_string()]);
        assert_eq!(c.split_threshold(), 10);
        assert_eq!(c.split_max_depth(), 3);
    }
}
