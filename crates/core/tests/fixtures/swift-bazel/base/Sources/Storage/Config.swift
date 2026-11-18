public struct Config {
    public var limit = 10

    public init() {}
}

public protocol Source {
    func fetch() -> Int
}
