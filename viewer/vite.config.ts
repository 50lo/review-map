import type { Plugin } from "vite";
import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";
import { viteSingleFile } from "vite-plugin-singlefile";
import fs from "node:fs";
import path from "node:path";
import { collectSources, editorFrom, gitShow, openInEditor, repoInfo } from "./server/repo";

// The change report to show. Set by `reviewmap --view`, or by hand:
//   REVIEWMAP_MODEL=/path/to/change-report.json npm run dev
const modelPath = process.env.REVIEWMAP_MODEL ? path.resolve(process.env.REVIEWMAP_MODEL) : undefined;

const readModel = () => JSON.parse(fs.readFileSync(modelPath!, "utf8"));

// The editor Open runs: REVIEWMAP_EDITOR, set by `reviewmap --editor` or by hand.
const editor = editorFrom(process.env.REVIEWMAP_EDITOR);
if (process.env.REVIEWMAP_EDITOR && !editor) {
  console.warn(`REVIEWMAP_EDITOR="${process.env.REVIEWMAP_EDITOR}" is neither a known editor nor a command with {file}; Open is off.`);
}

// Serves the change report at /api/model, file contents at base and head at /api/source, and
// opening a file in the editor at /api/open.
function modelServer(): Plugin {
  return {
    name: "reviewmap-model",
    configureServer(server) {
      const repo = () => (modelPath && fs.existsSync(modelPath) ? repoInfo(readModel()) : null);
      server.middlewares.use("/api/source", async (req, res) => {
        const q = new URL(req.url ?? "", "http://x").searchParams;
        const r = repo();
        const side = q.get("side") === "base" ? "base" : "head";
        const text = r ? await gitShow(r, side, q.get("file") ?? "") : null;
        res.statusCode = text === null ? 404 : 200;
        res.setHeader("Content-Type", "text/plain; charset=utf-8");
        res.end(text ?? (r ? "Not found at that commit" : "Repo not found; set REVIEWMAP_REPO"));
      });
      server.middlewares.use("/api/open", async (req, res) => {
        const q = new URL(req.url ?? "", "http://x").searchParams;
        const r = repo();
        // Only POST, so a page elsewhere can't trigger it with a link or an image.
        const result =
          req.method !== "POST"
            ? { ok: false, message: "Use POST" }
            : !editor
              ? { ok: false, message: "No editor set; pass --editor or set REVIEWMAP_EDITOR." }
              : r
                ? await openInEditor(editor, r, q.get("file") ?? "", Number(q.get("line") ?? 1))
                : { ok: false, message: "Repo not found" };
        res.statusCode = result.ok ? 200 : 400;
        res.setHeader("Content-Type", "text/plain; charset=utf-8");
        res.end(result.message);
      });
      // Reviewed marks and notes, in a file next to the model, keyed by head commit.
      server.middlewares.use("/api/review", (req, res) => {
        if (!modelPath) {
          res.statusCode = 404;
          res.end("REVIEWMAP_MODEL is not set");
          return;
        }
        const file = modelPath.replace(/\.json$/, "") + ".review.json";
        const read = () => {
          try {
            return JSON.parse(fs.readFileSync(file, "utf8"));
          } catch {
            return {};
          }
        };
        if (req.method === "PUT") {
          let body = "";
          req.on("data", (c) => (body += c));
          req.on("end", () => {
            try {
              const { headSha, state } = JSON.parse(body);
              if (typeof headSha !== "string" || !state || typeof state !== "object") throw new Error("bad request");
              fs.writeFileSync(file, JSON.stringify({ ...read(), [headSha]: state }, null, 2));
              res.end("saved");
            } catch (err) {
              res.statusCode = 400;
              res.end(String(err));
            }
          });
          return;
        }
        res.setHeader("Content-Type", "application/json");
        res.setHeader("Cache-Control", "no-store");
        res.end(JSON.stringify(read()));
      });
      server.middlewares.use("/api/model", (_req, res) => {
        if (!modelPath || !fs.existsSync(modelPath)) {
          res.statusCode = 404;
          res.end(modelPath ? `No file at ${modelPath}` : "REVIEWMAP_MODEL is not set");
          return;
        }
        res.setHeader("Content-Type", "application/json");
        res.setHeader("Cache-Control", "no-store");
        fs.createReadStream(modelPath).pipe(res);
      });
    },
  };
}

// For `npm run build:single`: embeds the model, and the source files its entities live in, in
// the page, so dist/index.html is one self-contained file that opens anywhere, with no server.
// REVIEWMAP_EMBED_MAX caps the embedded sources (bytes, default 8 MB).
function embedModel(): Plugin {
  return {
    name: "reviewmap-embed",
    transformIndexHtml(html) {
      if (!modelPath) return html;
      const raw = fs.readFileSync(modelPath, "utf8");
      const json = raw.replace(/</g, "\\u003c");
      const max = Number(process.env.REVIEWMAP_EMBED_MAX ?? 8_000_000);
      const { sources, skipped } = collectSources(JSON.parse(raw), max);
      const count = Object.keys(sources).length;
      console.log(`Embedding ${count} source files${skipped ? `, ${skipped} skipped over the size cap` : ""}.`);
      const src = count ? `<script>window.__REVIEWMAP_SOURCES__ = ${JSON.stringify(sources).replace(/</g, "\\u003c")};</script>\n` : "";
      // A function replacement, so "$&" and similar in the sources aren't read as patterns.
      return html.replace("</head>", () => `<script>window.__REVIEWMAP_MODEL__ = ${json};</script>\n${src}</head>`);
    },
  };
}

export default defineConfig(({ mode }) => ({
  plugins: [react(), modelServer(), ...(mode === "single" ? [embedModel(), viteSingleFile()] : [])],
  // The editor's name for the Open buttons; null hides them.
  define: { __REVIEWMAP_EDITOR__: JSON.stringify(mode === "single" ? null : (editor?.name ?? null)) },
  build: { chunkSizeWarningLimit: 4000 }, // elkjs is large; this is a local tool
  test: { environment: "node" },
}));
