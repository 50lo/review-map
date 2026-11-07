package demo.store

class Store {
    fun load(key: String): String {
        return "store:" + key
    }
}
