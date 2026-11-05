import { track } from "@shop/analytics";
import { shared } from "./cart/store";

export function start(): string {
  track("start");
  return shared.total().amount.toString();
}
