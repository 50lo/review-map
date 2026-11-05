import { Currency, Money, round } from "./money";

export interface Item {
  id: string;
  price: number;
}

export interface CartRepository {
  load(): Item[];
  save(items: Item[]): void;
}

export class Cart {
  private items: Item[] = [];

  constructor(private readonly repository: CartRepository) {}

  add(item: Item): void {
    if (item.price < 0) {
      return;
    }
    this.items.push(item);
  }

  total(): Money {
    const sum = this.items.reduce((acc, i) => acc + i.price, 0);
    return { amount: round(sum), currency: Currency.USD };
  }

  private persist(): void {
    this.repository.save(this.items);
  }
}

export class MemoryRepository implements CartRepository {
  private stored: Item[] = [];

  load(): Item[] {
    return this.stored;
  }

  save(items: Item[]): void {
    this.stored = items;
  }
}
