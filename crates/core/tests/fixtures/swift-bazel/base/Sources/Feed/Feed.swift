import Cache
import Settings
import Storage

public struct Feed {
    let store: Store
    let cache = Cache()

    public init(store: Store) {
        self.store = store
    }

    public func items() -> [Item] {
        store.load()
    }

    public func cached() -> [String] {
        cache.load()
    }

    public func theme() -> String {
        Settings.Config().theme
    }
}

final class LocalSource: Storage.Source {
    func fetch() -> Int { 1 }
}

final class ThemeSource: Settings.Source {
    func fetch() -> Int { 2 }
}
