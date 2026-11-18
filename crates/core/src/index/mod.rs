//! Exact references from a language's compiler index, instead of name matching. Each language turns its
//! index into a `SideIndex` per side: Swift from the compiler's index store, Kotlin from per-target SCIP
//! indexes resolved through source and classpath ownership, and TypeScript from scip-typescript's index of
//! each Yarn Classic project or rules_ts workspace.

pub mod kotlin;
pub mod scip;
pub mod swift;
pub mod typescript;

use crate::model::Warning;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// A reference from one line of a file to a declaration in the repo, at one side.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[serde(rename_all = "camelCase")]
pub struct IndexedRef {
    pub line: u32,
    /// Repo-relative file and line of the referenced declaration's name.
    pub target_file: String,
    pub target_line: u32,
    /// The index's name for the symbol ("load()", "Config", "id").
    pub name: String,
}

/// Exact references for the source files of one side. Files missing from `refs` had no index data.
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
pub struct SideIndex {
    pub refs: BTreeMap<String, Vec<IndexedRef>>,
    /// What the index is missing, such as targets that could not be indexed.
    #[serde(default)]
    pub warnings: Vec<Warning>,
}
