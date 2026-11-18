//! The core rules where the language matters, on Swift: the prototype's `basic` fixture, parsed by the
//! Swift helper. Each test returns early, saying so, when the helper is not built.

mod common;

use common::*;
use reviewmap_core::index::{IndexedRef, SideIndex};
use reviewmap_core::model::{ChangeKind, ChangeReport};
use std::sync::OnceLock;

/// The fixture's review without indexes: it is a SwiftPM package, which has no index here, so the report is syntax-only.
fn basic() -> Option<&'static ChangeReport> {
    static REPORT: OnceLock<ChangeReport> = OnceLock::new();
    if !swift_helper() {
        return None;
    }
    Some(REPORT.get_or_init(|| {
        let repo = fixture_repo(&prototype_fixture("basic"));
        let mut request = request(&repo);
        request.index = Some(false);
        analyze(request)
    }))
}

/// The same review's comparison report, which matches every reference by name and so runs every check.
fn basic_by_name() -> Option<&'static ChangeReport> {
    static REPORT: OnceLock<ChangeReport> = OnceLock::new();
    if !swift_helper() {
        return None;
    }
    Some(REPORT.get_or_init(|| {
        let repo = fixture_repo(&prototype_fixture("basic"));
        let mut request = request(&repo);
        request.index = Some(false);
        run(request).0.name_based_report()
    }))
}

#[test]
fn swift_changes_are_classified() {
    let Some(report) = basic() else { return };
    assert_eq!(review_item(report, "Cart.add(_:)").change, ChangeKind::Body, "a removed guard is a body change");
    assert_eq!(review_item(report, "Cart.format(_:)").contract_flags, vec!["swift:access-changed:internal->public"]);
    let prices: Vec<_> = report.review_items.iter().filter(|i| i.qualified_name == "Cart.price(for:)").collect();
    assert_eq!(prices.len(), 1, "only the changed overload is reported");
    assert_eq!(prices[0].signature.head.as_deref(), Some("func price(for item: Item) -> Decimal"));
}

/// CORE-006: a formatting-only review item stays in the report but asks for no review.
#[test]
fn core_006_a_cosmetic_swift_review_item_asks_for_no_review() {
    let Some(report) = basic() else { return };
    let cosmetic = review_item(report, "CatalogView.title()");
    assert_eq!(cosmetic.change, ChangeKind::Cosmetic);
    assert!(!report.regions.iter().any(|r| r.review_item == cosmetic.id), "no regions");
    assert!(!report.findings.iter().any(|f| f.anchors.iter().any(|a| a.review_item.as_deref() == Some(cosmetic.id.as_str()))), "no findings");
    let component = report.components.iter().find(|c| c.id == cosmetic.component).expect("its component");
    let changed = report.review_items.iter().filter(|i| i.component == cosmetic.component && i.change != ChangeKind::Cosmetic).count();
    assert_eq!(component.changed_review_items, changed, "not counted as changed");
}

/// CORE-005, on the fixture's findings: those of the syntax-only report, and the comparison report's, which has more.
#[test]
fn core_005_every_swift_finding_is_anchored_in_the_report() {
    let (Some(syntax_only), Some(by_name)) = (basic(), basic_by_name()) else { return };
    assert!(!by_name.findings.is_empty());
    for (report, f) in [syntax_only, by_name].into_iter().flat_map(|r| r.findings.iter().map(move |f| (r, f))) {
        assert!(!f.evidence.is_empty() && !f.anchors.is_empty(), "{f:?}");
        for a in &f.anchors {
            let known = match (&a.review_item, &a.component, &a.from, &a.to) {
                (Some(id), _, _, _) => report.review_items.iter().any(|i| &i.id == id),
                (None, Some(id), _, _) => report.components.iter().any(|c| &c.id == id),
                (None, None, Some(from), Some(to)) => report.edges.iter().any(|e| &e.from == from && &e.to == to),
                _ => false,
            };
            assert!(known, "{}: {a:?} names nothing in the report", f.id);
        }
    }
}

/// CORE-003 on Swift: modules `A` and `B` each declare a protocol `Store`. `App` conforms to A's in an
/// extension of `OneStore` and to B's in the declaration of `TwoStore`. Head changes A's requirement. The
/// supertypes come from the index's references in the inheritance clauses, so `TwoStore` is no conformer of
/// A's `Store`, as it would be by name.
#[test]
fn core_003_swift_supertypes_come_from_the_index_not_from_their_names() {
    if !swift_helper() {
        return;
    }
    let store = |load: &str| format!("public protocol Store {{\n    func {load}\n}}\n");
    let repo = two_commits(
        &[
            ("A/Store.swift", &store("load()")),
            ("B/Store.swift", &store("load()")),
            ("App/OneStore.swift", "import A\n\nstruct OneStore {\n    func load() {}\n}\n\nextension OneStore: Store {}\n"),
            ("App/TwoStore.swift", "import B\n\nstruct TwoStore: Store {\n    func load() {}\n}\n"),
        ],
        &[("A/Store.swift", Some(&store("load(force: Bool)")))],
    );
    let to = |line: u32, file: &str, target_line: u32, name: &str| IndexedRef { line, target_file: file.to_string(), target_line, name: name.to_string() };
    let index = || SideIndex {
        refs: [
            ("A/Store.swift", vec![]),
            ("B/Store.swift", vec![]),
            ("App/OneStore.swift", vec![to(7, "App/OneStore.swift", 3, "OneStore"), to(7, "A/Store.swift", 1, "Store")]),
            ("App/TwoStore.swift", vec![to(3, "B/Store.swift", 1, "Store")]),
        ]
        .into_iter()
        .map(|(f, r)| (f.to_string(), r))
        .collect(),
        warnings: Vec::new(),
    };
    let mut session = open(request(&repo));
    session.set_index("swift", index(), index());
    let report = session.report();
    let conformers = findings(&report, "conformers");
    assert_eq!(conformers.len(), 1, "{:?}", report.findings);
    assert!(conformers[0].message.contains("1 conformer wasn't updated"), "{:?}", conformers[0]);
    assert!(conformers[0].evidence.iter().any(|e| e.contains("OneStore.load")), "{:?}", conformers[0].evidence);
    assert!(!conformers[0].evidence.iter().any(|e| e.contains("TwoStore")), "TwoStore conforms to B's Store: {:?}", conformers[0].evidence);
    let load = report.review_items.iter().find(|i| i.qualified_name.starts_with("Store.load")).expect("the changed requirement");
    let context: Vec<String> = report
        .regions
        .iter()
        .filter(|r| r.review_item == load.id && r.relation.as_deref() == Some("conformer"))
        .map(|r| format!("{}:{}", r.file, r.start_line))
        .collect();
    assert_eq!(context, ["App/OneStore.swift:4"], "{:?}", report.regions);
}
