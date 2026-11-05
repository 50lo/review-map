import { z } from "zod";

export const ItemSchema = z.object({ id: z.string(), price: z.number() });
