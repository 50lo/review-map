import { useState } from "react";
import { Cart, format } from "@shop/core";

type Props = { cart: Cart };

export function CartView({ cart }: Props) {
  const [open, setOpen] = useState(false);
  if (cart.size === 0) {
    return null;
  }
  return (
    <div onClick={() => setOpen(!open)}>
      {open ? format(cart.total()) : `Cart (${cart.size})`}
    </div>
  );
}
