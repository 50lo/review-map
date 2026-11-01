public protocol CartRepository {
    func items() async -> [Item]
    func add(_ item: Item) throws
    func clear() async throws
}
