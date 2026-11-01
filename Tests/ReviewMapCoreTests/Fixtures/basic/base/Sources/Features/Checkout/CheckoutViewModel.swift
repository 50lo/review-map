import Combine
import Core
import Persistence

final class CheckoutViewModel: ObservableObject {
    var total: Int = 0
    let store = CartStore()
    let cart = Cart()

    nonisolated func refresh() {
        total = cart.total()
    }

    func pay(with method: PaymentMethod) {
        let items = store.items()
        total = items.reduce(0) { $0 + $1.price }
    }
}
