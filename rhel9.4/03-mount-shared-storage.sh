#!/usr/bin/env bash
#
# GovExy web node — STAGE 3: shared storage bind mounts
#
# Interactive. Discovers mounted NFS exports, asks which one backs this
# installation, then binds three of its subdirectories onto the application:
#
#     <export>/<media>    ->  <APP_ROOT>/storage/app/public    dashboard uploads
#     <export>/<private>  ->  <APP_ROOT>/storage/app/private   form attachments
#     <export>/<themes>   ->  <APP_ROOT>/resources/themes      uploaded themes
#
# Idempotent: safe to re-run. Existing fstab entries are detected, not duplicated.
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

# ═════════════════════════════════════════════════════════════════════════════
log "1/7  Discover mounted NFS exports"
# ═════════════════════════════════════════════════════════════════════════════

mapfile -t NFS_MOUNTS < <(findmnt -rn -t nfs,nfs4 -o TARGET 2>/dev/null | sort -u)

if (( ${#NFS_MOUNTS[@]} == 0 )); then
  die "No NFS mount found.

       The storage team mounts the export; this script only binds parts of it
       into the application. Check with:
           findmnt -t nfs,nfs4
           df -hT -t nfs -t nfs4"
fi

printf '\n'
findmnt -t nfs,nfs4 -o TARGET,SOURCE,SIZE,AVAIL 2>/dev/null || \
  df -hT -t nfs -t nfs4

EXPORT_ROOT=""
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

# ═════════════════════════════════════════════════════════════════════════════
log "2/7  Application root"
# ═════════════════════════════════════════════════════════════════════════════

DEFAULT_APP_ROOT="/var/www/govexy"
[[ -f "${BASH_SOURCE%/*}/govexy-node.conf" ]] && \
  DEFAULT_APP_ROOT=$(grep -E '^APP_ROOT=' "${BASH_SOURCE%/*}/govexy-node.conf" 2>/dev/null \
    | head -1 | cut -d= -f2- | tr -d '"' | awk '{print $1}') || true
DEFAULT_APP_ROOT="${DEFAULT_APP_ROOT:-/var/www/govexy}"

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

SUB_MEDIA=$(ask   "Subdirectory for dashboard media"    "media")
SUB_PRIVATE=$(ask "Subdirectory for form attachments"   "private")
SUB_THEMES=$(ask  "Subdirectory for uploaded themes"    "themes")

# source|target|label
MAPPINGS=(
  "${EXPORT_ROOT}/${SUB_MEDIA}|${APP_ROOT}/storage/app/public|dashboard media"
  "${EXPORT_ROOT}/${SUB_PRIVATE}|${APP_ROOT}/storage/app/private|form attachments"
  "${EXPORT_ROOT}/${SUB_THEMES}|${APP_ROOT}/resources/themes|uploaded themes"
)

printf '\n'
for m in "${MAPPINGS[@]}"; do
  IFS='|' read -r src tgt label <<< "$m"
  printf '  %-40s ->  %s   (%s)\n' "$src" "$tgt" "$label"
done
printf '\n'

if $VERIFY_ONLY; then
  log "VERIFY ONLY"
  rc=0
  for m in "${MAPPINGS[@]}"; do
    IFS='|' read -r src tgt label <<< "$m"
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

for m in "${MAPPINGS[@]}"; do
  IFS='|' read -r src tgt label <<< "$m"

  if findmnt -rn "$tgt" &>/dev/null; then
    ok "already mounted, skipping checks: $tgt"
    continue
  fi

  if [[ ! -d "$src" ]]; then
    if confirm "Source ${src} does not exist. Create it?"; then
      run "install -d -o '$APP_USER' -g '$APP_GROUP' '$src'"
    else
      die "cannot bind a source that does not exist: $src"
    fi
  fi

  run "install -d -o '$APP_USER' -g '$APP_GROUP' '$tgt'"

  local_files=$(find "$tgt" -mindepth 1 2>/dev/null | wc -l)
  share_files=$(find "$src" -mindepth 1 2>/dev/null | wc -l)

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
      if run "sudo -u '$APP_USER' cp -a --no-preserve=ownership '${tgt}/.' '${src}/'"; then
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

# ═════════════════════════════════════════════════════════════════════════════
log "5/7  Write fstab entries"
# ═════════════════════════════════════════════════════════════════════════════

SEED_INCOMPLETE=0

FSTAB_ADDED=0

# The additions are built in a temp file and appended to /etc/fstab in ONE
# operation. A sequence of `printf >> /etc/fstab` inside run "..." strings is one
# interrupted redirect away from a truncated fstab, and an unbootable node.
FSTAB_NEW=$(mktemp)
trap 'rm -f "$FSTAB_NEW"' EXIT

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
  IFS='|' read -r src tgt label <<< "$m"

  # -F, on the target surrounded by spaces. The previous ERE escaped every '/',
  # which is unnecessary in an ERE and strictly an undefined escape.
  if grep -q -F " ${tgt} " /etc/fstab || grep -q -F "	${tgt}	" /etc/fstab; then
    ok "fstab entry already present: $tgt"
    continue
  fi

  printf '%s  %s  none  bind,nofail,x-systemd.requires-mounts-for=%s  0 0\n' \
    "$src" "$tgt" "$EXPORT_ROOT" >> "$FSTAB_NEW"
  FSTAB_ADDED=$((FSTAB_ADDED + 1))
done

if (( FSTAB_ADDED > 0 )); then
  run "cp -a /etc/fstab '/etc/fstab.bak.\$(date +%s)'"
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

# ═════════════════════════════════════════════════════════════════════════════
log "7/7  Verify"
# ═════════════════════════════════════════════════════════════════════════════

$DRY_RUN && { log "dry run complete — nothing changed"; exit 0; }

FAILED=0
for m in "${MAPPINGS[@]}"; do
  IFS='|' read -r src tgt label <<< "$m"

  if ! findmnt -rn "$tgt" &>/dev/null; then
    warn "NOT MOUNTED: $tgt"
    FAILED=1
    continue
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
findmnt -o TARGET,SOURCE,FSTYPE "${APP_ROOT}/storage/app/public" \
                                "${APP_ROOT}/storage/app/private" \
                                "${APP_ROOT}/resources/themes" 2>/dev/null || true

(( SEED_INCOMPLETE == 0 )) || \
  warn "one or more shares were only PARTIALLY seeded — see the warnings above"

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
