import { readFileSync } from "node:fs";

export function lint(path: string): number {
  const text = readFileSync(path, "utf8");
  if (!text) throw new Error(`empty: ${path}`);
  return text.split("\n").length;
}
