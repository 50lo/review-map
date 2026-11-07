package example

fun removed(): String = "old"
fun signature(value: String): String = value
fun nullable(value: String, count: Int?): String? = value
fun narrowed() {}
fun becomeSuspend() {}
suspend fun becomeSync() {}
open class Flexible
class Extensible
abstract class AbstractOwner
class BecomesAbstract
data class Point(val x: Int)
data class Reordered(val x: Int, val y: Int)
class BecomesData(val x: Int)
data class StopsBeingData(val x: Int)
@Serializable
data class Wire(@SerialName("old") val name: String)
@Entity
class Row(@ColumnInfo(name = "old") val name: String)
class JsonValue(@Json(name = "old") val value: String)
sealed class State
class OldState : State()
enum class Color { RED, GREEN }
internal class Hidden {
    fun secret(value: String) {}
}
class Visibility {
    internal fun becomesProtected() {}
    protected fun becomesInternal() {}
}
fun defaultText(value: String = "?"): String = value
