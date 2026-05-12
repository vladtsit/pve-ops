#!/bin/bash
# pve-config-snapshot.sh
# Captures PVE host configuration into a single tarball for DR.
# Runs weekly. Last 8 snapshots kept. Stored on nvme-backup (vzdump'd nightly).

set -euo pipefail

DEST_DIR=/mnt/nvme/backups/pve-config
KEEP=8
TS=$(date +%Y%m%d-%H%M%S)
OUT="$DEST_DIR/pve-config-$(hostname)-$TS.tar.gz"

mkdir -p "$DEST_DIR"

# Paths to capture. Missing paths are silently skipped.
PATHS=(
    /etc/pve                               # cluster config (incl. VMs, storage, jobs)
    /etc/network/interfaces
    /etc/network/interfaces.d
    /etc/hosts
    /etc/hostname
    /etc/resolv.conf
    /etc/fstab
    /etc/exports
    /etc/smartd.conf
    /etc/default/grub
    /etc/apt/sources.list
    /etc/apt/sources.list.d
    /etc/cron.d
    /etc/cron.daily
    /etc/cron.weekly
    /etc/crontab
    /etc/systemd/system          # custom units (convert-copy, nic-watchdog, cpu-powersave, powertop, ...)
    /etc/pve-monitor.env         # shared creds (Pushover + MQTT)
    /usr/local/sbin              # all custom scripts
    /root/.ssh/authorized_keys
    /root/README.md
)

# Build list of existing paths (tar errors on missing)
EXIST=()
for p in "${PATHS[@]}"; do
    [[ -e "$p" ]] && EXIST+=("$p")
done

# Capture state that isn't files
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT
pveversion -v > "$TMP/pveversion.txt" 2>&1 || true
qm list > "$TMP/qm-list.txt" 2>&1 || true
pvesm status > "$TMP/pvesm-status.txt" 2>&1 || true
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,UUID,MODEL > "$TMP/lsblk.txt" 2>&1 || true
ip -4 addr > "$TMP/ip-addr.txt" 2>&1 || true
dpkg --get-selections > "$TMP/dpkg-selections.txt" 2>&1 || true
cat /proc/cmdline > "$TMP/kernel-cmdline.txt" 2>&1 || true
cp /etc/pve/qemu-server/*.conf "$TMP/" 2>/dev/null || true

tar -czf "$OUT" \
    --warning=no-file-changed \
    --transform="s|^$TMP/|state/|" \
    "${EXIST[@]}" "$TMP" 2>/dev/null || true

chmod 600 "$OUT"

# Prune old snapshots
ls -1t "$DEST_DIR"/pve-config-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f

# Log line
SIZE=$(du -h "$OUT" | cut -f1)
echo "[$(date -Is)] snapshot $OUT ($SIZE)" >> /var/log/pve-config-snapshot.log
tail -200 /var/log/pve-config-snapshot.log > /var/log/pve-config-snapshot.log.tmp && mv /var/log/pve-config-snapshot.log.tmp /var/log/pve-config-snapshot.log

# Heartbeat for HA stale-detection
HB_STATUS=ok; [[ -s "$OUT" ]] || HB_STATUS=fail
/usr/local/sbin/pve-cron-heartbeat.sh config_snapshot "$HB_STATUS" "Config Snapshot" >/dev/null 2>&1 || true
