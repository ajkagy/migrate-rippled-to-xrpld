#!/usr/bin/env bash
#
# migrate-rippled-to-xrpld.sh
#
# Migrates an XRPL core-server node from the old `rippled` package (3.1.3)
# to the renamed `xrpld` package (3.2.0), per the XRPL Foundation guide
# "Migrating from rippled to xrpld".
#
# WHAT THIS DOES (in order):
#   1. Backs up config + identity (and optionally a full data snapshot)
#   2. Stops and removes the rippled package (remove, never purge)
#   3. Installs xrpld and stops the auto-started service
#   4. Restores your config and validators.txt into /etc/xrpld
#   5. Either keeps your existing ledger data OR lets xrpld re-sync
#   6. Restarts xrpld
#   7. Verifies sync status
#
# SAFETY MODEL:
#   - Aborts immediately on any error (set -euo pipefail).
#   - Will NOT proceed past backup if the backup step fails.
#   - Never runs `apt-get purge` and never deletes your original data.
#   - The data-directory migration moves the empty default dirs ASIDE
#     (.default) — nothing is destroyed and it is fully reversible.
#   - Destructive-feeling steps require explicit confirmation unless --yes.
#
# THIS SCRIPT DOES NOT:
#   - Update the GPG package-signing key (do this first — see prerequisites).
#   - Copy your backup OFF the host. Do that yourself; a backup on the same
#     disk does not protect you from a disk failure.
#
# Tested against the defaults in the guide. If you customised paths, set the
# variables below or pass flags. Run as root (or via sudo).
#
# Usage:
#   sudo ./migrate-rippled-to-xrpld.sh [options]
#
# Options:
#   --mode keep|resync   Data strategy (default: prompt)
#                          keep   = full/large-history nodes, preserve data
#                          resync = validators/small-history, rebuild from peers
#   --snapshot           Take a full tar snapshot of the data dir in Step 1
#   --backup-dir DIR     Local backup dir (default: /root/rippled-backup)
#   --yes                Don't prompt; assume yes to confirmations
#   --skip-verify        Don't run the Step 7 server_info check
#   --dry-run            Print what would run without changing anything
#   -h, --help           Show this help
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Defaults (override with env vars or flags). These are the guide's defaults.
# ----------------------------------------------------------------------------
BACKUP_DIR="${BACKUP_DIR:-/root/rippled-backup}"
OLD_CFG="${OLD_CFG:-/opt/ripple/etc/rippled.cfg}"
OLD_VALIDATORS="${OLD_VALIDATORS:-/opt/ripple/etc/validators.txt}"
OLD_WALLET="${OLD_WALLET:-/var/lib/rippled/db/wallet.db}"
OLD_DATA_DIR="${OLD_DATA_DIR:-/var/lib/rippled}"
OLD_LOG_DIR="${OLD_LOG_DIR:-/var/log/rippled}"

NEW_CFG="${NEW_CFG:-/etc/xrpld/xrpld.cfg}"
NEW_VALIDATORS="${NEW_VALIDATORS:-/etc/xrpld/validators.txt}"
NEW_DATA_DIR="${NEW_DATA_DIR:-/var/lib/xrpld}"
NEW_LOG_DIR="${NEW_LOG_DIR:-/var/log/xrpld}"

ADMIN_PORT="${ADMIN_PORT:-5005}"

MODE=""
DO_SNAPSHOT=0
ASSUME_YES=0
SKIP_VERIFY=0
DRY_RUN=0

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
if [ -t 1 ]; then
  C_RST='\033[0m'; C_GRN='\033[0;32m'; C_YEL='\033[0;33m'
  C_RED='\033[0;31m'; C_CYN='\033[0;36m'; C_BLD='\033[1m'
else
  C_RST=''; C_GRN=''; C_YEL=''; C_RED=''; C_CYN=''; C_BLD=''
fi

step() { echo -e "\n${C_CYN}${C_BLD}==> $*${C_RST}"; }
info() { echo -e "    $*"; }
ok()   { echo -e "    ${C_GRN}✓${C_RST} $*"; }
warn() { echo -e "    ${C_YEL}!${C_RST} $*"; }
die()  { echo -e "\n${C_RED}${C_BLD}ERROR:${C_RST} $*" >&2; exit 1; }

# Run a command, honouring --dry-run. Use for state-changing commands only.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "    ${C_YEL}[dry-run]${C_RST} $*"
  else
    "$@"
  fi
}

confirm() {
  # confirm "question" -> returns 0 if yes
  [ "$ASSUME_YES" -eq 1 ] && return 0
  local reply
  read -r -p "    $1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

usage() { sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ----------------------------------------------------------------------------
# Parse args
# ----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)        MODE="${2:-}"; shift 2 ;;
    --snapshot)    DO_SNAPSHOT=1; shift ;;
    --backup-dir)  BACKUP_DIR="${2:-}"; shift 2 ;;
    --yes|-y)      ASSUME_YES=1; shift ;;
    --skip-verify) SKIP_VERIFY=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     usage ;;
    *)             die "Unknown option: $1 (try --help)" ;;
  esac
done

if [ -n "$MODE" ] && [ "$MODE" != "keep" ] && [ "$MODE" != "resync" ]; then
  die "--mode must be 'keep' or 'resync'"
fi

# ----------------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------------
step "Pre-flight checks"

if [ "$(id -u)" -ne 0 ]; then
  die "Run as root (use sudo)."
fi

# Detect package manager / distro family
PKG=""
if command -v apt-get >/dev/null 2>&1; then
  PKG="apt"
elif command -v yum >/dev/null 2>&1; then
  PKG="yum"
else
  die "Neither apt-get nor yum found. Unsupported distro for this script."
fi
ok "Package manager: $PKG"

[ "$DRY_RUN" -eq 1 ] && warn "DRY RUN — no changes will be made."

# Sanity: is there actually a rippled install to migrate?
if ! command -v rippled >/dev/null 2>&1 && [ ! -f "$OLD_CFG" ]; then
  warn "No 'rippled' binary and no $OLD_CFG found."
  warn "This host may not have a rippled install at the expected paths."
  confirm "Continue anyway?" || die "Aborted by user."
fi

echo
warn "${C_BLD}READ BEFORE CONTINUING${C_RST}"
info "This migrates rippled -> xrpld on THIS host."
info "Prerequisites you must have already done:"
info "  • Updated the package-signing GPG key (steps 1-5 of the install guide)"
info "  • Run apt-get update && apt-get upgrade (Debian) if appropriate"
info "Validator keys and node identity are IRREPLACEABLE. This script backs"
info "them up locally, but YOU must copy the backup off this host."
echo
confirm "I understand. Proceed with migration?" || die "Aborted by user."

# ----------------------------------------------------------------------------
# Resolve real paths from the old config if it exists (database_path, node_db,
# debug_logfile). Best-effort: only overrides if the cfg actually defines them.
# ----------------------------------------------------------------------------
if [ -f "$OLD_CFG" ]; then
  step "Reading real paths from $OLD_CFG"
  # [database_path] : value is on the line after the stanza header
  db_path="$(awk '/^\[database_path\]/{getline; gsub(/^[ \t]+|[ \t]+$/,""); print; exit}' "$OLD_CFG" 2>/dev/null || true)"
  # [node_db] path=... line
  nodedb_path="$(awk '/^\[node_db\]/{f=1;next} /^\[/{f=0} f && /^[ \t]*path[ \t]*=/{sub(/^[ \t]*path[ \t]*=[ \t]*/,""); print; exit}' "$OLD_CFG" 2>/dev/null || true)"
  logfile="$(awk '/^\[debug_logfile\]/{getline; gsub(/^[ \t]+|[ \t]+$/,""); print; exit}' "$OLD_CFG" 2>/dev/null || true)"

  [ -n "$db_path" ]  && info "database_path : $db_path"
  [ -n "$nodedb_path" ] && info "node_db path : $nodedb_path"
  [ -n "$logfile" ] && info "debug_logfile: $logfile"
  warn "Verify these match the defaults the script assumes. If you customised"
  warn "paths heavily, review the data-migration step (Step 5) carefully."
fi

# ----------------------------------------------------------------------------
# STEP 1: Back up
# ----------------------------------------------------------------------------
step "Step 1 — Back up config & identity"

run mkdir -p "$BACKUP_DIR"

backup_one() {
  # backup_one <src> <required:0|1> <label>
  local src="$1" required="$2" label="$3"
  if [ -f "$src" ]; then
    run cp -a "$src" "$BACKUP_DIR/"
    ok "Backed up $label ($src)"
  else
    if [ "$required" -eq 1 ]; then
      warn "MISSING required file: $src ($label)"
      confirm "File not found — continue without it?" \
        || die "Aborted: refusing to migrate without $label."
    else
      info "Skipped (not present): $label ($src)"
    fi
  fi
}

backup_one "$OLD_CFG"        1 "rippled.cfg"
backup_one "$OLD_VALIDATORS" 0 "validators.txt"
backup_one "$OLD_WALLET"     1 "wallet.db (node identity)"

# Validator master keys — try common locations; warn loudly if absent.
VK_FOUND=0
for vk in "$OLD_DATA_DIR/validator-keys.json" /var/lib/rippled/validator-keys.json; do
  if [ -f "$vk" ]; then
    run cp -a "$vk" "$BACKUP_DIR/"
    ok "Backed up validator-keys.json ($vk)"
    VK_FOUND=1
    break
  fi
done
if [ "$VK_FOUND" -eq 0 ]; then
  warn "No validator-keys.json found at the common paths."
  warn "If this is a validator, that file is often kept OFFLINE — make sure"
  warn "you still have it elsewhere. Without it you can't rotate your token."
fi

# Optional full snapshot of the data dir
if [ "$DO_SNAPSHOT" -eq 1 ]; then
  step "Step 1b — Snapshot data directory (optional safety net)"
  warn "Stopping rippled so the snapshot is consistent..."
  run systemctl stop rippled || warn "rippled service was not running."
  snap="/root/rippled-data-$(hostname).tar.gz"
  parent="$(dirname "$OLD_DATA_DIR")"
  base="$(basename "$OLD_DATA_DIR")"
  info "Creating $snap (this can take a while for large nodes)..."
  run tar -czf "$snap" -C "$parent" "$base"
  ok "Snapshot written to $snap"
fi

echo
ok "Local backup complete: $BACKUP_DIR"
warn "${C_BLD}COPY THIS BACKUP OFF THE HOST NOW.${C_RST}"
warn "e.g. from your laptop:  scp -r user@$(hostname):$BACKUP_DIR ./rippled-backup"
echo
confirm "Backup is safely OFF this host — continue to remove rippled?" \
  || die "Stopped so you can secure your backup. Re-run when ready."

# ----------------------------------------------------------------------------
# STEP 1c: Stop & remove rippled (remove, NOT purge)
# ----------------------------------------------------------------------------
step "Step 1c — Stop and remove the rippled package"
run systemctl stop rippled || warn "rippled service was not running."
if [ "$PKG" = "apt" ]; then
  run apt-get remove -y rippled || warn "rippled package not installed via apt."
else
  run yum remove -y rippled || warn "rippled package not installed via yum."
fi
ok "rippled removed. Config and data left in place (remove, not purge)."

# ----------------------------------------------------------------------------
# STEP 2: Install xrpld
# ----------------------------------------------------------------------------
step "Step 2 — Install xrpld"
if [ "$PKG" = "apt" ]; then
  run apt-get update
  run apt-get install -y xrpld
else
  run yum install -y xrpld
fi
ok "xrpld installed (binary at /usr/bin/xrpld, default cfg at $NEW_CFG)."

info "Stopping the auto-started xrpld so nothing writes while we migrate..."
run systemctl stop xrpld || warn "xrpld service was not running yet."

# ----------------------------------------------------------------------------
# STEP 3: Migrate the binary config
# ----------------------------------------------------------------------------
step "Step 3 — Restore your server config into $NEW_CFG"
if [ -f "$BACKUP_DIR/rippled.cfg" ]; then
  run mkdir -p "$(dirname "$NEW_CFG")"
  run cp -a "$BACKUP_DIR/rippled.cfg" "$NEW_CFG"
  ok "Restored config -> $NEW_CFG"
else
  die "Backup config not found at $BACKUP_DIR/rippled.cfg — cannot continue."
fi

# ----------------------------------------------------------------------------
# STEP 4: Migrate validators.txt (if separate)
# ----------------------------------------------------------------------------
step "Step 4 — Restore validators.txt (if you keep one separately)"
if [ -f "$BACKUP_DIR/validators.txt" ]; then
  run cp -a "$BACKUP_DIR/validators.txt" "$NEW_VALIDATORS"
  ok "Restored validators.txt -> $NEW_VALIDATORS"
else
  info "No separate validators.txt in backup."
  info "If your [validators] section lives inside the cfg, that's expected;"
  info "the package's generic validators.txt will simply be unused."
fi

# ----------------------------------------------------------------------------
# STEP 5: Migrate data directories
# ----------------------------------------------------------------------------
step "Step 5 — Data directories"

# Decide mode if not given
if [ -z "$MODE" ]; then
  echo "    Which describes this node?"
  echo "      [k] keep   — full/large-history; preserve existing ledger data"
  echo "      [r] resync — validator/small-history; rebuild from peers (minutes)"
  if [ "$ASSUME_YES" -eq 1 ]; then
    MODE="resync"
    warn "--yes given with no --mode; defaulting to SAFE 'resync'."
  else
    read -r -p "    Choose [k/r]: " m
    case "$m" in
      k|K) MODE="keep" ;;
      r|R) MODE="resync" ;;
      *) die "Invalid choice." ;;
    esac
  fi
fi
ok "Data mode: $MODE"

# Helper: ensure cfg points at the new default paths. This is a light-touch
# check — it warns rather than rewriting your cfg, since cfg edits are risky.
# Rewrite the data/log paths inside the cfg from old -> new, with a backup.
# This is what was missing before: in resync mode the restored cfg still
# pointed at /var/lib/rippled, so the xrpld user hit "Permission denied".
# We make the cfg agree with wherever the data actually ends up.
repoint_cfg() {
  # repoint_cfg <from_data> <to_data> <from_log> <to_log>
  local fd="$1" td="$2" fl="$3" tl="$4"
  [ -f "$NEW_CFG" ] || die "Config $NEW_CFG missing — cannot repoint paths."

  if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "    ${C_YEL}[dry-run]${C_RST} would rewrite in $NEW_CFG:"
    echo -e "    ${C_YEL}[dry-run]${C_RST}   $fd -> $td"
    echo -e "    ${C_YEL}[dry-run]${C_RST}   $fl -> $tl"
    return
  fi

  cp -a "$NEW_CFG" "${NEW_CFG}.pre-migrate.bak"
  ok "Saved cfg backup -> ${NEW_CFG}.pre-migrate.bak"
  # Anchor on the path prefix so we catch database_path, node_db path=, and
  # debug_logfile in one pass. '#' delimiter avoids escaping the slashes.
  sed -i \
    -e "s#${fd}#${td}#g" \
    -e "s#${fl}#${tl}#g" \
    "$NEW_CFG"
  ok "Repointed cfg paths ($fd -> $td, $fl -> $tl)"
}

# Show what the cfg now resolves to, and verify the targets are reachable and
# owned by xrpld. This catches the failure class you'd otherwise only see as a
# core-dump on startup.
verify_cfg_paths() {
  info "Active data/log stanzas in $NEW_CFG:"
  grep -A1 -E '\[database_path\]|\[node_db\]|\[debug_logfile\]' "$NEW_CFG" \
    | grep -vE '^\s*#|^--' | sed 's/^/      /' || true

  # Pull the resolved directories straight from the cfg and check ownership.
  local dbp ndb logf
  dbp="$(awk '/^\[database_path\]/{getline; gsub(/^[ \t]+|[ \t]+$/,""); print; exit}' "$NEW_CFG" 2>/dev/null || true)"
  ndb="$(awk '/^\[node_db\]/{f=1;next} /^\[/{f=0} f && /^[ \t]*path[ \t]*=/{sub(/^[ \t]*path[ \t]*=[ \t]*/,""); print; exit}' "$NEW_CFG" 2>/dev/null || true)"
  logf="$(awk '/^\[debug_logfile\]/{getline; gsub(/^[ \t]+|[ \t]+$/,""); print; exit}' "$NEW_CFG" 2>/dev/null || true)"

  local p
  for p in "$dbp" "$ndb" "$(dirname "$logf" 2>/dev/null)"; do
    [ -z "$p" ] && continue
    if [ "$DRY_RUN" -eq 1 ]; then continue; fi
    if [ ! -e "$p" ]; then
      warn "cfg path does not exist yet: $p"
      info "  (fine for resync — xrpld will create it. Ensure parent is writable.)"
    else
      local owner; owner="$(stat -c '%U:%G' "$p" 2>/dev/null || echo '?')"
      if [ "$owner" = "xrpld:xrpld" ]; then
        ok "ownership OK ($owner): $p"
      else
        warn "ownership is $owner (should be xrpld:xrpld): $p"
        if confirm "  Fix ownership of $p now?"; then
          run chown -R xrpld:xrpld "$p"
          ok "chowned $p -> xrpld:xrpld"
        else
          warn "Left as-is — xrpld may fail with 'Permission denied' on start."
        fi
      fi
    fi
  done
}

# Make the data directory traversable by non-owner local users (mode 0755 on
# the top dir only). The xrpld package ships the data dir as 0750, which blocks
# `xrpld server_info` when run as a normal user (e.g. ubuntu): the CLIENT can't
# traverse into [database_path] and aborts with `Can not create ".../db"`.
# The old rippled package used 0755, so this restores the familiar behaviour
# where `xrpld server_info` works for any user, matching `rippled server_info`.
# Only the +x (traverse) bit on the top dir is added; ownership and the files
# inside are unchanged, and nothing sensitive lives here (config/keys are in
# /etc/xrpld and wallet.db keeps its own ownership).
make_traversable() {
  local d="$1"
  [ -d "$d" ] || return 0
  run chmod 0755 "$d"
  ok "Set $d to 0755 so 'xrpld server_info' works for any user"
}

if [ "$MODE" = "resync" ]; then
  info "Re-sync mode: xrpld uses fresh default dirs under $NEW_DATA_DIR and"
  info "rebuilds the ledger store from peers (minutes for small-history nodes)."
  # The restored cfg almost certainly still references the OLD rippled paths.
  # Repoint them to the new xrpld defaults so the new user can read/write.
  repoint_cfg "$OLD_DATA_DIR" "$NEW_DATA_DIR" "$OLD_LOG_DIR" "$NEW_LOG_DIR"
  # Make sure the fresh dirs exist and are owned correctly.
  run mkdir -p "$NEW_DATA_DIR/db" "$NEW_LOG_DIR"
  run chown -R xrpld:xrpld "$NEW_DATA_DIR" "$NEW_LOG_DIR"
  make_traversable "$NEW_DATA_DIR"
  verify_cfg_paths

else
  # KEEP mode — move existing data into the xrpld locations.
  step "Step 5 (keep) — Move existing data into the xrpld locations"
  warn "This is the riskiest step. The empty default dirs are moved ASIDE to"
  warn ".default (NOT deleted), then your real data is moved into place."
  confirm "Proceed to move data directories?" || die "Aborted before moving data."

  # Data dir
  if [ -d "$OLD_DATA_DIR" ]; then
    if [ -d "$NEW_DATA_DIR" ]; then
      run mv "$NEW_DATA_DIR" "${NEW_DATA_DIR}.default"
      ok "Parked empty $NEW_DATA_DIR -> ${NEW_DATA_DIR}.default"
    fi
    run mv "$OLD_DATA_DIR" "$NEW_DATA_DIR"
    run chown -R xrpld:xrpld "$NEW_DATA_DIR"
    make_traversable "$NEW_DATA_DIR"
    ok "Moved data $OLD_DATA_DIR -> $NEW_DATA_DIR (owned by xrpld:xrpld)"
  else
    warn "$OLD_DATA_DIR not found — assuming non-default data location."
    warn "Update ownership yourself:  chown -R xrpld:xrpld <your data dir>"
  fi

  # Log dir
  if [ -d "$OLD_LOG_DIR" ]; then
    if [ -d "$NEW_LOG_DIR" ]; then
      run mv "$NEW_LOG_DIR" "${NEW_LOG_DIR}.default"
      ok "Parked empty $NEW_LOG_DIR -> ${NEW_LOG_DIR}.default"
    fi
    run mv "$OLD_LOG_DIR" "$NEW_LOG_DIR"
    run chown -R xrpld:xrpld "$NEW_LOG_DIR"
    ok "Moved logs $OLD_LOG_DIR -> $NEW_LOG_DIR (owned by xrpld:xrpld)"
  else
    warn "$OLD_LOG_DIR not found — assuming non-default log location."
    warn "Update ownership yourself:  chown -R xrpld:xrpld <your log dir>"
  fi

  # The data now lives at the new paths, so make the cfg agree.
  repoint_cfg "$OLD_DATA_DIR" "$NEW_DATA_DIR" "$OLD_LOG_DIR" "$NEW_LOG_DIR"
  verify_cfg_paths
  info "Once verified healthy (Step 7), you may remove the parked dirs:"
  info "  rm -rf ${NEW_DATA_DIR}.default ${NEW_LOG_DIR}.default"
fi

# ----------------------------------------------------------------------------
# STEP 6: Restart xrpld
# ----------------------------------------------------------------------------
step "Step 6 — Restart xrpld"
run systemctl daemon-reload
# Clear any prior crash backoff ("Start request repeated too quickly"),
# otherwise systemd refuses to start the unit after repeated failures.
run systemctl reset-failed xrpld || true
run systemctl restart xrpld
ok "xrpld (re)started."

# ----------------------------------------------------------------------------
# STEP 7: Verify
# ----------------------------------------------------------------------------
if [ "$SKIP_VERIFY" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
  step "Step 7 — Verify (skipped)"
else
  step "Step 7 — Verify server sync status"
  info "Querying server_info on admin port $ADMIN_PORT..."
  info "(A full re-sync can take up to ~20 min depending on data size.)"
  sleep 3
  if command -v curl >/dev/null 2>&1; then
    out="$(curl -s "localhost:${ADMIN_PORT}" -d '{"method":"server_info"}' \
          | grep -oP '"(server_state|complete_ledgers)":"[^"]+"' || true)"
    if [ -n "$out" ]; then
      echo "$out" | sed 's/^/    /'
      ok "Server responded. Healthy = server_state 'full' (or 'proposing')"
      ok "with a contiguous complete_ledgers range."
    else
      warn "No response yet on admin port $ADMIN_PORT."
      # Distinguish "still syncing" from "crashed on startup".
      if [ "$DRY_RUN" -ne 1 ] && ! systemctl is-active --quiet xrpld; then
        warn "xrpld is NOT running — it failed to start. Last log lines:"
        journalctl -u xrpld -n 15 --no-pager 2>/dev/null | sed 's/^/      /' || true
        echo
        warn "Common cause: a path in $NEW_CFG isn't owned by xrpld:xrpld,"
        warn "or points somewhere that doesn't exist. Check the stanzas with:"
        warn "  grep -A1 -E '\\[database_path\\]|\\[node_db\\]|\\[debug_logfile\\]' $NEW_CFG"
        warn "Then fix ownership:  chown -R xrpld:xrpld <that path>"
        warn "and:  systemctl reset-failed xrpld && systemctl start xrpld"
      else
        info "Service is running; it may just still be starting/syncing."
        warn "Re-check in a minute, or inspect:"
        warn "  journalctl -u xrpld -n 200"
        warn "  $NEW_LOG_DIR/debug.log"
      fi
    fi
  else
    warn "curl not installed; skipping automated check."
    info "Manually: curl -s localhost:$ADMIN_PORT -d '{\"method\":\"server_info\"}'"
  fi
fi

# ----------------------------------------------------------------------------
# STEP 8: Install a cfg-independent `xrpld-info` helper
# ----------------------------------------------------------------------------
# Running `xrpld server_info` as a non-xrpld user can abort with
#   Can not create "/var/lib/xrpld/db"
# because the CLIENT loads the cfg and tries to touch the data dir, which is
# mode 0750 xrpld:xrpld and not traversable by e.g. the ubuntu user. The robust
# way to check status is to query the RUNNING daemon's RPC port directly — that
# never touches the data dir and works for any user. We install a small wrapper
# so a bare command "just works".
step "Step 8 — Install 'xrpld-info' status helper"
HELPER=/usr/local/bin/xrpld-info
if [ "$DRY_RUN" -eq 1 ]; then
  echo -e "    ${C_YEL}[dry-run]${C_RST} would install $HELPER"
else
  cat > "$HELPER" <<'HELP'
#!/usr/bin/env bash
# Query the running xrpld daemon's admin RPC port directly.
# cfg-independent and permission-safe: does not touch the data directory.
# Usage: xrpld-info [method]   (default method: server_info)
set -euo pipefail
CFG="${XRPLD_CFG:-/etc/xrpld/xrpld.cfg}"
METHOD="${1:-server_info}"
# Pull the admin RPC port from [port_rpc_admin_local]; fall back to 5005.
PORT="$(awk '
  /^\[port_rpc_admin_local\]/{f=1; next}
  /^\[/{f=0}
  f && /^[ \t]*port[ \t]*=/{gsub(/[^0-9]/,""); print; exit}
' "$CFG" 2>/dev/null || true)"
PORT="${PORT:-5005}"
curl -s "localhost:${PORT}" -d "{\"method\":\"${METHOD}\"}"
echo
HELP
  chmod +x "$HELPER"
  ok "Installed $HELPER"
  info "Use it from any user:  xrpld-info            (runs server_info)"
  info "                       xrpld-info peers      (any RPC method)"
  warn "Note: bare 'xrpld server_info' as a non-xrpld user can still abort with"
  warn "'Can not create .../db' — that's the CLIENT hitting the 0750 data dir,"
  warn "not a server fault. Use 'xrpld-info' or 'sudo -u xrpld xrpld server_info'."
fi


cat <<'EOF'
    Update anything that still references the old rippled paths/service name:
      • systemd/tooling: systemctl ... rippled  ->  xrpld
      • log shippers (alloy/vector/fluentbit/filebeat), logrotate, cron:
          /var/log/rippled/  ->  /var/log/xrpld/
      • metrics/monitoring: Prometheus exporters, process matchers, Grafana
          dashboards -> recognise 'xrpld'
      • coredump patterns/scripts -> include xrpld and /usr/bin/xrpld
      • cron jobs touching the data dir (e.g. online delete) -> new paths
      • ownership/ACLs: rippled:ripple  ->  xrpld:xrpld
      • backup/snapshot tooling -> new data path
      • firewalls: ports unchanged, but note the example cfg's default port
          is now the IANA-registered XRPL port 2459
EOF
ok "Migration script finished."