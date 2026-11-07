import Foundation
import XCTest
import TreeSitter
@testable import ReviewMapCore

final class KotlinTests: XCTestCase {
    func testDeclarationsAndPublicAPI() throws {
        let source = """
            package shop.model
            @Serializable
            data class Cart(@SerialName("cart_id") val id: String, var note: String?) : Base(), Item {
                companion object {
                    const val TAG: String = "cart"
                }
                suspend fun load(id: Int): String? = null
                private val secret: String = "x"
                val computed: String get() = "value"
            }
            internal class Hidden { fun exposed(): Unit {} }
            sealed class Result
            value class ID(val value: String)
            annotation class Marker
            enum class State { OPEN, CLOSED }
            interface Reader {
                fun read(): String
                fun fallback(): String = "fallback"
            }
            typealias Name = String
            fun String.pretty(): String = this
            object Singleton
            """
        let file = KotlinExtractor.parse(path: "model.kt", source: source)
        let byName = Dictionary(uniqueKeysWithValues: file.decls.map { ($0.qualifiedName, $0) })
        XCTAssertEqual(file.packageName, "shop.model")
        XCTAssertEqual(byName["Cart"]?.kind, .class)
        XCTAssertEqual(byName["Cart"]?.modifiers, ["data"])
        XCTAssertEqual(byName["Cart"]?.attributes, ["Serializable"])
        XCTAssertEqual(byName["Cart"]?.inherited, ["Base", "Item"])
        XCTAssertEqual(byName["Cart.id"]?.kind, .var)
        XCTAssertTrue(byName["Cart.id"]?.traits.contains("constructor-property") == true)
        XCTAssertTrue(byName["Cart.id"]?.traits.contains(where: { $0.hasPrefix("annotation:") && $0.contains("cart_id") }) == true)
        XCTAssertEqual(byName["Cart.note"]?.typeAnnotation, "String?")
        XCTAssertEqual(byName["Cart.Companion"]?.modifiers, ["object", "companion"])
        XCTAssertEqual(byName["Cart.Companion.TAG"]?.isStatic, true)
        XCTAssertEqual(byName["Cart.load()"]?.labelsKey, "load(id:)")
        XCTAssertEqual(byName["Cart.load()"]?.isAsync, true)
        XCTAssertEqual(byName["Cart.load()"]?.typeAnnotation, "String?")
        XCTAssertEqual(byName["Cart.computed"]?.isStored, false)
        XCTAssertEqual(byName["Reader"]?.kind, .protocol)
        XCTAssertEqual(byName["Reader.read()"]?.inProtocol, true)
        XCTAssertEqual(byName["Reader.fallback()"]?.inProtocol, false)
        XCTAssertEqual(byName["State.OPEN"]?.kind, .case)
        XCTAssertEqual(byName["Name"]?.kind, .typealias)
        XCTAssertEqual(byName["String.pretty()"]?.scope, "String")
        XCTAssertEqual(byName["Singleton"]?.modifiers, ["object"])
        let lang = KotlinLanguage()
        for decl in file.decls {
            XCTAssertEqual(lang.isPublicAPI(decl, enclosing: file.enclosingDeclarations(of: decl)),
                           !["Cart.secret", "Hidden", "Hidden.exposed()"].contains(decl.qualifiedName), decl.qualifiedName)
        }
    }

    func testGrammarCompatibilityAndModernSyntax() {
        let parser = ts_parser_new()
        defer { ts_parser_delete(parser) }
        XCTAssertTrue(ts_parser_set_language(parser, KotlinExtractor.language), "grammar ABI must load with pinned tree-sitter")
        let source = #"""
            @JvmInline value class ID(val value: String)
            context(ctx: Context)
            fun contextual(): String = ctx.value
            val template = $$"dollar $ literal; interpolation $$value"
            fun after(): String = "still parsed"
            """#
        let tree = SyntaxTree(source: source, language: KotlinExtractor.language)
        XCTAssertFalse(ts_node_has_error(tree.root.raw))
        let file = KotlinExtractor.parse(path: "modern.kt", source: source)
        XCTAssertEqual(Set(file.decls.map(\.name)), ["ID", "value", "contextual", "template", "after"])
        XCTAssertTrue(file.decls.first { $0.name == "contextual" }?.modifiersCanon.contains("context") == true)
    }

    func testReferencesAndSourcePaths() {
        let file = KotlinExtractor.parse(path: "app.kt", source: """
            package app
            import shop.model.Cart as Basket
            import shop.money.*
            fun render(cart: Basket): String = format(1) + cart.note
            """)
        XCTAssertEqual(file.packageName, "app")
        XCTAssertEqual(file.imports.map(\.name), ["shop.model.Cart", "shop.money"])
        XCTAssertEqual(file.wildcardImports, ["shop.money"])
        XCTAssertTrue(file.typeRefs.contains(NameRef(name: "Cart", line: 4, module: "shop.model")))
        XCTAssertTrue(file.typeRefs.contains(NameRef(name: "format", line: 4)))
        XCTAssertTrue(file.memberRefs.contains(NameRef(name: "note", line: 4)))
        let lang = KotlinLanguage()
        XCTAssertTrue(lang.isSource("source.kt"))
        XCTAssertTrue(lang.isSource("script.kts"))
        XCTAssertFalse(lang.isSource("settings.gradle.kts"))
        XCTAssertFalse(lang.isSource("build.gradle.kts"))
        XCTAssertFalse(lang.isSource("Source.java"))
        XCTAssertTrue(lang.isPlatformModule("kotlin.collections.List"))
        XCTAssertFalse(lang.isPlatformModule("kotlinx.coroutines"))
    }

    func testFixture() throws {
        let report = try Fixture.report("kotlin")
        let note = try XCTUnwrap(report.reviewItems.first { $0.qualifiedName == "Cart.note" })
        XCTAssertTrue(note.changes.contains(.signature))
        let cart = try XCTUnwrap(report.reviewItems.first { $0.qualifiedName == "Cart" })
        let format = try XCTUnwrap(report.reviewItems.first { $0.qualifiedName == "format()" })
        XCTAssertTrue(cart.usedBy.contains { $0.file.hasSuffix("Main.kt") })
        XCTAssertTrue(format.usedBy.contains { $0.file.hasSuffix("Main.kt") })
        XCTAssertTrue(format.usedBy.contains { $0.file.hasSuffix("SamePackage.kt") })
        let first = try XCTUnwrap(report.reviewItems.first { $0.qualifiedName == "Widget.run()" && $0.location.file.contains("first/") })
        let second = try XCTUnwrap(report.reviewItems.first { $0.qualifiedName == "Widget.run()" && $0.location.file.contains("second/") })
        XCTAssertTrue(first.usedBy.contains { $0.file.hasSuffix("Main.kt") })
        XCTAssertFalse(second.usedBy.contains { $0.file.hasSuffix("Main.kt") })
        XCTAssertFalse(report.warnings.contains { $0.kind == "unresolved-import" })
    }

    func testCosmeticAndImplicitCallers() {
        let base = KotlinExtractor.parse(path: "a.kt", source: "fun f(x: String): String { return x }")
        let head = KotlinExtractor.parse(path: "a.kt", source: "fun f(x:String):String { /* comment */ return x }")
        XCTAssertEqual(base.decls.first?.signatureCanon, head.decls.first?.signatureCanon)
        XCTAssertEqual(base.decls.first?.bodyCanon, head.decls.first?.bodyCanon)
        let file = KotlinExtractor.parse(path: "entry.kt", source: """
            fun main() {}
            @Test fun test() {}
            operator fun String.plus(other: String): String = this
            fun ordinary() {}
            """)
        XCTAssertEqual(Set(file.decls.filter(KotlinLanguage().isImplicitlyCalled).map(\.name)), ["main", "test", "plus"])
    }
}
