## Change

The difference between two versions of a repository that someone wants to review. The starting version is the base; the version being reviewed is the head. A change can span several commits, such as the work in a pull request.

```yaml
agreed: proposed
code: [RepoInfo, baseSha, headSha]
not:
  - name: ChangeKind
    means: How one review item changed, such as added, removed, or a changed signature or body.
```

## Component

A named part of the software that Review Map uses to group code for review. It can be a package, a build target, or a folder; an external package can also be a component. For example, an app and its networking library can appear as separate components.

```yaml
agreed: proposed
code: [Component, ComponentKind]
not: []
```

## Review item

An individual part of a component that changed and that Review Map asks you to review. Usually it is a function, type, or property; it can also be a configuration file or a set of build settings. For example, a changed `signIn()` function is a review item inside the app component.

```yaml
agreed: proposed
code: [Entity, EntityKind]
not:
  - name: Region
    means: A portion of code shown for review or context.
  - name: Finding
    means: A possible problem reported by a review check or an AI review.
```

## Dependency

A connection from one component to another that it uses or declares it needs. For example, an app that calls a networking library depends on that library. On the map, a dependency is drawn as an arrow from the app to the library.

```yaml
agreed: proposed
code: [Edge]
not:
  - name: ExternalDepChange
    means: A record of an external package being added, removed, or changing version.
  - name: dependsOn
    means: The declarations in other components that one review item references.
```

## Change report

The saved result of analyzing a change. It describes the affected components, their dependencies, the review items, and supporting information. The change analyzer produces it, and the viewer displays it. In code, it remains `ChangeModel`, saved as `change-model.json`.

```yaml
agreed: proposed
code: [ChangeModel]
not: []
```
