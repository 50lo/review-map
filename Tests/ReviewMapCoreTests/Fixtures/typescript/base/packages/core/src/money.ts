export enum Currency {
  USD = "USD",
  EUR = "EUR",
}

export type Money = { amount: number; currency: Currency };

export function format(money: Money): string {
  return `${money.amount.toFixed(2)} ${money.currency}`;
}

export function round(value: number): number {
  return Math.round(value * 100) / 100;
}
