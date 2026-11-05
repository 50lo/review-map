---
# rm-1w6o
title: Show Go in the viewer
status: todo
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-05T08:00:00Z
parent: rm-a4b7
---

## Implementation scope
Add the Go entry to the viewer's language table from rm-tnty: `.go` files, `go.mod`, `go.sum`, and `go.work`, the `goPackage` component kind, an icon, Shiki's `go` language, and kind names (protocol -> interface, func -> function or method, typealias -> type, var -> variable, field).

## Acceptance criteria
- [ ] Go components show the Go badge; code pages highlight Go.
- [ ] Entities show Go's kind names.
- [ ] Checked in Chromium at desktop and phone widths, in light and dark mode, on a Go fixture model.
