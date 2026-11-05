import { shared } from "./cart/store";

export function start(): string {
  return shared.total().amount.toString();
}
