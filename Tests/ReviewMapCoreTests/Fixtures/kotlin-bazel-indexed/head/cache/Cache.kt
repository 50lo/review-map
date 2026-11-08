package demo.cache

class Cache {
    fun load(key: String): String {
        return "cache/" + key
    }
}
