import XCTest
@testable import AeroBenchKit

final class GroundShareTests: XCTestCase {
    func testTheShareMatchesTheEngine() {
        // engine estimate.ground_share: 0.8 / (1 + (gain / 1.6)^3)
        XCTAssertEqual(GroundEffect.share(gain: 0), 0.8, accuracy: 1e-12)
        XCTAssertEqual(GroundEffect.share(gain: 1.6), 0.4, accuracy: 1e-12)
        XCTAssertEqual(GroundEffect.share(gain: 12.34), 0.8 / (1 + pow(12.34 / 1.6, 3)), accuracy: 1e-12)
    }

    func testTheImageGainIsCutToWhatRansHolds() {
        // The stalled study wing at 30 mm: the image method 12 times free air.
        let free = PanelSolution(alphaDeg: 0, speed: [], cp: [], cl: [-2, -0.5], cd: [0, 0], cm: [0.1, 0.05])
        let ground = PanelSolution(alphaDeg: 0, speed: [], cp: [], cl: [-30, -2.5], cd: [0, 0], cm: [1, 0.2])
        let fixed = ground.groundCorrected(free: free)
        let s = GroundEffect.share(gain: 32.5 / 2.5 - 1)
        XCTAssertEqual(fixed.cl[0], -2 + s * -28, accuracy: 1e-12)
        XCTAssertEqual(fixed.clTotal / free.clTotal, 1 + s * 12, accuracy: 1e-12)
        XCTAssertLessThan(fixed.clTotal / free.clTotal, 1.8)
    }
}
