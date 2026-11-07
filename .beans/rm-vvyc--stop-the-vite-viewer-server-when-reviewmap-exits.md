---
# rm-vvyc
title: Stop the Vite viewer server when reviewmap exits
status: todo
type: task
created_at: 2026-11-07T22:47:13Z
updated_at: 2026-11-07T22:47:13Z
---

## What

When the reviewer stops `reviewmap` with Ctrl-C, the Vite dev server it started keeps running and keeps holding the viewer port (default 5173). The reviewer has to find and kill it by hand:

```
> reviewmap-viewer@0.1.0 dev
> vite --port 5173 --strictPort --open
  VITE v6.3.5  ready in 198 ms
  ➜  Local:   http://localhost:5173/
^C
$ lsof -i:5173
COMMAND   PID USER   FD   TYPE ... NAME
node    44902 solo   36u  IPv6 ... TCP localhost:5173 (LISTEN)
$ kill 44902
```

Make stopping `reviewmap` (Ctrl-C, or SIGTERM) also stop Vite, so the port is free right away.

## Why

Because the viewer runs with `--strictPort`, the next `reviewmap … --view` or `reviewmap view` on the same port fails until the orphaned Vite is killed manually.

## Where

- `Sources/reviewmap/Viewer.swift`, `ViewerLauncher.run` and the private `exec` helper. `run` starts the viewer as `/usr/bin/env npm run dev -- --port <port> --strictPort [--open]` with `Process`, then blocks in `p.waitUntilExit()`. reviewmap installs no signal handlers, so on Ctrl-C it dies with the default SIGINT action and never cleans up its child. The process chain is reviewmap → npm → sh → node (vite); the signal does not reliably reach vite through npm, so vite is orphaned.
- Both entry points go through `ViewerLauncher.run`: `reviewmap view` (`ViewCommand` in the same file) and `reviewmap … --view` (`Sources/reviewmap/main.swift`).
- `viewer/package.json` (`"dev": "vite"`) and `viewer/vite.config.ts` if the fix touches how Vite is started.

## Possible approaches (pick the simplest that works)

1. In `ViewerLauncher.run`, handle SIGINT/SIGTERM in reviewmap (ignore the default action with `signal(SIGINT, SIG_IGN)` and use `DispatchSource.makeSignalSource`), then terminate the child and wait for it before exiting.
2. Start Vite without npm in between (run `node_modules/.bin/vite` directly), so there is a single child to signal.
3. Put the child in its own process group and signal the whole group on exit, so grandchildren (sh, node) are covered too.

## Acceptance criteria

- [ ] After `reviewmap view` (and `reviewmap … --view`) is stopped with Ctrl-C, nothing listens on the viewer port (`lsof -i:<port>` is empty) within a couple of seconds.
- [ ] Same after `kill <reviewmap pid>` (SIGTERM).
- [ ] Running `reviewmap view` again on the same port right after works without manual cleanup.
- [ ] The first-run `npm ci` step and the `--open`, `--port` and `--editor` options behave as before.
- [ ] A non-zero exit of Vite still makes reviewmap exit with that code (current `exec` behavior).

## Constraints

- macOS is the main target; don't break Linux if the code is shared.
- Keep the change inside the viewer launcher; no change to the report format or the viewer UI.
