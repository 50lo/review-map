import Core

actor PriceCache {
    private var cache: [String: Decimal] = [:]

    func price(for item: Item) -> Decimal {
        if let cached = cache[item.id] { return cached }
        cache[item.id] = item.price
        return item.price
    }
}
