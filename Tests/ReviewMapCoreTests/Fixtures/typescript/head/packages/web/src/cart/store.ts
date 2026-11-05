import { Cart, MemoryRepository } from "@shop/core";

export const shared = new Cart(new MemoryRepository());

export const reset = async (): Promise<void> => {
  shared.add({ id: "reset", price: 0 });
  await shared.persist();
};
