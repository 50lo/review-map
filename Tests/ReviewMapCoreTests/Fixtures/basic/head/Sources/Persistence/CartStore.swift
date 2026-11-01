import Core

public final class CartStore: CartRepository {
    private var storage: [Item] = []

    public init() {}

    public func items() async -> [Item] { storage }
    public func add(_ item: Item) throws { storage.append(item) }
    public func clear() async throws { storage.removeAll() }
}
