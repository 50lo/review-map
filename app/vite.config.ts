import type { Plugin } from "vite";
import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";
import { execFile } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

// The UI of the Review Map app. Tauri loads the built assets from dist/ (no server, no port); `tauri dev`
// uses this dev server on a fixed port instead.
//
// To work on the UI in a plain browser, without the app:
//   REVIEWMAP_REPORT=/path/to/report.json npm run dev
// serves that report (written by `reviewmap --report`) and the sources it points at through a mocked
// backend (src/dev-mock.ts). This exists only in the dev server; the app itself never serves HTTP.
const reportPath = process.env.REVIEWMAP_REPORT ? path.resolve(process.env.REVIEWMAP_REPORT) : undefined;

function devBackend(): Plugin {
  return {
    name: "reviewmap-dev-backend",
    apply: "serve",
    configureServer(server) {
      const report = () => JSON.parse(fs.readFileSync(reportPath!, "utf8"));
      server.middlewares.use("/__dev/report", (_req, res) => {
        if (!reportPath || !fs.existsSync(reportPath)) {
          res.statusCode = 404;
          res.end("REVIEWMAP_REPORT is not set");
          return;
        }
        res.setHeader("Content-Type", "application/json");
        res.setHeader("Cache-Control", "no-store");
        fs.createReadStream(reportPath).pipe(res);
      });
      server.middlewares.use("/__dev/source", (req, res) => {
        const q = new URL(req.url ?? "", "http://x").searchParams;
        const file = q.get("file") ?? "";
        const safe = !!file && !file.startsWith("/") && !file.startsWith("-") && !file.split("/").includes("..");
        if (!reportPath || !safe) {
          res.statusCode = 404;
          res.end();
          return;
        }
        const { repo } = report();
        const sha = q.get("side") === "base" ? repo.baseSha : repo.headSha;
        execFile("git", ["-C", repo.root, "show", `${sha}:${file}`], { maxBuffer: 32 * 1024 * 1024, encoding: "utf8" }, (err, out) => {
          res.statusCode = err ? 404 : 200;
          res.setHeader("Content-Type", "text/plain; charset=utf-8");
          res.end(err ? "" : out);
        });
      });
    },
  };
}

export default defineConfig({
  plugins: [react(), devBackend()],
  clearScreen: false,
  server: { port: 1420, strictPort: true, watch: { ignored: ["**/src-tauri/**"] } },
  build: { chunkSizeWarningLimit: 4000, target: "safari16" }, // elkjs is large; this is a local app
  test: { environment: "node" },
});
