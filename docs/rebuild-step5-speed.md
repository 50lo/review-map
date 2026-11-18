# Phase 1 step 5: where indexing time goes, and what to do first

Step 5 of the [phase 1 plan](rebuild-phase1-proposal.md) ("Implementation and validation order") is to optimise measured bottlenecks while keeping reference results and coverage the same. On 2026-11-17 the user decided to start it before the manual comparisons of step 3, from measurements taken by an agent rather than by hand. This document holds those measurements, taken on this repository at `rebuild` 046c3e7, what they show, and a prioritised list of changes. Beans for the top items are under the epic **rm-8hfq** ("Phase 1 step 5: indexing speed").

## Headline numbers

| What | Time |
| --- | --- |
| Preliminary report (syntax only), any scenario | 0.1–1.0 s |
| Report with the build graph, cold | 17–19 s (two `cquery`s of the root workspace, 8–10 s each) |
| Complete report, UI-only change (`//app:bundle`), empty caches | **324 s**, of which **226 s** is the TypeScript step's Bazel build of the whole app bundle |
| The same review opened again (new process, caches kept) | 17.9 s, of which 16.3 s is the two graph queries |
| The next UI change, same session (Bazel servers warm) | 24.6 s, of which 14.3 s is the TypeScript step's Bazel build (Vite 7.7 s, Rust app 4.6 s) |
| TypeScript Bazel step if it built only `//app:node_modules`, empty caches | **7.6 s** instead of 205 s, with a byte-identical SCIP index |
| Rust analysis (parsing both sides, each report build) | 0.02–0.8 s parsing, 0.06–0.1 s per report |
| Change in nested fixture workspaces (4 workspaces + root) | 160 s warm-root; 571–883 s cold, both under memory pressure (see below) |

The Rust core is not the problem. Nearly all the time is Bazel: building more than the indexers read, querying the graph again and again, one cold server per workspace and side, and doing it all one step at a time.

## Method

**Machine.** Mac mini (Macmini9,1, M1, 8 cores, 16 GB RAM), macOS 27.0.1, Xcode 27.2, Bazel 9.3.1 through Bazelisk (the app-owned trees contain `tools/bazel`, so Bazel runs with `XCODE_VERSION` set as in the repo), Node.js 24.22.2, OpenJDK 27. Other agent sessions were using the machine at the same time (a UI agent and several idle Bazel servers of other worktrees); the load average was recorded for every run, and runs under heavy load are marked.

**Binaries.** `reviewmap` and `reviewmap-swift-helper` built with `bazel build --config=release` (as the app bundle is) from this branch, with throwaway instrumentation that is not committed:

- `REVIEWMAP_TIMING=1` prints `[timing] <seconds> <step>` for every external command (`Cmd::output`, `output_lenient`, `run_logged` in `crates/core/src/proc.rs`), for reading and parsing the two trees, for materialising each app-owned tree, for each side's graph query, for each language's index per workspace and side (`Session::index_workspaces`), for the Swift helper's index read and store merge, for TypeScript's `resolve`, and for every report build (`Session::build`).
- `REVIEWMAP_PROFILE_DIR` keeps a copy of Bazel's JSON trace profile (`<output_base>/command.profile.gz`, rewritten by every command) after each Bazel command, so the phases inside each command (module resolution, loading, analysis, execution, the slowest actions) can be read afterwards.
- `REVIEWMAP_KEEP_BAZEL=1` makes the CLI skip `shutdown_all()` at exit. The app runs `session::run` in its own process for every review and shuts the Bazel servers down only when it quits (`app/src-tauri/src/lib.rs`), so two CLI runs with servers kept up are a faithful stand-in for two reviews in one app session.

The CLI ran in its diagnostic mode, `reviewmap <repo> --base <b> --head <h> --no-llm --report <file> [--target //app:bundle]`, with every progress line timestamped, from a scratch clone of the repository (two extra commits, below). A sampler recorded the peak resident memory of every process whose command line names the scratch home (Bazel servers) and of `reviewmap`, the helper, scip-typescript and the Kotlin indexer. This is a lower bound: Bazel's Swift and Java workers don't name the output base. Disk use is `du` of the scratch home after the run.

**Isolation and what "cold" means.** Every run used `REVIEWMAP_HOME=<scratch>/homes/<n>`, so Review Map's cache (syntax cache, index caches, app-owned trees, output bases, `disk-cache`, the scip-java launcher) never touched the user's. A cold run starts with that directory deleted and no Bazel server of it running. Two things stay shared and warm even then: Bazel's repository cache and install base under the default output user root (shared with the user's own Bazel builds, so no package was downloaded), and npm's cache (`npx` had scip-typescript 0.4.0). A first install on a new machine adds those downloads on top. The scip-java launcher, which lives in Review Map's cache, was downloaded in the cold Kotlin run (15.9 s).

**Three cache states**, as the plan asks:

- *cold*: empty Review Map cache, new process.
- *reopen*: caches kept, new process, Bazel servers stopped (what reopening the app gives). Either the same pair again, or the next pair.
- *session*: caches kept and Bazel servers still running from the previous review (`REVIEWMAP_KEEP_BAZEL=1`), the next pair.

**Scenarios.** All with the default merge-base (the base is the head's parent in every pair, so the merge-base is the base).

| Name | Base..head | What changed | Scope | Languages indexed |
| --- | --- | --- | --- | --- |
| UI | `6324470^..6324470` (rm-mgz2) | 4 files in `app/src` (TS/TSX/CSS) | `--target //app:bundle` | Swift (root workspace, which holds the helper), TypeScript |
| UI next | `99f2be4^..99f2be4`, then `bff6fe0^..bff6fe0` | `app/src`; bff6fe0 also `app/src-tauri/src` | same | same |
| Rust | `f1df7b4^..f1df7b4` | 9 `.rs` files in `crates/core` | same | Swift only (no TS file changed; Rust has no index in phase 1) |
| Swift helper | `046c3e7..bench-helper` (synthetic: an extension added to `helper/Sources/reviewmap-swift-helper/Model.swift`) | 1 Swift file | same | Swift |
| Kotlin | `046c3e7..bench-kotlin`, then `046c3e7..bench-kotlin2` (synthetic: a function added to `Tests/ReviewMapCoreTests/Fixtures/kotlin-bazel-indexed/head/store/Store.kt`, then to `cache/Cache.kt`) | 1 Kotlin file in the nested rules_kotlin fixture workspace | none (that workspace becomes primary; `//...`) | Kotlin |
| Mixed | `8cf8972..046c3e7` | 46 files: Rust, TS, and Swift/TS sources of the four nested fixture workspaces `crates/core/tests/fixtures/{swift-bazel,ts-bazel}/{base,head}` | `--target //app:bundle` for the root; the nested ones get `//...` | Swift (root; the nested Swift workspaces have no scope targets and are refused), TypeScript (root and the two ts-bazel workspaces) |
| No index | UI pair with `--no-index` | | | none: parsing, graph queries, reports |

Raw logs, reports, summaries and Bazel profiles of every run are in the session's scratch directory, not in the repository. Bean rm-l8ck describes the harness (a benchmark script, a phase table, a report comparison) and proposes keeping the timing in the product.

## Results

Seconds of wall time per phase. Phases run one after another, so they add up to the total, except that Kotlin's indexer JVMs run up to `REVIEWMAP_KOTLIN_JOBS` at a time. "graph report" is when the report with the build graph reached the UI. A dash means the phase didn't run (or its result came from Review Map's cache).

| Run | state | parse | graph | Swift build | Swift read | TS Bazel | scip-ts | Kotlin Bazel | Kotlin indexer | download | reports | graph report at | **total** | load (1 min, start→end) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| No index | cold | 0.8 | 7.0 | – | – | – | – | – | – | – | 0.2 | 8.5 | **9.7** | 4→4 |
| UI | cold | 0.4 | 16.8 | 67.0 | 0.9 | 225.6 | 10.4 | – | – | – | 0.3 | 17.4 | **323.7** | 4→18 |
| UI (repeat) | cold | 0.4 | 17.6 | 66.4 | 0.9 | 228.6 | 8.9 | – | – | – | 0.3 | 18.3 | **325.3** | 8→15 |
| UI | reopen, same pair | 0.0 | 16.3 | – | – | – | – | – | – | – | 0.3 | 16.5 | **17.9** | 15→13 |
| UI next (99f2be4) | reopen | 0.2 | 14.3 | 2.9 | 0.4 | 15.7 | 4.3 | – | – | – | 0.3 | 14.7 | **39.4** | 12→11 |
| UI next (bff6fe0) | session | 0.2 | 2.1 | 1.3 | 0.5 | 14.3 | 4.4 | – | – | – | 0.4 | 2.5 | **24.6** | 11→10 |
| Rust | cold | 0.3 | 16.1 | 69.9 | 0.9 | – | – | – | – | – | 0.3 | 16.6 | **89.3** | 4→8 |
| Rust | session | 0.2 | 2.6 | 3.3 | 0.9 | – | – | – | – | – | 0.3 | 3.0 | **8.3** | 5→7 |
| Swift helper | cold | 0.4 | 18.2 | 88.1 | 1.4 | – | – | – | – | – | 1.0 | 19.0 | **111.2** | 8→19 |
| Swift helper | session | 0.2 | 2.4 | 3.3 | 0.9 | – | – | – | – | – | 0.3 | 2.8 | **8.2** | 7→8 |
| Kotlin | cold | 0.4 | 23.8 | – | – | – | – | 23.0 | 7.4 | 15.9 | 0.3 | 24.5 | **72.1** | 5→4 |
| Kotlin | reopen, same pair | 0.0 | 3.3 | – | – | – | – | 5.1 | 0.3 | – | 0.3 | 3.5 | **9.7** | 4→4 |
| Kotlin next (bench-kotlin2) | session | 0.0 | 0.2 | – | – | – | – | 3.3 | 2.7 | – | 0.3 | 0.4 | **7.2** | 4→4 |
| Mixed | session (root warm, nested cold) | 0.0 | 93.8 | – | – | 49.5 | 13.8 | – | – | – | 0.3 | 94.0 | **159.6** | 7→5 |
| Mixed | cold, **under memory pressure** | 0.8 | 189.5 | 366.8 | 2.7 | 302.7 | 15.7 | – | – | – | 1.0 | 190.8 | **883.2** | 20→46 (5-min avg 106) |
| Mixed (repeat) | cold, **under memory pressure** | 0.4 | 111.4 | 68.5 | 0.9 | 346.1 | 37.2 | – | – | – | 0.4 | 112.0 | **571.0** | 8→48 (5-min avg 28→31) |

Per side, cold UI: graph head 8.4 + base 8.4; Swift head 62.1 (68 actions, critical path 58 s: compiling swift-syntax's `SwiftSyntax` module alone takes about 90 s of CPU) + base 5.0 (32 disk-cache hits); TypeScript head 205.1 (2292 actions, 1463 run, critical path 144 s) + base 20.5 (1464 disk-cache hits); scip-typescript 5.9 + 4.5.

**Memory and disk.**

| Run | Peak RSS, Bazel servers (lower bound) | Peak RSS, reviewmap + indexers | Review Map cache after the run |
| --- | --- | --- | --- |
| No index | 0.7 GB | 0.07 GB | 0.04 GB |
| UI cold | 2.4 GB | 0.8 GB (scip-typescript) | 3.8 GB: disk cache 1.4, head output base 1.5, base output base 0.9 |
| Rust cold / Swift helper cold | 3.1 GB | 0.3 GB | 0.4 GB |
| Kotlin cold | 2.4 GB | 0.7 GB | 0.55 GB (0.1 GB is the scip-java launcher) |
| Mixed session | 3.4 GB, 10 Bazel servers alive at the end | 0.8 GB | (not measured separately) |
| Mixed cold (two runs) | 3.1–3.6 GB | 0.7–0.8 GB | 4.1 GB |

Index caches are small (7 MB for UI); syntax cache 6 MB.

### Repeat runs

The cold UI and cold mixed scenarios were repeated, each started once the 1-minute load average was below 8 (the 5-minute average was still 28–59 from other work on the machine).

| Run | parse | graph | Swift build | Swift read | TS Bazel | scip-ts | reports | graph report at | total |
|---|---|---|---|---|---|---|---|---|---|
| UI cold | 0.4 | 16.8 | 67.0 | 0.9 | 225.6 | 10.4 | 0.3 | 17.4 | 323.7 |
| UI cold, repeat | 0.4 | 17.6 | 66.4 | 0.9 | 228.6 | 8.9 | 0.3 | 18.3 | 325.3 |
| Mixed cold | 0.8 | 189.5 | 366.8 | 2.7 | 302.7 | 15.7 | 1.0 | 190.8 | 883.2 |
| Mixed cold, repeat | 0.4 | 111.4 | 68.5 | 0.9 | 346.1 | 37.2 | 0.4 | 112.0 | 571.0 |

The two UI reports are byte-identical after `jq -S`, and so are the three mixed reports (cold, repeat, warm-root session). The UI numbers are stable within 1%. The mixed numbers are not: both cold mixed runs ran with 4.6–4.7 GB of swap in use and a load average of 30–106, partly from other work on the machine and partly from the review's own Bazel servers (B3). The Swift build that took 353 s in the first run took 64 s in the repeat, the same as in the UI runs; the TypeScript bundle build took 303 s and 346 s, against 226 s in the UI runs. Treat the mixed cold totals as "what happens on a busy 16 GB machine", not as a baseline; use the UI and warm-root mixed numbers as baselines.

## Where the time goes

**B1. TypeScript builds the review scope instead of what scip-typescript reads.** For a rules_ts workspace, `index::typescript::build` runs `bazel build <scope targets>` (`Setup::Bazel`), then links `bazel-bin/<pkg>/node_modules` for the indexer. With `--target //app:bundle` that builds the whole app: the Rust app and CLI, the Swift helper (again, see B4), Vite's `//app:dist`, and the bundle. Without a target it builds `//...` (an earlier run of this repo, recorded in bean rm-kmap's hand-over, took 215 s cold for that). scip-typescript reads only the sources and the `node_modules` that rules_js lays out. Building only `//app:node_modules` (a `js_library` over 15 `npm_link_package_store` targets, which pull in 385 package stores) in the cold head tree took 7.6 s (457 actions, critical path 0.8 s) and laid out the same packages; scip-typescript over it gave a SCIP file byte-identical (same SHA-1) to the one over the full bundle build. Measured cost of the current behaviour: 226 s of a 324 s cold UI review, 14–16 s of a 24–39 s warm one (Vite 7.7 s and the Rust app 4.6 s in the profile of bff6fe0), 49.5 s of the warm mixed review.

*Done in rm-9e2v (2026-11-18):* the TypeScript step now runs one `bazel query` for the `npm_link_package_store` targets (and generated TypeScript sources) the scope depends on and builds only those, falling back to the scope targets when the query fails or finds no link. Cold UI review 315.2 → 91.4 s (TypeScript query + build 202.9 → 4.6 s at head, 21.1 → 3.0 s at base); the same pair with scope `//...` 411.1 → 24.6 s; `bff6fe0` in a session 0.8 s for the TypeScript query + build. Every report is identical to the one from the previous code. Details in the bean.

**B2. The build graph is queried per side, per workspace, one after another, with no cache.** `Session::refine` step 1 runs `load_graph` for head then base for every workspace in scope. Nothing is cached, so reopening the same review spends 16.3 s of its 17.9 s there. A new Bazel server costs 6–8 s of each cold `cquery` (server start, module resolution, loading and analysis of `//app:bundle`'s closure); a warm one answers in 0.7–1.7 s. Base and head are separate trees with separate output bases, so they never share that work. In 6 of the 7 pairs measured no BUILD, `.bzl`, MODULE, lock or `.bazelrc` file changed; in 3 of them no file was added or removed either, so the base graph equals the head graph and its query is redundant. (Added or removed files change `glob()` results, so any reuse must key on the path list, not only on build files.)

*Done in rm-n8fo (2026-11-18):* `Session::refine` keeps each workspace's graph in `<cache>/graphs/<repo>/<key>.json` (`crates/core/src/bazel/cache.rs`). The key covers the scope, the Bazel arguments, the Bazel and Xcode versions, the bazelrc files, every build-definition and lock file, and the list of paths. Base reuses head's graph when their keys are equal. Reopening the UI review: 13.6 → 0.57 s, with no query. Cold `99f2be4`: one `cquery` instead of two, and the report with the build graph at 7.8 s instead of 16.0 s. Reports are identical to the previous code's in every scenario, cold and on reopen. Details are in the bean.

*Done in rm-zm5r (2026-11-18):* the graph queries run at the same time, up to `REVIEWMAP_BAZEL_JOBS` (default `min(4, cores / 2)`, lower when little memory is free; `crates/core/src/bazel/jobs.rs`). When base's key differs from head's, both sides are queried at once; when they are equal, base still takes head's graph. The cold UI review's graph report came at 12.9–14.2 s instead of 15.4–16.9 s, short of the 9–11 s hoped for: two cold analyses of `//app:bundle` take about 12.5 s each together against about 7.5 s alone, because they compete for the CPU. Details in the bean.

**B3. Nested workspaces multiply servers and graph time.** The mixed review touched four nested fixture workspaces. Each got two cold Bazel servers (one per side), and each `query //...` took 10–13 s even with the root warm: 92 s in all. The profiles show 8.6 s of each spent in Bzlmod module resolution, downloading `MODULE.bazel` files and yanked-version metadata from the Bazel Central Registry, because these fixtures have no `MODULE.bazel.lock` and every output base resolves from scratch. The servers then stay up until the process exits, so the mixed review ended with 10 Bazel servers alive (3.4 GB measured, more in practice). On a 16 GB machine shared with other work, the system had 4.7 GB of swap in use after the cold mixed run, and its Swift build took 353 s instead of 62 s (64 s in the repeat run, which also ended with 4.6 GB of swap). How much of the pressure came from the review's own servers and how much from other work on the machine could not be separated.

*Done in rm-zm5r (2026-11-18):* the nested workspaces' graph queries run four at a time, so the mixed review's graph step took 27.5–35.0 s in 9 of 13 runs instead of 95.8–118.5 s, with the root warm (38–57 s when other work or the Bazel Central Registry slowed the queries). Its index builds still run workspace by workspace. Running them at once saved about 5 s but raised the peak memory of the servers. The peak memory of the Bazel servers is the same as before (3.9–4.4 GB): the review still keeps 10 servers alive (rm-e2b4). Details in the bean.

**B4. Every Bazel command after the first discards the analysis cache.** The graph `cquery` runs without `--features`, the Swift index build with `--features=swift.index_while_building --features=swift.use_global_index_store`, and the TypeScript build without them again, all in the same output base. Every build log says "Build option --features has changed, discarding analysis cache". With a warm server this costs about 1 s per command (profile of the Swift build in the UI session run: 1.0 s to complete). It also means the TypeScript build cannot reuse the Swift helper that the index build just compiled (different configuration): the cold TypeScript build compiled swift-syntax again, without index flags (0 disk-cache hits on head). Fixing B1 removes most of the second cost.

**B5. Swift is indexed when no Swift file changed.** In the Rust-only review, Swift's index was built at both sides: 66 + 5 s cold, 3.3 s warm. TypeScript, in contrast, is indexed only when a TypeScript file changed (`Session::index_typescript` builds units from changed files only); Swift and Kotlin use every Bazel workspace in scope (`Session::bazel_units`), and with no changed file of an indexed language the root workspace is still put in scope (`Session::open`, "Explicit targets belong to the workspace around the directory the review was started from"). The Swift index is cached by commit, so a new commit always rebuilds it.

**B6. Cold Swift is compiling swift-syntax.** The Swift index build compiles every Swift module the scope reaches with index-while-building: the helper and swift-syntax/indexstore-db, 68 actions, critical path 58 s cold. The base side then hits the shared disk cache (5 s). This cost is real indexing work and comes once per toolchain and dependency version; the normal developer build of the app can't supply it, because its Swift actions run without index flags and therefore have different action keys (and it uses another output base and no `--disk_cache`).

**B7. Kotlin.** On the small fixture: 15.9 s to download the scip-java launcher into an empty cache, 11.8–12 s per cold `query //...` (module resolution again), 9–14 s per aspect build cold, about 2 s per target JVM. On reopen the aspect build still runs at each side (2.5 s each), because only per-target indexes are cached, not the side's result. The fixture has three targets, so these are lower bounds for a real Kotlin project.

**B8. What is already fine.** Parsing both sides: 0.2–0.8 s cold, 0.02 s from the syntax cache. Each report build: 0.06–0.1 s (5–6 per review). Updating an app-owned tree: 0.04 s for 700 files. The Swift helper's index read: 0.4–0.5 s per side. Swift and TypeScript index caches hit as designed on reopen, and the base side of a "next" review is usually a cache hit too (the previous review's head or base). scip-typescript itself: 4–6 s per side for this repo's 20 tsconfig projects.

## What to do, in order

Gains are measured where the measurement exists, otherwise marked as estimates. "Risk" is to reference results and coverage (CORE-003); every item must leave the final report the same as the baseline report of the same scenario apart from timings (bean rm-l8ck describes the comparison: `diff <(jq -S . baseline.json) <(jq -S . new.json)` must be empty; two runs of the same pair give identical reports today).

| # | Bean | Change | Gain | Effort | Risk | Statute decision | UI work |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | rm-l8ck | **Measure in the product:** keep `REVIEWMAP_TIMING`-style phase timing (in the log, not the UI) and a benchmark script, so every later item can show its gain and its unchanged report | enables the rest | S | none | no | no |
| 2 | rm-9e2v | **TypeScript: build only what the indexer reads** (the `npm_link_package_store` targets the scope depends on, plus generated `.ts`/`.d.ts` sources) instead of the scope targets | cold UI 324 → ~105 s (−200 s, measured: 205 s → 7.6 s head); warm UI 24.6 → ~11 s (est.) | M | low: a file with an unresolved in-repo import already drops to syntax-only with `index-partial`; check identical SCIP/report on this repo, `ts-bazel` and `ts-yarn` fixtures | no | no |
| 3 | rm-n8fo | **Graph: cache it, and reuse the head graph for base** when the build-definition files, the path list, the scope, the Bazel arguments and the Bazel version are the same | reopen 17.9 → ~2 s (−16 s); cold −8 s for pairs where base equals head (3 of 7 here) | M | low–medium: a wrong key gives wrong components or edges (not a CORE-003 issue but a correctness one); key must include glob inputs | no | no |
| 4 | rm-zm5r | **Run independent Bazel work at the same time, bounded**: head and base graph queries; graph queries of different workspaces; base's index build while head's result is read | cold UI −8 s (graph 17 → 9 s); mixed graph 92 s → ~25 s (est., bound 4) | M | none (same commands); memory rises with concurrent servers, so bound by memory too | no | no |
| 5 | rm-e2b4 | **Fewer Bazel servers alive**: stop a workspace's servers once its last job in the review is done (keep the root's), and for nested workspaces measure one output base per workspace instead of per side (that part would change the phase 1 plan's stated design, see item 12) | mixed: 10 → 2–4 servers, less memory pressure (cold mixed runs took 571–883 s with 4.6–4.7 GB of swap in use) | M | none | no | no |
| 6 | rm-2tan | **Same configuration flags for every command in an output base** (graph query and index builds), so Bazel keeps its analysis cache | ~1 s per command warm, more on large graphs (est.) | S | none (graph content is the same; check reports equal) | no | no |
| 7 | rm-gnyb | **Don't index a language that has no changed file**, as TypeScript already does; say why in the report | Rust-only cold 89 → ~17 s, warm 8.3 → ~3 s | S | changes the report: Swift becomes syntax-only with an `index-unavailable` warning when only Rust or only TS changed | **yes**: CORE-003 lists the reasons a language ends without an index (no index could be built, indexing was cancelled, indexes are off); skipping a language on purpose because none of its files changed is a new reason, so it needs a proposed decision that adds it (and probably a boundary case). On 2026-11-17 the user chose to skip such languages (option A in rm-gnyb), and approved decision D261116-tnmgj, which changes CORE-003 accordingly; the code still has to follow (rm-gnyb). TypeScript's existing behaviour has the same gap | no |
| 8 | rm-0ixm | **First-run network costs**: keep a `MODULE.bazel.lock` per app-owned workspace across sides (copy head's to base when `MODULE.bazel` is equal), and fetch the scip-java launcher in the background at the start of a review that has Kotlin | ~8.5 s per nested workspace and side on its first query; 16 s once for Kotlin | S | none (lockfile is in the app-owned tree only, CORE-002) | no | no |
| 9 | – | **Keep Bazel servers after the app quits** (rely on `--max_idle_secs=900`) | reopen graph 16 → ~2 s; 1.5–3 GB stays in memory for 15 min after quitting | S | none | no Statute rule, but it **changes the phase 1 plan's stated design** ("Stop owned Bazel servers when the app exits", `rebuild-phase1-proposal.md`); the user decides (memory vs speed) | no |
| 10 | – | **Kotlin: cache the side's result by commit, and evaluate indexing as a Bazel action** (plan item) | reopen −5 s here; real gain needs a real Kotlin project | M–L | low with per-target identity kept | no | no |
| 11 | – | **Reuse Swift index stores from the user's builds** (plan item) | cold Swift −60 s at best, only when the user's builds index (rules_xcodeproj does, `swift.index_while_building`) and provenance can be checked | L | medium: provenance (sources, configuration, toolchain) must be verified, an index for head never describes base | likely yes: index provenance isn't covered by a rule yet; CORE-002 allows reading, not writing | no |
| 12 | – | **One output base per workspace for both sides**, materialising base and head into it in turn | halves output-base disk (2.4 → ~1.5 GB) and servers; loses base/head concurrency | L | none | no Statute rule, but it **changes the phase 1 plan's stated design** (base and head directories "with stable paths and dedicated output bases"); the user decides | no |

Small UI follow-up, kept apart because another agent works on the UI epic (rm-w7ge): the progress line shows "Building head … with Bazel for the TypeScript index" for minutes with no sign of progress. Passing Bazel's own progress (`[965 / 980] Compiling …`) through `Event::Progress` is core-only work; showing elapsed time per step would touch `app/src`. Not made a bean.

### What it adds up to (estimates from the measurements)

- Cold UI review: 324 s → about 105 s with item 2, about 95 s with item 4. The remaining floor is compiling swift-syntax for the Swift index (62 s), which item 11 or item 7 (when Swift didn't change) can remove.
- Reopening the same review: 17.9 s → about 2 s with item 3.
- Next UI review in a session: 24.6 s → about 10 s with item 2 (scip-typescript 4.4 s, Swift 2 s, graph 2 s).
- Mixed review touching nested workspaces: 160 s warm-root → about 45 s with items 2, 4 and 8.

## Parallel work with the UI epic

Items 1–8 change only `crates/core` (`session.rs`, `index/typescript.rs`, `index/swift.rs`, `index/kotlin.rs`, `bazel/query.rs`, `bazel/workspace.rs`, `proc.rs`) and `crates/cli`; none touches `app/src`, so they can run alongside the UI epic rm-w7ge. Items 2, 3, 4, 5 and 7 all change `Session::refine` or its helpers in `session.rs`, so they should run one after another (order: 1, 2, 3, 4, then 5–8), or in separate branches merged with care.
