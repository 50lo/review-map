public enum PaymentMethod: String, Codable {
    case card
    case paypal
}

public enum PaymentError: Error {
    case declined
}
