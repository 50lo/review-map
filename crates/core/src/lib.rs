//! Review Map's core: read two revisions of a repository, parse them, and build the change report that
//! the review UI shows. See docs/rebuild-phase1-proposal.md for the plan this crate implements.

pub mod analyze;
pub mod bazel;
pub mod config;
pub mod git;
pub mod index;
pub mod lang;
pub mod model;
pub mod parse;
pub mod paths;
pub mod proc;
pub mod store;
pub mod tools;
pub mod session;
