import XCTest
import simd
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

    /// Wing Lab's own "Export Wing Points" layout (element,index,x_mm,y_mm), as in
    /// a three-element S1223 wing: one section per element, named by the column.
    func testMultiElementWingExport() throws {
        let wing = Wing(elements: [
            WingElement(airfoil: Airfoil.naca4("4412")!, chord: 0.48, angle: 8, leadingEdge: .zero, inverted: true),
            WingElement(airfoil: Airfoil.naca4("4412")!, chord: 0.16, angle: 19, leadingEdge: SIMD2(0.47, 0.03), inverted: true),
            WingElement(airfoil: Airfoil.naca4("4412")!, chord: 0.08, angle: 32, leadingEdge: SIMD2(0.62, 0.09), inverted: true),
        ])
        let text = wing.csvFile()
        XCTAssertTrue(text.hasPrefix("element,index,x_mm,y_mm\nMain,0,"))
        let elements = try AirfoilCSV.parseElements(text)
        XCTAssertEqual(elements.map(\.name), ["Main", "Flap 1", "Flap 2"])
        for (e, placed) in zip(elements, wing.elements.map { $0.placed() }) {
            // The same outline, scaled to unit x extent, in Selig order either way round.
            let lo = placed.map(\.x).min()!, c = placed.map(\.x).max()! - lo
            let want = placed.map { SIMD2(($0.x - lo) / c, $0.y / c) }
            XCTAssertEqual(e.points.count, want.count)
            let forward = zip(e.points, want).allSatisfy { simd_distance($0, $1) < 1e-5 }
            let backward = zip(e.points, want.reversed()).allSatisfy { simd_distance($0, $1) < 1e-5 }
            XCTAssertTrue(forward || backward, "\(e.name ?? "")")
        }
        XCTAssertThrowsError(try AirfoilCSV.parse(text)) { XCTAssertEqual($0 as? AirfoilCSV.ParseError, .severalElements(3)) }

        // The same without the header, and with a label row and header before each element.
        let bare = text.split(separator: "\n").dropFirst().joined(separator: "\n")
        XCTAssertEqual(try AirfoilCSV.parseElements(bare), elements)
        let labelled = "Main\nx,y\n" + csv(foil) + "\nFlap 1\nx,y\n" + csv(foil, chord: 0.3)
        let two = try AirfoilCSV.parseElements(labelled)
        XCTAssertEqual(two.map(\.name), ["Main", "Flap 1"])
        assertFoil(two[1].points)
        // A bad element is named in the message.
        let short = labelled + "\nFlap 2\n0.1,0.2\n0.3,0.4"
        XCTAssertThrowsError(try AirfoilCSV.parseElements(short)) {
            XCTAssertEqual($0 as? AirfoilCSV.ParseError, .inElement("Flap 2", .tooFewPoints(2)))
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription, "Flap 2: Only 2 x,y rows: an airfoil needs at least six.")
        }
    }

    func testDatRoundTrip() throws {
        let dat = AirfoilCSV.dat(name: "my foil", points: try AirfoilCSV.parse(csv(foil, chord: 250)))
        let lines = dat.split(separator: "\n")
        XCTAssertEqual(lines.first, "my foil")
        XCTAssertEqual(lines.count, foil.count + 1)
        XCTAssertFalse(dat.contains(","))
    }
}
