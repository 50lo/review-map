package sample.api
interface LosesDefault {
    fun refresh()
}
class NeedsDefault : LosesDefault
abstract class LosesImplementation {
    abstract fun reset()
}
class NeedsImplementation : LosesImplementation()
