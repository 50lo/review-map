import { VERSION } from "./generated/version";
import { Store } from "@demo/lib";

export function buildInfo(): string {
  return `${VERSION} ${new Store().load()}`;
}
