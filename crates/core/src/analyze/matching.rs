//! Pairing the declarations of base and head, and saying how each pair changed.

use super::{kind_group, Builder, DeclKey, Located, Pair, SideData};
use crate::model::{ChangeKind, ItemKind, Side, Warning};
use crate::parse::Declaration;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::sync::Arc;

impl<'a> Builder<'a> {
    fn located_decls(&self, s: &SideData) -> BTreeMap<String, Vec<Located>> {
        let mut groups: BTreeMap<String, Vec<Located>> = BTreeMap::new();
        for (path, file) in s.files() {
            let Some(comp) = s.layout.file_component.get(path) else { continue };
            let file_key: Arc<str> = Arc::from(path.as_str());
            let comp_key: Arc<str> = Arc::from(comp.as_str());
            let package = file.package_name.as_ref().map(|p| format!("package:{p}|")).unwrap_or_default();
            for (i, d) in file.decls.iter().enumerate() {
                let name = if d.kind == ItemKind::Extension { &d.qualified_name } else { &d.name };
                let key = format!("{comp}|{package}{}|{}|{name}", kind_group(d.kind), d.scope.as_deref().unwrap_or(""));
                groups.entry(key).or_default().push(Located { parsed: file.clone(), file: file_key.clone(), index: i, component: comp_key.clone() });
            }
        }
        groups
    }

    /// Pairs declarations by component, package, kind group, scope, and name; overloads by exact
    /// signature first, then by argument labels. Then assigns ids and each language's contract flags.
    pub fn match_review_items(&mut self) {
        let mut bg = self.located_decls(self.base);
        let mut hg = self.located_decls(self.head);
        let keys: BTreeSet<String> = bg.keys().chain(hg.keys()).cloned().collect();
        type Pass = fn(&Declaration, &Declaration) -> bool;
        let passes: [Pass; 4] = [
            |a, b| a.signature_canon == b.signature_canon && a.modifiers_canon == b.modifiers_canon && a.body_canon == b.body_canon,
            |a, b| a.signature_canon == b.signature_canon && a.modifiers_canon == b.modifiers_canon,
            |a, b| a.signature_canon == b.signature_canon,
            |a, b| a.labels_key == b.labels_key,
        ];
        for key in keys {
            let mut bs = bg.remove(&key).unwrap_or_default();
            let mut hs = hg.remove(&key).unwrap_or_default();
            let mut matched: Vec<(Option<Located>, Option<Located>)> = Vec::new();
            // The common case, one declaration at each side, needs no passes.
            if bs.len() == 1 && hs.len() == 1 {
                matched.push((bs.pop(), hs.pop()));
            }
            for pass in passes {
                let mut i = 0;
                while i < bs.len() {
                    if let Some(j) = hs.iter().position(|h| pass(bs[i].decl(), h.decl())) {
                        let b = bs.remove(i);
                        let h = hs.remove(j);
                        matched.push((Some(b), Some(h)));
                    } else {
                        i += 1;
                    }
                }
            }
            if bs.len() == hs.len() {
                for (b, h) in bs.into_iter().zip(hs) {
                    matched.push((Some(b), Some(h)));
                }
            } else {
                if !bs.is_empty() && !hs.is_empty() {
                    self.warnings.insert(Warning::at(
                        "ambiguous-overloads",
                        format!(
                            "Could not pair {} base and {} head declarations of {}; reported as removed and added.",
                            bs.len(),
                            hs.len(),
                            bs[0].decl().qualified_name
                        ),
                        &hs[0].file,
                        hs[0].decl().start_line,
                    ));
                }
                for b in bs {
                    matched.push((Some(b), None));
                }
                for h in hs {
                    matched.push((None, Some(h)));
                }
            }
            for (b, h) in matched {
                let index = self.pairs.len();
                if let Some(b) = &b {
                    self.pair_of.insert(DeclKey::of(Side::Base, b), index);
                }
                if let Some(h) = &h {
                    self.pair_of.insert(DeclKey::of(Side::Head, h), index);
                }
                let changes = changes(b.as_ref().map(|l| l.decl()), h.as_ref().map(|l| l.decl()));
                self.pairs.push(Pair { base: b, head: h, id: String::new(), changes, flags: Vec::new() });
            }
        }
        self.assign_ids();
        self.compute_flags();
    }

    /// "<file>::<qualified name>", numbered when a file declares the name more than once. The file, not
    /// the component, starts the id, so it stays the same when components are refined from packages to targets.
    fn assign_ids(&mut self) {
        let mut order: Vec<usize> = (0..self.pairs.len()).collect();
        order.sort_by(|&x, &y| {
            let (a, b) = (self.pairs[x].any(), self.pairs[y].any());
            (&*a.file, &a.decl().qualified_name, a.decl().start_line).cmp(&(&*b.file, &b.decl().qualified_name, b.decl().start_line))
        });
        let mut used: HashMap<String, usize> = HashMap::new();
        for i in order {
            let a = self.pairs[i].any();
            let mut id = format!("{}::{}", a.file, a.decl().qualified_name);
            let n = used.entry(id.clone()).or_insert(0);
            *n += 1;
            if *n > 1 {
                id = format!("{id}#{n}");
            }
            self.pairs[i].id = id;
        }
    }

    /// Each language's contract flags, with its prefix.
    fn compute_flags(&mut self) {
        let mut by_language: BTreeMap<&'static str, Vec<usize>> = BTreeMap::new();
        for (i, p) in self.pairs.iter().enumerate() {
            by_language.entry(self.language_of(&p.any().file).id()).or_default().push(i);
        }
        let languages = self.languages.clone();
        for lang in languages {
            let indices = by_language.get(lang.id()).cloned().unwrap_or_default();
            let flags = lang.contract_flags(self, &indices);
            for (i, list) in flags {
                self.pairs[i].flags = list.into_iter().map(|f| format!("{}:{f}", lang.id())).collect();
            }
        }
    }
}

/// Every aspect of a declaration that changed, most significant first. A change of trivia only is
/// `cosmetic` (CORE-006); a container is never cosmetic, since its members are judged one by one.
pub fn changes(b: Option<&Declaration>, h: Option<&Declaration>) -> Vec<ChangeKind> {
    let Some(b) = b else { return vec![ChangeKind::Added] };
    let Some(h) = h else { return vec![ChangeKind::Removed] };
    let mut c = Vec::new();
    if b.signature_canon != h.signature_canon || (kind_group(b.kind) == "type" && b.kind != h.kind) {
        c.push(ChangeKind::Signature);
    }
    if b.modifiers_canon != h.modifiers_canon {
        c.push(ChangeKind::Modifiers);
    }
    if b.body_canon != h.body_canon {
        c.push(ChangeKind::Body);
    }
    if c.is_empty() && !b.is_container() && b.raw_text != h.raw_text {
        c.push(ChangeKind::Cosmetic);
    }
    c
}
