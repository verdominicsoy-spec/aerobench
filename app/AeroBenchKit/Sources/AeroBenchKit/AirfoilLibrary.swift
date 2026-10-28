import Foundation
import SQLite3

/// The airfoil index the engine builds (data/airfoils/index.sqlite), read
/// in full: about 1,900 sections at 161 points each loads in a fraction of
/// a second.
public enum AirfoilLibrary {
    public enum LoadError: LocalizedError {
        case missing(URL)
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .missing(let url): return "No airfoil library at \(url.path) yet."
            case .unreadable(let why): return "The airfoil library could not be read: \(why)"
            }
        }
    }

    /// <data>/airfoils/index.sqlite next to the engine folder.
    public static func indexURL(engineDirectory: URL) -> URL {
        engineDirectory.deletingLastPathComponent().appendingPathComponent("data/airfoils/index.sqlite")
    }

    public static func load(_ url: URL) throws -> [Airfoil] {
        guard FileManager.default.fileExists(atPath: url.path) else { throw LoadError.missing(url) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            defer { sqlite3_close(db) }
            throw LoadError.unreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_close(db) }
        let sql = "SELECT key, name, family, source, thickness, thickness_x, camber, camber_x, te_thickness, coords FROM airfoils ORDER BY source, name"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw LoadError.unreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
        var out: [Airfoil] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let points = try? JSONDecoder().decode([[Double]].self, from: Data(text(9).utf8)) else { continue }
            let coords = points.compactMap { $0.count == 2 ? SIMD2($0[0], $0[1]) : nil }
            guard coords.count >= 6 else { continue }
            out.append(Airfoil(key: text(0), name: text(1), family: text(2), source: text(3),
                               thickness: sqlite3_column_double(stmt, 4), thicknessX: sqlite3_column_double(stmt, 5),
                               camber: sqlite3_column_double(stmt, 6), camberX: sqlite3_column_double(stmt, 7),
                               teThickness: sqlite3_column_double(stmt, 8), coords: coords))
        }
        return out
    }

    /// Filters for the library panel.
    public struct Filter: Equatable, Sendable {
        public var text = ""
        public var family: String?  // nil: any
        public var source: String?  // nil: any; "naca", "uiuc", "mine"
        public var thickness: ClosedRange<Double> = 0...1
        public var camber: ClosedRange<Double> = -1...1
        public var favouritesOnly = false

        public init() {}

        public func matches(_ a: Airfoil, favourites: Set<String>) -> Bool {
            if favouritesOnly && !favourites.contains(a.key) { return false }
            if let family, a.family != family { return false }
            if let source, a.source != source { return false }
            if !thickness.contains(a.thickness) || !camber.contains(a.camber) { return false }
            let q = text.trimmingCharacters(in: .whitespaces).lowercased()
            if q.isEmpty { return true }
            let compact = q.replacingOccurrences(of: " ", with: "")
            return a.name.lowercased().contains(q) || a.name.lowercased().replacingOccurrences(of: " ", with: "").contains(compact)
                || a.key.lowercased().contains(compact)
        }
    }
}
