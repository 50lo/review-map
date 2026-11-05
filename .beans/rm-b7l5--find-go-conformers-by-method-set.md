---
# rm-b7l5
title: Find Go conformers by method set
status: todo
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-05T08:00:00Z
parent: rm-a4b7
---

Go interfaces are implicit: a type implements an interface when its method set includes all of the interface's methods. The `conformers` check in Checks.swift looks for inheritance clauses, which Go never has.

## Implementation scope
Implement the conformance hook from rm-n95m for Go: collect each type's methods (value and pointer receivers) and match them against an interface's methods by name and parameter count. Embedded interfaces contribute their methods. When an interface gains a method, the types that implemented it at base and no longer do at head are the finding.

## Acceptance criteria
- [ ] A fixture interface that gains a method produces a `conformers` finding for the type that doesn't implement it, and none for one that does.
- [ ] Types in other packages that implemented the interface at base are included.

## Constraints
Name and arity matching is enough; full type checking is index mode's job.
