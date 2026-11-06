import XCTest
@testable import AeroBenchKit

final class UpdateCheckTests: XCTestCase {
    func testAStampedBuildCountsEverythingSinceItsCommit() {
        XCTAssertEqual(UpdateCheck.revListArgs(builtCommit: "abc", builtDate: Date(), online: true),
                       ["--count", "HEAD", "@{u}", "^abc"])
        XCTAssertEqual(UpdateCheck.revListArgs(builtCommit: "abc", builtDate: nil, online: false), ["--count", "HEAD", "^abc"])
    }

    func testAnUnstampedBuildCountsCommitsMadeAfterIt() {
        // The 04:04 rebuild had lost its stamp and the checkout was ahead of GitHub: it read 0.
        let built = Date(timeIntervalSince1970: 1_793_937_876)
        XCTAssertEqual(UpdateCheck.revListArgs(builtCommit: nil, builtDate: built, online: true),
                       ["--count", "--since=@1793937876", "HEAD", "@{u}"])
    }

    func testWithNothingToGoOnOnlyGitHubCounts() {
        XCTAssertEqual(UpdateCheck.revListArgs(builtCommit: nil, builtDate: nil, online: true), ["--count", "@{u}", "^HEAD"])
        XCTAssertNil(UpdateCheck.revListArgs(builtCommit: nil, builtDate: nil, online: false))
    }
}
