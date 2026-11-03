// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Indexed",
    targets: [
        .target(name: "Storage"),
        .target(name: "Cache"),
        .target(name: "Settings"),
        .target(name: "Feed", dependencies: ["Storage", "Cache", "Settings"]),
    ]
)
