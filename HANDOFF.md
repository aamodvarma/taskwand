# TaskWand — Handoff Notes

A working, minimal Flutter + TaskChampion Taskwarrior client for Android. This document
captures the current state, the non-obvious fixes already applied, and how to build/run/
extend it. The original brief is in `../taskwand-spec.md`.

Last updated: 2026-07-17.

---

## What it is

A single-screen Android app that is a real TaskChampion replica: tasks live in a local
SQLite replica, work fully offline, and sync with a self-hosted `taskchampion-sync-server`
(reachable over Tailscale at `http://100.x.y.z:8080`). It interoperates with Taskwarrior
3.x on the desktop when given the same client ID + encryption secret.

All sync/encryption/storage logic comes from the `taskchampion` Rust crate — none of it is
hand-written. If you find yourself writing merge/versioning code, stop; you're off track.

## Status: working

- Rust bridge crate compiles and its logic is unit-tested (`cargo test` in `rust/`).
- Full pipeline builds: `flutter build linux --debug`, `flutter build apk --debug`, and the
  app runs on-device (verified by the user) and on Linux desktop.
- Core sync verified working against the user's real desktop task set.

---

## Architecture

```
Flutter UI (lib/main.dart, one screen)
        │  flutter_rust_bridge v2 (generated bindings in lib/src/rust/)
Rust bridge crate (rust/src/api/tasks.rs)
        │
taskchampion 3.1.0 crate  ──►  SQLite replica in <app documents>/taskdb
        │
   replica.sync()  ──►  http://<tailscale-ip>:8080
```

- FRB v2 (`=2.12.0`), Cargokit builds the Rust crate automatically via Gradle for Android.
- Rust crate name: `rust_lib_taskwand`. Bridge API module: `crate::api` (see
  `flutter_rust_bridge.yaml`).

---

## Key files

| Path | What |
|------|------|
| `rust/src/api/tasks.rs` | **All bridge logic** — the file to edit for task behavior. Has a `#[cfg(test)]` CRUD test at the bottom. |
| `rust/Cargo.toml` | Rust deps + dev-deps (tempfile/tokio for tests). |
| `lib/main.dart` | **The entire UI** — one screen + editor sheet + settings sheet. |
| `lib/src/rust/` | FRB-generated Dart bindings — **do not edit by hand**; regenerate (see below). |
| `rust/src/frb_generated.rs` | FRB-generated Rust glue — do not edit; regenerate. |
| `flutter_rust_bridge.yaml` | Codegen config (`rust_input: crate::api`, outputs to `lib/src/rust`). |
| `android/app/src/main/AndroidManifest.xml` | INTERNET permission + `networkSecurityConfig`. |
| `android/app/src/main/res/xml/network_security_config.xml` | Permits cleartext HTTP (needed for `http://` over Tailscale on Android ≥9). |
| `rust_builder/` | Vendored Cargokit + Android glue (see patched files under "Fixes" below). |

---

## Rust bridge API (`rust/src/api/tasks.rs`)

All are `async` and operate on one global `REPLICA` guarded by a `tokio::sync::Mutex`.

- `open_replica(dir)` — open/create the SQLite replica. Called once on startup.
- `list_tasks(include_completed) -> Vec<TaskSummary>` — returns **non-deleted** tasks only
  (deleted/recurring/unknown always excluded). Pending-only unless `include_completed`.
  Sorted: pending before completed; within each, due-dated first (soonest), then undated
  alphabetically.
- `add_task(description, project: Option, due_unix: Option)`
- `modify_task(uuid, description, project: Option, due_unix: Option)` — edit; a `None`/empty
  project or `None` due clears that field.
- `complete_task(uuid)` / `uncomplete_task(uuid)` — done ↔ pending.
- `delete_task(uuid)` — sets status Deleted (recoverable on desktop via `task undo`).
- `sync_tasks(url, client_id, secret)` — sync against the sync-server.

`TaskSummary { uuid, description, project: Option<String>, due_unix: Option<i64>, status:
String }` where status is `"pending"` or `"completed"`.

### Two deliberate, non-obvious sync details (verified against taskchampion 3.1.0 docs)

1. **`sync_tasks` runs inside `tokio::task::spawn_blocking` + a nested current-thread
   runtime.** This is required, not stylistic: taskchampion's `dyn Server` and its sync
   future are **not `Send`**, but FRB's `wrap_async` requires a `Send` future. Isolating the
   non-Send work on one blocking-pool thread satisfies the bound. If you touch `sync_tasks`
   and hit "future cannot be sent between threads safely", this is why. Other functions
   don't need it.
2. **`replica.sync(&mut server, /*avoid_snapshots=*/ true)`** — the docs recommend `true` on
   devices more constrained than a desktop (a phone). No explicit `rebuild_working_set` call
   afterward: `sync()` already rebuilds it, and `list_tasks` uses `all_tasks()` which doesn't
   depend on the working set.

---

## UI (`lib/main.dart`) — feature map

- **App bar:** sync button (spinner while syncing) · show-completed toggle · settings.
- **Filter chips** (client-side, over the fetched list): All / Overdue / Today / Upcoming /
  No date. See `DateFilter` + `_visibleTasks`.
- **Task tiles:** circular checkbox (tap = complete/uncomplete), description (strikethrough
  when completed), project shown as a chip, relative due label (Today/Tomorrow/weekday/date,
  year shown when not the current year — `_formatDue`). Overdue due dates in the error color.
  **Swipe left to delete.** **Tap to edit.**
- **Editor sheet** (`TaskEditorSheet`, shared by add + edit): description, project, date
  picker (with clear). Edit mode also has a delete button. Returns an `EditorResult`.
  Note: `autofocus` is on only for **new** tasks — auto-focusing on edit caused frame drops
  (keyboard raise fighting the sheet's open animation).
- **Settings sheet** (`SettingsSheet`): Server URL, Client ID, Encryption secret (obscured),
  persisted via `shared_preferences`. "Sync now" surfaces errors verbatim in a SnackBar.
- **Lifecycle:** open replica on startup → load settings → load list → background sync;
  background sync + reload on app resume; fire-and-forget sync after every mutation.

Styling is stock Material 3, `ThemeMode.system` (dark-aware).

---

## Build / run / test

Run from the `taskwand/` directory.

```bash
# Regenerate FRB bindings after ANY signature change in rust/src/api/*.rs
flutter_rust_bridge_codegen generate

# Rust: check + run the CRUD unit test
cd rust && cargo check && cargo test && cd ..

# Static analysis
flutter analyze

# Run on a connected device (DEBUG — expect jank; not representative)
flutter run

# Judge real performance / smoothness
flutter run --profile
flutter run --release

# Downloadable release APK  ->  build/app/outputs/flutter-apk/app-release.apk
flutter build apk --release
# Smaller APK for an arm64 phone only:
flutter build apk --release --target-platform android-arm64
# Install to the connected device directly:
flutter install --release
```

Release APKs are debug-signed by the Flutter template, which is fine for sideloading (no
Play signing needed).

### Acceptance checklist (from the spec, all expected to pass)
1. Enter URL/client ID/secret (same as desktop `.taskrc`), Sync → desktop tasks appear.
2. `task add …` + `task sync` on laptop, pull-to-refresh on phone → appears.
3. Add on phone → `task sync && task list` on laptop → appears.
4. Complete on phone → after sync shows completed on laptop.
5. Airplane mode: add task persists across restart; re-enable + sync → reaches laptop.
6. Wrong secret → sync fails with a visible error, local data unharmed.

---

## Fixes already applied (would recur on a clean checkout / regeneration)

These touch **vendored** files, so re-apply if Cargokit or the FRB template is regenerated.

1. **Gradle 9 removed `Project.exec()` from task execution.**
   `rust_builder/cargokit/gradle/plugin.gradle` now injects `ExecOperations`
   (`@Inject abstract ExecOperations getExecOperations()`) and calls `execOperations.exec {}`
   instead of `project.exec {}`. Symptom if lost: *"Could not find method exec() … on project
   ':rust_lib_taskwand'"*. (Toolchain here: Gradle 9.1.0 + AGP 9.0.1.)

2. **rust_builder compileSdk too low.** `rust_builder/android/build.gradle` bumped from
   `compileSdkVersion 33` → `36` so transitive AndroidX deps requiring API 34+ resolve.
   Symptom if lost: `:rust_lib_taskwand:checkDebugAarMetadata` fails.

3. **Android manifest** (`android/app/src/main/`): `INTERNET` permission +
   `android:networkSecurityConfig` pointing at `res/xml/network_security_config.xml`, which
   permits cleartext HTTP (Tailscale/WireGuard encrypts transport). Already in place.

---

## Known gaps / non-goals (intentionally not built)

- No recurrence, annotations, tags UI, urgency, reports/filters, multiple accounts, iOS,
  theming. Per the spec — keep scope tight.
- No background sync service / WorkManager; foreground-only sync is the accepted scope.
- `list_tasks` uses `all_tasks()` (loads full history then filters). Fine for personal use;
  if a very large completed history ever makes the pending view slow, switch the
  `!include_completed` path to `pending_tasks()` (working-set based) as an optimization.

## Gotchas for the next session

- **Always run `flutter_rust_bridge_codegen generate` after changing a Rust bridge
  signature**, or `frb_generated.rs`/Dart bindings go stale and the build fails with
  mismatched fields/args.
- `dueUnix` maps to Dart `PlatformInt64`, which is `typedef = int` on native (Android), so
  plain `int` values work.
- Debug builds jank; measure in `--profile`/`--release` before chasing performance ghosts.
  Flutter 3.44 uses Impeller on Android (no SkSL shader-warmup needed).
