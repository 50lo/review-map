package sample.api
interface Store {
    fun get(): String
    fun clear()
}
interface WithDefaults {
    fun title(): String = "title"
}
abstract class AbstractStore {
    abstract fun get(): String
    abstract fun reset()
}
fun load(): String = "head"
