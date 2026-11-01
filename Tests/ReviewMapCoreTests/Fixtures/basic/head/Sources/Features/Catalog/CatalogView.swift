import Core

struct CatalogView {
    var items: [Item]

    // Shown in the navigation bar.
    func title() -> String {
        "Catalog (\(items.count))"
    }
}
