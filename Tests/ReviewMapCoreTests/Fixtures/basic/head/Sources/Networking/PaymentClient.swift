import Core
import Collections

public final class PaymentClient {
    private var queue: Deque<Item> = []

    public init() {}

    public func charge(_ amount: Decimal, method: PaymentMethod) throws(PaymentError) {
        if amount <= 0 { throw PaymentError.declined }
    }
}

open class Transport {
    public init() {}

    open func send(_ data: String) -> Bool {
        if data.isEmpty { return false }
        return true
    }
}

final class LoggingTransport: Transport {
    override func send(_ data: String) -> Bool {
        super.send(data)
    }
}
