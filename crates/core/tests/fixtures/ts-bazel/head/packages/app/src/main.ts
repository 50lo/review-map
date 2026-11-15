import type { SemVer } from "semver";
import { Cache, Store } from "@demo/lib";

export let cache: Cache | undefined;
export let version: SemVer | undefined;

export function start(): number {
  const store = new Store();
  return store.load();
}
