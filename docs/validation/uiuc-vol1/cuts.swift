import Foundation
import PDFKit
// Each page's text read in vertical strips cut at the given x positions.
let doc = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))!
let first = Int(CommandLine.arguments[3])!, last = Int(CommandLine.arguments[4])!
let cuts = CommandLine.arguments[5].split(separator: ",").map { CGFloat(Double($0)!) }
var out = ""
for i in (first - 1)..<last {
    guard let page = doc.page(at: i) else { continue }
    let b = page.bounds(for: .mediaBox)
    let xs = [b.minX] + cuts + [b.maxX]
    out += "\n=====PAGE \(i + 1)=====\n"
    for k in 0..<(xs.count - 1) {
        let r = CGRect(x: xs[k], y: b.minY, width: xs[k + 1] - xs[k], height: b.height)
        out += "-----COL \(k + 1)-----\n" + (page.selection(for: r)?.string ?? "") + "\n"
    }
}
try! out.write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
