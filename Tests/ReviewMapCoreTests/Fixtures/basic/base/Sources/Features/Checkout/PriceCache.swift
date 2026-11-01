import Core

final class PriceCache {
    private var cache: [String: Int] = [:]

    func price(for item: Item) -> Int {
        if let cached = cache[item.id] { return cached }
        cache[item.id] = item.price
        return item.price
    }
}
