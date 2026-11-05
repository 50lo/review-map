---
# rm-patv
title: Hide nested fixture targets when Tests is off
status: completed
type: bug
priority: normal
created_at: 2026-11-05T02:14:18Z
updated_at: 2026-11-05T02:23:39Z
---

When Review Map analyzes its own repository, ordinary SPM targets inside Tests/ReviewMapCoreTests/Fixtures are marked isTest: false. They remain on the map with Tests unchecked, cluttering the production component graph.

## Reproduction
1. Analyze this repository with its basic and indexed fixtures present.
2. Open the map, select Whole system, and leave Tests unchecked.
3. Features, Core, and other fixture library targets remain visible; the Features side panel points into Tests/ReviewMapCoreTests/Fixtures/basic/base/Sources/Features.

Expected: fixture components are hidden with Tests off and available with Tests on. Actual: only explicit testTarget declarations are classified as tests; nested library targets lose the enclosing test context.

## Implementation scope
Update SPM component classification in Sources/ReviewMapCore/Swift/SwiftComponents.swift to include the target's repository-relative test path, using the existing ComponentBuilder.isTestPath convention. Component.isTest remains the boolean consumed by viewer/src/graph.ts; no model schema or viewer behavior change is required. Add analyzer and map-filter regression coverage under Tests/ReviewMapCoreTests and viewer/src/graph.test.ts. See README.md for the analyzer/viewer model and test commands.

## Acceptance criteria
- [x] Nested fixture library targets and split children are classified as tests.
- [x] Ordinary nested packages and fixtures analyzed as standalone repositories retain ordinary library classification; explicit test targets remain tests.
- [x] Whole-system map filtering hides fixture components and incident edges with Tests off and restores them with Tests on.
- [x] Regression assertion fails before the fix; relevant Swift and viewer checks pass afterward.

## Constraints
Use the existing fix-tests-map branch. Keep nested package discovery and the target repository read-only behavior. Commit the bug record with the fix and open a draft PR against main.

## Validation
- Built the analyzer and reproduced the screenshot's commit range: before the fix, 16 of 18 fixture components had isTest: false and the classification assertion failed; afterward all 18 are tests, with production targets unchanged.
- CLI checks pass for nested fixtures, ordinary nested packages, standalone fixtures, split children, and explicit test targets.
- Viewer: 52 tests pass; TypeScript checking and production build pass.
- Local Swift tests cannot run because Command Line Tools does not provide XCTest and Xcode is not installed. Linux PR CI passed all 48 Swift tests, including ComponentTests.testNestedFixtureTargetsInheritTestContext; viewer CI also passed. Run: https://github.com/50lo/review-map/actions/runs/41954393366.

## Summary of Changes
SPM targets now combine explicit test-target status with their repository-relative test path. Fixture library targets and split children follow the existing Tests filter, while ordinary nested packages and standalone fixtures keep their original classification. Added Swift coverage for all three contexts and viewer coverage for hiding/restoring fixture nodes and edges. Draft PR: https://github.com/50lo/review-map/pull/15.
