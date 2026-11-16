//! Supertypes of head containers, resolved through the language's index (CORE-003).
//!
//! The main report never maps an inheritance clause to a declaration by name. For a file the index covers at
//! head, each entry of a container's inheritance clause is resolved to the declaration that the index's
//! reference on the container's header points at: the reference whose target is a type with the entry's
//! name. The name only picks which of the header's references belongs to which entry; the declaration is the
//! one the index names. An extension's extended type is resolved the same way.
//!
//! An entry stays unresolved, with no relation, when its file is not covered by the index, when no header
//! reference points at a type in the repository (an external supertype such as `View` or `Codable`, whose
//! definition the index readers drop), or when the header's references point at two different types with
//! that name. The conformers check is held back where the index misses a file (`add_index`); the comparison
//! report keeps matching clauses by name (`Builder::inheritors`).

use super::{conformance_name, Builder, DeclKey, Located, Mode};
use crate::index::IndexedRef;
use crate::model::{ItemKind, Side};
use std::collections::HashMap;

/// The head containers' supertypes and extensions that the index resolves, keyed by declaration identity.
#[derive(Default)]
pub struct Hierarchy {
    /// A head type -> the head containers (types and extensions) whose inheritance clause resolves to it, in
    /// source order.
    inheritors: HashMap<DeclKey, Vec<Located>>,
    /// A head container -> the head types its inheritance clause resolves to, in clause order.
    supertypes: HashMap<DeclKey, Vec<Located>>,
    /// A head extension -> the head type it extends.
    extended: HashMap<DeclKey, Located>,
    /// A head type -> its extensions, in source order.
    extensions: HashMap<DeclKey, Vec<Located>>,
}

/// "@MainActor Mod.Store<Item>" -> "Store".
fn simple_type_name(entry: &str) -> &str {
    let s = conformance_name(entry);
    let s = s.split(['<', '(']).next().unwrap_or(s);
    s.rsplit('.').next().unwrap_or(s).trim()
}

fn key(l: &Located) -> DeclKey {
    DeclKey::of(Side::Head, l)
}

impl Hierarchy {
    /// Resolves the clauses of every head container in a file that an indexed language's index covers.
    pub fn build(b: &Builder) -> Hierarchy {
        let mut h = Hierarchy::default();
        for (path, file) in b.head.files() {
            if b.mode_of(&file.language) != Mode::Index {
                continue;
            }
            let Some(refs) = b.index_refs(Side::Head, path) else { continue };
            for (i, d) in file.decls.iter().enumerate() {
                if !d.is_container() {
                    continue;
                }
                let Some(located) = b.located(Side::Head, path, i) else { continue };
                let last = d.header_end_line.max(d.start_line);
                let targets: Vec<Located> = refs
                    .iter()
                    .filter(|r| d.start_line <= r.line && r.line <= last)
                    .filter_map(|r| type_target(b, r))
                    .filter(|t| !(t.file == located.file && t.index == i))
                    .collect();
                let pick = |name: &str| -> Option<Located> {
                    let mut found: Vec<&Located> = targets.iter().filter(|t| t.decl().name == name).collect();
                    found.sort_by_key(|t| key(t));
                    found.dedup_by_key(|t| key(t));
                    if found.len() == 1 {
                        Some(found[0].clone())
                    } else {
                        None
                    }
                };
                if d.kind == ItemKind::Extension {
                    if let Some(t) = pick(simple_type_name(&d.name)) {
                        h.extensions.entry(key(&t)).or_default().push(located.clone());
                        h.extended.insert(key(&located), t);
                    }
                }
                // The names written in the clause, and for Kotlin also the ones its import aliases stand for.
                let mut names: Vec<&str> = d.inherited.iter().map(|s| simple_type_name(s)).collect();
                names.extend(d.traits.iter().filter_map(|t| t.strip_prefix("supertype:")).map(simple_type_name));
                let mut seen: Vec<DeclKey> = Vec::new();
                for name in names {
                    let Some(t) = pick(name) else { continue };
                    if seen.contains(&key(&t)) {
                        continue;
                    }
                    seen.push(key(&t));
                    h.inheritors.entry(key(&t)).or_default().push(located.clone());
                    h.supertypes.entry(key(&located)).or_default().push(t);
                }
            }
        }
        h
    }

    /// The head containers whose inheritance clause the index resolves to this head type.
    pub fn inheritors_of(&self, ty: &Located) -> &[Located] {
        self.inheritors.get(&key(ty)).map(Vec::as_slice).unwrap_or(&[])
    }

    /// The head types a container's inheritance clause resolves to; for a type, also those of its extensions.
    pub fn supertypes_of(&self, container: &Located) -> Vec<Located> {
        let ty = self.type_of(container);
        let mut out: Vec<Located> = Vec::new();
        for holder in std::iter::once(&ty).chain(self.extensions_of(&ty)).chain(std::iter::once(container)) {
            for s in self.supertypes.get(&key(holder)).map(Vec::as_slice).unwrap_or(&[]) {
                if !out.iter().any(|o| key(o) == key(s)) {
                    out.push(s.clone());
                }
            }
        }
        out
    }

    /// The type a container stands for: the extended type for a resolved extension, else the container.
    pub fn type_of(&self, container: &Located) -> Located {
        self.extended.get(&key(container)).cloned().unwrap_or_else(|| container.clone())
    }

    /// The head extensions the index resolves to this head type.
    pub fn extensions_of(&self, ty: &Located) -> &[Located] {
        self.extensions.get(&key(ty)).map(Vec::as_slice).unwrap_or(&[])
    }

    /// The members of the type a container stands for: those declared in the type and in each of its resolved
    /// extensions, and in the container itself when it is an extension the index did not resolve.
    pub fn members_of(&self, container: &Located) -> Vec<Located> {
        let ty = self.type_of(container);
        let mut holders: Vec<&Located> = vec![&ty];
        holders.extend(self.extensions_of(&ty));
        if key(container) != key(&ty) && !holders.iter().any(|h| key(h) == key(container)) {
            holders.push(container);
        }
        let mut out = Vec::new();
        for holder in holders {
            for (i, m) in holder.parsed.decls.iter().enumerate() {
                if m.parent_index == Some(holder.index) {
                    out.push(Located { parsed: holder.parsed.clone(), file: holder.file.clone(), index: i, component: holder.component.clone() });
                }
            }
        }
        out
    }
}

/// The head type a reference points at: a type declaration, or the type of a constructor (Kotlin's
/// `Base()` in a supertype list refers to the constructor).
fn type_target(b: &Builder, r: &IndexedRef) -> Option<Located> {
    let (index, d) = b.decl_at(Side::Head, &r.target_file, r.target_line, &r.name)?;
    let index = if d.is_container() {
        index
    } else if d.kind == ItemKind::Init {
        d.parent_index?
    } else {
        return None;
    };
    let target = b.located(Side::Head, &r.target_file, index)?;
    let td = target.decl();
    (td.is_container() && td.kind != ItemKind::Extension).then_some(target)
}
