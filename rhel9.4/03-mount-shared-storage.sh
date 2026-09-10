#!/usr/bin/env bash
#
# GovExy web node — STAGE 3: shared storage bind mounts
#
# Interactive, with every answer defaulting to govexy-node.conf (NFS_EXPORT_ROOT,
# NFS_SUB_*, NFS_BIND_LOGS, NODE_HOSTNAME, APP_ROOT) — a node with a complete
# conf is re-run by pressing Enter. Without NFS_EXPORT_ROOT it discovers the
# mounted NFS exports and asks. It binds three subdirectories of the export
# onto the application:
#
#     <export>/<media>    ->  <APP_ROOT>/storage/app/public    dashboard uploads
#     <export>/<private>  ->  <APP_ROOT>/storage/app/private   form attachments
#     <export>/<themes>   ->  <APP_ROOT>/resources/themes      uploaded themes
#
# Optionally (asked interactively) it also binds this node's logs onto a
# PER-NODE directory of the same export, so every node's logs are readable
# from one place without two nodes ever appending to one file:
#
#     <export>/<logs>/<node>/laravel  ->  <APP_ROOT>/storage/logs
#     <export>/<logs>/<node>/nginx    ->  /var/log/nginx
#     <export>/<logs>/<node>/php-fpm  ->  /var/log/php-fpm
#
# The nginx and php-fpm masters open their logs as ROOT. Under root_squash
# that write is squashed, the open fails, and the service will not start —
# so the export must map root to the application user (anonuid/anongid), and
# step 7 probes exactly that before declaring success.
#
# Idempotent: safe to re-run. Existing fstab entries are detected, not duplicated.
# After the export MOVES, re-running is the migration: a target that is mounted
# from somewhere other than its source is unmounted and rebound, and its fstab
# line is rewritten. Stop nginx, php-fpm and Horizon first so the unmounts are
# not refused as busy.
#
# Usage:
#   bash 03-mount-shared-storage.sh              interactive
#   bash 03-mount-shared-storage.sh --dry-run    show what it would do, change nothing
#   bash 03-mount-shared-storage.sh --verify     check an existing setup only
#
# Two hazards this script exists to handle:
#
#   1. A bind mount HIDES whatever is under the mount point. resources/themes is
#      tracked in git and ships with themes, so mounting an empty share over it
#      makes them vanish. The script refuses to do that, and offers to seed the
#      share from the local content first.
#
#   2. A bind that fires before its NFS export is up silently binds an empty
#      local directory. It looks mounted and is not. Every fstab entry written
#      here carries x-systemd.requires-mounts-for for that reason.

set -euo pipefail

DRY_RUN=false
VERIFY_ONLY=false
case "${1:-}" in
  --dry-run) DRY_RUN=true ;;
  --verify)  VERIFY_ONLY=true ;;
  "")        ;;
  *) printf 'unknown argument: %s\n' "$1" >&2; exit 1 ;;
esac

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

# Callers pass a single command string (quoting already applied by the caller),
# so eval the joined string rather than the argument array.
run() {
  local cmd="$*"
  if $DRY_RUN; then
    printf '\033[2m[dry-run] %s\033[0m\n' "$cmd"
  else
    eval "$cmd"
  fi
}

# `read` returns non-zero at EOF, and under set -e that would terminate the
# script with no output at all — so a run under nohup or from a pipeline looked
# like a silent crash. This script is interactive by design; say so.
ask() {
  local prompt=$1 default=${2:-} answer
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " answer \
      || die "no terminal to prompt on (non-interactive run). Run it under tmux."
    printf '%s' "${answer:-$default}"
  else
    read -r -p "$prompt: " answer \
      || die "no terminal to prompt on (non-interactive run). Run it under tmux."
    printf '%s' "$answer"
  fi
}

confirm() {
  local answer
  read -r -p "$1 [y/N] " answer \
    || die "no terminal to confirm on (non-interactive run). Run it under tmux."
  [[ "$answer" == [yY] ]]
}

[[ $EUID -eq 0 ]] || die "must run as root"
$DRY_RUN && log "DRY RUN — nothing will be changed"

# ── govexy-node.conf ────────────────────────────────────────────────────────
#
# Read by key, not sourced: a syntax error in the conf must not take this
# script down with it. Every value the script asks for defaults to the conf,
# so a node whose conf is complete is re-run by pressing Enter through it.
#
# dirname, not ${BASH_SOURCE%/*}: invoked as `bash 03-mount-shared-storage.sh`
# BASH_SOURCE has no slash, the %/* expansion is a no-op, and the probe path
# became "03-mount-shared-storage.sh/govexy-node.conf" — the conf was never read.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONF="${SCRIPT_DIR}/govexy-node.conf"

conf_get() {   # conf_get KEY DEFAULT
  local v=""
  [[ -f "$CONF" ]] && v=$(grep -E "^$1=" "$CONF" 2>/dev/null | head -1 \
    | cut -d= -f2- | tr -d '"' | awk '{print $1}') || true
  printf '%s' "${v:-$2}"
}

# ═════════════════════════════════════════════════════════════════════════════
log "1/7  Shared storage root"
# ═════════════════════════════════════════════════════════════════════════════

mapfile -t NFS_MOUNTS < <(findmnt -rn -t nfs,nfs4 -o TARGET 2>/dev/null | sort -u)

printf '\n'
findmnt -t nfs,nfs4 -o TARGET,SOURCE,SIZE,AVAIL 2>/dev/null || \
  df -hT -t nfs -t nfs4 2>/dev/null || true

EXPORT_ROOT=$(conf_get NFS_EXPORT_ROOT "")
EXPORT_ROOT="${EXPORT_ROOT%/}"

if [[ -n "$EXPORT_ROOT" ]]; then
  # The conf names it: no discovery, no prompt. Check it is really there.
  [[ -d "$EXPORT_ROOT" ]] || die "NFS_EXPORT_ROOT=${EXPORT_ROOT} in govexy-node.conf is not a directory.

       Has the storage team mounted the export on this node yet?
           findmnt -t nfs,nfs4"
  if ! findmnt -rn -t nfs,nfs4 -o TARGET | grep -qx "$EXPORT_ROOT"; then
    warn "NFS_EXPORT_ROOT=${EXPORT_ROOT} is not itself an NFS mount point."
    confirm "Continue with it anyway?" || die "aborted"
  fi
  ok "Shared storage root (from govexy-node.conf): $EXPORT_ROOT"
else
  if (( ${#NFS_MOUNTS[@]} == 0 )); then
    die "No NFS mount found.

       The storage team mounts the export; this script only binds parts of it
       into the application. Check with:
           findmnt -t nfs,nfs4
           df -hT -t nfs -t nfs4"
  fi

  if (( ${#NFS_MOUNTS[@]} == 1 )); then
    EXPORT_ROOT="${NFS_MOUNTS[0]}"
    printf '\n'
    confirm "Use ${EXPORT_ROOT} as the GovExy shared storage root?" \
      || EXPORT_ROOT=""
  fi

  if [[ -z "$EXPORT_ROOT" ]]; then
    printf '\nMounted NFS exports:\n'
    idx=1
    for m in "${NFS_MOUNTS[@]}"; do
      printf '  %d) %s\n' "$idx" "$m"
      idx=$((idx + 1))
    done
    choice=$(ask "Which one backs this installation? (number, or full path)")
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#NFS_MOUNTS[@]} )); then
      EXPORT_ROOT="${NFS_MOUNTS[$((choice - 1))]}"
    else
      EXPORT_ROOT="$choice"
    fi
  fi

  [[ -d "$EXPORT_ROOT" ]] || die "not a directory: $EXPORT_ROOT"
  findmnt -rn -t nfs,nfs4 -o TARGET | grep -qx "$EXPORT_ROOT" \
    || warn "$EXPORT_ROOT is not itself an NFS mount point — continuing, but confirm this is intended"

  ok "Shared storage root: $EXPORT_ROOT"
  warn "Record it as NFS_EXPORT_ROOT=\"${EXPORT_ROOT}\" in govexy-node.conf so re-runs need no discovery."
fi

# A soft NFS mount returns I/O errors on server hiccups, which surface as
# truncated uploads. The storage team's line, not ours — but say it.
findmnt -rn -o OPTIONS "$EXPORT_ROOT" 2>/dev/null | tr ',' '\n' | grep -qx soft \
  && warn "${EXPORT_ROOT} is mounted 'soft' — NFS-SHARED-STORAGE.md §4 asks for 'hard'"

# ═════════════════════════════════════════════════════════════════════════════
log "2/7  Application root"
# ═════════════════════════════════════════════════════════════════════════════

DEFAULT_APP_ROOT=$(conf_get APP_ROOT /var/www/govexy)

APP_ROOT=$(ask "Application root" "$DEFAULT_APP_ROOT")
APP_ROOT="${APP_ROOT%/}"

[[ -d "$APP_ROOT" ]] || die "not a directory: $APP_ROOT"
[[ -d "$APP_ROOT/public" ]] || warn "$APP_ROOT/public does not exist — is the code deployed?"

APP_USER=$(stat -c '%U' "$APP_ROOT")
APP_GROUP=$(stat -c '%G' "$APP_ROOT")
ok "Application root: $APP_ROOT (owned by ${APP_USER}:${APP_GROUP})"

# ═════════════════════════════════════════════════════════════════════════════
log "3/7  Map share subdirectories to application paths"
# ═════════════════════════════════════════════════════════════════════════════

printf '\nContents of %s:\n' "$EXPORT_ROOT"
ls -1 "$EXPORT_ROOT" 2>/dev/null | sed 's/^/  /' || true
printf '\n'

SUB_MEDIA=$(ask   "Subdirectory for dashboard media"    "$(conf_get NFS_SUB_MEDIA   media)")
SUB_PRIVATE=$(ask "Subdirectory for form attachments"   "$(conf_get NFS_SUB_PRIVATE private)")
SUB_THEMES=$(ask  "Subdirectory for uploaded themes"    "$(conf_get NFS_SUB_THEMES  themes)")

# source|target|label|writer|seed
#
#   writer  app   the application user writes here (probe as that user)
#           root  a root-owned master process opens files here (nginx,
#                 php-fpm) — probe as root too, because root_squash turns
#                 that into a failed open and a service that will not start
#   seed    yes   local content under the target is offered for copying
#           no    logs: the local history stays on disk under the mount and
#                 is not copied — it is not worth a partial-copy failure
MAPPINGS=(
  "${EXPORT_ROOT}/${SUB_MEDIA}|${APP_ROOT}/storage/app/public|dashboard media|app|yes"
  "${EXPORT_ROOT}/${SUB_PRIVATE}|${APP_ROOT}/storage/app/private|form attachments|app|yes"
  "${EXPORT_ROOT}/${SUB_THEMES}|${APP_ROOT}/resources/themes|uploaded themes|app|yes"
)

# ── Per-node logs (optional) ────────────────────────────────────────────────
#
# One directory PER NODE. Two nodes appending to one file over NFS interleave
# and corrupt entries (NFS-SHARED-STORAGE.md §2), so the share is a central
# place to READ every node's logs, never a single file two nodes write.
#
# The node name defaults to NODE_HOSTNAME in govexy-node.conf, else the short
# hostname. It must differ between the two nodes — a copied conf with the same
# NODE_HOSTNAME on both would put both nodes into one directory, which is the
# exact failure the per-node layout exists to prevent. Step 4 checks for that.
NODE_NAME=$(conf_get NODE_HOSTNAME "")
NODE_NAME="${NODE_NAME%%.*}"
NODE_NAME="${NODE_NAME:-$(hostname -s)}"

LOG_TARGETS=("${APP_ROOT}/storage/logs" /var/log/nginx /var/log/php-fpm)
BIND_LOGS=false
CONF_BIND_LOGS=$(conf_get NFS_BIND_LOGS "")
if $VERIFY_ONLY; then
  # No prompt in verify mode: include the log binds if any of them is mounted.
  for t in "${LOG_TARGETS[@]}"; do
    findmnt -rn "$t" &>/dev/null && BIND_LOGS=true
  done
elif [[ "$CONF_BIND_LOGS" == "yes" ]]; then
  BIND_LOGS=true
  ok "per-node log binds: on (NFS_BIND_LOGS=yes in govexy-node.conf)"
elif [[ "$CONF_BIND_LOGS" == "no" ]]; then
  ok "per-node log binds: off (NFS_BIND_LOGS=no in govexy-node.conf)"
else
  printf '\n'
  if confirm "Also bind this node's logs (Laravel, nginx, php-fpm) to a per-node directory on the share?"; then
    BIND_LOGS=true
  fi
fi

SUB_LOGS=$(conf_get NFS_SUB_LOGS logs)
if $BIND_LOGS; then
  if ! $VERIFY_ONLY; then
    SUB_LOGS=$(ask  "Subdirectory for per-node logs"        "$SUB_LOGS")
    NODE_NAME=$(ask "Name of THIS node (its log directory)" "$NODE_NAME")
  fi
  [[ "$NODE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "node name must be a plain directory name: '$NODE_NAME'"
  LOG_ROOT="${EXPORT_ROOT}/${SUB_LOGS}/${NODE_NAME}"
  MAPPINGS+=(
    "${LOG_ROOT}/laravel|${APP_ROOT}/storage/logs|laravel logs, this node|app|no"
    "${LOG_ROOT}/nginx|/var/log/nginx|nginx logs, this node|root|no"
    "${LOG_ROOT}/php-fpm|/var/log/php-fpm|php-fpm logs, this node|root|no"
  )
fi

printf '\n'
for m in "${MAPPINGS[@]}"; do
  IFS='|' read -r src tgt label writer seed <<< "$m"
  printf '  %-40s ->  %s   (%s)\n' "$src" "$tgt" "$label"
done
printf '\n'

if $VERIFY_ONLY; then
  log "VERIFY ONLY"
  rc=0
  for m in "${MAPPINGS[@]}"; do
    IFS='|' read -r src tgt label writer seed <<< "$m"
    if findmnt -rn "$tgt" &>/dev/null; then
      ok "$tgt is mounted"
    else
      warn "$tgt is NOT mounted"
      rc=1
    fi
  done
  exit $rc
fi

confirm "Proceed with this mapping?" || die "aborted"

# ═════════════════════════════════════════════════════════════════════════════
log "4/7  Pre-flight — protect content that a bind mount would hide"
# ═════════════════════════════════════════════════════════════════════════════
#
# A bind mount does not merge directories, it masks them. Anything living under
# a target becomes invisible the moment the mount lands. For storage/app/* that
# is usually only Laravel's .gitignore stub; for resources/themes it is real,
# tracked content.

# Declared BEFORE the loop that sets it. It was initialised after, in the fstab
# section, so a partial seed set it and the next statement immediately reset it
# to 0 — the warning at the end could never fire.
SEED_INCOMPLETE=0

# The per-node log directory must be THIS node's. If the other node already
# writes into it, its files carry that node's hostname in nothing but their
# content — so the only cheap signal is a directory that exists, is not yet
# mounted here, and is non-empty. Ask, do not guess.
if $BIND_LOGS && [[ -d "$LOG_ROOT" ]] && ! findmnt -rn "${APP_ROOT}/storage/logs" &>/dev/null; then
  if (( $(find "$LOG_ROOT" -mindepth 2 2>/dev/null | wc -l) > 0 )); then
    printf '\n'
    warn "${LOG_ROOT} already holds logs, and nothing on this node is mounted from it."
    warn "If that is the OTHER node's directory, two nodes would write the same files."
    printf '\nSibling directories under %s:\n' "${EXPORT_ROOT}/${SUB_LOGS}"
    ls -1 "${EXPORT_ROOT}/${SUB_LOGS}" 2>/dev/null | sed 's/^/  /'
    confirm "Is '${NODE_NAME}' really THIS node's name?" || die "aborted — re-run and give this node its own name"
  fi
fi

# Creating directories ON the share: as the app user first. Under root_squash
# root's mkdir is squashed and fails, while the app user owns the export root
# (NFS-SHARED-STORAGE.md §6). Fall back to root for exports that allow it.
# A directory that does not exist yet counts as empty. Under --dry-run nothing
# is created, so `find <missing> | wc -l` failed, pipefail carried the failure
# into the assignment, and errexit ended the dry run silently after the first
# mapping — on exactly the fresh node a dry run is for.
count_entries() {
  [[ -d "$1" ]] || { printf '0'; return 0; }
  find "$1" -mindepth 1 2>/dev/null | wc -l | tr -d ' '
}

mkdir_on_share() {
  local dir=$1
  if $DRY_RUN; then
    run "sudo -u '$APP_USER' install -d '$dir' || install -d -o '$APP_USER' -g '$APP_GROUP' '$dir'"
  else
    sudo -u "$APP_USER" install -d "$dir" 2>/dev/null \
      || install -d -o "$APP_USER" -g "$APP_GROUP" "$dir" \
      || die "cannot create ${dir} — neither ${APP_USER} nor root may write there (export permissions / squash)"
  fi
}

# Does what is mounted at TGT actually reflect SRC? Write a probe on the
# share as the app user and look for it through the mount.
#   0  same content — the bind is the one we want
#   1  different — a bind from a previous export, or a manual mount
#   2  cannot tell — the app user cannot write to SRC
reflects() {
  local src=$1 tgt=$2 probe=".reflectprobe.$$" rc=2
  if sudo -u "$APP_USER" touch "${src}/${probe}" 2>/dev/null; then
    [[ -e "${tgt}/${probe}" ]] && rc=0 || rc=1
    sudo -u "$APP_USER" rm -f "${src}/${probe}"
  fi
  return $rc
}

STALE_REMOUNTED=0
UNWRITABLE=()

for m in "${MAPPINGS[@]}"; do
  IFS='|' read -r src tgt label writer seed <<< "$m"

  # Already mounted is not the same as mounted from the RIGHT place. After the
  # export moves, every target is still "mounted" — from the old export. Re-
  # running used to skip them here and then report MISMATCH at the end, having
  # changed nothing. Now a stale bind is unmounted and rebuilt below.
  if findmnt -rn "$tgt" &>/dev/null; then
    rc=1
    if [[ -d "$src" ]]; then
      rc=0; reflects "$src" "$tgt" || rc=$?
    fi
    if (( rc == 0 )); then
      ok "already mounted from ${src}: $tgt"
      continue
    elif (( rc == 2 )); then
      warn "$tgt is mounted, but ${APP_USER} cannot write to ${src} to check it is the same — leaving it"
      continue
    fi
    printf '\n'
    warn "$tgt is mounted, but NOT from ${src}."
    warn "That is a bind from a previous export (or a manual mount). It will be replaced."
    findmnt -o TARGET,SOURCE,FSTYPE "$tgt" 2>/dev/null | sed 's/^/    /' || true
    confirm "Unmount ${tgt} and rebind it from ${src}?" \
      || die "aborted — ${tgt} still points at the old location"
    run "umount '$tgt'" \
      || die "umount ${tgt} failed — busy? Stop nginx, php-fpm and govexy-horizon, then re-run."
    STALE_REMOUNTED=1
  fi

  if [[ ! -d "$src" ]]; then
    if confirm "Source ${src} does not exist. Create it?"; then
      mkdir_on_share "$src"
    else
      die "cannot bind a source that does not exist: $src"
    fi
  fi

  # The app user must be able to WRITE to the source before anything else
  # happens. On a first run this mounted an unwritable, empty directory the
  # storage team had created as root over 53 local themes, then reported the
  # write failure at the end — with the site already serving without themes.
  # Nothing is hidden and nothing is written to fstab until every source
  # passes this.
  wprobe=".writeprobe.$$"
  if [[ ! -d "$src" ]]; then
    # Only reachable under --dry-run: the create above was printed, not done.
    ok "(dry-run) ${src} would be created by ${APP_USER}; write check skipped"
  elif sudo -u "$APP_USER" touch "${src}/${wprobe}" 2>/dev/null; then
    sudo -u "$APP_USER" rm -f "${src}/${wprobe}"
  else
    printf '\n'
    warn "${APP_USER} cannot write to ${src}:"
    ls -ldn "$src" 2>/dev/null | sed 's/^/    /' || true
    printf '    %s\n' "$(id "$APP_USER")"
    UNWRITABLE+=("$src")
    continue   # no seeding, no hiding checks — this run stops before fstab anyway
  fi

  # Only CREATE a missing target. /var/log/nginx and /var/log/php-fpm exist
  # root-owned from their packages; re-owning them to the app user would be a
  # change under the mount that nobody asked for.
  [[ -d "$tgt" ]] || run "install -d -o '$APP_USER' -g '$APP_GROUP' '$tgt'"

  local_files=$(count_entries "$tgt")
  share_files=$(count_entries "$src")

  if [[ "$seed" == "no" ]]; then
    # Logs. History is not copied: root-owned files under /var/log would make
    # the app-user copy fail part way, and old local logs are not worth that.
    # They stay on disk under the mount and reappear if it is unmounted.
    if (( local_files > 0 )); then
      warn "${tgt} holds ${local_files} entries of local log history; they stay on disk UNDER the mount, not copied."
      warn "To read them later:  umount ${tgt}   (or look at the share for everything written after today)"
    fi
    continue
  fi

  if (( local_files > 0 && share_files == 0 )); then
    printf '\n'
    warn "${tgt} holds ${local_files} entries; ${src} is empty."
    warn "Mounting now would hide all of them."
    printf '\nWhat is there:\n'
    find "$tgt" -mindepth 1 -maxdepth 1 -printf '  %f\n' 2>/dev/null | head -20

    if confirm "Copy it to ${src} first (seed the share)?"; then
      # As the APP USER, not as root. NFS-SHARED-STORAGE.md calls root_squash
      # "fine and preferred", and under it root's writes on the export are
      # squashed to nobody and fail — including the chown. The app user is the
      # identity that has to be able to write there anyway.
      #
      # --no-preserve=ownership because -a implies -p: the app user cannot
      # chown a file it does not own, so a single root-owned or foreign-owned
      # file under the target aborted the copy PART WAY THROUGH, leaving the
      # share half seeded and the script reporting success up to that point.
      # The files land owned by the app user, which is what they need to be.
      #
      # Reported rather than fatal, for the same reason: a partial seed is a
      # state the operator must see in full, not one to die in the middle of.
      if $DRY_RUN; then
        run "sudo -u '$APP_USER' cp -a --no-preserve=ownership '${tgt}/.' '${src}/'"
        ok "would seed $src"
      elif run "sudo -u '$APP_USER' cp -a --no-preserve=ownership '${tgt}/.' '${src}/'"; then
        ok "seeded $src"
      else
        warn "seeding $src did not complete — some entries were not copied."
        warn "The share is PARTIALLY seeded. Compare the two before mounting:"
        warn "    diff -rq '${tgt}' '${src}'"
        warn "and copy the remainder as ${APP_USER}, or empty ${src} and start again."
        SEED_INCOMPLETE=1
      fi
    else
      die "refusing to hide ${local_files} entries under ${tgt}.

       Re-run and choose to seed, or empty the target deliberately first."
    fi

  elif (( local_files > 0 && share_files > 0 )); then
    printf '\n'
    warn "BOTH ${tgt} (${local_files}) and ${src} (${share_files}) have content."
    warn "The share wins; local content will be hidden, not merged, not deleted."
    warn "It stays on disk underneath the mount and reappears if unmounted."
    confirm "Continue?" || die "aborted"
  fi
done

if (( ${#UNWRITABLE[@]} > 0 )); then
  cat >&2 <<UNWRITABLE_MSG

[fail] ${APP_USER} cannot write to ${#UNWRITABLE[@]} source director$( (( ${#UNWRITABLE[@]} == 1 )) && printf 'y' || printf 'ies' ) on the share.
       Nothing was mounted and fstab was not touched: mounting now would hide
       the local content under an unwritable directory and every upload would
       fail.

       Fix the ownership ON THE NFS SERVER (the storage team), to the uid:gid
       of ${APP_USER} on the web nodes — $(id -u "$APP_USER"):$(id -g "$APP_GROUP") — for:
$(printf '           %s\n' "${UNWRITABLE[@]}")

       If ${EXPORT_ROOT} itself is writable by ${APP_USER} and the directories
       are empty, recreating them from this node also works:
           sudo -u ${APP_USER} sh -c 'cd ${EXPORT_ROOT} && mv <dir> <dir>.old && mkdir <dir>'

       Then re-run this script.
UNWRITABLE_MSG
  exit 1
fi

# ═════════════════════════════════════════════════════════════════════════════
log "5/7  Write fstab entries"
# ═════════════════════════════════════════════════════════════════════════════

FSTAB_ADDED=0

# The additions are built in a temp file and appended to /etc/fstab in ONE
# operation. A sequence of `printf >> /etc/fstab` inside run "..." strings is one
# interrupted redirect away from a truncated fstab, and an unbootable node.
FSTAB_NEW=$(mktemp)
FSTAB_TMP=$(mktemp)
FSTAB_REWRITE=()
trap 'rm -f "$FSTAB_NEW" "$FSTAB_TMP"' EXIT

{
  printf '\n# GovExy shared storage — bind mounts from %s\n' "$EXPORT_ROOT"
  printf '# x-systemd.requires-mounts-for stops a bind firing before NFS is up,\n'
  printf '# which would silently bind an empty local directory instead.\n'
  printf '#\n'
  printf '# nofail is a deliberate trade, and it goes the other way from the one\n'
  printf '# above. Without it these are boot-blocking: an NFS server that is down\n'
  printf '# when a web node reboots fails local-fs.target and drops the node to an\n'
  printf '# emergency console, so an NFS outage takes both web nodes offline\n'
  printf '# permanently and recovery needs console access to a government VM.\n'
  printf '# With it, the node boots with the binds absent and would write to local\n'
  printf '# disk — which 04-deploy.sh already refuses to do, and which a /up health\n'
  printf '# check plus a mount alarm covers. Nothing covers a node that will not boot.\n'
  printf '#\n'
  printf '# Add a mount assertion to this node monitoring:\n'
  printf '#     findmnt %s/storage/app/public\n' "$APP_ROOT"
} > "$FSTAB_NEW"

for m in "${MAPPINGS[@]}"; do
  IFS='|' read -r src tgt label writer seed <<< "$m"

  # By field, not by delimiter: a hand-written line mixing tabs and spaces
  # around the target defeated both fixed-string greps, and the duplicate bind
  # was appended — mount -a then stacks it.
  existing_src=$(awk -v t="$tgt" '!/^[[:space:]]*#/ && $2 == t { print $1; exit }' /etc/fstab)
  if [[ -n "$existing_src" ]]; then
    if [[ "$existing_src" == "$src" ]]; then
      ok "fstab entry already present: $tgt"
      continue
    fi
    # Same target, different source: the line from before the export moved.
    # It is dropped from fstab and the fresh line appended with the others.
    warn "fstab binds ${tgt} from ${existing_src} — replacing with ${src}"
    FSTAB_REWRITE+=("$tgt")
  fi

  printf '%s  %s  none  bind,nofail,_netdev,x-systemd.requires-mounts-for=%s  0 0\n' \
    "$src" "$tgt" "$EXPORT_ROOT" >> "$FSTAB_NEW"
  FSTAB_ADDED=$((FSTAB_ADDED + 1))
done

if (( FSTAB_ADDED > 0 )); then
  # Computed BEFORE run(): inside run's eval the substitution sat in single
  # quotes, so the backup was one literal file named '/etc/fstab.bak.$(date +%s)'
  # — and a second run overwrote the only copy of the original with the already-
  # modified fstab.
  fstab_bak="/etc/fstab.bak.$(date +%s)"
  run "cp -a /etc/fstab '$fstab_bak'"
  # Stale lines out first. Written through a temp file and copied back over
  # /etc/fstab (cat >, not mv) so the inode, mode and SELinux label survive.
  for t in ${FSTAB_REWRITE[@]+"${FSTAB_REWRITE[@]}"}; do
    run "awk -v t='$t' '!/^[[:space:]]*#/ && \$2 == t { next } { print }' /etc/fstab > '$FSTAB_TMP' && cat '$FSTAB_TMP' > /etc/fstab"
  done
  run "cat '$FSTAB_NEW' >> /etc/fstab"
  $DRY_RUN && sed 's/^/    /' "$FSTAB_NEW"
  ok "added ${FSTAB_ADDED} fstab entries"
else
  ok "fstab already complete"
fi

# ═════════════════════════════════════════════════════════════════════════════
log "6/7  Mount and SELinux"
# ═════════════════════════════════════════════════════════════════════════════

run "systemctl daemon-reload"

# findmnt --verify first: it reports a malformed entry without acting on it.
#
# `mount -a` under set -e used to abort the script before the verify section if
# any UNRELATED fstab entry failed, leaving the entries just written untested and
# the operator with no report. Let it warn instead and let step 7 say what is
# actually mounted.
run "findmnt --verify --verbose || true"
run "mount -a || printf '\033[1;33m[warn]\033[0m mount -a reported a failure — step 7 says which paths are affected\n'"

# Without this, SELinux denies nginx/php-fpm access to NFS-backed paths. The
# symptom is misleading: the file is present, correctly owned, readable by the
# service user, and every read still fails.
if command -v getsebool &>/dev/null && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]; then
  if [[ "$(getsebool httpd_use_nfs 2>/dev/null)" != *" on" ]]; then
    run "setsebool -P httpd_use_nfs 1"
    ok "enabled SELinux boolean httpd_use_nfs"
  else
    ok "SELinux httpd_use_nfs already on"
  fi
fi

# A process that already had a log file open keeps writing to the LOCAL inode
# under the new mount — the share shows an empty file while the log grows
# invisibly on local disk. Make every writer reopen its logs once the binds
# are in place: nginx and php-fpm reopen on reload, Horizon is long-lived and
# holds laravel.log open, so terminate it and let its unit restart it. Only
# when a log bind was actually added this run.
if $BIND_LOGS && (( FSTAB_ADDED > 0 || STALE_REMOUNTED > 0 )); then
  log "6b/7  Reopen log files"
  if systemctl is-active --quiet nginx; then
    run "nginx -t && systemctl reload nginx" \
      && ok "nginx reloaded (logs reopened on the share)" \
      || warn "nginx reload failed — it is still writing to the LOCAL files under the mount"
  fi
  if systemctl is-active --quiet php-fpm; then
    run "systemctl reload php-fpm" \
      && ok "php-fpm reloaded (logs reopened on the share)" \
      || warn "php-fpm reload failed — it is still writing to the LOCAL files under the mount"
  fi
  if systemctl is-active --quiet govexy-horizon 2>/dev/null; then
    run "sudo -u '$APP_USER' php '${APP_ROOT}/artisan' horizon:terminate" \
      && ok "Horizon terminated; its unit restarts it with laravel.log on the share" \
      || warn "horizon:terminate failed — restart govexy-horizon by hand or its log stays local"
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
log "7/7  Verify"
# ═════════════════════════════════════════════════════════════════════════════

$DRY_RUN && { log "dry run complete — nothing changed"; exit 0; }

FAILED=0
ROOT_SQUASHED=0
for m in "${MAPPINGS[@]}"; do
  IFS='|' read -r src tgt label writer seed <<< "$m"

  if ! findmnt -rn "$tgt" &>/dev/null; then
    warn "NOT MOUNTED: $tgt"
    FAILED=1
    continue
  fi

  # nginx and php-fpm masters open their logs as root BEFORE dropping
  # privileges. If the export squashes root to nobody, that open is denied and
  # the service refuses to start on its next restart — a failure that appears
  # hours later, at the first reboot, not now. Prove root can write here.
  if [[ "$writer" == "root" ]]; then
    rprobe=".rootprobe.$$"
    if touch "${tgt}/${rprobe}" 2>/dev/null; then
      rm -f "${tgt}/${rprobe}"
    else
      warn "ROOT cannot write to ${tgt} — nginx/php-fpm will fail to open their logs at the next restart"
      ROOT_SQUASHED=1
      FAILED=1
      continue
    fi
  fi

  # findmnt alone only proves something is mounted there. Write on the share and
  # read through the mount to prove it is the RIGHT something.
  #
  # The probe runs as the APP USER, not as root. Under root_squash — which
  # NFS-SHARED-STORAGE.md calls "fine and preferred" — root's touch is squashed
  # to nobody and fails, so this reported FAILED=1 on a CORRECTLY configured
  # export and sent the operator off to loosen it. The app user is the identity
  # whose access actually matters.
  probe=".mountprobe.$$"
  if sudo -u "$APP_USER" touch "${src}/${probe}" 2>/dev/null; then
    if [[ -e "${tgt}/${probe}" ]]; then
      ok "$tgt  <-  $src"
    else
      warn "MISMATCH: $tgt is mounted but does not reflect $src"
      FAILED=1
    fi
    sudo -u "$APP_USER" rm -f "${src}/${probe}"
  else
    warn "$APP_USER cannot write to $src — check export permissions and ID mapping"
    warn "(root cannot either, under the recommended root_squash; this checks the"
    warn " user that matters.)"
    FAILED=1
  fi
done

printf '\n'
ALL_TARGETS=()
for m in "${MAPPINGS[@]}"; do
  IFS='|' read -r src tgt label writer seed <<< "$m"
  ALL_TARGETS+=("$tgt")
done
findmnt -o TARGET,SOURCE,FSTYPE "${ALL_TARGETS[@]}" 2>/dev/null || true

(( SEED_INCOMPLETE == 0 )) || \
  warn "one or more shares were only PARTIALLY seeded — see the warnings above"

if (( ROOT_SQUASHED )); then
  cat >&2 <<SQUASH

The export squashes root and the nginx / php-fpm log directories are not
writable by the squashed identity. Two ways out — the first is the right one:

  1. Ask the storage team to map root to the application user on this export,
     keeping root_squash:
         anonuid=$(id -u "$APP_USER"),anongid=$(id -g "$APP_GROUP")
     (both web nodes report the same ids — NFS-SHARED-STORAGE.md §3)

  2. Make the two log directories world-writable with the sticky bit, as the
     application user, from any node:
         sudo -u ${APP_USER} chmod 1777 ${LOG_ROOT}/nginx ${LOG_ROOT}/php-fpm

Until one is done, do NOT restart nginx or php-fpm on this node. Roll back the
log binds with:
         umount /var/log/nginx /var/log/php-fpm ${APP_ROOT}/storage/logs
         (and remove their lines from /etc/fstab)
SQUASH
fi

(( FAILED == 0 )) || die "verification failed — see warnings above"

cat <<DONE

────────────────────────────────────────────────────────────────────────────
Shared storage mounted and verified.

Run this on EVERY other web node. Do NOT seed again — the share already holds
the content, and this script will detect that and skip the copy.

Cross-node check, once a second node is done:

    # node A
    sudo -u ${APP_USER} touch ${APP_ROOT}/storage/app/public/.crosstest
    # node B
    ls -la ${APP_ROOT}/storage/app/public/.crosstest
    # node A
    rm -f ${APP_ROOT}/storage/app/public/.crosstest
DONE

if $BIND_LOGS; then
cat <<LOGS
Per-node logs: every node's logs are under ${EXPORT_ROOT}/${SUB_LOGS}/<node>/.
Give the OTHER node a different name when you run this there. Read across nodes:

    tail -f ${EXPORT_ROOT}/${SUB_LOGS}/*/laravel/laravel.log
    ls ${EXPORT_ROOT}/${SUB_LOGS}/

logrotate for nginx creates the rotated file as nginx:adm. With root mapped to
the application user on the export, the chgrp to adm is refused and the daily
rotation fails. If ${EXPORT_ROOT} squashes root, change the create line:

    sed -i 's/^\(\s*create 640 nginx\) adm/\1 ${APP_GROUP}/' /etc/logrotate.d/nginx
    logrotate -d /etc/logrotate.d/nginx      # dry run, expect no errors

LOGS
fi

cat <<DONE
One thing this script cannot fix, in the application repository:

  resources/themes is tracked in git. While it stays tracked, every deploy that
  replaces the code tree fights the share — git sees the mounted content as
  modified or deleted tracked files. Untrack it:

      git rm -r --cached resources/themes

  and add to .gitignore:

      /resources/themes/*
      !/resources/themes/.gitkeep

  Note the test suite has ThemeFixturesAreCommittedTest guarding
  resources/themes/starter, and several render tests copy from it, so move that
  fixture to tests/Fixtures/themes/ in the same change.

  Any rsync-based deploy must also exclude the mounted paths:

      rsync -a --delete --exclude 'resources/themes' --exclude 'storage/app' ...
────────────────────────────────────────────────────────────────────────────
DONE
