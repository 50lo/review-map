//! The LLM's structural review: one pass over the whole change. Its input is what a CI agent reading the
//! diff doesn't have: the change's description, the edge diff with sample references, the interface diff,
//! usage of the changed code (callers, how many, their isolation, the lines at the call sites), existing
//! declarations with names like the new ones, and the deterministic findings. It asks whether the shape of
//! the change matches its intent, and flags misplaced responsibilities, gaps, duplicates, and complexity the
//! usage data shows isn't needed. Every finding cites its evidence and is anchored to a component, an edge,
//! or a review item that is in the report, so the UI can show it on the map (CORE-005).

use super::batch::{eligible, languages};
use super::cli::{check_text, parse_json, CallError, Runner};
use super::{Outcome, SourceLines};
use crate::model::*;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

pub(crate) const KINDS: [&str; 5] = ["intent", "placement", "missing", "duplicate", "complexity"];
pub(crate) const MAX_FINDINGS: usize = 12;
/// Characters of changed code in the prompt; the riskiest regions go first.
const MAX_CODE_CHARS: usize = 80_000;

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub(crate) struct ReviewFinding {
    pub kind: String,
    pub severity: String,
    pub message: String,
    pub evidence: Vec<String>,
    #[serde(default)]
    pub suggestion: Option<String>,
    pub anchors: Vec<Anchor>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub(crate) struct ReviewReply {
    pub findings: Vec<ReviewFinding>,
}

/// What the change says it does: a pull request's title and body, or its commit messages.
pub(crate) struct Description {
    pub text: String,
    /// "pr" or "commits".
    pub source: &'static str,
}

pub(crate) struct StructuralReview<'a> {
    pub report: &'a ChangeReport,
    pub lines: &'a SourceLines<'a>,
    pub review_notes: Option<&'a str>,
    pub description: Option<&'a Description>,
}

fn component_kind(k: ComponentKind) -> &'static str {
    match k {
        ComponentKind::BazelTarget => "bazelTarget",
        ComponentKind::BazelPackage => "bazelPackage",
        ComponentKind::Folder => "folder",
        ComponentKind::External => "external",
        ComponentKind::NpmPackage => "npmPackage",
        ComponentKind::Tsconfig => "tsconfig",
    }
}

fn edge_status(s: EdgeStatus) -> &'static str {
    match s {
        EdgeStatus::Added => "added",
        EdgeStatus::Removed => "removed",
        EdgeStatus::Changed => "changed",
        EdgeStatus::Unchanged => "unchanged",
    }
}

fn clip(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

impl<'a> StructuralReview<'a> {
    fn names(&self) -> HashMap<&'a str, &'a str> {
        self.report.components.iter().map(|c| (c.id.as_str(), c.name.as_str())).collect()
    }

    fn name(&self, names: &HashMap<&str, &str>, id: &str) -> String {
        names.get(id).map(|n| n.to_string()).unwrap_or_else(|| id.to_string())
    }

    /// The line of a file at one side, trimmed, for showing a reference.
    fn line(&self, side: Side, file: &str, line: u32) -> String {
        if line == 0 {
            return String::new();
        }
        let lines = self.lines.get(side, file);
        lines.get(line as usize - 1).map(|l| clip(l.trim(), 160)).unwrap_or_default()
    }

    /// The prompt, or None when the change has nothing to review: no eligible review item and no changed edge.
    pub fn prompt(&self) -> Option<String> {
        let reviewed = eligible(self.report);
        if reviewed.is_empty() && !self.report.edges.iter().any(|e| e.status != EdgeStatus::Unchanged) {
            return None;
        }
        let mut out = format!(
            "You are reviewing the structure of a {} change, not its lines. CI review agents \
already read the diff. You have what they don't: both sides of the whole repo reduced to a dependency graph, \
the interface diff, and how the changed code is used. Answer:

- Does the shape of the change match its intent (the description below)? (kind \"intent\")
- Do responsibilities sit in the right component, type, or layer? (kind \"placement\")
- What's missing: a caller, a conformer, a test, a migration, an error path the change implies? (kind \"missing\")
- What's duplicated: new code that re-implements an existing declaration or helper (see \"Similar existing \
declarations\")? (kind \"duplicate\")
- What's more complex than the usage shows it needs to be? (kind \"complexity\") In particular:
  - checks that can't fail: nil checks, guards, and validation for states the types or every caller already \
rule out, and catch blocks for errors nothing throws;
  - concurrency protection for impossible scenarios: locks, actors, queues, or atomics around state only one \
isolation domain touches;
  - algorithms and data structures beyond what the input needs: caches, memoization, or indexes for small \
inputs or one-shot calls;
  - abstractions without a second use: protocols with one implementation, generics, factories, and options \
nobody sets;
  - retries, fallbacks, and timeouts for failures that can't happen on that path;
  - re-implementations of helpers the repo already has.

Rules:
- Report only what the facts below support. Every finding cites its evidence from them, such as \"the only \
caller is @MainActor, so this lock guards nothing\" or \"3 callers, all pass a non-nil value\".
- Say what to remove, simplify, move, or add in \"suggestion\".
- Anchor each finding to 1 to 3 things it is about, using ids exactly as listed: {{\"reviewItem\": \"<review item id>\"}}, \
{{\"component\": \"<component id>\"}}, or {{\"from\": \"<component id>\", \"to\": \"<component id>\"}} for a dependency edge.
- Don't repeat the deterministic findings listed below; build on them only when you add something.
- At most {MAX_FINDINGS} findings, most important first. Fewer is better than weak ones; an empty list is fine.
- severity: \"high\" (likely a defect or a design problem that will spread), \"medium\" (worth changing in this PR), \
or \"low\" (worth knowing).
- message: one sentence, at most 200 characters. Each evidence item and the suggestion: one line, at most 300.

Reply with only a JSON object, no prose and no code fences:
{{\"findings\": [{{\"kind\": \"complexity\", \"severity\": \"medium\", \"message\": \"...\", \"evidence\": [\"...\"], \"suggestion\": \"...\", \"anchors\": [{{\"reviewItem\": \"...\"}}]}}]}}
",
            languages(self.report)
        );
        match self.description {
            Some(d) => {
                let source = if d.source == "pr" { "pull request" } else { "commit messages" };
                out.push_str(&format!("\n<description source=\"{source}\">\n{}\n</description>\n", d.text));
            }
            None => out.push_str("\nThe change has no description; judge intent from the change itself.\n"),
        }
        if let Some(notes) = self.review_notes {
            out.push_str(&format!("\n<review-notes>\nThe repository's REVIEW.md, its own notes on what matters:\n{notes}\n</review-notes>\n"));
        }
        let names = self.names();
        out.push_str(&self.components());
        out.push_str(&self.edge_diff(&names));
        out.push_str(&self.interface_diff(&reviewed));
        out.push_str(&self.usage(&reviewed, &names));
        out.push_str(&self.similar(&reviewed, &names));
        out.push_str(&self.checks());
        out.push_str(&self.code(&reviewed));
        Some(out)
    }

    fn components(&self) -> String {
        let r = self.report;
        let touches = |c: &Component| r.edges.iter().any(|e| e.status != EdgeStatus::Unchanged && (e.from == c.id || e.to == c.id));
        let mut changed: Vec<&Component> = r
            .components
            .iter()
            .filter(|c| c.kind != ComponentKind::External && (c.changed_review_items > 0 || c.status.is_some() || touches(c)))
            .collect();
        if changed.is_empty() {
            return String::new();
        }
        changed.sort_by(|a, b| b.change_score.partial_cmp(&a.change_score).unwrap_or(std::cmp::Ordering::Equal));
        let names = self.names();
        let mut out = "\n## Components\n".to_string();
        for c in changed {
            let mut facts = vec![component_kind(c.kind).to_string()];
            if let Some(l) = &c.layer {
                facts.push(format!("layer {l}"));
            }
            if c.is_test {
                facts.push("tests".to_string());
            }
            if let Some(p) = &c.parent {
                facts.push(format!("part of {}", self.name(&names, p)));
            }
            if let Some(s) = &c.status {
                facts.push(s.clone());
            }
            facts.push(format!("{} changed review items", c.changed_review_items));
            out.push_str(&format!("- {} \"{}\": {}\n", c.id, c.name, facts.join(", ")));
        }
        out
    }

    fn edge_diff(&self, names: &HashMap<&str, &str>) -> String {
        let changed: Vec<&Edge> = self.report.edges.iter().filter(|e| e.status != EdgeStatus::Unchanged).collect();
        if changed.is_empty() {
            return String::new();
        }
        let mut out = "\n## Dependency edges that changed (from uses to)\n".to_string();
        for e in changed.iter().take(80) {
            out.push_str(&format!("- {} → {} ({} → {}): {}", e.from, e.to, self.name(names, &e.from), self.name(names, &e.to), edge_status(e.status)));
            if !e.symbols_added.is_empty() {
                out.push_str(&format!(", now uses {}", e.symbols_added.iter().take(10).cloned().collect::<Vec<_>>().join(", ")));
            }
            if !e.symbols_removed.is_empty() {
                out.push_str(&format!(", no longer uses {}", e.symbols_removed.iter().take(10).cloned().collect::<Vec<_>>().join(", ")));
            }
            out.push_str(&format!(", {} refs\n", e.ref_count));
            for r in e.refs.iter().take(3) {
                if r.line == 0 {
                    out.push_str(&format!("    {} (BUILD file): {}\n", r.file, r.symbol));
                    continue;
                }
                let base = if r.side == Side::Base { "base " } else { "" };
                out.push_str(&format!("    {base}{}:{}: {}\n", r.file, r.line, self.line(r.side, &r.file, r.line)));
            }
        }
        if changed.len() > 80 {
            out.push_str(&format!("- and {} more\n", changed.len() - 80));
        }
        out
    }

    fn interface_diff(&self, reviewed: &[&ReviewItem]) -> String {
        let iface: Vec<&&ReviewItem> = reviewed.iter().filter(|e| e.is_interface).collect();
        if iface.is_empty() {
            return String::new();
        }
        let mut out = "\n## Interface diff\n".to_string();
        for e in iface.iter().take(120) {
            let changes: Vec<&str> = e.changes.iter().map(|c| c.raw()).collect();
            out.push_str(&format!("- {}: {}, {}", e.id, e.kind.raw(), changes.join(", ")));
            if !e.contract_flags.is_empty() {
                out.push_str(&format!(", flags {}", e.contract_flags.join(", ")));
            }
            out.push('\n');
            if let Some(b) = e.signature.base.as_ref().filter(|b| Some(*b) != e.signature.head.as_ref()) {
                out.push_str(&format!("    base: {}\n", b.replace('\n', " ")));
            }
            if let Some(h) = &e.signature.head {
                out.push_str(&format!("    head: {}\n", h.replace('\n', " ")));
            }
        }
        if iface.len() > 120 {
            out.push_str(&format!("- and {} more\n", iface.len() - 120));
        }
        out
    }

    fn usage(&self, reviewed: &[&ReviewItem], names: &HashMap<&str, &str>) -> String {
        // Callers at head only; uses that exist only at base are callers the change removed.
        fn head_uses(e: &ReviewItem) -> Vec<&Usage> {
            e.used_by.iter().filter(|u| u.side != Some(Side::Base)).collect()
        }
        let used: Vec<&&ReviewItem> = reviewed.iter().filter(|e| !head_uses(e).is_empty() || !e.depends_on.is_empty()).collect();
        let internal_only: Vec<&&ReviewItem> = reviewed.iter().filter(|e| head_uses(e).is_empty() && !e.is_interface).collect();
        let mut out = "\n## Usage of the changed review items\n".to_string();
        out.push_str("Used by lists callers in other components at head, with the isolation the call runs in when known.\n");
        for e in used.iter().take(100) {
            out.push_str(&format!("- {}", e.id));
            let uses = head_uses(e);
            if !uses.is_empty() {
                let comps: BTreeSet<&str> = uses.iter().map(|u| u.component.as_str()).collect();
                let comps: Vec<String> = comps.into_iter().map(|c| self.name(names, c)).collect();
                let mut by_isolation: BTreeMap<&str, usize> = BTreeMap::new();
                for u in &uses {
                    *by_isolation.entry(u.isolation.as_deref().unwrap_or("unknown isolation")).or_default() += 1;
                }
                let mut iso: Vec<String> = by_isolation.into_iter().map(|(k, n)| format!("{n} {k}")).collect();
                iso.sort();
                out.push_str(&format!(": used by {} in {} ({})\n", uses.len(), comps.join(", "), iso.join(", ")));
                for u in uses.iter().take(4) {
                    out.push_str(&format!("    {} at {}:{}: {}\n", u.symbol, u.file, u.line, self.line(Side::Head, &u.file, u.line)));
                }
            } else {
                out.push_str(": no callers in other components\n");
            }
            let removed: Vec<&Usage> = e.used_by.iter().filter(|u| u.side == Some(Side::Base)).collect();
            if !removed.is_empty() {
                let listed: Vec<String> = removed.iter().take(4).map(|u| format!("{} ({})", u.symbol, self.name(names, &u.component))).collect();
                out.push_str(&format!("    callers the change removed: {}\n", listed.join(", ")));
            }
            if !e.depends_on.is_empty() {
                let deps: BTreeSet<String> = e.depends_on.iter().map(|u| format!("{} ({})", u.symbol, self.name(names, &u.component))).collect();
                out.push_str(&format!("    depends on {}\n", deps.into_iter().take(10).collect::<Vec<_>>().join(", ")));
            }
        }
        if !internal_only.is_empty() {
            let listed: Vec<&str> = internal_only.iter().take(60).map(|e| e.qualified_name.as_str()).collect();
            out.push_str(&format!("No callers in other components: {}{}\n", listed.join(", "), if internal_only.len() > 60 { ", …" } else { "" }));
        }
        out
    }

    fn similar(&self, reviewed: &[&ReviewItem], names: &HashMap<&str, &str>) -> String {
        let items: Vec<&&ReviewItem> = reviewed.iter().filter(|e| e.similar.as_ref().map(|s| !s.is_empty()).unwrap_or(false)).collect();
        if items.is_empty() {
            return String::new();
        }
        let mut out = "\n## Similar existing declarations (for added review items)\n".to_string();
        for e in items.iter().take(60) {
            let listed: Vec<String> = e
                .similar
                .as_deref()
                .unwrap_or(&[])
                .iter()
                .map(|s| format!("{} in {} ({}:{})", s.symbol, self.name(names, &s.component), s.file, s.line))
                .collect();
            out.push_str(&format!("- {} resembles {}\n", e.id, listed.join("; ")));
        }
        out
    }

    fn checks(&self) -> String {
        let found: Vec<&Finding> = self.report.findings.iter().filter(|f| f.source == "check").collect();
        if found.is_empty() {
            return "\n## Deterministic findings\nNone.\n".to_string();
        }
        let mut out = "\n## Deterministic findings (already reported)\n".to_string();
        for f in found.iter().take(60) {
            out.push_str(&format!("- {}: {}\n", f.kind, f.message));
        }
        out
    }

    /// The changed code itself, riskiest regions first, with a little context, until the budget runs out.
    fn code(&self, reviewed: &[&ReviewItem]) -> String {
        let ids: HashSet<&str> = reviewed.iter().map(|e| e.id.as_str()).collect();
        let mut regions: Vec<&Region> = self.report.regions.iter().filter(|r| r.kind != "context" && ids.contains(r.review_item.as_str())).collect();
        if regions.is_empty() {
            return String::new();
        }
        regions.sort_by(|a, b| b.risk.partial_cmp(&a.risk).unwrap_or(std::cmp::Ordering::Equal).then_with(|| a.id.cmp(&b.id)));
        let mut out = "\n## Changed code, riskiest first\n".to_string();
        let mut used = 0usize;
        let mut left = 0usize;
        for r in regions {
            let lines = self.lines.get(r.side, &r.file);
            let lo = r.start_line.saturating_sub(2).max(1);
            let hi = (lines.len() as u32).min(r.end_line + 2).min(r.start_line + 80);
            if lo > hi {
                continue;
            }
            let side = if r.kind == "removed" { "removed from base" } else { "head" };
            let mut block = format!("\n### {} ({side}, {}:{}-{})\n", r.review_item, r.file, r.start_line, r.end_line);
            for n in lo..=hi {
                block.push_str(&format!("    {n}| {}\n", lines[n as usize - 1]));
            }
            let size = block.chars().count();
            if used + size > MAX_CODE_CHARS {
                left += 1;
                continue;
            }
            out.push_str(&block);
            used += size;
        }
        if left > 0 {
            out.push_str(&format!("\n({left} lower-risk regions left out.)\n"));
        }
        out
    }

    // MARK: Run and validate

    pub fn run(&self, prompt: &str, runner: &Runner) -> Outcome<ReviewReply> {
        let mut errors: Vec<String> = Vec::new();
        for attempt in 0..2 {
            let p = if attempt == 0 {
                prompt.to_string()
            } else {
                let listed: Vec<&str> = errors.iter().take(10).map(String::as_str).collect();
                format!("{prompt}\n\nYour previous reply was rejected: {}.\nReply again with only the corrected JSON object.", listed.join("; "))
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
            match parse_json::<ReviewReply>(&text) {
                Err(e) => errors = vec![e],
                Ok(reply) => {
                    errors = self.validate(&reply);
                    if errors.is_empty() {
                        return Outcome::Accepted(normalize(reply));
                    }
                }
            }
        }
        Outcome::Rejected(errors)
    }

    pub fn validate(&self, reply: &ReviewReply) -> Vec<String> {
        let mut errors = Vec::new();
        if reply.findings.len() > MAX_FINDINGS + 3 {
            errors.push(format!("more than {MAX_FINDINGS} findings"));
        }
        let components: HashSet<&str> = self.report.components.iter().map(|c| c.id.as_str()).collect();
        let items: HashSet<&str> = self.report.review_items.iter().map(|e| e.id.as_str()).collect();
        let edges: HashSet<(&str, &str)> = self.report.edges.iter().map(|e| (e.from.as_str(), e.to.as_str())).collect();
        for (i, f) in reply.findings.iter().enumerate() {
            let at = format!("finding {}", i + 1);
            if !KINDS.contains(&f.kind.as_str()) {
                errors.push(format!("kind of {at} must be one of {}", KINDS.join(", ")));
            }
            if !["high", "medium", "low"].contains(&f.severity.as_str()) {
                errors.push(format!("severity of {at} must be high, medium, or low"));
            }
            errors.extend(check_text(&f.message, &format!("message of {at}"), 300));
            if f.evidence.is_empty() {
                errors.push(format!("{at} cites no evidence"));
            }
            for (j, ev) in f.evidence.iter().take(8).enumerate() {
                errors.extend(check_text(ev, &format!("evidence {} of {at}", j + 1), 400));
            }
            if let Some(s) = f.suggestion.as_ref().filter(|s| !s.trim().is_empty()) {
                errors.extend(check_text(s, &format!("suggestion of {at}"), 400));
            }
            if f.anchors.is_empty() {
                errors.push(format!("{at} has no anchor"));
            }
            for a in &f.anchors {
                if let Some(id) = &a.review_item {
                    if !items.contains(id.as_str()) {
                        errors.push(format!("unknown review item {id} in {at}"));
                    }
                } else if let Some(id) = &a.component {
                    if !components.contains(id.as_str()) {
                        errors.push(format!("unknown component {id} in {at}"));
                    }
                } else if let (Some(from), Some(to)) = (&a.from, &a.to) {
                    if !edges.contains(&(from.as_str(), to.as_str())) {
                        errors.push(format!("no edge {from} → {to} in {at}"));
                    }
                } else {
                    errors.push(format!("an anchor of {at} names no review item, component, or edge"));
                }
            }
        }
        errors
    }
}

/// Keeps at most the allowed findings, evidence, and anchors, with trimmed text.
pub(crate) fn normalize(reply: ReviewReply) -> ReviewReply {
    ReviewReply {
        findings: reply
            .findings
            .into_iter()
            .take(MAX_FINDINGS)
            .map(|f| {
                let suggestion = f.suggestion.map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
                ReviewFinding {
                    kind: f.kind,
                    severity: f.severity,
                    message: f.message.trim().to_string(),
                    evidence: f.evidence.into_iter().take(8).map(|e| e.trim().to_string()).collect(),
                    suggestion,
                    anchors: f.anchors.into_iter().take(4).collect(),
                }
            })
            .collect(),
    }
}

/// The report's findings for a reply: "<kind>:<n>" ids, source "llm".
pub(crate) fn findings(reply: &ReviewReply) -> Vec<Finding> {
    let mut counts: HashMap<&str, usize> = HashMap::new();
    reply
        .findings
        .iter()
        .map(|f| {
            let n = counts.entry(f.kind.as_str()).or_default();
            *n += 1;
            Finding {
                id: format!("{}:{}", f.kind, n),
                source: "llm".to_string(),
                kind: f.kind.clone(),
                severity: f.severity.clone(),
                message: f.message.clone(),
                evidence: f.evidence.clone(),
                suggestion: f.suggestion.clone(),
                anchors: f.anchors.clone(),
                location: None,
            }
        })
        .collect()
}
