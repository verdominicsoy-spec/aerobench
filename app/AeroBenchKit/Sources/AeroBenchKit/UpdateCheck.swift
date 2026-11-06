import Foundation

/// What `git rev-list --count` is asked to count as updates since this build.
public enum UpdateCheck {
    /// A build stamped with its commit counts every commit since it, on GitHub or
    /// only here (committed but not rebuilt). An unstamped build (Xcode, or a
    /// rebuild without AeroBench.command) counts the commits made after it was
    /// built, by its executable's date: without that, a checkout ahead of GitHub
    /// read as up to date however old the build was. Offline, only local ones.
    /// Nil when there is nothing to compare.
    public static func revListArgs(builtCommit: String?, builtDate: Date?, online: Bool) -> [String]? {
        let upstream = online ? ["@{u}"] : []
        if let c = builtCommit { return ["--count", "HEAD"] + upstream + ["^" + c] }
        if let d = builtDate { return ["--count", "--since=@\(Int(d.timeIntervalSince1970))", "HEAD"] + upstream }
        return online ? ["--count", "@{u}", "^HEAD"] : nil
    }
}
