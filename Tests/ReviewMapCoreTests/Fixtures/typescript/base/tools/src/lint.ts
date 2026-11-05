import { readFileSync } from "node:fs";

export function lint(path: string): number {
  return readFileSync(path, "utf8").split("\n").length;
}
