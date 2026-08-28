#!/usr/bin/env bash
#
# GovExy web node — STAGE 4: deploy
#
# Runs on EVERY web node, once per release. Stages 1-3 are provisioning and are
# not repeated here.
#
# Usage:
#   bash 04-deploy.sh --primary        run migrations too (exactly ONE node)
#   bash 04-deploy.sh                  every other node
#
# The Pest suite runs by default and blocks the deploy if it fails. It costs
# about ten minutes of maintenance mode per node, so a hotfix that has already
# been tested elsewhere is a fair reason to pass --skip-tests. A release that
# has not been tested anywhere is not.
#
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
#   Migrations run BEFORE the new code is cached but while other nodes still
#   serve the old code, so every migration must be backward compatible with the
#   release currently running. Adding a column is safe; dropping or renaming one
#   is not, and needs a two-release expand/contract instead.
#
#   php-fpm is reloaded LAST. opcache.validate_timestamps=0 means PHP holds the
#   old bytecode until it is told otherwise — without the reload a deploy
#   appears to do nothing at all.

set -euo pipefail

PRIMARY=false
DO_PULL=true
DO_BUILD=true
DO_COMPOSER=true
# Tests gate the deploy by default. Override per run with --skip-tests, or
# environment-wide with DO_TESTS=false in govexy-node.conf.
DO_TESTS="${DO_TESTS:-true}"
# Do not stop on test failures — report them and carry on. For unattended runs
# where a red suite is a known, accepted state.
TESTS_ADVISORY=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --primary)       PRIMARY=true ;;
    --no-pull)       DO_PULL=false ;;
    --skip-build)    DO_BUILD=false ;;
    --skip-composer) DO_COMPOSER=false ;;
    --with-tests)    DO_TESTS=true ;;
    --skip-tests)    DO_TESTS=false ;;
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
# explicit --with-tests / --skip-tests on the command line still wins, because
# the flags are parsed before this point.
if [[ -f "${SCRIPT_DIR}/govexy-node.conf" ]] && [[ "$DO_TESTS" == "true" ]]; then
  conf_tests=$(grep -E '^DO_TESTS=' "${SCRIPT_DIR}/govexy-node.conf" 2>/dev/null \
               | head -1 | cut -d= -f2- | tr -d '"' | awk '{print $1}')
  [[ "$conf_tests" == "false" ]] && DO_TESTS=false
fi

[[ -d "$APP_ROOT" ]] || die "application root not found: $APP_ROOT"
APP_USER=$(stat -c '%U' "$APP_ROOT")
APP_GROUP=$(stat -c '%G' "$APP_ROOT")

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
    warn "deploy failed (exit ${status}) — lifting maintenance mode"
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

printf '\n'
printf 'node      : %s\n' "$(hostname)"
printf 'app root  : %s (%s:%s)\n' "$APP_ROOT" "$APP_USER" "$APP_GROUP"
printf 'primary   : %s\n' "$PRIMARY"
printf 'pull      : %s\n' "$DO_PULL"
printf 'composer  : %s\n' "$DO_COMPOSER"
printf 'build     : %s\n' "$DO_BUILD"
printf 'tests     : %s\n' "$DO_TESTS"

if $PRIMARY; then
  printf '\n'
  warn "PRIMARY: this node runs migrations. Exactly one node may do so."
fi

if ! $DRY_RUN; then
  read -r -p $'\nProceed? [y/N] ' answer
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

  root_git "fetch --prune"
  root_git "pull --ff-only"
  root_git "log -1 --pretty='%h %s'"

  # git wrote as root; hand the tree back before composer and npm run as the
  # app user and hit permission errors on files they cannot touch.
  reown
else
  ok "skipped (--no-pull)"
fi

# ═════════════════════════════════════════════════════════════════════════════
log "3/10 PHP dependencies"
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
log "4/10 Front-end assets"
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
log "5/10 Test suite"
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
       Install it:  dnf -y install php-pdo"

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

  # memory_limit=-1 and no execution timeout: the suite is long-running and
  # memory-hungry, and the CLI defaults in /etc/php.d/99-govexy.ini are sized
  # for web requests, not for this.
  log "    running the full suite — this takes around 10 minutes"
  TEST_START=$SECONDS

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

  set +e
  sudo -u "$APP_USER" env HOME="$APP_HOME" sh -c \
    "cd '$APP_ROOT' && exec php -d memory_limit=-1 -d max_execution_time=0 \
     -d max_input_time=-1 artisan test --compact" 2>&1 | tee "$TEST_LOG"
  TEST_RC=${PIPESTATUS[0]}
  set -e

  chown "$APP_USER":"$APP_GROUP" "$TEST_LOG" 2>/dev/null || true
  TEST_MINS=$(( (SECONDS - TEST_START) / 60 ))
  TEST_SECS=$(( (SECONDS - TEST_START) % 60 ))

  # ── Summary ───────────────────────────────────────────────────────────────
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

  # ── Decision ──────────────────────────────────────────────────────────────
  if (( TEST_RC == 0 )); then
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

       Nothing was changed. To roll back the working tree to the previous
       release on this node:
           git -c safe.directory=${APP_ROOT} -C ${APP_ROOT} log --oneline -5
           git -c safe.directory=${APP_ROOT} -C ${APP_ROOT} reset --hard <commit>
       then re-run this script with --skip-tests.

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
# ORDER: maintenance mode starts AFTER the test gate, deliberately.
#
# It used to start at step 2, which left storage/framework/maintenance.php on
# disk for the whole test run — so PreventRequestsDuringMaintenance answered
# every HTTP feature test with 503, and the gate reported hundreds of failures
# that were one operational state rather than one bug each.
#
# Downtime is now the migrations, caches and reload — about two minutes — rather
# than that plus the ten the suite takes.
#
# The trade-off, stated plainly: from the composer step until here, the node
# serves requests with the new vendor/ tree while opcache still holds the old
# bytecode. Laravel autoloads lazily, so a request touching a class not yet
# cached reads the new file. That window is the test duration. Take the node out
# of the load balancer first, or deploy with --skip-tests, if a given release
# cannot tolerate it.
# ═════════════════════════════════════════════════════════════════════════════

# ═════════════════════════════════════════════════════════════════════════════
log "6/10 Maintenance mode"
# ═════════════════════════════════════════════════════════════════════════════

# Node-local: storage/framework/maintenance.php is not on the share, so each
# node goes dark only for itself. With a load balancer in front, take nodes one
# at a time and the site stays up.
as_app "php '$APP_ROOT/artisan' down --render='errors::503' --retry=60 || true"
MAINT_ON=true

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

run "chmod -R u+rwX,g+rwX '$APP_ROOT/storage' '$APP_ROOT/bootstrap/cache' 2>/dev/null || true"
run "restorecon -R '$APP_ROOT' >/dev/null 2>&1 || true"

# Node-local symlink into the shared target; each node needs its own.
if [[ ! -L "$APP_ROOT/public/storage" ]]; then
  as_app "php '$APP_ROOT/artisan' storage:link"
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
run "systemctl reload nginx"

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
trap - ERR

# ─────────────────────────────────────────────────────────────────────────────
log "Verify"
# ─────────────────────────────────────────────────────────────────────────────

$DRY_RUN && { log "dry run complete"; exit 0; }

printf 'up      : '
curl -s --noproxy '*' -o /dev/null -w '%{http_code}\n' http://127.0.0.1/up

git -c safe.directory="$APP_ROOT" -C "$APP_ROOT" log -1 --pretty='commit  : %h %s' 2>/dev/null || true

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

Repeat on every other node WITHOUT --primary. Take them one at a time so the
load balancer always has a healthy member.

If /up is not 200:
    tail -50 $APP_ROOT/storage/logs/laravel-\$(date +%Y-%m-%d).log
    tail -30 /var/log/nginx/govexy-error.log
    tail -30 /var/log/php-fpm/www-error.log
────────────────────────────────────────────────────────────────────────────
DONE
