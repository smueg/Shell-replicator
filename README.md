# Shell-replicator

---

## Parallel rsync-over-SSH replication tool

Usage: replicator.sh SRC_DIR DEST_DIR

Overridable via environment: TMP, RUN*TS, EXCLUDE_FILE, REPLICATOR_CONFIG,
REPLICATOR_SETTINGS_DIR
*(see below for default locations and file formats)\_.

---

### Settings directory (`~/Replicator-Settings/` by default, override with `REPLICATOR_SETTINGS_DIR`)

All external settings are plain YAML files kept together in one directory
for easy maintenance (out of the script and out of git):

```
~/Replicator-Settings/
├── replicator-config.yaml     # destination connection settings + log dir
└── replicator-excludes.yaml   # exclude patterns
```

Each file is independently opt-in (missing file = that setting's default
applies) and each has its own override env var (`REPLICATOR_CONFIG`,
`EXCLUDE_FILE`) if you want to point it somewhere else entirely, outside
`REPLICATOR_SETTINGS_DIR`.

#### `replicator-config.yaml` — destination connection settings + log dir

```yaml
dest_host: 8.1.2.3
dest_user: user
ssh_port: 22
log_dir: ~/Replicator-Logs # optional path override; same as setting TMP
```

`dest_host`, `dest_user`, and `ssh_port` are required (via this file or the
matching env vars). `log_dir` is optional — it can also be set via the `TMP`
environment variable (which takes precedence over the file), falling back
to `/home/user/Replicator-Logs` if neither is set.

Any of these can also be set as environment variables (`DEST_HOST`,
`DEST_USER`, `SSH_PORT`, `TMP`), which take precedence over the config file.

#### `replicator-excludes.yaml` — exclude patterns

A YAML list of strings, opt-in — if the file doesn't exist, nothing is
excluded. Each entry is normalized into one of three matching behaviors:

1. **Bare name** (no `/`) — matches that name at _any depth_ in the tree,
   file or directory alike (same as `find -name`).
   ```yaml
   - node_modules
   - .DS_Store
   ```
2. **A path** (contains `/`, no trailing `/*`) — anchored to `SRC_DIR`,
   excludes that exact file/directory _and_, for a directory, everything
   beneath it. Can be relative to `SRC_DIR`, or absolute as long as it
   falls under `SRC_DIR` (the prefix is stripped automatically; an
   absolute path outside `SRC_DIR` can never match and is rejected with
   a warning).
   ```yaml
   - build/cache
   - /home/user/foo/logs
   ```
3. **A path ending in `/*`** — excludes only the _contents_ of that
   directory; the directory itself is still created/replicated (empty)
   on the destination.
   ```yaml
   - /home/user/foo/some-folder/*
   ```

A trailing single `/` (no wildcard) is stripped automatically, so
`Rsync-Test/` behaves like case 2 above. A pattern of exactly `*` or `**`
triggers a runtime warning since it would likely exclude the whole tree.
Leading `!` negation (a gitignore habit) is **not** supported — such an
entry is skipped with a warning rather than silently mistreated.

Both files require `python3` with PyYAML installed — YAML is parsed
natively, with no JSON conversion or `jq`/`yq` dependency involved.

---

### Build file list:

1. Regular files, directories (incl. empty), and symlinks, so new files AND new/empty directories are always replicated.

2. Captures mtime too, so the destination comparison below can tell which files are actually new/changed versus already in sync.

---

### SSH connection multiplexing:

One real TCP+auth handshake, reused by the preflight check, every worker's rsync, and the replication-propagation calls. ControlPath must stay short (AF_UNIX socket path limit is 108 bytes) — deliberately anchored under /tmp rather than TMP, since TMP is user-configurable and could easily be deep enough to blow that limit (breaking every single SSH connection outright if it did).

---

### Adaptive JOBS:

1. Start from whatever the previous run decided worked well.

2. JOBS_DEFAULT above is only used the very first time (no history yet).

_See the adaptation logic near the end of the script for how this updates_.

---

### Log files (written under `TMP`; Override Path to `~/some-folder`)

**Override provided in ~/Replicator-Settings/replicator-config.yaml**

Specifying "log_dir:"

Every run is stamped with `RUN_TS` (e.g. `20260805-142301`), so filenames
below never collide across runs.

**Always written, kept regardless of outcome:**

- `replicator_parallel_<RUN_TS>.log` — the main run log (`$LOG`): info/ok/warn/fail
  lines, retries, per-chunk OK/FAIL summaries.
- `replicator_summary_<RUN_TS>.tsv` — one row per chunk (`$SUMMARY_TXT`):
  exit code, bytes/files transferred, changed vs. already-in-sync counts.

**Kept only if the run fails** (any worker failure, or non-empty stderr);
deleted automatically on a fully successful run:

- `replicator_parallel_error_<RUN_TS>.log` — captured stderr (`$ERR_LOG`).
- `worker_<RUN_TS>_W*.log` — one log per parallel worker.
- `files_<RUN_TS>.txt` and `chunk_<RUN_TS>_*` — the full file list and its
  per-worker chunks.

**Always deleted at the end of the run** (transient working files, not
logs — never worth keeping): `src_listing_<RUN_TS>.txt`,
`dest_listing_<RUN_TS>.txt`, `toadd_<RUN_TS>.txt`,
`extraneous_<RUN_TS>.txt`, `progress_<RUN_TS>.fifo`.

**Persists across runs, never cleaned up:** `.jobs_state` — the adaptive
JOBS history (see below), not scoped to a single `RUN_TS`.

---

### Cleanup:

1. Only scrub working files when the run was fully successful.

2. Always removes pure plumbing (progress FIFO, empty fail-marker dir).

---
