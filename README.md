# Shell-replicator

---

## Parallel rsync-over-SSH replication tool

Usage: replicator.sh SRC_DIR DEST_DIR

Overridable via environment: TMP, RUN_TS, EXCLUDE_FILE _(see below near the
exclude-pattern loading for its default location and file format)_.

---

---

### Adaptive JOBS:

Start from whatever the previous run decided worked well.

JOBS_DEFAULT above is only used the very first time (no history yet).

_See the adaptation logic near the end of the script for how this updates_.

---

### SSH connection multiplexing:

One real TCP+auth handshake, reused by the preflight check, every worker's rsync, and the replication-propagation calls. ControlPath must stay short (AF_UNIX socket path limit is 108 bytes) — deliberately anchored under /tmp rather than TMP, since TMP is user-configurable and could easily be deep enough to blow that limit (breaking every single SSH connection outright if it did).

---

### Cleanup:

only scrub working files when the run was fully successful.

Always removes pure plumbing (progress FIFO, empty fail-marker dir).

---

### Build file list:

Regular files, directories (incl. empty), and symlinks, so new files AND new/empty directories are always replicated.

Captures mtime too, so the destination comparison below can tell which files are actually new/changed versus already in sync.
