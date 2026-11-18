//! TypeScript and TSX, parsed with tree-sitter-typescript. Declarations come from a walk over the tree,
//! references and risk marks from queries. `.tsx` files use the TSX grammar. A port of the prototype's
//! `TypeScriptExtractor.swift`.
//!
//! Imports are kept as written: `imports` holds every module specifier a file names (static imports,
//! re-exports, `import()` and `require()`), and each use of an imported name is a `type_refs` entry whose
//! `module` is the specifier it came from. Which file or package a specifier names depends on the tree
//! (tsconfig `paths`, package `exports`), so it is resolved later, per revision (see `lang::typescript`).
//! A name declared in another file has to be imported before it can be used, so only imported names are
//! reference candidates.

use super::treesitter::*;
use super::{Declaration, LineMark, MarkKind, NameRef, ParsedFile};
use crate::model::ItemKind;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::sync::OnceLock;
use streaming_iterator::StreamingIterator;
use tree_sitter::{Node, Parser, Query, QueryCursor};

/// Part of the syntax cache key: bump it whenever the output for the same source can change.
pub const PARSER_VERSION: &str = "typescript-1+tree-sitter-typescript-0.23.2";

/// Whether a path is parsed with the TSX grammar. The syntax cache keeps the two apart, since the same
/// blob parses differently under each.
pub fn is_tsx(path: &str) -> bool {
    path.ends_with(".tsx")
}

struct Grammar {
    language: tree_sitter::Language,
    references: Query,
    risk: Query,
    /// The entry of `RISK` behind each pattern of `risk`.
    risk_entries: Vec<&'static RiskEntry>,
}

impl Grammar {
    fn new(language: tree_sitter::Language) -> Grammar {
        let references = Query::new(&language, REFERENCE_QUERY).expect("the TypeScript reference query matches the grammar");
        // A pattern that names a node the grammar lacks (TSX has no `<T>x` assertions) is left out.
        let risk_entries: Vec<&'static RiskEntry> = RISK.iter().filter(|e| Query::new(&language, e.pattern).is_ok()).collect();
        let text: Vec<&str> = risk_entries.iter().map(|e| e.pattern).collect();
        let risk = Query::new(&language, &text.join("\n")).expect("the TypeScript risk query matches the grammar");
        Grammar { language, references, risk, risk_entries }
    }
}

fn grammar(tsx: bool) -> &'static Grammar {
    static TS: OnceLock<Grammar> = OnceLock::new();
    static TSX: OnceLock<Grammar> = OnceLock::new();
    if tsx {
        TSX.get_or_init(|| Grammar::new(tree_sitter_typescript::LANGUAGE_TSX.into()))
    } else {
        TS.get_or_init(|| Grammar::new(tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into()))
    }
}

pub fn parse(source: &str, tsx: bool) -> ParsedFile {
    let g = grammar(tsx);
    let mut parser = Parser::new();
    parser.set_language(&g.language).expect("the TypeScript grammar matches the tree-sitter library");
    let Some(tree) = parser.parse(source, None) else {
        return ParsedFile { language: "typescript".into(), ..Default::default() };
    };
    let root = tree.root_node();
    let mut walker = Walker { source, decls: Vec::new(), stack: vec![Scope::default()] };
    walker.statements(root, &Context::default());
    let refs = references(root, source, &g.references);
    ParsedFile {
        language: "typescript".into(),
        decls: walker.decls,
        imports: refs.imports,
        type_refs: refs.type_refs,
        member_refs: refs.member_refs,
        marks: marks(root, source, g),
        ..Default::default()
    }
}

// MARK: Risk marks

/// One risk signal: a pattern whose `@m` capture is marked. `%` in the label stands for the captured text.
struct RiskEntry {
    kind: MarkKind,
    label: &'static str,
    pattern: &'static str,
}

const EARLY_RETURN: &str = r#"[(if_statement consequence: (return_statement) @m) (if_statement consequence: (statement_block (return_statement) @m)) (else_clause (return_statement) @m) (else_clause (statement_block (return_statement) @m))]"#;

const RISK: &[RiskEntry] = &[
    RiskEntry { kind: MarkKind::Crash, label: "non-null assertion", pattern: r#"(non_null_expression "!" @m)"# },
    RiskEntry { kind: MarkKind::Crash, label: "type assertion", pattern: r#"((as_expression) @m (#not-match? @m "as\\s+const$"))"# },
    RiskEntry { kind: MarkKind::Crash, label: "type assertion", pattern: r#"(type_assertion) @m"# },
    RiskEntry { kind: MarkKind::Crash, label: "any", pattern: r#"((predefined_type) @m (#eq? @m "any"))"# },
    RiskEntry { kind: MarkKind::Crash, label: "type check suppressed", pattern: r#"((comment) @m (#match? @m "@ts-(ignore|expect-error|nocheck)"))"# },
    RiskEntry { kind: MarkKind::Check, label: "throw", pattern: r#"(throw_statement) @m"# },
    RiskEntry { kind: MarkKind::Flow, label: "throw", pattern: r#"(throw_statement) @m"# },
    RiskEntry { kind: MarkKind::Check, label: "early return", pattern: EARLY_RETURN },
    RiskEntry { kind: MarkKind::Flow, label: "early return", pattern: EARLY_RETURN },
    RiskEntry { kind: MarkKind::Check, label: "%", pattern: r#"(call_expression function: (identifier) @m (#any-of? @m "assert" "invariant"))"# },
    RiskEntry {
        kind: MarkKind::Check,
        label: "assert",
        pattern: r#"(call_expression function: (member_expression object: (identifier) @o property: (property_identifier) @m) (#any-of? @o "assert" "console") (#match? @m "^(assert|ok|equal|strictEqual|deepEqual|deepStrictEqual)$"))"#,
    },
    RiskEntry { kind: MarkKind::Flow, label: "if", pattern: r#"(if_statement) @m"# },
    RiskEntry { kind: MarkKind::Flow, label: "switch", pattern: r#"(switch_statement) @m"# },
    RiskEntry { kind: MarkKind::Flow, label: "?:", pattern: r#"(ternary_expression) @m"# },
    RiskEntry { kind: MarkKind::Flow, label: "for", pattern: r#"[(for_statement) (for_in_statement)] @m"# },
    RiskEntry { kind: MarkKind::Flow, label: "while", pattern: r#"[(while_statement) (do_statement)] @m"# },
    RiskEntry { kind: MarkKind::Flow, label: "catch", pattern: r#"(catch_clause) @m"# },
    RiskEntry { kind: MarkKind::Flow, label: "catch", pattern: r#"(call_expression function: (member_expression property: (property_identifier) @m (#eq? @m "catch")))"# },
    RiskEntry { kind: MarkKind::Flow, label: "break", pattern: r#"(break_statement) @m"# },
    RiskEntry { kind: MarkKind::Flow, label: "continue", pattern: r#"(continue_statement) @m"# },
    RiskEntry { kind: MarkKind::Concurrency, label: "new Promise", pattern: r#"(new_expression constructor: (identifier) @m (#eq? @m "Promise"))"# },
    RiskEntry {
        kind: MarkKind::Concurrency,
        label: "Promise.%",
        pattern: r#"(call_expression function: (member_expression object: (identifier) @o property: (property_identifier) @m) (#eq? @o "Promise") (#any-of? @m "all" "allSettled" "race" "any"))"#,
    },
    RiskEntry {
        kind: MarkKind::Concurrency,
        label: "%",
        pattern: r#"(call_expression function: (identifier) @m (#any-of? @m "setTimeout" "setInterval" "setImmediate" "queueMicrotask" "requestAnimationFrame"))"#,
    },
    RiskEntry {
        kind: MarkKind::Concurrency,
        label: "new %",
        pattern: r#"(new_expression constructor: (identifier) @m (#any-of? @m "Worker" "SharedWorker" "SharedArrayBuffer" "MessageChannel"))"#,
    },
    RiskEntry { kind: MarkKind::Concurrency, label: "Atomics", pattern: r#"(member_expression object: (identifier) @m (#eq? @m "Atomics"))"# },
];

fn marks(root: Node, source: &str, g: &Grammar) -> BTreeMap<u32, Vec<LineMark>> {
    let m_index = g.risk.capture_index_for_name("m");
    let mut cursor = QueryCursor::new();
    let mut out: BTreeMap<u32, Vec<LineMark>> = BTreeMap::new();
    let mut matches = cursor.matches(&g.risk, root, source.as_bytes());
    while let Some(m) = matches.next() {
        let Some(node) = m.captures.iter().find(|c| Some(c.index) == m_index).map(|c| c.node) else { continue };
        let entry = g.risk_entries[m.pattern_index];
        let mark = LineMark { kind: entry.kind, label: entry.label.replace('%', text(node, source)) };
        let list = out.entry(start_line(node)).or_default();
        if !list.contains(&mark) {
            list.push(mark);
        }
    }
    out
}

// MARK: References

const REFERENCE_QUERY: &str = r#"
(identifier) @id
(type_identifier) @id
(shorthand_property_identifier) @id
(nested_type_identifier module: (identifier) @ns name: (type_identifier) @member)
(member_expression object: (identifier) @ns property: (property_identifier) @member)
(member_expression property: (property_identifier) @member)
(call_expression function: (import) arguments: (arguments (string (string_fragment) @module)))
(call_expression function: (identifier) @require arguments: (arguments (string (string_fragment) @module)) (#eq? @require "require"))
"#;

#[derive(Default)]
struct References {
    imports: Vec<NameRef>,
    type_refs: Vec<NameRef>,
    member_refs: Vec<NameRef>,
}

struct Binding {
    /// The exported name, or None for a namespace import (`import * as api`, `import x = require()`).
    name: Option<String>,
    specifier: String,
}

fn specifier(string: Option<Node>, source: &str) -> Option<String> {
    let string = string?;
    named_children(string).into_iter().find(|c| c.kind() == "string_fragment").map(|f| text(f, source).to_string())
}

fn capture<'t>(m: &tree_sitter::QueryMatch<'_, 't>, index: Option<u32>) -> Option<Node<'t>> {
    m.captures.iter().find(|c| Some(c.index) == index).map(|c| c.node)
}

fn name_ref(name: &str, line: u32, module: Option<&str>) -> NameRef {
    NameRef { name: name.to_string(), line, module: module.map(str::to_string), end_line: None }
}

/// What a file imports, and the uses of imported names.
fn references(root: Node, source: &str, query: &Query) -> References {
    let mut out = References::default();
    let mut bindings: HashMap<String, Binding> = HashMap::new();
    let mut body: Vec<Node> = Vec::new();
    let import = |out: &mut References, spec: &str, node: Node| {
        let (start, end) = (start_line(node), end_line(node));
        out.imports.push(NameRef { name: spec.to_string(), line: start, module: None, end_line: (end > start).then_some(end) });
    };
    for stmt in named_children(root) {
        match stmt.kind() {
            "import_statement" => {
                let spec = specifier(stmt.child_by_field_name("source"), source).or_else(|| {
                    named_children(stmt).into_iter().find(|c| c.kind() == "import_require_clause").and_then(|c| specifier(c.child_by_field_name("source"), source))
                });
                let Some(spec) = spec else { continue };
                import(&mut out, &spec, stmt);
                for clause in named_children(stmt).into_iter().filter(|c| c.kind() == "import_clause" || c.kind() == "import_require_clause") {
                    for part in named_children(clause) {
                        match part.kind() {
                            "identifier" => {
                                // A default import binds the module's `default`; `import x = require()` the whole module.
                                let name = (clause.kind() == "import_clause").then(|| "default".to_string());
                                bindings.insert(text(part, source).to_string(), Binding { name, specifier: spec.clone() });
                            }
                            "namespace_import" => {
                                if let Some(id) = named_children(part).into_iter().next() {
                                    bindings.insert(text(id, source).to_string(), Binding { name: None, specifier: spec.clone() });
                                }
                            }
                            "named_imports" => {
                                for s in named_children(part).into_iter().filter(|s| s.kind() == "import_specifier") {
                                    let Some(name) = s.child_by_field_name("name") else { continue };
                                    let local = s.child_by_field_name("alias").unwrap_or(name);
                                    bindings.insert(text(local, source).to_string(), Binding { name: Some(text(name, source).to_string()), specifier: spec.clone() });
                                }
                            }
                            _ => {}
                        }
                    }
                }
            }
            "export_statement" if stmt.child_by_field_name("source").is_some() => {
                // A re-export (`export { Cart } from "./cart"`) uses the names it passes on.
                let Some(spec) = specifier(stmt.child_by_field_name("source"), source) else { continue };
                import(&mut out, &spec, stmt);
                for clause in named_children(stmt).into_iter().filter(|c| c.kind() == "export_clause") {
                    for s in named_children(clause).into_iter().filter(|s| s.kind() == "export_specifier") {
                        if let Some(name) = s.child_by_field_name("name") {
                            out.type_refs.push(name_ref(text(name, source), start_line(s), Some(&spec)));
                        }
                    }
                }
            }
            _ => body.push(stmt),
        }
    }
    let id = query.capture_index_for_name("id");
    let ns = query.capture_index_for_name("ns");
    let member = query.capture_index_for_name("member");
    let module = query.capture_index_for_name("module");
    let mut cursor = QueryCursor::new();
    for stmt in body {
        let mut matches = cursor.matches(query, stmt, source.as_bytes());
        while let Some(m) = matches.next() {
            if let Some(node) = capture(m, id) {
                if let Some(Binding { name: Some(name), specifier }) = bindings.get(text(node, source)) {
                    out.type_refs.push(name_ref(name, start_line(node), Some(specifier)));
                }
            } else if let Some(node) = capture(m, module) {
                import(&mut out, text(node, source), node);
            } else if let Some(node) = capture(m, member) {
                match capture(m, ns) {
                    Some(namespace) => {
                        if let Some(Binding { name: None, specifier }) = bindings.get(text(namespace, source)) {
                            out.type_refs.push(name_ref(text(node, source), start_line(node), Some(specifier)));
                        }
                    }
                    None => out.member_refs.push(name_ref(text(node, source), start_line(node), None)),
                }
            }
        }
    }
    out
}

// MARK: Declarations

/// Keywords and decorators that a wrapper (`export`, `declare`) or a preceding line (a member's decorators)
/// adds to a declaration.
#[derive(Clone, Default)]
struct Context<'t> {
    outer: Option<Node<'t>>,
    modifiers: Vec<String>,
    decorators: Vec<Node<'t>>,
}

const MODIFIER_KEYWORDS: &[&str] = &["export", "default", "declare", "abstract", "static", "readonly", "async", "override", "accessor", "const", "get", "set", "*"];
const FUNCTION_VALUES: &[&str] = &["arrow_function", "function_expression", "generator_function", "function"];

#[derive(Clone, Default)]
struct Scope {
    qualified: Option<String>,
    index: Option<usize>,
    kind: Option<ItemKind>,
}

struct Walker<'s> {
    source: &'s str,
    decls: Vec<Declaration>,
    stack: Vec<Scope>,
}

#[derive(Default)]
struct Add<'t> {
    qualified: Option<String>,
    body: Option<Node<'t>>,
    inherited: Vec<String>,
    header_end: Option<Node<'t>>,
    function: Option<Node<'t>>,
    stored: bool,
    type_node: Option<Node<'t>>,
}

impl<'s> Walker<'s> {
    fn current(&self) -> &Scope {
        self.stack.last().expect("the walker has a scope")
    }

    fn qualify(&self, name: &str) -> String {
        match &self.current().qualified {
            Some(q) => format!("{q}.{name}"),
            None => name.to_string(),
        }
    }

    fn text(&self, n: Node) -> &'s str {
        text(n, self.source)
    }

    fn statements<'t>(&mut self, block: Node<'t>, ctx: &Context<'t>) {
        for stmt in named_children(block) {
            self.statement(stmt, ctx);
        }
    }

    fn statement<'t>(&mut self, n: Node<'t>, ctx: &Context<'t>) {
        let mut ctx = ctx.clone();
        match n.kind() {
            "export_statement" => {
                ctx.outer = ctx.outer.or(Some(n));
                ctx.modifiers.push("export".into());
                if children(n).iter().any(|c| c.kind() == "default" && !c.is_named()) {
                    ctx.modifiers.push("default".into());
                }
                ctx.decorators.extend(named_children(n).into_iter().filter(|c| c.kind() == "decorator"));
                if let Some(d) = n.child_by_field_name("declaration") {
                    self.statement(d, &ctx);
                } else if let Some(v) = n.child_by_field_name("value") {
                    if FUNCTION_VALUES.contains(&v.kind()) || v.kind() == "class" {
                        self.statement(v, &ctx);
                    }
                }
            }
            "ambient_declaration" => {
                ctx.outer = ctx.outer.or(Some(n));
                ctx.modifiers.push("declare".into());
                for c in named_children(n) {
                    if c.kind() == "statement_block" {
                        self.statements(c, &Context::default());
                    } else {
                        self.statement(c, &ctx);
                    }
                }
            }
            "class_declaration" | "abstract_class_declaration" | "class" => self.container(n, ItemKind::Class, "class", &ctx),
            "interface_declaration" => self.container(n, ItemKind::Protocol, "interface", &ctx),
            "enum_declaration" => self.container(n, ItemKind::Enum, "enum", &ctx),
            "type_alias_declaration" => {
                let start = keyword_start(n, "type").unwrap_or(n.start_byte());
                let name = n.child_by_field_name("name").map(|x| self.text(x).to_string()).unwrap_or_default();
                let header = tokens(n).into_iter().filter(|t| t.start_byte() >= start).collect();
                self.add(n, &ctx, ItemKind::Typealias, &name, &name, header, Add::default());
            }
            "function_declaration" | "generator_function_declaration" | "function_signature" | "function_expression" | "generator_function" => {
                let name = n.child_by_field_name("name").map(|x| self.text(x).to_string()).unwrap_or_else(|| "default".to_string());
                let body = n.child_by_field_name("body");
                let start = keyword_start(n, "function").unwrap_or(n.start_byte());
                let end = body.map(|b| b.start_byte()).unwrap_or(usize::MAX);
                let header = tokens(n).into_iter().filter(|t| t.start_byte() >= start && t.start_byte() < end).collect();
                let labels = format!("{name}{}", self.labels(n));
                let qualified = self.qualify(&format!("{name}()"));
                self.add(n, &ctx, ItemKind::Func, &name, &labels, header, Add { qualified: Some(qualified), body, ..Default::default() });
            }
            "lexical_declaration" | "variable_declaration" => self.variables(n, &ctx),
            "module" | "internal_module" => {
                let (Some(name), Some(body)) = (n.child_by_field_name("name"), n.child_by_field_name("body")) else { return };
                let label = if name.kind() == "string" {
                    named_children(name).into_iter().next().map(|f| self.text(f).to_string()).unwrap_or_else(|| self.text(name).to_string())
                } else {
                    self.text(name).to_string()
                };
                let scope = Scope { qualified: Some(self.qualify(&label)), index: self.current().index, kind: self.current().kind };
                self.stack.push(scope);
                self.statements(body, &Context::default());
                self.stack.pop();
            }
            "expression_statement" => {
                for c in named_children(n).into_iter().filter(|c| c.kind() == "internal_module") {
                    self.statement(c, &ctx);
                }
            }
            _ => {}
        }
    }

    /// "(a:b:)" from the parameter names, to pair overloads.
    fn labels(&self, n: Node) -> String {
        let Some(params) = n.child_by_field_name("parameters") else { return "()".to_string() };
        let names: String = named_children(params).into_iter().map(|p| format!("{}:", self.text(p.child_by_field_name("pattern").unwrap_or(p)))).collect();
        format!("({names})")
    }

    fn base_name(&self, t: Node) -> String {
        let n = if t.kind() == "generic_type" { t.child_by_field_name("name").unwrap_or(t) } else { t };
        let s = self.text(n);
        s.rsplit('.').next().unwrap_or(s).to_string()
    }

    fn container<'t>(&mut self, n: Node<'t>, kind: ItemKind, keyword: &str, ctx: &Context<'t>) {
        let Some(body) = n.child_by_field_name("body") else { return };
        let name = n.child_by_field_name("name").map(|x| self.text(x).to_string()).unwrap_or_else(|| "default".to_string());
        let mut inherited: Vec<String> = Vec::new();
        for c in named_children(n) {
            match c.kind() {
                "class_heritage" => {
                    for clause in named_children(c) {
                        // `extends` comes first, so the superclass is the first inherited name.
                        inherited.extend(named_children(clause).into_iter().filter(|x| x.kind() != "type_arguments").map(|x| self.base_name(x)));
                    }
                }
                "extends_type_clause" => inherited.extend(named_children(c).into_iter().map(|x| self.base_name(x))),
                _ => {}
            }
        }
        let start = keyword_start(n, keyword).unwrap_or(n.start_byte());
        // Supertypes stay in the compared header, type arguments included (`Base<string>` -> `Base<number>`).
        let header = tokens(n).into_iter().filter(|t| t.start_byte() >= start && t.start_byte() < body.start_byte()).collect();
        let index = self.add(n, ctx, kind, &name, &name, header, Add { inherited, header_end: Some(body), ..Default::default() });
        self.stack.push(Scope { qualified: Some(self.qualify(&name)), index: Some(index), kind: Some(kind) });
        if kind == ItemKind::Enum {
            for m in named_children(body) {
                let name_node = if m.kind() == "enum_assignment" { m.child_by_field_name("name") } else { Some(m) };
                let Some(label) = name_node.map(|x| self.text(x).to_string()) else { continue };
                self.add(m, &Context::default(), ItemKind::Case, &label, &label, tokens(m), Add::default());
            }
        } else {
            let mut decorators: Vec<Node<'t>> = Vec::new();
            for m in named_children(body) {
                if m.kind() == "decorator" {
                    decorators.push(m);
                    continue;
                }
                let member_ctx = Context { decorators: std::mem::take(&mut decorators), ..Default::default() };
                self.member(m, &member_ctx);
            }
        }
        self.stack.pop();
    }

    fn member<'t>(&mut self, n: Node<'t>, ctx: &Context<'t>) {
        let name_node = n.child_by_field_name("name").or(if n.kind() == "index_signature" { Some(n) } else { None });
        let Some(name_node) = name_node else {
            match n.kind() {
                "call_signature" => {
                    let labels = format!("call{}", self.labels(n));
                    let qualified = self.qualify("call()");
                    self.add(n, ctx, ItemKind::Func, "call", &labels, tokens(n), Add { qualified: Some(qualified), ..Default::default() });
                }
                "construct_signature" => {
                    let labels = format!("new{}", self.labels(n));
                    let qualified = self.qualify("new()");
                    self.add(n, ctx, ItemKind::Init, "new", &labels, tokens(n), Add { qualified: Some(qualified), ..Default::default() });
                }
                _ => {}
            }
            return;
        };
        let name = if n.kind() == "index_signature" { "[index]".to_string() } else { self.text(name_node).to_string() };
        let from_name: Vec<Node<'t>> = tokens(n).into_iter().filter(|t| t.start_byte() >= name_node.start_byte()).collect();
        match n.kind() {
            "method_definition" | "method_signature" | "abstract_method_signature" => {
                let body = n.child_by_field_name("body");
                let end = body.map(|b| b.start_byte()).unwrap_or(usize::MAX);
                let header: Vec<Node> = from_name.iter().copied().filter(|t| t.start_byte() < end).collect();
                if let Some(accessor) = children(n).into_iter().find(|c| !c.is_named() && (c.kind() == "get" || c.kind() == "set")) {
                    let key = format!("{} {name}", accessor.kind());
                    let header = tokens(n).into_iter().filter(|t| t.start_byte() >= accessor.start_byte() && t.start_byte() < end).collect();
                    let qualified = self.qualify(&key);
                    self.add(n, ctx, ItemKind::Var, &name, &key, header, Add { qualified: Some(qualified), body, ..Default::default() });
                } else if name == "constructor" {
                    let labels = format!("{name}{}", self.labels(n));
                    let qualified = self.qualify("constructor()");
                    self.add(n, ctx, ItemKind::Init, &name, &labels, header, Add { qualified: Some(qualified), body, ..Default::default() });
                } else {
                    let labels = format!("{name}{}", self.labels(n));
                    let qualified = self.qualify(&format!("{name}()"));
                    self.add(n, ctx, ItemKind::Func, &name, &labels, header, Add { qualified: Some(qualified), body, ..Default::default() });
                }
            }
            "public_field_definition" | "property_signature" | "index_signature" => {
                let value = n.child_by_field_name("value");
                match value.filter(|v| FUNCTION_VALUES.contains(&v.kind())) {
                    Some(function) => {
                        let body = function.child_by_field_name("body");
                        let end = body.map(|b| b.start_byte()).unwrap_or(usize::MAX);
                        let header = from_name.into_iter().filter(|t| t.start_byte() < end).collect();
                        let labels = format!("{name}{}", self.labels(function));
                        let qualified = self.qualify(&format!("{name}()"));
                        self.add(n, ctx, ItemKind::Func, &name, &labels, header, Add { qualified: Some(qualified), body, function: Some(function), ..Default::default() });
                    }
                    None => {
                        let end = value.map(|v| v.start_byte()).unwrap_or(usize::MAX);
                        let mut header: Vec<Node> = from_name.into_iter().filter(|t| t.start_byte() < end).collect();
                        if header.last().map(|t| t.kind() == "=").unwrap_or(false) {
                            header.pop();
                        }
                        let stored = n.kind() == "public_field_definition";
                        self.add(n, ctx, ItemKind::Var, &name, &name, header, Add { body: value, stored, type_node: n.child_by_field_name("type"), ..Default::default() });
                    }
                }
            }
            _ => {}
        }
    }

    fn variables<'t>(&mut self, n: Node<'t>, ctx: &Context<'t>) {
        let Some(keyword) = children(n).into_iter().find(|c| !c.is_named()) else { return };
        let declarators: Vec<Node<'t>> = named_children(n).into_iter().filter(|c| c.kind() == "variable_declarator").collect();
        let several = declarators.len() > 1;
        for (i, v) in declarators.iter().copied().enumerate() {
            let Some(name_node) = v.child_by_field_name("name").filter(|x| x.kind() == "identifier") else { continue };
            let name = self.text(name_node).to_string();
            // A single declarator spans the whole statement; with several, each spans its own text.
            let mut c = ctx.clone();
            if several {
                c.outer = if i == 0 { ctx.outer.or(Some(n)) } else { Some(v) };
                if i > 0 {
                    c.decorators.clear();
                }
            } else {
                c.outer = ctx.outer.or(Some(n));
            }
            let span = if several { v } else { n };
            let value = v.child_by_field_name("value");
            match value.filter(|x| FUNCTION_VALUES.contains(&x.kind())) {
                Some(function) => {
                    let body = function.child_by_field_name("body");
                    let end = body.map(|b| b.start_byte()).unwrap_or(usize::MAX);
                    let mut header = vec![keyword];
                    header.extend(tokens(v).into_iter().filter(|t| t.start_byte() < end));
                    let labels = format!("{name}{}", self.labels(function));
                    let qualified = self.qualify(&format!("{name}()"));
                    self.add(span, &c, ItemKind::Func, &name, &labels, header, Add { qualified: Some(qualified), body, function: Some(function), ..Default::default() });
                }
                None => {
                    let end = value.map(|x| x.start_byte()).unwrap_or(usize::MAX);
                    let mut rest: Vec<Node> = tokens(v).into_iter().filter(|t| t.start_byte() < end).collect();
                    if rest.last().map(|t| t.kind() == "=").unwrap_or(false) {
                        rest.pop();
                    }
                    let mut header = vec![keyword];
                    header.extend(rest);
                    self.add(span, &c, ItemKind::Var, &name, &name, header, Add { body: value, stored: true, type_node: v.child_by_field_name("type"), ..Default::default() });
                }
            }
        }
    }

    /// Adds a declaration. `n` is the declaration's own node; the context's outer node (an `export` or
    /// `declare`, or the first decorator) widens its lines.
    #[allow(clippy::too_many_arguments)]
    fn add<'t>(&mut self, n: Node<'t>, ctx: &Context<'t>, kind: ItemKind, name: &str, labels_key: &str, header: Vec<Node<'t>>, opts: Add<'t>) -> usize {
        let source = self.source;
        let mut modifiers: Vec<String> = ctx.modifiers.clone();
        let mut access: Option<String> = None;
        let mut decorators: Vec<Node> = ctx.decorators.clone();
        let header_ids: BTreeSet<usize> = header.iter().map(|t| t.id()).collect();
        for c in children(n) {
            if c.kind() == "decorator" {
                decorators.push(c);
                continue;
            }
            if c.kind() == "accessibility_modifier" {
                access = Some(text(c, source).to_string());
                continue;
            }
            if c.kind() == "override_modifier" {
                modifiers.push("override".into());
                continue;
            }
            if !c.is_named() && MODIFIER_KEYWORDS.contains(&c.kind()) && !header_ids.contains(&c.id()) {
                modifiers.push(c.kind().to_string());
            }
        }
        let mut traits: BTreeSet<String> = BTreeSet::new();
        if children(n).iter().any(|c| !c.is_named() && c.kind() == "?") {
            traits.insert("optional".into());
        }
        if opts.body.map(contains_jsx).unwrap_or(false) {
            traits.insert("jsx".into());
        }
        if let Some(function) = opts.function {
            if children(function).iter().any(|c| !c.is_named() && c.kind() == "async") {
                modifiers.push("async".into());
            }
        }
        if n.child_by_field_name("name").map(|x| x.kind() == "private_property_identifier").unwrap_or(false) {
            access = Some("#private".into());
        }
        let mut modifier_parts: Vec<String> = decorators.iter().map(|d| canon(&tokens(*d), source)).collect();
        modifier_parts.extend(access.clone());
        modifier_parts.extend(modifiers.iter().cloned());
        let first = decorators.first().copied().or(ctx.outer).unwrap_or(n);
        let start = start_line(first).min(ctx.outer.map(start_line).unwrap_or(start_line(n)));
        let start_byte = first.start_byte().min(ctx.outer.map(|o| o.start_byte()).unwrap_or(n.start_byte()));
        let container = matches!(kind, ItemKind::Class | ItemKind::Protocol | ItemKind::Enum);
        let raw_end = if container { opts.header_end.map(|h| h.start_byte()).unwrap_or(n.end_byte()) } else { n.end_byte() };
        // Semicolons are optional, so adding or dropping one is cosmetic.
        let mut header = header;
        if header.last().map(|t| t.kind() == ";").unwrap_or(false) {
            header.pop();
        }
        let canon_of = |toks: &[Node]| canon(&toks.iter().copied().filter(|t| t.kind() != ";").collect::<Vec<_>>(), source);
        let scope = self.current().clone();
        let header_end_line = opts.header_end.or(opts.body).map(start_line).unwrap_or(end_line(n)).max(start);
        let d = Declaration {
            kind,
            name: name.to_string(),
            qualified_name: opts.qualified.unwrap_or_else(|| self.qualify(name)),
            scope: scope.qualified.clone(),
            parent_index: scope.index,
            labels_key: labels_key.to_string(),
            signature_display: display(&header, source),
            signature_canon: canon_of(&header),
            modifiers_canon: modifier_parts.join(" "),
            body_canon: opts.body.map(|b| canon_of(&tokens(b))).unwrap_or_default(),
            raw_text: source.get(start_byte..raw_end.max(start_byte)).unwrap_or("").to_string(),
            access,
            attributes: decorators.iter().map(|d| decorator_name(*d, source)).collect(),
            is_static: modifiers.iter().any(|m| m == "static"),
            is_async: modifiers.iter().any(|m| m == "async"),
            modifiers,
            inherited: opts.inherited,
            is_throws: false,
            throws_type: None,
            is_stored: opts.stored,
            type_annotation: opts.type_node.map(|t| text(t, source).trim_start_matches([':', ' ']).to_string()),
            in_protocol: scope.kind == Some(ItemKind::Protocol),
            parent_kind: scope.kind,
            start_line: start,
            end_line: end_line(n),
            header_end_line,
            traits,
        };
        self.decls.push(d);
        self.decls.len() - 1
    }
}

/// Start of the first anonymous `keyword` token among a node's children.
fn keyword_start(n: Node, keyword: &str) -> Option<usize> {
    children(n).into_iter().find(|c| !c.is_named() && c.kind() == keyword).map(|c| c.start_byte())
}

fn contains_jsx(node: Node) -> bool {
    find_first_prefix(node, "jsx_")
}

fn find_first_prefix(node: Node, prefix: &str) -> bool {
    let mut found = false;
    for_each(node, &mut |n| {
        if found {
            return false;
        }
        if n.kind().starts_with(prefix) {
            found = true;
            return false;
        }
        true
    });
    found
}

/// "Component" for `@Component({...})`, "Input" for `@Input()`.
fn decorator_name(d: Node, source: &str) -> String {
    let Some(expr) = named_children(d).into_iter().next() else { return text(d, source).to_string() };
    let callee = if expr.kind() == "call_expression" { expr.child_by_field_name("function").unwrap_or(expr) } else { expr };
    let s = text(callee, source);
    s.rsplit('.').next().unwrap_or(s).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn declarations() {
        let source = r#"import { Money, type Currency } from "./money";
import * as api from "@acme/api/client";
import Default from "lodash";

/** A cart. */
export interface Repository<T> extends Base<T> {
  load(id: string): Promise<T>;
  readonly size?: number;
}

export abstract class Cart extends Base implements Repository<Item> {
  @Input() items: Item[] = [];
  #secret = 1;
  constructor(private readonly store: Store) {
    super();
  }
  static create(): Cart {
    return new Cart(api.makeStore());
  }
  get total(): Money {
    if (!this.items.length) return Money.zero;
    return this.items.reduce((a, b) => a.add(b.price), Money.zero)!;
  }
  abstract clear(): void;
  handle = async (event: Event) => {
    await Promise.all([]);
  };
}

export enum Status { Open = "open", Closed }
export const enum Fast { A }
export type Id = string;
export function render(cart: Cart): JSX.Element { return null as any; }
export default function () {}
const a = 1, b = (x: number) => x;
namespace Inner { export function helper() {} }
declare module "virtual:config" { export const flag: boolean; }
"#;
        let file = parse(source, false);
        let names: Vec<(&str, ItemKind)> = file.decls.iter().map(|d| (d.qualified_name.as_str(), d.kind)).collect();
        assert_eq!(
            names,
            vec![
                ("Repository", ItemKind::Protocol),
                ("Repository.load()", ItemKind::Func),
                ("Repository.size", ItemKind::Var),
                ("Cart", ItemKind::Class),
                ("Cart.items", ItemKind::Var),
                ("Cart.#secret", ItemKind::Var),
                ("Cart.constructor()", ItemKind::Init),
                ("Cart.create()", ItemKind::Func),
                ("Cart.get total", ItemKind::Var),
                ("Cart.clear()", ItemKind::Func),
                ("Cart.handle()", ItemKind::Func),
                ("Status", ItemKind::Enum),
                ("Status.Open", ItemKind::Case),
                ("Status.Closed", ItemKind::Case),
                ("Fast", ItemKind::Enum),
                ("Fast.A", ItemKind::Case),
                ("Id", ItemKind::Typealias),
                ("render()", ItemKind::Func),
                ("default()", ItemKind::Func),
                ("a", ItemKind::Var),
                ("b()", ItemKind::Func),
                ("Inner.helper()", ItemKind::Func),
                ("virtual:config.flag", ItemKind::Var),
            ]
        );
        let by = |q: &str| file.decls.iter().find(|d| d.qualified_name == q).unwrap();
        assert_eq!(by("Repository").inherited, vec!["Base".to_string()]);
        assert!(by("Repository.load()").in_protocol);
        assert!(by("Repository.size").traits.contains("optional"));
        assert!(by("Repository.size").modifiers.contains(&"readonly".to_string()));
        let cart = by("Cart");
        assert_eq!(cart.inherited, vec!["Base".to_string(), "Repository".to_string()]);
        assert!(cart.modifiers.contains(&"export".to_string()) && cart.modifiers.contains(&"abstract".to_string()));
        assert_eq!(cart.start_line, 11, "the declaration starts at its export");
        assert_eq!(by("Cart.items").attributes, vec!["Input".to_string()]);
        assert_eq!(by("Cart.#secret").access.as_deref(), Some("#private"));
        assert!(by("Cart.create()").is_static);
        assert!(by("Cart.clear()").modifiers.contains(&"abstract".to_string()));
        assert!(by("Cart.handle()").is_async);
        assert!(by("Fast").modifiers.contains(&"const".to_string()));
        assert!(by("default()").modifiers.contains(&"default".to_string()));
        assert_eq!(by("Status").raw_text.trim_end(), "export enum Status");

        // Imports keep their specifiers, and uses of imported names carry them.
        let imports: Vec<&str> = file.imports.iter().map(|i| i.name.as_str()).collect();
        assert_eq!(imports, vec!["./money", "@acme/api/client", "lodash"]);
        assert!(file.type_refs.iter().any(|r| r.name == "Money" && r.module.as_deref() == Some("./money") && r.line == 20));
        assert!(file.type_refs.iter().any(|r| r.name == "makeStore" && r.module.as_deref() == Some("@acme/api/client")), "a namespace member");
        assert!(!file.type_refs.iter().any(|r| r.name == "Store"), "names that are not imported are no candidates");
        assert!(file.member_refs.iter().any(|r| r.name == "reduce"));

        let marks: Vec<&str> = file.marks.values().flatten().map(|m| m.label.as_str()).collect();
        for label in ["early return", "if", "non-null assertion", "type assertion", "any", "Promise.all"] {
            assert!(marks.contains(&label), "{label} in {marks:?}");
        }
    }

    #[test]
    fn tsx_and_multiline_imports() {
        let source = "import {\n  A,\n  B,\n} from \"../lib\";\nexport const View = () => <div>{A}</div>;\nconst lazy = import(\"./lazy\");\n";
        let file = parse(source, true);
        assert_eq!(file.imports[0].name, "../lib");
        assert_eq!((file.imports[0].line, file.imports[0].end_line), (1, Some(4)));
        assert!(file.imports.iter().any(|i| i.name == "./lazy"));
        assert!(file.decls[0].traits.contains("jsx"));
        assert!(file.type_refs.iter().any(|r| r.name == "A" && r.line == 5));
        // TSX has no `<T>x` assertions; the pattern is left out rather than failing.
        assert!(parse("const x = <any>y;", false).marks.values().flatten().any(|m| m.label == "type assertion"));
    }

    #[test]
    fn reexports_use_the_names_they_pass_on() {
        let file = parse("export { Store } from \"./store\";\nexport * from \"./cache\";\n", false);
        assert_eq!(file.imports.iter().map(|i| i.name.as_str()).collect::<Vec<_>>(), vec!["./store", "./cache"]);
        assert!(file.type_refs.iter().any(|r| r.name == "Store" && r.module.as_deref() == Some("./store")));
    }
}
