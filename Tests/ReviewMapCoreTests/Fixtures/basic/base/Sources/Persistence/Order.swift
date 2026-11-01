import Foundation

final class Order {
    var id: UUID
    var total: Int

    init(id: UUID, total: Int) {
        self.id = id
        self.total = total
    }
}
