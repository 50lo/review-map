import Combine
import Core
import Networking

@MainActor
final class CheckoutViewModel: ObservableObject {
    @Published var total: Decimal = 0
    let client = PaymentClient()
    let logger = Logger()
    let cart = Cart()

    func refresh() {
        total = cart.total()
    }

    func pay(with method: PaymentMethod) throws {
        try client.charge(total, method: method)
    }
}
