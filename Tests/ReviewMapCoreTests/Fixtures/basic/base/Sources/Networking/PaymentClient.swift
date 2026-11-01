import Core
import Collections

public final class PaymentClient {
    private var queue: Deque<Item> = []

    public init() {}

    func charge(_ amount: Int, method: PaymentMethod) throws {
        if amount <= 0 { throw PaymentError.declined }
    }
}

open class Transport {
    public init() {}

    open func send(_ data: String) -> Bool {
        true
    }
}

final class LoggingTransport: Transport {
    override func send(_ data: String) -> Bool {
        super.send(data)
    }
}
