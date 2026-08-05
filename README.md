# Shell-replicator

---

## Parallel rsync-over-SSH replication tool

Usage: replicator.sh SRC_DIR DEST_DIR

Overridable via environment: TMP, RUN*TS, EXCLUDE_FILE *(see below near the
exclude-pattern loading for its default location and file format)\_.

---

---

### Adaptive JOBS:

1. Start from whatever the previous run decided worked well.

2. JOBS_DEFAULT above is only used the very first time (no history yet).

_See the adaptation logic near the end of the script for how this updates_.

---

### SSH connection multiplexing:

One real TCP+auth handshake, reused by the preflight check, every worker's rsync, and the replication-propagation calls. ControlPath must stay short (AF_UNIX socket path limit is 108 bytes) — deliberately anchored under /tmp rather than TMP, since TMP is user-configurable and could easily be deep enough to blow that limit (breaking every single SSH connection outright if it did).

---

### Cleanup:

1. Only scrub working files when the run was fully successful.

2. Always removes pure plumbing (progress FIFO, empty fail-marker dir).

---

### Build file list:

1. Regular files, directories (incl. empty), and symlinks, so new files AND new/empty directories are always replicated.

2. Captures mtime too, so the destination comparison below can tell which files are actually new/changed versus already in sync.
