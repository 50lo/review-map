import Foundation
import XCTest
@testable import ReviewMapCore

/// Go: the parser on its own, and the analyzer on Fixtures/go, a module with a base and a head tree.
final class GoTests: XCTestCase {
    func model() throws -> ChangeModel { try Fixture.model("go") }

    func entity(_ m: ChangeModel, _ qualifiedName: String, file: StaticString = #filePath, line: UInt = #line) throws -> Entity {
        try XCTUnwrap(m.entities.first { $0.qualifiedName == qualifiedName }, "no entity \(qualifiedName)", file: file, line: line)
    }

    func regions(_ m: ChangeModel, _ qualifiedName: String, kind: String? = nil) throws -> [Region] {
        let e = try entity(m, qualifiedName)
        return m.regions.filter { $0.entity == e.id && (kind == nil || $0.kind == kind) }
    }

    // MARK: Parsing

    func testDeclarations() {
        let source = """
            package shop

            func (c *Cart) Add(item Item, n int) error { return nil }

            // Cart holds items.
            type Cart struct {
            \tID    string `json:"id"`
            \ta, b  int
            \tBase
            \t*sync.Mutex
            }

            type (
            \tReader interface {
            \t\tio.Closer
            \t\tRead(p []byte) (n int, err error)
            \t}
            \tID     string
            \tAlias  = map[string]int
            \tList[T any] []T
            )

            func New[T any](xs ...T) *Cart { return &Cart{} }

            func (Cart) value() {}

            func (l List[T]) Len() int { return len(l) }

            const (
            \tA = iota
            \tB
            )

            var x, y = 1, "a"
            var _ = 3
            """
        let file = GoExtractor.parse(path: "shop/cart.go", source: source)
        let byName = Dictionary(grouping: file.decls, by: \.qualifiedName)
        func decl(_ q: String, line: UInt = #line) -> Decl? {
            let d = byName[q]?.first
            XCTAssertNotNil(d, "no \(q)", line: line)
            return d
        }
        let cart = decl("Cart")
        XCTAssertEqual(cart?.kind, .struct)
        XCTAssertEqual(cart?.access, "public")
        XCTAssertEqual(cart?.startLine, 6)
        XCTAssertEqual(cart?.endLine, 11)
        XCTAssertEqual(cart?.headerEndLine, 6)
        XCTAssertEqual(cart?.signatureDisplay, "type Cart struct")
        let add = decl("Cart.Add()")
        XCTAssertEqual(add?.scope, "Cart")
        XCTAssertEqual(add?.parentIndex.map { file.decls[$0].name }, "Cart", "a method above its type still belongs to it")
        XCTAssertEqual(add?.parentKind, .struct)
        XCTAssertEqual(add?.labelsKey, "Add(item:n:)")
        XCTAssertEqual(add?.signatureDisplay, "func (c *Cart) Add(item Item, n int) error")
        XCTAssertEqual(add?.bodyCanon, "{ return nil }")
        XCTAssertEqual(add?.traits, ["pointer-receiver"])
        XCTAssertEqual(decl("Cart.value()")?.access, "internal")
        XCTAssertEqual(decl("Cart.value()")?.labelsKey, "value()")

        let id = decl("Cart.ID")
        XCTAssertEqual(id?.kind, .var)
        XCTAssertEqual(id?.isStored, true)
        XCTAssertEqual(id?.signatureCanon, "ID string")
        XCTAssertEqual(id?.modifiersCanon, #"json:"id""#, "the tag is compared with the modifiers")
        XCTAssertEqual(id?.typeAnnotation, "string")
        XCTAssertEqual(decl("Cart.a")?.signatureCanon, "a int")
        XCTAssertEqual(decl("Cart.b")?.signatureCanon, "b int")
        XCTAssertEqual(decl("Cart.Base")?.traits, ["embedded"])
        XCTAssertEqual(decl("Cart.Mutex")?.signatureCanon, "* sync . Mutex")

        let reader = decl("Reader")
        XCTAssertEqual(reader?.kind, .protocol)
        XCTAssertEqual(reader?.inherited, ["Closer"])
        XCTAssertEqual(reader?.startLine, 14, "a grouped type spans its own lines")
        XCTAssertEqual(reader?.signatureDisplay, "Reader interface")
        let read = decl("Reader.Read()")
        XCTAssertEqual(read?.inProtocol, true)
        XCTAssertEqual(read?.labelsKey, "Read(p:)")
        XCTAssertEqual(decl("ID")?.kind, .typealias)
        XCTAssertEqual(decl("ID")?.signatureCanon, "ID string")
        XCTAssertEqual(decl("Alias")?.kind, .typealias)
        XCTAssertEqual(decl("List")?.kind, .typealias)
        XCTAssertEqual(decl("List.Len()")?.parentIndex.map { file.decls[$0].name }, "List", "a generic receiver names its type")

        XCTAssertEqual(decl("New()")?.labelsKey, "New(xs:)")
        XCTAssertEqual(decl("New()")?.scope, nil)
        XCTAssertEqual(decl("A")?.modifiers, ["const"])
        XCTAssertEqual(decl("B")?.signatureCanon, "const B", "a grouped constant keeps its keyword")
        XCTAssertEqual(decl("x")?.bodyCanon, "1", "each name has its own value")
        XCTAssertEqual(decl("y")?.bodyCanon, #"" a ""#)
        XCTAssertNil(byName["_"], "blank names declare nothing")
        XCTAssertTrue(file.decls.allSatisfy { $0.scope == nil || $0.qualifiedName.hasPrefix($0.scope! + ".") })
        XCTAssertFalse(file.isGenerated)
    }

    func testCommentsAreCosmetic() {
        let a = GoExtractor.parse(path: "a.go", source: "package a\n\nfunc F(x int) int {\n\treturn x + 1\n}\n").decls[0]
        let b = GoExtractor.parse(path: "a.go", source: "package a\n\nfunc F(x int) int {\n\t// one more\n\treturn x+1\n}\n").decls[0]
        XCTAssertEqual(a.signatureCanon, b.signatureCanon)
        XCTAssertEqual(a.bodyCanon, b.bodyCanon)
        XCTAssertNotEqual(a.rawText, b.rawText)
        XCTAssertTrue(GoExtractor.parse(path: "empty.go", source: "").decls.isEmpty)
    }

    func testGeneratedHeader() {
        XCTAssertTrue(GoExtractor.parse(path: "a.go", source: "// Code generated by protoc-gen-go. DO NOT EDIT.\n\npackage a\n").isGenerated)
        XCTAssertFalse(GoExtractor.parse(path: "a.go", source: "package a\n\n// Code generated by hand. DO NOT EDIT.\n").isGenerated,
                       "only before the package clause")
        let lang = GoLanguage()
        XCTAssertFalse(lang.isSource("vendor/github.com/x/y/y.go"))
        XCTAssertFalse(lang.isSource("pkg/testdata/sample.go"))
        XCTAssertTrue(lang.isSource("pkg/vendors.go"))
    }

    func testReferences() {
        let source = """
            package api

            import (
            \t"fmt"
            \tm "example.com/shop/money"
            \t"example.com/shop/cart"
            \t_ "example.com/shop/plugins"
            \t"gopkg.in/yaml.v3"
            \t"example.com/shop/v2"
            )

            func Show(c *cart.Cart) string {
            \tvar t cart.Total
            \tlocal := Helper()
            \t_ = yaml.Marshal
            \t_ = shop.Version
            \treturn fmt.Sprint(m.Format(c.Sum()), t, local)
            }
            """
        let file = GoExtractor.parse(path: "api/show.go", source: source)
        XCTAssertEqual(file.imports.map(\.name), ["fmt", "example.com/shop/money", "example.com/shop/cart", "example.com/shop/plugins",
                                                   "gopkg.in/yaml.v3", "example.com/shop/v2"])
        let refs = Set(file.typeRefs.map { "\($0.name)@\($0.line)<\($0.module ?? "-")" })
        XCTAssertEqual(refs, [
            "Cart@12<example.com/shop/cart", "Total@13<example.com/shop/cart", "Marshal@15<gopkg.in/yaml.v3",
            "Version@16<example.com/shop/v2", "Sprint@17<fmt", "Format@17<example.com/shop/money",
        ], "unqualified names are the package's own")
        XCTAssertTrue(file.memberRefs.contains(NameRef(name: "Sum", line: 17)))
        XCTAssertFalse(file.memberRefs.contains { $0.name == "Format" }, "a package's names aren't members")

        let test = GoExtractor.parse(path: "api/show_test.go", source: "package api\n\nfunc TestShow(t *testing.T) { Show(nil) }\n")
        XCTAssertTrue(test.typeRefs.contains { $0.name == "Show" && $0.module == nil }, "a test may use its package's names")
        let dot = GoExtractor.parse(path: "a.go", source: "package a\n\nimport . \"example.com/x\"\n\nvar v = Thing(local)\n")
        XCTAssertEqual(dot.typeRefs.map { "\($0.name)<\($0.module ?? "-")" }, ["Thing<example.com/x"], "exported names through a dot import")
    }

    func testRiskMarks() {
        let source = """
            package a

            func f(v any, m *sync.Mutex) error {
            \tif err := g(); err != nil {
            \t\treturn err
            \t}
            \tgo work()
            \ts := v.(string)
            \tn, ok := v.(int)
            \t_ = h()
            \tx, _ := strconv.Atoi(s)
            \t_, found := lookup[s]
            \tdefer func() { recover() }()
            \tpanic("no")
            \tlog.Fatalf("bad %d", n)
            \tp := unsafe.Pointer(&x)
            \tselect {}
            \tvar wg sync.WaitGroup
            \tswitch x { case 1: break }
            }
            """
        let marks = GoExtractor.parse(path: "a.go", source: source).marks
        func labels(_ line: Int) -> Set<String> { Set((marks[line] ?? []).map { "\($0.kind.rawValue):\($0.label)" }) }
        XCTAssertEqual(labels(3), ["concurrency:sync.Mutex"])
        XCTAssertEqual(labels(4), ["flow:if"])
        XCTAssertEqual(labels(5), ["check:early return", "flow:early return"])
        XCTAssertEqual(labels(7), ["concurrency:go"])
        XCTAssertEqual(labels(8), ["crash:type assertion"])
        XCTAssertEqual(labels(9), [], "an assertion checked with ok")
        XCTAssertEqual(labels(10), ["crash:ignored error"])
        XCTAssertEqual(labels(11), ["crash:ignored error"])
        XCTAssertEqual(labels(12), [], "an index, not a call")
        XCTAssertEqual(labels(13), ["flow:defer", "flow:recover"])
        XCTAssertEqual(labels(14), ["crash:panic"])
        XCTAssertEqual(labels(15), ["crash:log.Fatalf"])
        XCTAssertEqual(labels(16), ["crash:unsafe"])
        XCTAssertEqual(labels(17), ["flow:select", "concurrency:select"])
        XCTAssertEqual(labels(18), ["concurrency:sync.WaitGroup"])
        XCTAssertEqual(labels(19), ["flow:switch", "flow:break"])
    }

    func testLanguageRules() {
        let lang = GoLanguage()
        XCTAssertTrue(lang.isPlatformModule("net/http"))
        XCTAssertFalse(lang.isPlatformModule("github.com/google/uuid"))
        XCTAssertEqual(lang.package(ofModule: "golang.org/x/text/language", pinned: ["golang.org/x/text", "golang.org/x"]), "golang.org/x/text")
        XCTAssertNil(lang.package(ofModule: "golang.org/x/textual", pinned: ["golang.org/x/text"]))
        XCTAssertEqual(GoExtractor.packageName("gopkg.in/yaml.v3"), "yaml")
        XCTAssertEqual(GoExtractor.packageName("github.com/jackc/pgx/v5"), "pgx")
        XCTAssertEqual(GoExtractor.packageName("github.com/mattn/go-sqlite3"), "sqlite3")
        let file = GoExtractor.parse(path: "a.go", source: """
            package a
            type T struct{ F int }
            func (t T) String() string { return "" }
            func (t T) helper() {}
            func (t t2) Exported() {}
            func main() {}
            func TestX(t *testing.T) {}
            func Testify() {}
            """)
        let d = Dictionary(uniqueKeysWithValues: file.decls.map { ($0.qualifiedName, $0) })
        XCTAssertTrue(lang.isImplicitlyCalled(d["T.String()"]!))
        XCTAssertFalse(lang.isImplicitlyCalled(d["T.helper()"]!))
        XCTAssertTrue(lang.isImplicitlyCalled(d["main()"]!))
        XCTAssertTrue(lang.isImplicitlyCalled(d["TestX()"]!))
        XCTAssertFalse(lang.isImplicitlyCalled(d["Testify()"]!))
        XCTAssertTrue(lang.isPublicAPI(d["T.F"]!, enclosing: []))
        XCTAssertFalse(lang.isPublicAPI(d["t2.Exported()"]!, enclosing: []), "a method of an unexported type")
        XCTAssertEqual(lang.settingFlag("go.mod replace example.com/x"), "replace-changed")
    }

    func testGoMod() {
        let text = """
            module example.com/shop // the shop

            go 1.22
            toolchain go1.22.4

            require github.com/a/b v1.0.0
            require (
            \tgithub.com/c/d v0.2.0 // indirect
            )
            replace github.com/a/b v1.0.0 => ../b
            """
        let m = GoComponents.parse(text, dir: "", manifest: "go.mod")
        XCTAssertEqual(m?.path, "example.com/shop")
        XCTAssertEqual(m?.requires, ["github.com/a/b": "v1.0.0", "github.com/c/d": "v0.2.0"])
        XCTAssertEqual(m.map(GoComponents.settings), ["go.mod go": "1.22", "go.mod toolchain": "go1.22.4",
                                                      "go.mod replace github.com/a/b@v1.0.0": "../b"])
    }

    /// Writes files into a new temporary directory and returns it; the caller removes it.
    private func tree(_ files: [String: String]) throws -> String {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-go-\(UUID().uuidString)")
        for (path, text) in files {
            let full = root + "/" + path
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: full, atomically: true, encoding: .utf8)
        }
        return root
    }

    func testWorkspaceModules() throws {
        let root = try tree([
            "go.work": "go 1.22\n\nuse (\n\t./api\n\t./lib\n)\n",
            "api/go.mod": "module example.com/api\n\ngo 1.22\n",
            "api/main.go": "package main\n",
            "lib/go.mod": "module example.com/lib\n\ngo 1.22\n",
            "lib/util/util.go": "package util\n",
            "lib/util/util_test.go": "package util\n",
            "tools/gen.go": "package tools\n",
        ])
        defer { try? FileManager.default.removeItem(atPath: root) }
        var layout = ComponentLayout()
        GoComponents.add(root: root, files: ["api/main.go", "lib/util/util.go", "lib/util/util_test.go", "tools/gen.go"], layout: &layout)
        XCTAssertEqual(layout.fileComponent, ["api/main.go": "go:example.com/api", "lib/util/util.go": "go:example.com/lib/util",
                                              "lib/util/util_test.go": "go:example.com/lib/util:tests"],
                       "files outside a module are left to folder components")
        XCTAssertEqual(layout.moduleComponent["example.com/lib/util"], "go:example.com/lib/util")
        XCTAssertEqual(layout.components["go:example.com/lib"]?.name, "example.com/lib", "a module's root anchors its settings")
        XCTAssertEqual(Set(layout.targetSettings.keys), ["go:example.com/api", "go:example.com/lib"])
    }

    // MARK: Fixture

    func testSnapshot() throws {
        try Fixture.checkSnapshot("go")
    }

    func testComponents() throws {
        let m = try model()
        XCTAssertEqual(m.analyzer.languages, ["go"])
        let ids = Set(m.components.map(\.id))
        XCTAssertEqual(ids, ["go:example.com/shop", "go:example.com/shop/api", "go:example.com/shop/cart", "go:example.com/shop/cart:tests",
                             "go:example.com/shop/money", "go:example.com/shop/report", "go:example.com/shop/store",
                             "ext:github.com/google/uuid", "ext:golang.org/x/text"], "no vendor or testdata components")
        XCTAssertEqual(m.components.first { $0.id == "go:example.com/shop/cart:tests" }?.isTest, true)
        XCTAssertEqual(m.components.first { $0.id == "go:example.com/shop/report" }?.status, "added")
        XCTAssertTrue(m.warnings.isEmpty, "standard library imports aren't warnings: \(m.warnings)")
        XCTAssertEqual(try entity(m, "Kind").tags, ["generated"], "a `Code generated` header")
    }

    func testEdges() throws {
        let m = try model()
        func edge(_ from: String, _ to: String) -> Edge? { m.edges.first { $0.from == "go:example.com/shop/\(from)" && $0.to == to } }
        XCTAssertEqual(edge("api", "go:example.com/shop/cart")?.symbolsRemoved, ["Describe"])
        XCTAssertEqual(edge("api", "go:example.com/shop/money")?.refs.map(\.symbol).sorted(), ["Format", "import example.com/shop/money"],
                       "an aliased import")
        XCTAssertEqual(edge("cart:tests", "go:example.com/shop/cart")?.status, .unchanged, "a test uses its package unqualified")
        XCTAssertEqual(edge("report", "ext:golang.org/x/text")?.status, .added, "a pinned module's package")
        XCTAssertEqual(edge("cart", "ext:github.com/google/uuid")?.status, .unchanged)
        XCTAssertFalse(m.edges.contains { $0.to.contains("fmt") || $0.to.contains("net/http") }, "standard library imports aren't edges")
        XCTAssertEqual(m.externalDeps, [
            ExternalDepChange(name: "github.com/google/uuid", change: "bumped", from: "v1.5.0", to: "v1.6.0"),
            ExternalDepChange(name: "golang.org/x/text", change: "added", from: nil, to: "v0.16.0"),
        ])
    }

    func testChanges() throws {
        let m = try model()
        XCTAssertEqual(try entity(m, "Cart.Total()").changes, [.signature, .body])
        XCTAssertEqual(try entity(m, "Item.SKU").changes, [.modifiers])
        XCTAssertEqual(try entity(m, "Cart.Note").change, .added)
        XCTAssertEqual(try entity(m, "Describe()").change, .removed)
        XCTAssertEqual(try entity(m, "Describe()").usedBy.map(\.symbol), ["Handler.ServeHTTP()"])
        XCTAssertFalse(try entity(m, "notify()").isInterface)
    }

    func testFlags() throws {
        let m = try model()
        XCTAssertEqual(try entity(m, "Store.Clear()").contractFlags, ["go:interface-method-added"])
        XCTAssertEqual(try entity(m, "Store").contractFlags, ["go:interface-method-added"])
        XCTAssertEqual(try entity(m, "Item.SKU").contractFlags, ["go:field-tag-changed:json"])
        XCTAssertEqual(try entity(m, "Cart.Note").contractFlags, ["go:field-added"])
        XCTAssertEqual(try entity(m, "Cart").contractFlags, ["go:field-added"])
        XCTAssertEqual(try entity(m, "Cart.Total()").contractFlags, ["go:api-signature-changed"])
        XCTAssertEqual(try entity(m, "Describe()").contractFlags, ["go:unexported"])
        XCTAssertEqual(try entity(m, "describe()").contractFlags, [])
        XCTAssertEqual(try entity(m, "Summary()").contractFlags, ["go:api-added"])
        let settings = try entity(m, "example.com/shop build settings")
        XCTAssertEqual(settings.contractFlags, ["go:go-version-changed", "go:toolchain-changed"])
        XCTAssertEqual(settings.location.file, "go.mod")
    }

    func testRegions() throws {
        let m = try model()
        let add = try XCTUnwrap(try regions(m, "Cart.Add()", kind: "review").first)
        XCTAssertEqual(add.reasons, ["concurrency: go", "new ignored error"])
        let total = try regions(m, "Cart.Total()", kind: "review")
        XCTAssertGreaterThan(add.risk, total.filter { $0.reasons == ["changed lines"] }.map(\.risk).max() ?? 1,
                             "a new goroutine and an ignored error rank above a body-only change")
        XCTAssertEqual(try regions(m, "Summary()", kind: "review").first?.reasons, ["go:api-added", "new type assertion"])
        XCTAssertTrue(try regions(m, "Store.Clear()", kind: "context").contains { $0.relation == "conformer" && $0.reasons == ["Memory.Clear()"] })
    }

    func testConformers() throws {
        let m = try model()
        let findings = m.findings.filter { $0.kind == "conformers" }
        XCTAssertEqual(findings.map(\.message), ["New requirement Store.Clear(): 1 conformer wasn't updated."])
        XCTAssertEqual(findings.first?.evidence.first?.hasPrefix("No Clear in File,"), true, "Memory implements it; File, in another package, doesn't")
        XCTAssertEqual(findings.first?.anchors.map { $0.component ?? $0.entity ?? "" },
                       ["go:example.com/shop/cart::Store.Clear()", "go:example.com/shop/store"])
    }
}
