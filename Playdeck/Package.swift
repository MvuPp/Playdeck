// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Playdeck",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PlaydeckCore"),
        .executableTarget(name: "Playdeck", dependencies: ["PlaydeckCore"]),
        .testTarget(name: "PlaydeckCoreTests", dependencies: ["PlaydeckCore"], exclude: ["Fixtures"]),
    ]
)
