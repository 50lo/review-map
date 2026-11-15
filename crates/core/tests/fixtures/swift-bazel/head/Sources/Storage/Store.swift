public struct Item: Equatable {
    public let id: Int

    public init(id: Int) {
        self.id = id
    }
}

public final class Store {
    public init() {}

    public func load() -> [Item] {
        guard !isEmpty else { return [] }
        return [Item(id: 1), Item(id: 2)]
    }

    var isEmpty: Bool { false }
}
