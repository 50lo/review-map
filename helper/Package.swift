// swift-tools-version:5.10
import PackageDescription

// The Swift helper that the Review Map app owns: it parses Swift with SwiftSyntax and reads the compiler's
// index store with IndexStoreDB, in batches, for the Rust core. See docs/rebuild-phase1-proposal.md.
let package = Package(
    name: "ReviewMapSwiftHelper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "reviewmap-swift-helper", targets: ["reviewmap-swift-helper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "602.0.0"),
        // swift-6.2.4-RELEASE, the revision the prototype reads index stores with.
        .package(url: "https://github.com/swiftlang/indexstore-db.git", revision: "cf29ef4e5e5243a3b6f518d72c6e527b5290375a"),
    ],
    targets: [
        .executableTarget(
            name: "reviewmap-swift-helper",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "IndexStoreDB", package: "indexstore-db"),
            ],
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        ),
    ]
)
