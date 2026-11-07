package example

fun added(): String = "new"
fun signature(value: Int): String = value.toString()
fun nullable(value: String?, count: Int): String = value ?: ""
private fun narrowed() {}
suspend fun becomeSuspend() {}
fun becomeSync() {}
class Flexible
open class Extensible
class AbstractOwner
abstract class BecomesAbstract
data class Point(val x: Int, val y: Int)
data class Reordered(val y: Int, val x: Int)
data class BecomesData(val x: Int)
class StopsBeingData(val x: Int)
@Serializable
data class Wire(@SerialName("new") val name: String?)
@Entity
class Row(@ColumnInfo(name = "new") val name: String)
class JsonValue(@Json(name = "new") val value: String)
sealed class State
class NewState : State()
enum class Color { RED, BLUE }
internal class Hidden {
    fun secret(value: Int) {}
}
class Visibility {
    protected fun becomesProtected() {}
    internal fun becomesInternal() {}
}
fun defaultText(value: String = "!"): String = value
