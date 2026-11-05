---
# rm-czqu
title: Hide Xcode targets inside test fixtures when Tests is off
status: todo
type: bug
priority: normal
created_at: 2026-11-05T02:51:32Z
updated_at: 2026-11-05T02:51:32Z
---

When Review Map analyzes a repository with an Xcode project nested under a test path, such as Tests/<X>Tests/Fixtures/App/App.xcodeproj, application and framework targets in that project are marked isTest: false. They remain on the map with Tests unchecked, cluttering the production component graph. rm-patv fixed the same bug for SPM targets; the Xcode path was not changed.

## Reproduction
1. In an analyzed repository, add an Xcode project with an application or framework target under a test path, for example Tests/HostTests/Fixtures/App/App.xcodeproj.
2. Analyze the repository, open the map, select Whole system, and leave Tests unchecked.
3. The fixture's xcode: component remains visible.

Expected: components from a project under a test path are hidden with Tests off and available with Tests on. Actual: isTest is true only for unit-test and UI-test bundle targets, because xcodeTargets in Sources/ReviewMapCore/Swift/SwiftComponents.swift classifies by product type alone (`target.productType == .unitTestBundle || target.productType == .uiTestBundle`).

## Implementation scope
In xcodeTargets in Sources/ReviewMapCore/Swift/SwiftComponents.swift, also mark the target as a test when ComponentBuilder.isTestPath(projDir) is true. projDir is the repository-relative directory containing the .xcodeproj, so a project at the repository root gets an empty path and is not treated as a test. Folder splits take `parent.isTest || isTestPath(folder)` in Sources/ReviewMapCore/Components.swift, so split children inherit the value with no further change. Component.isTest remains the boolean consumed by viewer/src/graph.ts; no model schema or viewer change is required.

Add regression coverage to Tests/ReviewMapCoreTests/ComponentTests.swift, following testNestedFixtureTargetsInheritTestContext. No .xcodeproj fixture exists under Tests/ReviewMapCoreTests/Fixtures yet, so the test must add one or generate one in a temporary repository. See README.md for the analyzer/viewer model and test commands.

## Acceptance criteria
- [ ] Application and framework targets in a .xcodeproj under a test path, such as Tests/HostTests/Fixtures/App/App.xcodeproj, are classified as tests, including split children.
- [ ] An application target in an ordinary top-level .xcodeproj keeps isTest: false.
- [ ] Unit-test and UI-test bundle targets remain tests wherever the project is located.
- [ ] The regression assertion fails before the fix; relevant Swift checks pass afterward.

## Constraints
Keep .xcodeproj discovery, file-claim priorities, and the target repository read-only behavior unchanged. Local Swift tests need XCTest, which Command Line Tools does not provide; without Xcode installed, confirm them through Linux PR CI.
