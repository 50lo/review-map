import type { Plugin } from "vite";
import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";
import { viteSingleFile } from "vite-plugin-singlefile";
import fs from "node:fs";
import path from "node:path";

// The change model to show. Set by `reviewmap --view`, or by hand:
//   REVIEWMAP_MODEL=/path/to/change-model.json npm run dev
const modelPath = process.env.REVIEWMAP_MODEL ? path.resolve(process.env.REVIEWMAP_MODEL) : undefined;

// Serves the change model at /api/model. Later milestones add file contents and /open here.
function modelServer(): Plugin {
  return {
    name: "reviewmap-model",
    configureServer(server) {
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

// For `npm run build:single`: embeds the model in the page, so dist/index.html is one
// self-contained file that opens anywhere, with no server.
function embedModel(): Plugin {
  return {
    name: "reviewmap-embed",
    transformIndexHtml(html) {
      if (!modelPath) return html;
      const json = fs.readFileSync(modelPath, "utf8").replace(/</g, "\\u003c");
      return html.replace("</head>", `<script>window.__REVIEWMAP_MODEL__ = ${json};</script>\n</head>`);
    },
  };
}

export default defineConfig(({ mode }) => ({
  plugins: [react(), modelServer(), ...(mode === "single" ? [embedModel(), viteSingleFile()] : [])],
  build: { chunkSizeWarningLimit: 4000 }, // elkjs is large; this is a local tool
  test: { environment: "node" },
}));
