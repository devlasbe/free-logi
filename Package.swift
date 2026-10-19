// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FreeLogi",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "FreeLogi"),
        .testTarget(name: "FreeLogiTests", dependencies: ["FreeLogi"]),
    ]
)
