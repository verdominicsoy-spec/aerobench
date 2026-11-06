import XCTest
@testable import AeroBenchKit

final class SU2MeshTests: XCTestCase {
    func testParsesCellsPointsAndWalls() throws {
        let text = """
        NDIME= 2
        NELEM= 2
        5 0 1 2 0
        9 1 3 4 2 1
        NPOIN= 5
        0 0 0
        1 0 1
        0 1 2
        2 0 3
        2 1 4
        NMARK= 2
        MARKER_TAG= wall_0
        MARKER_ELEMS= 1
        3 0 1
        MARKER_TAG= farfield
        MARKER_ELEMS= 1
        3 3 4
        """
        let m = try SU2Mesh.parse(text)
        XCTAssertEqual(m.points.count, 5)
        XCTAssertEqual(m.cells, [[0, 1, 2], [1, 3, 4, 2]])
        XCTAssertEqual(m.wallPoints, [0, 1])
        XCTAssertEqual(m.wallBounds?.max, SIMD2(1, 0))
    }
}
