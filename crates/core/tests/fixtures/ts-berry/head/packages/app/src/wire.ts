import type { Message } from "@demo/proto";
import { Store } from "@demo/lib";

export function send(message: Message): number {
  const store = new Store();
  store.reset();
  return message.id.length + store.load();
}
