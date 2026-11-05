import Foundation
import XCTest
@testable import ReviewMapCore

/// TypeScript: the parser on its own, and the analyzer on Fixtures/typescript, an npm workspace with a
/// base and a head tree.
final class TypeScriptTests: XCTestCase {
    func model() throws -> ChangeModel { try Fixture.model("typescript") }

    func entity(_ m: ChangeModel, _ qualifiedName: String, component: String? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> Entity {
        try XCTUnwrap(m.entities.first { $0.qualifiedName == qualifiedName && (component == nil || $0.component == component) },
                      "no entity \(qualifiedName)", file: file, line: line)
    }

    func regions(_ m: ChangeModel, _ qualifiedName: String, kind: String? = nil) throws -> [Region] {
        let e = try entity(m, qualifiedName)
        return m.regions.filter { $0.entity == e.id && (kind == nil || $0.kind == kind) }
    }

    // MARK: Parsing

    func testDeclarations() {
        let source = """
            import { Thing } from "./thing";

            @Injectable()
            export abstract class Store<T> extends Base<T> implements Loader, api.Saver {
              private readonly items: T[] = [];
              static count?: number;
              #secret = 1;
              constructor(private api: Api) { super(); }
              async load(id: string, opts?: Opts): Promise<T> { return this.api.get(id); }
              get size(): number { return this.items.length; }
              set size(v: number) {}
              protected abstract reset(): void;
              @Output() changed = (value: T) => value;
            }
            export interface Loader {
              readonly name: string;
              load?(id: string): Promise<void>;
              (x: number): string;
              new (x: number): Loader;
              [key: string]: unknown;
            }
            export const enum Color { Red = 1, Green }
            export type Props = { a: string };
            export function f(a: number): number;
            export function f(a: any): any { return a; }
            export const g = async (x: number) => { await x; };
            export default function () {}
            let u = 1, w: string = "a";
            namespace NS { export const k = 1; }
            """
        let file = TypeScriptExtractor.parse(path: "src/store.ts", source: source)
        let byName = Dictionary(grouping: file.decls, by: \.qualifiedName)
        func decl(_ q: String, line: UInt = #line) -> Decl? {
            let d = byName[q]?.first
            XCTAssertNotNil(d, "no \(q)", line: line)
            return d
        }
        let store = decl("Store")
        XCTAssertEqual(store?.kind, .class)
        XCTAssertEqual(store?.startLine, 3, "decorators belong to the declaration")
        XCTAssertEqual(store?.endLine, 14)
        XCTAssertEqual(store?.headerEndLine, 4)
        XCTAssertEqual(store?.attributes, ["Injectable"])
        XCTAssertEqual(store?.inherited, ["Base", "Loader", "Saver"])
        XCTAssertEqual(store?.signatureDisplay, "class Store<T> extends Base<T> implements Loader, api.Saver")
        XCTAssertEqual(store?.signatureCanon, "class Store < T >", "supertypes are compared on their own")
        XCTAssertTrue(store?.modifiers.contains("export") == true && store?.modifiers.contains("abstract") == true)

        let items = decl("Store.items")
        XCTAssertEqual(items?.kind, .var)
        XCTAssertEqual(items?.access, "private")
        XCTAssertEqual(items?.isStored, true)
        XCTAssertEqual(items?.modifiers, ["readonly"])
        XCTAssertEqual(items?.signatureCanon, "items : T [ ]")
        XCTAssertEqual(items?.bodyCanon, "[ ]")
        XCTAssertEqual(decl("Store.count")?.traits, ["optional"])
        XCTAssertEqual(decl("Store.count")?.isStatic, true)
        XCTAssertEqual(decl("Store.#secret")?.access, "#private")
        XCTAssertEqual(decl("Store.constructor()")?.kind, .`init`)
        let load = decl("Store.load()")
        XCTAssertEqual(load?.isAsync, true)
        XCTAssertEqual(load?.labelsKey, "load(id:opts:)")
        XCTAssertEqual(load?.signatureDisplay, "load(id: string, opts?: Opts): Promise<T>")
        XCTAssertEqual(decl("Store.get size")?.kind, .var)
        XCTAssertEqual(decl("Store.get size")?.signatureDisplay, "get size(): number")
        XCTAssertEqual(decl("Store.set size")?.labelsKey, "set size")
        XCTAssertEqual(decl("Store.reset()")?.modifiers, ["abstract"])
        XCTAssertEqual(decl("Store.reset()")?.access, "protected")
        let changed = decl("Store.changed()")
        XCTAssertEqual(changed?.kind, .func, "an arrow function property is a method")
        XCTAssertEqual(changed?.attributes, ["Output"])
        XCTAssertEqual(changed?.startLine, 13)

        XCTAssertEqual(decl("Loader")?.kind, .protocol)
        XCTAssertEqual(decl("Loader.name")?.inProtocol, true)
        XCTAssertEqual(decl("Loader.name")?.parentKind, .protocol)
        XCTAssertEqual(decl("Loader.load()")?.traits, ["optional"])
        XCTAssertEqual(decl("Loader.call()")?.kind, .func)
        XCTAssertEqual(decl("Loader.new()")?.kind, .`init`)
        XCTAssertEqual(decl("Loader.[index]")?.kind, .var)

        XCTAssertEqual(decl("Color")?.modifiers, ["export", "const"])
        XCTAssertEqual(file.decls.filter { $0.scope == "Color" }.map(\.name), ["Red", "Green"])
        XCTAssertEqual(file.decls.filter { $0.scope == "Color" }.map(\.kind), [.case, .case])
        XCTAssertEqual(decl("Props")?.signatureCanon, "type Props = { a : string }")
        XCTAssertEqual(byName["f()"]?.count, 2, "an overload and its implementation")
        let g = decl("g()")
        XCTAssertEqual(g?.kind, .func)
        XCTAssertEqual(g?.isAsync, true)
        XCTAssertEqual(g?.signatureDisplay, "const g = async (x: number) =>")
        XCTAssertEqual(decl("default()")?.kind, .func)
        XCTAssertEqual(decl("u")?.startLine, 28)
        XCTAssertEqual(decl("w")?.typeAnnotation, "string")
        XCTAssertEqual(decl("NS.k")?.scope, "NS")
        XCTAssertTrue(file.decls.allSatisfy { $0.scope == nil || $0.qualifiedName.hasPrefix($0.scope! + ".") })
    }

    func testCommentsAreCosmetic() {
        let a = TypeScriptExtractor.parse(path: "a.ts", source: "export function f(x: number) {\n  return x + 1;\n}\n").decls[0]
        let b = TypeScriptExtractor.parse(path: "a.ts", source: "export function f(x:number) {\n  // one more\n  return x+1\n}\n").decls[0]
        XCTAssertEqual(a.signatureCanon, b.signatureCanon)
        XCTAssertEqual(a.bodyCanon, b.bodyCanon)
        XCTAssertNotEqual(a.rawText, b.rawText)
        XCTAssertTrue(TypeScriptExtractor.parse(path: "empty.ts", source: "").decls.isEmpty)
    }

    func testReferences() {
        let source = """
            import React, { useState as useLocal, type FC } from "react";
            import * as api from "../api/client.js";
            import { Cart } from "./cart";
            import { format } from "@shop/core/money";
            import "node:fs";
            export { Price } from "./price";

            export function view(cart: Cart): FC {
              const [x] = useLocal(0);
              api.fetchCart(cart.id);
              const t: api.Total = format(cart.total);
              return lazy(() => import("./lazy"));
            }
            """
        let file = TypeScriptExtractor.parse(path: "src/app/view.tsx", source: source)
        XCTAssertEqual(file.imports.map(\.name), ["react", "@shop/core", "fs"], "packages only; relative imports resolve by path")
        let refs = Set(file.typeRefs.map { "\($0.name)@\($0.line)<\($0.source ?? "-")" })
        XCTAssertTrue(refs.isSuperset(of: [
            "Price@6<src/app/price", "Cart@8<src/app/cart", "useState@9<-", "fetchCart@10<src/api/client",
            "Total@11<src/api/client", "format@11<-", "FC@8<-",
        ]), "\(refs.sorted())")
        XCTAssertFalse(file.typeRefs.contains { $0.name == "x" || $0.name == "lazy" }, "names that aren't imported aren't references")
        XCTAssertEqual(file.typeRefs.first { $0.name == "format" }?.module, "@shop/core")
        XCTAssertTrue(file.memberRefs.contains(NameRef(name: "total", line: 11)))
    }

    func testRiskMarks() {
        let source = """
            function f(x?: string, y: unknown) {
              if (!x) return;
              const a = x!.length;
              const b = y as number;
              const c = [1] as const;
              let d: any = 1;
              // @ts-expect-error
              setTimeout(() => {}, 0);
              await Promise.all([]);
              try { g(); } catch (e) { throw e; }
              invariant(a > 0);
            }
            """
        let marks = TypeScriptExtractor.parse(path: "a.ts", source: source).marks
        func labels(_ line: Int) -> Set<String> { Set((marks[line] ?? []).map { "\($0.kind.rawValue):\($0.label)" }) }
        XCTAssertEqual(labels(2), ["flow:if", "check:early return", "flow:early return"])
        XCTAssertEqual(labels(3), ["crash:non-null assertion"])
        XCTAssertEqual(labels(4), ["crash:type assertion"])
        XCTAssertEqual(labels(5), [], "`as const` isn't an assertion")
        XCTAssertEqual(labels(6), ["crash:any"])
        XCTAssertEqual(labels(7), ["crash:type check suppressed"])
        XCTAssertEqual(labels(8), ["concurrency:setTimeout"])
        XCTAssertEqual(labels(9), ["concurrency:Promise.all"])
        XCTAssertEqual(labels(10), ["flow:catch", "check:throw", "flow:throw"])
        XCTAssertEqual(labels(11), ["check:invariant"])
    }

    func testTSXAndViewCode() {
        let source = """
            export const Badge = ({ n }: { n: number }) => <span>{n > 0 ? n : null}</span>;
            export function useCount(): number { return 1; }
            """
        let file = TypeScriptExtractor.parse(path: "Badge.tsx", source: source)
        let lang = TypeScriptLanguage()
        XCTAssertTrue(lang.isViewCode(file.decls[0], inherits: []))
        XCTAssertFalse(lang.isViewCode(file.decls[1], inherits: []))
        XCTAssertEqual(file.marks[1]?.map(\.label), ["?:"])
    }

    func testModuleSpecifiers() {
        XCTAssertEqual(TypeScriptLanguage.packageName("@scope/pkg/sub/path"), "@scope/pkg")
        XCTAssertEqual(TypeScriptLanguage.packageName("lodash/fp"), "lodash")
        XCTAssertEqual(TypeScriptLanguage.packageName("node:fs/promises"), "fs")
        XCTAssertNil(TypeScriptLanguage.packageName("@/components/Button"))
        XCTAssertNil(TypeScriptLanguage.packageName("virtual:pwa"))
        XCTAssertEqual(TypeScriptLanguage.resolve("./cart.js", from: "src/app/main.ts"), "src/app/cart")
        XCTAssertEqual(TypeScriptLanguage.resolve("../models", from: "src/app/main.ts"), "src/models")
        XCTAssertEqual(TypeScriptLanguage.resolve("./foo.service", from: "a.ts"), "foo.service")
        XCTAssertNil(TypeScriptLanguage.resolve("../../x", from: "src/a.ts"))
    }

    func testLockfiles() throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-locks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let files = [
            "package.json": #"{ "dependencies": { "react": "^18" }, "devDependencies": { "typescript": "^5" } }"#,
            "web/package.json": #"{ "dependencies": { "zod": "^3", "lodash": "^4", "left-pad": "^1" } }"#,
            // Transitive packages are left out.
            "package-lock.json": #"{ "packages": { "node_modules/react": { "version": "18.3.1" }, "node_modules/scheduler": { "version": "0.23.2" }, "node_modules/a/node_modules/react": { "version": "17.0.0" } } }"#,
            "web/pnpm-lock.yaml": """
                ---
                lockfileVersion: '9.0'
                importers:
                  .:
                    packageManagerDependencies:
                      pnpm: {specifier: 10.0.0, version: 10.0.0}
                ---
                lockfileVersion: '9.0'
                importers:
                  .:
                    dependencies:
                      zod:
                        specifier: ^3
                        version: 3.23.8(typescript@5.6.0)
                """,
            "web/yarn.lock": """
                # yarn lockfile v1

                "lodash@^4.17.0", lodash@^4.17.21:
                  version "4.17.21"
                  resolved "https://registry.yarnpkg.com/lodash/-/lodash-4.17.21.tgz"
                """,
            "web/bun.lock": #"{ "lockfileVersion": 1, "packages": { "left-pad": ["left-pad@1.3.0", "", {}, "sha512-x"], } }"#,
        ]
        var blobs: [String: String] = [:]
        for (path, text) in files {
            let full = root + "/" + path
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: full, atomically: true, encoding: .utf8)
            blobs[path] = "x"
        }
        XCTAssertEqual(TypeScriptComponents.pinnedPackages(blobs: blobs, dir: root),
                       ["react": "18.3.1", "zod": "3.23.8", "lodash": "4.17.21", "left-pad": "1.3.0"])
    }

    func testJSONWithComments() throws {
        let text = """
            {
              // comment
              "a": "http://x", /* block */
              "b": [1, 2,],
            }
            """
        let obj = try JSONSerialization.jsonObject(with: Data(TypeScriptComponents.stripJSONComments(text).utf8)) as? [String: Any]
        XCTAssertEqual(obj?["a"] as? String, "http://x")
        XCTAssertEqual((obj?["b"] as? [Int]), [1, 2])
    }

    func testIndexProjects() throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-ts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let files = [
            "tsconfig.json": #"{ "references": [{ "path": "packages/a" }] }"#,
            "packages/a/tsconfig.json": "{}",
            "packages/a/test/tsconfig.json": "{}",
            "tools/tsconfig.json": "{}",
            "tools/x/tsconfig.json": "{}",
        ]
        for (path, text) in files {
            let full = root + "/" + path
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: full, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(TypeScriptIndex.projectDirs(root), [".", "packages/a", "tools"])
        XCTAssertEqual(TypeScriptIndex.installDirs(root), [], "no package.json")
        for path in ["web/package.json", "web/yarn.lock", "web/packages/a/package.json", "tools/package.json"] {
            let full = root + "/" + path
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try "{}".write(toFile: full, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(TypeScriptIndex.installDirs(root), ["web"], "lockfiles win")
        try FileManager.default.removeItem(atPath: root + "/web/yarn.lock")
        XCTAssertEqual(TypeScriptIndex.installDirs(root), ["tools", "web"])
    }

    // MARK: Fixture

    func testSnapshot() throws {
        try Fixture.checkSnapshot("typescript")
    }

    func testComponents() throws {
        let m = try model()
        XCTAssertEqual(m.analyzer.languages, ["typescript"])
        let kinds = Dictionary(uniqueKeysWithValues: m.components.map { ($0.id, $0.kind) })
        XCTAssertEqual(kinds["npm:@shop/core"], .npmPackage)
        XCTAssertEqual(kinds["tsconfig:tools"], .tsconfig)
        XCTAssertEqual(kinds["folder:scripts"], .folder)
        XCTAssertNil(kinds["npm:shop"], "a workspace root is not a component")
        let tests = try XCTUnwrap(m.components.first { $0.id == "npm:@shop/core:tests" })
        XCTAssertTrue(tests.isTest)
        XCTAssertEqual(tests.module, "@shop/core")
        XCTAssertEqual(m.components.first { $0.id == "npm:@shop/analytics" }?.status, "added")
        XCTAssertEqual(try entity(m, "testTotal()").tags, ["test"])
        XCTAssertTrue(m.warnings.isEmpty, "\(m.warnings)")
    }

    func testEdges() throws {
        let m = try model()
        func edge(_ from: String, _ to: String) -> Edge? { m.edges.first { $0.from == from && $0.to == to } }
        let analytics = try XCTUnwrap(edge("npm:@shop/web", "npm:@shop/analytics"))
        XCTAssertEqual(analytics.status, .added)
        XCTAssertEqual(analytics.symbolsAdded, ["dependency @shop/analytics", "import @shop/analytics", "track"])
        XCTAssertEqual(edge("folder:scripts", "npm:@shop/core")?.symbolsAdded, ["Currency"], "a relative import resolves by path")
        XCTAssertEqual(edge("npm:@shop/web", "ext:zod")?.status, .added)
        XCTAssertEqual(edge("npm:@shop/web", "ext:react")?.status, .unchanged)
        XCTAssertEqual(edge("npm:@shop/core:tests", "npm:@shop/core")?.status, .unchanged)
        // Both core and analytics export `format`; CartView imports only @shop/core.
        XCTAssertTrue(try regions(m, "CartView()", kind: "context").contains { $0.relation == "definition" && $0.component == "npm:@shop/core" })
        XCTAssertNil(edge("npm:@shop/web", "npm:@shop/analytics")?.refs.first { $0.file.hasSuffix("CartView.tsx") })
    }

    func testFlags() throws {
        let m = try model()
        XCTAssertEqual(try entity(m, "CartRepository.load()").contractFlags, ["typescript:interface-member-changed"])
        XCTAssertEqual(try entity(m, "CartRepository.clear()").contractFlags, ["typescript:interface-member-added"])
        XCTAssertEqual(try entity(m, "CartRepository").contractFlags, ["typescript:interface-member-added", "typescript:interface-member-changed"])
        XCTAssertEqual(try entity(m, "Item.name").contractFlags, ["typescript:interface-member-added"])
        XCTAssertEqual(try entity(m, "Currency.GBP").contractFlags, ["typescript:enum-member-added"])
        XCTAssertEqual(try entity(m, "Cart").contractFlags, ["typescript:supertype-added:Serializable"])
        XCTAssertEqual(try entity(m, "Cart.persist()").contractFlags, ["typescript:access-changed:private->public", "typescript:async-added"])
        XCTAssertEqual(try entity(m, "reset()").contractFlags, ["typescript:async-added"])
        XCTAssertEqual(try entity(m, "Serializable").contractFlags, [], "a new interface's members are not flagged one by one")
        XCTAssertEqual(try entity(m, "Serializable.toJSON()").contractFlags, [])
        let settings = try entity(m, "@shop/core build settings")
        XCTAssertEqual(settings.contractFlags, ["typescript:package-exports-changed", "typescript:strictness-changed"])
        XCTAssertEqual(settings.signature.head, "package.json exports = {\".\":\".\\/src\\/index.ts\"}\ntsconfig strict = true")
    }

    func testChangesAndUsage() throws {
        let m = try model()
        XCTAssertEqual(try entity(m, "format()", component: "npm:@shop/core").change, .cosmetic)
        XCTAssertEqual(try entity(m, "round()").changes, [.signature, .body])
        XCTAssertTrue(try entity(m, "Cart").isInterface)
        XCTAssertTrue(try entity(m, "track()").isInterface)
        XCTAssertFalse(try entity(m, "format()", component: "npm:@shop/analytics").isInterface)
        XCTAssertEqual(Set(try entity(m, "Cart.get size").usedBy.map(\.symbol)), ["CartView()"], "member use through an imported type")
        XCTAssertEqual(m.externalDeps, [
            ExternalDepChange(name: "react", change: "bumped", from: "18.2.0", to: "18.3.1"),
            ExternalDepChange(name: "zod", change: "added", from: nil, to: "3.23.8"),
        ])
    }

    func testRegions() throws {
        let m = try model()
        let removed = try regions(m, "Cart.add()", kind: "removed")
        XCTAssertEqual(removed.count, 1)
        XCTAssertTrue(removed[0].reasons.contains("early return removed"))
        XCTAssertGreaterThanOrEqual(removed[0].risk, 0.6)
        XCTAssertEqual(try regions(m, "Cart.first()", kind: "review").first?.reasons, ["new non-null assertion"])
        XCTAssertEqual(try regions(m, "Cart.toJSON()", kind: "review").first?.reasons, ["new any, new type assertion"])
        XCTAssertEqual(try regions(m, "track()", kind: "review").first?.reasons.first, "concurrency: setTimeout")
        let view = try regions(m, "CartView()", kind: "review")
        XCTAssertTrue(view.allSatisfy { $0.reasons.first?.hasPrefix("view control flow") == true && $0.risk < 0.3 })
        XCTAssertTrue(try regions(m, "CartRepository.load()", kind: "context").contains { $0.relation == "conformer" && $0.reasons == ["MemoryRepository.load()"] })
        XCTAssertTrue(try regions(m, "Cart.persist()", kind: "context").contains { $0.relation == "caller" && $0.component == "npm:@shop/web" })
    }
}
