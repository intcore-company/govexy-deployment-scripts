#!/usr/bin/env bash
#
# GovExy web node — STAGE 5: scheduler and queue workers
#
# Provisioning, not per-deploy. Run once per node.
#
#   Scheduler     -> /etc/cron.d/govexy-scheduler, every minute
#   Horizon       -> systemd unit govexy-horizon.service
#   Meter ingest  -> systemd timer govexy-meter-ingest.timer, every 60 s
#
# Usage:
#   bash 05-configure-workers.sh --scheduler --horizon --meter-ingest   primary node
#   bash 05-configure-workers.sh --horizon --meter-ingest               every other node
#   bash 05-configure-workers.sh --status                 report, change nothing
#   bash 05-configure-workers.sh --remove                 tear them all down
#
# Three jobs, three different node rules. They live in one script because that is
# where an operator looks for "what periodic work runs on this box", and because
# splitting them is how a node ends up with Horizon and no meter ingest.
#
# THE SCHEDULER RUNS ON EXACTLY ONE NODE.
#
#   Laravel's scheduler has no cross-host lock. `withoutOverlapping()` uses the
#   cache, which IS shared via Redis here, so the daily metering and billing jobs
#   would be protected — but the entries without it are not. Running it on two
#   nodes fires workflow:process-scheduled twice a minute, and every workflow
#   whose trigger has fired executes twice: two emails, two record updates, two
#   runs in the history.
#
# HORIZON RUNS ON AS MANY NODES AS YOU WANT.
#
#   Queue workers are pull-based. Several nodes competing for the same Redis
#   queue is the normal way to scale, and no job is delivered twice.
#
# THE METER INGEST RUNS ON EVERY NODE. It is the counter-example to the rule
# above, and the reason both rules are stated in the same file.
#
#   Each node has its OWN nginx meter log on its OWN local disk and its OWN
#   cursor row. Laravel's scheduler runs on one node and has no cross-host lock,
#   so scheduling the ingest would drain one node's log and leave the other's
#   growing until logrotate threw it away — bytes lost permanently, with no
#   symptom anywhere. Ingest is inherently per-node work, so it gets a per-node
#   timer rather than a scheduler entry.
#
#   Nothing is double-counted by running it everywhere: a node only ever reads
#   its own log, and the cursor advance is committed in the same transaction as
#   the increments.
#
# systemd rather than supervisor: it is already installed and already how nginx
# and php-fpm are managed on this box, so there is one service manager to learn,
# one log destination (journalctl), and no EPEL dependency. Supervisor would
# work equally well if the estate standardises on it.

set -euo pipefail

DO_SCHEDULER=false
DO_HORIZON=false
DO_METER=false
DO_STATUS=false
DO_REMOVE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scheduler) DO_SCHEDULER=true ;;
    --horizon)   DO_HORIZON=true ;;
    --meter-ingest) DO_METER=true ;;
    --status)    DO_STATUS=true ;;
    --remove)    DO_REMOVE=true ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
  shift
done

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="/var/www/govexy"
[[ -f "${SCRIPT_DIR}/govexy-node.conf" ]] && \
  APP_ROOT=$(grep -E '^APP_ROOT=' "${SCRIPT_DIR}/govexy-node.conf" | head -1 \
             | cut -d= -f2- | tr -d '"' | awk '{print $1}' || true)
APP_ROOT="${APP_ROOT:-/var/www/govexy}"

[[ -d "$APP_ROOT" ]] || die "application root not found: $APP_ROOT"
APP_USER=$(stat -c '%U' "$APP_ROOT")
APP_GROUP=$(stat -c '%G' "$APP_ROOT")
# `command -v` failing inside a command substitution does NOT abort under set -e
# — the assignment succeeds with an empty value. Every generated unit then
# carries "ExecStart= /var/www/govexy/artisan horizon", which systemd rejects at
# daemon-reload with a message about an absolute path, a long way from the cause.
PHP_BIN=$(command -v php || true)
[[ -x "$PHP_BIN" ]] || die "php is not on root's PATH — run 01-install-dependencies.sh first"

CRON_FILE="/etc/cron.d/govexy-scheduler"
UNIT_FILE="/etc/systemd/system/govexy-horizon.service"
MOUNTWAIT_SERVICE="/etc/systemd/system/govexy-horizon-mountwait.service"
MOUNTWAIT_TIMER="/etc/systemd/system/govexy-horizon-mountwait.timer"
METER_SERVICE="/etc/systemd/system/govexy-meter-ingest.service"
METER_TIMER="/etc/systemd/system/govexy-meter-ingest.timer"
METER_FAILURE="/etc/systemd/system/govexy-meter-ingest-failure.service"

# ─────────────────────────────────────────────────────────────────────────────
if $DO_STATUS; then
  log "Scheduler"
  if [[ -f "$CRON_FILE" ]]; then
    ok "cron entry present"
    sed -n '/artisan schedule:run/p' "$CRON_FILE" | sed 's/^/    /'
    printf '    last runs:\n'
    grep -h 'schedule:run' /var/log/cron 2>/dev/null | tail -3 | sed 's/^/      /' || \
      printf '      (nothing in /var/log/cron yet)\n'
  else
    warn "no cron entry — scheduled tasks are NOT running on this node"
  fi

  log "Horizon"
  if [[ -f "$UNIT_FILE" ]]; then
    systemctl status govexy-horizon --no-pager -n 5 || true

    # The specific failure worth naming: Horizon requires the three shared
    # mounts, the fstab entries carry nofail, and systemd does not retry a
    # failed start job. An NFS server down at boot therefore leaves Horizon
    # permanently failed long after the mounts come back.
    if ! systemctl is-active --quiet govexy-horizon; then
      missing=()
      for m in "$APP_ROOT/storage/app/public" "$APP_ROOT/storage/app/private" \
               "$APP_ROOT/resources/themes"; do
        findmnt -rn "$m" &>/dev/null || missing+=("$m")
      done
      if (( ${#missing[@]} > 0 )); then
        warn "Horizon is not running and these shared mounts are ABSENT:"
        printf '      %s\n' "${missing[@]}"
        warn "That is why it will not start. Fix the mounts:  mount -a"
      else
        warn "Horizon is not running but all three mounts are present."
        warn "If the node booted while NFS was down, systemd failed the start job"
        warn "and does not retry. Clear it and start:"
        warn "    systemctl reset-failed govexy-horizon && systemctl start govexy-horizon"
      fi
    fi

    if [[ -f "$MOUNTWAIT_TIMER" ]]; then
      systemctl is-active --quiet govexy-horizon-mountwait.timer \
        && ok "mount-wait timer active (recovers Horizon after an NFS outage)" \
        || warn "mount-wait timer is NOT active — Horizon will not self-recover"
    else
      warn "no mount-wait timer — re-run with --horizon to install it"
    fi
  else
    warn "no systemd unit — queued jobs are NOT processed on this node"
  fi

  log "Bandwidth meter ingest"
  if [[ -f "$METER_TIMER" ]]; then
    systemctl status govexy-meter-ingest.timer --no-pager -n 3 || true
    printf '    last run:\n'
    journalctl -u govexy-meter-ingest.service -n 3 --no-pager 2>/dev/null | sed 's/^/      /' || true
    printf '    cursor row:\n'
    sudo -u "$APP_USER" "$PHP_BIN" "$APP_ROOT/artisan" tinker --execute='
      $n = config("metering.bandwidth.node_id") ?: gethostname();
      $c = Illuminate\Support\Facades\DB::table("metering_log_cursors")->where("node", $n)->first();
      echo $c ? "      {$c->node}  offset={$c->offset}  lag={$c->lag_bytes}  lines={$c->lines_ingested}  skipped={$c->bytes_skipped}  last_run={$c->last_run_at}\n"
               : "      no cursor row for {$n} — ingest has never completed here\n";
    ' 2>/dev/null || warn "could not read the cursor row"
  else
    warn "no timer — this node's meter log is NOT being drained and will rotate away unread"
  fi

  log "Queue depth (shared across nodes)"
  sudo -u "$APP_USER" "$PHP_BIN" "$APP_ROOT/artisan" horizon:status 2>/dev/null || \
    warn "horizon:status failed — check Redis connectivity"
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
if $DO_REMOVE; then
  log "Removing scheduler and Horizon"
  # The logrotate fragment goes with the cron entry. Left behind, logrotate
  # warns about a missing file forever.
  rm -f "$CRON_FILE" /etc/logrotate.d/govexy-scheduler && ok "cron entry removed"
  if [[ -f "$UNIT_FILE" ]]; then
    systemctl disable --now govexy-horizon-mountwait.timer 2>/dev/null || true
    systemctl disable --now govexy-horizon 2>/dev/null || true
    rm -f "$UNIT_FILE" "$MOUNTWAIT_SERVICE" "$MOUNTWAIT_TIMER"
    # The operator hold as well: left behind, it silently suppresses the NEXT
    # install's recovery timer for the rest of the boot.
    rm -f /run/govexy-horizon.hold
    systemctl daemon-reload
    ok "Horizon unit and its mount-wait timer removed"
  fi
  if [[ -f "$METER_TIMER" ]]; then
    systemctl disable --now govexy-meter-ingest.timer 2>/dev/null || true
    rm -f "$METER_TIMER" "$METER_SERVICE" "$METER_FAILURE"
    systemctl daemon-reload
    ok "meter ingest timer removed"
    warn "This node's meter log is no longer drained. Its unread tail is lost at the next rotation."
  fi
  exit 0
fi

$DO_SCHEDULER || $DO_HORIZON || $DO_METER || die "nothing to do.

       bash 05-configure-workers.sh --scheduler --horizon --meter-ingest   (one node)
       bash 05-configure-workers.sh --horizon --meter-ingest               (the others)
       bash 05-configure-workers.sh --status"

# ─────────────────────────────────────────────────────────────────────────────
log "Pre-flight"
# ─────────────────────────────────────────────────────────────────────────────

[[ -f "$APP_ROOT/.env" ]] || die ".env missing at $APP_ROOT/.env"

# The scheduler is a property of the NODE, not of the command line. Reading the
# role from govexy-node.conf makes "which node runs it" a committed, diffable
# fact rather than a flag someone remembers to pass — the warning below was the
# only thing standing between an estate and every workflow running twice.
if $DO_SCHEDULER; then
  # Empty first, "secondary" as the fallback — the same shape as 04-deploy.sh.
  # Initialised to "primary" this guard failed OPEN: a missing conf kept the
  # initial value, the check passed, and any node could become a second
  # scheduler — the exact estate-wide double-fire this file exists to prevent.
  NODE_ROLE_CFG=""
  [[ -f "${SCRIPT_DIR}/govexy-node.conf" ]] && \
    NODE_ROLE_CFG=$(grep -E '^NODE_ROLE=' "${SCRIPT_DIR}/govexy-node.conf" 2>/dev/null \
                    | head -1 | cut -d= -f2- | tr -d '"' | awk '{print $1}' || true)
  NODE_ROLE_CFG="${NODE_ROLE_CFG:-secondary}"

  [[ "$NODE_ROLE_CFG" == "primary" ]] || die "NODE_ROLE is '${NODE_ROLE_CFG}' in govexy-node.conf.

       The scheduler belongs on the primary node only. Laravel's scheduler has
       no cross-host lock, so a second copy fires workflow:process-scheduled
       twice a minute and every triggered workflow executes twice.

       Install Horizon and the meter ingest here instead:
           bash 05-configure-workers.sh --horizon --meter-ingest"

  # 05 restarts crond under set -e. On a minimal RHEL 9 install cronie is not
  # present, so the cron file was written and the script then died — leaving a
  # node that looks configured and runs no scheduled work at all.
  command -v crond >/dev/null 2>&1 || die "cronie is not installed — the scheduler cannot run.

       dnf -y install cronie && systemctl enable --now crond
       (01-install-dependencies.sh installs it.)"
fi

# Horizon needs Redis. Fail here rather than leaving a service that restart-loops.
if $DO_HORIZON; then
  if ! sudo -u "$APP_USER" "$PHP_BIN" "$APP_ROOT/artisan" tinker \
        --execute='Illuminate\Support\Facades\Redis::connection()->ping();' &>/dev/null; then
    die "cannot reach Redis with the settings in .env.

       Horizon would start and immediately restart-loop. Check REDIS_HOST,
       REDIS_PORT and REDIS_PASSWORD, then:
           sudo -u $APP_USER php $APP_ROOT/artisan tinker \\
             --execute='dd(Illuminate\\Support\\Facades\\Redis::connection()->ping());'"
  fi
  ok "Redis reachable"

  grep -qE '^QUEUE_CONNECTION=redis' "$APP_ROOT/.env" || \
    warn "QUEUE_CONNECTION is not redis in .env — Horizon only manages redis queues"
fi

printf '\nnode      : %s\n' "$(hostname)"
printf 'app root  : %s (%s)\n' "$APP_ROOT" "$APP_USER"
printf 'scheduler : %s\n' "$DO_SCHEDULER"
printf 'horizon   : %s\n' "$DO_HORIZON"
printf 'meter     : %s\n' "$DO_METER"

if $DO_METER; then
  METER_LOG_DIR_CFG="/var/log/govexy-meter"
  [[ -f "${SCRIPT_DIR}/govexy-node.conf" ]] && \
    METER_LOG_DIR_CFG=$(grep -E '^METER_LOG_DIR=' "${SCRIPT_DIR}/govexy-node.conf" | head -1 \
                        | cut -d= -f2- | tr -d '"' | awk '{print $1}' || true)
  METER_LOG_DIR_CFG="${METER_LOG_DIR_CFG:-/var/log/govexy-meter}"

  # A node whose identity is not stable across reboots and reimages shares a
  # cursor row with another node, and two nodes fighting over one offset lose
  # data. Derived from the hostname when unset, which is fine as long as the
  # hostname is stable — say so rather than assume it.
  if ! grep -qE '^METERING_NODE_ID=..*' "$APP_ROOT/.env"; then
    warn "METERING_NODE_ID is not set in .env — the ingest will use the hostname ($(hostname))."
    warn "That is only safe if the hostname is stable across reboots AND distinct from every other node."
  fi

  METER_NODE_ID=$(grep -E '^METERING_NODE_ID=..*' "$APP_ROOT/.env" | head -1 | cut -d= -f2- | tr -d '"'"'"' ')
  METER_NODE_ID="${METER_NODE_ID:-$(hostname)}"

  # Both watchdogs are OFF unless configured, and both used to be off silently.
  # Neither of these is written by this script — it configures the node, not the
  # application — so they are verified here and reported, loudly, when absent.
  if ! grep -qE '^METERING_NODES=..*' "$APP_ROOT/.env"; then
    warn "METERING_NODES is not set in .env."
    warn "    metering:check-edge-health has no fleet to check: it now raises a"
    warn "    critical alert and exits non-zero rather than reporting green, but"
    warn "    until it is set NOTHING tells you a node stopped billing."
    warn "    Set it on EVERY node to the full list, comma separated, e.g."
    warn "        METERING_NODES=web01,web02"
  elif ! grep -E '^METERING_NODES=' "$APP_ROOT/.env" | grep -qw -- "$METER_NODE_ID"; then
    warn "METERING_NODES does not list this node ($METER_NODE_ID)."
    warn "    A node absent from that list is never checked, and a stopped ingest"
    warn "    on it is invisible. Add it on every node."
  fi

  if ! grep -qE '^METERING_TX_INTERFACE=..*' "$APP_ROOT/.env"; then
    warn "METERING_TX_INTERFACE is not set in .env."
    warn "    That is the only cross-check reading something the metering pipeline"
    warn "    did not write itself. Without it a hole in the meter has no"
    warn "    independent witness, and metering:cross-check-tx will report this"
    warn "    node as missing its witness every night."
    warn "    Public-facing interfaces on this host:"
    ip -br link show 2>/dev/null | awk '$1 != "lo" {printf "        %s\n", $1}' || true
  fi

  if [[ ! -d "$METER_LOG_DIR_CFG" ]]; then
    die "meter log directory $METER_LOG_DIR_CFG does not exist.

       Run stage 2 first:  bash 02-configure-nginx-php.sh
       Without it there is no log to drain and every run reports zero bytes."
  fi

  # The classic silent-zero failure: the timer runs, the command succeeds, and it
  # reads nothing because the app user was never allowed near the file.
  if ! sudo -u "$APP_USER" test -x "$METER_LOG_DIR_CFG"; then
    die "$APP_USER cannot enter $METER_LOG_DIR_CFG.

       The ingest would report zero bytes forever with no error. Check the
       directory group and mode (nginx:<group> 0750), that $APP_USER is in that
       group, and under enforcing SELinux:  ausearch -m avc -ts recent"
  fi

  if [[ -f "$METER_LOG_DIR_CFG/meter.log" ]] && ! sudo -u "$APP_USER" test -r "$METER_LOG_DIR_CFG/meter.log"; then
    die "$APP_USER cannot read $METER_LOG_DIR_CFG/meter.log — the meter would read zero."
  fi

  ok "meter log readable by $APP_USER"

  printf '\n'
  warn "The meter ingest must run on EVERY node, unlike the scheduler. A node"
  warn "without it silently loses its own bytes at the next logrotate."
fi

if $DO_SCHEDULER; then
  printf '\n'
  warn "The scheduler must run on EXACTLY ONE node. If another node already has"
  warn "it, workflow:process-scheduled fires twice a minute and every triggered"
  warn "workflow executes twice — duplicate emails, duplicate record updates."
  warn "Check the other node with:  bash 05-configure-workers.sh --status"
fi

# read returns non-zero at EOF, and under set -e that terminates the script
# before die() is reached — a run under nohup exited 1 with a blank screen.
read -r -p $'\nProceed? [y/N] ' answer \
  || die "no terminal to confirm on (non-interactive run). Run it under tmux."
[[ "$answer" == [yY] ]] || die "aborted"

# ─────────────────────────────────────────────────────────────────────────────
if $DO_SCHEDULER; then
log "Scheduler"
# ─────────────────────────────────────────────────────────────────────────────

# schedule:run is called every minute and decides internally what is due. That
# single entry covers every task in routes/console.php; there is never more than
# one cron line for a Laravel application.
cat > "$CRON_FILE" <<EOF
# GovExy scheduler — managed by 05-configure-workers.sh
#
# Laravel dispatches every scheduled task from this one entry; schedule:run
# decides internally what is due. Do not add per-task lines.
#
# THIS MUST EXIST ON EXACTLY ONE NODE. Laravel's scheduler has no cross-host
# lock, so a second copy runs everything twice.
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
MAILTO=""

# '|| { ...; exit 1; }' rather than '&&': if APP_ROOT is unmounted or renamed
# the cd fails, an && short-circuits, cron sees exit 0 and MAILTO="" swallows it
# — so scheduled work stops with no trace anywhere. The FATAL goes to the
# JOURNAL via logger, not to scheduler.log: in the only case this branch fires,
# APP_ROOT is gone, so a redirect into it fails along with the cd.
* * * * * ${APP_USER} cd ${APP_ROOT} || { logger -t govexy-scheduler "FATAL: cannot cd to ${APP_ROOT} — scheduled work is NOT running"; exit 1; }; ${PHP_BIN} artisan schedule:run >> ${APP_ROOT}/storage/logs/scheduler.log 2>&1
EOF

chmod 644 "$CRON_FILE"
# Create it only if absent. `install ... /dev/null` TRUNCATES an existing file,
# so re-running this stage threw away the scheduler history — including whatever
# an operator was about to read to find out why a job stopped.
if [[ ! -f "$APP_ROOT/storage/logs/scheduler.log" ]]; then
  install -o "$APP_USER" -g "$APP_GROUP" -m 0664 /dev/null \
    "$APP_ROOT/storage/logs/scheduler.log" 2>/dev/null || true
fi

cat > /etc/logrotate.d/govexy-scheduler <<EOF
${APP_ROOT}/storage/logs/scheduler.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
    su ${APP_USER} ${APP_GROUP}
}
EOF

systemctl restart crond
ok "scheduler installed (every minute, as ${APP_USER})"
fi

# ─────────────────────────────────────────────────────────────────────────────
if $DO_HORIZON; then
log "Horizon"
# ─────────────────────────────────────────────────────────────────────────────

cat > "$UNIT_FILE" <<EOF
[Unit]
Description=GovExy Horizon queue supervisor

# NOT redis.service: Redis is remote on this estate, so there is no such unit
# here and the ordering directive was silently inert.
#
# remote-fs.target plus RequiresMountsFor is the dependency that matters.
# Queued jobs process media, form attachments and themes; a worker that starts
# before the three binds land writes into the empty local directories
# underneath them — the exact failure 03-mount-shared-storage.sh exists to
# prevent for the deploy path, arriving by the queue instead.
After=network-online.target remote-fs.target
Wants=network-online.target
RequiresMountsFor=${APP_ROOT}/storage/app/public ${APP_ROOT}/storage/app/private ${APP_ROOT}/resources/themes

# Restart=always with RestartSec=5 does not trip systemd's default
# StartLimitBurst=5 in a 10 s window — but that is true by arithmetic, not by
# intent. Without this, a future RestartSec change plus a transient Redis outage
# would leave Horizon permanently 'failed' with nothing processing the queue.
StartLimitIntervalSec=0

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${APP_ROOT}
ExecStart=${PHP_BIN} ${APP_ROOT}/artisan horizon

# horizon:terminate (run by the deploy script) makes the master exit cleanly once
# its workers have finished their current jobs. Restart=always is what brings it
# back on the new code — without it, a deploy silently leaves the node with no
# queue worker at all.
Restart=always
RestartSec=5

# SIGTERM reaches Horizon's master, which stops accepting work and waits for
# in-flight jobs. The timeout must exceed the longest job or a deploy kills work
# mid-flight; jobs are then retried, which is only safe if they are idempotent.
KillSignal=SIGTERM
TimeoutStopSec=120

StandardOutput=journal
StandardError=journal
SyslogIdentifier=govexy-horizon

[Install]
WantedBy=multi-user.target
EOF

# ── Mount-wait recovery ──────────────────────────────────────────────────────
#
# RequiresMountsFor= above is the right dependency and it has one sharp edge.
# The fstab bind entries carry `nofail` (03-mount-shared-storage.sh), which is
# deliberate — without it an NFS server that is down at boot drops the node to an
# emergency console. But `nofail` means the mount units are allowed to be absent,
# and RequiresMountsFor= on an absent mount makes Horizon fail its start job.
# Once systemd has failed that job it does not retry: the NFS server comes back
# ten minutes later, the mounts appear, and Horizon stays dead until a human
# notices the queue is not draining.
#
# So the two settings need a third thing between them. This timer looks for all
# three mounts once a minute and starts Horizon when they are all present. It is
# a no-op whenever Horizon is already running, which is the normal case.
#
# A .path unit is the more obvious tool and the wrong one here: PathExists=
# entries are OR-ed, and what has to be true is the AND of all three.
#
# Two escape hatches, because "starts Horizon whenever it is not running" would
# otherwise fight an operator who stopped it on purpose — draining a node,
# debugging a poison job — and win, once a minute:
#
#   systemctl disable govexy-horizon      permanent: is-enabled gates the timer
#   touch /run/govexy-horizon.hold        for this boot only; clears on reboot
#
# --no-block so a Horizon that is slow to start does not hold the timer's own
# start job open and trip TimeoutStartSec on the wrapper rather than on Horizon.
cat > "$MOUNTWAIT_SERVICE" <<EOF
[Unit]
Description=Start GovExy Horizon once the shared mounts are present
Documentation=man:systemd.mount(5)

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'test -e /run/govexy-horizon.hold && exit 0; systemctl is-enabled --quiet govexy-horizon || exit 0; for m in ${APP_ROOT}/storage/app/public ${APP_ROOT}/storage/app/private ${APP_ROOT}/resources/themes; do findmnt -rn "\$m" >/dev/null 2>&1 || exit 0; done; systemctl is-active --quiet govexy-horizon && exit 0; systemctl reset-failed govexy-horizon 2>/dev/null || true; exec systemctl start --no-block govexy-horizon'
EOF

cat > "$MOUNTWAIT_TIMER" <<'EOF'
[Unit]
Description=Check for the GovExy shared mounts and start Horizon, every 60s

[Timer]
OnBootSec=120s
OnUnitActiveSec=60s
AccuracySec=5s
Persistent=false
Unit=govexy-horizon-mountwait.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload

# Horizon FIRST, then the timer — and the timer only once Horizon is confirmed
# up. Enabling the recovery timer before knowing Horizon can start at all means
# a genuinely broken unit (bad .env, no Redis) gets restarted every 60 seconds
# forever, filling the journal and hiding the original failure behind a wall of
# identical start attempts.
# On a RE-RUN the mount-wait timer from a previous run is already active, and it
# would start Horizon underneath the check below — making a unit that cannot
# stay up look healthy for the three seconds this samples, or racing the enable
# outright. Stop it for the duration; it is re-enabled once Horizon is
# confirmed running, which is also what makes the failure message below true.
mountwait_was_active=false
systemctl is-active --quiet govexy-horizon-mountwait.timer && mountwait_was_active=true
systemctl disable --now govexy-horizon-mountwait.timer 2>/dev/null || true

systemctl enable --now govexy-horizon
sleep 3
if systemctl is-active --quiet govexy-horizon; then
  ok "Horizon running"
else
  # Put back what this run temporarily disabled: dying with a previously-active
  # recovery timer left off would remove the node's NFS-outage self-recovery as
  # a side effect of a failed RE-RUN. A first install has nothing to restore,
  # and a genuinely broken unit is not restarted every 60 s by this — the timer
  # was only active if a previous run proved the unit could start.
  $mountwait_was_active && systemctl enable --now govexy-horizon-mountwait.timer 2>/dev/null
  die "Horizon failed to start. Inspect:  journalctl -u govexy-horizon -n 50 --no-pager

       If the message mentions a dependency or a mount, check the three shared
       paths are present — Horizon requires them:
           findmnt ${APP_ROOT}/storage/app/public
           findmnt ${APP_ROOT}/storage/app/private
           findmnt ${APP_ROOT}/resources/themes

       The mount-wait timer is NOT (re)installed while Horizon cannot start, so
       it is not masking anything here. Re-run this stage once the unit is
       healthy."
fi

systemctl enable --now govexy-horizon-mountwait.timer
ok "mount-wait timer installed (recovers Horizon after an NFS outage at boot)"
ok "    to stop it restarting Horizon: touch /run/govexy-horizon.hold"
fi

# ─────────────────────────────────────────────────────────────────────────────
if $DO_METER; then
log "Bandwidth meter ingest"
# ─────────────────────────────────────────────────────────────────────────────

cat > "$METER_SERVICE" <<EOF
[Unit]
Description=GovExy edge bandwidth meter ingest (this node)
Documentation=https://github.com/intcore-company/govexy-docs
After=network-online.target remote-fs.target nginx.service
Wants=network-online.target

# Same reason as the Horizon unit: the ingest boots the framework, which reads
# and writes under the shared paths.
RequiresMountsFor=${APP_ROOT}/storage/app/public ${APP_ROOT}/storage/app/private ${APP_ROOT}/resources/themes

# A run that fails FAST must not be mistaken for a run that never started. The
# command records its own failure on the cursor row when it can reach the
# database; this covers the case where it cannot even boot.
OnFailure=govexy-meter-ingest-failure.service

[Service]
Type=oneshot
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${APP_ROOT}
ExecStart=${PHP_BIN} ${APP_ROOT}/artisan metering:ingest-edge

# One run drains from the durable cursor and commits. If it is killed partway,
# nothing was committed and the next run replays the identical byte range — so
# there is no cleanup to do and no state to repair.
TimeoutStartSec=300

StandardOutput=journal
StandardError=journal
SyslogIdentifier=govexy-meter-ingest

[Install]
WantedBy=multi-user.target
EOF

cat > "$METER_FAILURE" <<EOF
[Unit]
Description=GovExy meter ingest failure marker

[Service]
Type=oneshot
ExecStart=/usr/bin/logger -p daemon.err -t govexy-meter-ingest "edge bandwidth meter ingest FAILED on $(hostname)"
EOF

cat > "$METER_TIMER" <<'EOF'
[Unit]
Description=GovExy edge bandwidth meter ingest, every 60s

[Timer]
# 60 s is the dominant term in the enforcement-lag budget the plan is costed
# against. Dropping it to 15 s cuts worst-case overshoot roughly 3x at 4x the
# write rate, which is still trivial for MySQL — that is the lever to pull if
# the overshoot arithmetic proves optimistic under real load.
OnBootSec=90s
OnUnitActiveSec=60s
AccuracySec=1s

# Deliberately false. After a long outage the wanted behaviour is the NEXT
# scheduled run, not a thundering catch-up burst across every node at once —
# and the cursor makes catch-up automatic anyway: one run drains the whole
# backlog.
Persistent=false

Unit=govexy-meter-ingest.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload

# ORDER MATTERS, and it is the opposite of what reads naturally.
#
# This used to be `systemctl enable --now` followed by a bare `artisan
# metering:ingest-edge` as a smoke test. `--now` starts the timer, and with
# OnBootSec= long past on an already-running host the timer fires the service
# immediately — so the smoke test ran CONCURRENTLY with a real ingest run, on
# the same node, against the same cursor. That is the one race the pipeline must
# never see: two runs reading one offset and both committing bill the same bytes
# twice.
#
# The application now takes an exclusive row lock on the cursor for the whole
# drain, so the race is refused rather than won. This ordering means the install
# never asks it to: enable the timer WITHOUT starting it, take the smoke test
# through systemd (which will not run a second instance of a unit that is
# already running), and only then start the timer.
systemctl enable govexy-meter-ingest.timer

# Prove the command itself works before trusting the timer: a unit that fails on
# every fire looks identical to a unit that is not installed until someone reads
# the journal. `systemctl start` on a Type=oneshot unit blocks until it exits,
# and exits non-zero if the unit failed.
if systemctl start govexy-meter-ingest.service; then
  systemctl start govexy-meter-ingest.timer
  ok "meter ingest verified, timer started"
else
  warn "the first ingest run FAILED — the timer is enabled but NOT started, so"
  warn "nothing will run until this is fixed and you run:"
  warn "    systemctl start govexy-meter-ingest.timer"
  warn "Inspect:"
  warn "    journalctl -u govexy-meter-ingest -n 50 --no-pager"
fi
fi

# ─────────────────────────────────────────────────────────────────────────────
log "Verify"
# ─────────────────────────────────────────────────────────────────────────────

if $DO_SCHEDULER; then
  printf 'due tasks right now:\n'
  sudo -u "$APP_USER" "$PHP_BIN" "$APP_ROOT/artisan" schedule:list 2>/dev/null | head -12 || true
fi

if $DO_HORIZON; then
  systemctl status govexy-horizon --no-pager -n 3 || true
fi

if $DO_METER; then
  systemctl list-timers govexy-meter-ingest.timer --no-pager || true
fi

cat <<DONE

────────────────────────────────────────────────────────────────────────────
Done on $(hostname).

Watch it work:
    journalctl -u govexy-horizon -f
    tail -f ${APP_ROOT}/storage/logs/scheduler.log
    bash 05-configure-workers.sh --status

Horizon's dashboard is at /horizon on the app domain, gated by the
Horizon::auth gate.

Per node, from here:

  • Horizon on every node. Workers pull from a shared Redis queue, so more
    nodes means more throughput and no job runs twice.

  • The scheduler on ONE node only. If this node dies, scheduled work stops
    until you install the cron entry elsewhere — that is a deliberate
    trade against the duplicate-execution risk, not an oversight.

  • The meter ingest on EVERY node. Each node drains only its own local nginx
    meter log from its own cursor row, so running it everywhere double-counts
    nothing, and running it nowhere loses that node's bytes at the next
    logrotate with no error anywhere. Check with --status on each node.

The ingest owns bandwidth_monthly outright — there is no application-side
counter and no second meter to compare against. A node whose timer is stopped
is not missing telemetry, it is not billing. Check the pipeline with:

    php artisan metering:check-edge-health
    php artisan metering:cross-check-tx

The deploy script already calls queue:restart and horizon:terminate, and
Restart=always brings Horizon back on the new code.
────────────────────────────────────────────────────────────────────────────
DONE
