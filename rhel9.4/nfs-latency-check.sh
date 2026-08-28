#!/usr/bin/env bash
#
# Measure NFS latency against local disk for the paths the application actually
# reads. Read-only apart from a few probe files it removes afterwards.
#
# Usage: bash nfs-latency-check.sh [APP_ROOT]
#
# What matters here is LATENCY, not throughput. Blade stats a template's mtime on
# every render to decide whether its compiled form is stale, so a theme view on
# NFS costs one network round trip per view per request. Ten partials at 2 ms is
# 20 ms of pure waiting before any HTML is produced — invisible on a dashboard
# whose views are local, obvious on a themed page.

set -uo pipefail

APP_ROOT="${1:-/var/www/govexy}"
LOCAL_DIR="/var/tmp/nfsbench.$$"
ITER=200

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }

[[ -d "$APP_ROOT" ]] || { echo "no such directory: $APP_ROOT" >&2; exit 1; }
mkdir -p "$LOCAL_DIR"
trap 'rm -rf "$LOCAL_DIR"' EXIT

THEMES="$APP_ROOT/resources/themes"
MEDIA="$APP_ROOT/storage/app/public"

# ─────────────────────────────────────────────────────────────────────────────
log "1. Mount configuration"
# ─────────────────────────────────────────────────────────────────────────────

findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS "$THEMES" 2>/dev/null || warn "themes not mounted"
printf '\n'

OPTS=$(findmnt -no OPTIONS "$THEMES" 2>/dev/null || echo "")

# Attribute caching is the single biggest lever for this workload. Without it
# every stat() is a wire round trip; with the defaults (acregmin=3) a repeated
# stat is answered from the client cache for a few seconds.
if [[ "$OPTS" == *noac* ]]; then
  warn "MOUNTED WITH noac — attribute caching is OFF."
  warn "Every stat() is a network round trip. This alone can explain the symptom."
elif [[ "$OPTS" == *actimeo=0* ]]; then
  warn "MOUNTED WITH actimeo=0 — same effect as noac."
else
  ok "attribute caching not disabled (defaults: acregmin=3s, acregmax=60s)"
fi

case "$OPTS" in
  *vers=4.2*) ok "NFS 4.2" ;;
  *vers=4.1*) ok "NFS 4.1" ;;
  *vers=4.0*) warn "NFS 4.0 — 4.1+ adds sessions and better parallelism; worth asking for" ;;
  *vers=3*)   warn "NFS 3 — locking is fragile across nodes and latency is usually worse" ;;
esac

[[ "$OPTS" == *noatime* ]] || warn "no noatime — every read may also write an access time"

# ─────────────────────────────────────────────────────────────────────────────
log "2. stat() latency — the metric that matters for Blade"
# ─────────────────────────────────────────────────────────────────────────────

# Returns microseconds per stat on stdout. Nothing else is printed here, so the
# caller can capture the number; the table row is printed by the caller.
bench_stat() {
  [ -e "$1" ] || { printf '0'; return; }
  local t0 t1
  t0=$(date +%s%N)
  local i=0
  while [ "$i" -lt "$ITER" ]; do
    stat -c '%Y' "$1" >/dev/null 2>&1
    i=$((i + 1))
  done
  t1=$(date +%s%N)
  printf '%s' "$(( (t1 - t0) / 1000 / ITER ))"
}

row() { printf '  %-28s %8s us/stat\n' "$1" "$2"; }

echo "probe" > "$LOCAL_DIR/probe.txt"
printf '\n%d iterations each:\n\n' "$ITER"

LOCAL_US=$(bench_stat "$LOCAL_DIR/probe.txt")
row "local disk" "$LOCAL_US"

THEME_FILE=$(find "$THEMES" -name '*.blade.php' -type f 2>/dev/null | head -1)
NFS_US=0
if [ -n "$THEME_FILE" ]; then
  NFS_US=$(bench_stat "$THEME_FILE")
  row "NFS (theme blade)" "$NFS_US"
else
  warn "no .blade.php found under $THEMES"
fi

MEDIA_FILE=$(find "$MEDIA" -type f 2>/dev/null | head -1)
if [ -n "$MEDIA_FILE" ]; then
  row "NFS (media)" "$(bench_stat "$MEDIA_FILE")"
fi

if [ "${LOCAL_US:-0}" -gt 0 ] && [ "${NFS_US:-0}" -gt 0 ]; then
  if [ "$NFS_US" -ge "$LOCAL_US" ]; then
    printf '\n  NFS is %sx slower per stat than local disk\n' "$(( NFS_US * 100 / LOCAL_US ))e-2"
  else
    printf '\n  NFS stat is not slower than local here (%s vs %s us)\n' "$NFS_US" "$LOCAL_US"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
log "3. Cold stat() — cache defeated"
# ─────────────────────────────────────────────────────────────────────────────
#
# The loop above mostly measures the client attribute cache. A distinct file per
# iteration is closer to what a real request does when it touches many views it
# has not looked at recently.

if [[ -d "$THEMES" ]]; then
  # A plain loop rather than mapfile: this has to run on whatever bash the host
  # ships, and mapfile is absent from bash 3.
  FILE_LIST="$LOCAL_DIR/filelist"
  find "$THEMES" -type f 2>/dev/null | head -100 > "$FILE_LIST"
  COUNT=$(wc -l < "$FILE_LIST" | tr -d ' ')
  if [ "${COUNT:-0}" -gt 5 ]; then
    t0=$(date +%s%N)
    while IFS= read -r f; do stat -c '%Y' "$f" >/dev/null 2>&1; done < "$FILE_LIST"
    t1=$(date +%s%N)
    printf '  %-28s %8s us/stat  (%s distinct files)\n' \
      "NFS, distinct files" "$(( (t1 - t0) / 1000 / COUNT ))" "$COUNT"
  else
    warn "too few files under $THEMES to sample"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
log "4. Read throughput"
# ─────────────────────────────────────────────────────────────────────────────

bench_read() {
  local dir="$1" label="$2"
  [[ -d "$dir" && -w "$dir" ]] || { warn "not writable, skipping: $label"; return; }
  local f="$dir/.nfsbench.$$"
  local w r
  w=$( { time -p dd if=/dev/zero of="$f" bs=1M count=64 conv=fsync 2>/dev/null; } 2>&1 | awk '/real/{print $2}')
  sync
  r=$( { time -p dd if="$f" of=/dev/null bs=1M 2>/dev/null; } 2>&1 | awk '/real/{print $2}')
  rm -f "$f"
  printf '  %-28s write %ss  read %ss  (64 MB)\n' "$label" "$w" "$r"
}

bench_read "$LOCAL_DIR" "local disk"
bench_read "$MEDIA" "NFS (media)"

# ─────────────────────────────────────────────────────────────────────────────
log "5. NFS client counters"
# ─────────────────────────────────────────────────────────────────────────────

if command -v nfsstat &>/dev/null; then
  # A GETATTR share far above reads is the signature of stat-heavy access —
  # exactly what Blade's staleness check produces.
  nfsstat -c 2>/dev/null | grep -A4 -iE 'client nfsv4|getattr|access|lookup' | head -14
else
  warn "nfsstat not installed:  dnf -y install nfs-utils"
fi

printf '\nMounted-path attribute cache settings:\n'
grep -hE 'acregmin|acregmax|actimeo|noac' /proc/self/mountinfo 2>/dev/null | head -3 || \
  printf '  (defaults in use)\n'

# ─────────────────────────────────────────────────────────────────────────────
log "6. Are compiled views local?"
# ─────────────────────────────────────────────────────────────────────────────

VIEWS="$APP_ROOT/storage/framework/views"
if findmnt -rn "$VIEWS" &>/dev/null; then
  warn "storage/framework/views is ON A MOUNT. Compiled Blade must be node-local;"
  warn "this is the single worst thing to put on shared storage."
else
  ok "storage/framework/views is local ($(find "$VIEWS" -name '*.php' 2>/dev/null | wc -l) compiled)"
fi

printf '\n'
cat <<'DONE'
────────────────────────────────────────────────────────────────────────────
Reading this:

  stat() under ~100 us          NFS latency is not your problem; look at the
                                nginx access log rt= field and at the queries
                                a themed page runs.

  stat() 500 us - 2 ms          Normal for NFS, and enough to be felt. A page
                                touching 20 view files spends 10-40 ms purely
                                waiting on metadata.

  stat() above 5 ms             Something is wrong: noac/actimeo=0, a saturated
                                link, or a loaded NFS server.

Next, prove it end to end rather than inferring:

  tail -f /var/log/nginx/govexy-access.log
  # rt= is total request time, upstream= is time in PHP. Compare a dashboard
  # page against a themed page.

  # Where PHP actually spends its time on one themed request:
  strace -f -c -e trace=stat,statx,newfstatat,open,openat \
    -p $(pgrep -f 'php-fpm: pool www' | head -1)
────────────────────────────────────────────────────────────────────────────
DONE
