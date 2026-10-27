import Foundation

/// One line of engine stdout. The engine prints one JSON object per line.
public enum EngineEvent: Equatable, Sendable {
    case progress(pct: Double, msg: String)
    case log(level: String, msg: String)
    case result(path: String)
    case error(msg: String, detail: String?)
    /// A line that is not a recognised event, kept so nothing is silently lost.
    case unparsed(String)

    public static func parse(_ line: String) -> EngineEvent {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String
        else { return .unparsed(line) }

        switch type {
        case "progress":
            guard let pct = (obj["pct"] as? NSNumber)?.doubleValue else { return .unparsed(line) }
            return .progress(pct: pct, msg: obj["msg"] as? String ?? "")
        case "log":
            return .log(level: obj["level"] as? String ?? "info", msg: obj["msg"] as? String ?? "")
        case "result":
            guard let path = obj["path"] as? String else { return .unparsed(line) }
            return .result(path: path)
        case "error":
            return .error(msg: obj["msg"] as? String ?? "unknown engine error", detail: obj["detail"] as? String)
        default:
            return .unparsed(line)
        }
    }
}
