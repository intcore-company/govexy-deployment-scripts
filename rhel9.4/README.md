# GovExy web node provisioning — RHEL 9.x

Provisioning scripts for a **GovExy web node**: the tier that runs nginx and PHP-FPM
for the GovExy multi-tenant Laravel 12 CMS.

| | |
|---|---|
| Target OS | RHEL 9.x, x86_64 (verified on a host reporting RHEL 9.7; the directory name reflects the baseline it was written against, not a hard floor) |
| Guard in the script | `01-install-dependencies.sh` aborts unless `/etc/redhat-release` matches `release 9` |
| Role provisioned | Web node only — nginx + PHP 8.4 + PHP-FPM + Composer |
| Topology assumed | Two identical web nodes behind a load balancer |
| Not provisioned | MySQL (separate server), Redis (separate server, `10.32.46.95`), NFS server, the load balancer itself, and the application code |

PHP comes from **Remi**, not AppStream: the application requires PHP `^8.4` and RHEL 9
AppStream tops out at 8.3.

The scripts encode workarounds for this estate's network — a TLS-inspecting proxy and
restrictive egress. Those workarounds are documented inline in the scripts and
summarised under [What each script does](#6-what-each-script-does). Do not "simplify"
them away.

---

## 1. Contents of this directory

| File | Purpose |
|---|---|
| `govexy-node.conf` | Shared variables, including `NODE_ROLE`. Sourced or read by every script. **Edit here, never inside the scripts.** |
| `01-install-dependencies.sh` | Stage 1 — install only. Repos, packages, PHP 8.4, Composer. Starts no services. No prompts. |
| `02-configure-nginx-php.sh` | Stage 2 — configuration. FPM pool, php.ini, nginx vhost, SELinux, firewalld; starts and verifies services. Also `--set-lb` mode. **Prompts for confirmation.** |
| `03-mount-shared-storage.sh` | Stage 3 — bind the three shared paths out of the NFS export onto the application. Interactive; `--dry-run` and `--verify` modes. |
| `04-deploy.sh` | Stage 4 — **per release, on every node.** Pulls a tag, builds, runs the Pest gate, migrates on the primary, rebuilds caches, reloads FPM. **Prompts for confirmation.** |
| `05-configure-workers.sh` | Stage 5 — scheduler cron (primary only), Horizon unit, meter-ingest timer. `--status` and `--remove` modes. **Prompts for confirmation.** |
| `nfs-latency-check.sh` | Diagnostic. Measures NFS stat latency against local disk for the paths Blade actually reads. Writes a 64 MB probe into the media export and removes it. |
| `NFS-SHARED-STORAGE.md` | Specification for the storage team: which paths must be shared between nodes, which must not, export requirements, fstab, verification. |
| `TROUBLESHOOTING.md` | Symptom-first index of the failures these scripts produce, and which fix is the correct one. |
| `README.md` | This file. |

Stages 1, 2, 3 and 5 are idempotent provisioning and safe to re-run. Stage 4 is the
per-release deploy and is idempotent for a clean re-run.

---

## 2. Prerequisites

- **Root.** Every script exits immediately if `$EUID != 0`.
- **RHEL 9.x**, x86_64.
- **An active Red Hat subscription**, attached and entitled. Stage 1 runs
  `subscription-manager repos --enable codeready-builder-for-rhel-9-x86_64-rpms`;
  a failure there is a warning, not a fatal error, but several Remi dependencies will
  not resolve without CRB.
- **SELinux enforcing is supported and expected.** Stage 2 sets the contexts and
  booleans required; do not disable it.
- **tmux** (or screen) available for stage 2 — see [Run order](#5-run-order).

### Network egress

The node must be able to reach, over HTTPS:

| Host | Needed for |
|---|---|
| Red Hat CDN (`cdn.redhat.com`) or your Satellite/Capsule | BaseOS, AppStream, CodeReady Builder, `nginx`, `composer` |
| `dl.fedoraproject.org` | `epel-release-latest-9.noarch.rpm` (and EPEL metadata thereafter, via its mirrors) |
| `rpms.remirepo.net` | `remi-release-9.rpm` and all Remi package/metadata fetches |
| `10.32.46.95:6379` | Redis, at runtime |
| The MySQL host | at runtime |
| An NFS server | at runtime, per `NFS-SHARED-STORAGE.md` |

Known-blocked on this estate, and deliberately routed around:

- **Plain HTTP to `rpms.remirepo.net` is dropped.** Every Remi `baseurl` is rewritten to
  `https://`.
- **`cdn.remirepo.net` returns 403.** That is the mirrorlist/metalink host, so mirrorlist
  and metalink are commented out and a single-host `baseurl` is used instead.
- **`getcomposer.org` is TLS-intercepted with an untrusted CA**, so the official installer
  cannot be signature-verified. Composer is installed from the distro repos
  (`dnf -y install composer`). **Do not "fix" this with `curl -k`** — that discards the only
  integrity check on a binary that runs with write access to the application tree.
- **`repo.packagist.org`** may be unreachable. If so, build `vendor/` on a host that can
  reach it and ship the directory to the node.

---

## 3. Configuration — `govexy-node.conf`

Every variable is listed. Stages 1 and 2 `source` this file, so a syntax error here
breaks both; stages 3, 4 and 5 read individual keys out of it with `grep`.

### Identity and locale

| Variable | Required | Default | Effect |
|---|---|---|---|
| `SERVER_TZ` | yes | `Asia/Dubai` | Stage 1 runs `timedatectl set-timezone`. Stage 2 also writes it as `date.timezone` in `/etc/php.d/99-govexy.ini`. |
| `NODE_HOSTNAME` | no | `""` | If non-empty, stage 1 runs `hostnamectl set-hostname`. Empty leaves the hostname untouched. Set it per node (`web1.govexy.local`, `web2.govexy.local`). |
| `NODE_ROLE` | yes | `secondary` | `primary` or `secondary`. Defaults to `secondary` so an unedited copy of this file cannot make a second scheduler by omission — set it to `primary` on exactly one node, deliberately. **Exactly one node in the estate is primary.** It is the node that runs migrations (`04-deploy.sh --primary`) and the only node allowed to carry the scheduler cron — `05-configure-workers.sh` refuses `--scheduler` anywhere else, because Laravel's scheduler has no cross-host lock and a second copy runs every triggered workflow twice. Horizon and the meter ingest run on every node regardless. |

### Backing services

| Variable | Required | Default | Effect |
|---|---|---|---|
| `REDIS_HOST` | **yes** | `10.32.46.95` | Stage 2 refuses to run if it is empty or not a valid IPv4 address. It is a documentation/validation value for the node — the application reads Redis from `.env`, which the scripts do not write. Keep the two in agreement. |
| `LB_IPS` | no | `""` | Space-separated IPv4 list. See below. |

#### `LB_IPS` — do not guess this value

`LB_IPS` becomes nginx's `set_real_ip_from` allowlist, written to
`/etc/nginx/conf.d/01-govexy-realip.conf` together with `real_ip_header X-Forwarded-For`
and `real_ip_recursive on`.

`set_real_ip_from` is an **allowlist of sources whose `X-Forwarded-For` header nginx will
believe**. Naming an address that is not actually your load balancer does not produce an
error and does not fail a config test. It silently instructs nginx to accept a forged
`X-Forwarded-For` from whoever occupies that address. The consequences are concrete:

- Laravel's rate limiting keys on the client IP. A forged header lets a caller present a
  different IP per request and never hit a throttle.
- Audit logs record the attacker-chosen value, so the record of who did what is wrong,
  and wrong in a way that is not obvious afterwards.

Leaving it empty is the safe state, and the scripts treat it as such. The generated
real-IP file then contains only an explanatory comment and no directives, so
`$remote_addr` stays the address that actually opened the TCP connection. Once a load
balancer is in front, that is the LB's own address on every request — rate limiting and
audit logs collapse onto a single value. Nothing is lost from the record: the true client
is still written to the access log as `xff="..."` by the `main_lb` log format. But nothing
is enforced per client either.

So: leave `LB_IPS` empty until the load balancer address is known **as a fact**, then apply
it with `--set-lb` (see [section 7](#7-adding-the-load-balancer-later)). Stage 2 validates
every entry as IPv4 and dies on a malformed one.

### Application

| Variable | Required | Default | Effect |
|---|---|---|---|
| `APP_ROOT` | yes | `/var/www/govexy` | Laravel root. Stage 2 creates it and `${APP_ROOT}/public` owned by `nginx:nginx`, sets SELinux fcontexts under it, and points the nginx `root` at `${APP_ROOT}/public`. Changing it after deployment means redoing the fcontext rules. |

### Install options

| Variable | Required | Default | Effect |
|---|---|---|---|
| `INSTALL_IMAGICK` | no | `yes` | `yes` adds `php-pecl-imagick` and `ImageMagick` to the stage 1 package set — PDF thumbnails and better image conversions. Any other value omits them. |

### Runtime tuning

| Variable | Required | Default | Effect |
|---|---|---|---|
| `PHP_MEMORY_LIMIT` | yes | `512M` | `php_admin_value[memory_limit]` on the **FPM pool only**. Deliberately not in `/etc/php.d/99-govexy.ini`, which both SAPIs read — a web-sized limit there also caps `artisan`, and that covers Horizon workers, `schedule:run`, `metering:ingest-edge`, `theme:publish-assets` and the content-bundle importers. Note `FPM_MAX_CHILDREN` x this value is the pool's theoretical ceiling: 50 x 512M is 25 GB. Size the node against it. |
| `PHP_CLI_MEMORY_LIMIT` | yes | `1024M` | `memory_limit` in `/etc/php.d/99-govexy.ini`, which the CLI reads. Should be the larger of the two. `04-deploy.sh` passes its own `php -d memory_limit=1G` for the test run rather than relying on it. |
| `PHP_UPLOAD_MAX` | yes | `128M` | `upload_max_filesize` — the largest **single file**. |
| `PHP_POST_MAX` | no | `PHP_UPLOAD_MAX` + 8M | `post_max_size` in php.ini and `client_max_body_size` in nginx. **Must exceed `PHP_UPLOAD_MAX`.** A multipart request carrying a file of exactly `PHP_UPLOAD_MAX` is larger than it once boundaries, field names and the CSRF token are counted; PHP then discards the whole body and raises nothing, so `$_POST` and `$_FILES` arrive empty, Laravel sees no CSRF token and returns **419** — a failure that reads as a session problem rather than a size one. They are two values precisely so they can differ in this one controlled direction. |
| `FPM_MAX_CHILDREN` | yes | `50` | `pm.max_children` in the `www` pool. The rest of the pm tuning is fixed in the script: `pm = dynamic`, `start_servers 8`, `min_spare 6`, `max_spare 12`, `max_requests 500`. |

### Firewall

| Variable | Required | Default | Effect |
|---|---|---|---|
| `RESTRICT_HTTP_TO_LB` | yes | `no` | `no` opens the `http` and `https` firewalld services to everyone. `yes` removes both and instead adds a rich rule accepting `http` only from each `LB_IPS/32`. Stage 2 **dies** if this is `yes` while `LB_IPS` is empty — that combination would firewall the node off from everything. |

### Deploy

| Variable | Required | Default | Effect |
|---|---|---|---|
| `DO_TESTS` | yes | `true` | Whether `04-deploy.sh` runs the Pest suite as a gate before migrating. `false` makes skipping the default for this environment. `--with-tests` and `--skip-tests` on the command line both override it, in either direction — an explicit flag always wins. Note the environment variable `DO_TESTS` does **not**: only this file and the command line can turn the gate off. |

Costs about ten minutes of maintenance mode per node and blocks the deploy on failure.
A hotfix already tested elsewhere is a fair reason to pass `--skip-tests`; a release that
has been tested nowhere is not.

---

## 4. Two-node notes before you start

Both nodes get the same treatment. The values that must differ, and the values that must
not:

| Item | Per node | Identical across nodes |
|---|---|---|
| `NODE_HOSTNAME` | differs | — |
| `REDIS_HOST`, `APP_ROOT`, tuning, `LB_IPS`, `RESTRICT_HTTP_TO_LB` | — | identical |
| `APP_KEY` in `.env` | — | **byte-identical** (see [section 8](#8-what-the-scripts-do-not-do)) |
| `nginx` UID/GID | — | identical, and matching the NFS export (see `NFS-SHARED-STORAGE.md`) |

---

## 5. Run order

Five stages. 1 to 3 provision the node and run once; 4 runs once per release on every
node; 5 runs once per node after the first deploy.

| Stage | Script | When | Where |
|---|---|---|---|
| 1 | `01-install-dependencies.sh` | once | every node |
| 2 | `02-configure-nginx-php.sh` | once | every node |
| 3 | `03-mount-shared-storage.sh` | once | every node |
| 4 | `04-deploy.sh --ref <tag>` | every release | every node, **primary first** |
| 5 | `05-configure-workers.sh` | once, after the first deploy | scheduler on the primary only; Horizon and the meter ingest everywhere |

Copy the whole directory to the node (the whole directory, not a subset — the scripts
resolve `govexy-node.conf` relative to their own path), edit `govexy-node.conf`, then:

```bash
cd /root/govexy-deployment-scripts/rhel9.4
vim govexy-node.conf
```

### Stage 1 — dependencies

No prompts. Long-running (Remi metadata over an inspected link, plus the RHSM package
profile uploader holding the dnf lock roughly 180 s after each transaction), so it is
fine to background:

```bash
nohup bash 01-install-dependencies.sh > /root/govexy-stage1.log 2>&1 &
tail -f /root/govexy-stage1.log
```

Or run it in the same tmux session you will use for stage 2.

### Stage 2 — configuration

Stage 2 **asks for confirmation** (`Correct? [y/N]`) after echoing the resolved
`LB_IPS`/`REDIS_HOST`/`APP_ROOT`. Under `nohup` that read gets EOF and the script aborts.
Run it under **tmux**:

```bash
tmux new -s govexy
bash 02-configure-nginx-php.sh
# answer y, then detach with Ctrl-b d if needed; reattach with:
tmux attach -t govexy
```

### Stage 3 — shared storage

Interactive. Binds `<export>/media`, `<export>/private` and `<export>/themes` onto
`storage/app/public`, `storage/app/private` and `resources/themes`. Run `--verify` first
on a node that is already set up; run it under tmux for the same reason as stage 2.

```bash
bash 03-mount-shared-storage.sh --dry-run   # show the plan
bash 03-mount-shared-storage.sh             # do it
bash 03-mount-shared-storage.sh --verify    # check an existing setup
```

### Stage 4 — deploy a release

Per release, on every node, **primary first**. `--ref` is required and must name a tag:
without it each node deploys whatever the tracked branch's HEAD happens to be when that
node runs, and a push between the first node and the second splits the pair.

```bash
# primary node — runs migrations
bash 04-deploy.sh --ref v1.4.24 --primary

# every other node, same ref, one at a time
bash 04-deploy.sh --ref v1.4.24
```

The node enters maintenance mode before composer, npm, the build and the test gate, so
`/up` returns 503 and the load balancer drains it. A non-primary node refuses to deploy
while migrations are pending, and refuses a ref the primary did not deploy. The script
exits non-zero if `/up` is not 200 afterwards — do not deploy the next node until it is.

Flags: `--allow-branch`, `--no-pull`, `--skip-build`, `--skip-composer`, `--with-tests`
(default), `--skip-tests`, `--tests-advisory`, `--dry-run`. `DO_TESTS=false` in
`govexy-node.conf` makes skipping the default for the environment; `--with-tests` on the
command line overrides it.

### Stage 5 — scheduler and workers

Once per node, after the first successful deploy.

```bash
# primary (NODE_ROLE=primary in govexy-node.conf)
bash 05-configure-workers.sh --scheduler --horizon --meter-ingest

# every other node
bash 05-configure-workers.sh --horizon --meter-ingest

bash 05-configure-workers.sh --status
```

`--scheduler` is refused unless `NODE_ROLE=primary`. Laravel's scheduler has no
cross-host lock, so a second copy runs every triggered workflow twice.

Then repeat stages 1 to 3 and 5 on the second node, and stage 4 for every release.

---

## Upgrading from an earlier copy of these scripts

`04-deploy.sh` now refuses to deploy unless four keys are right in `.env`. On an
existing node the first run will abort until they are present — check them before
the deploy window, not during it:

```bash
grep -E '^(APP_ENV|APP_DEBUG|TELESCOPE_ENABLED|LICENSE_MODE)=' /var/www/govexy/.env
```

| Key | Required value | Why the deploy refuses without it |
|---|---|---|
| `APP_ENV` | `production` | Gates a dozen framework safeguards. |
| `APP_DEBUG` | `false` | Otherwise stack traces, config values and the DSN reach visitors. |
| `TELESCOPE_ENABLED` | `false` | **Most likely to be missing.** `config/telescope.php` defaults it to `true`, and `laravel/telescope` is in `require`, so `--no-dev` leaves it installed. The UI is gated but the *recording* is not: every request, query, job and payload is written to `telescope_entries`, unbounded, on government data. It is absent from older `.env` files, so add it. |
| `LICENSE_MODE` | present (`onprem`) | `onprem` and `saas` are different products. |

Four other changes affect an existing estate:

- **`PHP_POST_MAX`** is new in `govexy-node.conf`. A conf written before it existed still
  works — stage 2 derives `PHP_UPLOAD_MAX + 8M` — but set it explicitly if you want a
  different ceiling. It must be strictly greater than `PHP_UPLOAD_MAX`, and stage 2 now
  refuses to run if it is not.

- **`NODE_ROLE`** is new in `govexy-node.conf` and defaults to `secondary`. Set it to
  `primary` on the one node that runs migrations and the scheduler, or
  `05-configure-workers.sh --scheduler` will refuse.
- **`--ref` is now required** for a deploy that pulls. There is no "deploy whatever is on
  the branch" path any more.
- **`--primary` must agree with `NODE_ROLE`.** `04-deploy.sh` refuses a run where one says
  primary and the other does not, in either direction.

---

## Rollback

There are no release directories and no symlink switch: the tree is deployed in place.
So a rollback is a **redeploy of the previous tag**, on every node, primary first:

```bash
# find the tag that was running
git -c safe.directory=/var/www/govexy -C /var/www/govexy tag --sort=-creatordate | head

bash 04-deploy.sh --ref v1.4.23 --primary --skip-tests   # primary
bash 04-deploy.sh --ref v1.4.23 --skip-tests             # every other node
```

Three things this does and does not do:

- **It does restore the code, `vendor/`, `public/build` and every cache.** composer and
  npm are re-run against the old lock files and the caches are rebuilt from the old
  source, so nothing of the new release survives in the tree.
- **It does NOT reverse migrations.** They stay applied. This is why every migration must
  be backward compatible with the release before it — add a column in one release, stop
  writing the old one in the next, drop it in a third (expand/contract). A release that
  drops or renames a column in a single step cannot be rolled back at all.
- **Do NOT use `git reset --hard`.** It restores tracked paths, and `resources/themes` is
  both tracked and an NFS bind mount, so it would put shipped themes over admin-uploaded
  ones on the shared export — the same hazard as `git clean`, which the deploy script
  refuses outright. `04-deploy.sh --ref` is the supported route.

The primary records the deployed ref at `storage/app/private/.deployed-ref` on the shared
export, so a rolled-back primary makes every other node refuse the newer ref until it is
rolled back too.

---

## 6. What each script does

### `01-install-dependencies.sh` — install only, starts nothing

| Step | Actions |
|---|---|
| 1/7 Base system | `hostnamectl set-hostname` if `NODE_HOSTNAME` set; `timedatectl set-timezone`; enable CodeReady Builder (warn on failure); install `epel-release` from `dl.fedoraproject.org` if absent; install `dnf-plugins-core policycoreutils-python-utils firewalld chrony vim unzip tar git curl`; `systemctl enable --now chronyd firewalld`. |
| 2/7 dnf tolerance | Sets `timeout=300`, `minrate=100`, `retries=10` in `/etc/dnf/dnf.conf`. The stock `minrate=1000` B/s is what produced `Curl error (28): Operation too slow` on Remi metadata through this proxy. |
| 3/7 nginx | `dnf -y install nginx` from AppStream. Warns if the binary lacks `http_realip_module` (which would make LB real-IP impossible). **Does not start it** — stage 2 writes the vhost first. |
| 4/7 Remi | Installs `remi-release-9.rpm` from `rpms.remirepo.net`. Backs up each `/etc/yum.repos.d/remi*.repo` to `.bak`, then comments out `mirrorlist=`/`metalink=`, uncomments `baseurl=`, and forces the baseurl to `https://rpms.remirepo.net/`. Enables `remi-safe` and `remi-modular`. `dnf clean all && dnf makecache`. |
| 5/7 PHP 8.4 | `dnf module reset php`, `dnf module enable php:remi-8.4`, and **dies** if that stream is not then marked enabled. Installs, in one transaction: `php-cli php-fpm php-common php-mbstring php-xml php-gd php-intl php-bcmath php-opcache php-mysqlnd php-pdo php-sodium php-process php-pecl-zip php-pecl-redis6`, plus `php-pecl-imagick ImageMagick` when `INSTALL_IMAGICK=yes`. One transaction on purpose — each extra `dnf install` costs another RHSM uploader wait. |
| 6/7 Composer | `dnf -y install composer` if not already on `PATH`. Distro package, not `getcomposer.org` — see [prerequisites](#network-egress). |
| 7/7 Verification | **Dies** unless `php -v` reports 8.4. Warns (does not fail) on any missing extension from: `curl fileinfo intl mbstring redis sodium zip pcntl posix pdo_mysql gd bcmath openssl tokenizer dom xmlwriter exif`. Prints `php -v`, `composer --version`, `nginx -v`. |

### `02-configure-nginx-php.sh` — configuration, starts services

**Preflight** — dies if: not root; `nginx`, `php`, or `/etc/php-fpm.d` missing (run stage 1
first); PHP 8.4 not active; `REDIS_HOST` empty or not IPv4; any `LB_IPS` entry not IPv4;
or `RESTRICT_HTTP_TO_LB=yes` with `LB_IPS` empty. Then prints the resolved config and
requires an interactive `y`.

| Step | Actions |
|---|---|
| 1/6 PHP-FPM pool | Backs up `www.conf` to `www.conf.orig` (once), then overwrites it: user/group `nginx`, unix socket `/run/php-fpm/www.sock` (`0660`, owner/group nginx), `pm dynamic` with `FPM_MAX_CHILDREN`, slowlog at 10 s, error log `/var/log/php-fpm/www-error.log`. Creates `/var/lib/php/session` and `/var/lib/php/wsdlcache` as `root:nginx 0770`. |
| 2/6 PHP runtime | Writes `/etc/php.d/99-govexy.ini`: memory/upload limits, `max_execution_time 60`, `expose_php Off`, `date.timezone`, and opcache — 256 MB, 20000 files, `save_comments 1` (required: Laravel/Filament read annotations), **`validate_timestamps 0`** (see [operational notes](#10-operational-notes)). |
| 3/6 App dir + SELinux | Creates `APP_ROOT` and `APP_ROOT/public` as `nginx:nginx`. `semanage fcontext`: `httpd_sys_content_t` over the tree, `httpd_sys_rw_content_t` over `storage/` and `bootstrap/cache/`; `restorecon -R`. Booleans: `httpd_can_network_connect` (Redis), `httpd_can_network_connect_db` (remote MySQL), `httpd_use_nfs` (shared storage — without it every NFS read is denied while the file looks perfectly readable). |
| 4/6 nginx | Comments out the stock `server {}` block that RHEL ships **inside `nginx.conf`** (brace-depth aware, backup kept as `nginx.conf.bak.<epoch>`) since it collides on port 80; removes `conf.d/default.conf` if present. Writes `conf.d/00-govexy-http.conf` (`server_tokens off`, `client_max_body_size`, the `main_lb` log format including `xff=`/`rt=`/`upstream=`, gzip). Writes `conf.d/01-govexy-realip.conf` (directives if `LB_IPS` set, otherwise a comment-only file). Writes `conf.d/govexy.conf` — the vhost. Runs `nginx -t`. |
| 5/6 Firewall | Per `RESTRICT_HTTP_TO_LB`, as described in [configuration](#firewall). `firewall-cmd --reload`. |
| 6/6 Services | `systemctl enable --now php-fpm nginx`, then reloads both. Prints `systemctl is-active` for each and the HTTP status of `http://127.0.0.1/up`. Warns about the opcache reload requirement, and about the missing LB trust if `LB_IPS` is empty. |

#### The vhost, `/etc/nginx/conf.d/govexy.conf`

`listen 80 default_server`, `server_name _`, root `${APP_ROOT}/public`. TLS is expected to
terminate at the load balancer. `HTTPS` is passed to PHP through the `$govexy_https`
**map**, which yields `on` only for `X-Forwarded-Proto: https` and an empty string
otherwise — the raw header cannot be forwarded, because Symfony's `Request::isSecure()`
treats any non-empty value that is not `off` as secure, so a plaintext request carrying
`X-Forwarded-Proto: http` would have been seen as HTTPS.

| Location | Behaviour |
|---|---|
| `/up` (application route) | The load balancer health check target. It boots the framework, so it fails when PHP-FPM, MySQL or Redis are down. There is deliberately **no** nginx-only health endpoint: one would answer 200 on a node whose PHP is dead, and for the whole maintenance window of a deploy. |
| `= /favicon.ico` | Not logged. |
| `/` | `try_files $uri $uri/ /index.php?$query_string`. |
| `~ ^/index\.php(/|$)` | The only FastCGI pass, and it is `internal;` — reachable only via an internal rewrite, never directly. Hides `X-Powered-By`, 60 s read timeout. |
| `~ \.php$` | `return 404` — nothing else executes PHP. |
| `^~ /.well-known/` | Passed through to `index.php`: the application serves tenant-managed verification files and ACME challenges. |
| `~ /\.` | `deny all` — all other dotfiles. |
| `^~ /storage/theme-dist/` | Published theme assets. `gzip_static on`, `Cache-Control: public, max-age=31536000, immutable`, `try_files $uri =404` — a miss is a cheap 404, never a Laravel boot. `^~` so it beats the static-asset regex below. Inert until the application sets `THEME_ASSETS_SERVE_PUBLISHED=true`; see [Published theme assets](#published-theme-assets). |
| `@theme_dist_404` | Internal named location. `error_page 404 = @theme_dist_404` inside the block above resets the server-level `error_page 404 /index.php`, so a theme-dist miss is answered by nginx and never boots the framework. Stage 2 probes it by **body size**, because Laravel also answers 404. |
| static assets | 30 d `expires`, `Cache-Control: public, max-age=2592000` — deliberately **not** `immutable`, because these URLs carry no content hash and a tenant's replaced logo would not reach returning visitors. Access log deliberately **ON**: `public/storage` symlinks to the media export, so these bytes are served without PHP ever seeing them and the log is the only place they can still be counted for bandwidth metering. Falls back to `index.php`. |
| `^~ /telescope`, `^~ /pulse` | `return 404`. Defence in depth — both are gated in the application and `04-deploy.sh` refuses to deploy unless `TELESCOPE_ENABLED=false`. `/horizon` is deliberately left reachable. |
| `error_page 404` | `/index.php` — Laravel renders 404s. |

`gzip_static on` in the theme-dist block needs `ngx_http_gzip_static_module`; stage 2
warns if nginx was built without it.

---

### Published theme assets

`storage/app/public/theme-dist/{slug}/{buildId}/` holds one released theme version's asset
tree, copied there once at release time and never edited. `{buildId}` is an HMAC over a
digest of that tree, so a changed theme is a changed URL: there is nothing to purge and
nothing to coordinate between the nodes. It lives on the shared NFS export and is already
reachable through the `public/storage` symlink, so no new mount is needed.

**`immutable, max-age=1y` is a one-way door.** Once a page has handed those URLs out, the
copies in visitors' browsers cannot be recalled. Two consequences that are not optional:

- Old build directories are kept for a grace window (30 days by default) after nothing
  references them any more, so a page held in a corporate proxy renders with the older
  theme rather than unstyled.
- Nothing deletes them automatically. `php artisan theme:assets-gc` reports; only
  `--force` deletes, and it refuses anything inside the grace window.

Operator sequence, in this order:

```bash
# 1. Both nodes get the location block (this script is idempotent).
bash 02-configure-nginx-php.sh

# 2. Materialise every already-released version. Safe with the flag off, and
#    idempotent — the build id is a digest, so re-running lands on the same
#    directory. Run it on ONE node; the tree is shared.
php artisan theme:publish-assets --all

# 3. Verify on one tenant, then turn it on in .env on BOTH nodes:
#       THEME_ASSETS_SERVE_PUBLISHED=true
php artisan config:cache && systemctl reload php-fpm
```

To roll back, set the flag to `false` and reload. `theme_asset()` falls straight back to
the PHP route, which is never removed by this step, and there is no data migration to undo.

Housekeeping, when an operator decides to run it:

```bash
php artisan theme:assets-gc            # report only
php artisan theme:assets-gc --force    # delete builds past the grace window
```

---

## 7. Adding the load balancer later

When the LB address is known — and only then — run this **on every web node**:

```bash
bash 02-configure-nginx-php.sh --set-lb 10.32.46.10
# clustered LB:
bash 02-configure-nginx-php.sh --set-lb 10.32.46.10 10.32.46.11
```

This mode short-circuits everything else: it validates each argument as IPv4 (dying on a
bad one), rewrites **only** `/etc/nginx/conf.d/01-govexy-realip.conf`, runs `nginx -t`, and
`systemctl reload nginx`. No packages, no prompts, no service restarts, no other file
touched.

Afterwards, record the same value in `govexy-node.conf` on every node, so a future full
re-run of stage 2 does not silently drop the trust configuration.

If you also want to close port 80 to everything except the LB, set
`RESTRICT_HTTP_TO_LB="yes"` and `LB_IPS="<ip> ..."` in `govexy-node.conf` and re-run stage 2
in full — `--set-lb` does not touch firewalld.

---

## 8. What the scripts do NOT do

The node serves nginx and PHP-FPM after stage 2, but the application is not deployed.
Remaining work, per node unless stated:

1. **Mount shared storage.** Three NFS mounts, `fstab` entries, export requirements and
   verification are all in `NFS-SHARED-STORAGE.md`. Do this before deploying code —
   `resources/themes` is inside the code tree and a `--delete` style deploy will destroy
   it.

2. **Deploy application code** into `APP_ROOT`.

3. **Install PHP dependencies as the app user, never as root:**

   ```bash
   sudo -u nginx composer install --no-dev --optimize-autoloader
   ```

   Running Composer as root leaves root-owned files in `vendor/` and `bootstrap/cache/`
   that php-fpm (running as `nginx`) cannot rewrite. If `repo.packagist.org` is unreachable,
   build `vendor/` elsewhere and ship it.

4. **Write `.env`** — the scripts write no application configuration. It must be identical
   on both nodes, in particular:

   | Key | Value / rule |
   |---|---|
   | `APP_KEY` | **byte-identical on both nodes.** Differing keys break sessions and encrypted cookies the moment the load balancer moves a user between nodes. Generate once, copy. |
   | `CACHE_STORE` | `redis` |
   | `SESSION_DRIVER` | `redis` |
   | `QUEUE_CONNECTION` | `redis` |
   | `REDIS_CLIENT` | `phpredis` (the `php-pecl-redis6` extension stage 1 installs) |
   | `REDIS_HOST` | the Redis server, `10.32.46.95` |
   | `DB_HOST` | the MySQL server |

   Sessions, cache and queue all live in Redis precisely so the two nodes share no local
   state.

5. **Ownership and SELinux relabel after deploying code:**

   ```bash
   chown -R nginx:nginx /var/www/govexy/storage /var/www/govexy/bootstrap/cache
   restorecon -R /var/www/govexy
   ```

6. **`storage:link`** — on **every** node. The symlink is node-local: it lives in
   `public/`, which is not shared, so creating it on one node does nothing for the other
   (see `NFS-SHARED-STORAGE.md` §6). `04-deploy.sh` creates it per node and warns if an
   existing link points somewhere other than `storage/app/public`.

   ```bash
   sudo -u nginx php artisan storage:link
   ```

7. **Cache the framework artifacts, then reload FPM:**

   ```bash
   sudo -u nginx php artisan config:cache
   sudo -u nginx php artisan route:cache
   sudo -u nginx php artisan view:cache
   sudo -u nginx php artisan event:cache
   systemctl reload php-fpm
   ```

   `event:cache` is in the list because `04-deploy.sh` builds it too; a node cached by
   hand without it behaves differently from one the deploy script touched.

   These write to `bootstrap/cache` and `storage/framework/views`, both of which are
   node-local by design — so run them on **every** node, every deploy.

8. **Decide scheduler and queue worker placement** — see below.

Also out of scope: MySQL, Redis, the NFS server, the load balancer, TLS certificates
(terminate at the LB), and log shipping.

---

## 9. Verification

Stage 2 already prints service state and the /up status. To check by hand:

```bash
php -v | head -1
# PHP 8.4.x (cli) (built: ...)

php -m | grep -E '^(redis|intl|sodium|zip|pdo_mysql|gd|bcmath|imagick)$'
# each name listed once

composer --version
nginx -v

systemctl is-active php-fpm nginx
# active
# active

nginx -t
# nginx: configuration file /etc/nginx/nginx.conf test is successful

curl -s --noproxy '*' -o /dev/null -w '%{http_code}\n' http://127.0.0.1/up
# 200

curl -s --noproxy '*' http://127.0.0.1/up
# ok
```

Socket, SELinux and firewall:

```bash
ls -l /run/php-fpm/www.sock
# srw-rw---- 1 nginx nginx ... /run/php-fpm/www.sock

getsebool httpd_can_network_connect httpd_can_network_connect_db httpd_use_nfs
# all --> on

firewall-cmd --list-all
# services: ... http https        (RESTRICT_HTTP_TO_LB=no)
# rich rules: rule family="ipv4" source address="<lb>/32" service name="http" accept
```

Real-IP trust and opcache:

```bash
cat /etc/nginx/conf.d/01-govexy-realip.conf
# either set_real_ip_from lines, or a comment-only file if no LB is configured yet

php -i | grep -E 'opcache.enable|validate_timestamps|save_comments|memory_consumption'
```

Backing services reachable from the node:

```bash
timeout 3 bash -c '</dev/tcp/10.32.46.95/6379' && echo 'redis port open'
timeout 3 bash -c '</dev/tcp/<mysql-host>/3306'  && echo 'mysql port open'

# through the PHP extension, which is what actually matters:
php -r '$r = new Redis; var_dump($r->connect("10.32.46.95", 6379));'
# bool(true)
```

Once the LB is in front, confirm the real client IP is being recovered — the leading field
of `/var/log/nginx/govexy-access.log` should be the client, not the LB, and should match
the `xff=` field:

```bash
tail -n 5 /var/log/nginx/govexy-access.log
```

If SELinux is suspected (particularly on NFS paths), check the actual denials rather than
guessing at permissions:

```bash
ausearch -m AVC -ts recent
```

---

## 10. Operational notes

**`opcache.validate_timestamps = 0` — every deploy must reload PHP-FPM.**
PHP will never re-stat a source file. New code on disk is invisible until the opcode cache
is dropped. The last step of every deployment, on every node, is:

```bash
systemctl reload php-fpm
```

Skip it and the node serves the previous release with no error anywhere to explain it. The
usual failure mode is a half-deployed pair: one node reloaded, one not, and behaviour that
changes depending on which node the load balancer picked.

**Scheduler runs on ONE node only.**
`php artisan schedule:run` installed on both nodes means every scheduled job fires twice —
duplicate emails, duplicate publications, duplicate workflow transitions. Put the cron
entry on one node, and have a documented procedure to move it if that node is lost.

**Queue worker placement is a deliberate decision, not a default.**
Workers may run on one node, both, or dedicated hosts. Both is fine for throughput (Redis
distributes the jobs) but doubles the concurrency the database and any rate-limited
outbound service sees, and doubles the memory pressure on nodes that are also serving web
traffic. Decide explicitly, write it down, and keep the two nodes' supervisor configuration
in sync with that decision. Whatever you choose, workers hold code in memory and must be
restarted on deploy (`php artisan queue:restart`) just as FPM must be reloaded.

**Shared storage is not optional in a two-node deployment.**
With `storage/app/public` on local disk, a file uploaded through web1 returns 404 from
web2. `resources/themes` has the same problem and is the one people miss because it lives
in the code tree. See `NFS-SHARED-STORAGE.md`.

**Re-running the scripts.** Both are idempotent. Stage 2 rewrites
`/etc/php-fpm.d/www.conf`, `/etc/php.d/99-govexy.ini` and the three
`/etc/nginx/conf.d/*govexy*.conf` files from `govexy-node.conf` every time — local edits to
those files are lost. Put changes in `govexy-node.conf`, or in a separate `conf.d` file the
script does not own. Originals are preserved as `www.conf.orig`, `remi*.repo.bak` and
`nginx.conf.bak.<epoch>`.
