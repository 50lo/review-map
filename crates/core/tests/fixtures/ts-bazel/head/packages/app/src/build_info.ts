import { VERSION } from "./generated/version";
import { Store } from "@demo/lib";

export function buildInfo(): string {
  return `version ${VERSION}, value ${new Store().load()}`;
}
