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

### One path not decided here: `storage/app/themes`

Several parts of the application write under `storage/app/themes` (the theme preview and
screenshot paths, and the seeder, which builds a randomised root there). It is **not** in
either table above because nobody has confirmed which side it belongs on.

Resolve it with the application team before go-live. If a theme preview generated on one
node has to be visible from the other, it belongs in §1; if it is regenerated on demand,
it is node-local and belongs in §2. Until then it is on local disk on each node, which is
the behaviour of an unmounted path and may be silently wrong.

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

**Two topologies. Pick one; do not produce a hybrid.**

### 4a. One export, three bind mounts — what the scripts do

This is the supported arrangement and the one `03-mount-shared-storage.sh` builds. The
storage team mounts **one** export; the script binds three of its subdirectories onto the
application paths:

```fstab
nfs-server:/govexy       /srv/govexy-share                    nfs4  _netdev,hard,timeo=600,retrans=2,noatime,nodiratime  0 0
/srv/govexy-share/media    /var/www/govexy/storage/app/public   none  bind,nofail,_netdev,x-systemd.requires-mounts-for=/srv/govexy-share  0 0
/srv/govexy-share/private  /var/www/govexy/storage/app/private  none  bind,nofail,_netdev,x-systemd.requires-mounts-for=/srv/govexy-share  0 0
/srv/govexy-share/themes   /var/www/govexy/resources/themes     none  bind,nofail,_netdev,x-systemd.requires-mounts-for=/srv/govexy-share  0 0
```

- **`x-systemd.requires-mounts-for`** is what stops a bind firing before the NFS export is
  up. Without it the bind silently attaches an empty local directory: it looks mounted and
  is not.
- **`nofail`** is a deliberate trade. Without it these entries are boot-blocking, so an
  NFS server that is down when a node reboots fails `local-fs.target` and drops the node to
  an emergency console — an NFS outage would take both web nodes offline permanently and
  recovery would need console access to a government VM. With it, a node boots with the
  binds absent, which `04-deploy.sh` refuses to deploy onto and a `/up` health check plus a
  mount alarm covers. Add that mount alarm.

### 4b. Three exports mounted directly — the alternative

Equivalent in effect, and simpler if the storage team would rather present three exports.
`03-mount-shared-storage.sh` does not build this; it is set up by hand.

```fstab
nfs-server:/govexy/media    /var/www/govexy/storage/app/public   nfs4  _netdev,hard,timeo=600,retrans=2,noatime,nodiratime,nofail  0 0
nfs-server:/govexy/private  /var/www/govexy/storage/app/private  nfs4  _netdev,hard,timeo=600,retrans=2,noatime,nodiratime,nofail  0 0
nfs-server:/govexy/themes   /var/www/govexy/resources/themes     nfs4  _netdev,hard,timeo=600,retrans=2,noatime,nodiratime,nofail  0 0
```

Option notes, for both:

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

**Ownership on the shared paths is NOT set from a web node.** Under the `root_squash`
recommended in §3, a `chown -R` run as root on the export is squashed to `nobody` and
fails — so the obvious command here would simply not work. Set ownership one of two ways:

- at export creation, on the NFS server, to the UID/GID that `id nginx` reports on the web
  nodes (they must match — see §3); or
- from a host the export grants `no_root_squash` to, then remove that grant.

`03-mount-shared-storage.sh` seeds the share as the **application user** for the same
reason, never as root.

```bash
# public/storage -> storage/app/public — on EVERY node
sudo -u nginx php artisan storage:link
```

`public/storage` is a symlink created by `storage:link`, pointing at
`storage/app/public`. It lives in `public/`, which is part of the code tree and is
therefore node-local — so creating it on one node does nothing for the other. **Every node
needs its own.** `04-deploy.sh` creates it per node and warns if an existing link points
somewhere other than `storage/app/public`.
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

# cleanup — as the app user: root is squashed on the export, and `rm -f`
# swallows the refusal, leaving the probe file behind
sudo -u nginx rm -f /var/www/govexy/storage/app/public/.nfs-probe
```

Repeat for `storage/app/private` and `resources/themes`.

Then the real test — upload an image in the tenant dashboard while the load
balancer routes you to one node, and confirm it renders when routed to the other.
