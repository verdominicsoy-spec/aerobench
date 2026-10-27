import XCTest
@testable import AeroBenchKit

final class EngineEventTests: XCTestCase {
    func testParsesEveryEventType() {
        XCTAssertEqual(EngineEvent.parse(#"{"type":"progress","pct":42,"msg":"meshing"}"#), .progress(pct: 42, msg: "meshing"))
        XCTAssertEqual(EngineEvent.parse(#"{"type":"log","level":"warning","msg":"hm"}"#), .log(level: "warning", msg: "hm"))
        XCTAssertEqual(EngineEvent.parse(#"{"type":"result","path":"result.json"}"#), .result(path: "result.json"))
        XCTAssertEqual(EngineEvent.parse(#"{"type":"error","msg":"gmsh failed","detail":"..."}"#), .error(msg: "gmsh failed", detail: "..."))
        XCTAssertEqual(EngineEvent.parse(#"{"type":"error","msg":"no detail"}"#), .error(msg: "no detail", detail: nil))
    }

    func testKeepsAnythingElseAsUnparsed() {
        XCTAssertEqual(EngineEvent.parse("Traceback (most recent call last):"), .unparsed("Traceback (most recent call last):"))
        XCTAssertEqual(EngineEvent.parse(#"{"type":"mystery"}"#), .unparsed(#"{"type":"mystery"}"#))
        XCTAssertEqual(EngineEvent.parse(#"{"type":"progress"}"#), .unparsed(#"{"type":"progress"}"#))
        XCTAssertEqual(EngineEvent.parse("[1,2]"), .unparsed("[1,2]"))
    }
}
