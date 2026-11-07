package shop.model

data class Cart(val id: String, val note: String)
interface Repository {
    fun load(): String
}
object Store : Repository {
    override fun load(): String = "ok"
}
