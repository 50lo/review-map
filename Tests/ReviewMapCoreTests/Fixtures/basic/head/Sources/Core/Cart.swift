public final class Cart {
    private(set) var items: [Item] = []
    let maxItems = 50

    public init() {}

    public func add(_ item: Item) {
        items.append(item)
    }

    public func total() -> Decimal {
        items.reduce(0) { $0 + $1.price }
    }

    func price(for item: Item) -> Decimal { item.price }
    func price(for items: [Item]) -> Int { items.reduce(0) { $0 + $1.price } }

    public func format(_ value: Int) -> String {
        return "\(value)"
    }
}
