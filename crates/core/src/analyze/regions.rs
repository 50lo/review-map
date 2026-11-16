//! Review, removed, and context regions: where in each changed review item the reviewer should look, how
//! risky each place is, and which unchanged code explains it. Everything here is deterministic. A port
//! of the prototype's `Regions.swift`; while a language shows only what syntax proves (it is preliminary,
//! or ended without an index), only context that needs no reference resolution (the stored properties a
//! changed body relies on) is shown. Context found by name is for the comparison report only (CORE-003).

use super::{conformance_name, Builder, DeclKey, Located, Mode, Pair};
use crate::lang::{self, risk, ConformanceUse};
use crate::model::*;
use crate::parse::{Declaration, LineMark, MarkKind};
use crate::paths::is_test_path;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::sync::Arc;

struct Signal {
    weight: f64,
    reason: String,
}

fn signal(weight: f64, reason: impl Into<String>) -> Signal {
    Signal { weight, reason: reason.into() }
}

/// A run of changed lines in one review item: head lines, removed base lines, or both.
#[derive(Clone, Debug, PartialEq)]
pub struct ChangeBlock {
    pub head: Option<(u32, u32)>,
    pub base: Option<(u32, u32)>,
    /// The last unchanged head line before the block.
    pub anchor: u32,
}

struct ContextItem {
    file: String,
    start_line: u32,
    end_line: u32,
    relation: String,
    label: String,
    component: String,
    lines: Option<Vec<u32>>,
    supports: Vec<String>,
}

const FALLBACK_REASONS: &[&str] = &[
    "new declaration", "removed declaration", "removed lines", "signature changed", "modifiers changed", "changed lines", "changed", "new file", "removed file",
];

impl<'a> Builder<'a> {
    pub fn build_regions(&self, review_items: &[ReviewItem]) -> Vec<Region> {
        let ctx = RegionBuilder::new(self);
        let pair_by_id: HashMap<&str, &Pair> = self.pairs.iter().map(|p| (p.id.as_str(), p)).collect();
        let mut out = Vec::new();
        for e in review_items.iter().filter(|e| e.change != ChangeKind::Cosmetic) {
            out.extend(ctx.regions(e, pair_by_id.get(e.id.as_str()).copied()));
        }
        out
    }
}

struct RegionBuilder<'b, 'a> {
    b: &'b Builder<'a>,
    /// "component|scope" -> all head members of the scope, for definition, override, and state context.
    members: HashMap<String, Vec<Located>>,
    /// Top-level head declarations by simple name (no extensions).
    top_level: HashMap<String, Vec<Located>>,
    /// "component|Type" -> head type declarations (not extensions).
    types: HashMap<String, Vec<Located>>,
    /// "component|Type" -> what the head type and its extensions conform to or inherit from.
    type_inherits: HashMap<String, HashSet<String>>,
    /// Head declarations whose review item changed.
    changed_head: HashSet<DeclKey>,
}

fn overlaps(a: (u32, u32), b: (u32, u32)) -> bool {
    a.0 <= b.1 && b.0 <= a.1
}

impl<'b, 'a> RegionBuilder<'b, 'a> {
    fn new(b: &'b Builder<'a>) -> Self {
        let mut members: HashMap<String, Vec<Located>> = HashMap::new();
        let mut top_level: HashMap<String, Vec<Located>> = HashMap::new();
        let mut types: HashMap<String, Vec<Located>> = HashMap::new();
        let mut type_inherits: HashMap<String, HashSet<String>> = HashMap::new();
        for (path, file) in b.head.files() {
            let Some(comp) = b.head.layout.file_component.get(path) else { continue };
            let file_key: Arc<str> = Arc::from(path.as_str());
            let comp_key: Arc<str> = Arc::from(comp.as_str());
            for (i, d) in file.decls.iter().enumerate() {
                let item = Located { parsed: file.clone(), file: file_key.clone(), index: i, component: comp_key.clone() };
                if let Some(scope) = &d.scope {
                    members.entry(format!("{comp}|{scope}")).or_default().push(item.clone());
                }
                if d.is_top_level() && d.kind != ItemKind::Extension {
                    top_level.entry(d.name.clone()).or_default().push(item.clone());
                }
                if d.is_container() {
                    let type_name = d.type_name();
                    if d.kind != ItemKind::Extension {
                        types.entry(format!("{comp}|{type_name}")).or_default().push(item.clone());
                    }
                    for c in &d.inherited {
                        type_inherits.entry(format!("{comp}|{type_name}")).or_default().insert(conformance_name(c).to_string());
                    }
                }
            }
        }
        let mut changed_head = HashSet::new();
        for p in b.pairs.iter().filter(|p| p.is_changed()) {
            if let Some(h) = &p.head {
                changed_head.insert(DeclKey::of(Side::Head, h));
            }
        }
        RegionBuilder { b, members, top_level, types, type_inherits, changed_head }
    }

    fn slice(&self, side: Side, file: &str, range: (u32, u32)) -> Vec<String> {
        let Some(all) = self.b.side(side).source.lines(file) else { return Vec::new() };
        let lo = range.0.max(1) as usize;
        let hi = (range.1 as usize).min(all.len());
        if lo <= hi {
            all[lo - 1..hi].to_vec()
        } else {
            Vec::new()
        }
    }

    // MARK: Review regions

    fn regions(&self, e: &ReviewItem, pair: Option<&Pair>) -> Vec<Region> {
        let is_low = e.tags.iter().any(|t| t == "test" || t == "generated");
        let region = |kind: &str, file: &str, lines: (u32, u32), side: Side, risk: f64, reasons: Vec<String>, anchor: Option<u32>| Region {
            id: String::new(),
            review_item: e.id.clone(),
            kind: kind.to_string(),
            file: file.to_string(),
            start_line: lines.0,
            end_line: lines.1,
            side,
            risk,
            reasons,
            supports: None,
            relation: None,
            component: None,
            lines: None,
            anchor,
            llm: None,
        };
        let Some(pair) = pair.filter(|_| e.kind != ItemKind::File && e.kind != ItemKind::Target) else {
            // Non-code contracts: one region over the file or setting, scored by its flags.
            let mut signals = self.flag_signals(e);
            let fallback = match e.change {
                ChangeKind::Added => "new file",
                ChangeKind::Removed => "removed file",
                _ => "changed",
            };
            signals.push(signal(risk::BASE, fallback));
            let mut r = region(
                if e.change == ChangeKind::Removed { "removed" } else { "review" },
                &e.location.file,
                (e.location.start_line, e.location.end_line),
                e.location.side,
                score(&signals, is_low),
                reasons(signals, e, is_low),
                None,
            );
            r.id = format!("{}/r1", e.id);
            return vec![r];
        };
        let (hd, bd) = (pair.head.as_ref(), pair.base.as_ref());
        let range = |d: &Declaration| (d.start_line, if d.is_container() { d.start_line.max(d.header_end_line) } else { d.end_line });
        let header = |d: &Declaration| (d.start_line, d.start_line.max(d.header_end_line));

        let mut blocks: Vec<ChangeBlock> = Vec::new();
        match (hd, bd) {
            (Some(hd), Some(bd)) => {
                let base = self.slice(Side::Base, &bd.file, range(bd.decl()));
                let head = self.slice(Side::Head, &hd.file, range(hd.decl()));
                blocks = change_blocks(&base, bd.decl().start_line, &head, hd.decl().start_line);
            }
            (Some(hd), None) => blocks.push(ChangeBlock { head: Some(range(hd.decl())), base: None, anchor: hd.decl().start_line - 1 }),
            (None, Some(bd)) => blocks.push(ChangeBlock { head: None, base: Some(range(bd.decl())), anchor: 0 }),
            (None, None) => {}
        }
        let is_header = |blk: &ChangeBlock| -> bool {
            if let (Some(h), Some(hd)) = (blk.head, hd) {
                if overlaps(h, header(hd.decl())) {
                    return true;
                }
            }
            if let (None, Some(bb), Some(bd)) = (blk.head, blk.base, bd) {
                if overlaps(bb, header(bd.decl())) {
                    return true;
                }
            }
            false
        };
        let mut header_index = blocks.iter().position(is_header);
        if let (None, Some(hd)) = (header_index, hd) {
            if blocks.is_empty() || !e.contract_flags.is_empty() {
                // Flags that come from members or extensions (a Codable shape, a conformance) belong on the declaration line.
                blocks.insert(0, ChangeBlock { head: Some(header(hd.decl())), base: None, anchor: hd.decl().start_line - 1 });
                header_index = Some(0);
            }
        }

        let ui = self.is_ui(e, hd);
        let used_from: BTreeSet<&str> = e
            .used_by
            .iter()
            .map(|u| u.component.as_str())
            .filter(|c| !self.b.head.is_test_component(c) && *c != e.component)
            .collect();
        let used_from = used_from.len();
        let mut out: Vec<Region> = Vec::new();
        for (n, blk) in blocks.iter().enumerate() {
            let mut signals: Vec<Signal> = Vec::new();
            if Some(n) == header_index {
                signals.extend(self.flag_signals(e));
                if e.is_interface && e.contract_flags.is_empty() && e.changes.contains(&ChangeKind::Signature) && bd.is_some() && hd.is_some() {
                    signals.push(signal(risk::MEDIUM, "interface signature changed"));
                }
                if hd.is_none() && e.is_interface {
                    signals.push(signal(risk::MEDIUM, "interface removed"));
                }
            }
            signals.extend(self.mark_signals(blk, hd, bd, ui));
            if used_from > 0 && e.is_interface {
                signals.push(signal(0.05 * used_from.min(4) as f64, format!("used from {used_from} component{}", if used_from == 1 { "" } else { "s" })));
            }
            let fallback = if hd.is_none() {
                "removed declaration"
            } else if bd.is_none() {
                "new declaration"
            } else if blk.head.is_none() {
                "removed lines"
            } else if Some(n) == header_index && e.changes.contains(&ChangeKind::Signature) {
                "signature changed"
            } else if Some(n) == header_index && e.changes.contains(&ChangeKind::Modifiers) {
                "modifiers changed"
            } else {
                "changed lines"
            };
            signals.push(signal(risk::BASE, fallback));
            let risk_value = score(&signals, is_low);
            let why = reasons(signals, e, is_low);
            if let (Some(h), Some(hd)) = (blk.head, hd) {
                out.push(region("review", &hd.file, h, Side::Head, risk_value, why, None));
            } else if let (Some(bb), Some(bd)) = (blk.base, bd) {
                out.push(region("removed", &bd.file, bb, Side::Base, risk_value, why, hd.map(|_| blk.anchor)));
            }
        }
        for (i, r) in out.iter_mut().enumerate() {
            r.id = format!("{}/r{}", e.id, i + 1);
        }
        if is_low || hd.is_none() {
            return out;
        }
        let header_id = header_index.and_then(|i| out.get(i)).or(out.first()).map(|r| r.id.clone());
        let context = self.context(e, pair, &out, header_id);
        out.extend(context);
        out
    }

    /// Each flag weighs what its language says; the reason is the flag itself.
    fn flag_signals(&self, e: &ReviewItem) -> Vec<Signal> {
        e.contract_flags
            .iter()
            .map(|f| match lang::split_flag(f) {
                Some((language, name)) => signal(language.flag_risk(name, e.is_interface), f.clone()),
                None => signal(if e.is_interface { risk::HIGH } else { risk::MEDIUM }, f.clone()),
            })
            .collect()
    }

    fn marks(&self, side: Side, file: &str, range: Option<(u32, u32)>) -> BTreeMap<LineMark, usize> {
        let mut counts = BTreeMap::new();
        let (Some(range), Some(parsed)) = (range, self.b.side(side).files().get(file)) else { return counts };
        for (_, list) in parsed.marks.range(range.0..=range.1) {
            for m in list {
                *counts.entry(m.clone()).or_insert(0) += 1;
            }
        }
        counts
    }

    fn mark_signals(&self, blk: &ChangeBlock, head: Option<&Located>, base: Option<&Located>, ui: bool) -> Vec<Signal> {
        // A deleted declaration is judged by what used it, not by the checks it contained.
        let Some(head) = head else { return Vec::new() };
        let hm = self.marks(Side::Head, &head.file, blk.head);
        let bm = base.map(|b| self.marks(Side::Base, &b.file, blk.base)).unwrap_or_default();
        let mut signals = Vec::new();
        let labels = |kind: MarkKind, pred: &dyn Fn(usize, usize) -> bool| -> Vec<String> {
            let keys: BTreeSet<&LineMark> = hm.keys().chain(bm.keys()).collect();
            let mut out: Vec<String> = keys
                .into_iter()
                .filter(|m| m.kind == kind && pred(hm.get(*m).copied().unwrap_or(0), bm.get(*m).copied().unwrap_or(0)))
                .map(|m| m.label.clone())
                .collect();
            out.sort();
            out
        };
        let removed_checks = labels(MarkKind::Check, &|h, b| b > h);
        if !removed_checks.is_empty() {
            signals.push(signal(risk::HIGH, removed_checks.iter().map(|l| format!("{l} removed")).collect::<Vec<_>>().join(", ")));
        }
        // Isolation annotations in code are high; tasks, continuations, and locks are medium.
        type Pred = fn(usize, usize) -> bool;
        let directions: [(Pred, &str); 2] = [(|h, b| h > b, "concurrency: "), (|h, b| b > h, "concurrency removed: ")];
        for (pred, prefix) in directions {
            let isolation = labels(MarkKind::Isolation, &pred);
            let mut all = isolation.clone();
            all.extend(labels(MarkKind::Concurrency, &pred));
            all.sort();
            if !all.is_empty() {
                signals.push(signal(if isolation.is_empty() { risk::MEDIUM } else { risk::HIGH }, format!("{prefix}{}", all.join(", "))));
            }
        }
        let crashes = labels(MarkKind::Crash, &|h, b| h > b);
        if !crashes.is_empty() {
            signals.push(signal(risk::MEDIUM, crashes.iter().map(|l| format!("new {l}")).collect::<Vec<_>>().join(", ")));
        }
        let flow = labels(MarkKind::Flow, &|h, b| h + b > 0);
        if !flow.is_empty() {
            let shown: Vec<&str> = flow.iter().take(4).map(String::as_str).collect();
            signals.push(signal(
                if ui { risk::BASE * 1.5 } else { risk::MEDIUM },
                format!("{}{}", if ui { "view control flow: " } else { "control flow: " }, shown.join(", ")),
            ));
        }
        signals
    }

    fn is_ui(&self, e: &ReviewItem, hd: Option<&Located>) -> bool {
        if self.b.head.layout.components.get(&e.component).and_then(|c| c.layer.as_deref()) == Some("ui") {
            return true;
        }
        let Some(hd) = hd else { return false };
        let d = hd.decl();
        let mut inherits: HashSet<String> = d.scope.as_ref().and_then(|s| self.type_inherits.get(&format!("{}|{s}", hd.component))).cloned().unwrap_or_default();
        if d.is_container() {
            if let Some(more) = self.type_inherits.get(&format!("{}|{}", hd.component, d.type_name())) {
                inherits.extend(more.iter().cloned());
            }
        }
        self.b.language_of(&hd.file).is_view_code(d, &inherits)
    }

    // MARK: Context regions

    fn context(&self, e: &ReviewItem, pair: &Pair, regions: &[Region], header_id: Option<String>) -> Vec<Region> {
        let Some(hd) = pair.head.as_ref() else { return Vec::new() };
        let b = self.b;
        let d = hd.decl();
        let language = b.language_of(&hd.file);
        let mode = b.mode_of(language.id());
        let preliminary = mode.is_syntax_only();
        let mut items: Vec<ContextItem> = Vec::new();
        let mut keys: HashMap<(String, u32, u32), usize> = HashMap::new();
        let mut add = |items: &mut Vec<ContextItem>, it: ContextItem| -> bool {
            // Never point at the review item itself.
            if it.file == *hd.file && it.start_line == d.start_line {
                return false;
            }
            // One snippet per declaration; a specific relation (override, conformer) wins over caller.
            let key = (it.file.clone(), it.start_line, it.end_line);
            if let Some(&i) = keys.get(&key) {
                for s in &it.supports {
                    if !items[i].supports.contains(s) {
                        items[i].supports.push(s.clone());
                    }
                }
                if items[i].relation == "caller" && (it.relation == "override" || it.relation == "conformer") {
                    items[i].relation = it.relation;
                    items[i].lines = it.lines;
                }
                return false;
            }
            keys.insert(key, items.len());
            items.push(it);
            true
        };
        let decl_item = |x: &Located, relation: &str, supports: Vec<String>| -> ContextItem {
            let xd = x.decl();
            let span = xd.end_line - xd.start_line + 1;
            let mut lines: Option<Vec<u32>> = None;
            if span > 12 {
                let last = xd.start_line.max(xd.header_end_line).min(xd.start_line + 2);
                lines = Some((xd.start_line..=last).collect());
            }
            ContextItem {
                file: x.file.to_string(),
                start_line: xd.start_line,
                end_line: xd.end_line,
                relation: relation.to_string(),
                label: xd.qualified_name.clone(),
                component: x.component.to_string(),
                lines,
                supports,
            }
        };
        let header_supports: Vec<String> = header_id.into_iter().collect();
        let review_regions: Vec<&Region> = regions.iter().filter(|r| r.kind == "review").collect();

        // Definitions of what the changed lines reference.
        let mut definitions = 0;
        let index_refs = b.index_refs(Side::Head, &hd.file);
        if let Some(refs) = index_refs {
            // Index mode: the exact declarations the changed lines reference.
            for r in &review_regions {
                if definitions >= 6 {
                    break;
                }
                let mut per_region = 0;
                for rf in refs.iter().filter(|rf| rf.line >= r.start_line && rf.line <= r.end_line) {
                    if per_region >= 4 || definitions >= 6 {
                        break;
                    }
                    let Some((ti, td)) = b.decl_at(Side::Head, &rf.target_file, rf.target_line, &rf.name) else { continue };
                    let Some(x) = b.located(Side::Head, &rf.target_file, ti) else { continue };
                    // Not the review item or its own parts, nothing that changed (it has its own review item), and no
                    // stored properties of the same type (state context shows those).
                    if x.file == hd.file && td.start_line >= d.start_line && td.end_line <= d.end_line {
                        continue;
                    }
                    if x.file == hd.file && d.start_line >= td.start_line && d.end_line <= td.end_line {
                        continue;
                    }
                    if self.changed_head.contains(&DeclKey::of(Side::Head, &x)) {
                        continue;
                    }
                    if td.kind == ItemKind::Var && td.is_stored && td.scope.is_some() && td.scope == d.scope {
                        continue;
                    }
                    if add(&mut items, decl_item(&x, "definition", vec![r.id.clone()])) {
                        per_region += 1;
                        definitions += 1;
                    }
                }
            }
        } else if mode == Mode::NameBased {
            // The comparison report: definitions told by name.
            for r in &review_regions {
                if definitions >= 6 {
                    break;
                }
                let mut refs: Vec<(&str, u32, bool)> = hd
                    .parsed
                    .type_refs
                    .iter()
                    .map(|x| (x.name.as_str(), x.line, false))
                    .chain(hd.parsed.member_refs.iter().map(|x| (x.name.as_str(), x.line, true)))
                    .filter(|x| x.1 >= r.start_line && x.1 <= r.end_line)
                    .collect();
                refs.sort_by(|a, b| (a.1, a.0).cmp(&(b.1, b.0)));
                let mut seen: HashSet<&str> = HashSet::new();
                let mut per_region = 0;
                for (name, _, is_member) in refs {
                    if per_region >= 4 || definitions >= 6 {
                        break;
                    }
                    if name == d.name || !seen.insert(name) {
                        continue;
                    }
                    let Some(x) = self.definition(name, is_member, hd, (d.start_line, d.end_line)) else { continue };
                    if self.changed_head.contains(&DeclKey::of(Side::Head, &x)) {
                        continue;
                    }
                    if add(&mut items, decl_item(&x, "definition", vec![r.id.clone()])) {
                        per_region += 1;
                        definitions += 1;
                    }
                }
            }
        }

        // Callers, for changes that reach them.
        if !preliminary && (e.is_interface || e.changes.contains(&ChangeKind::Signature) || e.changes.contains(&ChangeKind::Modifiers) || !e.contract_flags.is_empty()) {
            for it in self.callers(e, hd, &header_supports) {
                add(&mut items, it);
            }
        }

        // Other conformers of a changed protocol, and their implementations of a changed requirement.
        if !preliminary && (d.kind == ItemKind::Protocol || d.parent_kind == Some(ItemKind::Protocol)) {
            let interface = if d.kind == ItemKind::Protocol { Some(pair) } else { b.parent_pair(hd, Side::Head).map(|i| &b.pairs[i]) };
            if let Some(interface) = interface {
                let requirement = if d.kind == ItemKind::Protocol { None } else { Some(pair) };
                let mut n = 0;
                for candidate in language.conformers(interface, requirement, b, ConformanceUse::Context) {
                    if n >= 5 {
                        break;
                    }
                    let located = if requirement.is_some() {
                        let Some(implementation) = candidate.implementations.into_iter().next() else { continue };
                        implementation
                    } else {
                        candidate.declaration
                    };
                    let mut it = decl_item(&located, "conformer", header_supports.clone());
                    if requirement.is_none() {
                        let ld = located.decl();
                        it.lines = Some((ld.start_line..=ld.start_line.max(ld.header_end_line)).collect());
                    }
                    add(&mut items, it);
                    n += 1;
                }
            }
        }

        // Overrides of a changed method, and the method a changed override overrides.
        let is_override = d.modifiers.iter().any(|m| m == "override");
        if let (false, true, Some(scope)) = (preliminary, matches!(d.kind, ItemKind::Func | ItemKind::Var), d.scope.as_ref()) {
            if d.parent_kind == Some(ItemKind::Class) || is_override {
                let mut n = 0;
                for sub in b.inheritors.get(scope).map(Vec::as_slice).unwrap_or(&[]) {
                    if n >= 5 {
                        break;
                    }
                    let sub_name = sub.decl().type_name();
                    for m in self.members.get(&format!("{}|{sub_name}", sub.component)).map(Vec::as_slice).unwrap_or(&[]) {
                        if m.decl().labels_key == d.labels_key && m.decl().modifiers.iter().any(|x| x == "override") {
                            add(&mut items, decl_item(m, "override", header_supports.clone()));
                            n += 1;
                        }
                    }
                }
                if is_override {
                    let owner = self.types.get(&format!("{}|{scope}", hd.component)).and_then(|v| v.first());
                    if let Some(super_name) = owner.and_then(|o| o.decl().inherited.first()).map(|s| conformance_name(s)) {
                        let suffix = format!("|{super_name}");
                        let mut keys: Vec<&String> = self.members.keys().filter(|k| k.ends_with(&suffix)).collect();
                        keys.sort();
                        for key in keys {
                            for m in &self.members[key] {
                                if m.decl().labels_key == d.labels_key {
                                    add(&mut items, decl_item(m, "override", header_supports.clone()));
                                }
                            }
                        }
                    }
                }
            }
        }

        // The stored properties of the enclosing type, which carry the invariants a changed body relies on.
        let is_body = matches!(d.kind, ItemKind::Func | ItemKind::Init) || (d.kind == ItemKind::Var && !d.is_stored);
        if let (true, Some(scope)) = (is_body, d.scope.as_ref()) {
            if d.parent_kind != Some(ItemKind::Protocol) && (e.changes.contains(&ChangeKind::Body) || e.change == ChangeKind::Added) {
                let mut by_file: BTreeMap<&str, Vec<&Located>> = BTreeMap::new();
                for p in self.members.get(&format!("{}|{scope}", hd.component)).map(Vec::as_slice).unwrap_or(&[]) {
                    let pd = p.decl();
                    if pd.kind == ItemKind::Var && pd.is_stored && !pd.is_static {
                        by_file.entry(&p.file).or_default().push(p);
                    }
                }
                for (file, props) in by_file {
                    let mut lines: Vec<u32> = props.iter().flat_map(|p| p.decl().start_line..=p.decl().end_line).collect();
                    lines.sort();
                    lines.dedup();
                    let (Some(first), Some(last)) = (lines.first().copied(), lines.last().copied()) else { continue };
                    add(
                        &mut items,
                        ContextItem {
                            file: file.to_string(),
                            start_line: first,
                            end_line: last,
                            relation: "state".to_string(),
                            label: format!("stored properties of {scope}"),
                            component: hd.component.to_string(),
                            lines: Some(lines),
                            supports: regions.iter().map(|r| r.id.clone()).collect(),
                        },
                    );
                }
            }
        }

        items
            .into_iter()
            .enumerate()
            .map(|(i, it)| Region {
                id: format!("{}/c{}", e.id, i + 1),
                review_item: e.id.clone(),
                kind: "context".to_string(),
                file: it.file,
                start_line: it.start_line,
                end_line: it.end_line,
                side: Side::Head,
                risk: 0.0,
                reasons: vec![it.label],
                supports: Some(it.supports),
                relation: Some(it.relation),
                component: Some(it.component),
                lines: it.lines,
                anchor: None,
                llm: None,
            })
            .collect()
    }

    /// The unchanged declaration a name in changed code refers to, when it can be told by name.
    fn definition(&self, name: &str, member: bool, hd: &Located, item_range: (u32, u32)) -> Option<Located> {
        let d = hd.decl();
        let comp = &*hd.component;
        // Members of the same type: `helper()`, `self.helper()`. Stored properties are covered by state context.
        let own_scope = d.scope.clone().or_else(|| d.is_container().then(|| d.type_name().to_string()));
        if let Some(scope) = own_scope {
            if let Some(x) = self.members.get(&format!("{comp}|{scope}")).and_then(|list| {
                list.iter().find(|m| {
                    let md = m.decl();
                    md.name == name && !(md.kind == ItemKind::Var && md.is_stored) && !md.is_container()
                })
            }) {
                return Some(x.clone());
            }
        }
        let visible_modules: HashSet<&str> = hd.parsed.imports.iter().map(|i| i.name.as_str()).collect();
        let visible = |c: &str| -> bool {
            c == comp || self.b.head.layout.components.get(c).and_then(|i| i.module.as_deref()).map(|m| visible_modules.contains(m)).unwrap_or(false)
        };
        if !member {
            let cands: Vec<&Located> = self.top_level.get(name).into_iter().flatten().filter(|x| visible(&x.component)).collect();
            let comps: BTreeSet<&str> = cands.iter().map(|x| &*x.component).collect();
            return if comps.len() == 1 { cands.first().map(|x| (*x).clone()) } else { None };
        }
        // `x.foo`: a member of a type the review item mentions, if exactly one such type declares it.
        let mut type_names: BTreeSet<&str> = BTreeSet::new();
        for r in &hd.parsed.type_refs {
            if r.line >= item_range.0 && r.line <= item_range.1 && r.name.chars().next().map(char::is_uppercase).unwrap_or(false) {
                type_names.insert(&r.name);
            }
        }
        if let Some(scope) = &d.scope {
            for p in self.members.get(&format!("{comp}|{scope}")).into_iter().flatten().filter(|p| p.decl().is_stored) {
                for r in &p.parsed.type_refs {
                    if r.line >= p.decl().start_line && r.line <= p.decl().end_line {
                        type_names.insert(&r.name);
                    }
                }
            }
        }
        let mut found: Vec<&Located> = Vec::new();
        let mut owners: BTreeSet<String> = BTreeSet::new();
        for t in type_names {
            let comps: BTreeSet<&str> = self.top_level.get(t).into_iter().flatten().map(|x| &*x.component).filter(|c| visible(c)).collect();
            for c in comps {
                let ms: Vec<&Located> =
                    self.members.get(&format!("{c}|{t}")).into_iter().flatten().filter(|m| m.decl().name == name && !m.decl().is_container()).collect();
                if !ms.is_empty() {
                    found.extend(ms);
                    owners.insert(format!("{c}|{t}"));
                }
            }
        }
        if owners.len() == 1 {
            found.first().map(|x| (*x).clone())
        } else {
            None
        }
    }

    /// Declarations that reference the review item: other components first (from usedBy), then the
    /// review item's own component, tests last. At most five.
    fn callers(&self, e: &ReviewItem, hd: &Located, supports: &[String]) -> Vec<ContextItem> {
        let b = self.b;
        let d = hd.decl();
        struct Entry {
            x: Located,
            lines: Vec<u32>,
            rank: u8,
        }
        let mut by_decl: HashMap<(String, u32), Entry> = HashMap::new();
        let mut order: Vec<(String, u32)> = Vec::new();
        let mut note = |comp: &str, file: &str, line: u32| {
            let Some(parsed) = b.head.files().get(file) else { return };
            let Some(idx) = parsed.enclosing_index(line) else { return };
            let encl = &parsed.decls[idx];
            if file == &*hd.file && encl.start_line >= d.start_line && encl.end_line <= d.end_line {
                return;
            }
            let key = (file.to_string(), encl.start_line);
            let entry = by_decl.entry(key.clone()).or_insert_with(|| {
                order.push(key);
                let is_test = b.head.is_test_component(comp) || is_test_path(file);
                Entry {
                    x: Located { parsed: parsed.clone(), file: Arc::from(file), index: idx, component: Arc::from(comp) },
                    lines: Vec::new(),
                    rank: if is_test { 2 } else if comp == e.component { 1 } else { 0 },
                }
            });
            if !entry.lines.contains(&line) {
                entry.lines.push(line);
            }
        };
        // Exact head references, in any component. Coverage belongs to the caller's file,
        // so an index for another language or target must not suppress uncovered callers.
        if let Some(pi) = b.pair_of.get(&DeclKey::of(Side::Head, hd)) {
            for u in b.index_callers.get(pi).into_iter().flatten() {
                note(&u.component, &u.file, u.line);
            }
        }
        // usedBy of files without index data: name matches, which only the comparison report has. It also
        // retains base-only usages, whose line numbers cannot locate head callers.
        for u in e.used_by.iter().filter(|u| u.side != Some(Side::Base) && !b.index_covers(Side::Head, &u.file)) {
            note(&u.component, &u.file, u.line);
        }
        // Same-component references by name, in the comparison report; members only count in files that
        // mention their type.
        if !d.is_container() && d.name.chars().count() >= 4 && d.name != "init" {
            // The innermost type must be named in the file, or the reference must come from inside that type.
            let owner: Option<&str> = d.scope.as_deref().map(|s| s.rsplit('.').next().unwrap_or(""));
            for (path, file) in b.head.files() {
                if b.head.layout.file_component.get(path).map(String::as_str) != Some(e.component.as_str()) || b.index_covers(Side::Head, path) {
                    continue;
                }
                if b.mode_of(&file.language) != Mode::NameBased {
                    continue;
                }
                let mentions_type = match owner {
                    None => true,
                    Some(o) => file.type_refs.iter().chain(file.member_refs.iter()).any(|r| r.name == o),
                };
                let refs: Vec<&crate::parse::NameRef> = if owner.is_none() {
                    file.type_refs.iter().collect()
                } else {
                    file.member_refs.iter().chain(file.type_refs.iter()).collect()
                };
                for r in refs.into_iter().filter(|r| r.name == d.name) {
                    let inside = match (&d.scope, file.enclosing_decl(r.line)) {
                        (Some(scope), Some(en)) => en.scope.as_deref().unwrap_or("") == scope || en.qualified_name == *scope,
                        _ => false,
                    };
                    if mentions_type || inside {
                        note(&e.component, path, r.line);
                    }
                }
            }
        }
        let mut ranked: Vec<(usize, (String, u32))> = order.into_iter().enumerate().collect();
        ranked.sort_by_key(|(offset, key)| (by_decl[key].rank, *offset));
        ranked
            .into_iter()
            .take(5)
            .map(|(_, key)| {
                let v = &by_decl[&key];
                let xd = v.x.decl();
                let mut lines: Vec<u32> = std::iter::once(xd.start_line).chain(v.lines.iter().copied()).collect();
                lines.sort();
                lines.dedup();
                ContextItem {
                    file: v.x.file.to_string(),
                    start_line: xd.start_line,
                    end_line: xd.end_line,
                    relation: "caller".to_string(),
                    label: xd.qualified_name.clone(),
                    component: v.x.component.to_string(),
                    lines: Some(lines),
                    supports: supports.to_vec(),
                }
            })
            .collect()
    }
}

fn score(signals: &[Signal], low: bool) -> f64 {
    let r = 1.0 - signals.iter().fold(1.0, |acc, s| acc * (1.0 - s.weight));
    ((if low { r * 0.2 } else { r }) * 1000.0).round() / 1000.0
}

fn reasons(signals: Vec<Signal>, e: &ReviewItem, low: bool) -> Vec<String> {
    let mut sorted: Vec<(usize, Signal)> = signals.into_iter().enumerate().collect();
    // Heaviest first; among equal weights, the earlier signal first.
    sorted.sort_by(|a, b| b.1.weight.partial_cmp(&a.1.weight).unwrap_or(std::cmp::Ordering::Equal).then(a.0.cmp(&b.0)));
    let mut sorted: Vec<Signal> = sorted.into_iter().map(|(_, s)| s).collect();
    // The fallback only explains a region that has no other reason.
    if sorted.len() > 1 {
        sorted.retain(|s| !(s.weight == risk::BASE && FALLBACK_REASONS.contains(&s.reason.as_str())));
    }
    let mut out: Vec<String> = sorted.into_iter().map(|s| s.reason).collect();
    if low {
        out.push(if e.tags.iter().any(|t| t == "generated") { "generated code" } else { "test code" }.to_string());
    }
    out
}

/// Changed blocks between the base and head lines of one review item, ignoring indentation, spacing, and
/// blank lines. This is what makes a formatting-only change produce no regions (CORE-006).
pub fn change_blocks(base: &[String], base_start: u32, head: &[String], head_start: u32) -> Vec<ChangeBlock> {
    fn norm(s: &str) -> String {
        s.split(|c| c == ' ' || c == '\t' || c == '\r').filter(|p| !p.is_empty()).collect::<Vec<_>>().join(" ")
    }
    let bf: Vec<(u32, String)> = base.iter().enumerate().map(|(i, s)| (i as u32, norm(s))).filter(|x| !x.1.is_empty()).collect();
    let hf: Vec<(u32, String)> = head.iter().enumerate().map(|(i, s)| (i as u32, norm(s))).filter(|x| !x.1.is_empty()).collect();
    let a: Vec<&str> = bf.iter().map(|x| x.1.as_str()).collect();
    let c: Vec<&str> = hf.iter().map(|x| x.1.as_str()).collect();
    let mut pairs = lcs(&a, &c);
    pairs.push((bf.len(), hf.len()));
    let mut out = Vec::new();
    let (mut pb, mut ph): (isize, isize) = (-1, -1);
    for (i, j) in pairs {
        let (i, j) = (i as isize, j as isize);
        let b_range = (pb + 1 < i).then(|| (base_start + bf[(pb + 1) as usize].0, base_start + bf[(i - 1) as usize].0));
        let h_range = (ph + 1 < j).then(|| (head_start + hf[(ph + 1) as usize].0, head_start + hf[(j - 1) as usize].0));
        if b_range.is_some() || h_range.is_some() {
            out.push(ChangeBlock { head: h_range, base: b_range, anchor: if ph >= 0 { head_start + hf[ph as usize].0 } else { head_start.saturating_sub(1) } });
        }
        pb = i;
        ph = j;
    }
    out
}

/// Longest common subsequence as index pairs. Common prefix and suffix are matched first;
/// a middle too large to compare is treated as fully replaced.
pub fn lcs(a: &[&str], b: &[&str]) -> Vec<(usize, usize)> {
    let (n, m) = (a.len(), b.len());
    let mut pre = 0;
    while pre < n && pre < m && a[pre] == b[pre] {
        pre += 1;
    }
    let mut suf = 0;
    while suf < n - pre && suf < m - pre && a[n - 1 - suf] == b[m - 1 - suf] {
        suf += 1;
    }
    let mut out: Vec<(usize, usize)> = (0..pre).map(|i| (i, i)).collect();
    let (an, bm) = (n - pre - suf, m - pre - suf);
    if an > 0 && bm > 0 && an * bm <= 4_000_000 {
        let w = bm + 1;
        let mut t = vec![0i32; (an + 1) * w];
        for i in (0..an).rev() {
            for j in (0..bm).rev() {
                t[i * w + j] = if a[pre + i] == b[pre + j] { t[(i + 1) * w + j + 1] + 1 } else { t[(i + 1) * w + j].max(t[i * w + j + 1]) };
            }
        }
        let (mut i, mut j) = (0, 0);
        while i < an && j < bm {
            if a[pre + i] == b[pre + j] {
                out.push((pre + i, pre + j));
                i += 1;
                j += 1;
            } else if t[(i + 1) * w + j] >= t[i * w + j + 1] {
                i += 1;
            } else {
                j += 1;
            }
        }
    }
    out.extend((0..suf).map(|k| (n - suf + k, m - suf + k)));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines(s: &str) -> Vec<String> {
        s.split('\n').map(str::to_string).collect()
    }

    #[test]
    fn reformatting_makes_no_blocks() {
        let base = lines("func a() {\n  let x = 1\n  return x\n}");
        let head = lines("func a() {\n\n      let x = 1\n\n      return   x\n}");
        assert!(change_blocks(&base, 10, &head, 20).is_empty());
    }

    #[test]
    fn changed_and_removed_lines() {
        let base = lines("func a() {\n  guard ok else { return }\n  let x = 1\n  return x\n}");
        let head = lines("func a() {\n  let x = 2\n  return x\n}");
        let blocks = change_blocks(&base, 10, &head, 20);
        assert_eq!(blocks, vec![ChangeBlock { head: Some((21, 21)), base: Some((11, 12)), anchor: 20 }]);
    }
}
