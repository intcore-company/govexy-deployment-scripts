#!/usr/bin/env bash
#
# GovExy web node — STAGE 4: deploy
#
# Runs on EVERY web node, once per release. Stages 1-3 are provisioning and are
# not repeated here.
#
# Usage:
#   bash 04-deploy.sh --ref v1.4.24 --primary   run migrations too (exactly ONE node)
#   bash 04-deploy.sh --ref v1.4.24             every other node
#
# The Pest suite runs by default and blocks the deploy if it fails. It costs
# about ten minutes of maintenance mode per node, so a hotfix that has already
# been tested elsewhere is a fair reason to pass --skip-tests. A release that
# has not been tested anywhere is not.
#
#   --ref <tag>      REQUIRED with a pull. The release tag to deploy, checked
#                    out detached so every node lands on the same commit.
#   --allow-branch   permit --ref to name a branch or bare sha (not a tag)
#   --no-pull        code arrives as an artifact; skip git
#   --skip-build     assets built off-server; public/build already shipped
#   --skip-composer  vendor/ shipped with the artifact
#   --with-tests     run the Pest suite as a gate before migrating (default)
#   --skip-tests     deploy without running the suite (~10 min faster)
#   --tests-advisory run the suite, report failures, continue regardless
#   --dry-run        print the plan, change nothing
#
# Order matters and is not arbitrary:
#
#   Maintenance mode is entered BEFORE composer, npm, the build and the test
#   gate. Everything from that point on rewrites vendor/ and public/build, and
#   Vite empties the output directory — so a node doing that while still in the
#   load balancer serves 404s for every hashed asset and can autoload a
#   half-written autoloader. `artisan down` makes /up return 503, which is the
#   load balancer's own drain signal, so the window costs nothing extra.
#
#   The gate used to run outside that window because maintenance mode answered
#   every HTTP feature test with 503. That was fixed in the application
#   (APP_MAINTENANCE_DRIVER=cache pinned in phpunit.xml, cms >= 1.4.24), so the
#   tests are now immune to it and the window is back where it belongs. The
#   pin is asserted below rather than assumed.
#
#   Migrations run BEFORE the new code is cached but while other nodes still
#   serve the old code, so every migration must be backward compatible with the
#   release currently running. Adding a column is safe; dropping or renaming one
#   is not, and needs a two-release expand/contract instead.
#
#   php-fpm is reloaded LAST. opcache.validate_timestamps=0 means PHP holds the
#   old bytecode until it is told otherwise — without the reload a deploy
#   appears to do nothing at all.
#
# Rollback is a redeploy of the previous tag:  bash 04-deploy.sh --ref <previous>
# Migrations are NOT reversed by it; see the "Rollback" section of README.md.

set -euo pipefail

PRIMARY=false
DO_PULL=true
DO_BUILD=true
DO_COMPOSER=true
# Tests gate the deploy by default. Override per run with --skip-tests, or
# environment-wide with DO_TESTS=false in govexy-node.conf.
#
# NOT DO_TESTS="${DO_TESTS:-true}": an exported DO_TESTS in the operator's
# environment must not be able to silently disable the gate. The only two ways
# to turn it off are the command line and govexy-node.conf, both explicit.
DO_TESTS=true
# Set by --with-tests / --skip-tests. A flag given on the command line beats the
# conf file; without this the conf could not be distinguished from the default.
TESTS_EXPLICIT=false
# Do not stop on test failures — report them and carry on. For unattended runs
# where a red suite is a known, accepted state.
TESTS_ADVISORY=false
DRY_RUN=false
# The release to deploy. Required with a pull: without it each node deploys
# whatever the tracked branch's HEAD happens to be when that node runs, and a
# push between node 1 and node 2 silently splits the pair.
DEPLOY_REF=""
ALLOW_BRANCH=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --primary)       PRIMARY=true ;;
    --ref)           shift; DEPLOY_REF="${1:-}"
                     [[ -n "$DEPLOY_REF" ]] || { printf -- '--ref needs a tag\n' >&2; exit 1; } ;;
    --allow-branch)  ALLOW_BRANCH=true ;;
    --no-pull)       DO_PULL=false ;;
    --skip-build)    DO_BUILD=false ;;
    --skip-composer) DO_COMPOSER=false ;;
    --with-tests)    DO_TESTS=true;  TESTS_EXPLICIT=true ;;
    --skip-tests)    DO_TESTS=false; TESTS_EXPLICIT=true ;;
    --tests-advisory) TESTS_ADVISORY=true ;;
    --dry-run)       DRY_RUN=true ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
  shift
done

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

run() {
  local cmd="$*"
  if $DRY_RUN; then
    printf '\033[2m[dry-run] %s\033[0m\n' "$cmd"
  else
    eval "$cmd"
  fi
}

[[ $EUID -eq 0 ]] || die "must run as root"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="/var/www/govexy"
[[ -f "${SCRIPT_DIR}/govexy-node.conf" ]] && \
  APP_ROOT=$(grep -E '^APP_ROOT=' "${SCRIPT_DIR}/govexy-node.conf" | head -1 \
             | cut -d= -f2- | tr -d '"' | awk '{print $1}')
APP_ROOT="${APP_ROOT:-/var/www/govexy}"

# A DO_TESTS setting in govexy-node.conf becomes the site-wide default; an
# explicit --with-tests / --skip-tests on the command line still wins.
#
# It wins because of TESTS_EXPLICIT, not because the flags are parsed first.
# This used to test "$DO_TESTS" == "true", which is exactly the state
# --with-tests produces — so with DO_TESTS=false in the conf, --with-tests was a
# silent no-op and the release shipped with nothing verified.
if ! $TESTS_EXPLICIT && [[ -f "${SCRIPT_DIR}/govexy-node.conf" ]]; then
  conf_tests=$(grep -E '^DO_TESTS=' "${SCRIPT_DIR}/govexy-node.conf" 2>/dev/null \
               | head -1 | cut -d= -f2- | tr -d '"' | awk '{print $1}')
  [[ "$conf_tests" == "false" ]] && DO_TESTS=false
fi

[[ -d "$APP_ROOT" ]] || die "application root not found: $APP_ROOT"
APP_USER=$(stat -c '%U' "$APP_ROOT")
APP_GROUP=$(stat -c '%G' "$APP_ROOT")

# One deploy per node at a time. Two operators running this concurrently on the
# same node interleave composer, npm and the cache commands on one tree, and
# neither run's output says so. Node-local by design: the primary-only guard for
# migrations is --isolated, which locks in the shared cache store.
#
# The `exec 9>` is guarded: on RHEL /var/lock is a symlink to /run/lock and always
# exists, but a failed redirect under set -e would abort the deploy with a bare
# shell error and no explanation. Degrade to a warning rather than that.
if ! $DRY_RUN; then
  if exec 9>/var/lock/govexy-deploy.lock; then
    flock -n 9 || die "another deploy is already running on this node"
  else
    warn "could not open /var/lock/govexy-deploy.lock — concurrent deploys are not guarded"
  fi
fi

# Cross-node markers.
#
# storage/app/private is one of the three NFS binds (03-mount-shared-storage.sh),
# so a file written here by one node is read by the other. storage/app itself is
# NOT mounted — a marker directly under it would be node-local and could never
# catch the drift these two exist to catch.
DEPLOYED_REF_FILE="${APP_ROOT}/storage/app/private/.deployed-ref"
ENV_FINGERPRINT_FILE="${APP_ROOT}/storage/app/private/.env-fingerprint"

# The service user's home is often /usr/share/nginx or /var/lib/nginx and is not
# writable, so composer and npm fail with EACCES on their cache before doing any
# work. Give both an explicit writable cache and HOME.
COMPOSER_CACHE="/var/cache/govexy-composer"
NPM_CACHE="/var/cache/govexy-npm"
APP_HOME="/var/lib/govexy-deploy"

# git runs as ROOT, deliberately, so the deploy key never has to be readable by
# the app user. That user is also what PHP-FPM runs as, so a key copied into its
# home would be reachable from the web application — an RCE in PHP would leak
# repository credentials. Keeping it 0600 root:root removes that path entirely.
#
# Cost of this choice: files git creates are root-owned, so ownership is
# corrected immediately after the pull, before composer or npm run as the app
# user and would otherwise fail to write.
DEPLOY_SSH_KEY="${DEPLOY_SSH_KEY:-/root/.ssh/govexy_deploy}"

as_app() { run "sudo -u '$APP_USER' $*"; }

# run() is eval, so every call site quotes its own arguments. The interpolated
# values here — APP_USER, APP_GROUP, APP_ROOT — are machine-derived (stat on the
# application root, or the conf file) rather than operator input, and are quoted
# anyway; nothing from the command line reaches an eval unquoted.
as_app_env() {
  run "sudo -u '$APP_USER' env HOME='$APP_HOME' \
        COMPOSER_HOME='$COMPOSER_CACHE' \
        COMPOSER_CACHE_DIR='$COMPOSER_CACHE/cache' \
        npm_config_cache='$NPM_CACHE' $*"
}

# Runs as root with root's SSH identity and known_hosts.
#
# -c safe.directory: git refuses to operate on a repository owned by another
# user ("dubious ownership"). Scoped to this one command rather than written
# into a global gitconfig, so the protection stays in force everywhere else.
#
# IdentitiesOnly=yes stops ssh offering every other key it can find and
# exhausting the server's MaxAuthTries before it reaches this one.
root_git() {
  local ssh_opt=""
  [[ -r "$DEPLOY_SSH_KEY" ]] && \
    ssh_opt="GIT_SSH_COMMAND='ssh -i ${DEPLOY_SSH_KEY} -o IdentitiesOnly=yes'"
  run "env $ssh_opt git -c safe.directory='$APP_ROOT' -C '$APP_ROOT' $*"
}

# Files git just wrote are root-owned. Hand them back before anything runs as
# the app user.
reown() {
  run "find '$APP_ROOT' -xdev \( ! -user '$APP_USER' -o ! -group '$APP_GROUP' \) \
        -exec chown '$APP_USER':'$APP_GROUP' {} + 2>/dev/null || true"
}

MAINT_ON=false

# EXIT, not ERR. die() calls exit, and exit does not fire an ERR trap — using
# ERR here meant any failed pre-flight or pull left the node in maintenance mode
# with nothing to lift it.
cleanup() {
  local status=$?
  if (( status != 0 )) && $MAINT_ON && ! $DRY_RUN; then
    warn "deploy failed (exit ${status}) — clearing compiled caches and lifting maintenance"
    # Step 9 builds config, route, view and event caches as four separate gates.
    # A failure at the second one used to lift maintenance onto a NEW cached
    # config with NO route cache — a state nothing has ever been tested in.
    # Clear all four so the node comes back uncached, which is slower and
    # correct.
    #
    # Not optimize:clear. That includes cache:clear, which flushes the Redis
    # store shared with the other node and with Horizon.
    for c in config:clear route:clear view:clear event:clear; do
      sudo -u "$APP_USER" php "$APP_ROOT/artisan" "$c" >/dev/null 2>&1 || true
    done
    sudo -u "$APP_USER" php "$APP_ROOT/artisan" up || \
      warn "could not lift maintenance mode; run: sudo -u $APP_USER php $APP_ROOT/artisan up"
  fi
}
trap cleanup EXIT

# ═════════════════════════════════════════════════════════════════════════════
log "1/10 Pre-flight"
# ═════════════════════════════════════════════════════════════════════════════

$DRY_RUN && log "DRY RUN — nothing will be changed"

[[ -f "$APP_ROOT/.env" ]] || die ".env missing at $APP_ROOT/.env"
[[ -f "$APP_ROOT/artisan" ]] || die "not a Laravel root: $APP_ROOT"

# Shared storage must be mounted BEFORE anything writes. Deploying onto an
# unmounted target writes to local disk, and the files silently disappear the
# moment the real mount lands.
for p in storage/app/public storage/app/private resources/themes; do
  if findmnt -rn "${APP_ROOT}/${p}" &>/dev/null; then
    ok "mounted: ${p}"
  else
    die "NOT MOUNTED: ${APP_ROOT}/${p}

       Deploying now would write to local disk and lose the data when the
       share is mounted. Run 03-mount-shared-storage.sh --verify first."
  fi
done

run "install -d -o '$APP_USER' -g '$APP_GROUP' -m 0755 '$APP_HOME' '$COMPOSER_CACHE' '$NPM_CACHE'"

# ── .env assertions ──────────────────────────────────────────────────────────
#
# Existence was the only thing checked here, and config:cache succeeds happily
# against a null value. These four are the ones whose default is wrong for an
# on-premise government node:
#
#   TELESCOPE_ENABLED  defaults to TRUE in config/telescope.php, and the package
#                      is in require (not require-dev), so --no-dev leaves it
#                      installed. Recording is unconditional even though the UI
#                      is gated: every request, query, job and payload is
#                      written to telescope_entries, forever, on government data.
#   APP_DEBUG          leaks stack traces, config values and the DSN to visitors.
#   APP_ENV            production is what gates a dozen framework safeguards.
#   LICENSE_MODE       must be present; onprem and saas are different products.
env_value() {
  grep -E "^${1}=" "$APP_ROOT/.env" 2>/dev/null | head -1 | cut -d= -f2- \
    | tr -d '"'"'"' ' || true
}

if ! $DRY_RUN; then
  for k in TELESCOPE_ENABLED APP_DEBUG; do
    v=$(env_value "$k")
    [[ "$v" == "false" ]] || die "${k} is '${v:-unset}' in .env, expected false.

       Set ${k}=false and re-run. Telescope in particular defaults to ENABLED
       and records every request, query and job into the database."
  done

  v=$(env_value APP_ENV)
  [[ "$v" == "production" ]] || die "APP_ENV is '${v:-unset}' in .env, expected production."

  v=$(env_value LICENSE_MODE)
  [[ -n "$v" ]] || die "LICENSE_MODE is not set in .env.

       onprem and saas are different products — billing, tenant caps and the
       dashboard surface all differ. Set it deliberately."
  ok ".env: APP_ENV=production APP_DEBUG=false TELESCOPE_ENABLED=false LICENSE_MODE=${v}"

  # A release that introduces a required key resolves it to null rather than
  # failing, so the drift is invisible until something breaks at runtime.
  if [[ -f "$APP_ROOT/.env.example" ]]; then
    missing=$(comm -23 \
      <(grep -oE '^[A-Z_][A-Z0-9_]*=' "$APP_ROOT/.env.example" | sort -u) \
      <(grep -oE '^[A-Z_][A-Z0-9_]*=' "$APP_ROOT/.env"         | sort -u) || true)
    if [[ -n "$missing" ]]; then
      warn "keys present in .env.example but absent from .env (they resolve to null):"
      printf '%s\n' "$missing" | sed 's/^/    /'
    fi
  fi

  # Nodes must share one .env. A differing APP_KEY breaks every session and
  # encrypted cookie the moment the load balancer moves a user between nodes.
  # Comments and blank lines are stripped so a comment-only edit is not drift;
  # only the digest travels, never a value.
  ENV_FINGERPRINT=$(grep -vE '^\s*(#|$)' "$APP_ROOT/.env" | sort | sha256sum | cut -c1-16)
  printf 'env fp    : %s   (must match on every node)\n' "$ENV_FINGERPRINT"
  if [[ -r "$ENV_FINGERPRINT_FILE" ]]; then
    recorded=$(head -1 "$ENV_FINGERPRINT_FILE" | awk '{print $1}')
    [[ "$recorded" == "$ENV_FINGERPRINT" ]] || \
      warn ".env differs from the fingerprint the primary recorded (${recorded}).
       Reconcile the two files before this node serves traffic."
  fi
fi

if $DO_PULL && ! $DRY_RUN; then
  if [[ -r "$DEPLOY_SSH_KEY" ]]; then
    keyperms=$(stat -c '%a' "$DEPLOY_SSH_KEY")
    keyowner=$(stat -c '%U' "$DEPLOY_SSH_KEY")
    [[ "$keyperms" == "600" || "$keyperms" == "400" ]] || \
      warn "deploy key is mode ${keyperms}; ssh refuses keys readable by group or world"
    if [[ "$keyowner" == "$APP_USER" ]]; then
      warn "deploy key is owned by ${APP_USER}, which is also the PHP-FPM user."
      warn "A web-application compromise could read it. Prefer 0600 root:root."
    fi
    ok "deploy key: ${DEPLOY_SSH_KEY} (${keyowner}, ${keyperms})"
  else
    warn "no deploy key at ${DEPLOY_SSH_KEY} — relying on root's default ssh config"
  fi
fi

if $DO_PULL; then
  [[ -n "$DEPLOY_REF" ]] || die "no --ref given.

       Editions are built from a tagged release and every node must land on the
       same commit. Without a ref this script deploys whatever the tracked
       branch's HEAD happens to be when THIS node runs, so a push between the
       first node and the second splits the pair silently.

           bash 04-deploy.sh --ref v1.4.24 --primary

       Deploy with --no-pull if the code arrives as an artifact instead."

  # resources/themes is tracked in git AND is an NFS bind holding every theme
  # uploaded through the admin panel. While it stays tracked, a checkout that
  # touches a tracked path under it writes onto the shared export — seen by the
  # other node before that node has deployed — and any 'reset --hard' style
  # recovery restores shipped themes over uploaded ones. Same hazard as the
  # 'git clean' this script refuses below.
  if git -c safe.directory="$APP_ROOT" -C "$APP_ROOT" ls-files --error-unmatch \
       resources/themes >/dev/null 2>&1; then
    warn "resources/themes is still TRACKED in git and is an NFS bind mount."
    warn "A checkout that touches it writes onto the shared export. Untrack it:"
    warn "    git rm -r --cached resources/themes   (see 03-mount-shared-storage.sh)"
  fi
fi

printf '\n'
printf 'node      : %s\n' "$(hostname)"
printf 'app root  : %s (%s:%s)\n' "$APP_ROOT" "$APP_USER" "$APP_GROUP"
printf 'primary   : %s\n' "$PRIMARY"
printf 'ref       : %s\n' "${DEPLOY_REF:-<tracked branch HEAD>}"
printf 'pull      : %s\n' "$DO_PULL"
printf 'composer  : %s\n' "$DO_COMPOSER"
printf 'build     : %s\n' "$DO_BUILD"
printf 'tests     : %s\n' "$DO_TESTS"

if $PRIMARY; then
  printf '\n'
  warn "PRIMARY: this node runs migrations. Exactly one node may do so."
fi

if ! $DRY_RUN; then
  # read returns non-zero at EOF, and under `set -e` that terminates the script
  # before die() is reached — so a run under nohup or from a pipeline exited 1
  # with a blank screen. Say what happened instead.
  read -r -p $'\nProceed? [y/N] ' answer \
    || die "no terminal to confirm on (non-interactive run). Run it under tmux."
  [[ "$answer" == [yY] ]] || die "aborted"
fi

# ═════════════════════════════════════════════════════════════════════════════
log "2/10 Source code"
# ═════════════════════════════════════════════════════════════════════════════

if $DO_PULL; then
  # Refuse to pull over uncommitted work — on a server that means someone
  # edited live files, and a merge would either clobber it or halt mid-deploy.
  if ! $DRY_RUN; then
    # --untracked-files=no is the important part. A running node accumulates
    # untracked files as a matter of course: themes uploaded through the admin
    # panel land in the mounted resources/themes, and generated assets appear
    # under public/. None of that is uncommitted work and none of it blocks a
    # pull — git only refuses when an INCOMING commit would overwrite an
    # untracked file, and it says so plainly when that happens.
    #
    # What this check is actually for is tracked files edited in place on the
    # server, which a pull would either clobber or halt on.
    #
    # Also excluded: the mounted paths, which always look modified because the
    # share is what is really there, and package-lock.json, which npm rewrites
    # on the server and is restored from the commit just below.
    dirty=$(git -c safe.directory="$APP_ROOT" -C "$APP_ROOT" status --porcelain \
            --untracked-files=no \
            -- ':!resources/themes' ':!storage' ':!package-lock.json' 2>/dev/null || true)
    if [[ -n "$dirty" ]]; then
      printf '\n%s\n\n' "$dirty"
      die "TRACKED files have been modified on this server (untracked files are
       ignored — uploaded themes and generated assets are expected).

       Inspect:
           git -c safe.directory=$APP_ROOT -C $APP_ROOT status --untracked-files=no
           git -c safe.directory=$APP_ROOT -C $APP_ROOT diff

       Discard them if they were accidental:
           git -c safe.directory=$APP_ROOT -C $APP_ROOT checkout -- <file>

       Do NOT run 'git stash' or 'git clean' to get past this. Both reach into
       the mounted share, and 'git clean -fd' would delete every theme uploaded
       through the admin panel."
    fi

    if ! git -c safe.directory="$APP_ROOT" -C "$APP_ROOT" diff --quiet -- package-lock.json 2>/dev/null; then
      warn "package-lock.json was modified locally; restoring it from the commit"
      root_git "checkout -- package-lock.json"
    fi
  fi
  if ! git -c safe.directory="$APP_ROOT" -C "$APP_ROOT" rev-parse --git-dir &>/dev/null; then
    die "git cannot read $APP_ROOT as user $APP_USER.

       If the message mentions 'dubious ownership', the repository is owned by a
       different user than the one running git. Check with:
           stat -c '%U' $APP_ROOT
           git -c safe.directory=$APP_ROOT -C $APP_ROOT status
       Deploy with --no-pull if the code arrives as an artifact instead."
  fi

  root_git "fetch --prune --tags --force"

  # A detached checkout of a TAG, not a pull. A pull deploys the tracked
  # branch's HEAD as it stands at this instant, so two nodes deployed ten
  # minutes apart can land on different commits with nothing saying so.
  #
  # The tag check is not pedantry: a branch name is a moving target and gives
  # the same divergence back. --allow-branch exists for the deliberate case
  # (bisecting a bad release, deploying a fix branch to one node).
  if ! $DRY_RUN; then
    git -c safe.directory="$APP_ROOT" -C "$APP_ROOT" \
        rev-parse --verify --quiet "${DEPLOY_REF}^{commit}" >/dev/null \
      || die "no such ref in this repository: ${DEPLOY_REF}

       Available tags:
           git -c safe.directory=$APP_ROOT -C $APP_ROOT tag --sort=-creatordate | head"

    if ! git -c safe.directory="$APP_ROOT" -C "$APP_ROOT" \
           show-ref --verify --quiet "refs/tags/${DEPLOY_REF}"; then
      $ALLOW_BRANCH || die "${DEPLOY_REF} is not a tag.

       Releases are tags: a branch or a bare sha moves, or is not reproducible
       on the second node. Pass --allow-branch if this is deliberate."
      warn "${DEPLOY_REF} is not a tag; --allow-branch given, continuing"
    fi
  fi

  root_git "checkout --detach '$DEPLOY_REF'"
  root_git "log -1 --pretty='%h %s'"

  if ! $DRY_RUN; then
    DEPLOYED_SHA=$(git -c safe.directory="$APP_ROOT" -C "$APP_ROOT" rev-parse HEAD)
    ok "deployed ref: ${DEPLOY_REF} (${DEPLOYED_SHA})"
  fi

  # git wrote as root; hand the tree back before composer and npm run as the
  # app user and hit permission errors on files they cannot touch.
  reown
else
  ok "skipped (--no-pull)"
fi

# ── Cross-node ref agreement ─────────────────────────────────────────────────
#
# The primary records what it deployed on the shared export; every other node
# refuses to deploy anything else. This is the check that catches "someone
# pushed a hotfix between the two nodes" — the failure the tag pinning above
# makes unlikely and this makes visible.
if ! $DRY_RUN && [[ -n "$DEPLOY_REF" ]]; then
  if $PRIMARY; then
    run "install -o '$APP_USER' -g '$APP_GROUP' -m 0644 /dev/null '$DEPLOYED_REF_FILE'"
    run "printf '%s\n' '$DEPLOY_REF' > '$DEPLOYED_REF_FILE'"
    run "chown '$APP_USER':'$APP_GROUP' '$DEPLOYED_REF_FILE'"
  elif [[ -r "$DEPLOYED_REF_FILE" ]]; then
    primary_ref=$(head -1 "$DEPLOYED_REF_FILE" | awk '{print $1}')
    [[ "$primary_ref" == "$DEPLOY_REF" ]] || \
      die "the primary node deployed '${primary_ref}', this node was given '${DEPLOY_REF}'.

       The two nodes would run different code against one database. Re-run with
           bash 04-deploy.sh --ref ${primary_ref}
       or deploy ${DEPLOY_REF} on the primary first."
  else
    warn "no ref recorded by a primary node yet (${DEPLOYED_REF_FILE} absent)."
    warn "Deploy the primary first, or accept that nothing is cross-checking this."
  fi
fi

# ── Ordering guard for a non-primary node ────────────────────────────────────
#
# --isolated guards two SIMULTANEOUS --primary runs. It does not guard the
# likelier mistake: running the second node first, or forgetting --primary on
# both. That node then caches new code against the old schema and throws until
# someone notices, and the pre-flight banner asked no questions about it.
if ! $PRIMARY && ! $DRY_RUN; then
  pending=$(sudo -u "$APP_USER" php "$APP_ROOT/artisan" migrate:status 2>/dev/null \
            | grep -c 'Pending' || true)
  if (( pending > 0 )); then
    die "${pending} migrations are still pending.

       The primary node has not deployed this release yet. Caching new code
       against the old schema produces errors until it does. Deploy the primary
       first:
           bash 04-deploy.sh --ref ${DEPLOY_REF:-<tag>} --primary"
  fi
  ok "no pending migrations — the primary has deployed this release"
fi

# ═════════════════════════════════════════════════════════════════════════════
log "3/10 Maintenance mode"
# ═════════════════════════════════════════════════════════════════════════════
#
# BEFORE composer, npm, the build and the test gate — everything that rewrites
# vendor/ and public/build.
#
# It briefly ran after the gate instead, to stop maintenance mode answering
# every HTTP feature test with 503. That cost more than it saved: for the ten to
# fifteen minutes those steps take, the node was live in the load balancer while
# vendor/ was rewritten twice and Vite emptied public/build, so every already
# served page referenced hashed assets that had been deleted, and a request
# touching an uncached class could read a half-written autoloader.
#
# The 503 problem is fixed in the application instead: cms >= 1.4.24 pins
# APP_MAINTENANCE_DRIVER=cache in phpunit.xml, which makes the suite immune to
# the maintenance flag. That pin is asserted, not assumed — deploying an older
# release must fail loudly rather than quietly reintroduce the 503 storm.
#
# `artisan down` is also the load balancer drain: /up is the health check and
# maintenance makes it 503, so the node leaves rotation on its own.
#
# Node-local: storage/framework/maintenance.php is not on the share, so each
# node goes dark only for itself. With a load balancer in front, take nodes one
# at a time and the site stays up.

if $DO_TESTS && ! $DRY_RUN; then
  grep -q 'name="APP_MAINTENANCE_DRIVER" value="cache"' "$APP_ROOT/phpunit.xml" 2>/dev/null || \
    die "phpunit.xml does not pin APP_MAINTENANCE_DRIVER=cache.

       This release predates cms 1.4.24. Under maintenance mode every HTTP
       feature test returns 503, so the gate would report hundreds of failures
       that are one operational state rather than one bug each.

       Upgrade the application to >= 1.4.24, or deploy this release with
       --skip-tests and run the suite somewhere else. The gate is NOT moved
       outside the maintenance window to work around this: that puts a node
       with a half-swapped vendor/ and public/build back into the load
       balancer, which is the more expensive of the two failures."
fi

as_app "php '$APP_ROOT/artisan' down --render='errors::503' --retry=60 || true"
MAINT_ON=true

# ═════════════════════════════════════════════════════════════════════════════
log "4/10 PHP dependencies"
# ═════════════════════════════════════════════════════════════════════════════

if $DO_COMPOSER; then
  if $DO_TESTS; then
    # Pest, PHPUnit and the factories live in require-dev, so --no-dev would
    # remove the very thing the test gate needs. Dev dependencies are installed
    # now and stripped again in step 6 once the suite has passed.
    ok "installing WITH dev dependencies (test gate requested)"
    as_app_env "composer install --working-dir='$APP_ROOT' --optimize-autoloader --no-interaction --prefer-dist"
  else
    as_app_env "composer install --working-dir='$APP_ROOT' --no-dev --optimize-autoloader --no-interaction --prefer-dist"
  fi
else
  ok "skipped (--skip-composer)"
fi

# ═════════════════════════════════════════════════════════════════════════════
log "5/10 Front-end assets"
# ═════════════════════════════════════════════════════════════════════════════

if $DO_BUILD; then
  command -v npm &>/dev/null || die "npm not installed. Either install Node (see
       01-install-dependencies.sh, INSTALL_NODE=yes) or build off-server and
       deploy with --skip-build."
  # Never --ignore-scripts: it leaves the esbuild and rollup native binaries
  # unlinked, and vite then dies with "Bus error (core dumped)" rather than a
  # readable error. Dev dependencies are required here — vite and tailwind are
  # devDependencies and are exactly what the build needs.
  if [[ -f "$APP_ROOT/package-lock.json" ]]; then
    as_app_env "npm --prefix '$APP_ROOT' ci"
  else
    warn "no package-lock.json — falling back to 'npm install' (unpinned versions)"
    as_app_env "npm --prefix '$APP_ROOT' install"
  fi
  as_app_env "npm --prefix '$APP_ROOT' run build"
else
  ok "skipped (--skip-build)"
fi

[[ -d "$APP_ROOT/public/build" ]] || \
  warn "public/build is missing — the panels will throw a Vite manifest exception"

# ═════════════════════════════════════════════════════════════════════════════
log "6/10 Test suite"
# ═════════════════════════════════════════════════════════════════════════════

if $DO_TESTS; then
  # Safety gate. phpunit.xml pins the suite to sqlite/:memory:, array cache and
  # session, and a sync queue, so it cannot reach the production MySQL or Redis.
  # That isolation is the ONLY reason running the suite on a live node is
  # acceptable — verify it rather than trusting it, because a phpunit.xml that
  # ever lost those lines would run RefreshDatabase against the real database
  # and drop every table in it.
  if ! $DRY_RUN; then
    grep -q 'name="DB_CONNECTION" value="sqlite"'   "$APP_ROOT/phpunit.xml" && \
    grep -q 'name="DB_DATABASE" value=":memory:"'   "$APP_ROOT/phpunit.xml" || \
      die "phpunit.xml does not pin the suite to sqlite/:memory:.

       Refusing to run tests: the suite uses RefreshDatabase, and without that
       pin it would migrate:fresh the production database named in .env."

    php -m | grep -qix pdo_sqlite || \
      die "pdo_sqlite extension is missing — the suite cannot run.
       Install it:  dnf -y install php-pdo   (it carries pdo_sqlite.so)
       (01-install-dependencies.sh installs and verifies both.)"

    # PHPUnit's <env> elements do NOT overwrite a variable that already exists
    # in the process environment unless force="true", and none of the entries in
    # phpunit.xml set it. The gate is therefore safe only because the run below
    # starts from an empty environment. Assert that nothing was exported into
    # this deploy that would beat the sqlite pin and let RefreshDatabase loose on
    # the production database — a single `Defaults env_keep += "DB_*"` in
    # /etc/sudoers, or an operator who exported DB_CONNECTION while debugging,
    # is enough.
    for v in DB_CONNECTION DB_DATABASE DB_HOST DB_USERNAME DB_PASSWORD APP_ENV \
             FILESYSTEM_DISK CACHE_STORE SESSION_DRIVER QUEUE_CONNECTION; do
      [[ -z "${!v:-}" ]] || die "$v is set in the deploy environment ('${!v}').

       PHPUnit's <env> does not override an inherited variable, so this would
       beat the pins in phpunit.xml. Unset it and re-run."
    done

    [[ -d "$APP_ROOT/tests" && -f "$APP_ROOT/phpunit.xml" ]] || \
      die "no test suite in this checkout (tests/ or phpunit.xml missing).
       Deploy with --skip-tests."

    # Pest lives in require-dev, so a vendor/ built with --no-dev — by an earlier
    # deploy, or shipped that way inside the artifact — has no test runner. The
    # composer step above installs dev dependencies when tests are requested, but
    # not if it was skipped, so repair it here rather than failing the release
    # over a missing binary.
    if [[ ! -x "$APP_ROOT/vendor/bin/pest" ]]; then
      warn "vendor/bin/pest is missing — dev dependencies are not installed"
      if $DO_COMPOSER; then
        die "composer ran but pest is still absent. Check that require-dev
       resolved:  sudo -u $APP_USER composer show --working-dir=$APP_ROOT pestphp/pest"
      fi
      log "    installing dev dependencies so the suite can run"
      as_app_env "composer install --working-dir='$APP_ROOT' --optimize-autoloader --no-interaction --prefer-dist"
      reown
      [[ -x "$APP_ROOT/vendor/bin/pest" ]] || \
        die "pest is still missing after installing dev dependencies.
       Deploy with --skip-tests, or investigate composer.lock."
    fi
  fi

  # memory_limit=1G and no execution timeout: the suite is long-running and
  # memory-hungry, and the CLI defaults are sized for web requests, not for
  # this. A bounded ceiling rather than -1, so a runaway test is killed by PHP
  # with a readable fatal instead of being killed by the OOM killer, which takes
  # whatever else on the node the kernel happens to pick.
  log "    running the full suite — this takes around 10 minutes"
  TEST_START=$SECONDS

  # The suite runs with LICENSE_MODE=saas, pinned in phpunit.xml. State it
  # plainly: a green gate proves the release passes its SaaS suite, not that
  # this on-premise installation works. TenantLicenseObserver throws at the cap
  # in one mode and not the other, and the billing surface differs entirely.
  # There is no on-premise lane in the application yet; when there is, it belongs
  # here as a second gate.
  warn "the suite runs with LICENSE_MODE=saas (pinned in phpunit.xml); this node"
  warn "runs LICENSE_MODE=$(env_value LICENSE_MODE). The gate cannot fail on an"
  warn "onprem-only regression."

  # resources/themes is a SHARED NFS export, and the suite writes into it:
  # ThemeUploadServiceTest creates and deletes a randomised theme directory
  # under it. The afterEach cleans up, but an interrupted run (Ctrl-C, a dropped
  # SSH session) leaves an orphan there permanently, where ThemeSeeder and the
  # admin theme list will find it — on both nodes. Snapshot before, diff after.
  if ! $DRY_RUN; then
    THEME_SHARE_BEFORE=$(find "$APP_ROOT/resources/themes" -maxdepth 1 -mindepth 1 2>/dev/null | sort)
  fi

  # Prove config caching works, then get out of its way.
  #
  # config:cache fails loudly on a config file that throws or contains a closure,
  # so building it here catches that class of breakage BEFORE migrations run
  # rather than in step 8 afterwards.
  #
  # It is then cleared, because Laravel reads bootstrap/cache/config.php when it
  # exists and never calls env() again — a cached config silently overrides every
  # <env> in phpunit.xml, LICENSE_MODE=saas included. Left in place, the suite
  # runs against this installation's onprem settings and the entire billing suite
  # fails for a reason that has nothing to do with the code being deployed.
  #
  # Step 8 rebuilds the cache for real once the suite has passed.
  # No cached config while the suite runs. Laravel reads bootstrap/cache/config.php
  # when it exists and never calls env() again, so a cached config overrides every
  # <env> in phpunit.xml — LICENSE_MODE=saas included — and the suite silently runs
  # against this installation's settings instead of the test environment.
  #
  # All caches are built in step 8, after the suite has passed.
  as_app "php '$APP_ROOT/artisan' config:clear"

  # cd into the app root first. `artisan test` spawns the runner using a path
  # relative to the CURRENT directory (vendor/pestphp/pest/bin/pest), so calling
  # artisan by absolute path from elsewhere fails with "Could not open input
  # file" for a binary that is plainly present.
  #
  # The run is teed to a log so the outcome can be summarised afterwards; a
  # thousand lines of scrollback is not a report. PIPESTATUS is what carries the
  # runner's exit code, because tee always succeeds.
  TEST_LOG="${APP_ROOT}/storage/logs/deploy-tests-$(date +%Y%m%d-%H%M%S).log"

  if $DRY_RUN; then
    # The run itself used to sit outside run()'s dry-run branch, so --dry-run
    # ("print the plan, change nothing") spent ten minutes running the suite for
    # real on a production node — writing a log and writing into the shared
    # themes export while it was at it.
    printf '\033[2m[dry-run] would run: php artisan test --compact (~10 min)\033[0m\n'
    TEST_RC=0
    TEST_LOG=/dev/null
  else
    # 0640, app-owned, created BEFORE tee opens it. tee runs as root (only the
    # left of the pipe is sudo -u), so the file used to be created 0644
    # root-owned and chowned afterwards — and Pest failure output carries
    # exception messages, stack traces and, on a PDO failure, the DSN.
    install -o "$APP_USER" -g "$APP_GROUP" -m 0640 /dev/null "$TEST_LOG"

    # env -i, then the pins set EXPLICITLY rather than relying on phpunit.xml.
    # PHPUnit's <env> does not override an inherited variable, so the file alone
    # is not a guarantee; an empty environment plus these values is.
    #
    # FILESYSTEM_DISK is pinned because phpunit.xml does not pin it and the
    # node's own value is `local`, whose root is storage/app/private — an NFS
    # bind shared with the other node. Without this the suite writes production
    # shared storage.
    #
    # APP_MAINTENANCE_DRIVER=cache is what makes the suite immune to the
    # maintenance mode entered in step 3.
    set +e
    sudo -u "$APP_USER" env -i \
      HOME="$APP_HOME" \
      PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin \
      TERM="${TERM:-dumb}" \
      APP_ENV=testing \
      APP_MAINTENANCE_DRIVER=cache \
      DB_CONNECTION=sqlite DB_DATABASE=:memory: \
      FILESYSTEM_DISK=testing \
      CACHE_STORE=array SESSION_DRIVER=array QUEUE_CONNECTION=sync \
      sh -c "cd '$APP_ROOT' && exec php -d memory_limit=1G -d max_execution_time=0 \
       -d max_input_time=-1 artisan test --compact" 2>&1 | tee -a "$TEST_LOG"
    TEST_RC=${PIPESTATUS[0]}
    set -e
  fi

  TEST_MINS=$(( (SECONDS - TEST_START) / 60 ))
  TEST_SECS=$(( (SECONDS - TEST_START) % 60 ))

  if ! $DRY_RUN; then
    THEME_SHARE_AFTER=$(find "$APP_ROOT/resources/themes" -maxdepth 1 -mindepth 1 2>/dev/null | sort)
    if [[ "$THEME_SHARE_BEFORE" != "$THEME_SHARE_AFTER" ]]; then
      warn "the test run left entries in the SHARED resources/themes export:"
      comm -13 <(printf '%s\n' "$THEME_SHARE_BEFORE") <(printf '%s\n' "$THEME_SHARE_AFTER") \
        | sed 's/^/    /'
      warn "remove them by hand before continuing; both nodes see them."
    fi

    # One log per deploy accumulates forever otherwise.
    ls -1t "${APP_ROOT}"/storage/logs/deploy-tests-*.log 2>/dev/null \
      | tail -n +11 | xargs -r rm -f
  fi

  # ── Summary ───────────────────────────────────────────────────────────────
  # Nothing to summarise on a dry run: no suite was executed and TEST_LOG is
  # /dev/null, so every grep below would report a crash that never happened.
  if ! $DRY_RUN; then
  printf '\n\033[1m──────────────── TEST SUMMARY ────────────────\033[0m\n'
  printf 'duration : %dm %ds\n' "$TEST_MINS" "$TEST_SECS"
  printf 'log      : %s\n\n' "$TEST_LOG"

  # The runner's own tallies, rather than a count reconstructed here — the
  # "Tests:" line is authoritative and already accounts for skipped, incomplete
  # and risky outcomes that a naive grep would misreport.
  if grep -qE '^\s*Tests:' "$TEST_LOG"; then
    grep -E '^\s*(Tests|Duration|Parallel):' "$TEST_LOG" | tail -5
  else
    warn "no summary line — the runner did not finish (crash, fatal error, or"
    warn "it never started; check the top of the log)"
    head -20 "$TEST_LOG" | sed 's/^/    /'
  fi

  FAILED_LINES=$(grep -E '(⨯|✕|FAIL(ED)?\s)' "$TEST_LOG" 2>/dev/null || true)
  if [[ -n "$FAILED_LINES" ]]; then
    FAILED_COUNT=$(printf '%s\n' "$FAILED_LINES" | grep -cE '⨯|✕' || true)
    printf '\n\033[1;31mFailures (%s):\033[0m\n' "${FAILED_COUNT:-?}"
    printf '%s\n' "$FAILED_LINES" | head -40 | sed 's/^/  /'
    total_failed=$(printf '%s\n' "$FAILED_LINES" | wc -l | tr -d ' ')
    (( total_failed > 40 )) && printf '  ... %d more, see %s\n' "$(( total_failed - 40 ))" "$TEST_LOG"
  fi
  printf '\033[1m──────────────────────────────────────────────\033[0m\n\n'
  fi

  # ── Decision ──────────────────────────────────────────────────────────────
  if $DRY_RUN; then
    ok "test gate skipped (--dry-run)"
  elif (( TEST_RC == 0 )); then
    ok "test suite passed in ${TEST_MINS}m ${TEST_SECS}s"
  else
    warn "TEST SUITE FAILED (exit ${TEST_RC})"
    warn ""
    warn "Nothing has been migrated and no cache has been rebuilt. php-fpm has"
    warn "not been reloaded, so opcache is still serving the PREVIOUS release —"
    warn "this node is currently unaffected by the new code."
    warn ""
    warn "Continuing runs migrations and reloads php-fpm. Migrations are the"
    warn "part that is not simply undone by checking out the old commit."

    if $TESTS_ADVISORY; then
      warn "--tests-advisory given: continuing despite failures"
    elif [[ ! -t 0 ]]; then
      die "test failures, and no terminal to ask on (non-interactive run).
       Re-run with --tests-advisory to proceed anyway, or --skip-tests."
    else
      printf '\n'
      read -r -p "Continue the deploy anyway? [y/N] " tests_answer
      if [[ "$tests_answer" != [yY] ]]; then
        die "aborted on test failures.

       Nothing was migrated. To go back to the previous release on this node,
       redeploy its tag — do NOT use 'git reset --hard'. reset restores TRACKED
       paths, and resources/themes is both tracked and an NFS bind mount, so it
       would put shipped themes over admin-uploaded ones on the shared export.
       That is the same hazard as the 'git clean' this script refuses.

           git -c safe.directory=${APP_ROOT} -C ${APP_ROOT} tag --sort=-creatordate | head
           bash 04-deploy.sh --ref <previous-tag> --skip-tests

       Full output: ${TEST_LOG}"
      fi
      warn "continuing at operator request despite ${FAILED_COUNT:-some} failures"
    fi
  fi

  # Strip dev dependencies again so they never reach a serving node.
  if $DO_COMPOSER; then
    log "    removing dev dependencies"
    as_app_env "composer install --working-dir='$APP_ROOT' --no-dev --optimize-autoloader --no-interaction --prefer-dist"
  else
    warn "dev dependencies remain installed (--skip-composer given with --with-tests)"
  fi

  # `artisan test` clears the config cache; step 8 rebuilds it.
  reown
else
  warn "test suite SKIPPED — nothing verified this release on this node"
fi

# ═════════════════════════════════════════════════════════════════════════════
log "7/10 Database"
# ═════════════════════════════════════════════════════════════════════════════

if $PRIMARY; then
  # --isolated takes a lock in the cache store (Redis, shared by every node)
  # for the duration. If a second node is given --primary at the same moment it
  # exits without migrating rather than racing.
  #
  # This matters because MySQL DDL is not transactional: two concurrent migrate
  # runs can both read the same pending list, both apply a migration, and leave
  # a half-applied schema that neither rolls back nor records.
  #
  # Run sequentially it is a no-op anyway — the second run finds every migration
  # already recorded. The lock only guards the simultaneous case.
  as_app "php '$APP_ROOT/artisan' migrate --force --isolated"

  # Theme assets, primary only, right after migrations.
  #
  # With THEME_ASSETS_SERVE_PUBLISHED=true the site serves theme CSS/JS from
  # storage/app/public/theme-dist/{slug}/{buildId}/, and the build id is a digest
  # of the theme tree — so a release that changes a shipped theme's assets
  # produces a NEW build id with no directory behind it. The nginx location
  # answers =404 by design and never falls through to PHP, so the site renders
  # unstyled with nothing in any log explaining it.
  #
  # Idempotent (digest-addressed) and the tree is shared, so one node does it.
  if grep -qE '^THEME_ASSETS_SERVE_PUBLISHED=true' "$APP_ROOT/.env" 2>/dev/null; then
    as_app "php '$APP_ROOT/artisan' theme:publish-assets --all"
    ok "published theme assets materialised (shared tree, primary only)"
  fi
else
  ok "skipped (not primary) — migrations belong to exactly one node"
fi

# ═════════════════════════════════════════════════════════════════════════════
log "8/10 Ownership, SELinux, storage link"
# ═════════════════════════════════════════════════════════════════════════════

# Sweep the whole tree so nothing composer, npm or git left behind is misowned —
# but -xdev keeps find on this filesystem, so it never descends into the three
# NFS binds. chown across NFS is slow, may be refused by ID squashing, and is
# pointless: the share already carries correct ownership.
#
# Only misowned paths are touched, so the common case does no writes at all.
run "find '$APP_ROOT' -xdev \\( ! -user '$APP_USER' -o ! -group '$APP_GROUP' \\) \
      -exec chown '$APP_USER':'$APP_GROUP' {} + 2>/dev/null || true"

# Same -xdev discipline as the chown above, and for the same reason. This was a
# bare `chmod -R` on storage/, which descends into storage/app/public and
# storage/app/private — the two NFS binds holding every tenant media file and
# every public-form attachment. On a real media tree that is minutes to hours of
# NFS metadata traffic INSIDE the maintenance window, it marks every one of
# those files group-writable where it succeeds, and where root_squash refuses it
# (the recommended export setting) it fails silently per file behind
# 2>/dev/null, so "did nothing" and "rewrote 400,000 files" look identical.
run "find '$APP_ROOT/storage' '$APP_ROOT/bootstrap/cache' -xdev \
      \\( -type d -exec chmod u+rwx,g+rwx {} + -o -type f -exec chmod u+rw,g+rw {} + \\) \
      2>/dev/null || true"

# -x stops restorecon crossing filesystem boundaries. Without it, it still walks
# the whole NFS tree to discover it cannot label it.
run "restorecon -R -x '$APP_ROOT' >/dev/null 2>&1 || true"

# Node-local symlink into the shared target; each node needs its own.
if [[ ! -L "$APP_ROOT/public/storage" ]]; then
  as_app "php '$APP_ROOT/artisan' storage:link"
elif ! $DRY_RUN; then
  # Never clobbered (no --force anywhere in this repository), but a symlink
  # pointing at the WRONG target was previously never noticed either — and it
  # serves 404s for every uploaded file with the link plainly present.
  [[ "$(readlink -f "$APP_ROOT/public/storage")" == "$(readlink -f "$APP_ROOT/storage/app/public")" ]] || \
    warn "public/storage points at $(readlink -f "$APP_ROOT/public/storage"), not storage/app/public.
       Tenant media will 404. Remove the link and re-run:
           rm $APP_ROOT/public/storage && sudo -u $APP_USER php $APP_ROOT/artisan storage:link"
fi

# ═════════════════════════════════════════════════════════════════════════════
log "9/10 Caches"
# ═════════════════════════════════════════════════════════════════════════════

# The only place caches are built. Everything before this point runs uncached on
# purpose: artisan reads config through env() when no cache file exists, which is
# what lets phpunit.xml govern the test run.
#
# Each command is a real gate. config:cache fails on a config file that throws or
# holds a closure; route:cache fails on duplicate route names or a closure-based
# route; view:cache fails on a Blade syntax error. Any of those aborts the deploy
# here, before php-fpm is reloaded — so opcache is still serving the previous
# release and the node stays functional while you fix it.
as_app "php '$APP_ROOT/artisan' config:clear"

as_app "php '$APP_ROOT/artisan' config:cache"
ok "config cached"

as_app "php '$APP_ROOT/artisan' route:cache"
ok "routes cached"

as_app "php '$APP_ROOT/artisan' view:cache"
ok "views cached"

as_app "php '$APP_ROOT/artisan' event:cache"
ok "events cached"

# Written by artisan running as the app user, but re-assert it: a cache file
# owned by anyone else makes php-fpm fail to read it on the next request.
reown

# ═════════════════════════════════════════════════════════════════════════════
log "10/10 Restart services"
# ═════════════════════════════════════════════════════════════════════════════

# opcache.validate_timestamps=0 — without this reload the new code is invisible.
run "systemctl reload php-fpm"

# nginx configuration is owned by stage 2 and is not touched by a deploy, so
# this reload changes nothing. Kept only so a hand-edited vhost is picked up
# rather than sitting unloaded — a deploy cannot fix an nginx problem.
run "systemctl reload nginx"

# govexy-meter-ingest is deliberately NOT signalled. It is Type=oneshot, so each
# fire of the timer starts a fresh PHP process and picks up the new code by
# itself. Nothing to restart here.

# Workers hold the old bytecode for the life of the process; signal them to exit
# and be respawned. Harmless if no worker is running on this node.
# Plain queue workers poll this flag and exit after their current job.
as_app "php '$APP_ROOT/artisan' queue:restart || true"

# Horizon holds the old bytecode for the life of its master process, so a deploy
# that skips this leaves the node serving new code while processing jobs with the
# old — the kind of split that produces errors nobody can reproduce.
#
# horizon:terminate stops the master once in-flight jobs finish; systemd's
# Restart=always brings it back on the new code. Both unit names are checked
# because 05-configure-workers.sh installs govexy-horizon.service while some
# hosts use the conventional horizon.service.
for unit in govexy-horizon horizon; do
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    as_app "php '$APP_ROOT/artisan' horizon:terminate || true"
    ok "signalled ${unit} to restart on the new code"
    HORIZON_UNIT="$unit"
    break
  fi
done
[[ -n "${HORIZON_UNIT:-}" ]] || \
  warn "no Horizon service running on this node — queued jobs are not processed here"

# The scheduler needs nothing: cron invokes 'artisan schedule:run' fresh every
# minute, so it picks up new code on its next tick without any signal.
if [[ ! -f /etc/cron.d/govexy-scheduler ]]; then
  warn "no scheduler cron entry on this node (expected on all but one node)"
fi

as_app "php '$APP_ROOT/artisan' up"
MAINT_ON=false
# No `trap - ERR` here: the trap installed above is on EXIT, deliberately (see
# the comment beside cleanup()), and removing a trap that was never installed
# only reads as if one had been.

# ─────────────────────────────────────────────────────────────────────────────
log "Verify"
# ─────────────────────────────────────────────────────────────────────────────

$DRY_RUN && { log "dry run complete"; exit 0; }

FINAL_RC=0

# The status code used to be printed and discarded, so a deploy that ended with
# /up returning 500 still exited 0 — and any `for node in ...` loop took that as
# success and broke the second node too.
#
# Localhost with the node's own hostname as the Host header: the vhost is a
# catch-all, but the application resolves the tenant from the host, so a bare IP
# is not what a real request looks like.
UP_CODE=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 20 \
  -H "Host: $(hostname -f 2>/dev/null || hostname)" http://127.0.0.1/up || echo 000)
printf 'up      : %s\n' "$UP_CODE"
if [[ "$UP_CODE" != "200" ]]; then
  warn "/up returned ${UP_CODE} — this node is NOT healthy. Do not deploy the next node."
  FINAL_RC=1
fi

# Written after a healthy deploy so the other nodes can compare against a known
# good .env rather than against whatever this node happened to have mid-run.
if $PRIMARY && (( FINAL_RC == 0 )) && [[ -n "${ENV_FINGERPRINT:-}" ]]; then
  install -o "$APP_USER" -g "$APP_GROUP" -m 0640 /dev/null "$ENV_FINGERPRINT_FILE"
  printf '%s\n' "$ENV_FINGERPRINT" > "$ENV_FINGERPRINT_FILE"
  chown "$APP_USER":"$APP_GROUP" "$ENV_FINGERPRINT_FILE" 2>/dev/null || true
fi

printf 'ref     : %s\n' "${DEPLOY_REF:-<tracked branch HEAD>}"
git -c safe.directory="$APP_ROOT" -C "$APP_ROOT" log -1 --pretty='commit  : %H %s' 2>/dev/null || true

if [[ -n "${HORIZON_UNIT:-}" ]]; then
  sleep 3
  printf 'horizon : '
  systemctl is-active "$HORIZON_UNIT" 2>/dev/null || true
fi

cat <<DONE

────────────────────────────────────────────────────────────────────────────
Deploy complete on $(hostname).

/up boots the framework and runs the application's health checks, so it fails
when PHP-FPM, MySQL or Redis are down. It is the ONLY endpoint the load balancer
should check — an nginx-only check answers 200 on a node whose PHP is dead.

Repeat on every other node WITHOUT --primary, with the SAME --ref. Take them one
at a time so the load balancer always has a healthy member.

    bash 04-deploy.sh --ref ${DEPLOY_REF:-<tag>}

Rollback is a redeploy of the previous tag on every node:

    bash 04-deploy.sh --ref <previous-tag> --primary   (then the others)

Migrations are NOT reversed by that — which is why every migration must be
backward compatible with the release before it (expand/contract).

If /up is not 200:
    tail -50 $APP_ROOT/storage/logs/laravel-\$(date +%Y-%m-%d).log
    tail -30 /var/log/nginx/govexy-error.log
    tail -30 /var/log/php-fpm/www-error.log
────────────────────────────────────────────────────────────────────────────
DONE

# Non-zero when /up did not answer 200, so a wrapper or a for-loop over nodes
# stops here instead of breaking the next node too. Set rather than die()d, so
# the banner above with the log paths still prints.
exit "$FINAL_RC"
