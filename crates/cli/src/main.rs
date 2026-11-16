//! `reviewmap`: opens or focuses the Review Map app and passes it the repository, the refs, and the
//! directory it was run from.
//!
//!     reviewmap [repo] [--base main] [--head <branch>] [--no-merge-base]
//!               [--target //app:App]... [--bazel-arg --config=sim]... [--no-index]
//!               [--llm claude|codex] [--llm-command <path>] [--llm-model <name>] [--no-llm]
//!
//! With `--report <file>` (or `-` for stdout) it analyzes in this process instead and writes the final
//! change report as JSON. That is a diagnostic for development and tests, not a product feature.

use anyhow::{anyhow, bail, Result};
use reviewmap_core::llm::LlmOptions;
use reviewmap_core::proc::Cancel;
use reviewmap_core::session::{self, Event, ReviewRequest};
use std::path::PathBuf;

const HELP: &str = "reviewmap: open the Review Map app on a change.

Usage: reviewmap [repo] [options]

  [repo]               The repository, or any directory inside it (default: the current directory).
  --base <ref>         Base ref: a branch, tag, or sha (default: main).
  --head <ref>         Head ref (default: the branch checked out in the repository).
  --no-merge-base      Compare against the base itself instead of the merge-base of base and head.
  --target <label>     A Bazel target that defines the review scope; repeat for several
                       (default: index.targets in reviewmap.yml, else rules_xcodeproj's top_level_targets).
  --bazel-arg <arg>    An extra argument for Bazel queries and builds, such as --config=sim; repeat for several.
  --no-index           Don't build indexes: only links that syntax proves are shown.
  --llm <tool>         Run the LLM pass with claude or codex (default: the app's settings, where it is off
                       unless turned on).
  --llm-command <path> Run this executable instead of the LLM tool, such as scripts/fake-llm.sh.
  --llm-model <name>   The model the LLM tool uses.
  --no-llm             Don't run the LLM pass, whatever the settings say.
  --report <file>      Analyze here instead of opening the app, and write the final change report (- for stdout).
  --name-based         With --report: write the comparison report that matches every reference by name.
  -h, --help           Show this help.
  -V, --version        Show the version.
";

struct Args {
    request: ReviewRequest,
    report: Option<String>,
    name_based: bool,
    /// What the launch says about the LLM pass. `request.llm` holds the options when it asks for the pass.
    llm: launch::LlmChoice,
}

fn parse() -> Result<Args> {
    let cwd = std::env::current_dir()?;
    let mut request = ReviewRequest::new(cwd.clone());
    request.cwd = Some(cwd);
    let mut report = None;
    let mut name_based = false;
    let mut repo: Option<String> = None;
    let mut llm_tool: Option<String> = None;
    let mut llm_command: Option<PathBuf> = None;
    let mut llm_model: Option<String> = None;
    let mut no_llm = false;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let mut value = |name: &str| args.next().ok_or_else(|| anyhow!("{name} needs a value"));
        match arg.as_str() {
            "-h" | "--help" => {
                print!("{HELP}");
                std::process::exit(0);
            }
            "-V" | "--version" => {
                println!("reviewmap {}", env!("CARGO_PKG_VERSION"));
                std::process::exit(0);
            }
            "--base" => request.base = value("--base")?,
            "--head" => request.head = Some(value("--head")?),
            "--no-merge-base" => request.use_merge_base = false,
            "--target" => request.targets.push(value("--target")?),
            "--bazel-arg" => request.bazel_args.push(value("--bazel-arg")?),
            "--no-index" => request.index = Some(false),
            "--index" => request.index = Some(true),
            "--report" => report = Some(value("--report")?),
            "--name-based" => name_based = true,
            "--llm" => llm_tool = Some(value("--llm")?),
            "--llm-command" => {
                let given = PathBuf::from(value("--llm-command")?);
                // A path is made absolute, because the app runs it from elsewhere; a bare name is looked up.
                llm_command = Some(if given.components().count() > 1 { std::fs::canonicalize(&given).unwrap_or(given) } else { given });
            }
            "--llm-model" => llm_model = Some(value("--llm-model")?),
            "--no-llm" => no_llm = true,
            other if other.starts_with("--bazel-arg=") => request.bazel_args.push(other["--bazel-arg=".len()..].to_string()),
            other if other.starts_with('-') => bail!("Unknown option {other}. Run reviewmap --help."),
            other => {
                if repo.is_some() {
                    bail!("Only one repository can be given.");
                }
                repo = Some(other.to_string());
            }
        }
    }
    if let Some(r) = repo {
        request.repo = PathBuf::from(r);
    }
    request.repo = std::fs::canonicalize(&request.repo).map_err(|_| anyhow!("{} does not exist.", request.repo.display()))?;
    if let Some(tool) = &llm_tool {
        if tool != "claude" && tool != "codex" {
            bail!("Unknown LLM tool {tool}. Use claude or codex.");
        }
    }
    let llm = if no_llm {
        if llm_tool.is_some() || llm_command.is_some() || llm_model.is_some() {
            bail!("--no-llm can't be given with --llm, --llm-command, or --llm-model.");
        }
        launch::LlmChoice::Off
    } else if llm_tool.is_some() || llm_command.is_some() || llm_model.is_some() {
        let options = LlmOptions { tool: llm_tool.unwrap_or_else(|| "claude".to_string()), command: llm_command, model: llm_model, ..LlmOptions::default() };
        request.llm = Some(options);
        launch::LlmChoice::On
    } else {
        launch::LlmChoice::Default
    };
    Ok(Args { request, report, name_based, llm })
}

fn main() {
    let args = match parse() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("reviewmap: {e}");
            std::process::exit(2);
        }
    };
    let result = match &args.report {
        Some(out) => write_report(&args, out),
        None => launch::open_app(&args.request, args.llm),
    };
    reviewmap_core::bazel::workspace::shutdown_all();
    if let Err(e) = result {
        eprintln!("reviewmap: {e:#}");
        std::process::exit(1);
    }
}

fn write_report(args: &Args, out: &str) -> Result<()> {
    let cancel = Cancel::new();
    let last = std::sync::Mutex::new(None);
    let emit = |event: Event| match event {
        Event::Progress(message) => eprintln!("{message}"),
        Event::Report(report) => {
            eprintln!("Report: {} ({} review items, {} edges)", report.analysis.stage, report.review_items.len(), report.edges.len());
            *last.lock().unwrap() = Some(report);
        }
    };
    let session = session::run(args.request.clone(), &cancel, &emit)?;
    let report = if args.name_based { session.name_based_report() } else { *last.into_inner().unwrap().ok_or_else(|| anyhow!("the analysis produced no report"))? };
    let json = serde_json::to_string_pretty(&report)?;
    if out == "-" {
        println!("{json}");
    } else {
        std::fs::write(out, json)?;
        eprintln!("Wrote {out}.");
    }
    Ok(())
}

mod launch;
