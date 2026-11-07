import XCTest
@testable import AeroBenchKit

final class NumberTextTests: XCTestCase {
    func testReadsPlainNumbers() {
        XCTAssertEqual(try NumberText.parse(" 20 ").get(), 20)
        XCTAssertEqual(try NumberText.parse("1.184").get(), 1.184)
        XCTAssertEqual(try NumberText.parse("−2.5").get(), -2.5)
        XCTAssertEqual(try NumberText.parse("1.81e-5").get(), 1.81e-5)
    }

    func testAnEmptyBoxIsNil() {
        XCTAssertEqual(try NumberText.parse("").get(), nil)
    }

    func testRefusesThousandsCommasAndWords() {
        XCTAssertThrowsError(try NumberText.parse("1,184").get())
        XCTAssertThrowsError(try NumberText.parse("Main").get())
        XCTAssertThrowsError(try NumberText.parse("inf").get())
    }

    func testShowsWithoutGroupingAndKeepsSmallValues() {
        XCTAssertEqual(NumberText.format(1184, digits: 4), "1184")
        XCTAssertEqual(NumberText.format(15, digits: 4), "15")
        XCTAssertEqual(NumberText.format(250.123, digits: 1), "250.1")
        XCTAssertEqual(NumberText.format(1.81e-5, digits: 4), "0.0000181")
    }

    func testWithinSaysTheRange() {
        let check = NumberText.within(0.3...2, "kg/m³")
        XCTAssertNil(check(1.184))
        XCTAssertEqual(check(1184), "Expected 0.3 to 2 kg/m³")
    }
}
