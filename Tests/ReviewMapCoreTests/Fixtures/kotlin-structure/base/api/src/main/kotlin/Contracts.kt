package sample.api
interface Store {
    fun get(): String
}
interface WithDefaults {
}
abstract class AbstractStore {
    abstract fun get(): String
}
fun load(): String = "base"
