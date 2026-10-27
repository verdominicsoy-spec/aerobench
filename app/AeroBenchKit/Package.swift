// swift-tools-version:6.0
import PackageDescription

// Non-UI core of AeroBench: engine job runner, event parsing, project and job
// files. Kept in a package so it can be tested with `swift test`.
let package = Package(
    name: "AeroBenchKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AeroBenchKit", targets: ["AeroBenchKit"]),
    ],
    targets: [
        .target(name: "AeroBenchKit"),
        .testTarget(name: "AeroBenchKitTests", dependencies: ["AeroBenchKit"]),
    ],
    swiftLanguageModes: [.v5]
)
