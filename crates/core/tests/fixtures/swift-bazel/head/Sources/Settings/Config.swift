public struct Config {
    public var theme = "light"

    public init() {}
}

public protocol Source {
    func fetch() -> Int
}
