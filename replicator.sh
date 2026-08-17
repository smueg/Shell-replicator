#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Parallel rsync-over-SSH replication tool
# Usage: replicator.sh SRC_DIR DEST_DIR
#
# Overridable via environment: TMP, RUN_TS, EXCLUDE_FILE, REPLICATOR_CONFIG,
# REPLICATOR_SETTINGS_DIR (see below near the relevant loading logic for
# default locations and file formats).
# ============================================================================

SRC_DIR="${1:-}"
DEST_DIR="${2:-}"

if [[ -z "${SRC_DIR}" || -z "${DEST_DIR}" ]]; then
  echo "Usage: $0 SRC_DIR DEST_DIR" >&2
  exit 1
fi
[[ -d "$SRC_DIR" ]] || { echo "SRC_DIR is not a directory: $SRC_DIR" >&2; exit 1; }

# ---------------------------------------------------------------------------
# YAML loading helpers: shared by REPLICATOR_CONFIG and EXCLUDE_FILE below.
# Read and validated with python3+PyYAML directly — no
# JSON intermediate representation and no `jq`/`yq` dependency anywhere in
# the pipeline.
#
# yaml_read_mapping FILE KEY [KEY ...]
#   Validates FILE parses as a YAML mapping, then prints each requested
#   key's value on its own line (blank line for a missing/null key), in
#   the order given. A YAML syntax error, or FILE not being a mapping,
#   prints a message to stderr and exits non-zero.
#
# yaml_read_list FILE
#   Validates FILE parses as a YAML list of strings, then prints each
#   element on its own line. Same error handling as above.
# ---------------------------------------------------------------------------
yaml_read_mapping() {
  local file="$1"; shift
  python3 - "$file" "$@" <<'PYEOF'
import sys, yaml

path = sys.argv[1]
keys = sys.argv[2:]
try:
    with open(path) as f:
        data = yaml.safe_load(f)
except yaml.YAMLError as e:
    print(f"YAML parse error in {path}: {e}", file=sys.stderr)
    sys.exit(1)

if data is None:
    data = {}
if not isinstance(data, dict):
    print(f"{path} must be a YAML mapping (key: value pairs)", file=sys.stderr)
    sys.exit(1)

for k in keys:
    v = data.get(k)
    print("" if v is None else v)
PYEOF
}

yaml_read_list() {
  local file="$1"
  python3 - "$file" <<'PYEOF'
import sys, yaml

path = sys.argv[1]
try:
    with open(path) as f:
        data = yaml.safe_load(f)
except yaml.YAMLError as e:
    print(f"YAML parse error in {path}: {e}", file=sys.stderr)
    sys.exit(1)

if data is None:
    data = []
if not isinstance(data, list) or not all(isinstance(x, str) for x in data):
    print(f"{path} must be a YAML list of strings", file=sys.stderr)
    sys.exit(1)

for item in data:
    print(item)
PYEOF
}

# ---------------------------------------------------------------------------
# All external settings (this file, EXCLUDE_FILE below) live together in
# $HOME/Replicator-Settings/ for easy maintenance — kept out of the script
# (and out of git), same "opt-in" pattern as before. Format:
#   dest_host: 203.0.113.1
#   dest_user: user
#   ssh_port: 22
#   log_dir: /home/user/Rsync-logs   # optional; see TMP below (defaults to /tmp if unset)
# Env vars, if already set when the script is invoked, take precedence over
# the config file (config file only fills in what isn't already set).
# ---------------------------------------------------------------------------
REPLICATOR_SETTINGS_DIR="${REPLICATOR_SETTINGS_DIR:-$HOME/Replicator-Settings}"
REPLICATOR_CONFIG="${REPLICATOR_CONFIG:-$REPLICATOR_SETTINGS_DIR/replicator-config.yml}"
if [[ -f "$REPLICATOR_CONFIG" ]]; then
  command -v python3 >/dev/null 2>&1 || { echo "python3 (with PyYAML) is required to read $REPLICATOR_CONFIG but is not installed." >&2; exit 1; }

  CONFIG_VALS="$(yaml_read_mapping "$REPLICATOR_CONFIG" dest_host dest_user ssh_port log_dir)" || exit 1
  mapfile -t CONFIG_VALS_ARR <<<"$CONFIG_VALS"
  CONF_DEST_HOST="${CONFIG_VALS_ARR[0]:-}"
  CONF_DEST_USER="${CONFIG_VALS_ARR[1]:-}"
  CONF_SSH_PORT="${CONFIG_VALS_ARR[2]:-}"
  CONF_LOG_DIR="${CONFIG_VALS_ARR[3]:-}"

  DEST_HOST="${DEST_HOST:-$CONF_DEST_HOST}"
  DEST_USER="${DEST_USER:-$CONF_DEST_USER}"
  SSH_PORT="${SSH_PORT:-$CONF_SSH_PORT}"
  TMP="${TMP:-$CONF_LOG_DIR}"
fi

DEST_HOST="${DEST_HOST:-}"
DEST_USER="${DEST_USER:-}"
SSH_PORT="${SSH_PORT:-}"

if [[ -z "$DEST_HOST" || -z "$DEST_USER" || -z "$SSH_PORT" ]]; then
  echo "Missing DEST_HOST, DEST_USER, and/or SSH_PORT." >&2
  echo "Set them in $REPLICATOR_CONFIG (or export as environment variables). Example:" >&2
  echo '  dest_host: 203.0.113.1' >&2
  echo '  dest_user: user' >&2
  echo '  ssh_port: 22' >&2
  exit 1
fi

JOBS_DEFAULT=8
JOBS_MIN=2
JOBS_MAX=32
# Cap on how many simultaneous live per-file bar positions the progress
# display (see start_progress_phase below) reuses at once, regardless of how
# high JOBS is — past this, more rows costs terminal real estate without
# adding much readability. Every file still gets a permanent completion line
# once it finishes, regardless of this cap — it only bounds how many can be
# concurrently *in flight* on screen at once.
PROGRESS_MAX_SLOTS=10
# CHUNK_LINES itself is computed dynamically once the source tree is
# scanned (see below) — sized relative to JOBS_MAX so chunk count never
# becomes the bottleneck on concurrency.

# Log/working-file directory: env TMP wins if already set, else log_dir
# from REPLICATOR_CONFIG (loaded above), else the system temp directory —
# no log_dir configured means logs land in /tmp rather than silently
# picking a path specific to whoever first wrote this script.
TMP="${TMP:-/tmp}"
RUN_TS="${RUN_TS:-$(date +%Y%m%d_%H%M%S)}"

# Exclude patterns: a YAML file in REPLICATOR_SETTINGS_DIR (not tied to
# wherever the script itself lives), opt-in — absence of this file means
# zero exclusions. See load_exclude_patterns() below for the format.
EXCLUDE_FILE="${EXCLUDE_FILE:-$REPLICATOR_SETTINGS_DIR/replicator-excludes.yml}"

# Used both for the exclude-pattern report and the add/remove name listings
# further down.
NAME_LIST_CAP=50

mkdir -p "$TMP"

# ---------------------------------------------------------------------------
# Adaptive JOBS: start from whatever the previous run decided worked well.
# JOBS_DEFAULT above is only used the very first time (no history yet).
# See the adaptation logic near the end of the script for how this updates.
# ---------------------------------------------------------------------------
JOBS_STATE_FILE="$TMP/.jobs_state"
if [[ -f "$JOBS_STATE_FILE" ]] && JOBS="$(cat "$JOBS_STATE_FILE" 2>/dev/null)" && [[ "$JOBS" =~ ^[0-9]+$ ]]; then
  # Defense-in-depth: clamp even on read, in case the state file was
  # hand-edited or written by a future code path that forgets to clamp.
  [[ "$JOBS" -lt "$JOBS_MIN" ]] && JOBS="$JOBS_MIN"
  [[ "$JOBS" -gt "$JOBS_MAX" ]] && JOBS="$JOBS_MAX"
else
  JOBS="$JOBS_DEFAULT"
fi

# ---------------------------------------------------------------------------
# SSH connection multiplexing: one real TCP+auth handshake, reused by the
# preflight check, every worker's rsync, and the replication-propagation
# calls. ControlPath must stay short (AF_UNIX socket path limit is 108
# bytes) — deliberately anchored under /tmp rather than TMP, since TMP is
# user-configurable and could easily be deep enough to blow that limit
# (breaking every single SSH connection outright if it did).
# ---------------------------------------------------------------------------
SSH_CTL_PATH="/tmp/.rsync-ssh-cm-%C"
SSH_CTL_OPTS="-o ControlMaster=auto -o ControlPersist=120s -o ControlPath=$SSH_CTL_PATH"
ssh -O exit -o ControlPath="$SSH_CTL_PATH" -p "$SSH_PORT" "${DEST_USER}@${DEST_HOST}" 2>/dev/null || true

LOG="$TMP/replicator_parallel_${RUN_TS}.log"
ERR_LOG="$TMP/replicator_parallel_error_${RUN_TS}.log"
FILES_TXT="$TMP/files_${RUN_TS}.txt"
CHUNK_PREFIX="$TMP/chunk_${RUN_TS}_"
SUMMARY_TXT="$TMP/replicator_summary_${RUN_TS}.tsv"
FAIL_MARKERS_DIR="$TMP/failmarkers_${RUN_TS}"
PROGRESS_EVENTS_FIFO="$TMP/progress_events_${RUN_TS}.fifo"
SRC_LISTING="$TMP/src_listing_${RUN_TS}.txt"
DEST_LISTING="$TMP/dest_listing_${RUN_TS}.txt"
ADD_FULL="$TMP/toadd_${RUN_TS}.txt"
EXTRANEOUS_FULL="$TMP/extraneous_${RUN_TS}.txt"
LOCAL_SCAN_RESULT="$TMP/local_scan_${RUN_TS}.txt"
DEST_SCAN_EXIT_FILE="$TMP/dest_scan_exit_${RUN_TS}.txt"

mkdir -p "$FAIL_MARKERS_DIR"

# ---------------------------------------------------------------------------
# Colors / on-screen styling (disabled automatically when not a terminal)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
  C_BLUE=$'\e[34m'; C_CYAN=$'\e[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_RED=""; C_GREEN=""; C_YELLOW=""
  C_BLUE=""; C_CYAN=""
fi

human_size() {
  awk -v bytes="${1:-0}" 'BEGIN {
    units[0]="B"; units[1]="KB"; units[2]="MB"; units[3]="GB"; units[4]="TB"; units[5]="PB"
    size = bytes + 0
    i = 0
    while (size >= 1024 && i < 5) { size /= 1024; i++ }
    if (i == 0) printf "%d %s", size, units[i]
    else printf "%.1f %s", size, units[i]
  }'
}

hr()     { printf '%s\n' "${C_DIM}────────────────────────────────────────────────────────────────${C_RESET}"; }
banner() { hr; printf '%s\n' "${C_BOLD}${C_CYAN}  $1${C_RESET}"; hr; }
info()   { printf '%s\n' "${C_BLUE}➤${C_RESET} $1" | tee -a "$LOG"; }
ok()     { printf '%s\n' "${C_GREEN}✔${C_RESET} $1" | tee -a "$LOG"; }
warn()   { printf '%s\n' "${C_YELLOW}⚠${C_RESET} $1" | tee -a "$LOG"; }
fail()   { printf '%s\n' "${C_RED}✘${C_RESET} $1" | tee -a "$LOG" >&2; }

# ---------------------------------------------------------------------------
# Exclude patterns: a YAML list of strings in $EXCLUDE_FILE, e.g.
#   - node_modules
#   - "*.log"
#   - /home/user/Projects/foo/*
# Blank/whitespace-only strings are ignored. No negation (a leading '!' is a
# gitignore habit, not supported here — skipped with a warning rather than
# silently mistreated as a literal filename). Absence of the file means zero
# exclusions: no auto-create, no defaults, strictly opt-in. YAML supports
# '#' comments natively, so annotate patterns right in the file if needed.
#
# Each raw pattern is normalized (right here at load time, ONCE) into one
# of two internal forms, stored in EXCLUDE_PATTERNS as "kind:value":
#   "name:VALUE" — a bare pattern (no '/'): matches VALUE at any depth,
#                  same as find's -name / rsync's unanchored --exclude.
#   "path:VALUE" — VALUE is relative to the sync root: matches only that
#                  exact relative path, same as find's -path anchored at
#                  SRC_DIR (or DEST_DIR on the remote side) / rsync's
#                  --exclude=/VALUE.
# Users naturally write exclude patterns as absolute filesystem paths
# (e.g. "/home/user/Projects/foo/*") rather than paths relative to
# SRC_DIR — an absolute pattern is accepted as long as it falls under
# SRC_DIR, with the SRC_DIR prefix stripped to produce the relative form;
# an absolute pattern that does NOT fall under SRC_DIR can never match
# anything on either side and is rejected with a warning rather than
# silently doing nothing (which is exactly the bug this replaced: patterns
# that looked valid but matched zero files, so nothing was ever excluded).
# ---------------------------------------------------------------------------
EXCLUDE_PATTERNS=()
load_exclude_patterns() {
  [[ -f "$EXCLUDE_FILE" ]] || return 0
  command -v python3 >/dev/null 2>&1 || { echo "python3 (with PyYAML) is required to read $EXCLUDE_FILE but is not installed." >&2; exit 1; }

  local excludes_list
  excludes_list="$(yaml_read_list "$EXCLUDE_FILE")" || exit 1

  local raw trimmed src_abs rel
  src_abs="${SRC_DIR%/}"
  while IFS= read -r raw; do
    trimmed="${raw#"${raw%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ -z "$trimmed" ]] && continue
    if [[ "$trimmed" == !* ]]; then
      warn "Ignoring unsupported negation pattern in $EXCLUDE_FILE: $trimmed"
      continue
    fi

    # Patterns come from a YAML string, not parsed by the shell, so a
    # leading '~' is never auto-expanded like it would be on a command
    # line — do it ourselves for the common "~" / "~/rest" forms (current
    # user's home only; "~otheruser/..." isn't supported, kept out of scope).
    # shellcheck disable=SC2088 # intentional: matching the literal "~/" prefix, not expanding it
    if [[ "$trimmed" == "~" ]]; then
      trimmed="$HOME"
    elif [[ "$trimmed" == "~/"* ]]; then
      trimmed="$HOME/${trimmed#\~/}"
    fi

    # A trailing '/' is a common gitignore-style "this is a directory"
    # convention, but find's %P output never has one — "Rsync-Test/" would
    # otherwise never match the bare directory entry "Rsync-Test". Strip a
    # single trailing slash (but not the pattern "/" itself).
    if [[ "$trimmed" == */ && "$trimmed" != "/" ]]; then
      trimmed="${trimmed%/}"
    fi

    if [[ "$trimmed" == "*" || "$trimmed" == "**" ]]; then
      warn "Exclude pattern '$trimmed' matches everything at that level — this will likely exclude the whole tree. Confirm this is intentional."
    fi

    if [[ "$trimmed" == /* ]]; then
      if [[ "$trimmed" == "$src_abs/"* ]]; then
        rel="${trimmed#"$src_abs"/}"
        EXCLUDE_PATTERNS+=("path:$rel")
      elif [[ "$trimmed" == "$src_abs" ]]; then
        warn "Exclude pattern '$trimmed' is SRC_DIR itself — ignoring it (would exclude everything)."
      else
        warn "Exclude pattern '$trimmed' is an absolute path outside SRC_DIR ($SRC_DIR) — it can never match anything here and is being ignored."
      fi
    elif [[ "$trimmed" == */* ]]; then
      EXCLUDE_PATTERNS+=("path:$trimmed")
    else
      EXCLUDE_PATTERNS+=("name:$trimmed")
    fi
  done < <(printf '%s\n' "$excludes_list")
}

# ---------------------------------------------------------------------------
# Cleanup: only scrub working files when the run was fully successful.
# Always removes pure plumbing (progress FIFO, empty fail-marker dir).
#
# "Successful" is decided by fail_count (worker failures, tracked via
# FAIL_MARKERS_DIR) OR ERR_LOG actually having content — not fail_count
# alone. Early failures (SSH connectivity down, missing tools, bad config)
# exit before any worker ever runs, so FAIL_MARKERS_DIR stays empty even
# though stderr was captured into ERR_LOG and the user was just told to go
# read it; gating solely on fail_count deleted that file out from under
# them before they could.
# ---------------------------------------------------------------------------
cleanup() {
  local fail_count
  fail_count="$(find "$FAIL_MARKERS_DIR" -type f 2>/dev/null | wc -l)"

  rm -f "$PROGRESS_EVENTS_FIFO" 2>/dev/null || true
  rm -f "$SRC_LISTING" "$DEST_LISTING" "$ADD_FULL" "$EXTRANEOUS_FULL" 2>/dev/null || true
  rm -f "$LOCAL_SCAN_RESULT" "$DEST_SCAN_EXIT_FILE" 2>/dev/null || true
  ssh -O exit -o ControlPath="$SSH_CTL_PATH" -p "$SSH_PORT" "${DEST_USER}@${DEST_HOST}" 2>/dev/null || true

  if [[ "$fail_count" -eq 0 && ! -s "$ERR_LOG" ]]; then
    rm -f "$ERR_LOG" 2>/dev/null || true
    rm -f "$TMP"/worker_"$RUN_TS"_W* 2>/dev/null || true
    rm -f "$FILES_TXT" "$CHUNK_PREFIX"* 2>/dev/null || true
    rmdir "$FAIL_MARKERS_DIR" 2>/dev/null || true
  else
    warn "Failures occurred. Keeping logs for review:"
    printf '%s\n' "  Error log:   $ERR_LOG" | tee -a "$LOG"
    if [[ "$fail_count" -gt 0 ]]; then
      printf '%s\n' "  Worker logs: $TMP/worker_${RUN_TS}_W*" | tee -a "$LOG"
    fi
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Worker: rsyncs one chunk of the file list, streaming per-file completions
# into the shared progress FIFO (if present) and parsing transfer stats.
# ---------------------------------------------------------------------------
worker() {
  local chunk_file="$1"
  local dest_dir_worker="$2"

  [[ -n "${TMP:-}" ]]        || { echo "TMP is empty in worker" >&2; return 1; }
  [[ -n "${RUN_TS:-}" ]]     || { echo "RUN_TS is empty in worker" >&2; return 1; }
  [[ -n "$dest_dir_worker" ]] || { echo "DEST_DIR is empty in worker" >&2; return 1; }
  [[ -n "${SRC_DIR:-}" ]]    || { echo "SRC_DIR is empty in worker" >&2; return 1; }
  [[ -f "$chunk_file" ]]     || { echo "Missing chunk file in worker: $chunk_file" >&2; return 1; }

  local wtag worker_log
  wtag="W$$"
  worker_log="$TMP/worker_${RUN_TS}_${wtag}_$(basename "$chunk_file" .txt).log"
  : > "$worker_log"

  # NOTE: deletion of files removed from SRC is handled by a dedicated
  # replication-propagation pass after all chunks complete (see main flow
  # below), not by rsync's own --delete here. Each worker only ever sees a
  # fragment of any given directory's contents (its own chunk), so
  # rsync's --delete has no complete view to detect extraneous files
  # against and would silently do nothing (or, worse, act inconsistently
  # depending on where chunk boundaries happen to fall).
  local rsync_opts=(
    -aHAX
    --numeric-ids
    --partial
    --partial-dir=.rsync-partial
    "--out-format=%i|%l|%n"
    --info=stats2
    --progress
  )

  # Exclude patterns as defense-in-depth alongside the find-level pruning
  # done before chunking. Not currently load-bearing: --files-from changes
  # -a's behavior so it does NOT imply -r/--recursive (per rsync's own
  # manual), and rsync_opts never adds -r, so rsync here only ever touches
  # the exact paths listed in --files-from — it can't "rediscover" pruned
  # nested content on its own. This protects against a future edit that
  # adds -r for an unrelated reason and would otherwise silently reintroduce
  # that risk.
  if [[ -n "${EXCLUDE_PATTERNS_JOINED:-}" ]]; then
    local pat
    while IFS= read -r pat; do
      # A leading '/' in rsync's own --exclude syntax means "anchored to
      # the transfer root" (SRC_DIR here) — NOT "absolute filesystem path".
      # So a "path:" entry (already normalized relative to SRC_DIR) needs
      # a leading '/' prepended for rsync's own anchoring; a "name:" entry
      # passes through bare, matching at any depth exactly like find -name.
      case "$pat" in
        path:*) rsync_opts+=(--exclude="/${pat#path:}") ;;
        name:*) rsync_opts+=(--exclude="${pat#name:}") ;;
      esac
    done <<< "$EXCLUDE_PATTERNS_JOINED"
  fi

  local ssh_cmd="ssh -p ${SSH_PORT} -C -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=15 ${SSH_CTL_OPTS:-}"
  local dest_spec="${DEST_USER}@${DEST_HOST}:${dest_dir_worker}/"

  {
    echo "===== Worker start ====="
    echo "Time: $(date)"
    echo "Worker tag: $wtag"
    echo "Chunk file: $chunk_file"
    echo "Source root: $SRC_DIR/"
    echo "Destination: $dest_spec"
    echo "SSH cmd: $ssh_cmd"
    echo "Rsync opts: ${rsync_opts[*]}"
    echo "Chunk list line count: $(wc -l < "$chunk_file" 2>/dev/null || echo 0)"
    echo "===== Rsync begin ====="
  } >> "$worker_log"

  # No per-worker startup jitter: the old UFW rate-limit rule that made
  # bursts of simultaneous new connections risky has been switched to
  # ALLOW, and SSH connection multiplexing (SSH_CTL_OPTS) now means workers
  # share one already-established connection rather than opening N new
  # ones anyway, so there's no longer a burst to stagger.
  local rsync_exit=0
  local max_attempts=4
  local attempt=1
  local backoff_schedule=(10 30 60)

  while (( attempt <= max_attempts )); do
    echo "----- Attempt $attempt/$max_attempts -----" >> "$worker_log"
    set +e
    stdbuf -oL rsync "${rsync_opts[@]}" \
        --files-from="$chunk_file" \
        -e "$ssh_cmd" \
        "${SRC_DIR}/" "$dest_spec" 2>&1 | tr '\r' '\n' |
    {
      # `--progress` makes rsync print, per file: the itemize/name line
      # first (our own "%i|%l|%n" format, which also carries that file's
      # total size up front), then a run of incremental byte/percent
      # updates *for that one file* as it transfers, `\r`-separated so a
      # real terminal overwrites them in place. `tr '\r' '\n'` turns each
      # of those into its own line so `read` sees them as they arrive
      # instead of blocking until rsync eventually emits a real newline
      # (which only happens once the file is done) — this is what makes
      # genuinely live, sub-file, mid-transfer progress possible at all.
      #
      # Two event types go to PROGRESS_EVENTS_FIFO, both tagged with this
      # worker's tag so the single progress-phase reader can attribute
      # them to the right row:
      #   F <wtag> <name> <total_bytes> <action> <type>  — this worker just
      #        started NAME ("NEW" or "UPD"); TYPE is what kind of object
      #        it is (FILE/DIR/LNK/DEV/SPEC/OBJ), from rsync's own itemize
      #        type character — the manifest of what's being synced covers
      #        every object type rsync actually touches, not just files.
      #   P <wtag> <bytes_so_far> <pct>   — progress on whatever object this
      #                                     worker most recently started
      cur_name=""
      while IFS= read -r line; do
        printf '%s\n' "$line" >> "$worker_log"
        if [[ "$line" == *'|'* ]]; then
          IFS='|' read -r itemized bytes name <<<"$line"
          # rsync's itemize type character (position 1 of %i): f=file,
          # d=directory, L=symlink, D=device, S=special. Anything else
          # non-space/non-empty still gets tracked, generically, as "OBJ"
          # rather than silently skipped.
          case "${itemized:1:1}" in
            f) obj_type="FILE" ;;
            d) obj_type="DIR" ;;
            L) obj_type="LNK" ;;
            D) obj_type="DEV" ;;
            S) obj_type="SPEC" ;;
            ""|" ") obj_type="" ;;
            *) obj_type="OBJ" ;;
          esac
          if [[ -n "${itemized:-}" && -n "$obj_type" && -n "${name:-}" ]]; then
            cur_name="$name"
            if [[ -n "${PROGRESS_EVENTS_FIFO:-}" && -p "$PROGRESS_EVENTS_FIFO" ]]; then
              # rsync's itemize code: an entirely new object is "+" all the
              # way through from position 2 on (e.g. ">f+++++++++"); an
              # existing one being updated shows which attributes changed
              # instead (e.g. ">f.st......"). That third character alone
              # reliably tells the two apart, for any object type.
              action="UPD"; [[ "${itemized:2:1}" == "+" ]] && action="NEW"
              printf 'F\t%s\t%s\t%s\t%s\t%s\n' "$wtag" "$cur_name" "${bytes:-0}" "$action" "$obj_type" >> "$PROGRESS_EVENTS_FIFO" 2>/dev/null || true
              # Only regular files stream incremental `\r` progress lines
              # after this; a directory/symlink/etc. is done the instant
              # rsync itemizes it, so report that immediately rather than
              # waiting for percentage lines that will never come.
              if [[ "$obj_type" != "FILE" ]]; then
                printf 'P\t%s\t%s\t100\n' "$wtag" "${bytes:-0}" >> "$PROGRESS_EVENTS_FIFO" 2>/dev/null || true
              fi
            fi
          fi
        elif [[ -n "$cur_name" && "$line" =~ ^[[:space:]]*([0-9][0-9,]*)[[:space:]]+([0-9]+)% ]]; then
          if [[ -n "${PROGRESS_EVENTS_FIFO:-}" && -p "$PROGRESS_EVENTS_FIFO" ]]; then
            printf 'P\t%s\t%s\t%s\n' "$wtag" "${BASH_REMATCH[1]//,/}" "${BASH_REMATCH[2]}" >> "$PROGRESS_EVENTS_FIFO" 2>/dev/null || true
          fi
        fi
      done
    }
    rsync_exit="${PIPESTATUS[0]}"
    set -e

    [[ "$rsync_exit" -eq 0 ]] && break

    if (( attempt < max_attempts )); then
      local backoff="${backoff_schedule[$((attempt - 1))]}"
      echo "Attempt $attempt failed (exit=$rsync_exit). Retrying in ${backoff}s ..." >> "$worker_log"
      echo "RETRY: worker=$wtag chunk=$(basename "$chunk_file") attempt=$attempt exit=$rsync_exit" >> "$LOG"
      sleep "$backoff"
    fi
    attempt=$(( attempt + 1 ))
  done

  echo "__RSYNC_EXIT__:${rsync_exit}" >> "$worker_log"

  local transferred_files transferred_bytes
  transferred_files="$(grep -m1 'Number of regular files transferred:' "$worker_log" | grep -oE '[0-9,]+' | tr -d ',' || true)"
  transferred_bytes="$(grep -m1 'Total transferred file size:' "$worker_log" | grep -oE '[0-9,]+' | tr -d ',' || true)"
  [[ -z "$transferred_files" ]] && transferred_files=0
  [[ -z "$transferred_bytes" ]] && transferred_bytes=0

  if [[ "$rsync_exit" -ne 0 ]]; then
    touch "$FAIL_MARKERS_DIR/fail_${wtag}_$(basename "$chunk_file")"

    {
      echo "===== FAILED worker=$wtag chunk=$(basename "$chunk_file") exit=$rsync_exit ====="
      echo "Time: $(date)"
      echo "Host: ${DEST_HOST} Port: ${SSH_PORT} User: ${DEST_USER}"
      echo "Destination: $dest_spec"
      echo
      tail -n 250 "$worker_log"
      echo
    } >> "$ERR_LOG"

    echo "FAIL: worker=$wtag chunk=$(basename "$chunk_file") exit=$rsync_exit transferred_bytes=$transferred_bytes files_transferred=$transferred_files" >> "$LOG"

    printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$(basename "$chunk_file")" "$rsync_exit" "$(human_size "$transferred_bytes")" "$transferred_files" "NA" "NA" >> "$SUMMARY_TXT"

    return 1
  fi

  local changed already
  if [[ "$transferred_bytes" -gt 0 || "$transferred_files" -gt 0 ]]; then
    changed=1; already=0
  else
    changed=0; already=1
  fi

  echo "OK:   worker=$wtag chunk=$(basename "$chunk_file") exit=$rsync_exit changed=$changed already=$already transferred_bytes=$transferred_bytes files_transferred=$transferred_files" >> "$LOG"

  printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$(basename "$chunk_file")" "$rsync_exit" "$(human_size "$transferred_bytes")" "$transferred_files" "$changed" "$already" >> "$SUMMARY_TXT"

  return 0
}
export -f worker human_size

rm -f "$FILES_TXT" "$CHUNK_PREFIX"* "$LOG" "$ERR_LOG" "$SUMMARY_TXT" 2>/dev/null || true
rm -f "$TMP"/worker_"$RUN_TS"_W* 2>/dev/null || true

: > "$LOG"
: > "$ERR_LOG"
: > "$SUMMARY_TXT"
printf "chunk\texit\tsize\tfiles\tchanged\talready\n" > "$SUMMARY_TXT"

banner "Parallel Rsync Replication"
info "Start:  $(date)"
info "Source: $SRC_DIR"
info "Dest:   ${DEST_USER}@${DEST_HOST}:${DEST_DIR}"
info "SSH:    ${DEST_USER}@${DEST_HOST} port ${SSH_PORT}"

# ---------------------------------------------------------------------------
# Preflight: required tools
# ---------------------------------------------------------------------------
MISSING=()
for bin in rsync ssh find split xargs awk stdbuf grep python3; do
  command -v "$bin" >/dev/null 2>&1 || MISSING+=("$bin")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  fail "Missing required tools: ${MISSING[*]}"
  exit 1
fi
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  fail "python3's PyYAML module is required (pip install pyyaml / apt install python3-yaml) but is not available."
  exit 1
fi
if ! python3 -c 'import tqdm' >/dev/null 2>&1; then
  fail "python3's tqdm module is required (pip install tqdm / apt install python3-tqdm) but is not available."
  exit 1
fi
ok "All required tools present (rsync, ssh, find, split, xargs, awk, stdbuf, grep, python3+PyYAML+tqdm)"

# ---------------------------------------------------------------------------
# Preflight: SSH connectivity + remote destination directory
# ---------------------------------------------------------------------------
info "Checking SSH connectivity to ${DEST_USER}@${DEST_HOST}:${SSH_PORT} ..."
# shellcheck disable=SC2086
if ! ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new $SSH_CTL_OPTS \
      "${DEST_USER}@${DEST_HOST}" "mkdir -p $(printf '%q' "$DEST_DIR")" 2>>"$ERR_LOG"; then
  fail "Could not connect via SSH or create remote destination directory."
  fail "See error log: $ERR_LOG"
  exit 1
fi
ok "SSH connection OK; remote destination directory ready: $DEST_DIR"
ok "SSH connection multiplexing established — subsequent connections will reuse it"

load_exclude_patterns
if [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]]; then
  info "Excluding ${#EXCLUDE_PATTERNS[@]} pattern(s) (from $EXCLUDE_FILE):"
  printf '%s\n' "${EXCLUDE_PATTERNS[@]}" |
    sed -E 's/^name:(.*)/    - \1  (matches at any depth)/; s/^path:(.*)/    - \1  (anchored to sync root)/' |
    head -n "$NAME_LIST_CAP" | tee -a "$LOG"
  if [[ ${#EXCLUDE_PATTERNS[@]} -gt "$NAME_LIST_CAP" ]]; then
    info "    ... and $(( ${#EXCLUDE_PATTERNS[@]} - NAME_LIST_CAP )) more"
  fi
fi

# ---------------------------------------------------------------------------
# Build file lists: regular files, directories (incl. empty), and symlinks,
# so new files AND new/empty directories are always replicated. Captures
# mtime too, so the destination comparison below can tell which files are
# actually new/changed versus already in sync.
#
# The local (SRC_DIR) scan and the remote (DEST_DIR, over SSH) scan are
# fully independent of each other until the diff step below, and the remote
# one is a full SSH round-trip over the tree — so they're run concurrently
# as two background jobs and joined with `wait`, rather than paying that
# round-trip latency serially after the local scan already finished.
# ---------------------------------------------------------------------------
info "Scanning source and destination trees (concurrently) ..."

# Build a find-native prune clause from EXCLUDE_PATTERNS (already normalized
# to "name:VALUE" / "path:VALUE" by load_exclude_patterns) as a bash array
# (no string interpolation, no quoting risk).
LOCAL_PRUNE_ARGS=()
if [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]]; then
  first=1
  for pat in "${EXCLUDE_PATTERNS[@]}"; do
    [[ $first -eq 1 ]] || LOCAL_PRUNE_ARGS+=(-o)
    case "$pat" in
      path:*) LOCAL_PRUNE_ARGS+=(-path "${SRC_DIR%/}/${pat#path:}") ;;
      name:*) LOCAL_PRUNE_ARGS+=(-name "${pat#name:}") ;;
    esac
    first=0
  done
fi

# Same prune logic as the local scan, but built as an argv array and quoted
# in one pass (printf -v ... '%q ') rather than hand-escaped, since this has
# to become a single string argument sent over ssh to the remote shell.
# Every token — including the literal ( ) -prune -o and every user pattern —
# is quoted independently, so a pattern containing spaces/$/backticks/quotes
# can't break out of its own argument or inject shell syntax (this
# generalizes the printf '%q' "$DEST_DIR" quoting already used above).
REMOTE_FIND_ARGV=(find "$DEST_DIR" -mindepth 1)
if [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]]; then
  REMOTE_FIND_ARGV+=("(")
  first=1
  for pat in "${EXCLUDE_PATTERNS[@]}"; do
    [[ $first -eq 1 ]] || REMOTE_FIND_ARGV+=("-o")
    case "$pat" in
      path:*) REMOTE_FIND_ARGV+=(-path "${DEST_DIR%/}/${pat#path:}") ;;
      name:*) REMOTE_FIND_ARGV+=(-name "${pat#name:}") ;;
    esac
    first=0
  done
  REMOTE_FIND_ARGV+=(")" -prune -o)
fi
REMOTE_FIND_ARGV+=("(" -type f -o -type d -o -type l ")" -printf '%y\t%s\t%T@\t%P\n')
printf -v REMOTE_FIND_CMD '%q ' "${REMOTE_FIND_ARGV[@]}"

(
  if [[ ${#LOCAL_PRUNE_ARGS[@]} -gt 0 ]]; then
    find "$SRC_DIR" -mindepth 1 \( "${LOCAL_PRUNE_ARGS[@]}" \) -prune -o \( -type f -o -type d -o -type l \) -printf '%y\t%s\t%T@\t%P\n'
  else
    find "$SRC_DIR" -mindepth 1 -printf '%y\t%s\t%T@\t%P\n'
  fi | awk -F'\t' -v files_txt="$FILES_TXT" -v listing="$SRC_LISTING" '
    {
      type = $1; size = $2; mtime = $3; path = $4
      for (i = 5; i <= NF; i++) path = path "\t" $i
      if (type == "f" || type == "d" || type == "l") {
        print path > files_txt
        print type"\t"size"\t"mtime"\t"path > listing
        if (type == "f") { files++; bytes += size }
        else if (type == "d") dirs++
        else if (type == "l") links++
      }
    }
    END { printf "%d %d %d %d\n", files+0, dirs+0, links+0, bytes+0 }
  ' > "$LOCAL_SCAN_RESULT"
) &
LOCAL_SCAN_PID=$!

(
  # shellcheck disable=SC2086
  if ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=15 \
       -o StrictHostKeyChecking=accept-new $SSH_CTL_OPTS "${DEST_USER}@${DEST_HOST}" \
       "$REMOTE_FIND_CMD" \
       > "$DEST_LISTING" 2>>"$ERR_LOG"; then
    echo 0 > "$DEST_SCAN_EXIT_FILE"
  else
    echo 1 > "$DEST_SCAN_EXIT_FILE"
  fi
) &
DEST_SCAN_PID=$!

wait "$LOCAL_SCAN_PID"
wait "$DEST_SCAN_PID"

read -r TOTAL_FILES TOTAL_DIRS TOTAL_LINKS TOTAL_BYTES < "$LOCAL_SCAN_RESULT"
rm -f "$LOCAL_SCAN_RESULT"
TOTAL_ENTRIES="$(wc -l < "$FILES_TXT")"

info "Entries to sync: $TOTAL_ENTRIES  (files: $TOTAL_FILES, dirs: $TOTAL_DIRS, symlinks: $TOTAL_LINKS)"
info "Total data size: $(human_size "$TOTAL_BYTES")"

# ---------------------------------------------------------------------------
# Diff source vs. destination — now that both scans (run concurrently above)
# have completed — so we know everything that needs to change (what SRC has
# that DEST doesn't yet reflect, AND what DEST has that SRC no longer does)
# before anything starts. This lets the progress bar only appear when
# there's real work, sized to the real amount of work, and lets us name
# exactly what's being added/updated or removed. "Added/updated" is decided
# the same way rsync's own default quick-check does: new to DEST, or
# size/mtime differs.
# ---------------------------------------------------------------------------
ADD_COUNT=0
ADD_BYTES=0
EXTRANEOUS_COUNT=0
REMOVE_BYTES=0
DEST_SCAN_OK=0
[[ "$(cat "$DEST_SCAN_EXIT_FILE" 2>/dev/null)" == "0" ]] && DEST_SCAN_OK=1
rm -f "$DEST_SCAN_EXIT_FILE"

if [[ "$DEST_SCAN_OK" -eq 1 ]]; then
  read -r ADD_COUNT ADD_BYTES EXTRANEOUS_COUNT REMOVE_BYTES < <(
    awk -F'\t' -v addfile="$ADD_FULL" -v remfile="$EXTRANEOUS_FULL" '
      function rejoin(startidx,   p, i) {
        p = $startidx
        for (i = startidx + 1; i <= NF; i++) p = p "\t" $i
        return p
      }
      FNR==NR {
        type=$1; size=$2; mtime=int($3+0.5); path=rejoin(4)
        stype[path]=type; ssize[path]=size; smtime[path]=mtime
        next
      }
      {
        type=$1; size=$2; mtime=int($3+0.5); path=rejoin(4)
        dtype[path]=type; dsize[path]=size; dmtime[path]=mtime
      }
      END {
        for (p in stype) {
          if (stype[p] == "f") {
            if (!(p in dtype) || dtype[p] != "f" || dsize[p] != ssize[p] || dmtime[p] != smtime[p]) {
              print "f\t" ssize[p] "\t" p > addfile
              acount++; abytes += ssize[p]
            }
          } else if (!(p in dtype)) {
            print stype[p] "\t" ssize[p] "\t" p > addfile
            acount++
          }
        }
        for (p in dtype) {
          if (!(p in stype)) {
            print dtype[p] "\t" dsize[p] "\t" p > remfile
            rcount++
            if (dtype[p] == "f") rbytes += dsize[p]
          }
        }
        printf "%d %d %d %d\n", acount+0, abytes+0, rcount+0, rbytes+0
      }
    ' "$SRC_LISTING" "$DEST_LISTING"
  )
else
  # No baseline to diff against — fall back to treating the whole source
  # as needing verification (matches what rsync will actually check),
  # rather than wrongly reporting "nothing to add or remove".
  ADD_COUNT="$TOTAL_ENTRIES"
  ADD_BYTES="$TOTAL_BYTES"
  warn "Could not list destination contents — treating the full source as needing verification (no baseline to compare against)."
fi

# Names of what's changing, capped so a huge change set doesn't flood the
# terminal — still communicated as a real count, never silently truncated.
print_capped_names() {
  local file="$1" count="$2"
  cut -f3 "$file" | head -n "$NAME_LIST_CAP" | sed 's/^/    - /' | tee -a "$LOG"
  if [[ "$count" -gt "$NAME_LIST_CAP" ]]; then
    info "    ... and $(( count - NAME_LIST_CAP )) more"
  fi
}

if [[ "$DEST_SCAN_OK" -eq 1 && "$ADD_COUNT" -gt 0 ]]; then
  info "Adding/updating $ADD_COUNT item(s) to destination:"
  print_capped_names "$ADD_FULL" "$ADD_COUNT"
elif [[ "$ADD_COUNT" -gt 0 ]]; then
  info "Adding/updating up to $ADD_COUNT item(s) to destination (exact names unknown — no destination baseline this run)."
fi
if [[ "$DEST_SCAN_OK" -eq 1 && "$EXTRANEOUS_COUNT" -gt 0 ]]; then
  info "Removing $EXTRANEOUS_COUNT item(s) from destination:"
  print_capped_names "$EXTRANEOUS_FULL" "$EXTRANEOUS_COUNT"
fi

# Dynamic chunk sizing: a fixed chunk size caps real concurrency at
# (total entries / chunk size) chunks, regardless of JOBS — e.g. a fixed
# 5000-line chunk gave only 7 chunks for a 32k-entry tree, so JOBS could
# never usefully exceed 7 no matter how high it adapted. Size chunks so
# there are comfortably more of them than JOBS_MAX can ever run at once,
# floored so small trees don't get needlessly fragmented into tiny chunks
# (each chunk pays its own rsync/connection overhead).
TARGET_CHUNKS=$(( JOBS_MAX * 3 ))
CHUNK_LINES_MIN=200
CHUNK_LINES=$(( (TOTAL_ENTRIES + TARGET_CHUNKS - 1) / TARGET_CHUNKS ))
[[ "$CHUNK_LINES" -lt "$CHUNK_LINES_MIN" ]] && CHUNK_LINES="$CHUNK_LINES_MIN"

CHUNK_GLOB=()
if [[ "$TOTAL_ENTRIES" -gt 0 ]]; then
  split -l "$CHUNK_LINES" -d --additional-suffix=.txt "$FILES_TXT" "$CHUNK_PREFIX"

  shopt -s nullglob
  CHUNK_GLOB=("$CHUNK_PREFIX"*.txt)
  shopt -u nullglob
  if [[ ${#CHUNK_GLOB[@]} -eq 0 ]]; then
    fail "No chunk files were created by split. Check CHUNK_LINES and input files."
    exit 1
  fi
fi
CHUNKS=${#CHUNK_GLOB[@]}

info "Chunks: $CHUNKS (each ~${CHUNK_LINES} lines)"
banner "Replication Propagation: $SRC_DIR  →  ${DEST_USER}@${DEST_HOST}:${DEST_DIR}"
info "Running parallel rsync with JOBS=$JOBS ..."

# ---------------------------------------------------------------------------
# Live per-item progress: one phase for the upload/update transfer below, a
# separate one for removal propagation further down (each labeled and sized
# to its own byte total, rather than one ambiguous bar for both). Every
# file/object gets its own real, colored, 0-100% tqdm bar while it's
# transferring; the instant it finishes, that bar is replaced by a
# permanent, colored, one-line completion record via `tqdm.write()` — so a
# screenshot or terminal copy/paste taken any time after the run (which only
# ever shows current screen contents, not the history of frames that
# scrolled past) still shows every individual file/object that was acted on,
# not just the aggregate.
#
# A handful of live bar *positions* (capped at PROGRESS_MAX_SLOTS) are
# reused across the run — tqdm's `position=` mechanism is only reliable for
# a small, stable set of concurrently-live rows; closing several
# `leave=True` position-based bars over the course of a run (one new
# permanent row per file) turns out to corrupt tqdm's own cursor bookkeeping
# (verified empirically: trailing garbage character runs and, in one case,
# a line printed in the wrong place entirely). `tqdm.write()` is the
# actually-supported way to interleave permanent lines with live bars — it
# temporarily clears the active bars, writes a normal scrolled line above
# them, and redraws them — so the permanent record goes through that
# instead of through a second wave of position-based bars.
#
# This used to run `pv` as an independent background process for the bar,
# with a second reader process drawing a status line underneath it via
# cursor save/restore tricks. In practice two uncoordinated processes both
# writing live-updating escape sequences to the same terminal cannot be made
# reliably race-free that way: the two writes occasionally interleaved badly
# enough that `pv` lost track of its own row and started a fresh line
# instead of overwriting it, producing duplicate/stacked bars. The fix kept
# here is to have exactly one process own the terminal: a single Python
# reader (using tqdm) computes/draws everything itself from the same
# byte-count events workers already emit. There's nothing else writing to
# the terminal to race with. Both phases are fully finished and closed
# before the Summary section prints, further down.
# ---------------------------------------------------------------------------
PROGRESS_EVENTS_FD=""
PROGRESS_READER_PID=""

start_progress_phase() {
  local label="$1" total_bytes="$2" n_slots="${3:-1}"
  [[ "$total_bytes" -gt 0 ]] || return 1
  [[ "$n_slots" -ge 1 ]] || n_slots=1
  [[ "$n_slots" -gt "$PROGRESS_MAX_SLOTS" ]] && n_slots="$PROGRESS_MAX_SLOTS"

  # No live display at all when stderr isn't a terminal (redirected to a
  # file, piped, etc.) — nothing to draw to, and nothing here writes
  # PROGRESS_EVENTS_FIFO in that case (worker's own `-p` check on it will
  # simply be false, so it skips the write, no blocking).
  [[ -t 2 ]] || return 1

  mkfifo "$PROGRESS_EVENTS_FIFO"

  # Renderer is Python + tqdm rather than hand-rolled ANSI: tqdm draws each
  # live bar at its own fixed terminal row via `position=`. The FIFO path is
  # passed as argv (not piped via stdin) because stdin is already the
  # heredoc; the script opens it itself with open(), which blocks until the
  # write end below is opened — same reader-starts-first handshake the old
  # `exec 4< "$PROGRESS_EVENTS_FIFO"` relied on.
  python3 - "$PROGRESS_EVENTS_FIFO" "$label" "$total_bytes" "$n_slots" <<'PYEOF' &
import shutil, sys, time
from tqdm import tqdm

fifo_path, label, total_bytes, n_slots = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])

# tqdm's own format_meter() silently discards the entire custom bar_format
# below (falling back to its plain built-in one) whenever it resolves the
# terminal width to exactly 0 columns — which some environments report
# (certain multiplexers/log wrappers, or a pty with a not-yet-populated
# window size). Passing an explicit, guaranteed-nonzero width sidesteps
# that codepath entirely, so the richer formatting below is never silently
# dropped.
NCOLS = shutil.get_terminal_size(fallback=(120, 24)).columns or 120

# ANSI SGR codes for the permanent completion line, keyed by action type
# (what kind of change this object was).
COLOR = {"NEW": "32", "UPD": "36", "DEL": "31"}

# While a bar is still live (actually transferring), its fill colour
# progresses with how far along it is — vivid red early, amber through the
# middle, vivid green as it nears done — rather than a single static color,
# so a glance at the bar's own color says roughly how far along it is
# without having to read the percentage. Hex (truecolor) rather than one of
# tqdm's 8 basic named colours, since basic ANSI red/green tend to render
# dim/washed-out on many terminal themes.
def pct_colour(pct):
    if pct < 34:
        return "#ff3b30"
    if pct < 67:
        return "#ffcc00"
    return "#34c759"

# Small, bounded pool of live-bar row positions, reused across the run —
# keyed by worker tag (wtag), which is only a routing key for this worker's
# byte-progress (P) events; the bar itself always reflects whichever real
# object that worker is currently syncing — file, directory, symlink, or
# anything else rsync itemizes: reuse the row a wtag already owns, else an
# unused row, else steal the least-recently-updated row (its occupant is
# finished — freeze+log it first).
slot_wtag = [None] * n_slots
slot_bar = [None] * n_slots
slot_name = [None] * n_slots
slot_action = [None] * n_slots
slot_type = [None] * n_slots
slot_counts = [False] * n_slots  # only FILE objects have real transferred bytes
slot_seq = [0] * n_slots
slot_open_at = [0.0] * n_slots
seq = 0
committed_bytes = 0

# A file small/fast enough to transfer within a single throttle tick would
# otherwise go from "doesn't exist" straight to "permanent completion
# line" with no live bar ever actually rendered in between — which is
# exactly what a live bar is for. Holding each slot open for at least this
# long guarantees every file's live, colored bar is on screen long enough
# to actually be seen before it's replaced.
#
# This is a display-side wait in this single reader process, not the
# actual worker/rsync — but the reader is also the only thing draining
# PROGRESS_EVENTS_FIFO, and a named pipe's kernel buffer is finite: if this
# wait fell far enough behind, a worker's own writes to the FIFO would
# eventually block on a full buffer, which *would* stall real transfer
# work. VISIBLE_BUDGET_S bounds the total cosmetic delay this can ever add
# across a whole phase, so a run with hundreds of small files can't turn a
# per-file half-second UX nicety into a cumulative multi-minute stall —
# once the budget is spent, files still get their guaranteed first frame
# (the unthrottled refresh right after each bar opens, below) but no
# longer get held open past it.
MIN_VISIBLE_S = 0.35
VISIBLE_BUDGET_S = 3.0
visible_budget = VISIBLE_BUDGET_S

# Positioned *below* every live per-object row (position=n_slots, the
# largest position number = the bottom-most row) so the aggregate always
# renders as the last line of the block for the whole phase, not just
# after every object has finished and closed — the manifest of individual
# objects sits above it throughout.
#
# leave=False, not True: tqdm's own close() hardcodes `self.display(pos=0)`
# for a `leave=True` bar (verified by reading its source) — it assumes a
# left-behind bar is always the outer/root bar at position 0. With the
# aggregate now at position=n_slots instead, that hardcoded call writes its
# final frame at the wrong row, corrupting the block (verified empirically:
# a duplicated frame and a garbled banner line right after). Sidestep it
# entirely the same way per-object completions already do: close ephemeral
# (leave=False, the safe codepath, which does use the real position) and
# hand-write the permanent final line via tqdm.write() once every other bar
# in the phase is already closed — see the `finally` block below.
overall = tqdm(total=total_bytes, desc=label, position=n_slots, leave=False, ncols=NCOLS,
                unit="B", unit_scale=True, unit_divisor=1024, file=sys.stderr, colour=pct_colour(0),
                bar_format="\x1b[1m{desc} TOTAL\x1b[0m: {percentage:3.0f}%|{bar}| "
                           "{n_fmt}/{total_fmt}  {rate_fmt}  elapsed {elapsed}")

def slot_for(wtag):
    for i in range(n_slots):
        if slot_wtag[i] == wtag:
            return i
    for i in range(n_slots):
        if slot_wtag[i] is None:
            return i
    return min(range(n_slots), key=lambda i: slot_seq[i])

def finish_slot(i):
    global committed_bytes, visible_budget
    bar = slot_bar[i]
    if bar is not None:
        remaining = MIN_VISIBLE_S - (time.monotonic() - slot_open_at[i])
        if remaining > 0 and visible_budget > 0:
            wait = min(remaining, visible_budget)
            time.sleep(wait)
            visible_budget -= wait
        bar.n = bar.total
        bar.colour = pct_colour(100)
        bar.refresh()
        fd = bar.format_dict  # snapshot elapsed/rate before close() tears the bar down
        bar.close()  # leave=False: clears this row cleanly, no residue
        sgr = COLOR.get(slot_action[i], "36")
        size_str = tqdm.format_sizeof(bar.total, suffix="B", divisor=1024)
        elapsed_str = tqdm.format_interval(fd["elapsed"])
        rate = fd["rate"] or (bar.total / fd["elapsed"] if fd["elapsed"] else 0)
        rate_str = tqdm.format_sizeof(rate, suffix="B/s", divisor=1024)
        tqdm.write(f"\x1b[1;{sgr}m✓ {slot_action[i]:<3}\x1b[0m {slot_type[i]:<4} {slot_name[i]}  "
                   f"100%  {size_str}  in {elapsed_str}  avg {rate_str}", file=sys.stderr)
        # Only real file bytes were ever budgeted into total_bytes (see
        # ADD_BYTES/REMOVE_BYTES upstream, which sum file sizes only) — a
        # directory/symlink/etc.'s own size folded in here would let the
        # aggregate reach 100% before every object is actually finished.
        if slot_counts[i]:
            committed_bytes += bar.total
    slot_wtag[i] = None
    slot_bar[i] = None
    slot_name[i] = None
    slot_action[i] = None
    slot_type[i] = None
    slot_counts[i] = False

def active_bytes():
    return sum(b.n for i, b in enumerate(slot_bar) if b is not None and slot_counts[i])

def refresh_overall():
    overall.n = min(committed_bytes + active_bytes(), total_bytes)
    overall.colour = pct_colour(overall.n * 100 / total_bytes if total_bytes else 100)
    overall.refresh()

last_tick = -1
try:
    with open(fifo_path, "r") as fifo:
        for line in fifo:
            parts = line.rstrip("\n").split("\t")
            ev_type = parts[0]
            if ev_type == "F" and len(parts) >= 6:
                _, wtag, name, size, action, obj_type = parts[:6]
                i = slot_for(wtag)
                finish_slot(i)  # previous occupant of this row (if any) is done
                slot_wtag[i] = wtag
                slot_name[i] = name
                slot_action[i] = action
                slot_type[i] = obj_type
                slot_counts[i] = (obj_type == "FILE")
                # A zero-byte object (an empty directory, say) would make
                # `total` falsy, and tqdm's percentage math is skipped
                # entirely when total is falsy — clamp to a nominal 1 so
                # the bar/percentage always render normally, 0% -> 100%.
                slot_bar[i] = tqdm(total=max(int(size or 0), 1), desc=f"\x1b[1m{action:<3}\x1b[0m {obj_type:<4} {name}",
                                    position=i, leave=False, ncols=NCOLS, unit="B", unit_scale=True,
                                    unit_divisor=1024, file=sys.stderr, colour=pct_colour(0),
                                    bar_format="  {desc:.75}  {percentage:3.0f}%|{bar}| "
                                               "{n_fmt}/{total_fmt}  {rate_fmt}  "
                                               "elapsed {elapsed} ETA {remaining}")
                slot_open_at[i] = time.monotonic()
                slot_bar[i].refresh()  # unthrottled: guarantees a visible first frame even for a file that finishes within one tick
                seq += 1; slot_seq[i] = seq
            elif ev_type == "P" and len(parts) >= 3:
                _, wtag, bytes_so_far = parts[:3]
                i = slot_for(wtag)
                if slot_bar[i] is None:
                    continue
                slot_bar[i].n = min(int(bytes_so_far or 0), slot_bar[i].total)
                seq += 1; slot_seq[i] = seq
            else:
                continue

            # Throttled to ~4/sec so bars still look genuinely live without
            # redrawing on every single event — a busy run can emit many
            # progress events per second.
            tick = int(time.monotonic() * 4)
            if tick == last_tick:
                continue
            last_tick = tick
            for b in slot_bar:
                if b is not None:
                    b.colour = pct_colour(b.n * 100 / b.total if b.total else 100)
                    b.refresh()
            refresh_overall()
finally:
    for i in range(n_slots):
        finish_slot(i)
    overall.n = total_bytes
    overall.colour = pct_colour(100)
    overall.refresh()
    fd = overall.format_dict
    # By this point overall is the only bar left registered, so its own
    # close() (leave=False) clears via display(msg='', pos=pos) directly
    # rather than going through clear() — and unlike clear(), that path
    # doesn't write a trailing \r to reset the cursor column afterward, so
    # the next write would otherwise land indented by however wide the
    # last live frame was. The leading \r below is that same reset.
    overall.close()
    size_str = tqdm.format_sizeof(total_bytes, suffix="B", divisor=1024)
    elapsed_str = tqdm.format_interval(fd["elapsed"])
    rate = fd["rate"] or (total_bytes / fd["elapsed"] if fd["elapsed"] else 0)
    rate_str = tqdm.format_sizeof(rate, suffix="B/s", divisor=1024)
    tqdm.write(f"\r\x1b[1m{label} TOTAL\x1b[0m: 100%  {size_str}  {rate_str}  elapsed {elapsed_str}",
               file=sys.stderr)
PYEOF
  PROGRESS_READER_PID=$!

  exec {PROGRESS_EVENTS_FD}>"$PROGRESS_EVENTS_FIFO"
  return 0
}

close_progress_phase() {
  if [[ -n "$PROGRESS_EVENTS_FD" ]]; then
    exec {PROGRESS_EVENTS_FD}>&-
    PROGRESS_EVENTS_FD=""
  fi
  if [[ -n "$PROGRESS_READER_PID" ]]; then
    wait "$PROGRESS_READER_PID" 2>/dev/null || true
    PROGRESS_READER_PID=""
  fi
  # PROGRESS_EVENTS_FIFO is a fixed path (set once, near the top of the
  # script) reused across both phases — only the FIFO file itself is
  # removed here, not the path variable, so start_progress_phase can
  # mkfifo the same path again for the next phase.
  rm -f "$PROGRESS_EVENTS_FIFO" 2>/dev/null || true
}

if [[ "$ADD_COUNT" -eq 0 && "$EXTRANEOUS_COUNT" -eq 0 ]]; then
  ok "Nothing to add or remove — destination already matches source, no progress bar needed."
fi

# Arrays can't cross the export/xargs-bash-c boundary, so serialize once as
# a newline-joined scalar; each element is guaranteed single-line already
# (it came from `read -r` over the exclude file), so this round-trips safely.
EXCLUDE_PATTERNS_JOINED="$(printf '%s\n' "${EXCLUDE_PATTERNS[@]-}")"

export SRC_DIR DEST_USER DEST_HOST SSH_PORT TMP RUN_TS LOG ERR_LOG FAIL_MARKERS_DIR SUMMARY_TXT DEST_DIR PROGRESS_EVENTS_FIFO SSH_CTL_OPTS EXCLUDE_PATTERNS_JOINED

# "Uploading" phase: aggregate bar + a live bar per file actually in flight
# (each leaving a permanent completion line behind it), sized to what the
# destination diff found needs adding/updating.
UPLOAD_SLOTS="$JOBS"
[[ "$CHUNKS" -lt "$UPLOAD_SLOTS" ]] && UPLOAD_SLOTS="$CHUNKS"
# CHUNKS is sized off the *whole* tree (so every rsync quick-check runs),
# not off how many items the diff actually found changed — most chunks on
# an incremental run transfer nothing at all. Capping slots at ADD_COUNT
# too avoids reserving rows that will just sit idle the entire run.
[[ "$ADD_COUNT" -gt 0 && "$ADD_COUNT" -lt "$UPLOAD_SLOTS" ]] && UPLOAD_SLOTS="$ADD_COUNT"
start_progress_phase "Syncing" "$ADD_BYTES" "$UPLOAD_SLOTS" || true

# shellcheck disable=SC2016 # single-quoted on purpose: $1/$DEST_DIR must expand in the xargs-spawned subshell, not here
if [[ "$CHUNKS" -gt 0 ]]; then
  printf "%s\0" "${CHUNK_GLOB[@]}" |
  xargs -0 -n1 -P "$JOBS" bash -c 'worker "$1" "$DEST_DIR"' _ || true
fi

# Upload phase's bar/current-item line is done once the workers are — fully
# finished and closed here, well before anything else prints, rather than
# staying live across later output (that's what used to make the pv line
# and the Summary text interleave on screen).
close_progress_phase

echo
FAILS="$(find "$FAIL_MARKERS_DIR" -type f 2>/dev/null | wc -l)"
OKS=$(( CHUNKS - FAILS ))
RETRIES="$(grep -c '^RETRY:' "$LOG" 2>/dev/null || true)"
RETRIES="${RETRIES:-0}"

# ---------------------------------------------------------------------------
# Adaptive JOBS: decide what concurrency the *next* run should start from,
# based on how this run actually went. Hard failures back off hard (halve);
# a clean run that still needed retries backs off gently (-1); a fully
# clean run with no retries nudges up (+1). Bounded to [JOBS_MIN, JOBS_MAX].
# ---------------------------------------------------------------------------
if [[ "$FAILS" -gt 0 ]]; then
  NEW_JOBS=$(( JOBS / 2 ))
  JOBS_REASON="chunk failures occurred"
elif [[ "$RETRIES" -gt 0 ]]; then
  NEW_JOBS=$(( JOBS - 1 ))
  JOBS_REASON="transient retries were needed"
else
  NEW_JOBS=$(( JOBS + 1 ))
  JOBS_REASON="clean run, no retries"
fi
[[ "$NEW_JOBS" -lt "$JOBS_MIN" ]] && NEW_JOBS="$JOBS_MIN"
[[ "$NEW_JOBS" -gt "$JOBS_MAX" ]] && NEW_JOBS="$JOBS_MAX"
echo "$NEW_JOBS" > "$JOBS_STATE_FILE"

# Re-pad every field to its real column width so the header lines up with
# the data (plain single-tab TSV is otherwise misaligned since chunk names
# are much wider than their header labels). Stays valid tab-delimited data.
if command -v column >/dev/null 2>&1; then
  column -t -s $'\t' -o $'\t' "$SUMMARY_TXT" > "${SUMMARY_TXT}.aligned" \
    && mv "${SUMMARY_TXT}.aligned" "$SUMMARY_TXT"
fi

if [[ "$FAILS" -gt 0 ]]; then
  # A partial/failed transfer never triggers deletions — the extraneous-item
  # removal below only ever runs after a fully successful transfer.
  DELETE_EXIT=""
else
  # -------------------------------------------------------------------------
  # Replication propagation, part two: remove from DEST anything no longer
  # present in SRC. Uses the extraneous list computed up front (before the
  # transfer even started — see the destination scan above), so it always
  # has complete context regardless of how the transfer was chunked. Its own
  # "Removing" bar + current-item line (separate from the "Uploading" one
  # above) is fully closed before the Summary section below prints.
  # -------------------------------------------------------------------------
  start_progress_phase "Syncing" "$REMOVE_BYTES" || true

  if [[ "$DEST_SCAN_OK" -eq 1 && "$EXTRANEOUS_COUNT" -gt 0 ]]; then
    set +e
    # shellcheck disable=SC2086
    # shellcheck disable=SC2094 # false positive: EXTRANEOUS_FULL is fully written earlier and only ever read here (twice, not written)
    cut -f3 "$EXTRANEOUS_FULL" | tr '\n' '\0' |
      ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=15 \
        -o StrictHostKeyChecking=accept-new $SSH_CTL_OPTS "${DEST_USER}@${DEST_HOST}" \
        "cd $(printf '%q' "$DEST_DIR") && fail=0; while IFS= read -r -d '' item; do rm -rf -- \"\$item\" || fail=1; echo; done; exit \$fail" \
        2>>"$ERR_LOG" |
      {
        # One completion line arrives per removed item, in the same order
        # they were sent — pair it with that item's real name/size (read in
        # lockstep from fd 3) and feed it to the Removing phase's single
        # row as an F+P pair (removal has no partial/sub-item progress of
        # its own — `rm` is atomic — so each item is reported as starting
        # and finishing in the same breath, same F/P protocol as uploads).
        while IFS= read -r _; do
          IFS=$'\t' read -r -u 3 item_type item_size item_name || break
          # find's -printf '%y' (used to build EXTRANEOUS_FULL) only ever
          # emits f/d/l for this script's find invocation.
          obj_type=""
          case "$item_type" in
            f) obj_type="FILE" ;;
            d) obj_type="DIR" ;;
            l) obj_type="LNK" ;;
          esac
          if [[ -n "$obj_type" && -n "${PROGRESS_EVENTS_FIFO:-}" && -p "$PROGRESS_EVENTS_FIFO" ]]; then
            printf 'F\tR\t%s\t%s\tDEL\t%s\n' "$item_name" "$item_size" "$obj_type" >> "$PROGRESS_EVENTS_FIFO" 2>/dev/null || true
            printf 'P\tR\t%s\t100\n' "$item_size" >> "$PROGRESS_EVENTS_FIFO" 2>/dev/null || true
          fi
        done
      } 3< "$EXTRANEOUS_FULL"
    DELETE_EXIT="${PIPESTATUS[2]}"
    set -e
  else
    DELETE_EXIT=0
  fi

  close_progress_phase
fi
# SRC_LISTING/DEST_LISTING/ADD_FULL/EXTRANEOUS_FULL are cleaned up
# unconditionally by cleanup() (the EXIT trap), not here — that way they're
# removed on every exit path, including early failures, not just this one.

# ---------------------------------------------------------------------------
# Unified summary: printed only after both progress phases (Uploading,
# Removing) are fully closed, so nothing here interleaves with a still-live
# pv line — this was previously split across a mid-run "Summary" banner and
# a separate block after deletion, with the pv bar still writing to the
# terminal in between.
# ---------------------------------------------------------------------------
banner "Summary"
info "Completed: $(date)"
info "Chunks:    $CHUNKS"
if [[ "$FAILS" -gt 0 ]]; then
  fail "Failures:  $FAILS"
else
  ok "Failures:  $FAILS"
fi
ok "Successes: $OKS"
info "Retries:   $RETRIES"
if [[ "$NEW_JOBS" -ne "$JOBS" ]]; then
  info "JOBS: $JOBS → $NEW_JOBS for next run ($JOBS_REASON)"
else
  info "JOBS: staying at $JOBS for next run ($JOBS_REASON, already at limit)"
fi

if [[ "$FAILS" -gt 0 ]]; then
  fail "One or more chunks failed to replicate. Review the error log below."
  printf '%s\n' "Error log: $ERR_LOG"
  exit 2
fi

if [[ "$DEST_SCAN_OK" -eq 1 && "$EXTRANEOUS_COUNT" -gt 0 ]]; then
  if [[ "$DELETE_EXIT" -eq 0 ]]; then
    ok "Replication propagation complete: $EXTRANEOUS_COUNT item(s) removed."
  else
    fail "Replication propagation failed while removing files — see error log: $ERR_LOG"
  fi
elif [[ "$DEST_SCAN_OK" -eq 1 ]]; then
  ok "Nothing to remove — destination matches source."
fi

TOTAL_CHANGED_BYTES="$(awk '/changed=1/ {for (i=1;i<=NF;i++) if ($i ~ /^transferred_bytes=/){split($i,a,"="); sum+=a[2]}} END{print sum+0}' "$LOG")"
TOTAL_CHANGED_FILES="$(awk '/changed=1/ {for (i=1;i<=NF;i++) if ($i ~ /^files_transferred=/){split($i,a,"="); sum+=a[2]}} END{print sum+0}' "$LOG")"

echo
if [[ "$TOTAL_CHANGED_FILES" -gt 0 || "$EXTRANEOUS_COUNT" -gt 0 ]]; then
  ok "Replication propagation completed successfully — changes applied."
else
  ok "Replication propagation completed successfully — destination already up to date."
fi
info "Files added/updated: $TOTAL_CHANGED_FILES  ($(human_size "$TOTAL_CHANGED_BYTES"))"
info "Items removed:       $EXTRANEOUS_COUNT  ($(human_size "$REMOVE_BYTES"))"

echo
info "Main log: $LOG"
info "Summary:  $SUMMARY_TXT"

if [[ "$DELETE_EXIT" -ne 0 ]]; then
  fail "Deletion propagation failed — see error log: $ERR_LOG"
  exit 3
fi
