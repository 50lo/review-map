import { Cache, Store } from "@demo/lib";
import { label } from "@app/format";

export let cache: Cache | undefined;

export function start(): number {
  const store = new Store();
  return store.load();
}

export function describe(): string {
  return label(start());
}
