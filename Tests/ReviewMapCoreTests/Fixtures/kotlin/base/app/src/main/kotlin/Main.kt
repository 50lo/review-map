package shop.app
import shop.model.Cart as Basket
import shop.money.*
import shop.first.Widget

fun render(cart: Basket): String = format(1) + cart.note

fun runWidget(): String = Widget().run()
