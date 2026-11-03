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
