import XCTest
@testable import AeroBenchKit

final class AirfoilCSVTests: XCTestCase {
    /// NACA 2412 in Selig order, scaled so x runs exactly 0 to 1 (its upper
    /// TE sits just past 1): the answer every file should give.
    private let foil: [SIMD2<Double>] = {
        let raw = Airfoil.naca4("2412", points: 41)!.coords
        let lo = raw.map(\.x).min()!, c = raw.map(\.x).max()! - lo
        return raw.map { SIMD2(($0.x - lo) / c, $0.y / c) }
    }()

    private func csv(_ points: some Sequence<SIMD2<Double>>, chord: Double = 1, separator: String = ",", header: String? = nil) -> String {
        ((header.map { [$0] } ?? []) + points.map { "\($0.x * chord)\(separator)\($0.y * chord)" }).joined(separator: "\n")
    }

    private func assertFoil(_ got: [SIMD2<Double>], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.count, foil.count, file: file, line: line)
        for (a, b) in zip(got, foil) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-9, file: file, line: line)
        }
    }

    func testSeligWithAndWithoutHeader() throws {
        assertFoil(try AirfoilCSV.parse(csv(foil)))
        assertFoil(try AirfoilCSV.parse(csv(foil, header: "x,y")))
        assertFoil(try AirfoilCSV.parse(csv(foil, header: "\u{FEFF}\"x (mm)\",\"y (mm)\"")))
    }

    func testSeparators() throws {
        assertFoil(try AirfoilCSV.parse(csv(foil, separator: ";", header: "x;y")))
        assertFoil(try AirfoilCSV.parse(csv(foil, separator: "\t")))
        assertFoil(try AirfoilCSV.parse(csv(foil, separator: ", ")))
        // Decimal commas only when the separator is not a comma.
        let european = csv(foil, separator: ";").replacingOccurrences(of: ".", with: ",")
        assertFoil(try AirfoilCSV.parse(european))
    }

    func testCommaIsNeverADecimalMark() throws {
        // "75,4" is two columns, 75 and 4, never 754 or 75.4.
        let got = try AirfoilCSV.parse("100,0\n75,4\n25,6\n0,0\n25,-4\n75,-2\n100,0")
        XCTAssertEqual(got.count, 7)
        XCTAssertEqual(got[1], SIMD2(0.75, 0.04))
        XCTAssertEqual(got[3], SIMD2(0, 0))
    }

    func testScalesToUnitChord() throws {
        assertFoil(try AirfoilCSV.parse(csv(foil, chord: 250, header: "x_mm,y_mm")))
        let shifted = foil.map { SIMD2($0.x * 300 + 40, $0.y * 300) }
        assertFoil(try AirfoilCSV.parse(csv(shifted)))
    }

    func testSplitSurfaces() throws {
        let le = foil.indices.min { foil[$0].x < foil[$1].x }!
        let upper = Array(foil[...le].reversed()), lower = Array(foil[le...])  // both from the LE
        // A blank line or label rows between them, or nothing at all.
        assertFoil(try AirfoilCSV.parse(csv(upper, chord: 200) + "\n\n" + csv(lower, chord: 200)))
        assertFoil(try AirfoilCSV.parse("upper\n" + csv(upper) + "\nlower\n" + csv(lower)))
        assertFoil(try AirfoilCSV.parse(csv(upper) + "\n" + csv(lower)))
        // Lower surface first, and both from the trailing edge.
        assertFoil(try AirfoilCSV.parse(csv(lower) + "\n\n" + csv(upper)))
        assertFoil(try AirfoilCSV.parse(csv(upper.reversed()) + "\n" + csv(lower.reversed())))
        // A loop from the leading edge is refused: its open TE points could go to either surface.
        XCTAssertThrowsError(try AirfoilCSV.parse(csv(upper + lower.reversed())))
        // Selig order with the lower surface first.
        assertFoil(try AirfoilCSV.parse(csv(foil.reversed())))
    }

    func testRejectsBadFiles() {
        func error(_ text: String) -> AirfoilCSV.ParseError? {
            do { _ = try AirfoilCSV.parse(text); return nil } catch { return error as? AirfoilCSV.ParseError }
        }
        XCTAssertEqual(error("x,y\n1,0\n0.5,0.1\n0,0\n0.5,-0.1\n1,0"), .tooFewPoints(5))
        XCTAssertEqual(error(""), .tooFewPoints(0))
        XCTAssertEqual(error("x,y\n1,0\n0.5,abc\n" + csv(foil)), .notANumber(line: 3, field: "abc"))
        XCTAssertEqual(error(csv(foil) + "\n0.5,inf"), .notANumber(line: foil.count + 1, field: "inf"))
        XCTAssertEqual(error("x,y\n1\n" + csv(foil)), .oneColumn(line: 2))
        XCTAssertEqual(error(csv(foil) + "\n\n" + csv(foil) + "\n\n" + csv(foil)), .tooManyBlocks(3))
        XCTAssertEqual(error((0..<10).map { "\($0 % 3),\($0)" }.joined(separator: "\n")), .notAnAirfoil)
        XCTAssertEqual(error((0..<10).map { "2,\($0)" }.joined(separator: "\n")), .zeroChord)
        XCTAssertNotNil(AirfoilCSV.ParseError.notANumber(line: 3, field: "abc").errorDescription)
    }

    func testDatRoundTrip() throws {
        let dat = AirfoilCSV.dat(name: "my foil", points: try AirfoilCSV.parse(csv(foil, chord: 250)))
        let lines = dat.split(separator: "\n")
        XCTAssertEqual(lines.first, "my foil")
        XCTAssertEqual(lines.count, foil.count + 1)
        XCTAssertFalse(dat.contains(","))
    }
}
