#!/usr/bin/env bash
#
# GovExy web node — STAGE 2: configuration
#
# Assumes stage 1 already installed nginx, PHP 8.4 and Composer.
#   - PHP-FPM pool + runtime ini
#   - nginx http-context settings, vhost, load balancer real-IP trust
#   - application directory + SELinux contexts and booleans
#   - firewalld
#   - starts and verifies both services
#
# Idempotent: safe to re-run.
#
# Usage:
#   bash 02-configure-nginx-php.sh                     full configuration
#   bash 02-configure-nginx-php.sh --set-lb <ip>...    update LB trust only

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=govexy-node.conf
source "${SCRIPT_DIR}/govexy-node.conf"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root"

valid_ipv4() {
  local ip=$1 o n
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -ra o <<< "$ip"
  for n in "${o[@]}"; do (( n >= 0 && n <= 255 )) || return 1; done
}

write_realip_conf() {
  if [[ -n "$LB_IPS" ]]; then
    {
      echo "# Load balancer real-IP trust. Only these sources may have their"
      echo "# X-Forwarded-For header believed."
      for ip in $LB_IPS; do echo "set_real_ip_from ${ip};"; done
      echo "real_ip_header X-Forwarded-For;"
      echo "real_ip_recursive on;"
    } > /etc/nginx/conf.d/01-govexy-realip.conf
  else
    cat > /etc/nginx/conf.d/01-govexy-realip.conf <<'REALIP'
# Load balancer not yet known — no real_ip trust configured.
#
# Until this is set, $remote_addr is whatever opens the TCP connection. Once an
# LB sits in front, that is the LB's own address on every request, so Laravel's
# rate limiting and audit logs key on one value for all clients. The true client
# is still recorded as xff= in the access log, so nothing is lost — but nothing
# is enforced per-client either.
#
# This is deliberately left empty rather than guessed: set_real_ip_from is an
# allowlist deciding whose X-Forwarded-For is trusted. Naming the wrong address
# tells nginx to believe a forged header from whoever occupies it.
#
# When the LB exists:  bash 02-configure-nginx-php.sh --set-lb <ip> [<ip>...]
REALIP
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# --set-lb : update load balancer trust only, then reload
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--set-lb" ]]; then
  shift
  [[ $# -gt 0 ]] || die "--set-lb needs at least one IP"
  for ip in "$@"; do valid_ipv4 "$ip" || die "not a valid IPv4 address: '$ip'"; done
  LB_IPS="$*"
  write_realip_conf
  nginx -t
  systemctl reload nginx
  log "Load balancer trust set: ${LB_IPS}"
  warn "Apply the same on every other web node, and record it in govexy-node.conf"
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Preflight
# ─────────────────────────────────────────────────────────────────────────────

command -v nginx    &>/dev/null || die "nginx not installed — run 01-install-dependencies.sh first"
command -v php      &>/dev/null || die "php not installed — run 01-install-dependencies.sh first"
[[ -d /etc/php-fpm.d ]]         || die "php-fpm not installed — run 01-install-dependencies.sh first"
php -v | head -1 | grep -q 'PHP 8\.4' || die "PHP 8.4 is not active"

[[ -n "$REDIS_HOST" ]] || die "REDIS_HOST is unset in govexy-node.conf"
valid_ipv4 "$REDIS_HOST" || die "REDIS_HOST is not a valid IPv4 address: '$REDIS_HOST'"

for ip in $LB_IPS; do
  valid_ipv4 "$ip" || die "LB_IPS contains an invalid IPv4 address: '$ip'"
done

if [[ -z "$LB_IPS" && "$RESTRICT_HTTP_TO_LB" == "yes" ]]; then
  die "RESTRICT_HTTP_TO_LB=yes requires LB_IPS. Set one or the other."
fi

PHP_POST_MAX="${PHP_POST_MAX:-${PHP_UPLOAD_MAX}}"
PHP_CLI_MEMORY_LIMIT="${PHP_CLI_MEMORY_LIMIT:-1024M}"
SECURITY_HEADERS="${SECURITY_HEADERS:-yes}"
HSTS_MAX_AGE="${HSTS_MAX_AGE:-31536000}"
HSTS_INCLUDE_SUBDOMAINS="${HSTS_INCLUDE_SUBDOMAINS:-yes}"
HSTS_PRELOAD="${HSTS_PRELOAD:-no}"
FRAME_OPTIONS="${FRAME_OPTIONS:-SAMEORIGIN}"
CSP_MODE="${CSP_MODE:-no}"
CSP_REPORT_URI="${CSP_REPORT_URI:-}"

case "$FRAME_OPTIONS" in
  SAMEORIGIN) ;;
  DENY) die "FRAME_OPTIONS=DENY breaks the visual page builder — its page preview is
       an iframe driven over postMessage. Use SAMEORIGIN." ;;
  *) die "FRAME_OPTIONS must be SAMEORIGIN (or DENY, which is refused above)" ;;
esac

case "$CSP_MODE" in
  no|report-only|enforce) ;;
  *) die "CSP_MODE must be one of: no | report-only | enforce" ;;
esac

HSTS_VALUE="max-age=${HSTS_MAX_AGE}"
[[ "$HSTS_INCLUDE_SUBDOMAINS" == "yes" ]] && HSTS_VALUE+="; includeSubDomains"
[[ "$HSTS_PRELOAD" == "yes" ]] && HSTS_VALUE+="; preload"

if [[ "$HSTS_PRELOAD" == "yes" ]]; then
  warn "HSTS preload is enabled. This is effectively irreversible for months and"
  warn "forces valid HTTPS on EVERY subdomain of the registrable domain, including"
  warn "ones that do not exist yet. Confirm this was a deliberate decision."
fi

CSP_HEADER_NAME="Content-Security-Policy"
[[ "$CSP_MODE" == "report-only" ]] && CSP_HEADER_NAME="Content-Security-Policy-Report-Only"

CSP_POLICY="default-src 'self'; base-uri 'self'; object-src 'none'; \
frame-ancestors 'self'; form-action 'self'; frame-src 'self'; \
img-src 'self' data: blob:; font-src 'self' data:; media-src 'self' data: blob:; \
style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; \
connect-src 'self'; worker-src 'self' blob:"
[[ -n "$CSP_REPORT_URI" ]] && CSP_POLICY+="; report-uri ${CSP_REPORT_URI}"

log "Config: LB=[${LB_IPS:-<none yet>}]  REDIS=${REDIS_HOST}  APP_ROOT=${APP_ROOT}"
log "        headers=${SECURITY_HEADERS}  frame=${FRAME_OPTIONS}  csp=${CSP_MODE}"
read -r -p "Correct? [y/N] " confirm
[[ "$confirm" == [yY] ]] || die "aborted"

if [[ "$CSP_MODE" == "enforce" ]]; then
  warn "CSP is set to ENFORCE."
  warn "Tenants can enable Google Analytics, GTM, Facebook Pixel and reCAPTCHA from"
  warn "the dashboard, and themes may load their own assets. This policy allows only"
  warn "'self' for scripts and connections, so every one of those will be blocked on"
  warn "public tenant sites — silently, as a browser console error nobody watches."
  warn "Run report-only first unless those origins are already enumerated."
  read -r -p "Continue with enforce? [y/N] " cspconfirm
  [[ "$cspconfirm" == [yY] ]] || die "aborted"
fi

# ═════════════════════════════════════════════════════════════════════════════
log "1/6  PHP-FPM pool"
# ═════════════════════════════════════════════════════════════════════════════

[[ -f /etc/php-fpm.d/www.conf.orig ]] || cp -a /etc/php-fpm.d/www.conf /etc/php-fpm.d/www.conf.orig

cat > /etc/php-fpm.d/www.conf <<EOF
[www]
user = nginx
group = nginx

listen = /run/php-fpm/www.sock
listen.owner = nginx
listen.group = nginx
listen.mode = 0660

pm = dynamic
pm.max_children = ${FPM_MAX_CHILDREN}
pm.start_servers = 8
pm.min_spare_servers = 6
pm.max_spare_servers = 12
pm.max_requests = 500

slowlog = /var/log/php-fpm/www-slow.log
request_slowlog_timeout = 10s

; A worker blocked on a stalled NFS mount never returns on its own — `hard`
; mounts retry indefinitely by design. Without a ceiling, one stall walks the
; whole pool into a permanent wedge that no health check can see, because the
; workers are alive and simply never answer. This kills such a request and logs
; a backtrace naming the call that hung.
request_terminate_timeout = 120s

php_admin_value[error_log] = /var/log/php-fpm/www-error.log
php_admin_flag[log_errors] = on

; The WEB memory limit belongs here, not in /etc/php.d/99-govexy.ini, which the
; CLI reads too. A web-sized ceiling there also caps artisan — Horizon workers,
; schedule:run, metering:ingest-edge, theme:publish-assets and the content-bundle
; importers all run under it.
php_admin_value[memory_limit] = ${PHP_MEMORY_LIMIT}

; Laravel does not use PHP's own session handler (SESSION_DRIVER=redis does the
; work), so these only keep the stock directories valid for anything that asks.
php_value[session.save_handler] = files
php_value[session.save_path]    = /var/lib/php/session
php_value[soap.wsdl_cache_dir]  = /var/lib/php/wsdlcache

; RHEL's stock www.conf carries these, and this file is written from scratch.
; php-fpm's clear_env defaults to ON, so without them the pool starts with an
; EMPTY environment and every exec(), shell_exec() or Symfony Process call from
; PHP fails with "command not found" — no PATH, no TMPDIR. Imagick is in-process
; and unaffected; anything shelling out to gs, pdftoppm, unzip or git is not.
env[PATH] = /usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
env[TMP] = /tmp
env[TMPDIR] = /tmp
env[TEMP] = /tmp
EOF

install -d -o root -g nginx -m 0770 /var/lib/php/session /var/lib/php/wsdlcache

# ═════════════════════════════════════════════════════════════════════════════
log "2/6  PHP runtime settings"
# ═════════════════════════════════════════════════════════════════════════════

# Read by BOTH SAPIs. The web memory limit is deliberately absent — it is set on
# the FPM pool instead, so it cannot cap artisan. What is here is the CLI's own
# limit, which needs to be the larger of the two.
cat > /etc/php.d/99-govexy.ini <<EOF
memory_limit = ${PHP_CLI_MEMORY_LIMIT}
upload_max_filesize = ${PHP_UPLOAD_MAX}

; Must exceed upload_max_filesize: a multipart body carrying a file of exactly
; upload_max_filesize is larger than it once boundaries and fields are counted,
; and PHP silently discards the entire body when this is exceeded — the request
; arrives with no CSRF token and Laravel answers 419.
post_max_size = ${PHP_POST_MAX}
max_execution_time = 60
expose_php = Off
date.timezone = ${SERVER_TZ}

opcache.enable = 1
opcache.enable_cli = 0
opcache.memory_consumption = 256
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 20000
opcache.validate_timestamps = 0
opcache.save_comments = 1
EOF

# ═════════════════════════════════════════════════════════════════════════════
log "3/6  Application directory + SELinux"
# ═════════════════════════════════════════════════════════════════════════════

install -d -o nginx -g nginx "$APP_ROOT"
install -d -o nginx -g nginx "${APP_ROOT}/public"

semanage fcontext -a -t httpd_sys_content_t    "${APP_ROOT}(/.*)?"                 2>/dev/null || true
semanage fcontext -a -t httpd_sys_rw_content_t "${APP_ROOT}/storage(/.*)?"         2>/dev/null || true
semanage fcontext -a -t httpd_sys_rw_content_t "${APP_ROOT}/bootstrap/cache(/.*)?" 2>/dev/null || true
restorecon -R "$APP_ROOT"

# PHP must reach Redis (${REDIS_HOST}) and the remote MySQL host.
setsebool -P httpd_can_network_connect 1
setsebool -P httpd_can_network_connect_db 1

# Shared storage is NFS-mounted (media, form attachments, uploaded themes).
# Without this boolean SELinux blocks nginx/php-fpm from NFS entirely, and the
# failure looks like a permissions bug rather than a policy one — the file is
# plainly there and readable by the nginx user, yet every read is denied.
setsebool -P httpd_use_nfs 1

# ── Bandwidth meter log directory ────────────────────────────────────────────
#
# NOT /var/log/nginx. On RHEL that directory is root-owned 0700, so the ingest
# command — which runs as the application user under a systemd timer — cannot
# read it at all. The failure presents as "the meter reads zero", which is the
# worst way for a billing pipeline to break: silently, while everything else
# looks healthy.
#
# nginx writes, the app user reads. 0750 on the directory and 0640 on the files
# is the minimum that allows both.
if [[ "$METER_LOG" == "yes" ]]; then
  install -d -o nginx -g "$METER_LOG_GROUP" -m 0750 "$METER_LOG_DIR"

  # httpd_log_t is the type nginx is allowed to write. Labelling the directory
  # explicitly (rather than inheriting /var/log's default) is what makes the
  # write succeed under enforcing; the app user's READ is a DAC decision, which
  # the group ownership above covers.
  semanage fcontext -a -t httpd_log_t "${METER_LOG_DIR}(/.*)?" 2>/dev/null || true
  restorecon -R "$METER_LOG_DIR"

  log "    meter log directory: ${METER_LOG_DIR} (nginx:${METER_LOG_GROUP} 0750)"
  warn "Verify under load that the reader is not being denied:  ausearch -m avc -ts recent"
fi

# ═════════════════════════════════════════════════════════════════════════════
log "4/6  nginx configuration"
# ═════════════════════════════════════════════════════════════════════════════

# The RHEL package ships its default site inside nginx.conf, not conf.d/default.conf.
# Left in place it collides with the GovExy vhost on port 80. Comment it out,
# tracking brace depth so nested location blocks are covered too.
if grep -qE '^[[:space:]]*server[[:space:]]*\{' /etc/nginx/nginx.conf; then
  cp -a /etc/nginx/nginx.conf "/etc/nginx/nginx.conf.bak.$(date +%s)"
  awk '
    BEGIN { inblk = 0; depth = 0 }
    {
      if (!inblk && $0 ~ /^[[:space:]]*server[[:space:]]*\{/) { inblk = 1; depth = 0 }
      if (inblk) {
        line = $0
        opens  = gsub(/\{/, "{")
        closes = gsub(/\}/, "}")
        depth += opens - closes
        print "#" line
        if (depth <= 0) { inblk = 0 }
        next
      }
      print
    }
  ' /etc/nginx/nginx.conf > /tmp/nginx.conf.new && mv /tmp/nginx.conf.new /etc/nginx/nginx.conf
  log "    commented out the stock default server block"
fi

# nginx.org packages put a default site here instead; harmless if absent.
rm -f /etc/nginx/conf.d/default.conf

# http-context directives. conf.d/*.conf is included inside http{}, so these are
# valid here and nginx.conf needs no further editing.
{
  echo "server_tokens off;"
  # Follows post_max_size, not upload_max_filesize: nginx must not reject a
  # multipart body that PHP would have accepted.
  echo "client_max_body_size ${PHP_POST_MAX};"
  echo
  # HTTPS for FastCGI. NOT $http_x_forwarded_proto directly.
  #
  # Symfony's Request::isSecure() is !empty($https) && 'off' !== strtolower($https),
  # so a plaintext request arriving with "X-Forwarded-Proto: http" set HTTPS=http
  # — non-empty, not "off" — and the framework treated it as SECURE. Only a
  # request with no XFP header at all was correctly seen as insecure.
  #
  # An empty value is what makes PHP see no HTTPS at all, which is the intent.
  echo 'map $http_x_forwarded_proto $govexy_https {'
  echo '    default "";'
  echo '    "https"  "on";'
  echo '}'
  echo
  echo 'log_format main_lb '"'"'\$remote_addr - \$remote_user [\$time_local] "\$request" '"'"''
  echo '                   '"'"'\$status \$body_bytes_sent "\$http_referer" '"'"''
  echo '                   '"'"'"\$http_user_agent" xff="\$http_x_forwarded_for" '"'"''
  echo '                   '"'"'rt=\$request_time upstream=\$upstream_response_time'"'"';'
  echo
  if [[ "$METER_LOG" == "yes" ]]; then
    echo
    echo "# Per-request bandwidth meter format, drained by \`php artisan metering:ingest-edge\`."
    echo "#"
    echo "# The REQUEST LINE IS DELIBERATELY ABSENT. \$request and \$request_uri are"
    echo "# attacker-controlled, and the meter parser must not have to be a security"
    echo "# boundary. \$host is the only user-influenced field and it is validated on parse."
    echo "#"
    echo "# \$bytes_sent is what is billed: headers plus body, after compression, as"
    echo "# actually written to the client socket. \$body_bytes_sent is logged beside it so"
    echo "# a contract that defines bandwidth as body-only is a config change rather than a"
    echo "# redesign, retroactive over the log retention window. \$request_length is logged"
    echo "# because ingress may one day be billed and re-instrumenting later is not free."
    echo "# \$server_protocol is logged so the HTTP/2 header-accounting caveat can be"
    echo "# measured on real traffic rather than argued about. \$request_completion"
    echo "# distinguishes a completed response from an aborted one."
    echo 'log_format govexy_meter '"'"'\$time_iso8601|\$host|\$status|\$request_method|'"'"''
    echo '                        '"'"'\$bytes_sent|\$body_bytes_sent|\$request_length|'"'"''
    echo '                        '"'"'\$server_protocol|\$request_completion'"'"';'
  fi

  echo
  echo "gzip on;"
  echo "gzip_vary on;"
  echo "gzip_min_length 1024;"
  echo "gzip_types text/plain text/css application/json application/javascript text/xml application/xml image/svg+xml;"

  if [[ "$SECURITY_HEADERS" == "yes" ]]; then
    echo
    echo "# HSTS is emitted only when the request actually arrived over HTTPS."
    echo "# The load balancer terminates TLS and forwards plaintext, so the only"
    echo "# evidence of the client's scheme is X-Forwarded-Proto. A browser ignores"
    echo "# HSTS on a plaintext response, so emitting it unconditionally is noise;"
    echo "# an empty variable makes nginx omit the header entirely."
    echo 'map $http_x_forwarded_proto $govexy_hsts {'
    echo '    default "";'
    printf '    "https"  "%s";\n' "$HSTS_VALUE"
    echo '}'
  fi
} > /etc/nginx/conf.d/00-govexy-http.conf

# Real-IP trust lives in its own file so the LB can be added later without
# regenerating anything else.
write_realip_conf

# ── Security headers ─────────────────────────────────────────────────────────
#
# These live in a snippet rather than the http block because nginx's add_header
# inheritance is all-or-nothing: the moment a location declares ANY add_header of
# its own, every inherited one is discarded. The vhost has two such locations
# (the static-asset block sets Cache-Control, the published-assets block sets its own), so the
# snippet is re-included there explicitly. Get this wrong and those responses
# silently ship with no security headers at all.
install -d -m 0755 /etc/nginx/snippets

if [[ "$SECURITY_HEADERS" == "yes" ]]; then
  {
    echo "# Managed by 02-configure-nginx-php.sh — edits are overwritten on re-run."
    echo "# Re-include this file in every location that declares its own add_header."
    echo
    echo 'add_header Strict-Transport-Security $govexy_hsts always;'
    echo 'add_header X-Content-Type-Options "nosniff" always;'
    echo "add_header X-Frame-Options \"${FRAME_OPTIONS}\" always;"
    echo 'add_header Referrer-Policy "strict-origin-when-cross-origin" always;'
    echo 'add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()" always;'
    echo 'add_header Cross-Origin-Opener-Policy "same-origin" always;'
    echo 'add_header X-Permitted-Cross-Domain-Policies "none" always;'
    echo
    echo "# Current guidance is to DISABLE the legacy XSS auditor rather than enable it."
    echo "# The old filter introduced its own vulnerabilities and is removed from modern"
    echo "# browsers; \"1; mode=block\" is a downgrade, not a hardening."
    echo 'add_header X-XSS-Protection "0" always;'

    if [[ "$CSP_MODE" != "no" ]]; then
      echo
      echo "# Content-Security-Policy (${CSP_MODE})."
      echo "# 'unsafe-inline'/'unsafe-eval' are present because Filament v5 + Livewire 4"
      echo "# + Alpine require them. That materially weakens the policy — it still stops"
      echo "# external script injection and framing, but not inline injection. Tightening"
      echo "# means nonce-based tags, which is an application change."
      echo "add_header ${CSP_HEADER_NAME} \"${CSP_POLICY}\" always;"
    fi
  } > /etc/nginx/snippets/govexy-security-headers.conf
else
  cat > /etc/nginx/snippets/govexy-security-headers.conf <<'NOSEC'
# SECURITY_HEADERS="no" in govexy-node.conf — no headers set at this tier.
# Only correct if an upstream tier (gov-proxy / HAProxy) sets them for every
# hostname this node serves, including the admin and tenant dashboard hosts.
NOSEC
fi

# ── The second, dedicated access log ─────────────────────────────────────────
#
# A SEPARATE log, not a replacement: the ops log above is untouched, so nothing
# an operator or an incident review depends on changes.
#
# buffer=64k flush=5s cuts write syscalls by roughly two orders of magnitude at
# 30+ requests per page view. The cost is up to 5 seconds of records sitting in
# nginx's buffer, which is the smallest term in the enforcement-lag budget. A
# graceful reload or `nginx -s reopen` flushes them; SIGKILL loses them.
#
# NOTE, and this matters for how the numbers are read: this node serves ALL
# hostnames from one catch-all server block — tenant public sites and the app and
# superadmin panels alike. The meter log therefore carries panel traffic, which
# the ingest discards at parse time by host, exactly as the application meter
# does today. When tenant sites get their own server block, move this directive
# there and the volume drops.
METER_ACCESS_LOG=""
if [[ "$METER_LOG" == "yes" ]]; then
  METER_ACCESS_LOG="    access_log ${METER_LOG_DIR}/meter.log govexy_meter buffer=64k flush=5s;"
fi

cat > /etc/nginx/conf.d/govexy.conf <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root ${APP_ROOT}/public;
    index index.php;
    charset utf-8;

    access_log /var/log/nginx/govexy-access.log main_lb;
    error_log  /var/log/nginx/govexy-error.log;
${METER_ACCESS_LOG}

    include /etc/nginx/snippets/govexy-security-headers.conf;

    # No nginx-level health endpoint, deliberately.
    #
    # There used to be a /healthz here that returned 200 from nginx alone. It was
    # worse than nothing: it answered 200 while PHP-FPM was dead, while MySQL or
    # Redis were unreachable, and for the entire maintenance window of a deploy —
    # so a load balancer using it could not tell a working node from a broken one
    # and would keep sending traffic to both.
    #
    # The load balancer must check /up, which boots the framework and runs the
    # application's own health checks.

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { try_files \$uri /index.php?\$query_string; }

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ ^/index\.php(/|\$) {
        fastcgi_pass unix:/run/php-fpm/www.sock;
        fastcgi_split_path_info ^(.+\.php)(/.*)\$;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        # "on" only when the load balancer says https, empty otherwise. See the
        # \$govexy_https map in 00-govexy-http.conf for why the raw header
        # cannot be passed through here.
        fastcgi_param HTTPS \$govexy_https;

        # Overwrite the client-supplied X-Forwarded-For with the address nginx
        # actually resolved. The application trusts proxies at '*', so without
        # this a request carrying its own "X-Forwarded-For: 1.2.3.4" would have
        # that value believed by Laravel — defeating login throttling and writing
        # forged addresses into the activity log.
        #
        # \$remote_addr is already the true client here when LB_IPS is set (the
        # realip module rewrites it before params are evaluated); with no LB
        # configured it is the direct peer. Either way it is a value nginx
        # established, not one the client asserted.
        fastcgi_param HTTP_X_FORWARDED_FOR \$remote_addr;

        # Same reasoning, and just as necessary: the application calls
        # trustProxies(at: '*') with HEADER_X_FORWARDED_HOST, so Laravel believes
        # this header from anyone. IdentifyTenantForSite resolves the tenant from
        # \$request->getHost(), and url()/route() build password-reset links from
        # it. Left client-supplied, a request carrying
        # "X-Forwarded-Host: some-other-tenant.ishj.ae" is served as that tenant
        # and generates links pointing at whatever host the attacker chose.
        #
        # \$host is what nginx matched the request on, not what the client asserted.
        fastcgi_param HTTP_X_FORWARDED_HOST \$host;

        # X-Forwarded-Proto, passed through as the client sent it — unlike XFF
        # and XFH above, which are pinned to values nginx established.
        #
        # It is NOT pinned, and this comment used to claim it was. With
        # RESTRICT_HTTP_TO_LB="no" anyone who can reach :80 directly can assert
        # "https" here. The impact is bounded — a forged URL scheme and secure
        # cookie flags, not authentication — but it is a claim the config does
        # not make good on. Restrict :80 to the load balancer to close it.
        fastcgi_param HTTP_X_FORWARDED_PROTO \$http_x_forwarded_proto;
        fastcgi_hide_header X-Powered-By;
        fastcgi_read_timeout 60s;
        fastcgi_buffer_size 32k;
        fastcgi_buffers 16 16k;
        internal;
    }

    # Nothing else may execute PHP.
    location ~ \.php\$ { return 404; }

    # Defence in depth. Both are gated in the application, and 04-deploy.sh
    # refuses to deploy unless TELESCOPE_ENABLED=false, but neither has any
    # business being reachable on a government node. /horizon is deliberately
    # NOT here: it is the operator's queue dashboard (see 05-configure-workers.sh).
    location ^~ /telescope { return 404; }
    location ^~ /pulse     { return 404; }

    # Dotfiles stay private, except .well-known, which the application serves
    # through index.php (tenant-managed verification files, ACME challenges).
    location ^~ /.well-known/ {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ /\. { deny all; }

    # ── Published theme assets ────────────────────────────────────────────
    #
    # storage/app/public/theme-dist/{slug}/{buildId}/ holds a released theme
    # version's asset tree, materialised once at release time and never edited.
    # The directory name is an HMAC over a digest of the tree's contents, so a
    # changed theme is a changed URL and there is nothing to invalidate: no
    # purge, no cache-buster, nothing to coordinate between the two nodes.
    #
    # ^~ so this wins outright over the generic static-extension regex location
    # below, which would otherwise match every .css/.woff2 in here and serve it
    # with a 30-day, non-immutable policy.
    #
    # This is inert until the application sets THEME_ASSETS_SERVE_PUBLISHED=true:
    # with the flag off nothing is published, no page emits a URL under this
    # prefix, and every theme asset is still served by PHP through /index.php.
    location ^~ /storage/theme-dist/ {
        # Serves the .gz written at publish time. Compression is paid once per
        # build instead of once per response.
        gzip_static on;

        # brotli_static on;   # only if a brotli module is actually available;
        #                     # stock RHEL 9 AppStream nginx does not ship one.

        include /etc/nginx/snippets/govexy-security-headers.conf;

        # Immutable is honest here, and ONLY here, because the path contains a
        # content digest. Note the one-way door: these URLs cannot be recalled
        # once a visitor has them, which is why old build directories are kept
        # for a grace window after they stop being referenced and are removed
        # only by an operator running `php artisan theme:assets-gc --force`.
        expires 1y;
        add_header Cache-Control "public, max-age=31536000, immutable" always;

        # A miss must be a cheap 404, never a fall-through to /index.php. A miss
        # should be impossible — the database only names a build id after the
        # directory has been renamed into place — and if one ever happens a 404
        # storm is a loud signal, whereas falling through to PHP would silently
        # reproduce the cost this whole change exists to remove.
        try_files \$uri =404;

        # error_page is inherited from the server block, where `error_page 404
        # /index.php;` sends misses to Laravel. That inheritance defeats the
        # =404 above: a miss here would boot the framework, which is exactly the
        # cost this location exists to avoid, and the deploy probe cannot detect
        # it because Laravel also answers 404. Reset it to nginx's own page.
        error_page 404 = @theme_dist_404;
    }

    location @theme_dist_404 {
        internal;
        default_type text/plain;
        return 404 "not found\n";
    }

    # Re-includes the header snippet: any location declaring its own add_header
    # discards every inherited one.
    # Static assets are the largest share of responses; losing nosniff here is how
    # an uploaded file gets content-sniffed into something executable.
    location ~* \.(jpg|jpeg|png|gif|webp|svg|ico|css|js|woff2?|ttf|eot)\$ {
        expires 30d;
        include /etc/nginx/snippets/govexy-security-headers.conf;

        # No "immutable". These URLs carry no content hash, so a replaced image
        # keeps its path — immutable would tell browsers not to revalidate for
        # 30 days and a tenant's updated logo would not reach returning
        # visitors. Only a versioned path may claim immutability.
        add_header Cache-Control "public, max-age=2592000";

        # Deliberately LOGGED. public/storage symlinks to storage/app/public, so
        # tenant media matches the request URI here and is served by nginx without PHP
        # ever seeing it — those bytes are invisible to the application bandwidth
        # metering. Silencing the log would make them invisible to log-based
        # metering as well, which is the only place they can still be counted.
        try_files \$uri /index.php?\$query_string;
    }

    error_page 404 /index.php;
}
EOF

nginx -t

# The theme-dist location serves the .gz written at publish time. Checked the
# same way realip is checked in stage 1: a missing module is silent, and the
# symptom is that compression is paid per response instead of per build.
nginx -V 2>&1 | tr ' ' '\n' | grep -q 'gzip_static' || \
  warn "nginx built without http_gzip_static_module — theme-dist .gz files will not be served"

# ── Meter log rotation ───────────────────────────────────────────────────────
#
# copytruncate is FORBIDDEN here, and this is not a style preference. It copies
# the file and then truncates it, and every byte nginx writes between those two
# operations is gone — an unbounded, undetectable hole in a billing meter. The
# ingest cannot even see that it happened, because the inode never changed.
#
# `create` + USR1 is the only correct pattern: logrotate renames the file (the
# original inode, with the unread tail, survives as meter.log.1), creates a new
# one with the ownership the ingest needs, and USR1 makes nginx reopen. The
# reader detects the inode change, drains the predecessor from its cursor offset
# to the end, and only then reads the new file.
#
# delaycompress is what guarantees meter.log.1 is still UNCOMPRESSED for one full
# cycle. The reader matches the predecessor by (dev, inode) and refuses to guess;
# compression creates a new inode, so without this grace window a rotation that
# lands between two runs is alarmed as an unmeasured gap instead of drained.
#
# rotate 72 hourly = 3 days of slack, several multiples of the longest plausible
# unnoticed stall given a 5-minute watchdog.
if [[ "$METER_LOG" == "yes" ]]; then
  cat > /etc/logrotate.d/govexy-meter <<ROTATE
${METER_LOG_DIR}/meter.log {
    hourly
    rotate 72
    missingok
    notifempty
    compress
    delaycompress
    create 0640 nginx ${METER_LOG_GROUP}
    sharedscripts
    postrotate
        /bin/kill -USR1 \$(cat /run/nginx.pid 2>/dev/null) 2>/dev/null || true
    endscript
}
ROTATE

  # The cheapest control in the whole pipeline, and it prevents the worst
  # failure it has. Assert rather than trust: someone WILL add copytruncate to
  # this file one day to fix an unrelated permissions complaint.
  if grep -q 'copytruncate' /etc/logrotate.d/govexy-meter; then
    die "copytruncate is present in /etc/logrotate.d/govexy-meter. It races nginx and drops metered bytes with no trace."
  fi
  if ! grep -q 'delaycompress' /etc/logrotate.d/govexy-meter; then
    die "delaycompress is missing from /etc/logrotate.d/govexy-meter. The reader needs an uncompressed .1 to finish draining."
  fi

  logrotate -d /etc/logrotate.d/govexy-meter >/dev/null 2>&1 || \
    warn "logrotate could not parse /etc/logrotate.d/govexy-meter — check it before go-live"

  log "    meter log rotation installed (hourly, rotate 72, create + USR1)"
fi

# ═════════════════════════════════════════════════════════════════════════════
log "5/6  Firewall"
# ═════════════════════════════════════════════════════════════════════════════

if [[ "$RESTRICT_HTTP_TO_LB" == "yes" ]]; then
  firewall-cmd --permanent --remove-service=http  &>/dev/null || true
  firewall-cmd --permanent --remove-service=https &>/dev/null || true
  for ip in $LB_IPS; do
    firewall-cmd --permanent \
      --add-rich-rule="rule family=\"ipv4\" source address=\"${ip}/32\" service name=\"http\" accept"
  done
else
  firewall-cmd --permanent --add-service=http
  firewall-cmd --permanent --add-service=https
fi
firewall-cmd --reload

# ═════════════════════════════════════════════════════════════════════════════
log "6/6  Services + verification"
# ═════════════════════════════════════════════════════════════════════════════

systemctl enable --now php-fpm
systemctl enable --now nginx
systemctl reload php-fpm
systemctl reload nginx

printf '\n'
systemctl is-active php-fpm nginx
printf 'up: '
curl -s --noproxy '*' -o /dev/null -w '%{http_code}\n' http://127.0.0.1/up

log "Published theme assets"

# Proves the location block is present AND that a miss is answered by nginx
# rather than by Laravel.
#
# Checking the status code alone is useless here: Laravel returns 404 for an
# unknown path too, so a fall-through to index.php — the exact regression the
# `error_page 404 = @theme_dist_404` line prevents — is invisible to it. The
# body is what distinguishes them. nginx replies with a short plain-text line;
# Laravel renders an HTML error page of some kilobytes.
printf 'theme-dist miss: '
THEME_DIST_PROBE=$(curl -s --noproxy '*' \
  -w '\n%{http_code} %{size_download}' \
  http://127.0.0.1/storage/theme-dist/_probe/_probe/probe.css 2>/dev/null || true)
THEME_DIST_CODE=$(printf '%s' "$THEME_DIST_PROBE" | tail -1 | awk '{print $1}')
THEME_DIST_SIZE=$(printf '%s' "$THEME_DIST_PROBE" | tail -1 | awk '{print $2}')

if [[ "$THEME_DIST_CODE" != "404" ]]; then
  warn "expected 404, got ${THEME_DIST_CODE:-no response} — check the location block"
elif (( ${THEME_DIST_SIZE:-0} > 200 )); then
  warn "404 came back with ${THEME_DIST_SIZE} bytes, so Laravel answered it."
  warn "A theme-dist miss is booting the framework — the whole point of this"
  warn "location is that it does not. Check that error_page is reset inside it."
else
  printf '404, %s bytes, served by nginx\n' "${THEME_DIST_SIZE:-0}"
fi

if [[ "$SECURITY_HEADERS" == "yes" ]]; then
  log "Security headers"

  # Checked on a real application response, which is what visitors receive.
  printf '\n-- plaintext request (no HSTS expected) --\n'
  curl -sI --noproxy '*' http://127.0.0.1/up \
    | grep -iE 'x-frame-options|x-content-type|referrer-policy|permissions-policy|cross-origin|x-permitted|x-xss|content-security|strict-transport' \
    || warn "no security headers on /up — check the snippet include"

  printf '\n-- simulated HTTPS via X-Forwarded-Proto (HSTS expected) --\n'
  curl -sI --noproxy '*' -H 'X-Forwarded-Proto: https' http://127.0.0.1/up \
    | grep -i 'strict-transport-security' \
    || warn "HSTS absent under X-Forwarded-Proto: https — check the map in 00-govexy-http.conf"

  for h in X-Frame-Options X-Content-Type-Options Referrer-Policy; do
    curl -sI --noproxy '*' http://127.0.0.1/up | grep -qi "^${h}:" || warn "missing header: ${h}"
  done
fi

if [[ "$METER_LOG" == "yes" ]]; then
  log "Bandwidth meter log"

  # One request through the vhost is enough to prove the whole chain: the format
  # compiles, the directive is on the right server block, the file is created
  # with the right ownership, and the app user can read it. Any of those failing
  # silently means the meter reads zero.
  curl -s --noproxy '*' -o /dev/null http://127.0.0.1/ || true
  sleep 6   # buffer=64k flush=5s

  if [[ -s "${METER_LOG_DIR}/meter.log" ]]; then
    printf 'last meter line: '
    tail -1 "${METER_LOG_DIR}/meter.log"
    stat -c '  %n  %U:%G %a' "${METER_LOG_DIR}/meter.log"

    # Derived from the application root's owner, like everything else in this
    # repository — the reader is the app user, which is only coincidentally
    # nginx today.
    METER_READER=$(stat -c '%U' "$APP_ROOT" 2>/dev/null || echo nginx)
    if ! sudo -u "$METER_READER" test -r "${METER_LOG_DIR}/meter.log"; then
      warn "the application user cannot READ the meter log — ingest would report zero bytes forever"
    fi
  else
    warn "no meter line was written. Check the access_log directive and, under enforcing SELinux:"
    warn "    ausearch -m avc -ts recent"
  fi
fi

printf '\n'
warn "opcache.validate_timestamps=0 — every deploy MUST end with: systemctl reload php-fpm"

if [[ -z "$LB_IPS" ]]; then
  warn "No load balancer trust configured. Once the LB IP is known, run on EVERY node:"
  warn "    bash 02-configure-nginx-php.sh --set-lb <lb-ip>"
fi

cat <<'DONE'

────────────────────────────────────────────────────────────────────────────
Stage 2 complete. Node serves nginx + PHP-FPM; the application is not deployed.

Remaining, per node:

  1. Deploy application code into APP_ROOT.
  2. Install dependencies as the app user, never root:
         sudo -u nginx composer install --no-dev --optimize-autoloader
     If repo.packagist.org is unreachable, build vendor/ elsewhere and ship it.
  3. Write .env — identical on BOTH web nodes:
         APP_KEY            byte-identical across nodes. Differing keys break
                            sessions and encrypted cookies the moment the load
                            balancer switches a user between nodes.
         CACHE_STORE=redis
         SESSION_DRIVER=redis
         QUEUE_CONNECTION=redis
         REDIS_CLIENT=phpredis
         REDIS_HOST=<redis server>
         DB_HOST=<mysql server>
  4. chown -R nginx:nginx storage bootstrap/cache && restorecon -R <APP_ROOT>
  5. php artisan config:cache route:cache view:cache
     systemctl reload php-fpm

Decisions this script cannot make:

  • Shared media. storage/app/public on local disk means a file uploaded on
    web1 returns 404 from web2. Needs NFS, S3/MinIO, or equivalent.
  • Scheduler. Run the cron entry on ONE node only, or every job fires twice.
  • Queue workers / Horizon. Decide deliberately which node(s) run them.
────────────────────────────────────────────────────────────────────────────
DONE
