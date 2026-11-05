export enum Currency {
  USD = "USD",
  EUR = "EUR",
  GBP = "GBP",
}

export type Money = { amount: number; currency: Currency };

export function format(money: Money): string {
  // Two decimals, then the currency code.
  return `${money.amount.toFixed(2)} ${money.currency}`;
}

export function round(value: number, digits = 2): number {
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}
