//! The annotation batches: one or more per component, each asking for the risk of every review and removed
//! region, keep and rank for every context region, and a one-line summary of every review item (and, in a
//! component's first batch, of the component). The prompt ends with the reply skeleton, every id filled in,
//! so the reply only has to fill in values. `scripts/fake-llm.sh` fills that skeleton by its text, so the
//! skeleton's lines keep the prototype's form (`"risk": null`, `"keep": null, "rank": null`, `"summary": ""`).

use super::cli::{check_text, parse_json, CallError, Runner};
use super::{Outcome, SourceLines};
use crate::model::*;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub(crate) struct ComponentReply {
    pub summary: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub(crate) struct RegionReply {
    pub id: String,
    pub risk: f64,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub(crate) struct ContextReply {
    pub id: String,
    pub keep: bool,
    #[serde(default)]
    pub rank: Option<i64>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub(crate) struct ItemReply {
    pub id: String,
    pub summary: String,
    pub regions: Vec<RegionReply>,
    #[serde(default)]
    pub context: Option<Vec<ContextReply>>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct BatchReply {
    #[serde(default)]
    pub component: Option<ComponentReply>,
    pub review_items: Vec<ItemReply>,
}

/// Part of a component's changed review items.
pub(crate) struct Batch {
    pub component: String,
    pub name: String,
    pub items: Vec<String>,
    pub blocks: Vec<String>,
    pub wants_summary: bool,
    pub part: usize,
    pub parts: usize,
    /// Cache keys by review item id.
    pub item_keys: HashMap<String, String>,
    pub component_key: String,
}

impl Batch {
    pub fn label(&self) -> String {
        if self.parts > 1 {
            format!("{} (part {} of {})", self.name, self.part, self.parts)
        } else {
            self.name.clone()
        }
    }
}

/// Whole review items are shown up to this many lines; longer ones show their regions with a margin.
const MAX_WHOLE_LINES: u32 = 150;
const MARGIN: u32 = 3;

/// Builds the prompts. A review item's block is also what its cache key hashes, so a result is reused only
/// when everything the LLM saw about the review item is the same.
pub(crate) struct PromptBuilder<'a> {
    pub report: &'a ChangeReport,
    pub lines: &'a SourceLines<'a>,
    pub review_notes: Option<&'a str>,
    own: HashMap<&'a str, Vec<&'a Region>>,
    context: HashMap<&'a str, Vec<&'a Region>>,
    components: HashMap<&'a str, &'a Component>,
    by_component: BTreeMap<&'a str, Vec<&'a ReviewItem>>,
}

/// Review items the LLM looks at: not cosmetic, test, or generated, and outside test components.
pub(crate) fn eligible<'r>(report: &'r ChangeReport) -> Vec<&'r ReviewItem> {
    let tests: HashSet<&str> = report.components.iter().filter(|c| c.is_test).map(|c| c.id.as_str()).collect();
    report
        .review_items
        .iter()
        .filter(|e| e.change != ChangeKind::Cosmetic && !tests.contains(e.component.as_str()) && !e.tags.iter().any(|t| t == "test" || t == "generated"))
        .collect()
}

pub(crate) fn kind_name(k: ComponentKind) -> &'static str {
    match k {
        ComponentKind::BazelTarget => "Bazel target",
        ComponentKind::BazelPackage => "Bazel package",
        ComponentKind::Folder => "folder",
        ComponentKind::External => "external package",
        ComponentKind::NpmPackage => "npm package",
        ComponentKind::Tsconfig => "tsconfig project",
    }
}

/// The languages of the change, by name, for the opening sentence.
pub(crate) fn languages(report: &ChangeReport) -> String {
    let names: Vec<String> = report.analyzer.languages.iter().map(|l| crate::lang::display_name(l)).collect();
    if names.is_empty() {
        "code".to_string()
    } else {
        names.join(" and ")
    }
}

fn quote(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".to_string())
}

impl<'a> PromptBuilder<'a> {
    pub fn new(report: &'a ChangeReport, lines: &'a SourceLines<'a>, review_notes: Option<&'a str>) -> PromptBuilder<'a> {
        let mut own: HashMap<&str, Vec<&Region>> = HashMap::new();
        let mut context: HashMap<&str, Vec<&Region>> = HashMap::new();
        for r in &report.regions {
            if r.kind == "context" {
                context.entry(r.review_item.as_str()).or_default().push(r);
            } else {
                own.entry(r.review_item.as_str()).or_default().push(r);
            }
        }
        let mut by_component: BTreeMap<&str, Vec<&ReviewItem>> = BTreeMap::new();
        for e in eligible(report) {
            by_component.entry(e.component.as_str()).or_default().push(e);
        }
        PromptBuilder {
            report,
            lines,
            review_notes,
            own,
            context,
            components: report.components.iter().map(|c| (c.id.as_str(), c)).collect(),
            by_component,
        }
    }

    pub fn items_of(&self, component: &str) -> &[&'a ReviewItem] {
        self.by_component.get(component).map(Vec::as_slice).unwrap_or(&[])
    }

    pub fn review_regions(&self, item: &str) -> &[&'a Region] {
        self.own.get(item).map(Vec::as_slice).unwrap_or(&[])
    }

    pub fn context_regions(&self, item: &str) -> &[&'a Region] {
        self.context.get(item).map(Vec::as_slice).unwrap_or(&[])
    }

    fn component_name(&self, id: &str) -> String {
        self.components.get(id).map(|c| c.name.clone()).unwrap_or_else(|| id.to_string())
    }

    pub fn component_header(&self, c: &Component) -> String {
        let mut parts = vec![kind_name(c.kind).to_string()];
        if let Some(l) = &c.layer {
            parts.push(format!("layer {l}"));
        }
        if let Some(m) = c.module.as_ref().filter(|m| **m != c.name) {
            parts.push(format!("module {m}"));
        }
        if let Some(s) = &c.status {
            parts.push(s.clone());
        }
        let mut out = format!("Component {} ({})", c.name, parts.join(", "));
        if !c.paths.is_empty() {
            out.push_str(&format!("\nPaths: {}", c.paths.join(", ")));
        }
        out
    }

    pub fn item_block(&self, e: &ReviewItem) -> String {
        let mut out = format!("### ReviewItem {}\n", e.id);
        let changes: Vec<&str> = e.changes.iter().map(|c| c.raw()).collect();
        out.push_str(&format!("{} {}, change: {}", e.kind.raw(), e.qualified_name, changes.join(", ")));
        out.push_str(if e.is_interface { ", interface\n" } else { ", internal\n" });
        if !e.contract_flags.is_empty() {
            out.push_str(&format!("Contract flags: {}\n", e.contract_flags.join(", ")));
        }
        if let Some(b) = e.signature.base.as_ref().filter(|b| Some(*b) != e.signature.head.as_ref()) {
            out.push_str(&format!("Base signature: {b}\n"));
        }
        if let Some(h) = &e.signature.head {
            out.push_str(&format!("Head signature: {h}\n"));
        }
        if !e.used_by.is_empty() {
            let comps: std::collections::BTreeSet<&str> = e.used_by.iter().map(|u| u.component.as_str()).collect();
            let names: Vec<String> = comps.into_iter().map(|c| self.component_name(c)).collect();
            out.push_str(&format!(
                "Used by {} declaration{} in {}\n",
                e.used_by.len(),
                if e.used_by.len() == 1 { "" } else { "s" },
                names.join(", ")
            ));
        }
        if !e.depends_on.is_empty() {
            let symbols: std::collections::BTreeSet<&str> = e.depends_on.iter().map(|u| u.symbol.as_str()).collect();
            let symbols: Vec<&str> = symbols.into_iter().take(12).collect();
            out.push_str(&format!("Depends on: {}\n", symbols.join(", ")));
        }
        let own = self.review_regions(&e.id);
        if e.change != ChangeKind::Removed {
            let regions: Vec<&Region> = own.iter().copied().filter(|r| r.side == e.location.side).collect();
            out.push_str(&self.code(e.location.side, &e.location, "Head code", &regions));
        }
        let base = if e.change == ChangeKind::Removed { Some(&e.location) } else { e.base_location.as_ref() };
        if let Some(b) = base.filter(|_| e.change != ChangeKind::Added) {
            let regions: Vec<&Region> = own.iter().copied().filter(|r| r.side == Side::Base).collect();
            out.push_str(&self.code(Side::Base, b, "Base code", &regions));
        }
        out.push_str("Regions:\n");
        for r in own {
            out.push_str(&format!("- {} {}, {} lines {}-{}", r.id, r.kind, r.side.name(), r.start_line, r.end_line));
            if let Some(a) = r.anchor {
                out.push_str(&format!(" (after head line {a})"));
            }
            out.push_str(&format!(", deterministic risk {:.2}: {}\n", r.risk, r.reasons.join("; ")));
        }
        let context = self.context_regions(&e.id);
        if !context.is_empty() {
            out.push_str("Context regions (unchanged code):\n");
            for c in context {
                let comp = c.component.as_deref().filter(|id| *id != e.component).map(|id| self.component_name(id)).unwrap_or_default();
                out.push_str(&format!("- {} {}", c.id, c.relation.as_deref().unwrap_or("context")));
                if !comp.is_empty() {
                    out.push_str(&format!(" in {comp}"));
                }
                out.push_str(&format!(
                    ": {} at {}:{}-{}, supports {}\n",
                    c.reasons.first().map(String::as_str).unwrap_or(""),
                    c.file,
                    c.start_line,
                    c.end_line,
                    c.supports.as_deref().unwrap_or(&[]).join(", ")
                ));
                let lines = self.lines.get(c.side, &c.file);
                let wanted: Vec<u32> = match &c.lines {
                    Some(l) => l.iter().copied().take(12).collect(),
                    None => (c.start_line..=c.end_line.min(c.start_line + 11)).collect(),
                };
                for n in wanted {
                    if n >= 1 && (n as usize) <= lines.len() {
                        out.push_str(&format!("    {n}| {}\n", lines[n as usize - 1]));
                    }
                }
            }
        }
        out
    }

    fn code(&self, side: Side, loc: &Location, title: &str, regions: &[&Region]) -> String {
        let lines = self.lines.get(side, &loc.file);
        if lines.is_empty() || loc.start_line < 1 {
            return format!("{title}: not available\n");
        }
        let end = loc.end_line.min(lines.len() as u32);
        if loc.start_line > end {
            return format!("{title}: not available\n");
        }
        let mut shown: Vec<(u32, u32)> = if end - loc.start_line < MAX_WHOLE_LINES {
            vec![(loc.start_line, end)]
        } else {
            // A long declaration shows its first lines and its regions; a type's members are review items of their own.
            let mut v = vec![(loc.start_line, end.min(loc.start_line + 2))];
            for r in regions {
                let last = r.end_line.min(r.start_line + MAX_WHOLE_LINES - 1);
                let lo = loc.start_line.max(r.start_line.saturating_sub(MARGIN));
                let hi = end.min(last + MARGIN);
                if lo <= hi {
                    v.push((lo, hi));
                }
            }
            v
        };
        shown.sort();
        let mut merged: Vec<(u32, u32)> = Vec::new();
        for r in shown {
            match merged.last_mut() {
                Some(last) if r.0 <= last.1 + 1 => last.1 = last.1.max(r.1),
                _ => merged.push(r),
            }
        }
        let mut out = format!("{title} ({}, lines {}-{end}):\n", loc.file, loc.start_line);
        let mut prev: Option<u32> = None;
        for (lo, hi) in merged {
            if let Some(p) = prev {
                if lo > p + 1 {
                    out.push_str("    …\n");
                }
            }
            for n in lo..=hi {
                out.push_str(&format!("    {n}| {}\n", lines[n as usize - 1]));
            }
            prev = Some(hi);
        }
        if let Some(p) = prev {
            if p < end {
                out.push_str("    …\n");
            }
        }
        out
    }

    pub fn prompt(&self, b: &Batch) -> String {
        let mut out = format!(
            "You are helping a reviewer read a {} change. A deterministic analyzer already found the changed \
declarations (review items) of one component, cut them into review regions with a risk score, and collected \
unchanged context regions that may explain them. You only annotate these facts: never add review items, \
regions, or ids, and never drop any.

Tasks:
1. Every review and removed region: a risk from 0 to 1 for how closely a reviewer must read it to catch \
a real problem (callers that break, persisted or network data that no longer decodes, isolation or \
concurrency mistakes, removed checks, changed behavior). The deterministic risk is a hint, not an anchor.
2. Every context region: keep true only when the reviewer needs it to understand the region it supports, \
and rank the kept ones of each review item from 1 (most needed). Use rank null when keep is false.
3. A one-line behavior summary, at most 20 words, for each review item{}: \
what the code does now that it didn't before, not which lines changed.

Reply with only the JSON object in <reply-template>, filled in: replace every null risk and keep and \
every empty summary, and set rank where it applies. Keep every id and the structure exactly. No prose \
and no code fences.
",
            languages(self.report),
            if b.wants_summary { " and for the component" } else { "" }
        );
        if let Some(notes) = self.review_notes {
            out.push_str(&format!("\n<review-notes>\nThe repository's REVIEW.md, its own notes on what matters:\n{notes}\n</review-notes>\n"));
        }
        if let Some(c) = self.components.get(b.component.as_str()) {
            out.push_str(&format!("\n## {}\n", self.component_header(c)));
        }
        if b.parts > 1 {
            out.push_str(&format!("This is part {} of {} of the component's changed review items.\n", b.part, b.parts));
        }
        let others: Vec<&&ReviewItem> = self.items_of(&b.component).iter().filter(|e| !b.items.contains(&e.id)).collect();
        if b.wants_summary && !others.is_empty() {
            out.push_str("Other changed review items in this component, not part of this batch:\n");
            for e in others.iter().take(60) {
                out.push_str(&format!("- {} {} ({})\n", e.kind.raw(), e.qualified_name, e.change.raw()));
            }
        }
        out.push('\n');
        out.push_str(&b.blocks.join("\n"));
        out.push_str(&format!("\n<reply-template>\n{}\n</reply-template>\n", self.template(b)));
        out
    }

    /// The reply skeleton with every id filled in, one value line per region, so the reply only has to fill values.
    pub fn template(&self, b: &Batch) -> String {
        let mut lines = vec!["{".to_string()];
        if b.wants_summary {
            lines.push(format!("  \"component\": {{\"id\": {}, \"summary\": \"\"}},", quote(&b.component)));
        }
        lines.push("  \"reviewItems\": [".to_string());
        for (i, id) in b.items.iter().enumerate() {
            lines.push("    {".to_string());
            lines.push(format!("      \"id\": {},", quote(id)));
            lines.push("      \"summary\": \"\",".to_string());
            lines.push("      \"regions\": [".to_string());
            let own = self.review_regions(id);
            for (j, r) in own.iter().enumerate() {
                lines.push(format!("        {{\"id\": {}, \"risk\": null}}{}", quote(&r.id), if j + 1 < own.len() { "," } else { "" }));
            }
            lines.push("      ],".to_string());
            lines.push("      \"context\": [".to_string());
            let context = self.context_regions(id);
            for (j, c) in context.iter().enumerate() {
                lines.push(format!("        {{\"id\": {}, \"keep\": null, \"rank\": null}}{}", quote(&c.id), if j + 1 < context.len() { "," } else { "" }));
            }
            lines.push("      ]".to_string());
            lines.push(format!("    }}{}", if i + 1 < b.items.len() { "," } else { "" }));
        }
        lines.push("  ]".to_string());
        lines.push("}".to_string());
        lines.join("\n")
    }

    // MARK: Validation

    /// Checks a reply against the batch: the same review items and regions, values in range, one-line text.
    pub fn validate(&self, reply: &BatchReply, b: &Batch) -> Vec<String> {
        let mut errors = Vec::new();
        if b.wants_summary {
            match &reply.component {
                Some(c) => errors.extend(check_text(&c.summary, "component summary", 200)),
                None => errors.push("component summary missing".to_string()),
            }
        }
        let expected: HashSet<&str> = b.items.iter().map(String::as_str).collect();
        let got: Vec<&str> = reply.review_items.iter().map(|e| e.id.as_str()).collect();
        let got_set: HashSet<&str> = got.iter().copied().collect();
        if got_set.len() != got.len() {
            errors.push("a review item appears twice".to_string());
        }
        let mut unknown: Vec<&&str> = got_set.difference(&expected).collect();
        unknown.sort();
        errors.extend(unknown.into_iter().map(|id| format!("unknown review item {id}")));
        for id in &b.items {
            if !got_set.contains(id.as_str()) {
                errors.push(format!("review item {id} missing"));
            }
        }
        for id in &b.items {
            if let Some(r) = reply.review_items.iter().find(|r| &r.id == id) {
                errors.extend(self.validate_item(r, id));
            }
        }
        errors
    }

    pub fn validate_item(&self, r: &ItemReply, item: &str) -> Vec<String> {
        let mut errors = check_text(&r.summary, &format!("summary of {item}"), 200);
        let own: Vec<&str> = self.review_regions(item).iter().map(|g| g.id.as_str()).collect();
        let context: Vec<&str> = self.context_regions(item).iter().map(|g| g.id.as_str()).collect();
        let region_ids: Vec<&str> = r.regions.iter().map(|g| g.id.as_str()).collect();
        if region_ids.iter().collect::<HashSet<_>>().len() != region_ids.len() {
            errors.push(format!("a region of {item} appears twice"));
        }
        for id in &region_ids {
            if !own.contains(id) {
                errors.push(format!("unknown region {id}"));
            }
        }
        for id in &own {
            if !region_ids.contains(id) {
                errors.push(format!("region {id} missing"));
            }
        }
        for g in r.regions.iter().filter(|g| own.contains(&g.id.as_str())) {
            if !(0.0..=1.0).contains(&g.risk) || g.risk.is_nan() {
                errors.push(format!("risk of {} is outside 0...1", g.id));
            }
        }
        let empty = Vec::new();
        let replies = r.context.as_ref().unwrap_or(&empty);
        let context_ids: Vec<&str> = replies.iter().map(|c| c.id.as_str()).collect();
        if context_ids.iter().collect::<HashSet<_>>().len() != context_ids.len() {
            errors.push(format!("a context region of {item} appears twice"));
        }
        for id in &context_ids {
            if !context.contains(id) {
                errors.push(format!("unknown context region {id}"));
            }
        }
        for id in &context {
            if !context_ids.contains(id) {
                errors.push(format!("context region {id} missing"));
            }
        }
        for c in replies.iter().filter(|c| c.keep) {
            if c.rank.unwrap_or(0) < 1 {
                errors.push(format!("kept context region {} needs a rank from 1", c.id));
            }
        }
        errors
    }
}

/// Trims text and numbers kept context regions 1, 2, 3… in the order the LLM ranked them.
pub(crate) fn normalize(mut reply: BatchReply) -> BatchReply {
    if let Some(c) = reply.component.as_mut() {
        c.summary = c.summary.trim().to_string();
    }
    for e in &mut reply.review_items {
        e.summary = e.summary.trim().to_string();
        if let Some(context) = e.context.as_mut() {
            let mut kept: Vec<(usize, i64)> = context.iter().enumerate().filter(|(_, c)| c.keep).map(|(i, c)| (i, c.rank.unwrap_or(0))).collect();
            kept.sort_by_key(|(i, rank)| (*rank, *i));
            for (n, (i, _)) in kept.into_iter().enumerate() {
                context[i].rank = Some(n as i64 + 1);
            }
            for c in context.iter_mut().filter(|c| !c.keep) {
                c.rank = None;
            }
        }
    }
    reply
}

/// Runs one batch, with one retry that names the errors, because a CLI agent sometimes wraps or truncates
/// its reply.
pub(crate) fn run_batch(b: &Batch, prompt: &str, runner: &Runner, builder: &PromptBuilder) -> Outcome<BatchReply> {
    let mut errors: Vec<String> = Vec::new();
    for attempt in 0..2 {
        let p = if attempt == 0 {
            prompt.to_string()
        } else {
            let listed: Vec<&str> = errors.iter().take(10).map(String::as_str).collect();
            format!("{prompt}\n\nYour previous reply was rejected: {}.\nReply again with only the completed JSON object.", listed.join("; "))
        };
        let text = match runner.call(&p) {
            Ok(t) => t,
            Err(CallError::Unavailable(m)) => return Outcome::Unavailable(m),
            Err(CallError::Cancelled) => return Outcome::Cancelled,
            Err(CallError::Failed(m)) => {
                errors = vec![m];
                continue;
            }
        };
        match parse_json::<BatchReply>(&text) {
            Err(e) => errors = vec![e],
            Ok(reply) => {
                errors = builder.validate(&reply, b);
                if errors.is_empty() {
                    return Outcome::Accepted(normalize(reply));
                }
            }
        }
    }
    Outcome::Rejected(errors)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn context(id: &str, keep: bool, rank: Option<i64>) -> ContextReply {
        ContextReply { id: id.to_string(), keep, rank }
    }

    #[test]
    fn numbers_kept_context_from_one_in_the_order_ranked() {
        let reply = BatchReply {
            component: Some(ComponentReply { summary: "  Keeps carts.  ".to_string() }),
            review_items: vec![ItemReply {
                id: "a".to_string(),
                summary: " Adds. ".to_string(),
                regions: vec![],
                context: Some(vec![context("c1", true, Some(7)), context("c2", false, Some(2)), context("c3", true, Some(3)), context("c4", true, Some(3))]),
            }],
        };
        let out = normalize(reply);
        assert_eq!(out.component.unwrap().summary, "Keeps carts.");
        let item = &out.review_items[0];
        assert_eq!(item.summary, "Adds.");
        let ranks: Vec<Option<i64>> = item.context.as_ref().unwrap().iter().map(|c| c.rank).collect();
        // Ties keep the reply's order; a dropped region has no rank.
        assert_eq!(ranks, vec![Some(3), None, Some(1), Some(2)]);
    }
}
