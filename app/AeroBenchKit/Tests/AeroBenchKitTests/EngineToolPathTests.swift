import XCTest
@testable import AeroBenchKit

final class EngineToolPathTests: XCTestCase {
    func testHomebrewIsAddedToABareFinderPath() {
        XCTAssertEqual(EngineProcess.toolPath("/usr/bin:/bin:/usr/sbin:/sbin"),
                       "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin")
    }

    func testAnExistingPathKeepsItsOrder() {
        XCTAssertEqual(EngineProcess.toolPath("/opt/homebrew/bin:/usr/bin"), "/opt/homebrew/bin:/usr/bin:/usr/local/bin")
        XCTAssertEqual(EngineProcess.toolPath(nil), "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin")
    }
}
