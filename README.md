# govexy-deployment-scripts

Provisioning and deployment for GovExy web nodes, one directory per target OS.

| Directory | Target |
|---|---|
| `rhel9.4/` | RHEL 9.x web nodes (verified on 9.7) |

## Why this is version-controlled

These scripts generate the nginx vhost, the PHP-FPM pool and the systemd units
that serve production. Several of the values they write are security-relevant —
which forwarded headers are believed, which sources are trusted for real-IP,
what a worker is allowed to block on.

They were previously copied between machines by hand. That made "both nodes are
running the same configuration" an unanswerable question: there was no history,
no diff and no version. Config that decides who is trusted should not be the
one thing nobody can audit.

Read `rhel9.4/README.md` for what each stage does and the order to run them.
