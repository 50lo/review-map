// `bazel run //app:dev`: Vite's dev server on the UI's sources, for work on the UI in a plain browser.
//
// Vite runs in the checkout's app/ directory, so it serves and reloads the files being edited. Their imports
// resolve through app/node_modules, a link to the packages Bazel laid out from pnpm-lock.yaml (this target's
// runfiles); .gitignore and .bazelignore keep it out of git and out of Bazel's view.
//
//   REVIEWMAP_REPORT=/path/to/report.json bazel run //app:dev
//
// serves that report (written by `reviewmap --report`) through the mocked backend in src/dev-mock.ts; see
// vite.config.ts. A relative path is taken from the directory `bazel run` was started in.
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const workspace = process.env.BUILD_WORKSPACE_DIRECTORY;
const runfiles = process.env.JS_BINARY__RUNFILES;
if (!workspace || !runfiles) {
  console.error("Start the dev server with `bazel run //app:dev`.");
  process.exit(1);
}
const app = path.join(workspace, "app");
const laidOut = path.join(runfiles, "_main/app/node_modules");
const link = path.join(app, "node_modules");

const existing = fs.lstatSync(link, { throwIfNoEntry: false });
if (existing && !existing.isSymbolicLink()) {
  console.error(`${link} is a directory, left by an install that is not Bazel's. Remove it and start again.`);
  process.exit(1);
}
if (existing) fs.unlinkSync(link);
fs.symlinkSync(laidOut, link);

const env = { ...process.env };
if (env.REVIEWMAP_REPORT) {
  env.REVIEWMAP_REPORT = path.resolve(process.env.BUILD_WORKING_DIRECTORY ?? workspace, env.REVIEWMAP_REPORT);
}
const vite = spawn(process.execPath, [path.join(link, "vite/bin/vite.js"), ...process.argv.slice(2)], { cwd: app, env, stdio: "inherit" });
for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => vite.kill(signal));
vite.on("exit", (code, signal) => process.exit(signal ? 1 : (code ?? 0)));
