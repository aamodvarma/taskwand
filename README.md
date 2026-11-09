# TaskWand

Minimal Android [Taskwarrior](https://taskwarrior.org) client built with Flutter and the [TaskChampion](https://github.com/GothenburgBitFactory/taskchampion) Rust crate.

- Local SQLite replica, works offline
- Syncs with a self-hosted `taskchampion-sync-server` (client ID + encryption secret), compatible with Taskwarrior 3.x
- Due dates, reminders, date filters, undo
- Home-screen widget

## Build

Requires Flutter and a Rust toolchain.

```sh
flutter pub get
flutter run                 # device or Linux desktop
flutter build apk --debug
cd rust && cargo test       # bridge crate tests
```

Regenerate bindings after editing `rust/src/api/`:

```sh
flutter_rust_bridge_codegen generate
```

## Layout

- `lib/` – Flutter UI
- `rust/src/api/tasks.rs` – TaskChampion bridge
- `HANDOFF.md` – detailed notes

## Setup

Open settings in the app and enter the sync server URL, client ID and secret.
