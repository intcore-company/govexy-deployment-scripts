# GovExy web tier — NFS shared storage specification

For the storage/infrastructure team. Two web nodes behind a load balancer, both
serving the same Laravel application from `/var/www/govexy`.

Paths below were read from the application source, not assumed.

---

## 1. What must be shared

Three directories, three different reasons.

| Mount point | Holds | Source of truth |
|---|---|---|
| `/var/www/govexy/storage/app/public` | All media and assets uploaded from the dashboard | `config/filesystems.php` → `public` disk = `storage_path('app/public')`; `media-library.disk_name` defaults to `public` |
| `/var/www/govexy/storage/app/private` | Files submitted by end users through public forms | `FormSubmission::ATTACHMENT_DISK = 'local'`; `config/filesystems.php` → `local` disk = `storage_path('app/private')` |
| `/var/www/govexy/resources/themes` | Themes uploaded by the super admin | `ThemeUploadService` writes `base_path('resources/themes/<slug>/<version>')` |

### The one that surprises people

`resources/themes` is **inside the application code tree**, not under `storage/`.
An admin uploading a theme writes into what most deployment processes treat as
read-only, replaceable code. Two consequences:

- It must be shared, or a theme uploaded while the load balancer routes to web1
  is simply absent on web2 — tenants get an unstyled site half the time.
- The deploy process must not blow the mount away. If deployment replaces the
  code tree wholesale (rsync `--delete`, git clean, symlinked release
  directories), `resources/themes` has to be excluded and re-mounted, or every
  uploaded theme is destroyed on each release.

Confirm the deploy method before the first release, not after.

---

## 2. What must NOT be shared

Putting these on NFS causes real damage, not just slowness.

| Path | Why it stays node-local |
|---|---|
| `storage/framework/views` | Compiled Blade templates. Laravel stats these on every render. Over NFS that is a network round trip per view per request — the single worst thing you can put on shared storage. |
| `storage/framework/cache` | File cache. Redis handles caching; this is only a fallback and must never be shared. |
| `storage/framework/sessions` | Unused (sessions are in Redis), but shared file sessions would deadlock on NFS locking. |
| `bootstrap/cache` | Compiled config/routes/services. Node-local by design; regenerated per node at deploy. |
| `storage/logs` | Two nodes appending to one file interleave and corrupt entries. Keep per-node, ship to a central collector if aggregation is needed. |
| `vendor/`, application code | Deployed per node. Loading PHP source over NFS is slow and defeats opcache. |

---

## 3. Requirements on the export

**UID/GID consistency.** Both web nodes run nginx and php-fpm as the `nginx`
user. That user's numeric UID and GID must be identical on both nodes and must
match ownership on the export. Mismatched IDs produce files that one node can
write and the other cannot read.

```bash
# run on both nodes — must return the same numbers
id nginx
```

**Squashing.** `root_squash` is fine and preferred; the application never needs
root on these paths. But it means the deploy process cannot `chown` files on the
share as root — do that from a host with appropriate access, or set ownership at
export creation.

**NFS version.** NFSv4.1 or later. NFSv3 locking (`rpc.statd`/`lockd`) is fragile
across a load-balanced pair.

**Capacity.** These paths hold every tenant's media library plus every public form
attachment, and grow without bound. The application enforces per-tenant storage
quotas in the database, but nothing enforces a ceiling on the filesystem. Size
and monitor accordingly.

---

## 4. Mount configuration

Suggested `/etc/fstab` entries, identical on both nodes:

```fstab
nfs-server:/govexy/media    /var/www/govexy/storage/app/public   nfs4  _netdev,hard,timeo=600,retrans=2,noatime,nodiratime  0 0
nfs-server:/govexy/private  /var/www/govexy/storage/app/private  nfs4  _netdev,hard,timeo=600,retrans=2,noatime,nodiratime  0 0
nfs-server:/govexy/themes   /var/www/govexy/resources/themes     nfs4  _netdev,hard,timeo=600,retrans=2,noatime,nodiratime  0 0
```

Option notes:

- **`hard`** not `soft`. A soft mount returns I/O errors on server hiccups, which
  surface as corrupted uploads and half-written files. Hard blocks instead —
  correct behaviour for data you cannot afford to truncate.
- **`_netdev`** so systemd waits for the network before mounting; without it boot
  ordering races and php-fpm starts against empty directories.
- **`noatime,nodiratime`** removes a write per read. Meaningful on a media tree.
- Do **not** use `nolock`.

---

## 5. SELinux

Enforcing mode stays on. One boolean is required:

```bash
setsebool -P httpd_use_nfs 1
```

Without it, nginx and php-fpm are denied access to NFS-backed paths entirely.
The symptom is misleading: the file is visibly present, owned correctly, and
readable by the `nginx` user — and every read still fails. Check with
`ausearch -m AVC -ts recent` before suspecting permissions.

`02-configure-nginx-php.sh` sets this boolean.

---

## 6. Application-side steps after mounting

```bash
# ownership on the shared paths
chown -R nginx:nginx /var/www/govexy/storage/app/public \
                     /var/www/govexy/storage/app/private \
                     /var/www/govexy/resources/themes

# public/storage -> storage/app/public (run once, on either node)
sudo -u nginx php artisan storage:link
```

`public/storage` is a symlink created by `storage:link`, pointing at
`storage/app/public`. It lives in the code tree and is therefore node-local,
which is correct — each node needs its own symlink into the shared target.
Verify on both:

```bash
readlink -f /var/www/govexy/public/storage
# expect: /var/www/govexy/storage/app/public
```

---

## 7. Verification

Run from web1, check from web2:

```bash
# web1
sudo -u nginx sh -c 'echo probe > /var/www/govexy/storage/app/public/.nfs-probe'

# web2
cat /var/www/govexy/storage/app/public/.nfs-probe      # expect: probe
sudo -u nginx test -w /var/www/govexy/storage/app/public && echo writable

# cleanup
rm -f /var/www/govexy/storage/app/public/.nfs-probe
```

Repeat for `storage/app/private` and `resources/themes`.

Then the real test — upload an image in the tenant dashboard while the load
balancer routes you to one node, and confirm it renders when routed to the other.
