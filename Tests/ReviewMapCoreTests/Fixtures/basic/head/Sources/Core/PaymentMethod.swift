public enum PaymentMethod: String, Codable {
    case card
    case paypal
    case applePay
}

public enum PaymentError: Error {
    case declined
}
