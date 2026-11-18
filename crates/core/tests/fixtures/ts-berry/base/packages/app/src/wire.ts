import type { Message } from "@demo/proto";
import { Store } from "@demo/lib";

export function send(message: Message): number {
  return message.id.length + new Store().load();
}
