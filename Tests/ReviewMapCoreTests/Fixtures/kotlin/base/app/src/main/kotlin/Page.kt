package shop.app
import androidx.compose.runtime.Composable
import shop.money.format

@Composable
fun Page(visible: Boolean): String {
    if (visible) return format(1)
    return "hidden"
}
