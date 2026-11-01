import Core
import Collections

public final class PaymentClient {
    private var queue: Deque<Item> = []

    public init() {}

    public func charge(_ amount: Decimal, method: PaymentMethod) throws(PaymentError) {
        if amount <= 0 { throw PaymentError.declined }
    }
}
