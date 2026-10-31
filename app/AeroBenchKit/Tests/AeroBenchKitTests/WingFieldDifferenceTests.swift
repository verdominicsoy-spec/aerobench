import XCTest
@testable import AeroBenchKit

final class WingFieldDifferenceTests: XCTestCase {
    /// A 4 x 2 field of Cp over [0, 4] x [0, 2] m; NaN marks no flow.
    private func field(_ cp: [Float]) throws -> WingField {
        let header = #"{"nx": 4, "ny": 2, "window": [0, 0, 4, 2], "scalars": [{"key": "cp", "name": "Cp", "min": -1, "max": 1, "range": [-1, 1], "colormap": []}], "streamlines": []}"#
        let binary = cp.withUnsafeBufferPointer { Data(buffer: $0) }
        return try WingField(json: Data(header.utf8), binary: binary)
    }

    func testChangeIsThisRunMinusTheOtherOnTheSameGrid() throws {
        let a = try field([0, 0, 0, 0, 0, 0, 0, .nan])
        let b = try field([-2, -1, 0, 1, 1, 1, 1, 1])
        let (px, limit) = b.difference("cp", from: a)
        XCTAssertEqual(px.count, 4 * 2 * 4)
        XCTAssertEqual(limit, 2, accuracy: 1e-9)  // the largest change, few enough cells that it is the 95th percentile
        // Rows come out top first: the bottom row (j = 0) is the image's second row.
        func pixel(_ i: Int, _ j: Int) -> [UInt8] { let o = ((1 - j) * 4 + i) * 4; return Array(px[o..<o + 4]) }
        XCTAssertEqual(pixel(0, 0), [48, 96, 188, 255])  // fell by the limit: full blue
        XCTAssertEqual(pixel(2, 0), [255, 255, 255, 255])  // held: white
        XCTAssertEqual(pixel(3, 1)[3], 0)  // no flow in the first run: transparent
    }

    func testDivergingEndsAndMiddle() {
        XCTAssertEqual(WingField.diverging(0).0, 255)
        XCTAssertEqual(WingField.diverging(5).0, WingField.diverging(1).0)  // clamped
        XCTAssertLessThan(WingField.diverging(-1).0, WingField.diverging(-1).2)  // blue
        XCTAssertGreaterThan(WingField.diverging(1).0, WingField.diverging(1).2)  // red
    }
}
