import { Cart, MemoryRepository } from "./cart";

export function testTotal(): boolean {
  const cart = new Cart(new MemoryRepository());
  cart.add({ id: "a", price: 2 });
  return cart.total().amount === 2;
}
