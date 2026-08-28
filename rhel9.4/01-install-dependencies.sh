#!/usr/bin/env bash
#
# GovExy web node — STAGE 1: dependencies
#
# Installs only. Writes no application configuration; stage 2 does that.
#   - base system packages, timezone, hostname
#   - EPEL + CodeReady Builder
#   - nginx (RHEL AppStream)
#   - Remi repository, pinned for this network
#   - PHP 8.4 + extensions
#   - Composer
#
# Idempotent: safe to re-run.
# Usage:  bash 01-install-dependencies.sh
#
# Network constraints encoded here, discovered on this estate:
#   - plain HTTP to rpms.remirepo.net is dropped; HTTPS works
#         -> every Remi baseurl pinned to https
#   - cdn.remirepo.net (the mirrorlist host) returns 403
#         -> mirrorlist/metalink disabled, single-host baseurl instead
#   - getcomposer.org is TLS-intercepted with an untrusted CA
#         -> the official installer cannot be signature-verified; Composer
#            comes from the distro repos instead. Do not "fix" this with -k.
#   - rhsm-package-profile-uploader holds the dnf lock ~180s after every
#     transaction -> package installs are batched into as few as possible

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=govexy-node.conf
source "${SCRIPT_DIR}/govexy-node.conf"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root"
grep -qi 'release 9' /etc/redhat-release 2>/dev/null || die "expected RHEL 9.x"

# ═════════════════════════════════════════════════════════════════════════════
log "1/7  Base system"
# ═════════════════════════════════════════════════════════════════════════════

[[ -n "$NODE_HOSTNAME" ]] && hostnamectl set-hostname "$NODE_HOSTNAME"
timedatectl set-timezone "$SERVER_TZ"

subscription-manager repos --enable codeready-builder-for-rhel-9-x86_64-rpms || \
  warn "CodeReady Builder enable failed — some Remi dependencies may not resolve"

rpm -q epel-release &>/dev/null || \
  dnf -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm

dnf -y install dnf-plugins-core policycoreutils-python-utils firewalld chrony \
               vim unzip tar git curl
systemctl enable --now chronyd firewalld

# ═════════════════════════════════════════════════════════════════════════════
log "2/7  dnf tolerance for a slow / inspected link"
# ═════════════════════════════════════════════════════════════════════════════

# minrate defaults to 1000 B/s. Through this proxy that threshold is what
# produced "Curl error (28): Operation too slow" on Remi metadata.
for kv in "timeout=300" "minrate=100" "retries=10"; do
  key="${kv%%=*}"
  if grep -qE "^${key}=" /etc/dnf/dnf.conf; then
    sed -i "s|^${key}=.*|${kv}|" /etc/dnf/dnf.conf
  else
    sed -i "/^\[main\]/a ${kv}" /etc/dnf/dnf.conf
  fi
done

# ═════════════════════════════════════════════════════════════════════════════
log "3/7  nginx"
# ═════════════════════════════════════════════════════════════════════════════

dnf -y install nginx
nginx -V 2>&1 | tr ' ' '\n' | grep -q 'realip' || \
  warn "nginx built without http_realip_module — load balancer real-IP will not work"

# Not started here. Stage 2 writes the vhost, then starts it.

# ═════════════════════════════════════════════════════════════════════════════
log "4/7  Remi repository (HTTPS baseurl, mirrorlist disabled)"
# ═════════════════════════════════════════════════════════════════════════════

rpm -q remi-release &>/dev/null || \
  dnf -y install https://rpms.remirepo.net/enterprise/remi-release-9.rpm

# Stock repo files resolve through cdn.remirepo.net, which this network blocks.
# Pin every Remi repo to the one reachable host, HTTPS only.
for f in /etc/yum.repos.d/remi*.repo; do
  [[ "$f" == *.bak ]] && continue
  [[ -f "${f}.bak" ]] || cp -a "$f" "${f}.bak"
  sed -i \
    -e 's|^mirrorlist=|#mirrorlist=|' \
    -e 's|^metalink=|#metalink=|' \
    -e 's|^#baseurl=|baseurl=|' \
    -e 's|^baseurl=http://rpms\.remirepo\.net/|baseurl=https://rpms.remirepo.net/|' \
    "$f"
done

dnf config-manager --set-enabled remi-safe
dnf config-manager --set-enabled remi-modular

dnf clean all
dnf makecache

# ═════════════════════════════════════════════════════════════════════════════
log "5/7  PHP 8.4"
# ═════════════════════════════════════════════════════════════════════════════

# RHEL 9 AppStream tops out at PHP 8.3; this application requires ^8.4.
dnf -y module reset php
dnf -y module enable php:remi-8.4
dnf module list php | grep -q 'remi-8.4 \[e\]' || die "php:remi-8.4 stream not enabled"

PHP_PKGS=(
  php-cli php-fpm php-common php-mbstring php-xml php-gd php-intl
  php-bcmath php-opcache php-mysqlnd php-pdo php-sodium php-process
  php-pecl-zip php-pecl-redis6
)
[[ "$INSTALL_IMAGICK" == "yes" ]] && PHP_PKGS+=(php-pecl-imagick ImageMagick)

# One transaction. Each extra dnf install costs another RHSM uploader wait.
dnf -y install "${PHP_PKGS[@]}"

# ═════════════════════════════════════════════════════════════════════════════
log "6/8  Composer"
# ═════════════════════════════════════════════════════════════════════════════

command -v composer &>/dev/null || dnf -y install composer

# ═════════════════════════════════════════════════════════════════════════════
log "7/8  Node.js"
# ═════════════════════════════════════════════════════════════════════════════

INSTALL_NODE="${INSTALL_NODE:-yes}"
NODE_STREAM="${NODE_STREAM:-22}"

if [[ "$INSTALL_NODE" == "yes" ]]; then
  # Vite 7 requires Node ^20.19 || >=22.12. AppStream's stream 20 currently ships
  # 20.x releases below 20.19 on some minor versions, so 18 and 20 are refused
  # here rather than left to fail at build time with an opaque bundler error.
  case "$NODE_STREAM" in
    22) ;;
    18|20) warn "NODE_STREAM=${NODE_STREAM}: Vite 7 requires Node ^20.19 || >=22.12."
           warn "Stream 22 is the supported choice. Continuing, but 'npm run build'"
           warn "may fail on an engine check." ;;
    *) die "NODE_STREAM must be 18, 20 or 22" ;;
  esac

  dnf -y module reset nodejs
  dnf -y module enable "nodejs:${NODE_STREAM}"
  dnf -y install nodejs npm

  node -v
  npm -v
else
  log "    skipped (INSTALL_NODE=no) — assets must be built off-server"
fi

# ═════════════════════════════════════════════════════════════════════════════
log "8/8  Verification"
# ═════════════════════════════════════════════════════════════════════════════

php -v | head -1 | grep -q 'PHP 8\.4' || die "PHP 8.4 is not the active version"

missing=()
for ext in curl fileinfo intl mbstring redis sodium zip pcntl posix pdo_mysql \
           gd bcmath openssl tokenizer dom xmlwriter exif; do
  php -m | grep -qix "$ext" || missing+=("$ext")
done
(( ${#missing[@]} == 0 )) || warn "extensions missing: ${missing[*]}"

printf '\n'
php -v | head -1
composer --version
nginx -v
if [[ "$INSTALL_NODE" == "yes" ]]; then
  printf 'node %s / npm %s\n' "$(node -v)" "$(npm -v)"
fi

cat <<'DONE'

────────────────────────────────────────────────────────────────────────────
Stage 1 complete — dependencies installed, nothing configured yet.

nginx and php-fpm are installed but NOT started; stage 2 writes their
configuration and starts them.

Next:
    bash 02-configure-nginx-php.sh
────────────────────────────────────────────────────────────────────────────
DONE
