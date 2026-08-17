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
replicate (see the error log), `3` transfer succeeded but deletion
propagation (removing extraneous destination items) failed (see the error
log).

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
4. **Preflight: required tools** — checks for `rsync`, `ssh`, `find`,
   `split`, `xargs`, `awk`, `stdbuf`, `grep`, `python3` (+ PyYAML and
   `tqdm`, the latter used to render the progress bars — see
   [Progress bar](#progress-bar)); exits if anything is missing.
5. **Preflight: SSH connectivity** — connects to the destination and runs
   `mkdir -p` on `DEST_DIR` remotely; exits if the connection or directory
   creation fails.
6. **Load exclude patterns** — reads `EXCLUDE_FILE` (if present) and
   reports how many patterns are active. See
   [`replicator-excludes.yaml`](#replicator-excludesyaml--exclude-patterns).
7. **Scan the source and destination trees concurrently** — `SRC_DIR` is
   walked locally while `DEST_DIR` is walked over the same SSH connection
   at the same time (two background jobs, joined before the diff), since
   the two scans are otherwise independent and the remote one is a full
   SSH round-trip. See [Build file list](#build-file-list) and
   [Destination scan and diff](#destination-scan-and-diff).
8. **Diff source vs. destination** — once both scans are in, determines
   exactly what needs adding/updating and what's extraneous (present on
   the destination but no longer in the source). See
   [Destination scan and diff](#destination-scan-and-diff).
9. **Chunk the file list** — splits the file list into chunks sized so
   there are always comfortably more chunks than the maximum job count,
   so concurrency isn't capped by chunk count. See
   [Parallel transfer workers](#parallel-transfer-workers).
10. **Run parallel rsync workers, with a live "Uploading" progress bar** —
    up to `JOBS` chunks transfer at once, each with its own retry/backoff
    on failure; a live aggregate header line plus one row per concurrently
    active worker (only if step 8 found additions/updates) tracks the
    transfer as it actually happens — several files in flight at once show
    as several rows, each with its own real 0–100% bar for that specific
    file — and is fully closed before anything below prints.
    See [Progress bar](#progress-bar) and
    [Parallel transfer workers](#parallel-transfer-workers).
11. **Adapt `JOBS` for next run** — based on how this run went (failures,
    retries, or a clean run). See [Adaptive JOBS](#adaptive-jobs).
12. **Propagate deletions, with a live "Removing" progress bar** — removes
    from `DEST_DIR` everything the diff in step 8 flagged as extraneous,
    with its own header + row (separate from the Uploading block above),
    fully closed before the summary prints. Only runs after a fully
    successful transfer — skipped entirely if any chunk failed.
13. **Print the summary** — chunk counts, failures, successes, retries, the
    JOBS adjustment, deletion outcome, and files added/updated + items
    removed (human-readable sizes), plus the paths to the main log and the
    per-chunk summary file. Printed only after both progress phases above
    are fully closed, so it never interleaves with a still-live progress
    line. If any chunk failed, exits `2` here (deletions never ran). If
    deletion propagation itself failed, exits `3` here. See
    [Log files](#log-files-written-under-tmp-override-path-to-foo).
14. **Clean up** — always runs (via an exit trap), regardless of how the
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
SSH connection) — and, since the two scans don't depend on each other, they
run concurrently as two background jobs (local `find` for the source,
remote `ssh find` for the destination) rather than one after the other, so
the script isn't paying the destination's SSH round-trip on top of the
source scan's time. Both are joined before the diff, which then works out:

1. **Additions/updates** — anything in the source that's missing from the
   destination, or a file whose size or mtime differs (the same
   comparison rsync's own default quick-check uses).
2. **Extraneous items** — anything present on the destination but no
   longer in the source; these are only ever removed after a fully
   successful transfer (see step 12 in [How it works](#how-it-works)).

Both lists are used to size the progress bars accurately and to print the
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
- Streams per-file transfer progress (bytes and item name) into the
  "Uploading" progress phase.
- Writes its own log (kept only if the run fails) and appends a row to
  the per-chunk summary file.

Deletion of files removed from the source is **not** handled by rsync's
own `--delete` inside each worker (a worker only ever sees its own
chunk's fragment of any given directory, so `--delete` would have no
complete view). It's handled separately, after all chunks succeed — see
step 12 in [How it works](#how-it-works).

---

## SSH connection multiplexing

One real TCP+auth handshake, reused by the preflight check, every worker's rsync, and the replication-propagation calls. ControlPath must stay short (AF_UNIX socket path limit is 108 bytes) — deliberately anchored under `/tmp` rather than TMP, since TMP is user-configurable and could easily be deep enough to blow that limit (breaking every single SSH connection outright if it did).

---

### Progress bar

Two sequential phases — one for the upload/update transfer, one for
deletion propagation — both labeled simply **"Syncing"** (the wording is
the same regardless of whether the objects underneath are being
added, updated, or removed; the per-object action tag, and its color,
already carries that distinction). Each phase is rendered with Python's
[`tqdm`](https://github.com/tqdm/tqdm) as a **manifest**: every object
rsync actually itemizes — regular file, directory, symlink, device, or
anything else — gets its own entry, not just regular files. Each entry
gets a real, independently-updating 0–100% bar while it's actually being
synced, with its fill color **progressing red → amber → green as it nears
completion** rather than sitting at one static color. The instant it
finishes, that bar is replaced by a **permanent, colored, one-line
completion record**, tagged with what it was and what kind of object it
is — so the display becomes a line-by-line log of the whole manifest, not
just a snapshot of whatever happened to still be moving when you looked.
A single aggregate bar for the phase as a whole sits **last, below the
entire manifest**, for the whole duration of the phase — not just once
everything above it has finished:

```
✓ UPD FILE file_updated.txt  100%  14.0B  in 00:00  avg 39.9B/s
✓ UPD LNK  link_new  100%  16.0B  in 00:00  avg 45.6B/s
  NEW FILE other_target.txt   62%|███████████        | 8.00/13.0  37.1B/s  elapsed 00:00 ETA 00:00
Syncing TOTAL:  77%|███████████████             | 30.0/39.0B  58.0B/s  elapsed 00:01
```

The top two lines are permanent completion records (bold, green ✓ for
`NEW`, cyan for `UPD`, red for `DEL`, followed by a type tag — `FILE`,
`DIR`, `LNK`, `DEV`, `SPEC`, or `OBJ` for anything else — the object's
name, final size, how long it took, and its average transfer rate) — these
stay on screen for the rest of the run and are still there in a screenshot
or terminal copy/paste taken any time afterward. The third line is a live
bar for whatever's still actually being synced — its own percent, bytes
done/total, rate, elapsed time, and ETA, with a bold action+type tag and a
fill color that shifts from red toward green as it approaches 100%. The
last line is the bold `TOTAL` aggregate for the whole phase, whose own
fill color progresses the same way; it's always the bottom-most line of
the block, so it reads as the running total *underneath* the manifest
rather than something separate from it.

Only regular-file bytes count toward the aggregate's own percentage —
directories, symlinks, and other non-file objects still get their own live
bar and permanent completion line, but contribute nothing to the
byte-total math, matching how the "Total data size" reported at the start
of the run is computed (file bytes only). Folding a directory's own
(usually 4KB-inode) size into that total would let the aggregate reach
100% before every object in the manifest was actually finished.

- **Uploading** phase (labeled "Syncing" on screen, during step 10). Sized
  to the bytes the destination diff found needs adding/updating. Live bars
  use up to `min(JOBS, chunk count, items actually needing upload,
  PROGRESS_MAX_SLOTS)` screen rows, reused across the run as objects finish
  and new ones start — but that cap only limits how many can be
  concurrently *in flight* on screen at once, not how many completion
  records accumulate: every object that's added or updated gets its own
  permanent line regardless of `PROGRESS_MAX_SLOTS`. Each worker's rsync
  runs with `--progress`, which reports real incremental byte/percent
  updates *for whichever file that worker is currently sending* — that's
  what drives each file's live bar (directories/symlinks/etc. have no
  incremental progress of their own — rsync itemizes them and moves on —
  so their bar jumps straight to 100%, held visible the same guaranteed
  minimum duration as everything else; see below). Capping by chunk count
  and by how many items actually need uploading matters on an incremental
  run: chunking is sized off the whole tree (so every chunk's rsync
  quick-check runs), not off how few items the diff found changed, so most
  chunks on a small incremental sync transfer nothing at all — without
  this cap the live-bar pool would reserve rows for workers that were
  never going to have anything to show.
- **Removing** phase (also labeled "Syncing" on screen, during step 12),
  sized to the bytes the diff found extraneous on the destination.
  Deletion isn't parallelized (one sequential SSH call walks the
  extraneous list) and `rm` has no partial-progress concept of its own, so
  each removed object's live bar jumps straight to 100% and becomes a
  permanent completion line tagged `DEL`.

A file small or fast enough to finish within a single redraw tick would
otherwise skip the live bar entirely — created and immediately replaced by
its completion line before a human eye could ever register it, especially
over a fast connection. Two things prevent that: every bar gets one
unthrottled `refresh()` the instant it's created (so its first, red frame
is always actually written to the terminal, not just internally tracked
and then silently redrawn-over), and a slot is held open for at least 0.35
seconds before being closed/reused, even if the underlying transfer already
finished faster than that. That hold only delays the *display*, not the
real rsync work behind it, which has already completed — but it does sit
in the same single-threaded reader that drains `PROGRESS_EVENTS_FIFO`, so
an unbounded version of it could, on a run with hundreds of tiny files,
fall behind far enough to back up the FIFO's kernel buffer and start
blocking worker writes — turning a cosmetic nicety into a real slowdown.
A 3-second total budget for this hold, shared across the whole phase,
keeps that worst case bounded: once spent, files still get their
guaranteed first frame, just not the extra hold time.

Getting real sub-file progress out of `rsync --progress` requires reading
its output character-by-character rather than line-by-line: rsync
`\r`-separates the incremental updates for one file (so a real terminal
overwrites them in place) and only emits a true `\n` once that file is
done — a plain `read` loop would block until then and only ever see the
fully-transferred state. Each worker instead pipes rsync's output through
`tr '\r' '\n'` first, turning every incremental update into its own line
the instant it's flushed, then classifies each resulting line as either a
"started file X (size N)" or "progress: N bytes so far" event and pushes
it to the shared events stream tagged with that worker's id.

Each phase is driven by a single Python reader process (embedded in
`replicator.sh` the same way the YAML config/exclude-file parsers are, via
`python3 - <<'PYEOF' ... PYEOF`) — not one process per worker — that reads
those tagged events and attributes each to the live bar its worker owns:
reusing the row already assigned to that worker, claiming a free row, or
reclaiming the least-recently-updated row once all of them are in use (its
occupant is finished, so it's turned into a completion line first). A
finished live bar is closed with `leave=False` (clears its row) and
immediately followed by a `tqdm.write()` call, which is `tqdm`'s
purpose-built way to interleave a permanent scrolled line with still-active
bars — it temporarily clears them, writes the line above, and redraws them.
Earlier attempts at "leave the bar itself behind, frozen" by opening every
file's bar at its own never-reused `position=` and closing it with
`leave=True` looked reasonable but turned out to corrupt `tqdm`'s own
cursor bookkeeping once more than one such bar was ever open at a time —
verified with a raw pty capture replayed through a real terminal emulator
([`pyte`](https://github.com/selectel/pyte)), which showed leftover
trailing characters and, in one case, a line rendered in the wrong screen
position entirely; `position=`+`leave=True` closes are only safe one at a
time, which a genuinely concurrent multi-file transfer can't guarantee.
`tqdm.write()` doesn't have that restriction, which is why the permanent
record goes through it instead.

The aggregate bar itself hits a related but distinct `tqdm` quirk: its
`close()` method hardcodes `self.display(pos=0)` for a `leave=True` bar,
regardless of that bar's actual `position=` — verified by reading `tqdm`'s
own source. That's a reasonable assumption for the conventional case (a
`leave=True` bar is normally the outer/root bar, already at position 0),
but the aggregate here is deliberately positioned *last* (`position=n`, the
bottom row, so it renders under the manifest rather than above it) — so
that hardcoded call wrote its final frame at the wrong row, corrupting the
block (a duplicated frame, and a banner line getting overwritten,
reproduced and confirmed via the same `pyte`-replayed pty capture
mentioned above). Sidestepped the same way per-object completions already
are: the aggregate closes `leave=False` (the codepath that *does* use its
real position) once every other bar in the phase has already closed, and
its own final line is hand-written via `tqdm.write()` immediately after —
prefixed with an explicit `\r`, since (also verified from source) the
`leave=False` close path clears via `display(msg='', pos=pos)` directly
rather than `tqdm`'s own `clear()`, and only `clear()` resets the cursor's
column back to the start of the line afterward.

Every `tqdm` instance is created with an explicit `ncols=` (from
`shutil.get_terminal_size()`, with a `120`-column fallback) rather than
left to auto-detect. `tqdm`'s own renderer silently discards the entire
custom `bar_format` above — falling back to its plain built-in layout, no
colors, no `TOTAL`/elapsed detail — whenever it resolves the terminal width
to exactly `0` columns, which some environments report (certain
multiplexers, log-capture wrappers, or a pty whose window size hasn't
propagated yet). Passing an explicit width sidesteps that codepath so the
richer formatting can't silently vanish.

This also deliberately does *not* run `pv` as a second, independent
live-updating process: two uncoordinated processes both writing
cursor-control sequences to the same terminal can't be made reliably
race-free in a shell script, and an earlier version of this that tried
(`pv` for the bar, a second process for a "current item" line) would
occasionally lose sync and print duplicate/stacked bars instead of
overwriting in place. A single writer has nothing to race with.

A phase is skipped entirely if it has nothing to do (e.g. an update-only
run skips "Removing"). Both phases are always fully finished and closed
before the summary section prints, so the live output never interleaves
with the summary text. Redraws are throttled to at most 4/sec so a tree
with many small files doesn't flood the terminal, and the whole live
display is skipped when stderr isn't a terminal (e.g. output redirected to
a file) — nothing here is written in that case. When there's nothing to
add or remove at all, the script says so and skips both phases. Requires
the `tqdm` Python module (see [step 4](#how-it-works) above).

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
`extraneous_<RUN_TS>.txt`, `progress_events_<RUN_TS>.fifo`,
`local_scan_<RUN_TS>.txt`, `dest_scan_exit_<RUN_TS>.txt`.

**Persists across runs, never cleaned up:** `.jobs_state` — the adaptive
JOBS history (see above), not scoped to a single `RUN_TS`.

---

## Cleanup

1. Only scrub working files when the run was fully successful.

2. Always removes pure plumbing (progress FIFO, empty fail-marker dir).

3. Always tears down the SSH multiplexed control connection, regardless of
   outcome.

---
