// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Shop",
    platforms: [.iOS(.v17), .macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
    ],
    targets: [
        .target(name: "Core"),
        .target(name: "Networking", dependencies: ["Core", .product(name: "Collections", package: "swift-collections")]),
        .target(name: "Persistence", dependencies: ["Core"]),
        .target(name: "Features", dependencies: ["Core", "Persistence"]),
        .testTarget(name: "FeaturesTests", dependencies: ["Features"]),
    ]
)
