# Shell-replicator

---

## Parallel rsync-over-SSH replication tool

Usage: replicator.sh SRC_DIR DEST_DIR

Overridable via environment: TMP, RUN*TS, EXCLUDE_FILE, REPLICATOR_CONFIG,
REPLICATOR_SETTINGS_DIR
*(see below for default locations and file formats)\_.

All sizes shown on-screen and in the per-run summary file are
human-readable (`B`/`KB`/`MB`/`GB`/`TB`/`PB`), not raw byte counts.

Exit codes: `0` success, `1` bad usage / missing tools / SSH or config
failure (nothing was transferred), `2` one or more chunks failed to
replicate (see the error log).

---

## How it works

The script runs these steps in order:

1. **Validate arguments** — `SRC_DIR` and `DEST_DIR` are required; `SRC_DIR`
   must exist as a directory, or the script exits immediately.
2. **Load settings** — reads `REPLICATOR_CONFIG` (if present) and applies
   any already-set environment variables on top of it; exits if
   `dest_host`/`dest_user`/`ssh_port` still aren't resolved. See
   [Settings directory](#settings-directory-fooreplicator-settings-by-default-override-with-replicator_settings_dir).
3. **Establish SSH connection multiplexing** — one control connection is
   opened and reused for every later SSH call this run. See
   [SSH connection multiplexing](#ssh-connection-multiplexing).
4. **Preflight: required tools** — checks for `rsync`, `ssh`, `pv`, `find`,
   `split`, `xargs`, `awk`, `stdbuf`, `grep`, `python3` (+ PyYAML); exits if
   anything is missing.
5. **Preflight: SSH connectivity** — connects to the destination and runs
   `mkdir -p` on `DEST_DIR` remotely; exits if the connection or directory
   creation fails.
6. **Load exclude patterns** — reads `EXCLUDE_FILE` (if present) and
   reports how many patterns are active. See
   [`replicator-excludes.yaml`](#replicator-excludesyaml--exclude-patterns).
7. **Scan the source tree** — walks `SRC_DIR` (honoring excludes) and
   records every file, directory, and symlink, plus size and mtime for
   each. See [Build file list](#build-file-list).
8. **Scan the destination tree and diff** — walks `DEST_DIR` over the same
   SSH connection and compares it against the source scan to determine
   exactly what needs adding/updating and what's extraneous (present on
   the destination but no longer in the source). See
   [Destination scan and diff](#destination-scan-and-diff).
9. **Chunk the file list** — splits the file list into chunks sized so
   there are always comfortably more chunks than the maximum job count,
   so concurrency isn't capped by chunk count. See
   [Parallel transfer workers](#parallel-transfer-workers).
10. **Start the progress bar** — only if step 8 found real work to do; one
    combined `pv` bar covers both additions and removals. See
    [Progress bar](#progress-bar).
11. **Run parallel rsync workers** — up to `JOBS` chunks transfer at once,
    each with its own retry/backoff on failure. See
    [Parallel transfer workers](#parallel-transfer-workers).
12. **Adapt `JOBS` for next run** — based on how this run went (failures,
    retries, or a clean run). See [Adaptive JOBS](#adaptive-jobs).
13. **Print the run summary** — chunk counts, failures, successes, retries,
    and the JOBS adjustment. If any chunk failed, the script stops here
    and exits `2` — deletions (next step) never run on a partial/failed
    transfer.
14. **Propagate deletions** — removes from `DEST_DIR` everything the
    diff in step 8 flagged as extraneous, feeding the same progress bar.
    Only runs after a fully successful transfer.
15. **Print the final summary** — files added/updated and items removed
    (human-readable sizes), plus the paths to the main log and the
    per-chunk summary file. See [Log files](#log-files-written-under-tmp-override-path-to-foo).
16. **Clean up** — always runs (via an exit trap), regardless of how the
    script exits. See [Cleanup](#cleanup).

---

## Settings directory (`/foo/Replicator-Settings/` by default, override with `REPLICATOR_SETTINGS_DIR`)

All external settings are plain YAML files kept together in one directory
for easy maintenance (out of the script and out of git):

```
/foo/Replicator-Settings/
├── replicator-config.yaml     # destination connection settings + log dir
└── replicator-excludes.yaml   # exclude patterns
```

Each file is independently opt-in (missing file = that setting's default
applies) and each has its own override env var (`REPLICATOR_CONFIG`,
`EXCLUDE_FILE`) if you want to point it somewhere else entirely, outside
`REPLICATOR_SETTINGS_DIR`.

#### `replicator-config.yaml` — destination connection settings + log dir

```yaml
dest_host: 203.0.113.1
dest_user: user
ssh_port: 22
log_dir: /foo/Replicator-Logs # optional path override; same as setting TMP
```

`dest_host`, `dest_user`, and `ssh_port` are required (via this file or the
matching env vars). `log_dir` is optional — it can also be set via the `TMP`
environment variable (which takes precedence over the file), falling back
to the system temp directory (`/tmp`) if neither is set.

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
   - /foo/logs
   ```
3. **A path ending in `/*`** — excludes only the _contents_ of that
   directory; the directory itself is still created/replicated (empty)
   on the destination.
   ```yaml
   - /foo/some-folder/*
   ```

A trailing single `/` (no wildcard) is stripped automatically, so
`Rsync-Test/` behaves like case 2 above. A pattern of exactly `*` or `**`
triggers a runtime warning since it would likely exclude the whole tree.
Leading `!` negation (a gitignore habit) is **not** supported — such an
entry is skipped with a warning rather than silently mistreated.

Exclude patterns are applied twice: once locally via `find -prune` when
building the source file list, and again as `rsync --exclude` flags inside
each worker (defense-in-depth, not currently load-bearing on its own).

Both files require `python3` with PyYAML installed — YAML is parsed
natively, with no JSON conversion or `jq`/`yq` dependency involved.

---

### Build file list

1. Regular files, directories (incl. empty), and symlinks, so new files AND new/empty directories are always replicated.

2. Captures mtime too, so the destination comparison below can tell which files are actually new/changed versus already in sync.

---

### Destination scan and diff

Before any transfer starts, the destination tree is scanned the same way
the source was (same `find`-based walk, run remotely over the multiplexed
SSH connection), so the script knows the complete picture up front:

1. **Additions/updates** — anything in the source that's missing from the
   destination, or a file whose size or mtime differs (the same
   comparison rsync's own default quick-check uses).
2. **Extraneous items** — anything present on the destination but no
   longer in the source; these are only ever removed after a fully
   successful transfer (see step 14 in [How it works](#how-it-works)).

Both lists are used to size the progress bar accurately and to print the
names of what's changing (capped at `NAME_LIST_CAP`, currently 50, so a
huge change set doesn't flood the terminal — still reported as a real
count, never silently truncated).

If the destination can't be listed at all (e.g. SSH hiccup), the script
doesn't fail — it falls back to treating the whole source as needing
verification, since that's what rsync will check anyway, and skips the
deletion step entirely for that run.

---

### Parallel transfer workers

The file list is split into chunks — sized so there are always
comfortably more chunks than the maximum job count (`JOBS_MAX`), so
concurrency is never capped by chunk count regardless of how high `JOBS`
adapts. Small trees have a floor (200 lines) so they aren't fragmented
into tiny chunks that each pay their own rsync/connection overhead.

Up to `JOBS` chunks run concurrently via `xargs -P`. Each worker:

- Runs one `rsync -aHAX` pass over its chunk (`--files-from`), sharing the
  multiplexed SSH connection.
- Retries up to 4 attempts total on failure, backing off 10s, 30s, then
  60s between attempts.
- Streams per-file transfer progress into the shared progress bar.
- Writes its own log (kept only if the run fails) and appends a row to
  the per-chunk summary file.

Deletion of files removed from the source is **not** handled by rsync's
own `--delete` inside each worker (a worker only ever sees its own
chunk's fragment of any given directory, so `--delete` would have no
complete view). It's handled separately, after all chunks succeed — see
step 14 in [How it works](#how-it-works).

---

## SSH connection multiplexing

One real TCP+auth handshake, reused by the preflight check, every worker's rsync, and the replication-propagation calls. ControlPath must stay short (AF_UNIX socket path limit is 108 bytes) — deliberately anchored under `/tmp` rather than TMP, since TMP is user-configurable and could easily be deep enough to blow that limit (breaking every single SSH connection outright if it did).

---

### Progress bar

A single `pv` bar, sized to the combined bytes of everything that will
actually change this run (additions + removals from the destination
diff), is shown only when there's real work to do. It's fed twice: once
per completed file during the parallel transfer (step 11), and again
during deletion propagation (step 14) — so one bar spans the whole run.
When nothing needs to change, the script says so and skips the bar
entirely.

---

## Adaptive JOBS

1. Start from whatever the previous run decided worked well.

2. `JOBS_DEFAULT` above is only used the very first time (no history yet).

3. At the end of each run, the next run's starting `JOBS` is decided by
   how this run went: any chunk failure halves it, a clean run that still
   needed retries backs off by one, and a fully clean run with no retries
   nudges it up by one — always bounded to `[JOBS_MIN, JOBS_MAX]`.

---

## Log files (written under `TMP`; defaults to `/tmp` if unset)

Resolved in this order: the `TMP` environment variable, then `log_dir` from
`/foo/Replicator-Settings/replicator-config.yaml`, then `/tmp` if neither
is set — no `log_dir` configured means logs land in the system temp
directory rather than some hardcoded, user-specific path.

Every run is stamped with `RUN_TS` (e.g. `20260805-142301`), so filenames
below never collide across runs.

**Always written, kept regardless of outcome:**

- `replicator_parallel_<RUN_TS>.log` — the main run log (`$LOG`): info/ok/warn/fail
  lines, retries, per-chunk OK/FAIL summaries.
- `replicator_summary_<RUN_TS>.tsv` — one row per chunk (`$SUMMARY_TXT`):
  exit code, size/files transferred (human-readable, e.g. `1.2 MB`), changed
  vs. already-in-sync counts.

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
JOBS history (see above), not scoped to a single `RUN_TS`.

---

## Cleanup

1. Only scrub working files when the run was fully successful.

2. Always removes pure plumbing (progress FIFO, empty fail-marker dir).

3. Always tears down the SSH multiplexed control connection, regardless of
   outcome.

---
