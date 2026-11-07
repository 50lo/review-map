package shop.app
import shop.first.*
import shop.second.*

// Deliberately ambiguous: neither Widget is a proven target.
fun ambiguousWidget(): String = Widget().run()
