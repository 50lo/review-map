public struct Item: Equatable {
    public let id: Int

    public init(id: Int) {
        self.id = id
    }
}

public final class Store {
    public init() {}

    public func load() -> [Item] {
        [Item(id: 1)]
    }
}
