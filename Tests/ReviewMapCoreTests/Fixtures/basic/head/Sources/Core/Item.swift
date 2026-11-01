import Foundation

public struct Item: Codable, Equatable {
    public var id: String
    public var name: String
    public var price: Decimal
    public var currency: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case price
        case currency
    }
}
