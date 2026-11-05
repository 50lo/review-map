---
# rm-d63r
title: Add Kotlin contract flags, risk marks, and Android contracts
status: todo
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-05T08:00:00Z
parent: rm-aks4
---

## Implementation scope
- `KotlinFlags`: public API added, removed, or changed; nullability of parameters and results; `suspend` added or removed; data class primary-constructor properties; serialized and persisted shapes (`@Serializable`, `@SerialName`, Moshi `@Json`, Room `@Entity` and `@ColumnInfo`); sealed subclasses and enum entries added or removed; `open`, `final`, and `abstract` changes; visibility narrowed.
- `AndroidManifest.xml` is a contract file (`contractFile` and `contractFileFlags`): permissions added or removed, components with `exported` changes, intent filters.
- `settingFlag` for SDK levels, JVM target, and Kotlin version, and `flagRisk` weights.
- Risk table as queries: `!!` (crash), `lateinit` (crash), unchecked `as` (crash), `TODO()` and `error()` (crash), `check` and `require` (check), `runBlocking` and `GlobalScope` (concurrency), `Dispatchers.Main`/`withContext` switches (isolation).
- Add the new flags to the viewer's `flagWeight`.

## Acceptance criteria
- [ ] Fixture changes produce the expected flags and risk marks, each covered by a test, including an AndroidManifest permission change.
