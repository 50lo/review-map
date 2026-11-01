import Core
import Collections

public final class PaymentClient {
    private var queue: Deque<Item> = []

    public init() {}

    func charge(_ amount: Int, method: PaymentMethod) throws {
        if amount <= 0 { throw PaymentError.declined }
    }
}
