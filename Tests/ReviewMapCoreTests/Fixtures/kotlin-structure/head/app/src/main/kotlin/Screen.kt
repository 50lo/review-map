package sample.ui
import android.app.Activity
import androidx.annotation.MainThread
import androidx.compose.runtime.Composable
import kotlinx.coroutines.*
import sample.api.*

class Broken : Store {
    override fun get(): String = "value"
}
class BrokenAbstract : AbstractStore() {
    override fun get(): String = "value"
}
class DefaultUser : WithDefaults

@MainThread
fun refresh() {
    load()
}

class Screen : Activity() {
    fun show() {
        load()
        withContext(Dispatchers.IO) {
            load()
        }
        launch(Dispatchers.Main) {
            load()
        }
    }
}

@Composable
fun Panel(flag: Boolean) {
    if (flag) load()
}
fun ordinary(flag: Boolean) {
    if (flag) load()
}
