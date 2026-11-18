public struct Config {
    public var limit = 10

    public init() {}
}

/// A conformer that does not throw still satisfies a throwing requirement, so head builds.
public protocol Source {
    func fetch() throws -> Int
}
