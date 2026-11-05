import { Currency } from "../packages/core/src/money";

export function version(): string {
  return `1.0.0-${Currency.USD}`;
}
