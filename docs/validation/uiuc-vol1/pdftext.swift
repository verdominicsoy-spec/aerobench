import Foundation
import PDFKit
let doc = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))!
var out = ""
for i in 0..<doc.pageCount { out += "\n=====PAGE \(i + 1)=====\n" + (doc.page(at: i)?.string ?? "") }
try! out.write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
print(doc.pageCount)
