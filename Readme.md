# xrpld-migration

A guided, safety-first Bash script to migrate an XRP Ledger core-server node
from the old **`rippled`** package to the renamed **`xrpld`** package
(per XLS-0095 / xrpld 3.2.0) on Debian/Ubuntu or RHEL hosts.

The migration touches your node identity and, on validators, irreplaceable
validator keys. This script is built around **not losing any of that**: it
backs up first, refuses to continue if the backup fails, never uses
`apt-get purge`, and never deletes your original data (it only moves directories
aside reversibly).

> Community resource, not affiliated with or endorsed by Ripple or the XRPL
> Foundation. Adapted from the official "Migrate from rippled to xrpld" guide.
> **Verify commands against the upstream docs for your exact version**, and test
> on a non-validator node before running on production validators.

## What it does

Runs the full migration in order, with confirmation prompts at the steps that
matter:

1. **Back up** config + identity (`rippled.cfg`, `validators.txt`, `wallet.db`,
   and `validator-keys.json` if found); optional full data snapshot.
2. **Stop & remove** the `rippled` package (`remove`, never `purge`).
3. **Install** `xrpld` and stop the auto-started service.
4. **Restore** your config and validators list into `/etc/xrpld/`.
5. **Migrate data** — either *keep* existing ledger data (full/large-history
   nodes) or *re-sync* from the network (validators/small-history). In both
   modes it rewrites the data/log paths inside the cfg so the config always
   matches where the data actually lives, and verifies ownership.
6. **Restart** `xrpld` (clearing any systemd crash backoff first).
7. **Verify** sync status via the admin RPC port.
8. **Install `xrpld-info`** — a small, permission-safe status helper.

## Requirements

- Debian/Ubuntu (`apt`) or RHEL (`yum`) host
- Root / `sudo`
- The package-signing **GPG key already updated** (a prerequisite — the script
  does *not* do this; see the upstream install guide)
- `curl` (for the verify step and the `xrpld-info` helper)

## Usage

```bash
chmod +x scripts/migrate-rippled-to-xrpld.sh

# Preview every action without changing anything (recommended first):
sudo ./scripts/migrate-rippled-to-xrpld.sh --dry-run

# Interactive run (prompts where it matters):
sudo ./scripts/migrate-rippled-to-xrpld.sh

# Non-interactive, e.g. a validator that re-syncs:
sudo ./scripts/migrate-rippled-to-xrpld.sh --mode resync --yes
```

### Options

| Flag | Description |
|------|-------------|
| `--mode keep\|resync` | Data strategy. `keep` preserves ledger data (full/large-history); `resync` rebuilds from peers (validators/small-history). Prompts if omitted. |
| `--snapshot` | Take a full tar snapshot of the data dir during backup. |
| `--backup-dir DIR` | Local backup directory (default `/root/rippled-backup`). |
| `--yes`, `-y` | Assume yes to confirmations (defaults `--mode` to the safe `resync`). |
| `--skip-verify` | Skip the post-restart `server_info` check. |
| `--dry-run` | Print actions without making changes. |
| `-h`, `--help` | Show help. |

Paths can be overridden via environment variables (`OLD_CFG`, `OLD_DATA_DIR`,
`NEW_CFG`, etc.) if your install is non-default — see the header of the script.

## Checking server status after migration

After migration the data directory is set to `0755` (matching the old `rippled`
default), so the familiar command works for any user:

```bash
xrpld server_info
```

A helper is also installed that queries the running daemon's RPC port directly —
handy for monitoring/scripts since it never touches the data dir and can't be
broken by working directory or permissions:

```bash
xrpld-info            # server_info
xrpld-info peers      # any RPC method
```

> Background: the `xrpld` package ships its data dir as `0750`, which makes the
> bare `xrpld server_info` client abort with `Can not create ".../db"` when run
> as a non-`xrpld` user — the client can't traverse into `[database_path]`. The
> migration sets the data dir to `0755` (traverse-only; ownership and file perms
> unchanged, nothing sensitive exposed) to restore the rippled-era behaviour.

A healthy node reports `server_state` of `full` (or `proposing` for validators)
and a contiguous `complete_ledgers` range.

## Safety model

- Aborts on first error (`set -euo pipefail`).
- Will not pass the backup step if backup fails, and pauses until you confirm
  the backup is **off the host**.
- `remove`, never `purge`; original data is moved aside (`.default`), never
  deleted — fully reversible until you choose to clean up.
- Rewrites cfg paths with a `.pre-migrate.bak` saved first.

**Always copy your backup off the host** — a backup on the same disk does not
protect against disk failure. The script reminds you and waits for confirmation.

## Post-migration

The script prints a checklist of things to repoint (log shippers, logrotate,
monitoring/exporters, cron jobs, backup tooling, firewall notes). If you run
Clio or other services against the node, update them to the new `xrpld` paths
and service name too.

## License

MIT — see [LICENSE](LICENSE).