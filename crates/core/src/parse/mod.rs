//! What a parser reports for one source file. Swift comes from the Swift helper (SwiftSyntax), Kotlin and
//! TypeScript from tree-sitter; all fill the same shapes, which follow the prototype's `Syntax.swift`.

pub mod cache;
pub mod kotlin;
pub mod swift_helper;
pub mod treesitter;
pub mod typescript;

use crate::model::ItemKind;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// A declaration found in one source file at one side of the change. Kinds and fields are shared by
/// every language; a language leaves the ones it has no equivalent for at their defaults.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Declaration {
    pub kind: ItemKind,
    /// Simple name ("add", "init", "CartService"); for extensions the extended type.
    pub name: String,
    /// Human-readable qualified name: "CartService.add(item:)", "extension CartService: Sendable".
    pub qualified_name: String,
    /// Qualified name of the enclosing type scope ("CartService"), None at top level.
    #[serde(default)]
    pub scope: Option<String>,
    #[serde(default)]
    pub parent_index: Option<usize>,
    /// Name plus argument labels, used to match overloads: "add(item:)".
    pub labels_key: String,
    pub signature_display: String,
    /// Trivia-free header tokens without attributes and modifiers.
    pub signature_canon: String,
    /// Trivia-free attributes + modifiers.
    pub modifiers_canon: String,
    /// Trivia-free body tokens (empty for containers: their members are compared one by one).
    pub body_canon: String,
    /// Raw text of the declaration (header only for containers), used to detect cosmetic-only changes.
    pub raw_text: String,
    #[serde(default)]
    pub access: Option<String>,
    #[serde(default)]
    pub attributes: Vec<String>,
    #[serde(default)]
    pub modifiers: Vec<String>,
    #[serde(default)]
    pub inherited: Vec<String>,
    #[serde(default)]
    pub is_async: bool,
    #[serde(default)]
    pub is_throws: bool,
    #[serde(default)]
    pub throws_type: Option<String>,
    #[serde(default)]
    pub is_stored: bool,
    #[serde(default)]
    pub is_static: bool,
    #[serde(default)]
    pub type_annotation: Option<String>,
    /// Declared inside a protocol (a requirement).
    #[serde(default)]
    pub in_protocol: bool,
    /// Kind of the enclosing container, if any.
    #[serde(default)]
    pub parent_kind: Option<ItemKind>,
    pub start_line: u32,
    pub end_line: u32,
    /// Last line of the declaration's header: the line of the opening brace of its body or members.
    #[serde(default)]
    pub header_end_line: u32,
    /// Facts a language records for its own contract flags and risk, outside the compared text.
    #[serde(default)]
    pub traits: BTreeSet<String>,
}

impl Declaration {
    pub fn is_top_level(&self) -> bool {
        self.parent_index.is_none()
    }

    pub fn is_container(&self) -> bool {
        matches!(
            self.kind,
            ItemKind::Struct | ItemKind::Class | ItemKind::Enum | ItemKind::Actor | ItemKind::Protocol | ItemKind::Extension
        )
    }

    /// The name a type is known by: the extended type for an extension, else the qualified name.
    pub fn type_name(&self) -> &str {
        if self.kind == ItemKind::Extension {
            &self.name
        } else {
            &self.qualified_name
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct NameRef {
    pub name: String,
    pub line: u32,
    /// The module (Kotlin: the package; TypeScript: the import specifier) the name was imported from, when
    /// the language says.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub module: Option<String>,
    /// Last line of a statement that spans several lines (TypeScript imports), when the language says.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end_line: Option<u32>,
}

/// A lexical block that establishes or explicitly clears known reference isolation.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct IsolationRegion {
    pub start_line: u32,
    pub end_line: u32,
    pub start_byte: usize,
    pub end_byte: usize,
    pub isolation: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[serde(rename_all = "lowercase")]
pub enum MarkKind {
    Crash,
    Check,
    Flow,
    Concurrency,
    Isolation,
}

/// A construct on one line that matters for risk: a crash point, a check, a branch, a concurrency
/// primitive (a task, a continuation, a lock), or an isolation annotation in code.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct LineMark {
    pub kind: MarkKind,
    pub label: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ParsedFile {
    /// Id of the language that parsed the file.
    pub language: String,
    pub decls: Vec<Declaration>,
    #[serde(default)]
    pub imports: Vec<NameRef>,
    /// Free identifiers and type names (candidates for cross-component references).
    #[serde(default)]
    pub type_refs: Vec<NameRef>,
    /// Names used after a dot (`x.foo`), for member-level usage.
    #[serde(default)]
    pub member_refs: Vec<NameRef>,
    /// Risk-relevant constructs per line (crash points, checks, branches, concurrency).
    #[serde(default)]
    pub marks: BTreeMap<u32, Vec<LineMark>>,
    /// The file says it is generated, on top of the generated patterns.
    #[serde(default)]
    pub is_generated: bool,
    /// Source package, distinct from a build-system module (Kotlin). Empty means the default package.
    #[serde(default)]
    pub package_name: Option<String>,
    /// Packages whose names can be used without an explicit import binding.
    #[serde(default)]
    pub wildcard_imports: Vec<String>,
    #[serde(default)]
    pub isolation_regions: Vec<IsolationRegion>,
}

impl ParsedFile {
    /// Index of the innermost declaration containing `line`.
    pub fn enclosing_index(&self, line: u32) -> Option<usize> {
        let mut best: Option<usize> = None;
        for (i, d) in self.decls.iter().enumerate() {
            if d.start_line <= line && line <= d.end_line {
                match best {
                    Some(b) => {
                        let bd = &self.decls[b];
                        if d.end_line - d.start_line <= bd.end_line - bd.start_line {
                            best = Some(i);
                        }
                    }
                    None => best = Some(i),
                }
            }
        }
        best
    }

    /// Innermost declaration containing `line`.
    pub fn enclosing_decl(&self, line: u32) -> Option<&Declaration> {
        self.enclosing_index(line).map(|i| &self.decls[i])
    }

    /// Parent declarations, innermost first, excluding the declaration itself.
    pub fn enclosing_declarations(&self, decl: &Declaration) -> Vec<&Declaration> {
        let mut out = Vec::new();
        let mut current = decl.parent_index;
        while let Some(i) = current {
            let Some(parent) = self.decls.get(i) else { break };
            out.push(parent);
            current = parent.parent_index;
        }
        out
    }
}
