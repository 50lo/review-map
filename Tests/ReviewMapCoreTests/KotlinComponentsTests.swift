import Foundation
import XCTest
@testable import ReviewMapCore

final class KotlinComponentsTests: XCTestCase {
    private func tree(_ files: [String: String]) throws -> String {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-kotlin-components-\(UUID().uuidString)")
        for (path, text) in files {
            let full = join(root, path)
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: full, atomically: true, encoding: .utf8)
        }
        return root
    }

    func testGradleComponentsInBothDSLs() throws {
        for kotlin in [true, false] {
            let suffix = kotlin ? ".gradle.kts" : ".gradle"
            let files = ["app/src/main/kotlin/App.kt", "app/src/test/kotlin/AppTest.kt", "app/src/androidTest/kotlin/DeviceTest.kt",
                         "app/src/testFixtures/kotlin/Fixture.kt", "modules/core/src/commonMain/kotlin/Core.kt",
                         "modules/core/src/jvmMain/kotlin/Jvm.kt", "modules/core/src/commonTest/kotlin/CoreTest.kt",
                         "feature/detail/src/androidMain/kotlin/Detail.kt", "app/src/main/java/Interop.java"]
            var contents: [String: String] = [
                "settings" + suffix: kotlin ? """
                    include(":app", ":core", ":feature:detail")
                    project(":core").projectDir = file("modules/core")
                    // include(":fake")
                    """ : """
                    include ':app', ':core', ':feature:detail'
                    project(':core').projectDir = new File(rootDir, 'modules/core')
                    /* include ':fake' */
                    """,
                "app/build" + suffix: kotlin ? """
                    dependencies {
                        implementation(project(":core"))
                        api(projects.feature.detail)
                        testImplementation("junit:junit:4.13.2")
                    }
                    android { compileSdk = 35; defaultConfig { minSdk = 24; targetSdk = 35 } }
                    kotlin { jvmToolchain(17) }
                    """ : """
                    dependencies {
                        implementation project(':core')
                        api projects.feature.detail
                        testImplementation 'junit:junit:4.13.2'
                    }
                    android { compileSdkVersion 35; defaultConfig { minSdkVersion 24; targetSdkVersion 35 } }
                    kotlinOptions { jvmTarget = '17' }
                    """,
                "modules/core/build" + suffix: "",
                "feature/detail/build" + suffix: "",
            ]
            for file in files { contents[file] = "" }
            let root = try tree(contents)
            defer { try? FileManager.default.removeItem(atPath: root) }
            var layout = ComponentLayout()
            KotlinComponents.add(root: root, files: files, options: AnalyzeOptions(repo: root, base: "base", head: "head"), layout: &layout)
            XCTAssertEqual(layout.fileComponent[files[0]], "gradle::app")
            for file in files[1...3] { XCTAssertEqual(layout.fileComponent[file], "gradle::app:tests") }
            for file in files[4...5] { XCTAssertEqual(layout.fileComponent[file], "gradle::core") }
            XCTAssertEqual(layout.fileComponent[files[6]], "gradle::core:tests")
            XCTAssertEqual(layout.fileComponent[files[7]], "gradle::feature:detail")
            XCTAssertEqual(layout.fileComponent[files[8]], "gradle::app")
            XCTAssertNil(layout.components["gradle::fake"])
            XCTAssertEqual(layout.components["gradle::core"]?.kind, .gradleModule)
            XCTAssertNil(layout.components["gradle::core"]?.module, "a Gradle project is not a Kotlin package")
            XCTAssertEqual(layout.moduleComponent[":core"], "gradle::core")
            XCTAssertTrue(layout.manifestDeps.contains { $0.from == "gradle::app" && $0.module == ":core" })
            XCTAssertTrue(layout.manifestDeps.contains { $0.from == "gradle::app" && $0.module == ":feature:detail" })
            XCTAssertTrue(layout.manifestDeps.contains { $0.from == "gradle::app:tests" && $0.module == "junit:junit" })
            XCTAssertTrue(layout.manifestDeps.contains { $0.from == "gradle::app:tests" && $0.module == ":app" })
            XCTAssertEqual(layout.targetSettings["gradle::app"]?.settings,
                           ["gradle compileSdk": "35", "gradle minSdk": "24", "gradle targetSdk": "35", "gradle jvmTarget": "17"])
        }
    }

    func testFixtureReportUsesGradleComponents() throws {
        let report = try Fixture.report("kotlin")
        XCTAssertEqual(report.components.first { $0.id == "gradle::app" }?.kind, .gradleModule)
        XCTAssertEqual(report.components.first { $0.id == "gradle::core" }?.kind, .gradleModule)
        XCTAssertTrue(report.edges.contains { $0.from == "gradle::app" && $0.to == "gradle::core" })
        XCTAssertFalse(report.warnings.contains { $0.kind == "unresolved-import" })
    }

    func testOnlyUsedCatalogDependenciesArePinned() throws {
        let contents = [
            "settings.gradle.kts": "include(\":app\")",
            "build.gradle.kts": "plugins { alias(libs.plugins.kotlin.android) apply false }",
            "app/build.gradle.kts": """
                dependencies {
                    implementation(libs.coroutines.core)
                    implementation(libs.bundles.network)
                    implementation("org.example:direct:2.0")
                    implementation("org.example:dynamic:$version")
                    // implementation(libs.unused)
                }
                android { compileSdk = libs.versions.sdk.get().toInt() }
                kotlinOptions { jvmTarget = JvmTarget.JVM_17 }
                """,
            "gradle/libs.versions.toml": """
                [versions]
                coroutine = "1.9.0"
                kotlin = "2.1.0"
                sdk = "35"
                [libraries]
                coroutines-core = { module = "org.jetbrains.kotlinx:kotlinx-coroutines-core", version.ref = "coroutine" }
                okhttp = { group = "com.squareup.okhttp3", name = "okhttp", version = "4.12.0" }
                unused = "com.example:unused:9.0"
                [bundles]
                network = ["okhttp"]
                [plugins]
                kotlin-android = { id = "org.jetbrains.kotlin.android", version.ref = "kotlin" }
                """,
            "app/src/main/kotlin/App.kt": "",
        ]
        let root = try tree(contents)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let pins = KotlinComponents.pinnedPackages(blobs: contents.mapValues { _ in "blob" }, dir: root)
        XCTAssertEqual(pins, ["org.jetbrains.kotlinx:kotlinx-coroutines-core": "1.9.0", "com.squareup.okhttp3:okhttp": "4.12.0", "org.example:direct": "2.0"])
        var layout = ComponentLayout()
        KotlinComponents.add(root: root, files: ["app/src/main/kotlin/App.kt"], options: AnalyzeOptions(repo: root, base: "base", head: "head"), layout: &layout)
        XCTAssertEqual(Set(layout.externalProducts.keys), Set(pins.keys))
        XCTAssertEqual(layout.targetSettings["gradle::app"]?.settings,
                       ["gradle kotlin": "2.1.0", "gradle compileSdk": "35", "gradle jvmTarget": "17"])
    }

    func testSingleBuildAndLiteralBoundaries() throws {
        let root = try tree(["build.gradle": """
            plugins { id 'org.jetbrains.kotlin.jvm' version '2.0.21' }
            dependencies {
                implementation 'com.example:core:1.0'
            }
            def misleading = "implementation 'com.fake:fake:9.0'"
            """])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let modules = KotlinComponents.modules(root: root)
        XCTAssertEqual(modules.map(\.path), [":"])
        let input = KotlinComponents.tokens(try String(contentsOfFile: root + "/build.gradle", encoding: .utf8))
        XCTAssertEqual(KotlinComponents.dependencies(input, catalog: .init(), modules: modules).map(\.name), ["com.example:core"])
        XCTAssertEqual(KotlinComponents.settings(input, catalog: .init()), ["gradle kotlin": "2.0.21"])
    }

    func testMultiplatformDependenciesAndDynamicProjectDirs() throws {
        let root = try tree([
            "settings.gradle.kts": """
                include(":core", ":feature-api")
                project(":core").projectDir = file("modules/" + suffix)
                """,
            "core/build.gradle.kts": """
                kotlin {
                    sourceSets {
                        val commonTest by getting {
                            dependencies { implementation("org.example:test:1") }
                        }
                    }
                    compilerOptions { jvmTarget.set(JvmTarget.JVM_21) }
                }
                dependencies { implementation(projects.featureApi) }
                """,
            "feature-api/build.gradle.kts": "",
        ])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let modules = KotlinComponents.modules(root: root)
        XCTAssertEqual(modules.first { $0.path == ":core" }?.dir, "core", "dynamic projectDir expressions are not treated as literal paths")
        var layout = ComponentLayout()
        KotlinComponents.add(root: root, files: ["core/src/commonMain/kotlin/Core.kt"], options: AnalyzeOptions(repo: root, base: "base", head: "head"), layout: &layout)
        XCTAssertTrue(layout.manifestDeps.contains { $0.from == "gradle::core:tests" && $0.module == "org.example:test" })
        XCTAssertTrue(layout.manifestDeps.contains { $0.from == "gradle::core" && $0.module == ":feature-api" })
        XCTAssertEqual(layout.targetSettings["gradle::core"]?.settings["gradle jvmTarget"], "21")
    }

    func testProjectDirectoryCanBeRepositoryRoot() throws {
        let root = try tree([
            "settings.gradle.kts": "include(\":core\")\nproject(\":core\").projectDir = file(\".\")",
            "build.gradle.kts": "",
        ])
        defer { try? FileManager.default.removeItem(atPath: root) }
        var layout = ComponentLayout()
        KotlinComponents.add(root: root, files: ["src/main/kotlin/Core.kt"], options: AnalyzeOptions(repo: root, base: "base", head: "head"), layout: &layout)
        XCTAssertEqual(layout.fileComponent["src/main/kotlin/Core.kt"], "gradle::core")
    }

    func testPackageMappingDoesNotGuessBetweenArtifacts() {
        XCTAssertEqual(KotlinComponents.package(ofModule: "com.example.core.model", pinned: ["com.example.core:library"]), "com.example.core:library")
        XCTAssertEqual(KotlinComponents.package(ofModule: "com.example.core.model", pinned: ["com.example:wide", "com.example.core:library"]), "com.example.core:library")
        XCTAssertEqual(KotlinComponents.package(ofModule: "com.example.corex", pinned: ["com.example.core:library"]), "com.example")
        XCTAssertEqual(KotlinComponents.package(ofModule: "com.example.core.model", pinned: ["com.example.core:a", "com.example.core:b"]), "com.example")
        XCTAssertEqual(KotlinComponents.package(ofModule: "kotlinx.coroutines.flow", pinned: ["org.jetbrains.kotlinx:kotlinx-coroutines-core"]), "kotlinx.coroutines")
    }
}
