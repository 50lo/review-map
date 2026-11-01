public protocol CartRepository {
    func items() -> [Item]
    func add(_ item: Item) throws
}
