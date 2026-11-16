//! The optional LLM pass, ported from the prototype (`Sources/ReviewMapCore/Annotator.swift` and
//! `StructuralReview.swift`). It only annotates facts the analysis produced: it re-ranks review and removed
//! regions, keeps and ranks context regions, and writes one-line summaries of components and changed review
//! items, in one batch or more per component (`batch`). Then one structural review of the whole change looks
//! at its shape (`review`). Both run a coding-agent CLI (`claude -p` or `codex exec`, see `cli`), validate
//! every reply strictly against the report, and cache accepted results in the app's cache
//! (`<cache root>/llm`), keyed by everything that shaped them: the prompt, tool, command, model, and REVIEW.md.
//!
//! CORE-004: the deterministic report never depends on the LLM. A reply that fails validation, or a call
//! that fails, is dropped: the deterministic scores and findings stay, and the report says so with an
//! `llm-rejected` warning (and `llm.failed`, or `llm.review: "rejected"`). When the CLI can't run at all, the
//! report is the one without the LLM plus an `llm-unavailable` warning.
//!
//! Nothing here picks an LLM by itself: the pass runs only when a caller passes `LlmOptions`
//! (`ReviewRequest.llm`). Tests use `scripts/fake-llm.sh` as the command; they never run a real agent.

mod batch;
mod cli;
mod review;

use crate::model::*;
use crate::proc::{Cancel, Cancelled};
use anyhow::{anyhow, Result};
use batch::{Batch, BatchReply, ItemReply, PromptBuilder};
use review::{Description, ReviewReply, StructuralReview};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Bump when the prompt or the reply format changes, so cached results are not reused.
pub const PROMPT_VERSION: &str = "3";

fn default_tool() -> String {
    "claude".to_string()
}
fn default_jobs() -> usize {
    4
}
fn default_timeout() -> u64 {
    300
}
fn default_batch_chars() -> usize {
    60_000
}
fn default_true() -> bool {
    true
}

/// How to run the LLM pass. In JSON (a review request, the app's settings) the fields are camelCase and
/// all but `tool` may be left out.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LlmOptions {
    /// "claude" or "codex".
    #[serde(default = "default_tool")]
    pub tool: String,
    /// An executable to run instead of the tool, with the tool's arguments: a path, or a name looked up like
    /// the other tools. Tests pass `scripts/fake-llm.sh`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<PathBuf>,
    /// The model the CLI uses. None uses the CLI's default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Calls that run at the same time.
    #[serde(default = "default_jobs")]
    pub jobs: usize,
    /// Seconds before a call is stopped.
    #[serde(default = "default_timeout")]
    pub timeout_secs: u64,
    /// Characters of review item material per batch.
    #[serde(default = "default_batch_chars")]
    pub max_batch_chars: usize,
    /// Whether to run the structural review of the whole change.
    #[serde(default = "default_true")]
    pub structural_review: bool,
    /// Whether to ask `gh` for the pull request of the head branch, for the change's description. Without
    /// one, the description is the commit messages.
    #[serde(default = "default_true")]
    pub pull_request: bool,
}

impl Default for LlmOptions {
    fn default() -> LlmOptions {
        LlmOptions {
            tool: default_tool(),
            command: None,
            model: None,
            jobs: default_jobs(),
            timeout_secs: default_timeout(),
            max_batch_chars: default_batch_chars(),
            structural_review: true,
            pull_request: true,
        }
    }
}

/// What the pass reads besides the report: file contents at each side, and the commit messages of the change.
/// Both come from the commits, never from the working tree (CORE-002).
pub trait Sources: Sync {
    fn text(&self, side: Side, file: &str) -> Option<String>;
    /// The messages of the commits in base..head, newest first.
    fn commit_messages(&self) -> Vec<String>;
}

impl Sources for crate::session::Session {
    fn text(&self, side: Side, file: &str) -> Option<String> {
        self.read_source(side, file)
    }

    fn commit_messages(&self) -> Vec<String> {
        match (self.repo.resolve(&self.info.base_sha), self.repo.resolve(&self.info.head_sha)) {
            (Ok(base), Ok(head)) => self.repo.commit_messages(base, head, 50),
            _ => Vec::new(),
        }
    }
}

/// File lines by side and path, read once.
pub(crate) struct SourceLines<'a> {
    sources: &'a dyn Sources,
    cache: Mutex<HashMap<(Side, String), Arc<Vec<String>>>>,
}

impl<'a> SourceLines<'a> {
    fn new(sources: &'a dyn Sources) -> SourceLines<'a> {
        SourceLines { sources, cache: Mutex::new(HashMap::new()) }
    }

    pub fn get(&self, side: Side, file: &str) -> Arc<Vec<String>> {
        let key = (side, file.to_string());
        if let Some(hit) = self.cache.lock().unwrap().get(&key) {
            return hit.clone();
        }
        let lines: Arc<Vec<String>> = Arc::new(self.sources.text(side, file).map(|t| t.split('\n').map(str::to_string).collect()).unwrap_or_default());
        self.cache.lock().unwrap().insert(key, lines.clone());
        lines
    }
}

/// How one call went.
pub(crate) enum Outcome<T> {
    Accepted(T),
    Rejected(Vec<String>),
    Unavailable(String),
    Cancelled,
}

/// Accepted results under `<dir>/<key>.json`: one file per review item, one per component summary, and one
/// per structural review.
struct Cache {
    dir: PathBuf,
}

impl Cache {
    fn path(&self, key: &str) -> PathBuf {
        self.dir.join(format!("{key}.json"))
    }

    fn read<T: serde::de::DeserializeOwned>(&self, key: &str) -> Option<T> {
        std::fs::read(self.path(key)).ok().and_then(|d| serde_json::from_slice(&d).ok())
    }

    /// Writes and renames, so a concurrent run never reads half a file.
    fn write<T: Serialize>(&self, key: &str, value: &T) {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let Ok(data) = serde_json::to_vec(value) else { return };
        let tmp = self.dir.join(format!("{key}.{}-{}.tmp", std::process::id(), NEXT.fetch_add(1, Ordering::SeqCst)));
        if std::fs::write(&tmp, data).is_ok() && std::fs::rename(&tmp, self.path(key)).is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
    }
}

const DESCRIPTION_CHARS: usize = 8_000;
const REVIEW_NOTES_CHARS: usize = 20_000;

/// The change's description: the pull request of the head branch (from `gh`), else the commit messages.
fn describe(report: &ChangeReport, sources: &dyn Sources, options: &LlmOptions, cancel: &Cancel) -> Option<Description> {
    let head = &report.repo.head;
    // gh knows the pull request of a branch; a detached head or a sha has none.
    if options.pull_request && !head.is_empty() && head != "HEAD" && *head != report.repo.head_sha {
        if let Some(gh) = crate::tools::find("gh", None) {
            let args: Vec<String> = ["pr", "view", head, "--json", "title,body"].iter().map(|s| s.to_string()).collect();
            if let Ok(out) = cli::run(&gh, &args, b"", Path::new(&report.repo.root), Duration::from_secs(20), cancel) {
                if out.status.map(|s| s.success()).unwrap_or(false) && !out.timed_out {
                    if let Ok(serde_json::Value::Object(obj)) = serde_json::from_slice::<serde_json::Value>(&out.stdout) {
                        if let Some(title) = obj.get("title").and_then(|t| t.as_str()) {
                            let body = obj.get("body").and_then(|b| b.as_str()).unwrap_or("");
                            let text: String = format!("{title}\n\n{body}").chars().take(DESCRIPTION_CHARS).collect();
                            return Some(Description { text, source: "pr" });
                        }
                    }
                }
            }
        }
    }
    let text = sources.commit_messages().join("\n\n");
    let text = text.trim();
    (!text.is_empty()).then(|| Description { text: text.chars().take(DESCRIPTION_CHARS).collect(), source: "commits" })
}

/// One unit of work for the pool: an annotation batch or the structural review.
enum Job {
    Batch(usize),
    Review,
}

/// The LLM pass over a final report.
pub struct Annotator<'a> {
    pub options: &'a LlmOptions,
}

impl<'a> Annotator<'a> {
    /// The report with the LLM's annotations and findings, or the same report with a warning when the LLM
    /// couldn't run or its replies were rejected (CORE-004). Fails only when the job is cancelled.
    pub fn run(&self, report: &ChangeReport, sources: &dyn Sources, cancel: &Cancel, progress: &(dyn Fn(String) + Sync)) -> Result<ChangeReport> {
        let options = self.options;
        let unavailable = |message: String| {
            progress(message.clone());
            let mut out = report.clone();
            out.warnings.push(Warning::new("llm-unavailable", message));
            Ok(out)
        };
        if options.tool != "claude" && options.tool != "codex" {
            return unavailable(format!("Unknown LLM tool {}. Use claude or codex. The LLM pass was skipped.", options.tool));
        }
        // The app's own cache, never a place a request names, so it is never inside the reviewed repository (CORE-002).
        let cache_dir = crate::store::cache_root().join("llm");
        if let Err(e) = std::fs::create_dir_all(&cache_dir) {
            return unavailable(format!("Could not make the LLM cache directory {}: {e}. The LLM pass was skipped.", cache_dir.display()));
        }
        let cache = Cache { dir: cache_dir };

        let lines = SourceLines::new(sources);
        let review_notes: Option<String> = sources.text(Side::Head, "REVIEW.md").map(|t| t.chars().take(REVIEW_NOTES_CHARS).collect());
        let builder = PromptBuilder::new(report, &lines, review_notes.as_deref());
        // Everything that shapes a reply besides the prompt. A command run in place of the tool may be another
        // agent, so its replies are kept apart from the tool's and from other commands'.
        let command = options.command.as_ref().map(|c| c.to_string_lossy().to_string()).unwrap_or_default();
        let fingerprint = [PROMPT_VERSION, &options.tool, &command, options.model.as_deref().unwrap_or(""), review_notes.as_deref().unwrap_or("")].join("\u{1}");

        // The batches, after taking what the cache has.
        let mut batches: Vec<Batch> = Vec::new();
        let mut item_replies: BTreeMap<String, ItemReply> = BTreeMap::new();
        let mut component_summaries: BTreeMap<String, String> = BTreeMap::new();
        let mut cached_batches = 0usize;
        for comp in report.components.iter().filter(|c| c.kind != ComponentKind::External && !c.is_test) {
            let items = builder.items_of(&comp.id);
            if items.is_empty() {
                continue;
            }
            let blocks: Vec<(String, String)> = items.iter().map(|e| (e.id.clone(), builder.item_block(e))).collect();
            let keys: HashMap<String, String> = blocks.iter().map(|(id, block)| (id.clone(), crate::store::digest([fingerprint.as_str(), "\u{2}", block.as_str()]))).collect();
            let mut key_parts: Vec<&str> = vec![fingerprint.as_str(), "\u{3}"];
            let header = builder.component_header(comp);
            key_parts.push(&header);
            for (id, _) in &blocks {
                key_parts.push(&keys[id]);
            }
            let component_key = crate::store::digest(key_parts);
            let mut misses: Vec<(String, String)> = Vec::new();
            for (id, block) in &blocks {
                match cache.read::<ItemReply>(&keys[id]).filter(|hit| builder.validate_item(hit, id).is_empty()) {
                    Some(hit) => {
                        item_replies.insert(id.clone(), hit);
                    }
                    None => misses.push((id.clone(), block.clone())),
                }
            }
            let summary = cache.read::<batch::ComponentReply>(&component_key).map(|c| c.summary);
            if let Some(s) = &summary {
                component_summaries.insert(comp.id.clone(), s.clone());
            }
            if misses.is_empty() && summary.is_some() {
                cached_batches += 1;
                continue;
            }
            // Large components are split into batches of whole review items. The first batch also asks for
            // the component's summary.
            let mut chunks: Vec<Vec<(String, String)>> = Vec::new();
            let mut chunk: Vec<(String, String)> = Vec::new();
            let mut size = 0usize;
            for m in misses {
                if !chunk.is_empty() && size + m.1.chars().count() > options.max_batch_chars {
                    chunks.push(std::mem::take(&mut chunk));
                    size = 0;
                }
                size += m.1.chars().count();
                chunk.push(m);
            }
            if !chunk.is_empty() || chunks.is_empty() {
                chunks.push(chunk);
            }
            let parts = chunks.len();
            for (i, c) in chunks.into_iter().enumerate() {
                batches.push(Batch {
                    component: comp.id.clone(),
                    name: comp.name.clone(),
                    items: c.iter().map(|(id, _)| id.clone()).collect(),
                    blocks: c.into_iter().map(|(_, block)| block).collect(),
                    wants_summary: i == 0 && summary.is_none(),
                    part: i + 1,
                    parts,
                    item_keys: keys.clone(),
                    component_key: component_key.clone(),
                });
            }
        }

        // The structural review of the whole change, unless its reply for the same prompt is cached.
        let description = if options.structural_review { describe(report, sources, options, cancel) } else { None };
        let review = options.structural_review.then(|| StructuralReview { report, lines: &lines, review_notes: review_notes.as_deref(), description: description.as_ref() });
        let review_prompt = review.as_ref().and_then(|r| r.prompt());
        let review_key = review_prompt.as_ref().map(|p| format!("review-{}", crate::store::digest([fingerprint.as_str(), "\u{4}", p.as_str()])));
        let cached_review: Option<ReviewReply> = match (&review, &review_key) {
            (Some(r), Some(key)) => cache.read::<ReviewReply>(key).filter(|reply| r.validate(reply).is_empty()),
            _ => None,
        };

        let model = options.model.as_deref().map(|m| format!(" ({m})")).unwrap_or_default();
        progress(format!(
            "LLM: {} batch{} to run with {}{model}, {cached_batches} component{} from the cache",
            batches.len(),
            if batches.len() == 1 { "" } else { "es" },
            options.tool,
            if cached_batches == 1 { "" } else { "s" }
        ));

        // Every call, on `jobs` threads. The first call that finds the CLI unusable stops the others.
        let mut jobs: Vec<Job> = (0..batches.len()).map(Job::Batch).collect();
        if review_prompt.is_some() && cached_review.is_none() {
            jobs.push(Job::Review);
        }
        let runner = cli::Runner::new(options, cancel);
        let next = AtomicUsize::new(0);
        let stop = AtomicBool::new(false);
        let batch_results: Mutex<Vec<Option<Outcome<BatchReply>>>> = Mutex::new((0..batches.len()).map(|_| None).collect());
        let review_result: Mutex<Option<Outcome<ReviewReply>>> = Mutex::new(None);
        let unavailable_message: Mutex<Option<String>> = Mutex::new(None);
        let workers = options.jobs.max(1).min(jobs.len().max(1));
        std::thread::scope(|scope| {
            for _ in 0..workers {
                scope.spawn(|| loop {
                    let i = next.fetch_add(1, Ordering::SeqCst);
                    if i >= jobs.len() || stop.load(Ordering::SeqCst) || cancel.is_cancelled() {
                        return;
                    }
                    match &jobs[i] {
                        Job::Batch(b) => {
                            let batch = &batches[*b];
                            let outcome = batch::run_batch(batch, &builder.prompt(batch), &runner, &builder);
                            match &outcome {
                                Outcome::Accepted(reply) => {
                                    for e in &reply.review_items {
                                        if let Some(key) = batch.item_keys.get(&e.id) {
                                            cache.write(key, e);
                                        }
                                    }
                                    if let Some(c) = &reply.component {
                                        cache.write(&batch.component_key, c);
                                    }
                                    progress(format!("LLM: {}: ok", batch.label()));
                                }
                                Outcome::Rejected(errors) => {
                                    let listed: Vec<&str> = errors.iter().take(3).map(String::as_str).collect();
                                    progress(format!("LLM: {}: rejected, deterministic scores kept ({})", batch.label(), listed.join("; ")));
                                }
                                Outcome::Unavailable(m) => {
                                    stop.store(true, Ordering::SeqCst);
                                    unavailable_message.lock().unwrap().get_or_insert(m.clone());
                                }
                                Outcome::Cancelled => {}
                            }
                            batch_results.lock().unwrap()[*b] = Some(outcome);
                        }
                        Job::Review => {
                            let (Some(r), Some(prompt)) = (&review, &review_prompt) else { continue };
                            progress("LLM: structural review of the whole change".to_string());
                            let outcome = r.run(prompt, &runner);
                            match &outcome {
                                Outcome::Accepted(reply) => {
                                    if let Some(key) = &review_key {
                                        cache.write(key, reply);
                                    }
                                    let n = reply.findings.len();
                                    progress(format!("LLM: structural review: {n} finding{}", if n == 1 { "" } else { "s" }));
                                }
                                Outcome::Rejected(errors) => {
                                    let listed: Vec<&str> = errors.iter().take(3).map(String::as_str).collect();
                                    progress(format!("LLM: structural review: rejected ({})", listed.join("; ")));
                                }
                                Outcome::Unavailable(m) => {
                                    stop.store(true, Ordering::SeqCst);
                                    unavailable_message.lock().unwrap().get_or_insert(m.clone());
                                }
                                Outcome::Cancelled => {}
                            }
                            *review_result.lock().unwrap() = Some(outcome);
                        }
                    }
                });
            }
        });
        if cancel.is_cancelled() {
            return Err(anyhow!(Cancelled));
        }

        let mut out = report.clone();
        let mut failed = 0usize;
        for (i, outcome) in batch_results.into_inner().unwrap().into_iter().enumerate() {
            let b = &batches[i];
            match outcome {
                Some(Outcome::Accepted(reply)) => {
                    for e in reply.review_items {
                        item_replies.insert(e.id.clone(), e);
                    }
                    if let Some(c) = reply.component {
                        component_summaries.insert(b.component.clone(), c.summary);
                    }
                }
                Some(Outcome::Rejected(errors)) => {
                    failed += 1;
                    let listed: Vec<&str> = errors.iter().take(5).map(String::as_str).collect();
                    out.warnings.push(Warning::new(
                        "llm-rejected",
                        format!("LLM reply for {} failed validation, deterministic scores kept: {}", b.label(), listed.join("; ")),
                    ));
                }
                _ => {}
            }
        }
        let mut review_status: Option<String> = review.as_ref().map(|_| "skipped".to_string());
        let mut review_reply = cached_review.clone();
        if cached_review.is_some() {
            review_status = Some("cached".to_string());
        }
        match review_result.into_inner().unwrap() {
            Some(Outcome::Accepted(reply)) => {
                review_reply = Some(reply);
                review_status = Some("ok".to_string());
            }
            Some(Outcome::Rejected(errors)) => {
                review_status = Some("rejected".to_string());
                let listed: Vec<&str> = errors.iter().take(5).map(String::as_str).collect();
                out.warnings.push(Warning::new("llm-rejected", format!("LLM structural review failed validation: {}", listed.join("; "))));
            }
            _ => {}
        }
        if let Some(message) = unavailable_message.into_inner().unwrap() {
            progress(message.clone());
            out.warnings.push(Warning::new("llm-unavailable", message));
            if item_replies.is_empty() && review_reply.is_none() {
                return Ok(out);
            }
        }
        apply(&mut out, &item_replies, &component_summaries);
        out.findings.retain(|f| f.source != "llm");
        if let Some(reply) = &review_reply {
            out.findings.extend(review::findings(reply));
        }
        out.llm = Some(LlmRun {
            tool: options.tool.clone(),
            model: options.model.clone(),
            command: options.command.as_ref().and_then(|c| c.file_name()).map(|n| n.to_string_lossy().to_string()),
            prompt_version: PROMPT_VERSION.to_string(),
            batches: batches.len() + cached_batches,
            cached: cached_batches,
            failed,
            review_notes: review_notes.is_some(),
            review: review_status,
            description: description.map(|d| d.source.to_string()),
        });
        progress(format!(
            "LLM: {} review item{} annotated, {failed} batch{} rejected",
            item_replies.len(),
            if item_replies.len() == 1 { "" } else { "s" },
            if failed == 1 { "" } else { "es" }
        ));
        Ok(out)
    }
}

/// Puts accepted replies on the report. Regions without a reply keep only their deterministic risk.
fn apply(report: &mut ChangeReport, items: &BTreeMap<String, ItemReply>, components: &BTreeMap<String, String>) {
    let mut region_risk: HashMap<&str, f64> = HashMap::new();
    let mut context: HashMap<&str, (bool, Option<i64>)> = HashMap::new();
    for e in items.values() {
        for g in &e.regions {
            region_risk.insert(g.id.as_str(), g.risk);
        }
        for c in e.context.as_deref().unwrap_or(&[]) {
            context.insert(c.id.as_str(), (c.keep, c.rank));
        }
    }
    for c in &mut report.components {
        c.llm = components.get(&c.id).map(|s| LlmSummary { summary: s.clone() });
    }
    for e in &mut report.review_items {
        e.llm = items.get(&e.id).map(|r| LlmSummary { summary: r.summary.clone() });
    }
    for r in &mut report.regions {
        r.llm = if let Some(risk) = region_risk.get(r.id.as_str()) {
            Some(RegionLlm { risk: Some((risk * 100.0).round() / 100.0), ..Default::default() })
        } else {
            context.get(r.id.as_str()).map(|(keep, rank)| RegionLlm { risk: None, keep: Some(*keep), rank: rank.map(|n| n as u32) })
        };
    }
}
