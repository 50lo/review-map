//! Structural review, deterministic part: new cycles, edges against the declared layering, new external
//! dependencies, new public API nobody calls, code its callers left behind, conformers a changed protocol
//! missed, and changed code no test references. Each finding is anchored to components, edges, or review
//! items of the same report (CORE-005). A port of the prototype's `Checks.swift`.
//!
//! With an index, "is X referenced" asks the index. The checks that claim "no callers" or "no test
//! references" (unused-api, orphaned, untested) run only when the index covers every file that could hold
//! such a reference: missing coverage is not evidence of no callers (CORE-003). The conformers check takes
//! supertypes from the index (`supertypes`), so it runs under the same coverage as unused-api and orphaned. A
//! language without an index gets none of them, as in the preliminary view.
//!
//! The comparison report matches by name, and there "is X referenced" means "does the identifier X appear
//! outside its own declaration". That over-counts uses, so the unused-code checks err towards saying nothing.

use super::{conformance_name, kind_group, Builder, DeclKey, Located, Mode, Pair, SideData};
use crate::config::Config;
use crate::lang::ConformanceUse;
use crate::model::*;
use crate::parse::Declaration;
use crate::paths::is_test_path;
use std::cell::OnceCell;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};

/// Where a declaration's name occurs on one side, outside the declaration itself.
#[derive(Clone)]
struct Occurrence {
    file: String,
    line: u32,
    is_test: bool,
}

/// Identifier occurrences of one side, built on first use.
struct WordIndex {
    words: HashMap<String, Vec<(u32, u32)>>,
    files: Vec<(String, bool, Vec<(u32, u32)>)>,
}

impl WordIndex {
    fn new(data: &SideData) -> WordIndex {
        let mut words: HashMap<String, Vec<(u32, u32)>> = HashMap::new();
        let mut files = Vec::new();
        for (path, parsed) in data.files() {
            if data.source.generated.contains(path) {
                continue;
            }
            let Some(bytes) = data.source.bytes(path) else { continue };
            let is_test = data.layout.file_component.get(path).map(|c| data.is_test_component(c)).unwrap_or(false) || is_test_path(path);
            let fi = files.len() as u32;
            files.push((path.clone(), is_test, parsed.decls.iter().filter(|d| d.traits.contains("test")).map(|d| (d.start_line, d.end_line)).collect()));
            let mut line = 1u32;
            let mut word: Vec<u8> = Vec::new();
            let flush = |word: &mut Vec<u8>, line: u32, words: &mut HashMap<String, Vec<(u32, u32)>>| {
                if word.is_empty() {
                    return;
                }
                // `$x` (a projected value) and `_x` (a backing store) use `x` too.
                let mut start = 0;
                while word.len() - start > 1 && (word[start] == b'$' || word[start] == b'_') {
                    start += 1;
                }
                let w = &word[start..];
                if !w[0].is_ascii_digit() {
                    words.entry(String::from_utf8_lossy(w).into_owned()).or_default().push((fi, line));
                }
                word.clear();
            };
            for &byte in &bytes {
                if byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'$' {
                    word.push(byte);
                } else {
                    flush(&mut word, line, &mut words);
                    if byte == b'\n' {
                        line += 1;
                    }
                }
            }
            flush(&mut word, line, &mut words);
        }
        WordIndex { words, files }
    }

    fn occurrences(&self, name: &str) -> Vec<Occurrence> {
        self.words
            .get(name)
            .into_iter()
            .flatten()
            .map(|&(fi, line)| {
                let (path, is_test, test_lines) = &self.files[fi as usize];
                Occurrence { file: path.clone(), line, is_test: *is_test || test_lines.iter().any(|r| r.0 <= line && line <= r.1) }
            })
            .collect()
    }
}

fn severity_order(s: &str) -> u8 {
    match s {
        "high" => 0,
        "medium" => 1,
        "low" => 2,
        _ => 3,
    }
}

pub struct StructuralChecks<'b, 'a> {
    b: &'b Builder<'a>,
    review_items: &'b [ReviewItem],
    edges: &'b [Edge],
    config: &'b Config,
    words: [OnceCell<WordIndex>; 2],
    /// Index mode: (side, file, decl index) -> the places that reference the declaration.
    indexed: [HashMap<(String, usize), Vec<Occurrence>>; 2],
    review_item_ids: HashSet<&'b str>,
    pair_id: HashMap<DeclKey, &'b str>,
}

fn si(s: Side) -> usize {
    if s == Side::Base {
        0
    } else {
        1
    }
}

impl<'b, 'a> StructuralChecks<'b, 'a> {
    pub fn new(b: &'b Builder<'a>, review_items: &'b [ReviewItem], edges: &'b [Edge], config: &'b Config) -> Self {
        let mut indexed: [HashMap<(String, usize), Vec<Occurrence>>; 2] = [HashMap::new(), HashMap::new()];
        for s in Side::BOTH {
            let data = b.side(s);
            for (path, list) in b.index_of(s) {
                let is_test = data.layout.file_component.get(path).map(|c| data.is_test_component(c)).unwrap_or(false) || is_test_path(path);
                let parsed = data.files().get(path);
                for r in list {
                    let Some((ti, _)) = b.decl_at(s, &r.target_file, r.target_line, &r.name) else { continue };
                    let in_test = is_test || parsed.and_then(|p| p.enclosing_decl(r.line)).map(|d| d.traits.contains("test")).unwrap_or(false);
                    indexed[si(s)].entry((r.target_file.clone(), ti)).or_default().push(Occurrence { file: path.clone(), line: r.line, is_test: in_test });
                }
            }
        }
        let mut pair_id = HashMap::new();
        for p in &b.pairs {
            if let Some(h) = &p.head {
                pair_id.insert(DeclKey::of(Side::Head, h), p.id.as_str());
            }
            if let Some(x) = &p.base {
                pair_id.insert(DeclKey::of(Side::Base, x), p.id.as_str());
            }
        }
        StructuralChecks {
            b,
            review_items,
            edges,
            config,
            words: [OnceCell::new(), OnceCell::new()],
            indexed,
            review_item_ids: review_items.iter().map(|e| e.id.as_str()).collect(),
            pair_id,
        }
    }

    pub fn run(&self) -> Vec<Finding> {
        let mut out = self.cycles();
        out.extend(self.layering());
        out.extend(self.new_externals());
        out.extend(self.unused_api());
        out.extend(self.orphaned());
        out.extend(self.conformers());
        out.extend(self.untested());
        out.sort_by(|a, b| (severity_order(&a.severity), &a.kind).cmp(&(severity_order(&b.severity), &b.kind)));
        let mut counts: HashMap<String, usize> = HashMap::new();
        for f in out.iter_mut() {
            let n = counts.entry(f.kind.clone()).or_insert(0);
            *n += 1;
            f.id = format!("{}:{n}", f.kind);
        }
        out
    }

    // MARK: Helpers

    fn name(&self, id: &str) -> String {
        self.b
            .head
            .layout
            .components
            .get(id)
            .or_else(|| self.b.base.layout.components.get(id))
            .map(|c| c.name.clone())
            .unwrap_or_else(|| id.strip_prefix("ext:").unwrap_or(id).to_string())
    }

    fn is_test_component(&self, id: &str) -> bool {
        self.b.head.layout.components.get(id).or_else(|| self.b.base.layout.components.get(id)).map(|c| c.is_test).unwrap_or(false)
    }

    /// The target a split folder belongs to.
    fn root(&self, id: &str, s: Side) -> String {
        self.b.side(s).layout.root_of(id).to_string()
    }

    fn is_low(&self, l: &Located, s: Side) -> bool {
        let data = self.b.side(s);
        l.decl().traits.contains("test") || data.is_test_component(&l.component) || is_test_path(&l.file) || data.source.generated.contains(&*l.file)
    }

    /// Whether every place that could reference a declaration from non-test code (`tests` false) or from a
    /// test (`tests` true) is known: by name in the comparison report, or through an index that covers every
    /// such file at head (CORE-003).
    fn knows_all_references(&self, l: &Located, tests: bool) -> bool {
        match self.b.mode_of(&l.parsed.language) {
            Mode::NameBased => true,
            Mode::Index => self.b.check_coverage.get(&l.parsed.language).map(|c| if tests { c.tests } else { c.callers }).unwrap_or(false),
            Mode::Preliminary | Mode::SyntaxOnly => false,
        }
    }

    fn is_public(&self, l: &Located) -> bool {
        let enclosing = l.parsed.enclosing_declarations(l.decl());
        self.b.language_of(&l.file).is_public_api(l.decl(), &enclosing)
    }

    /// Declarations that something calls without naming them: initializers, overrides, entry points,
    /// protocol requirements, and members of a type or extension that conforms to something (they may be witnesses).
    fn called_implicitly(&self, l: &Located) -> bool {
        let d = l.decl();
        if self.b.language_of(&l.file).is_implicitly_called(d) {
            return true;
        }
        if d.kind == ItemKind::Extension || d.kind == ItemKind::Init || d.in_protocol {
            return true;
        }
        if d.modifiers.iter().any(|m| m == "override") {
            return true;
        }
        if let Some(p) = self.b.parent_decl(l) {
            if !p.inherited.is_empty() || p.kind == ItemKind::Protocol {
                return true;
            }
        }
        false
    }

    fn word_index(&self, s: Side) -> &WordIndex {
        self.words[si(s)].get_or_init(|| WordIndex::new(self.b.side(s)))
    }

    /// Places that reference a declaration at one side, outside the declaration itself: what the index
    /// records, or in the comparison report, where the name appears. Files the index has no data for add
    /// nothing; the callers of this decide by `knows_all_references` whether the result may be trusted.
    fn references(&self, l: &Located, s: Side) -> Vec<Occurrence> {
        let d = l.decl();
        match self.b.mode_of(&l.parsed.language) {
            Mode::Index => self.indexed[si(s)]
                .get(&(l.file.to_string(), l.index))
                .into_iter()
                .flatten()
                .filter(|o| !(o.file == *l.file && d.start_line <= o.line && o.line <= d.end_line))
                .cloned()
                .collect(),
            Mode::NameBased => self.name_occurrences(l, s),
            Mode::Preliminary | Mode::SyntaxOnly => Vec::new(),
        }
    }

    /// Where the declaration's name appears at one side, outside the declaration itself.
    fn name_occurrences(&self, l: &Located, s: Side) -> Vec<Occurrence> {
        let d = l.decl();
        // Lines that name the declaration without using it: the declaration itself and extension headers of the type.
        let mut own: HashMap<&str, Vec<(u32, u32)>> = HashMap::new();
        own.entry(&l.file).or_default().push((d.start_line, d.end_line));
        if d.is_container() {
            for (path, file) in self.b.side(s).files() {
                for x in file.decls.iter().filter(|x| x.kind == ItemKind::Extension && x.name == d.name) {
                    own.entry(path.as_str()).or_default().push((x.start_line, x.start_line.max(x.header_end_line)));
                }
            }
        }
        self.word_index(s)
            .occurrences(&d.name)
            .into_iter()
            .filter(|o| !own.get(o.file.as_str()).map(|ranges| ranges.iter().any(|r| r.0 <= o.line && o.line <= r.1)).unwrap_or(false))
            .collect()
    }

    fn at(&self, o: &Occurrence, s: Side) -> String {
        match self.b.side(s).files().get(&o.file).and_then(|f| f.enclosing_decl(o.line)) {
            Some(encl) => format!("{} ({}:{})", encl.qualified_name, o.file, o.line),
            None => format!("{}:{}", o.file, o.line),
        }
    }

    fn location(&self, l: &Located, s: Side) -> Location {
        Location { file: l.file.to_string(), start_line: l.decl().start_line, end_line: l.decl().end_line, side: s }
    }

    fn ref_line(refs: &[Ref]) -> String {
        match refs.first() {
            None => String::new(),
            Some(r) if r.line == 0 => format!(" ({}, {})", r.symbol, r.file),
            Some(r) => format!(" ({} at {}:{})", r.symbol, r.file, r.line),
        }
    }

    fn main_anchor(&self, p: &Pair, l: &Located) -> Anchor {
        if self.review_item_ids.contains(p.id.as_str()) {
            Anchor::review_item(&p.id)
        } else {
            Anchor::component(&l.component)
        }
    }

    // MARK: Cycles

    /// The target-level graph of one side: split folders count as their target, external packages are left out.
    fn graph(&self, s: Side) -> BTreeMap<String, BTreeSet<String>> {
        let mut g: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
        for (from, tos) in self.b.edge_refs(s) {
            if from.starts_with("ext:") {
                continue;
            }
            for to in tos.keys().filter(|t| !t.starts_with("ext:")) {
                let (a, c) = (self.root(from, s), self.root(to, s));
                if a != c {
                    g.entry(a).or_default().insert(c);
                }
            }
        }
        g
    }

    fn cycles(&self) -> Vec<Finding> {
        let (hg, bg) = (self.graph(Side::Head), self.graph(Side::Base));
        let mut base_scc: HashMap<String, usize> = HashMap::new();
        for (i, scc) in cyclic(&bg).into_iter().enumerate() {
            for v in scc {
                base_scc.insert(v, i);
            }
        }
        let mut out = Vec::new();
        for scc in cyclic(&hg) {
            if let Some(first) = base_scc.get(&scc[0]) {
                if scc.iter().all(|v| base_scc.get(v) == Some(first)) {
                    continue;
                }
            }
            let members: BTreeSet<&str> = scc.iter().map(String::as_str).collect();
            let in_cycle = |a: &str| -> Vec<(String, String)> {
                hg.get(a).into_iter().flatten().filter(|t| members.contains(t.as_str())).map(|t| (a.to_string(), t.clone())).collect()
            };
            // The shortest cycle through an edge that is new at head.
            let new_edges: Vec<(String, String)> =
                scc.iter().flat_map(|a| in_cycle(a)).filter(|(a, c)| !bg.get(a).map(|s| s.contains(c)).unwrap_or(false)).collect();
            let Some((a, c)) = new_edges.into_iter().next().or_else(|| scc.iter().flat_map(|a| in_cycle(a)).next()) else { continue };
            let Some(back) = path(&hg, &c, &a, &members) else { continue };
            let mut cycle = vec![a.clone()];
            cycle.extend(back);
            let mut anchors: Vec<Anchor> = Vec::new();
            let mut evidence: Vec<String> = Vec::new();
            for pair in cycle.windows(2) {
                let (x, y) = (&pair[0], &pair[1]);
                let mut parts: Vec<&Edge> = self
                    .edges
                    .iter()
                    .filter(|e| self.root(&e.from, Side::Head) == *x && self.root(&e.to, Side::Head) == *y && e.status != EdgeStatus::Removed)
                    .collect();
                parts.sort_by_key(|e| ((e.status == EdgeStatus::Unchanged) as u8, e.from.clone(), e.to.clone()));
                anchors.extend(parts.iter().map(|e| Anchor::edge(&e.from, &e.to)));
                let is_new = !bg.get(x).map(|s| s.contains(y)).unwrap_or(false);
                evidence.push(format!(
                    "{} → {}{}{}",
                    self.name(x),
                    self.name(y),
                    if is_new { " (new)" } else { "" },
                    Self::ref_line(parts.first().map(|e| e.refs.as_slice()).unwrap_or(&[]))
                ));
            }
            anchors.extend(scc.iter().map(|c| Anchor::component(c)));
            out.push(Finding {
                id: String::new(),
                source: "check".into(),
                kind: "cycle".into(),
                severity: "high".into(),
                message: format!("New dependency cycle: {}.", cycle.iter().map(|c| self.name(c)).collect::<Vec<_>>().join(" → ")),
                evidence,
                suggestion: Some("Break the cycle at the new edge: move the shared code down, or invert the dependency with an interface.".into()),
                anchors,
                location: None,
            });
        }
        out
    }

    // MARK: Layering

    fn layer(&self, id: &str, s: Side) -> Option<&str> {
        self.b.side(s).layout.components.get(id).and_then(|c| c.layer.as_deref())
    }

    fn layering(&self) -> Vec<Finding> {
        if self.config.layers.as_ref().map(|l| l.is_empty()).unwrap_or(true) {
            return Vec::new();
        }
        // Violations grouped by the targets at their ends, so a declared dependency and the code under it are one finding.
        let mut groups: BTreeMap<(String, String), Vec<(&Edge, bool)>> = BTreeMap::new();
        for e in self.edges.iter().filter(|e| e.status != EdgeStatus::Removed && !e.to.starts_with("ext:") && !self.is_test_component(&e.from)) {
            let (Some(rf), Some(rt)) = (self.config.layer_rank(self.layer(&e.from, Side::Head)), self.config.layer_rank(self.layer(&e.to, Side::Head))) else {
                continue;
            };
            if rt >= rf {
                continue;
            }
            let broke_before = e.status != EdgeStatus::Added
                && match (self.config.layer_rank(self.layer(&e.from, Side::Base)), self.config.layer_rank(self.layer(&e.to, Side::Base))) {
                    (Some(bf), Some(bt)) => bt < bf,
                    _ => false,
                };
            if broke_before && e.symbols_added.is_empty() {
                continue;
            }
            groups.entry((self.root(&e.from, Side::Head), self.root(&e.to, Side::Head))).or_default().push((e, broke_before));
        }
        let mut out = Vec::new();
        for (_, mut group) in groups {
            // Code edges first: they say what crosses the boundary.
            group.sort_by_key(|(e, _)| (e.refs.iter().all(|r| r.line == 0) as u8, e.from.clone()));
            let e = group[0].0;
            let (lf, lt) = (self.layer(&e.from, Side::Head).unwrap_or(""), self.layer(&e.to, Side::Head).unwrap_or(""));
            let broke_before = group.iter().all(|(_, b)| *b);
            let mut evidence = vec![format!("{} is in {lf}, {} is in {lt}, which sits above it in reviewmap.yml.", self.name(&e.from), self.name(&e.to))];
            if broke_before {
                let syms: BTreeSet<&str> = group.iter().flat_map(|(e, _)| e.symbols_added.iter().map(String::as_str)).collect();
                evidence.push(format!(
                    "The dependency already broke the layering at base; it now also uses {}.",
                    syms.into_iter().collect::<Vec<_>>().join(", ")
                ));
            }
            for r in group.iter().flat_map(|(e, _)| e.refs.iter().filter(|r| r.side == Side::Head)).take(3) {
                evidence.push(if r.line == 0 { format!("{} in {}", r.symbol, r.file) } else { format!("{} at {}:{}", r.symbol, r.file, r.line) });
            }
            let mut anchors: Vec<Anchor> = group.iter().map(|(e, _)| Anchor::edge(&e.from, &e.to)).collect();
            anchors.push(Anchor::component(&e.from));
            anchors.push(Anchor::component(&e.to));
            out.push(Finding {
                id: String::new(),
                source: "check".into(),
                kind: "layering".into(),
                severity: if broke_before { "medium" } else { "high" }.into(),
                message: format!("{} ({lf}) depends on {} ({lt}), against the declared layering.", self.name(&e.from), self.name(&e.to)),
                evidence,
                suggestion: Some(format!(
                    "Move the code that needs {} up into {lt}, or pass what it needs down through an interface in {lf}.",
                    self.name(&e.to)
                )),
                anchors,
                location: None,
            });
        }
        out
    }

    // MARK: New external dependencies

    fn new_externals(&self) -> Vec<Finding> {
        let mut by_package: BTreeMap<&str, Vec<&Edge>> = BTreeMap::new();
        for e in self.edges.iter().filter(|e| e.status == EdgeStatus::Added && e.to.starts_with("ext:") && !e.from.starts_with("ext:")) {
            by_package.entry(e.to.as_str()).or_default().push(e);
        }
        let mut added: BTreeMap<String, &ExternalDepChange> = BTreeMap::new();
        for dep in self.b.external_deps.iter().filter(|d| d.change == "added") {
            added.entry(format!("ext:{}", dep.name)).or_insert(dep);
        }
        let ids: BTreeSet<String> = by_package.keys().map(|k| k.to_string()).chain(added.keys().cloned()).collect();
        let mut out = Vec::new();
        for id in ids {
            let mut users: Vec<&Edge> = by_package.get(id.as_str()).cloned().unwrap_or_default();
            users.sort_by(|a, b| a.from.cmp(&b.from));
            let pkg = self.name(&id);
            let lock = added.get(&id);
            let version = lock.and_then(|d| d.to.as_ref()).map(|v| format!(" at {v}")).unwrap_or_default();
            let mut evidence: Vec<String> = Vec::new();
            if lock.is_some() {
                evidence.push(format!("{pkg} is new in the lockfile{version}."));
            }
            evidence.extend(users.iter().take(5).map(|u| format!("{} → {pkg}{}", self.name(&u.from), Self::ref_line(&u.refs))));
            let only_tests = !users.is_empty() && users.iter().all(|u| self.is_test_component(&u.from));
            let mut names: Vec<String> = Vec::new();
            for u in &users {
                let n = self.name(&u.from);
                if !names.contains(&n) {
                    names.push(n);
                }
            }
            let who = if users.is_empty() {
                format!("The change adds {pkg}{version}")
            } else {
                format!(
                    "{}{} now depend{} on {pkg}",
                    names.iter().take(3).cloned().collect::<Vec<_>>().join(", "),
                    if names.len() > 3 { format!(" and {} more", names.len() - 3) } else { String::new() },
                    if names.len() == 1 { "s" } else { "" }
                )
            };
            let mut anchors: Vec<Anchor> = users.iter().map(|u| Anchor::edge(&u.from, &u.to)).collect();
            anchors.push(Anchor::component(&id));
            out.push(Finding {
                id: String::new(),
                source: "check".into(),
                kind: "new-external".into(),
                severity: if only_tests { "low" } else if lock.is_some() { "medium" } else { "low" }.into(),
                message: format!("{who}{}.", if lock.is_some() && !users.is_empty() { ", a new package" } else { "" }),
                evidence,
                suggestion: None,
                anchors,
                location: None,
            });
        }
        out
    }

    // MARK: Unused new API

    fn unused_api(&self) -> Vec<Finding> {
        let mut reported: HashSet<DeclKey> = HashSet::new();
        let mut out = Vec::new();
        let mut added: Vec<&Pair> = self.b.pairs.iter().filter(|p| p.base.is_none() && p.head.is_some()).collect();
        added.sort_by(|a, b| {
            let (x, y) = (a.head.as_ref().unwrap(), b.head.as_ref().unwrap());
            (&*x.file, x.decl().start_line).cmp(&(&*y.file, y.decl().start_line))
        });
        for p in added {
            let h = p.head.as_ref().unwrap();
            let d = h.decl();
            if !self.knows_all_references(h, false) || self.is_low(h, Side::Head) || d.kind == ItemKind::Case || !self.is_public(h) || self.called_implicitly(h) {
                continue;
            }
            // A member of a new type that is reported already goes with it.
            if let Some(pi) = d.parent_index {
                if reported.contains(&DeclKey { side: Side::Head, file: h.file.clone(), index: pi }) {
                    continue;
                }
            }
            let refs = self.references(h, Side::Head);
            if refs.iter().any(|o| !o.is_test) {
                continue;
            }
            reported.insert(DeclKey::of(Side::Head, h));
            let tests: Vec<&Occurrence> = refs.iter().filter(|o| o.is_test).collect();
            let exact = self.b.indexed_languages.contains(&h.parsed.language);
            let mut evidence = vec![if tests.is_empty() {
                if exact { "The index has no reference to it.".to_string() } else { format!("The name {} appears nowhere else in the repo.", d.name) }
            } else {
                format!("Only tests use it: {}.", tests.iter().take(3).map(|o| self.at(o, Side::Head)).collect::<Vec<_>>().join(", "))
            }];
            if let Some(a) = &d.access {
                evidence.push(format!("Declared {a}."));
            }
            out.push(Finding {
                id: String::new(),
                source: "check".into(),
                kind: "unused-api".into(),
                severity: "medium".into(),
                message: format!("New public {} {} has no callers outside tests.", d.kind.raw(), d.qualified_name),
                evidence,
                suggestion: Some("Keep it internal until something outside needs it, or drop it.".into()),
                anchors: vec![self.main_anchor(p, h)],
                location: Some(self.location(h, Side::Head)),
            });
        }
        out
    }

    // MARK: Code its callers left behind

    fn orphaned(&self) -> Vec<Finding> {
        let mut reported: HashSet<&str> = HashSet::new();
        let mut out = Vec::new();
        let mut both: Vec<&Pair> = self.b.pairs.iter().filter(|p| p.base.is_some() && p.head.is_some()).collect();
        both.sort_by(|a, b| {
            let (x, y) = (a.head.as_ref().unwrap(), b.head.as_ref().unwrap());
            (&*x.file, x.decl().start_line).cmp(&(&*y.file, y.decl().start_line))
        });
        for p in both {
            let (h, bl) = (p.head.as_ref().unwrap(), p.base.as_ref().unwrap());
            if !self.knows_all_references(h, false) || self.is_low(h, Side::Head) || self.is_public(h) || self.called_implicitly(h) {
                continue;
            }
            if let Some(pi) = h.decl().parent_index {
                if let Some(parent) = self.pair_id.get(&DeclKey { side: Side::Head, file: h.file.clone(), index: pi }) {
                    if reported.contains(parent) {
                        continue;
                    }
                }
            }
            let before: Vec<Occurrence> = self.references(bl, Side::Base).into_iter().filter(|o| !o.is_test).collect();
            if before.is_empty() || self.references(h, Side::Head).iter().any(|o| !o.is_test) {
                continue;
            }
            reported.insert(p.id.as_str());
            // Base callers that are gone or changed, and the review items they are.
            let mut callers: Vec<Anchor> = Vec::new();
            for o in &before {
                let Some(file) = self.b.base.files().get(&o.file) else { continue };
                let Some(i) = file.enclosing_index(o.line) else { continue };
                let Some(id) = self.pair_id.get(&DeclKey::new(Side::Base, &o.file, i)) else { continue };
                if !self.review_item_ids.contains(id) {
                    continue;
                }
                let anchor = Anchor::review_item(id);
                if !callers.contains(&anchor) {
                    callers.push(anchor);
                }
            }
            let mut anchors = vec![self.main_anchor(p, h)];
            anchors.extend(callers.into_iter().take(5));
            out.push(Finding {
                id: String::new(),
                source: "check".into(),
                kind: "orphaned".into(),
                severity: "medium".into(),
                message: format!("{} {} is no longer used: the change removed its last callers.", h.decl().kind.raw(), h.decl().qualified_name),
                evidence: vec![format!(
                    "At base it was used from {}{}.",
                    before.iter().take(3).map(|o| self.at(o, Side::Base)).collect::<Vec<_>>().join(", "),
                    if before.len() > 3 { format!(" and {} more", before.len() - 3) } else { String::new() }
                )],
                suggestion: Some("Delete it, unless a caller is still to come.".into()),
                anchors,
                location: Some(self.location(h, Side::Head)),
            });
        }
        out
    }

    // MARK: Conformers of a changed protocol

    fn conformers(&self) -> Vec<Finding> {
        let changed_head: HashSet<(String, usize)> =
            self.b.pairs.iter().filter(|p| p.is_changed()).filter_map(|p| p.head.as_ref()).map(|h| (h.file.to_string(), h.index)).collect();
        let is_abstract = |d: &Declaration| d.modifiers.iter().any(|m| m == "abstract");
        let mut out = Vec::new();
        for p in &self.b.pairs {
            let Some(h) = p.head.as_ref() else { continue };
            // A conformer can sit in any non-test file: the check needs the supertypes of all of them, which
            // only the index resolves (CORE-003), or the comparison report by name.
            if !self.knows_all_references(h, false) || self.is_low(h, Side::Head) {
                continue;
            }
            let Some(parent) = self.b.parent_decl(h) else { continue };
            let hdecl = h.decl();
            let abstract_ = parent.kind == ItemKind::Class && is_abstract(hdecl);
            let was_requirement =
                p.base.as_ref().map(|b| b.decl().in_protocol || (b.decl().parent_kind == Some(ItemKind::Class) && is_abstract(b.decl()))).unwrap_or(false);
            let gained_requirement = !was_requirement && (hdecl.in_protocol || abstract_);
            if !(hdecl.in_protocol || abstract_) || !(p.changes.contains(&ChangeKind::Added) || p.changes.contains(&ChangeKind::Signature) || gained_requirement) {
                continue;
            }
            let Some(interface_index) = self.b.parent_pair(h, Side::Head) else { continue };
            let interface = &self.b.pairs[interface_index];
            let proto = parent.qualified_name.clone();
            let mut missing: Vec<Located> = Vec::new();
            let mut stale: Vec<Located> = Vec::new();
            for candidate in self.b.language_of(&h.file).conformers(interface, Some(p), self.b, ConformanceUse::Check) {
                let c = candidate.declaration;
                let cd = c.decl();
                if cd.kind == ItemKind::Protocol || (cd.kind == ItemKind::Extension && cd.name == proto) || self.is_low(&c, Side::Head) {
                    continue;
                }
                if candidate.implementations.is_empty() {
                    if !missing.iter().any(|m| m.decl().qualified_name == cd.qualified_name) {
                        missing.push(c);
                    }
                } else if p.changes.contains(&ChangeKind::Signature) && !candidate.implementations.iter().any(|i| changed_head.contains(&(i.file.to_string(), i.index))) {
                    if !stale.iter().any(|m| m.decl().qualified_name == cd.qualified_name) {
                        stale.push(c);
                    }
                }
            }
            if missing.is_empty() && stale.is_empty() {
                continue;
            }
            let what = if p.changes.contains(&ChangeKind::Added) || gained_requirement { "New requirement" } else { "Changed requirement" };
            let type_name = |c: &Located| c.decl().type_name().to_string();
            let mut evidence: Vec<String> = Vec::new();
            if !missing.is_empty() {
                evidence.push(format!(
                    "No {} in {}, and no default implementation in an extension of {proto}.",
                    hdecl.name,
                    missing.iter().map(type_name).collect::<Vec<_>>().join(", ")
                ));
            }
            if !stale.is_empty() {
                evidence.push(format!("{} didn't change with it.", stale.iter().map(|c| format!("{}.{}", type_name(c), hdecl.name)).collect::<Vec<_>>().join(", ")));
            }
            let all: Vec<&Located> = missing.iter().chain(stale.iter()).collect();
            let comps: BTreeSet<&str> = all.iter().map(|c| &*c.component).collect();
            let mut anchors = vec![self.main_anchor(p, h)];
            anchors.extend(comps.into_iter().map(Anchor::component));
            out.push(Finding {
                id: String::new(),
                source: "check".into(),
                kind: "conformers".into(),
                severity: if missing.is_empty() { "medium" } else { "high" }.into(),
                message: format!(
                    "{what} {}: {} conformer{} updated.",
                    hdecl.qualified_name,
                    all.len(),
                    if all.len() == 1 { " wasn't" } else { "s weren't" }
                ),
                evidence,
                suggestion: Some(
                    if missing.is_empty() {
                        "Check that each implementation still does what the new signature promises."
                    } else {
                        "Implement it in each conformer, or add a default implementation."
                    }
                    .into(),
                ),
                anchors,
                location: all.first().map(|c| self.location(c, Side::Head)),
            });
        }
        out
    }

    // MARK: Changed code no test references

    fn untested(&self) -> Vec<Finding> {
        let head = self.b.head;
        let has_tests = head.files().keys().any(|path| is_test_path(path) || head.layout.file_component.get(path).map(|c| head.is_test_component(c)).unwrap_or(false));
        if !has_tests {
            return Vec::new();
        }
        // Only components that tests reach at all: ones a test component depends on, or with test files of their own.
        let mut tested: HashSet<String> = HashSet::new();
        for (from, tos) in self.b.edge_refs(Side::Head) {
            if self.is_test_component(from) {
                tested.extend(tos.keys().map(|t| self.root(t, Side::Head)));
            }
        }
        for (path, comp) in &head.layout.file_component {
            if is_test_path(path) {
                tested.insert(self.root(comp, Side::Head));
            }
        }
        let pair_of_id: HashMap<&str, &Pair> = self.b.pairs.iter().map(|p| (p.id.as_str(), p)).collect();
        let mut by_component: BTreeMap<&str, Vec<&ReviewItem>> = BTreeMap::new();
        for e in self.review_items {
            if e.change == ChangeKind::Cosmetic
                || e.change == ChangeKind::Removed
                || !matches!(e.kind, ItemKind::Func | ItemKind::Init | ItemKind::Var)
                || e.tags.iter().any(|t| t == "test" || t == "generated")
                || self.is_test_component(&e.component)
                || !tested.contains(&self.root(&e.component, Side::Head))
            {
                continue;
            }
            let Some(h) = pair_of_id.get(e.id.as_str()).and_then(|p| p.head.as_ref()) else { continue };
            if !self.knows_all_references(h, true) {
                continue;
            }
            let d = h.decl();
            if matches!(d.access.as_deref(), Some("private") | Some("fileprivate") | Some("#private") | Some("protected")) {
                continue;
            }
            let parent = self.b.parent_decl(h);
            let inherits: HashSet<String> = parent.map(|p| p.inherited.iter().map(|s| conformance_name(s).to_string()).collect()).unwrap_or_default();
            if self.b.language_of(&h.file).is_view_code(d, &inherits) {
                continue;
            }
            // An initializer is used through its type's name.
            let mut probe = h.clone();
            if let (ItemKind::Init, Some(pi)) = (d.kind, d.parent_index) {
                probe.index = pi;
            }
            if self.references(&probe, Side::Head).iter().any(|o| o.is_test) {
                continue;
            }
            by_component.entry(e.component.as_str()).or_default().push(e);
        }
        by_component
            .into_iter()
            .map(|(comp, list)| {
                let mut evidence: Vec<String> = list.iter().take(10).map(|e| format!("{} {} ({})", e.kind.raw(), e.qualified_name, e.change.raw())).collect();
                if list.len() > 10 {
                    evidence.push(format!("and {} more", list.len() - 10));
                }
                let mut anchors = vec![Anchor::component(comp)];
                anchors.extend(list.iter().map(|e| Anchor::review_item(&e.id)));
                Finding {
                    id: String::new(),
                    source: "check".into(),
                    kind: "untested".into(),
                    severity: "low".into(),
                    message: format!(
                        "No test references {} in {}.",
                        if list.len() == 1 { list[0].qualified_name.clone() } else { format!("{} changed review items", list.len()) },
                        self.name(comp)
                    ),
                    evidence,
                    suggestion: None,
                    anchors,
                    location: None,
                }
            })
            .collect()
    }
}

/// Strongly connected components with more than one node.
fn cyclic(graph: &BTreeMap<String, BTreeSet<String>>) -> Vec<Vec<String>> {
    struct State<'g> {
        graph: &'g BTreeMap<String, BTreeSet<String>>,
        index: usize,
        indices: HashMap<&'g str, usize>,
        low: HashMap<&'g str, usize>,
        stack: Vec<&'g str>,
        on_stack: HashSet<&'g str>,
        out: Vec<Vec<String>>,
    }
    fn visit<'g>(st: &mut State<'g>, v: &'g str) {
        st.indices.insert(v, st.index);
        st.low.insert(v, st.index);
        st.index += 1;
        st.stack.push(v);
        st.on_stack.insert(v);
        let graph = st.graph;
        for w in graph.get(v).into_iter().flatten() {
            let w = w.as_str();
            if !st.indices.contains_key(w) {
                visit(st, w);
                let lw = st.low[w];
                let lv = st.low.get_mut(v).unwrap();
                *lv = (*lv).min(lw);
            } else if st.on_stack.contains(w) {
                let iw = st.indices[w];
                let lv = st.low.get_mut(v).unwrap();
                *lv = (*lv).min(iw);
            }
        }
        if st.low[v] == st.indices[v] {
            let mut scc: Vec<String> = Vec::new();
            while let Some(w) = st.stack.pop() {
                st.on_stack.remove(w);
                scc.push(w.to_string());
                if w == v {
                    break;
                }
            }
            if scc.len() > 1 {
                scc.sort();
                st.out.push(scc);
            }
        }
    }
    let mut st = State { graph, index: 0, indices: HashMap::new(), low: HashMap::new(), stack: Vec::new(), on_stack: HashSet::new(), out: Vec::new() };
    let nodes: BTreeSet<&str> = graph.keys().map(String::as_str).chain(graph.values().flatten().map(String::as_str)).collect();
    for v in nodes {
        if !st.indices.contains_key(v) {
            visit(&mut st, v);
        }
    }
    st.out
}

/// The nodes after `from` on a shortest path from `from` to `to`, ending with `to`.
fn path(g: &BTreeMap<String, BTreeSet<String>>, from: &str, to: &str, within: &BTreeSet<&str>) -> Option<Vec<String>> {
    let mut prev: HashMap<String, String> = HashMap::new();
    let mut queue: VecDeque<String> = VecDeque::from([from.to_string()]);
    let mut seen: HashSet<String> = HashSet::from([from.to_string()]);
    while let Some(v) = queue.pop_front() {
        if v == to {
            let mut p = vec![to.to_string()];
            while let Some(q) = prev.get(&p[0]) {
                p.insert(0, q.clone());
            }
            return Some(p);
        }
        for w in g.get(&v).into_iter().flatten() {
            if within.contains(w.as_str()) && seen.insert(w.clone()) {
                prev.insert(w.clone(), v.clone());
                queue.push_back(w.clone());
            }
        }
    }
    None
}

// MARK: Similar names

/// "loadCartItems" -> ["load", "cart", "items"]; "load_cart" -> ["load", "cart"].
pub fn name_words(name: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut cur = String::new();
    let mut prev_lower = false;
    for ch in name.chars() {
        if ch == '_' || ch == '$' || !(ch.is_alphabetic() || ch.is_numeric()) {
            if !cur.is_empty() {
                words.push(cur.to_lowercase());
                cur.clear();
            }
            prev_lower = false;
            continue;
        }
        if ch.is_uppercase() && prev_lower && !cur.is_empty() {
            words.push(cur.to_lowercase());
            cur.clear();
        }
        cur.push(ch);
        prev_lower = ch.is_lowercase() || ch.is_numeric();
    }
    if !cur.is_empty() {
        words.push(cur.to_lowercase());
    }
    words
}

/// For each added review item, existing head declarations whose names are close: the same name in another
/// scope, most of the same words, or a near-identical spelling. Up to 5 each, closest first.
pub fn similar_declarations(b: &Builder, review_items: &[ReviewItem]) -> HashMap<String, Vec<Usage>> {
    struct Candidate {
        located: Located,
        words: BTreeSet<String>,
    }
    let mut out: HashMap<String, Vec<Usage>> = HashMap::new();
    let wanted: Vec<&ReviewItem> =
        review_items.iter().filter(|e| e.change == ChangeKind::Added && !e.tags.iter().any(|t| t == "test" || t == "generated")).collect();
    if wanted.is_empty() {
        return out;
    }
    let mut by_word: HashMap<String, Vec<usize>> = HashMap::new();
    let mut candidates: Vec<Candidate> = Vec::new();
    let added_head: HashSet<(String, usize)> =
        b.pairs.iter().filter(|p| p.base.is_none()).filter_map(|p| p.head.as_ref()).map(|h| (h.file.to_string(), h.index)).collect();
    let head = b.head;
    for (path, file) in head.files() {
        if head.source.generated.contains(path) || is_test_path(path) {
            continue;
        }
        let Some(comp) = head.layout.file_component.get(path) else { continue };
        if head.is_test_component(comp) {
            continue;
        }
        let language = b.language_of(path);
        let file_key: std::sync::Arc<str> = std::sync::Arc::from(path.as_str());
        let comp_key: std::sync::Arc<str> = std::sync::Arc::from(comp.as_str());
        for (i, d) in file.decls.iter().enumerate() {
            if d.kind == ItemKind::Extension || added_head.contains(&(path.clone(), i)) || language.is_implicitly_called(d) {
                continue;
            }
            let w: BTreeSet<String> = name_words(&d.name).into_iter().collect();
            if w.is_empty() {
                continue;
            }
            for x in &w {
                by_word.entry(x.clone()).or_default().push(candidates.len());
            }
            candidates.push(Candidate { located: Located { parsed: file.clone(), file: file_key.clone(), index: i, component: comp_key.clone() }, words: w });
        }
    }
    let pair_by_id: HashMap<&str, &Pair> = b.pairs.iter().map(|p| (p.id.as_str(), p)).collect();
    for e in wanted {
        let Some(h) = pair_by_id.get(e.id.as_str()).and_then(|p| p.head.as_ref()) else { continue };
        let hd = h.decl();
        if hd.kind == ItemKind::Case || b.language_of(&h.file).is_implicitly_called(hd) {
            continue;
        }
        let name = &hd.name;
        let words: BTreeSet<String> = name_words(name).into_iter().collect();
        let mut scored: Vec<(f64, &Located)> = Vec::new();
        let mut seen: HashSet<usize> = HashSet::new();
        for w in &words {
            for &ci in by_word.get(w).into_iter().flatten() {
                if !seen.insert(ci) {
                    continue;
                }
                let c = &candidates[ci];
                let cd = c.located.decl();
                if kind_group(cd.kind) != kind_group(hd.kind) {
                    continue;
                }
                let mut score = 0.0;
                if cd.name == *name {
                    // A short common name ("load", "id") in another type says little.
                    if words.len() >= 2 || name.chars().count() >= 8 {
                        score = 1.0;
                    }
                } else {
                    let inter = words.intersection(&c.words).count() as f64;
                    let union = words.union(&c.words).count() as f64;
                    let jaccard = inter / union;
                    if words.len() >= 2 && jaccard >= 0.66 {
                        score = jaccard * 0.9;
                    }
                    let (cl, nl) = (cd.name.chars().count() as i64, name.chars().count() as i64);
                    if nl >= 6 && (cl - nl).abs() <= 2 && edit_distance(&cd.name.to_lowercase(), &name.to_lowercase()) <= 2 {
                        score = f64::max(score, 0.8);
                    }
                }
                if score > 0.0 {
                    scored.push((score, &c.located));
                }
            }
        }
        if scored.is_empty() {
            continue;
        }
        // Closest first; among equals, by qualified name.
        scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal).then(a.1.decl().qualified_name.cmp(&b.1.decl().qualified_name)));
        out.insert(
            e.id.clone(),
            scored
                .into_iter()
                .take(5)
                .map(|(_, l)| Usage {
                    component: l.component.to_string(),
                    symbol: l.decl().qualified_name.clone(),
                    file: l.file.to_string(),
                    line: l.decl().start_line,
                    isolation: None,
                    side: None,
                })
                .collect(),
        );
    }
    out
}

pub fn edit_distance(a: &str, b: &str) -> usize {
    let (a, b): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
    if a.is_empty() {
        return b.len();
    }
    if b.is_empty() {
        return a.len();
    }
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    for i in 1..=a.len() {
        let mut cur = vec![i; b.len() + 1];
        for j in 1..=b.len() {
            cur[j] = (prev[j] + 1).min(cur[j - 1] + 1).min(prev[j - 1] + if a[i - 1] == b[j - 1] { 0 } else { 1 });
        }
        prev = cur;
    }
    prev[b.len()]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words_and_distance() {
        assert_eq!(name_words("loadCartItems"), vec!["load", "cart", "items"]);
        assert_eq!(name_words("load_cart"), vec!["load", "cart"]);
        assert_eq!(edit_distance("kitten", "sitting"), 3);
    }

    #[test]
    fn finds_cycles() {
        let mut g: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
        g.entry("a".into()).or_default().insert("b".into());
        g.entry("b".into()).or_default().insert("c".into());
        g.entry("c".into()).or_default().insert("a".into());
        g.entry("c".into()).or_default().insert("d".into());
        assert_eq!(cyclic(&g), vec![vec!["a".to_string(), "b".to_string(), "c".to_string()]]);
        let within: BTreeSet<&str> = ["a", "b", "c"].into();
        assert_eq!(path(&g, "b", "a", &within), Some(vec!["b".to_string(), "c".to_string(), "a".to_string()]));
    }
}
