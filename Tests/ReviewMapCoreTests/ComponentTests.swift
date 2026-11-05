import Foundation
import XCTest
@testable import ReviewMapCore

final class ComponentTests: XCTestCase {
    func testNestedFixtureTargetsInheritTestContext() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/basic/base", withExtension: nil))
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("rm-components-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        for (packagePath, isFixture) in [("Tests/HostTests/Fixtures/basic", true), ("Packages/Shop", false), ("", false)] {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let package = root.appendingPathComponent(packagePath)
            try fm.createDirectory(at: package, withIntermediateDirectories: true)
            for item in try fm.contentsOfDirectory(atPath: fixture.path) {
                try fm.copyItem(at: fixture.appendingPathComponent(item), to: package.appendingPathComponent(item))
            }
            if isFixture {
                try """
                import PackageDescription
                let package = Package(name: "Host", targets: [
                    .testTarget(name: "HostTests", resources: [.copy("Fixtures")])
                ])
                """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            }

            let files = ComponentBuilder.findFiles(root: root.path, where: { $0.hasSuffix(".swift") && $0 != "Package.swift" })
            var config = Config()
            config.split = Config.Split(threshold: 2, maxDepth: 3)
            let layout = ComponentBuilder.build(root: root.path, files: files, languages: Languages.all,
                                                config: &config, options: AnalyzeOptions(repo: root.path, base: "main", head: "main"))
            let features = try XCTUnwrap(layout.components["spm:Features"])
            XCTAssertEqual(features.isTest, isFixture, packagePath)
            let children = layout.components.values.filter { $0.parent == features.id }
            XCTAssertEqual(children.count, 2)
            XCTAssertTrue(children.allSatisfy { $0.isTest == isFixture }, packagePath)
            XCTAssertEqual(layout.components["spm:FeaturesTests"]?.isTest, true)
            for file in files where file.contains("/Sources/") || file.hasPrefix("Sources/") {
                let component = try XCTUnwrap(layout.fileComponent[file].flatMap { layout.components[$0] })
                XCTAssertEqual(component.isTest, isFixture, file)
            }
            try fm.removeItem(at: root)
        }
    }
}
