// swift-tools-version:6.0
import PackageDescription

// AeroBenchKit: non-UI core (engine job runner, event parsing, project and
// job files, mesh model and loaders). AeroBench3D: the shared 3D viewer core
// used by the CAD and Flow Field tools. Kept in a package so both can be
// tested with `swift test`.
let package = Package(
    name: "AeroBenchKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AeroBenchKit", targets: ["AeroBenchKit"]),
        .library(name: "AeroBench3D", targets: ["AeroBench3D"]),
    ],
    targets: [
        .target(name: "AeroBenchKit"),
        .target(name: "AeroBench3D", dependencies: ["AeroBenchKit"]),
        .testTarget(name: "AeroBenchKitTests", dependencies: ["AeroBenchKit", "AeroBench3D"]),
    ],
    swiftLanguageModes: [.v5]
)
