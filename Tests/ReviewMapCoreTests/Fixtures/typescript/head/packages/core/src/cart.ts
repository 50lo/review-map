import { Currency, Money, round } from "./money";

export interface Item {
  id: string;
  price: number;
  name?: string;
}

export interface CartRepository {
  load(): Promise<Item[]>;
  save(items: Item[]): void;
  clear?(): void;
}

export interface Serializable {
  toJSON(): string;
}

export class Cart implements Serializable {
  private items: Item[] = [];

  constructor(private readonly repository: CartRepository) {}

  get size(): number {
    return this.items.length;
  }

  add(item: Item): void {
    this.items.push(item);
  }

  first(): Item {
    return this.items[0]!;
  }

  total(): Money {
    const sum = this.items.reduce((acc, i) => acc + i.price, 0);
    return { amount: round(sum), currency: Currency.USD };
  }

  async persist(): Promise<void> {
    this.repository.save(this.items);
  }

  toJSON(): string {
    return JSON.stringify(this.items as any);
  }
}

export class MemoryRepository implements CartRepository {
  private stored: Item[] = [];

  async load(): Promise<Item[]> {
    return this.stored;
  }

  save(items: Item[]): void {
    this.stored = items;
  }
}
