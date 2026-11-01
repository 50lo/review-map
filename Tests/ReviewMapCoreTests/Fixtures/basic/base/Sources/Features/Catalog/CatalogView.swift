import Core

struct CatalogView {
    var items: [Item]

    func title() -> String { "Catalog (\(items.count))" }
}
