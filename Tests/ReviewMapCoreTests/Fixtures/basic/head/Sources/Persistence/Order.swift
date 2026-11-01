import Foundation
import SwiftData

@Model
final class Order {
    var id: UUID
    var total: Decimal
    var placedAt: Date

    init(id: UUID, total: Decimal, placedAt: Date) {
        self.id = id
        self.total = total
        self.placedAt = placedAt
    }
}
