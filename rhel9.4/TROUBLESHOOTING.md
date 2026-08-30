# GovExy web node — RHEL 9.4 build troubleshooting

Every failure recorded here was hit while bringing up the first web node on this
estate, or is a direct consequence of that node's environment and will recur on
the second. Error text is quoted exactly as it appeared.

Most of these are network failures wearing a package-manager costume. Read the
cause before applying the fix — several have a correct fix owned by another team
and a workaround that the scripts already apply.

---

## 0. Running the scripts

### Use tmux

Both scripts run long. Stage 1 waits on the RHSM uploader after every dnf
transaction (see [issue 3](#3-dnf-hangs-after-a-transaction-completes)), and on a
slow proxied link the Remi metadata fetch alone can take minutes. An SSH drop
part way through a `dnf` transaction leaves the rpm database mid-write.

```bash
tmux new -s govexy
sudo bash 01-install-dependencies.sh 2>&1 | tee /root/govexy-stage1.log
```

Detach with `Ctrl-b d`, reattach with `tmux attach -t govexy`.

**Do not use `nohup` or `&`.** `02-configure-nginx-php.sh`, `03-mount-shared-storage.sh`,
`04-deploy.sh` and `05-configure-workers.sh` all stop at a confirmation prompt:

```
==> Config: LB=[<none yet>]  REDIS=10.32.46.95  APP_ROOT=/var/www/govexy
Correct? [y/N]
```

With stdin detached, `read` hits EOF and returns **non-zero**, and under `set -e`
that terminated the script *before* the `[fail] aborted` message — so what an
operator actually saw was **exit 1 and a blank screen**, not the `N` branch. The
scripts now print "no terminal to confirm on (non-interactive run)" instead, but
the fix is the same: tmux keeps the terminal, so the prompt works.

### Where the logs are

| What | Path |
|---|---|
| Script output | wherever you `tee` it; nothing is written automatically |
| dnf transaction history | `/var/log/dnf.log`, `/var/log/dnf.rpm.log`, `dnf history` |
| nginx (GovExy vhost) | `/var/log/nginx/govexy-access.log`, `/var/log/nginx/govexy-error.log` |
| PHP-FPM | `/var/log/php-fpm/www-error.log`, `/var/log/php-fpm/www-slow.log` |
| SELinux denials | `ausearch -m AVC -ts recent` (raw: `/var/log/audit/audit.log`) |

### Re-running is safe

Stages 1, 2, 3 and 5 are idempotent by design and are meant to be re-run after a
fix. Stage 4 (the deploy) is idempotent for a clean re-run; see
[issue 11](#11-a-deploy-failed-part-way) for resuming a partial failure.

- Stage 1 guards installs with `rpm -q` / `command -v`, backs up each Remi repo
  file once to `<file>.bak`, and rewrites `/etc/dnf/dnf.conf` keys in place
  rather than appending duplicates.
- Stage 2 rewrites the files it owns (`/etc/php-fpm.d/www.conf`,
  `/etc/php.d/99-govexy.ini`, `/etc/nginx/conf.d/*govexy*.conf`) from scratch
  every time, keeping `/etc/php-fpm.d/www.conf.orig` as the untouched original.
  The nginx default-server edit only fires when an uncommented `server {` block
  is still present.

The one thing that accumulates: each run of stage 2 that finds a live default
server block writes a new `/etc/nginx/nginx.conf.bak.<epoch>`. Harmless, but if
you see several, only the oldest is the true stock file.

If a stage 1 run died mid-transaction, run `dnf history` and, if the last entry
is incomplete, `dnf history redo`/`rollback` before re-running — otherwise just
re-run the script.

---

## 1. Remi release RPM returns 403

**Symptom**

```
Status code: 403 for http://rpms.remirepo.net/enterprise/remi-release-9.rpm
```

**Cause**

The corporate proxy blocked the host. This is an outbound policy decision, not a
repository problem — remirepo.net was serving the file fine to anyone else.

**Fix**

The network team allowlisted `rpms.remirepo.net`. There is no client-side
workaround; nothing in the scripts can route around a proxy denial.

When requesting the allowlist, ask for the host over **HTTPS** (see
[issue 6](#6-plain-http-to-rpmsremireponet-returns-zero-bytes)) and be explicit
that a mirrorlist host is not an acceptable substitute (see
[issue 4](#4-403-from-cdnremireponet-the-mirrorlist-host)).

**Verify**

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://rpms.remirepo.net/enterprise/remi-release-9.rpm
# expect: 200
rpm -q remi-release
```

---

## 2. TLS certificate failure on getcomposer.org

**Symptom**

```
curl: (60) SSL certificate problem: unable to get local issuer certificate
```

Seen on both `https://getcomposer.org` and `https://composer.github.io` — i.e.
both the installer and the installer signature endpoint.

**Cause**

The proxy performs TLS inspection: it terminates the connection, presents its own
certificate signed by the corporate root CA, and re-originates outbound. That CA
is not in this host's trust store, so every verification against it fails. Nothing
is wrong with the remote certificate.

**Correct fix**

Install the corporate root CA. This requires the actual certificate file from the
security team; do not fabricate it from what the proxy presents.

```bash
cp corporate-root-ca.crt /etc/pki/ca-trust/source/anchors/
update-ca-trust extract
```

**Workaround used by the scripts**

Stage 1 installs Composer from the distro repositories instead of running the
upstream installer:

```bash
command -v composer &>/dev/null || dnf -y install composer
```

That path is verified by rpm signatures against a repo the host already trusts,
so it sidesteps the missing CA entirely.

### Never use `curl -k` to fetch an executable

`curl -k` (and `--insecure`, and `git config http.sslVerify false`) does not
"work around a certificate problem". It **discards the only integrity check on
the download**. Certificate verification is what proves the bytes came from
getcomposer.org and were not modified in transit; with `-k` you are piping an
unauthenticated binary from an unauthenticated source straight into `php` as
root. On an inspected link, where something is provably already sitting in the
middle of the connection, that is not a theoretical objection.

The upstream installer's own SHA-384 check does not rescue this either — that
checksum is fetched from `composer.github.io` over the same unverified channel.

If Composer must come from upstream, fix the trust store. Otherwise use the
distro package.

**Verify**

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://getcomposer.org/installer   # 200 once CA is trusted
composer --version
```

---

## 3. dnf hangs after a transaction completes

**Symptom**

The transaction finishes, then:

```
Waiting for process with pid 41287 to finish
```

and nothing moves. Roughly three minutes per occurrence, after *every* dnf
transaction.

**Cause**

```bash
ps -p 41287 -o pid,etime,cmd
#   PID     ELAPSED CMD
# 41287       02:14 /usr/libexec/rhsm-package-profile-uploader
```

Red Hat Subscription Manager runs a package-profile uploader on every rpm
transaction and it holds the dnf lock while it runs. It is trying to reach
`subscription.rhsm.redhat.com`, egress to which is blocked here, so it sits until
its own timeout expires. The bound is `server_timeout` in `/etc/rhsm/rhsm.conf`
(default `180`) — which is exactly the ~3 minutes observed.

**Ctrl-C does not help.** SIGINT reaches dnf, not the uploader. dnf dies, the
uploader keeps running and keeps the lock, and the next dnf invocation prints the
same `Waiting for process with pid …` line and waits out the remainder. You have
converted one wait into two.

**Correct fix (network / platform)**

Either is durable, both are outside these scripts:

- Allow egress to `subscription.rhsm.redhat.com`, or
- Point RHSM at the proxy. RHSM has first-class proxy support — set in
  `/etc/rhsm/rhsm.conf`:

  ```ini
  proxy_hostname = <proxy host>
  proxy_port     = <proxy port>
  ```

This host already has a Satellite Capsule (`no_proxy = rhcapsule.ishj.ae`), so
the strategic answer for this estate is to **sync the Remi repository into
Satellite** and consume PHP 8.4 from the Capsule. That removes the internet
dependency for packages entirely and makes issues 1, 4, 5 and 6 disappear along
with this one. Treat everything else here as bridging until that happens.

**Mitigation in the scripts**

Stage 1 batches package installs into as few transactions as possible — the whole
PHP set is one `dnf -y install "${PHP_PKGS[@]}"` — because the wait is per
transaction, not per package. Do not "helpfully" split those installs up.

**Verify**

```bash
grep -E '^(server_timeout|proxy_hostname|proxy_port)' /etc/rhsm/rhsm.conf
time dnf -y install vim   # already installed; measures the post-transaction wait
```

A second dnf command that starts immediately, rather than printing
`Waiting for process with pid …`, means the uploader is no longer blocking.

---

## 4. 403 from cdn.remirepo.net (the mirrorlist host)

**Symptom**

```
Status code: 403 for http://cdn.remirepo.net/enterprise/9/modular/x86_64/mirror
```

after `rpms.remirepo.net` had already been allowlisted and the release RPM
installed cleanly.

**Cause**

Two separate problems stacked.

1. The stock Remi `.repo` files do not use the host you allowlisted. They resolve
   through `mirrorlist=` / `metalink=` on **`cdn.remirepo.net`**, a different
   hostname, which is still blocked.
2. Allowlisting `cdn.remirepo.net` would not settle it either. A mirrorlist is not
   a content endpoint — it returns a rotating list of third-party mirror
   hostnames, different ones on different days and from different source IPs.
   Every one of those would need to be allowlisted too, and the set changes
   without notice. It is a permanently moving target.

**Fix**

Pin to the one approved host. Stage 1 does this for every `remi*.repo` file,
after taking a one-time `.bak` copy:

```bash
sed -i \
  -e 's|^mirrorlist=|#mirrorlist=|' \
  -e 's|^metalink=|#metalink=|' \
  -e 's|^#baseurl=|baseurl=|' \
  -e 's|^baseurl=http://rpms\.remirepo\.net/|baseurl=https://rpms.remirepo.net/|' \
  "$f"
```

Note the ordering: comment out the mirrorlist/metalink, uncomment the baseurl the
package ships commented, then force it to HTTPS.

If Remi ever ships a new `.repo` file (a `remi-release` update), the pinning must
be re-applied — re-run stage 1.

**Verify**

```bash
grep -E '^(mirrorlist|metalink|baseurl)' /etc/yum.repos.d/remi*.repo
# expect: no live mirrorlist= or metalink=, every baseurl= on https://rpms.remirepo.net/
dnf repolist | grep remi
dnf makecache
```

---

## 5. dnf gives up on a slow link

**Symptom**

```
Curl error (28): Timeout was reached for https://rpms.remirepo.net/... [Operation too slow. Less than 1000 bytes/sec transferred the last 30 seconds]
```

**Cause**

dnf's `minrate` default is **1000 bytes/sec**. If a transfer drops below that for
`timeout` seconds, dnf aborts it. Through this proxy, Remi metadata regularly
transfers slower than 1 KB/s for stretches — not stalled, just slow. The default
threshold treats that as a dead connection.

**Fix**

Stage 1 relaxes all three knobs in `/etc/dnf/dnf.conf`, replacing existing keys
in place rather than appending duplicates:

```ini
timeout=300
minrate=100
retries=10
```

**Verify**

```bash
grep -E '^(timeout|minrate|retries)=' /etc/dnf/dnf.conf
dnf clean all && dnf makecache
```

`makecache` completing — even slowly — is the test. If it still errors with
Curl 28 at 100 B/s, the link is not slow, it is broken; go to issue 6.

---

## 6. Plain HTTP to rpms.remirepo.net returns zero bytes

**Symptom**

HTTP requests to remirepo.net do not fail — they hang and return nothing. No
response headers, no body, no error, until the client's own timeout fires. The
identical path over HTTPS is fast.

**Cause**

Something on the path silently drops plain HTTP to this host: the connection is
accepted, then nothing is ever returned. HTTPS is passed through (or inspected
and re-originated) normally. This matters because the Remi release RPM's own
`.repo` files ship `http://` baseurls, so a repo that looks correctly configured
produces mysterious, non-specific timeouts.

**Diagnostics used to isolate it**

Compare the two schemes on the same path, bounded, printing transfer rate and
byte count. This is the pair of commands that made the difference obvious:

```bash
curl -s -o /dev/null --max-time 30 \
     -w 'http  %{speed_download} B/s   got: %{size_download} bytes\n' \
     http://rpms.remirepo.net/enterprise/9/remi/x86_64/repodata/repomd.xml

curl -s -o /dev/null --max-time 30 \
     -w 'https %{speed_download} B/s   got: %{size_download} bytes\n' \
     https://rpms.remirepo.net/enterprise/9/remi/x86_64/repodata/repomd.xml
```

Observed:

```
http  0 B/s        got: 0 bytes
https 244605 B/s   got: 348807 bytes
```

Zero bytes *and* zero headers after a full 30 seconds is the signature of a drop,
not of congestion — a slow link still delivers headers. `curl -sI` against the
HTTP URL returning nothing at all confirms it.

**Fix**

Use HTTPS for everything remirepo. Stage 1 pins every Remi baseurl to
`https://rpms.remirepo.net/` as part of the same rewrite described in issue 4.

**Verify**

Re-run the HTTPS command above (non-zero bytes), then:

```bash
grep -c 'baseurl=https://rpms.remirepo.net/' /etc/yum.repos.d/remi*.repo
grep -r 'baseurl=http://' /etc/yum.repos.d/remi*.repo   # expect no matches outside .bak
```

---

## 7. php:remi-8.4 stream not enabled

**Symptom**

Stage 1 aborts at step 5:

```
[fail] php:remi-8.4 stream not enabled
```

Preceded by one of:

```
Error: Problems in request:
Modular dependency problems: ... module php:remi-8.4 ... cannot be installed
```

or, if `php:8.4` was attempted instead:

```
Error: Unable to resolve argument php:8.4
No such stream 8.4 in php module
```

**Cause**

Two distinct mistakes, both common:

1. **A stream is already enabled.** RHEL 9 ships the `php` module with an
   AppStream default (8.1/8.2/8.3 depending on minor release). You cannot enable
   a second stream of the same module on top of it — it must be reset first.
2. **Wrong stream name.** `php:8.4` does not exist. `8.1`, `8.2`, `8.3` are Red
   Hat's own streams and AppStream tops out at 8.3; 8.4 exists only in Remi's
   namespace, named **`php:remi-8.4`**. GovExy requires PHP ^8.4, so the Remi
   stream is not optional.

**Fix**

Reset, then enable — in that order, and with the `remi-` prefix:

```bash
dnf -y module reset php
dnf -y module enable php:remi-8.4
```

Stage 1 does exactly this and then asserts the result before installing anything,
so a silently-failed enable cannot lead to a PHP 8.3 install.

**Verify**

```bash
dnf module list php
```

The `remi-8.4` row must carry `[e]`:

```
Name   Stream       Profiles                     Summary
php    remi-8.4 [e] common [d], devel, minimal   PHP scripting language
```

Then, after the install:

```bash
php -v | head -1     # PHP 8.4.x
```

---

## 8. nginx server-name conflict, or the RHEL default page still serving

**Symptom**

```
nginx: [warn] conflicting server name "_" on 0.0.0.0:80, ignored
```

or, with no warning at all, `http://<node>/` returning the Red Hat "Test Page for
the Nginx HTTP Server" instead of the application — including on `/up`,
which should return `ok`.

**Cause**

The RHEL nginx package does **not** ship its default site as
`/etc/nginx/conf.d/default.conf`. It puts the `server { ... }` block **inside
`/etc/nginx/nginx.conf`** itself. Deleting `conf.d/default.conf` — the standard
advice, written for nginx.org packages — removes a file that was never there and
changes nothing.

Both that block and the GovExy vhost declare `listen 80 default_server` with
`server_name _`. The one loaded first wins, and the one in `nginx.conf` is
included before `conf.d/*.conf`.

**Fix**

Stage 2 comments the block out in place. It backs the original up first, then
walks the file with awk tracking brace depth, so nested `location` blocks inside
the server block are commented too and no stray `}` is left behind:

```bash
cp -a /etc/nginx/nginx.conf "/etc/nginx/nginx.conf.bak.$(date +%s)"
```

It also still removes `/etc/nginx/conf.d/default.conf`, which is harmless when
absent and correct on nginx.org packages.

To restore the stock file, copy back the oldest `nginx.conf.bak.<epoch>`.

**Verify**

```bash
nginx -t                       # no "conflicting server name" warning
grep -n '^\s*server\s*{' /etc/nginx/nginx.conf   # expect no matches (all lines prefixed with #)
systemctl reload nginx
curl -s http://127.0.0.1/up     # expect: ok
```

`curl -s http://127.0.0.1/ | head` returning Red Hat test-page HTML means the
block is still live.

---

## 9. SELinux denies reads on NFS-backed paths

**Symptom**

Media, form attachments or uploaded themes 404 or produce permission errors,
while every ordinary check passes: the file exists, `ls -l` shows it owned by
`nginx`, the mode is readable, and `sudo -u nginx cat <file>` on the shell may
even work. The web request still fails. It reads as a permissions bug and is not
one.

In the audit log:

```
type=AVC msg=audit(...): avc:  denied  { read } for  pid=1234 comm="php-fpm" name="..." dev="0:45" ino=... scontext=system_u:system_r:httpd_t:s0 tcontext=system_u:object_r:nfs_t:s0 tclass=file permissive=0
```

The tell is `tcontext=…:nfs_t` — the whole NFS mount carries one context; per-file
ownership and modes are irrelevant to the decision.

**Cause**

The `httpd_use_nfs` SELinux boolean is off by default. With it off, SELinux blocks
`httpd_t` (nginx and php-fpm) from NFS entirely. This node's shared storage —
`storage/app/public`, `storage/app/private`, `resources/themes` — is NFS-mounted
(see `NFS-SHARED-STORAGE.md`), so this hits everything user-uploaded.

**Fix**

Stage 2 sets it, persistently:

```bash
setsebool -P httpd_use_nfs 1
```

It also sets `httpd_can_network_connect` and `httpd_can_network_connect_db`, which
are what let PHP reach Redis and the remote MySQL host — the same class of
failure, presenting as connection refused/timeout rather than a permissions error.

**Diagnose**

```bash
ausearch -m AVC -ts recent
ausearch -m AVC -ts recent | audit2why      # plain-language reason, incl. "boolean off"
getsebool -a | grep httpd_use_nfs
ls -Z /var/www/govexy/storage/app/public    # confirms the nfs_t context
```

Never "fix" this with `setenforce 0`. It confirms the diagnosis and nothing else,
and it does not survive a reboot — the failure returns at the worst moment.

**Verify**

```bash
getsebool httpd_use_nfs        # expect: httpd_use_nfs --> on
```

Then request an uploaded media file through nginx and confirm 200, and that
`ausearch -m AVC -ts recent` reports no new denials for `httpd_t`.

---

## 10. Code changes do not appear after a deploy

**Symptom**

New code is on disk, `git log` confirms it, the file timestamp is current — and
the site keeps serving the previous version. Indefinitely. No error anywhere.

**Cause**

`/etc/php.d/99-govexy.ini` sets:

```ini
opcache.validate_timestamps = 0
```

This is deliberate. With it off, PHP never stats source files to check for
changes, which is the single largest opcache win and matters more here because
application code sits alongside NFS mounts. The cost is that the compiled
bytecode is only replaced when the PHP-FPM workers are recycled.

**Fix**

Every deploy must end with a PHP-FPM reload:

```bash
systemctl reload php-fpm
```

The full tail of a deploy, per node:

```bash
php artisan config:cache route:cache view:cache
systemctl reload php-fpm
```

`reload` is a graceful worker restart — in-flight requests finish. `restart` is
not required and drops connections.

This is per node. Reloading web1 and not web2 leaves the load balancer serving
old code from half the requests, which presents as intermittent, unreproducible
staleness.

**Verify**

```bash
php -i | grep -E 'opcache.validate_timestamps|opcache.enable'   # CLI: informational only
systemctl show php-fpm -p ExecMainStartTimestamp
```

The real check is a request: hit a route touched by the deploy through nginx (not
the CLI — `opcache.enable_cli = 0`, so the CLI never shows this problem and is
useless as a test) and confirm the new behaviour.

---

## 11. A deploy failed part way

**Symptom**

`04-deploy.sh` exited non-zero. What the node is serving depends on where it
stopped, and the script says so at each stage — read its last lines before
touching anything.

**The node is stuck in maintenance mode (`/up` returns 503)**

The `EXIT` trap is supposed to prevent this: on any non-zero exit it clears the
compiled caches (`config:clear route:clear view:clear event:clear`, never
`optimize:clear` — that flushes the Redis store the other node shares) and runs
`artisan up`. If the trap itself could not run — SIGKILL, the node rebooted —
lift it by hand:

```bash
sudo -u nginx php /var/www/govexy/artisan up
```

If that returns but `/up` is still 503, the cache set is half built. Clear the
four and try again:

```bash
for c in config:clear route:clear view:clear event:clear; do
  sudo -u nginx php /var/www/govexy/artisan $c
done
sudo -u nginx php /var/www/govexy/artisan up
```

**The test gate failed for environmental reasons, not code**

Look for a whole class failing at once rather than a handful. The gate runs under
`env -i` with `DB_CONNECTION=sqlite`, `DB_DATABASE=:memory:`,
`FILESYSTEM_DISK=testing` and `APP_MAINTENANCE_DRIVER=cache` set explicitly, so
the usual environmental causes are already closed. What is left:

| Signature | Cause |
|---|---|
| hundreds of HTTP tests returning 503 | the release predates the `APP_MAINTENANCE_DRIVER=cache` pin in `phpunit.xml` (cms < 1.4.24). The script refuses to start rather than produce this — if you see it, the guard was bypassed. |
| every billing/licence test failing | the suite pins `LICENSE_MODE=saas` while this node runs `onprem`. Expected, and warned about before the run. A green gate does not prove the on-premise build works. |
| `could not find driver` | `pdo_sqlite` missing — `dnf -y install php-pdo`. Stage 1 asserts it. |
| the runner never produced a `Tests:` line | it crashed or never started; read the top of `storage/logs/deploy-tests-*.log`. |

Re-run with `--skip-tests` once you have established the failure is not the code,
and say why in the change record.

**`/up` is not 200 after the deploy**

The script exits non-zero for this, deliberately: **do not deploy the next node.**
One broken node is an incident; two is an outage.

```bash
tail -50 /var/www/govexy/storage/logs/laravel-$(date +%Y-%m-%d).log
tail -30 /var/log/nginx/govexy-error.log
tail -30 /var/log/php-fpm/www-error.log
```

Roll back by redeploying the previous tag — see "Rollback" in `README.md`. Do
**not** use `git reset --hard`.

**"N migrations are still pending" on a non-primary node**

Working as intended. The primary has not deployed this release yet, and caching
new code against the old schema produces errors until it does. Deploy the primary
first:

```bash
bash 04-deploy.sh --ref <tag> --primary
```

**"the primary node deployed X, this node was given Y"**

The primary recorded its ref at `storage/app/private/.deployed-ref` on the shared
export and they disagree — someone pushed or re-tagged between the two nodes.
Deploy the ref the primary actually ran, or redeploy the primary with the one you
want.

**Horizon is dead after a reboot and will not come back**

The one interaction between two settings that are each individually right. The
fstab bind entries carry `nofail`, so a node whose NFS server is down still
boots (without it, it drops to an emergency console). `govexy-horizon.service`
carries `RequiresMountsFor=` the three shared paths, so a worker never starts
against empty local directories. Put together: if the mounts are absent at boot,
Horizon's start job **fails**, and systemd does not retry a failed start job. The
NFS server comes back, the mounts appear, and Horizon stays dead — the queue
simply stops draining, with nothing in the application logs.

```bash
bash 05-configure-workers.sh --status     # names this case explicitly
systemctl status govexy-horizon
findmnt /var/www/govexy/storage/app/public
```

`govexy-horizon-mountwait.timer` exists to close this: it checks all three mounts
once a minute and starts Horizon when they are present. Confirm it is running —
a node provisioned before it existed will not have it, and needs
`bash 05-configure-workers.sh --horizon` once.

```bash
systemctl is-active govexy-horizon-mountwait.timer
```

To recover by hand:

```bash
mount -a
systemctl start govexy-horizon
```

`reset-failed` is only needed if the unit is genuinely in the `failed` state —
which here means it hit the start rate limit, not that a dependency was missing.
An unsatisfied `RequiresMountsFor=` leaves the unit **inactive**, and `start`
works on it directly once the mounts are there. Check before reaching for it:

```bash
systemctl is-failed govexy-horizon     # "failed" -> reset-failed first
systemctl reset-failed govexy-horizon
```

**Stopping the timer from restarting Horizon**

The timer exists to fight an accidental stop, so it will also fight a deliberate
one — draining a node, or holding the queue while you debug a poison job. Two
ways to tell it not to:

```bash
touch /run/govexy-horizon.hold     # this boot only; /run is cleared on reboot
systemctl disable govexy-horizon   # permanent, survives reboot
```

The timer skips when either is true, so `systemctl stop govexy-horizon` alone is
not enough — it will be restarted within the minute.

**`resources/themes` is still tracked in git**

A warning, not a failure, and it is the one hazard in this repository that the
scripts cannot fix on their own. `resources/themes` is both tracked and an NFS
bind mount, so a checkout touching a tracked path under it writes onto the shared
export — visible to the other node before that node has deployed — and any
`git reset --hard` restores shipped themes over admin-uploaded ones. Untrack it in
the application repository:

```bash
git rm -r --cached resources/themes
```

and add `/resources/themes/*` plus `!/resources/themes/.gitkeep` to `.gitignore`.
See the closing notes of `03-mount-shared-storage.sh` for the test-fixture move
that has to happen in the same change.

---

## Still blocked?

Capture all of the following before escalating. Together they answer nearly every
follow-up question a platform, network or security team will ask, and they make
the difference between "PHP won't install" and a ticket someone can act on.

```bash
dnf repolist
dnf module list php
php -v
php -m
nginx -t
systemctl status nginx php-fpm
sestatus
firewall-cmd --list-all
ausearch -m AVC -ts recent
```

Collect in one go:

```bash
{
  echo "=== dnf repolist ==="        ; dnf repolist
  echo "=== dnf module list php ===" ; dnf module list php
  echo "=== php -v ==="              ; php -v
  echo "=== php -m ==="              ; php -m
  echo "=== nginx -t ==="            ; nginx -t 2>&1
  echo "=== systemctl status ==="    ; systemctl status nginx php-fpm --no-pager
  echo "=== sestatus ==="            ; sestatus
  echo "=== firewall-cmd ==="        ; firewall-cmd --list-all
  echo "=== AVC denials ==="         ; ausearch -m AVC -ts recent
} > /root/govexy-diag-$(hostname -s)-$(date +%Y%m%d-%H%M).txt 2>&1
```

Add, depending on which issue you are stuck on:

| Stuck on | Also capture |
|---|---|
| 1, 4, 5, 6 (repo reachability) | `grep -E '^(mirrorlist\|metalink\|baseurl)' /etc/yum.repos.d/remi*.repo`, the http-vs-https `curl -w` pair from issue 6, `grep -E '^(timeout\|minrate\|retries)=' /etc/dnf/dnf.conf` |
| 2 (TLS) | `curl -v https://getcomposer.org/installer 2>&1 \| head -40`, `trust list \| grep -i <corporate CA name>` |
| 3 (dnf lock) | `ps -ef \| grep rhsm`, `grep -E '^(server_timeout\|proxy_)' /etc/rhsm/rhsm.conf`, `subscription-manager status` |
| 8 (nginx) | `nginx -T` (full effective config), `ls -la /etc/nginx/nginx.conf.bak.*` |
| 9 (SELinux) | `getsebool -a \| grep httpd`, `ls -Z` on the failing path, `mount \| grep nfs` |
| 10 (opcache) | the `php-fpm` reload time, and whether *both* nodes were reloaded |

When escalating to the network team, state the hostname, scheme and exact status
code — "`403` on `http://cdn.remirepo.net/...` from `<node ip>`" gets acted on;
"the internet doesn't work" does not. Where a request is for a mirrorlist host,
say so and ask for the single-host baseurl to be approved instead.
