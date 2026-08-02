# Captain operations

`fmw doctor` is static installation validation.
It does not require a captain, acquire a lock, inspect a watcher, or modify live state.

`fmw captain status` is read-only operational diagnosis.
It reports the Herdr server and terminal identity, the effective `FM_HOME`, captain lock ownership, watcher lock and beacon freshness, and the two official Firstmate Pi extensions.
It never creates a lock, touches a beacon, arms a watcher, stops Herdr, or changes fleet state.

`fmw captain` is a safe launch guide.
Run it from the intended Herdr-managed pane.
It refuses a second live captain and refuses stale or malformed lock repair.
When no captain is present, it prints one exact command that inherits the existing `HERDR_*` identity, runs Firstmate's official `fm-session-start.sh`, loads the tracked Pi watcher and turn-end extensions, and asks Pi to call `fm_watch_arm_pi` once.
It does not start or stop the Herdr server automatically.

The supervisor, watcher, and later tasks must use the same configured `FM_HOME`.
A live captain with a missing or stale watcher is reported as `WATCHER_STALE` and must be repaired through the official Pi extension path.
A live lock held by another process is `LOCKED_BY_OTHER`; do not delete the lock or start another captain.
A dead lock is reported as `READ_ONLY` for manual inspection.

Operational states use these exit semantics:

- `READY` and `NOT_RUNNING`: exit 0.
- `MISCONFIGURED`, `LOCKED_BY_OTHER`, `READ_ONLY`, and `WATCHER_STALE`: exit non-zero.

The E2E smoke flow remains a separate explicit operation and is not part of either command.
