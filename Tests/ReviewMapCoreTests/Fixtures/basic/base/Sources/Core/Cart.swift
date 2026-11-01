public final class Cart {
    private(set) var items: [Item] = []
    let maxItems = 50

    public init() {}

    public func add(_ item: Item) {
        guard items.count < maxItems else { return }
        items.append(item)
    }

    public func total() -> Int {
        items.reduce(0) { $0 + $1.price }
    }

    func price(for item: Item) -> Int { item.price }
    func price(for items: [Item]) -> Int { items.reduce(0) { $0 + $1.price } }

    func format(_ value: Int) -> String {
        return "\(value)"
    }
}

func rounded(_ value: Decimal) -> Decimal {
    value
}
