//! The core rules where the language matters, on Swift: the prototype's `basic` fixture, parsed by the
//! Swift helper. Each test returns early, saying so, when the helper is not built.

mod common;

use common::*;
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
