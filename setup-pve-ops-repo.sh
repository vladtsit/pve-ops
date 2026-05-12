#!/usr/bin/env bash
# Bootstrap a git repo at /root/pve-ops mirroring the canonical layout of
# pve-* operational files, plus a sanitized env example and an install script.
# Idempotent: re-running just refreshes file contents from the live system.
set -euo pipefail

REPO=/root/pve-ops
mkdir -p "$REPO"/{sbin,cron.d,logrotate.d,etc,docs}

# --- sync live files into repo --------------------------------------------
cp -av /usr/local/sbin/pve-*.sh           "$REPO/sbin/"
cp -av /etc/cron.d/pve-*                  "$REPO/cron.d/"      || true
cp -av /etc/logrotate.d/pve-monitor       "$REPO/logrotate.d/" || true

# Sanitized env example (no secrets)
sed -E 's/=.*$/=CHANGEME/' /etc/pve-monitor.env > "$REPO/etc/pve-monitor.env.example"
chmod 600 "$REPO/etc/pve-monitor.env.example"

# --- .gitignore: belt-and-braces for secrets ------------------------------
cat > "$REPO/.gitignore" <<'EOF'
# Never commit live credentials
pve-monitor.env
*.env
!*.env.example
*.log
*.swp
EOF

# --- README ---------------------------------------------------------------
cat > "$REPO/README.md" <<'EOF'
# pve-ops

Operational scripts, cron schedules, logrotate config, and env template for the
Proxmox VE host (NUC10i3FNH @ 192.168.3.20).

## Layout

| Path in repo            | Installed to                  |
|-------------------------|-------------------------------|
| `sbin/pve-*.sh`         | `/usr/local/sbin/`            |
| `cron.d/pve-*`          | `/etc/cron.d/`                |
| `logrotate.d/pve-monitor` | `/etc/logrotate.d/`         |
| `etc/pve-monitor.env.example` | copy to `/etc/pve-monitor.env`, fill in, `chmod 600` |

## Scripts

| Script | Purpose | Schedule |
|---|---|---|
| `pve-pressure-monitor.sh`     | Per-target memory/swap/disk pressure → Pushover + MQTT  | every 5 min |
| `pve-system-mqtt-publish.sh`  | Host CPU/load/mem/uptime → MQTT discovery | every 5 min |
| `pve-disk-mqtt-publish.sh`    | smartctl per-disk → MQTT discovery       | every 30 min |
| `pve-disk-weekly-summary.sh`  | Weekly SMART digest → Pushover            | Mon 08:00 |
| `pve-config-snapshot.sh`      | Snapshot `/etc/pve` + crontabs → tarball  | weekly Sun |
| `pve-offsite-onedrive.sh`     | Off-site rclone copy of latest vzdump     | weekly Sun 04:00 |
| `pve-vm-fstrim.sh`            | `fstrim -av` inside VMs via qm guest exec | weekly Sun 03:30 |
| `pve-cron-heartbeat.sh`       | Helper: publish retained heartbeat + HA discovery | (called by scripts above) |

## Install / re-sync

```bash
sudo ./install.sh         # copies files to canonical locations + sets perms
```

## Re-sync from live host into repo (after editing live files)

```bash
sudo ./setup-pve-ops-repo.sh   # the bootstrap script
git -C /root/pve-ops diff       # review
git -C /root/pve-ops commit -am "live sync $(date -I)"
git -C /root/pve-ops push
```
EOF

# --- install.sh: deploy repo → system -------------------------------------
cat > "$REPO/install.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "must run as root"; exit 1; }
cd "$(dirname "$0")"
install -m 0755 sbin/pve-*.sh        /usr/local/sbin/
install -m 0644 cron.d/pve-*         /etc/cron.d/
install -m 0644 logrotate.d/pve-*    /etc/logrotate.d/
echo "Installed. Ensure /etc/pve-monitor.env exists with mode 600:"
echo "  cp etc/pve-monitor.env.example /etc/pve-monitor.env && chmod 600 /etc/pve-monitor.env"
EOF
chmod +x "$REPO/install.sh"

# Also keep this bootstrap script in the repo so it's versioned
cp -av "$0" "$REPO/setup-pve-ops-repo.sh"
chmod +x "$REPO/setup-pve-ops-repo.sh"

# --- git init + first commit ----------------------------------------------
cd "$REPO"
if [ ! -d .git ]; then
  git init -q -b main
  git config user.email "root@$(hostname -f)"
  git config user.name  "PVE Host"
fi
git add -A

# Hard safety check: ensure no secrets staged
if git diff --cached | grep -E '^\+.*(PUSHOVER_TOKEN|PUSHOVER_USER|MQTT_PASS)=[^C]' | grep -v CHANGEME ; then
  echo "ABORT: secrets detected in staged changes"
  exit 2
fi

if git diff --cached --quiet; then
  echo "No changes to commit."
else
  git commit -q -m "sync from live host $(date -Is)"
  echo "Committed:"
  git log --oneline -1
fi

echo
echo "=== Repo summary ==="
ls -la "$REPO"
echo
echo "=== git log ==="
git log --oneline | head -10
echo
echo "Done. Next:"
echo "  cd $REPO"
echo "  # create a private GitHub repo, then:"
echo "  git remote add origin git@github.com:<you>/pve-ops.git"
echo "  git push -u origin main"
