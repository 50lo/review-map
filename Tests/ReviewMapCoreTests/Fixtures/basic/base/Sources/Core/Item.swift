import Foundation

public struct Item: Codable, Equatable {
    public var id: String
    public var name: String
    public var price: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case price
    }
}
