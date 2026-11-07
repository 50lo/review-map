package sample.api
interface LosesDefault {
    fun refresh() {}
}
class NeedsDefault : LosesDefault
abstract class LosesImplementation {
    open fun reset() {}
}
class NeedsImplementation : LosesImplementation()
