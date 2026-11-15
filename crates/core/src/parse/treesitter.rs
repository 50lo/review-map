//! Small helpers over tree-sitter nodes, for the languages parsed with it. Lines are 1-based, like the
//! rest of the change report.

use tree_sitter::Node;

pub fn children<'t>(node: Node<'t>) -> Vec<Node<'t>> {
    let mut cursor = node.walk();
    node.children(&mut cursor).collect()
}

/// Named children, without comments.
pub fn named_children<'t>(node: Node<'t>) -> Vec<Node<'t>> {
    let mut cursor = node.walk();
    node.children(&mut cursor).filter(|c| c.is_named() && !c.is_extra()).collect()
}

/// The first named child whose type is one of `kinds`.
pub fn first<'t>(node: Node<'t>, kinds: &[&str]) -> Option<Node<'t>> {
    named_children(node).into_iter().find(|c| kinds.contains(&c.kind()))
}

pub fn start_line(node: Node) -> u32 {
    node.start_position().row as u32 + 1
}

pub fn end_line(node: Node) -> u32 {
    node.end_position().row as u32 + 1
}

pub fn text<'s>(node: Node, source: &'s str) -> &'s str {
    source.get(node.start_byte()..node.end_byte()).unwrap_or("")
}

/// The tokens under the node, without comments and empty tokens (such as automatic semicolons).
pub fn tokens<'t>(node: Node<'t>) -> Vec<Node<'t>> {
    fn walk<'t>(n: Node<'t>, out: &mut Vec<Node<'t>>) {
        if n.is_extra() {
            return;
        }
        if n.child_count() == 0 {
            if n.end_byte() > n.start_byte() {
                out.push(n);
            }
            return;
        }
        let mut cursor = n.walk();
        for c in n.children(&mut cursor) {
            walk(c, out);
        }
    }
    let mut out = Vec::new();
    walk(node, &mut out);
    out
}

/// Token texts joined by single spaces: what's compared to tell real changes from cosmetic ones.
pub fn canon(tokens: &[Node], source: &str) -> String {
    tokens.iter().map(|t| text(*t, source)).collect::<Vec<_>>().join(" ")
}

/// Token texts with a single space wherever the source had anything between them.
pub fn display(tokens: &[Node], source: &str) -> String {
    let mut out = String::new();
    for (i, t) in tokens.iter().enumerate() {
        if i > 0 && tokens[i - 1].end_byte() < t.start_byte() {
            out.push(' ');
        }
        out.push_str(text(*t, source));
    }
    out
}

/// Every node under this one, itself included, depth first. Returning false skips a node's children.
pub fn for_each<'t>(node: Node<'t>, visit: &mut dyn FnMut(Node<'t>) -> bool) {
    if !visit(node) {
        return;
    }
    let mut cursor = node.walk();
    let kids: Vec<Node<'t>> = node.children(&mut cursor).collect();
    for c in kids {
        for_each(c, visit);
    }
}

/// The first node of a type under `node`, itself included, in document order.
pub fn find_first<'t>(node: Node<'t>, kind: &str) -> Option<Node<'t>> {
    let mut found = None;
    for_each(node, &mut |n| {
        if found.is_some() {
            return false;
        }
        if n.kind() == kind {
            found = Some(n);
            return false;
        }
        true
    });
    found
}
