// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ReviewMap",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "reviewmap", targets: ["reviewmap"]),
    ],
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder.git", exact: "0.4.5"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "602.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/tuist/XcodeProj.git", exact: "9.17.6"),
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
        .package(url: "https://github.com/kylef/PathKit.git", exact: "1.0.1"),
        // swift-6.2.4-RELEASE; index mode reads the compiler's index store with it.
        .package(url: "https://github.com/swiftlang/indexstore-db.git", revision: "cf29ef4e5e5243a3b6f518d72c6e527b5290375a"),
        // Tree-sitter's C library and the grammars of the languages parsed with it.
        .package(url: "https://github.com/tree-sitter/tree-sitter.git", exact: "0.25.10"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript.git", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go.git", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust.git", exact: "0.24.2"),
        .package(url: "https://github.com/fwcd/tree-sitter-kotlin.git", revision: "d6af96d2e23ef0a8ff5ab512864378cf08fba311"),
    ],
    targets: [
        .executableTarget(
            name: "reviewmap",
            dependencies: [
                "ReviewMapCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "ReviewMapCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "XcodeProj", package: "XcodeProj"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "PathKit", package: "PathKit"),
                .product(name: "IndexStoreDB", package: "indexstore-db"),
                .product(name: "TreeSitter", package: "tree-sitter"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                .product(name: "TreeSitterKotlin", package: "tree-sitter-kotlin"),
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
            ]
        ),
        .testTarget(
            name: "ReviewMapCoreTests",
            dependencies: ["ReviewMapCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
