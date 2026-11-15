//! Kotlin, parsed with tree-sitter (the fwcd grammar the prototype pins). Declaration structure comes
//! from the tree; reference candidates are the identifiers outside declaration names and imports. This is
//! a port of the prototype's `KotlinExtractor.swift`, `KotlinRisk.swift`, and the dispatcher regions of
//! `KotlinStructure.swift`.

use super::treesitter::*;
use super::{Declaration, IsolationRegion, LineMark, MarkKind, NameRef, ParsedFile};
use crate::model::ItemKind;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::sync::OnceLock;
use streaming_iterator::StreamingIterator;
use tree_sitter::{Node, Parser, Query, QueryCursor};

/// Part of the syntax cache key: bump it whenever the output for the same source can change.
pub const PARSER_VERSION: &str = "kotlin-1+fwcd-d6af96d";

pub const MAIN_THREAD: &str = "main thread";

fn language() -> tree_sitter::Language {
    tree_sitter_kotlin::LANGUAGE.into()
}

pub fn clean(name: &str) -> String {
    name.trim_matches('`').to_string()
}

pub fn parse(source: &str) -> ParsedFile {
    let mut parser = Parser::new();
    parser.set_language(&language()).expect("the Kotlin grammar matches the tree-sitter library");
    let Some(tree) = parser.parse(source, None) else {
        return ParsedFile { language: "kotlin".into(), package_name: Some(String::new()), ..Default::default() };
    };
    let root = tree.root_node();
    let mut walker = Walker { source, decls: Vec::new(), parent: None };
    walker.walk(root);

    let package = named_children(root)
        .into_iter()
        .find(|n| n.kind() == "package_header")
        .and_then(|n| first(n, &["identifier"]))
        .map(|n| qualified_identifier(n, source))
        .unwrap_or_default();

    let mut imports: Vec<NameRef> = Vec::new();
    let mut stars: Vec<String> = Vec::new();
    let mut bindings: HashMap<String, (String, String)> = HashMap::new();
    for n in named_children(root) {
        if n.kind() != "import_list" && n.kind() != "import_header" {
            continue;
        }
        let entries = if n.kind() == "import_list" { named_children(n) } else { vec![n] };
        for entry in entries.into_iter().filter(|e| e.kind() == "import_header") {
            let Some(identifier) = first(entry, &["identifier"]) else { continue };
            let path = qualified_identifier(identifier, source);
            if named_children(entry).iter().any(|c| c.kind() == "wildcard_import") {
                stars.push(path.clone());
                imports.push(NameRef { name: path, line: start_line(entry), module: None });
            } else {
                let parts: Vec<&str> = path.split('.').collect();
                let Some(name) = parts.last().filter(|s| !s.is_empty()) else { continue };
                let package = parts[..parts.len() - 1].join(".");
                let alias = first(entry, &["import_alias"])
                    .and_then(|a| named_children(a).into_iter().next())
                    .map(|a| text(a, source).to_string())
                    .unwrap_or_else(|| name.to_string());
                bindings.insert(clean(&alias), (clean(name), package));
                imports.push(NameRef { name: path.clone(), line: start_line(entry), module: None });
            }
        }
    }

    let mut refs: Vec<NameRef> = Vec::new();
    let mut members: Vec<NameRef> = Vec::new();
    for_each(root, &mut |n| {
        if matches!(n.kind(), "package_header" | "import_header" | "import_list") {
            return false;
        }
        if n.kind() != "simple_identifier" && n.kind() != "type_identifier" {
            return true;
        }
        if is_declaration_name(n) {
            return true;
        }
        let name = clean(text(n, source));
        if n.parent().map(|p| p.kind() == "navigation_suffix").unwrap_or(false) {
            members.push(NameRef { name, line: start_line(n), module: None });
        } else if let Some((bound, package)) = bindings.get(&name) {
            refs.push(NameRef { name: bound.clone(), line: start_line(n), module: Some(package.clone()) });
        } else {
            refs.push(NameRef { name, line: start_line(n), module: None });
        }
        true
    });

    let mut decls = walker.decls;
    for d in decls.iter_mut() {
        let supertypes: Vec<String> = d.traits.iter().filter(|t| t.starts_with("supertype:")).cloned().collect();
        for t in supertypes {
            let parts: Vec<&str> = t["supertype:".len()..].split('.').collect();
            let Some((name, package)) = parts.first().and_then(|f| bindings.get(*f)) else { continue };
            d.traits.remove(&t);
            let mut full: Vec<String> = vec![package.clone(), name.clone()];
            full.extend(parts[1..].iter().map(|s| s.to_string()));
            full.retain(|s| !s.is_empty());
            d.traits.insert(format!("supertype:{}", full.join(".")));
        }
    }

    ParsedFile {
        language: "kotlin".into(),
        decls,
        imports,
        type_refs: refs,
        member_refs: members,
        marks: marks(root, source),
        is_generated: false,
        package_name: Some(package),
        wildcard_imports: stars,
        isolation_regions: regions(root, source),
    }
}

fn qualified_identifier(n: Node, source: &str) -> String {
    named_children(n)
        .into_iter()
        .filter(|c| c.kind() == "simple_identifier")
        .map(|c| clean(text(c, source)))
        .collect::<Vec<_>>()
        .join(".")
}

fn is_declaration_name(n: Node) -> bool {
    let Some(p) = n.parent() else { return false };
    let first_of = |kinds: &[&str]| named_children(p).into_iter().find(|c| kinds.contains(&c.kind())).map(|c| c.id() == n.id()).unwrap_or(false);
    match p.kind() {
        "class_declaration" | "object_declaration" | "companion_object" | "type_alias" => first_of(&["simple_identifier", "type_identifier"]),
        "function_declaration" | "variable_declaration" | "class_parameter" | "parameter" | "parameter_with_optional_type" | "enum_entry"
        | "type_parameter" => first_of(&["simple_identifier"]),
        _ => false,
    }
}

struct Walker<'s> {
    source: &'s str,
    decls: Vec<Declaration>,
    parent: Option<usize>,
}

#[derive(Default)]
struct Add<'t> {
    body: Option<Node<'t>>,
    inherited: Vec<String>,
    header_end: Option<Node<'t>>,
    labels: Option<String>,
    function: bool,
    stored: bool,
    receiver: Option<String>,
}

impl<'s> Walker<'s> {
    fn scope(&self) -> Option<String> {
        self.parent.map(|p| self.decls[p].qualified_name.clone())
    }

    fn parent_kind(&self) -> Option<ItemKind> {
        self.parent.map(|p| self.decls[p].kind)
    }

    fn declaration_name(&self, node: Node) -> Option<String> {
        first(node, &["simple_identifier", "type_identifier"]).map(|n| clean(text(n, self.source)))
    }

    fn walk(&mut self, node: Node) {
        for n in named_children(node) {
            match n.kind() {
                "class_declaration" | "object_declaration" | "companion_object" => self.container(n),
                "function_declaration" => self.function(n),
                "property_declaration" => self.property(n),
                "type_alias" => {
                    if let Some(name) = self.declaration_name(n) {
                        self.add(n, ItemKind::Typealias, &name, tokens(n), Add::default());
                    }
                }
                "enum_entry" => {
                    if let Some(name) = self.declaration_name(n) {
                        self.add(n, ItemKind::Case, &name, tokens(n), Add::default());
                    }
                }
                "secondary_constructor" => {
                    let body = first(n, &["function_body", "statements"]);
                    let end = body.map(|b| b.start_byte()).unwrap_or(n.end_byte());
                    let header = tokens(n).into_iter().filter(|t| t.start_byte() < end).collect();
                    let labels = format!("constructor{}", self.labels(n));
                    self.add(n, ItemKind::Init, "constructor", header, Add { body, labels: Some(labels), function: true, ..Default::default() });
                }
                "statements" | "source_file" | "class_body" | "enum_class_body" => self.walk(n),
                _ => {}
            }
        }
    }

    fn container(&mut self, n: Node) {
        let name = self.declaration_name(n).unwrap_or_else(|| if n.kind() == "companion_object" { "Companion".to_string() } else { String::new() });
        if name.is_empty() {
            return;
        }
        let body = first(n, &["class_body", "enum_class_body"]);
        let kids = children(n);
        let kind = if kids.iter().any(|c| c.kind() == "interface") {
            ItemKind::Protocol
        } else if kids.iter().any(|c| c.kind() == "enum") {
            ItemKind::Enum
        } else {
            ItemKind::Class
        };
        let mut inherited: Vec<String> = Vec::new();
        let mut supertypes: Vec<String> = Vec::new();
        for c in named_children(n).into_iter().filter(|c| c.kind() == "delegation_specifier") {
            let Some(user_type) = find_first(c, "user_type") else { continue };
            let identifiers: Vec<String> =
                named_children(user_type).into_iter().filter(|x| x.kind() == "type_identifier").map(|x| clean(text(x, self.source))).collect();
            if let Some(last) = identifiers.last() {
                inherited.push(last.clone());
                supertypes.push(identifiers.join("."));
            }
        }
        let end = body.map(|b| b.start_byte()).unwrap_or(n.end_byte());
        let header = tokens(n).into_iter().filter(|t| t.start_byte() < end).collect();
        let index = self.add(n, kind, &name, header, Add { inherited, header_end: body, ..Default::default() });
        for s in supertypes {
            self.decls[index].traits.insert(format!("supertype:{s}"));
        }
        let old = self.parent;
        self.parent = Some(index);
        if let Some(constructor) = first(n, &["primary_constructor"]) {
            let shape = canon(&tokens(constructor), self.source);
            self.decls[index].traits.insert(format!("constructor-shape:{shape}"));
            for p in named_children(constructor) {
                if p.kind() != "class_parameter" || !children(p).iter().any(|c| c.kind() == "binding_pattern_kind") {
                    continue;
                }
                let Some(name) = self.declaration_name(p) else { continue };
                let p_tokens = tokens(p);
                let equals = p_tokens.iter().find(|t| t.kind() == "=").copied();
                let value = equals.and_then(|e| named_children(p).into_iter().find(|c| c.start_byte() > e.start_byte()));
                let cut = equals.map(|e| e.start_byte()).unwrap_or(p.end_byte());
                let header = p_tokens.into_iter().filter(|t| t.start_byte() < cut).collect();
                let i = self.add(p, ItemKind::Var, &name, header, Add { body: value, stored: true, ..Default::default() });
                self.decls[i].traits.insert("constructor-property".to_string());
                self.decls[i].type_annotation = self.type_after_colon(p);
                let nullable = self.nullable_traits(p, "property");
                self.decls[i].traits.extend(nullable);
            }
        }
        if let Some(body) = body {
            self.walk(body);
        }
        self.parent = old;
    }

    fn labels(&self, n: Node) -> String {
        let Some(parameters) = first(n, &["function_value_parameters"]) else { return "()".to_string() };
        let names: String = named_children(parameters)
            .into_iter()
            .filter(|p| p.kind() == "parameter")
            .filter_map(|p| self.declaration_name(p))
            .map(|name| format!("{name}:"))
            .collect();
        format!("({names})")
    }

    fn function(&mut self, n: Node) {
        let Some(name) = self.declaration_name(n) else { return };
        let body = first(n, &["function_body"]);
        let receiver = n.child_by_field_name("receiver");
        let receiver_scope = receiver.map(|node| {
            let id = find_first(node, "user_type")
                .map(|u| named_children(u).into_iter().filter(|c| c.kind() == "type_identifier").map(|c| text(c, self.source)).collect::<Vec<_>>().join("."))
                .unwrap_or_default();
            if id.is_empty() {
                canon(&tokens(node), self.source)
            } else {
                id
            }
        });
        let end = body.map(|b| b.start_byte()).unwrap_or(n.end_byte());
        let header = tokens(n).into_iter().filter(|t| t.start_byte() < end).collect();
        let labels = format!("{name}{}", self.labels(n));
        let i = self.add(n, ItemKind::Func, &name, header, Add { body, labels: Some(labels), function: true, receiver: receiver_scope, ..Default::default() });
        if receiver.is_some() {
            self.decls[i].traits.insert("extension".to_string());
        }
        if self.parent_kind() == Some(ItemKind::Protocol) && body.is_none() {
            self.decls[i].in_protocol = true;
        }
        self.decls[i].type_annotation = self.type_after_colon(n);
        let mut extra = self.nullable_traits(n, "result");
        if let Some(params) = first(n, &["function_value_parameters"]) {
            for (offset, parameter) in named_children(params).into_iter().filter(|p| p.kind() == "parameter").enumerate() {
                extra.extend(self.nullable_traits(parameter, &format!("parameter-{offset}")));
            }
        }
        self.decls[i].traits.extend(extra);
    }

    fn property(&mut self, n: Node) {
        let Some(variable) = first(n, &["variable_declaration"]) else { return };
        let Some(name) = self.declaration_name(variable) else { return };
        let equals = children(n).into_iter().find(|c| c.kind() == "=" || c.kind() == "property_delegate");
        let accessor = first(n, &["getter", "setter"]);
        let cutoff = equals.map(|e| e.start_byte()).unwrap_or(n.end_byte()).min(accessor.map(|a| a.start_byte()).unwrap_or(n.end_byte()));
        let all = tokens(n);
        let header: Vec<Node> = all.iter().copied().filter(|t| t.start_byte() < cutoff).collect();
        let i = self.add(n, ItemKind::Var, &name, header, Add { stored: accessor.is_none(), ..Default::default() });
        let body: Vec<Node> = all.iter().copied().filter(|t| t.start_byte() >= cutoff && t.kind() != ";").collect();
        self.decls[i].body_canon = canon(&body, self.source);
        self.decls[i].header_end_line = all.iter().rev().find(|t| t.start_byte() < cutoff).map(|t| end_line(*t)).unwrap_or(start_line(n));
        self.decls[i].type_annotation = self.type_after_colon(variable);
        let nullable = self.nullable_traits(variable, "property");
        self.decls[i].traits.extend(nullable);
        self.decls[i].in_protocol = self.parent_kind() == Some(ItemKind::Protocol) && equals.is_none() && accessor.is_none();
    }

    fn type_node<'t>(&self, n: Node<'t>) -> Option<Node<'t>> {
        let colon = children(n).into_iter().find(|c| c.kind() == ":")?;
        named_children(n).into_iter().find(|c| c.start_byte() > colon.start_byte())
    }

    fn type_after_colon(&self, n: Node) -> Option<String> {
        self.type_node(n).map(|t| display(&tokens(t), self.source))
    }

    fn nullable_traits(&self, n: Node, slot: &str) -> Vec<String> {
        let Some(ty) = self.type_node(n) else { return Vec::new() };
        let toks = tokens(ty);
        if !toks.iter().any(|t| text(*t, self.source) == "?") {
            return Vec::new();
        }
        let shape: Vec<&str> =
            toks.iter().map(|t| if matches!(t.kind(), "type_identifier" | "simple_identifier") { "T" } else { text(*t, self.source) }).collect();
        vec![format!("nullable:{slot}:{}", shape.join(" "))]
    }

    fn add(&mut self, n: Node, kind: ItemKind, name: &str, header: Vec<Node>, opts: Add) -> usize {
        let source = self.source;
        let mods = first(n, &["modifiers"]);
        let annotations: Vec<Node> = mods.map(|m| named_children(m).into_iter().filter(|c| c.kind() == "annotation").collect()).unwrap_or_default();
        let attributes: Vec<String> = annotations
            .iter()
            .filter_map(|a| {
                let user_type = find_first(*a, "user_type")?;
                named_children(user_type).into_iter().filter(|c| c.kind() == "type_identifier").map(|c| text(c, source).to_string()).last()
            })
            .collect();
        let mut modifiers: Vec<String> = mods
            .map(|m| {
                named_children(m)
                    .into_iter()
                    .filter(|c| c.kind() != "annotation" && c.kind() != "context_receiver")
                    .flat_map(|c| tokens(c).into_iter().map(|t| text(t, source).to_string()).collect::<Vec<_>>())
                    .collect()
            })
            .unwrap_or_default();
        if n.kind() == "object_declaration" || n.kind() == "companion_object" {
            modifiers.push("object".to_string());
        }
        if n.kind() == "companion_object" {
            modifiers.push("companion".to_string());
        }
        let kids = children(n);
        if kids.iter().any(|c| c.kind() == "enum") {
            modifiers.push("enum".to_string());
        }
        if let Some(binding) = first(n, &["binding_pattern_kind"]) {
            modifiers.push(text(binding, source).to_string());
        }
        if n.kind() == "property_declaration" {
            if let Some(binding) = kids.iter().find(|c| c.kind() == "val" || c.kind() == "var") {
                modifiers.push(text(*binding, source).to_string());
            }
        }
        let access = modifiers.iter().find(|m| matches!(m.as_str(), "public" | "private" | "internal" | "protected")).cloned().unwrap_or_else(|| "public".to_string());
        let header: Vec<Node> = header
            .into_iter()
            .filter(|t| t.kind() != ";" && !mods.map(|m| t.start_byte() >= m.start_byte() && t.end_byte() <= m.end_byte()).unwrap_or(false))
            .collect();
        let container = matches!(kind, ItemKind::Class | ItemKind::Protocol | ItemKind::Enum);
        let raw_end = if container { opts.header_end.map(|h| h.start_byte()).unwrap_or(n.end_byte()) } else { n.end_byte() };
        let scope = opts.receiver.clone().or_else(|| self.scope());
        let display_name = format!("{name}{}", if opts.function { "()" } else { "" });
        let qualified_name = match &scope {
            Some(s) => format!("{s}.{display_name}"),
            None => display_name,
        };
        let body_canon = opts
            .body
            .map(|b| canon(&tokens(b).into_iter().filter(|t| t.kind() != ";").collect::<Vec<_>>(), source))
            .unwrap_or_default();
        let is_static = modifiers.iter().any(|m| m == "const") || self.parent.map(|p| self.decls[p].modifiers.iter().any(|m| m == "object")).unwrap_or(false);
        let mut traits: BTreeSet<String> = BTreeSet::new();
        for a in &annotations {
            traits.insert(format!("annotation:{}", canon(&tokens(*a), source)));
        }
        let header_end_line = opts
            .header_end
            .or(opts.body)
            .map(start_line)
            .or_else(|| header.last().map(|t| end_line(*t)))
            .unwrap_or_else(|| start_line(n));
        let d = Declaration {
            kind,
            name: name.to_string(),
            qualified_name,
            scope,
            parent_index: self.parent,
            labels_key: opts.labels.unwrap_or_else(|| name.to_string()),
            signature_display: display(&header, source),
            signature_canon: canon(&header, source),
            modifiers_canon: mods.map(|m| canon(&tokens(m), source)).unwrap_or_default(),
            body_canon,
            raw_text: source.get(n.start_byte()..raw_end).unwrap_or("").to_string(),
            access: Some(access),
            attributes,
            is_async: modifiers.iter().any(|m| m == "suspend"),
            modifiers,
            inherited: opts.inherited,
            is_throws: false,
            throws_type: None,
            is_stored: opts.stored,
            is_static,
            type_annotation: None,
            in_protocol: false,
            parent_kind: self.parent_kind(),
            start_line: start_line(n),
            end_line: end_line(n),
            header_end_line,
            traits,
        };
        self.decls.push(d);
        self.decls.len() - 1
    }
}

// MARK: Risk marks

struct Entry {
    kind: MarkKind,
    label: &'static str,
    pattern: &'static str,
}

const ENTRIES: &[Entry] = &[
    Entry { kind: MarkKind::Crash, label: "non-null assertion", pattern: r#"(postfix_expression "!!" @m)"# },
    Entry { kind: MarkKind::Crash, label: "lateinit", pattern: r#"(member_modifier "lateinit" @m)"# },
    Entry { kind: MarkKind::Crash, label: "unchecked cast", pattern: r#"(as_expression "as" @m)"# },
    Entry { kind: MarkKind::Crash, label: "%", pattern: r#"(call_expression (simple_identifier) @m (#any-of? @m "TODO" "error"))"# },
    Entry { kind: MarkKind::Crash, label: "%", pattern: r#"(call_expression (navigation_expression (navigation_suffix (simple_identifier) @m)) (#any-of? @m "TODO" "error"))"# },
    Entry { kind: MarkKind::Check, label: "%", pattern: r#"(call_expression (simple_identifier) @m (#any-of? @m "check" "require"))"# },
    Entry { kind: MarkKind::Check, label: "%", pattern: r#"(call_expression (navigation_expression (navigation_suffix (simple_identifier) @m)) (#any-of? @m "check" "require"))"# },
    Entry { kind: MarkKind::Concurrency, label: "runBlocking", pattern: r#"(call_expression (simple_identifier) @m (#eq? @m "runBlocking"))"# },
    Entry { kind: MarkKind::Concurrency, label: "runBlocking", pattern: r#"(call_expression (navigation_expression (navigation_suffix (simple_identifier) @m)) (#eq? @m "runBlocking"))"# },
    Entry { kind: MarkKind::Concurrency, label: "GlobalScope", pattern: r#"(navigation_expression (simple_identifier) @m (#eq? @m "GlobalScope"))"# },
    Entry { kind: MarkKind::Isolation, label: "Dispatchers.Main", pattern: r#"(navigation_expression (simple_identifier) @owner (navigation_suffix (simple_identifier) @m) (#eq? @owner "Dispatchers") (#eq? @m "Main"))"# },
    Entry { kind: MarkKind::Isolation, label: "withContext", pattern: r#"(call_expression (simple_identifier) @m (#eq? @m "withContext"))"# },
    Entry { kind: MarkKind::Isolation, label: "withContext", pattern: r#"(call_expression (navigation_expression (navigation_suffix (simple_identifier) @m)) (#eq? @m "withContext"))"# },
    Entry { kind: MarkKind::Flow, label: "if", pattern: r#"(if_expression) @m"# },
    Entry { kind: MarkKind::Flow, label: "when", pattern: r#"(when_expression) @m"# },
    Entry { kind: MarkKind::Flow, label: "for", pattern: r#"(for_statement) @m"# },
    Entry { kind: MarkKind::Flow, label: "while", pattern: r#"(while_statement) @m"# },
];

fn risk_query() -> &'static Query {
    static QUERY: OnceLock<Query> = OnceLock::new();
    QUERY.get_or_init(|| {
        let text: Vec<&str> = ENTRIES.iter().map(|e| e.pattern).collect();
        Query::new(&language(), &text.join("\n")).expect("the Kotlin risk query matches the grammar")
    })
}

fn marks(root: Node, source: &str) -> BTreeMap<u32, Vec<LineMark>> {
    let query = risk_query();
    let m_index = query.capture_index_for_name("m");
    let mut cursor = QueryCursor::new();
    let mut out: BTreeMap<u32, Vec<LineMark>> = BTreeMap::new();
    let mut matches = cursor.matches(query, root, source.as_bytes());
    while let Some(m) = matches.next() {
        let Some(node) = m.captures.iter().find(|c| Some(c.index) == m_index).map(|c| c.node) else { continue };
        let entry = &ENTRIES[m.pattern_index];
        let mark = LineMark { kind: entry.kind, label: entry.label.replace('%', text(node, source)) };
        let list = out.entry(start_line(node)).or_default();
        if !list.contains(&mark) {
            list.push(mark);
        }
    }
    out
}

// MARK: Dispatcher regions

fn call_name(node: Node, source: &str) -> String {
    if node.kind() == "call_expression" {
        if let Some(callee) = named_children(node).into_iter().next() {
            return call_name(callee, source);
        }
    }
    tokens(node).last().map(|t| text(*t, source).to_string()).unwrap_or_default()
}

/// Lexical dispatcher blocks, which override declaration-level Android main-thread conventions.
fn regions(root: Node, source: &str) -> Vec<IsolationRegion> {
    let mut result = Vec::new();
    for_each(root, &mut |node| {
        if node.kind() != "call_expression" {
            return true;
        }
        let named = named_children(node);
        let Some(callee) = named.first().copied() else { return true };
        let Some(suffix) = named.iter().rev().find(|c| c.kind() == "call_suffix").copied() else { return true };
        if !matches!(call_name(callee, source).as_str(), "withContext" | "launch" | "async") {
            return true;
        }
        let arguments = named_children(suffix).into_iter().find(|c| c.kind() == "value_arguments").or_else(|| {
            named_children(callee)
                .into_iter()
                .rev()
                .find(|c| c.kind() == "call_suffix")
                .and_then(|s| named_children(s).into_iter().find(|c| c.kind() == "value_arguments"))
        });
        let Some(arguments) = arguments else { return true };
        let mut dispatchers: Vec<String> = Vec::new();
        for argument in named_children(arguments).into_iter().filter(|a| a.kind() == "value_argument") {
            // The context expression may combine a dispatcher with a Job. A block argument's own
            // dispatchers belong to nested calls and must not change this call's context.
            if named_children(argument).iter().any(|c| c.kind() == "lambda_literal") {
                continue;
            }
            let toks = tokens(argument);
            for i in 0..toks.len() {
                if i + 2 < toks.len()
                    && toks[i].kind() == "simple_identifier"
                    && text(toks[i], source) == "Dispatchers"
                    && text(toks[i + 1], source) == "."
                    && toks[i + 2].kind() == "simple_identifier"
                {
                    dispatchers.push(text(toks[i + 2], source).to_string());
                }
            }
        }
        if dispatchers.is_empty() {
            return true;
        }
        let mut lambdas: Vec<Node> = named_children(suffix)
            .into_iter()
            .filter(|c| c.kind() == "annotated_lambda")
            .flat_map(named_children)
            .filter(|c| c.kind() == "lambda_literal")
            .collect();
        lambdas.extend(
            named_children(arguments).into_iter().filter(|c| c.kind() == "value_argument").flat_map(named_children).filter(|c| c.kind() == "lambda_literal"),
        );
        for lambda in lambdas {
            result.push(IsolationRegion {
                start_line: start_line(lambda),
                end_line: end_line(lambda),
                start_byte: lambda.start_byte(),
                end_byte: lambda.end_byte(),
                isolation: if dispatchers.iter().all(|d| d == "Main") { Some(MAIN_THREAD.to_string()) } else { None },
            });
        }
        true
    });
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn declarations_and_references() {
        let source = "package demo.app\n\nimport demo.cache.Cache\nimport demo.store.*\nimport demo.util.Log as L\n\ninterface Loader { fun load(key: String): String? }\n\ndata class Page(val title: String, private var count: Int = 0) : Loader {\n    override fun load(key: String): String? = Cache().load(key)\n    suspend fun refresh() { if (count > 0) L.d(\"x\") }\n    companion object { const val MAX = 3 }\n}\n\nfun String.shout() = uppercase()\n";
        let file = parse(source);
        assert_eq!(file.package_name.as_deref(), Some("demo.app"));
        assert_eq!(file.wildcard_imports, vec!["demo.store".to_string()]);
        let names: Vec<(&str, ItemKind)> = file.decls.iter().map(|d| (d.qualified_name.as_str(), d.kind)).collect();
        assert_eq!(
            names,
            vec![
                ("Loader", ItemKind::Protocol),
                ("Loader.load()", ItemKind::Func),
                ("Page", ItemKind::Class),
                ("Page.title", ItemKind::Var),
                ("Page.count", ItemKind::Var),
                ("Page.load()", ItemKind::Func),
                ("Page.refresh()", ItemKind::Func),
                ("Page.Companion", ItemKind::Class),
                ("Page.Companion.MAX", ItemKind::Var),
                ("String.shout()", ItemKind::Func),
            ]
        );
        let page = &file.decls[2];
        assert!(page.modifiers.contains(&"data".to_string()));
        assert_eq!(page.inherited, vec!["Loader".to_string()]);
        assert!(file.decls[1].in_protocol);
        assert_eq!(file.decls[4].access.as_deref(), Some("private"));
        assert!(file.decls[6].is_async);
        assert!(file.decls[8].is_static);
        assert!(file.decls[9].traits.contains("extension"));
        assert!(file.decls[1].traits.iter().any(|t| t.starts_with("nullable:result:")));
        // An import alias resolves to the imported name and its package.
        assert!(file.type_refs.iter().any(|r| r.name == "Log" && r.module.as_deref() == Some("demo.util")));
        assert!(file.type_refs.iter().any(|r| r.name == "Cache" && r.module.as_deref() == Some("demo.cache")));
        assert!(file.member_refs.iter().any(|r| r.name == "load"));
        assert!(file.marks.values().flatten().any(|m| m.kind == MarkKind::Flow && m.label == "if"));
    }

    #[test]
    fn dispatcher_regions() {
        let source = "fun f() {\n    withContext(Dispatchers.Main) {\n        show()\n    }\n    launch(Dispatchers.IO) {\n        load()\n    }\n}\n";
        let file = parse(source);
        assert_eq!(file.isolation_regions.len(), 2);
        assert_eq!(file.isolation_regions[0].isolation.as_deref(), Some(MAIN_THREAD));
        assert_eq!(file.isolation_regions[1].isolation, None);
    }
}
