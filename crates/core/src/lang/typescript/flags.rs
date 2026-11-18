//! TypeScript's contract flags: changes to declarations that importers and implementers depend on. A port
//! of the prototype's `TypeScriptFlags.swift`.

use crate::analyze::Builder;
use crate::model::{ChangeKind, ItemKind, Side};
use crate::parse::Declaration;
use std::collections::{BTreeSet, HashMap};

/// Flags that a member reports on its type too, unless the type itself is new or deleted.
const MEMBER_LEVEL: &[&str] = &[
    "interface-member-added",
    "interface-member-removed",
    "interface-member-changed",
    "enum-member-added",
    "enum-member-removed",
    "enum-member-changed",
    "abstract-member-added",
    "abstract-member-removed",
    "abstract-member-changed",
];

pub fn flags(b: &Builder, indices: &[usize]) -> HashMap<usize, Vec<String>> {
    let mut out: HashMap<usize, Vec<String>> = HashMap::new();
    let mut parent_flags: HashMap<usize, BTreeSet<String>> = HashMap::new();
    for &i in indices {
        let p = &b.pairs[i];
        let (bd, hd) = (p.base.as_ref().map(|l| l.decl()), p.head.as_ref().map(|l| l.decl()));
        let d = p.any().decl();
        let side = if p.head.is_some() { Side::Head } else { Side::Base };
        let (added, removed) = (bd.is_none(), hd.is_none());
        let mut flags: Vec<String> = Vec::new();

        if let (Some(bd), Some(hd)) = (bd, hd) {
            let mut toggled = |name: &str, has: &dyn Fn(&Declaration) -> bool| {
                if has(bd) != has(hd) {
                    flags.push(format!("{name}-{}", if has(hd) { "added" } else { "removed" }));
                }
            };
            let modifier = |m: &'static str| move |x: &Declaration| x.modifiers.iter().any(|y| y == m);
            if d.is_top_level() {
                toggled("export", &modifier("export"));
            }
            toggled("async", &|x: &Declaration| x.is_async);
            toggled("readonly", &modifier("readonly"));
            toggled("optional", &|x: &Declaration| x.traits.contains("optional"));
            toggled("static", &|x: &Declaration| x.is_static);
            toggled("abstract", &modifier("abstract"));
            if d.parent_kind == Some(ItemKind::Class) {
                let (ba, ha) = (bd.access.as_deref().unwrap_or("public"), hd.access.as_deref().unwrap_or("public"));
                if ba != ha {
                    flags.push(format!("access-changed:{ba}->{ha}"));
                }
            }
            if bd.is_container() {
                let (bs, hs): (BTreeSet<&String>, BTreeSet<&String>) = (bd.inherited.iter().collect(), hd.inherited.iter().collect());
                for t in hs.difference(&bs) {
                    flags.push(format!("supertype-added:{t}"));
                }
                for t in bs.difference(&hs) {
                    flags.push(format!("supertype-removed:{t}"));
                }
            }
            if bd.kind == ItemKind::Enum && bd.modifiers.iter().any(|m| m == "const") != hd.modifiers.iter().any(|m| m == "const") {
                flags.push("const-enum-changed".into());
            }
        }

        let mut to_parent: Vec<String> = Vec::new();
        let structural = added || removed || p.changes.iter().any(|c| *c != ChangeKind::Body && *c != ChangeKind::Cosmetic);
        let state = if added { "added" } else if removed { "removed" } else { "changed" };
        let mut member = |prefix: &str, flags: &mut Vec<String>| {
            let f = format!("{prefix}-member-{state}");
            flags.push(f.clone());
            to_parent.push(f);
        };
        if d.parent_kind == Some(ItemKind::Protocol) && structural {
            member("interface", &mut flags);
        }
        if d.kind == ItemKind::Case && d.parent_kind == Some(ItemKind::Enum) && (added || removed || p.changes.contains(&ChangeKind::Signature)) {
            member("enum", &mut flags);
        }
        if d.parent_kind == Some(ItemKind::Class) && structural && bd.or(hd).map(|x| x.modifiers.iter().any(|m| m == "abstract")).unwrap_or(false) && !d.is_container() {
            member("abstract", &mut flags);
        }

        let parent = p.head.as_ref().or(p.base.as_ref()).and_then(|l| b.parent_pair(l, side));
        if let Some(pi) = parent {
            if b.pairs[pi].base.is_none() || b.pairs[pi].head.is_none() {
                // A member of a new or deleted type: the type carries the change.
                flags.retain(|f| !MEMBER_LEVEL.contains(&f.as_str()));
                to_parent.clear();
            }
        }
        out.insert(i, flags);
        if let Some(pi) = parent {
            if !to_parent.is_empty() {
                parent_flags.entry(pi).or_default().extend(to_parent);
            }
        }
    }
    for (pi, list) in parent_flags {
        let entry = out.entry(pi).or_default();
        for f in list {
            if !entry.contains(&f) {
                entry.push(f);
            }
        }
    }
    out
}
