// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PodmanStatusbar",
    platforms: [.macOS(.v13)],
    products: [.library(name: "PodmanCore", targets: ["PodmanCore"]), .executable(name: "PodmanStatusbar", targets: ["PodmanStatusbar"])],
    targets: [
        .target(name: "PodmanCore"),
        .executableTarget(name: "PodmanStatusbar", dependencies: ["PodmanCore"]),
        .testTarget(name: "PodmanCoreTests", dependencies: ["PodmanCore"])
    ]
)
