@testable import Features
import XCTest

final class CheckoutTests: XCTestCase {
    func testTotal() {
        let vm = CheckoutViewModel()
        vm.refresh()
        XCTAssertEqual(vm.total, 0)
    }
}
