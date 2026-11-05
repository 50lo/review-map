import { Cart, MemoryRepository } from "./cart";

export function testTotal(): boolean {
  const cart = new Cart(new MemoryRepository());
  cart.add({ id: "a", price: 2 });
  cart.add({ id: "b", price: 3 });
  return cart.total().amount === 5;
}
