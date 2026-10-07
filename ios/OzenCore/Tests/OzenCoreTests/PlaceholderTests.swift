import XCTest
@testable import OzenCore

final class PlaceholderTests: XCTestCase {
    func testModelFiles() { XCTAssertEqual(ModelFiles.all.count, 4) }
}
