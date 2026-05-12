#!/bin/bash
# pve-config-snapshot.sh — v2 (bare-metal-recovery)
#
# Produces a GPG-symmetric-encrypted tarball containing everything needed to
# rebuild this PVE host from scratch:
#   - /etc/pve, network/, ssh/, apt/, cron*, smartd, sysctl, modules
#   - secrets (pve-monitor.env, rclone.conf, root .ssh)
#   - all /usr/local/sbin scripts
#   - host state dumps (pveversion, qm list, lsblk, ip, dpkg selections, kernel cmdline)
#
# Output: /mnt/nvme/backups/pve-config/pve-restore-<host>-<ts>.tar.gz.gpg
# Last 8 kept. The off-site script mirrors this dir to OneDrive.
#
# Passphrase: $RESTORE_GPG_PASS from /etc/pve-monitor.env.
# Decrypt:  gpg -d --batch --passphrase "$RESTORE_GPG_PASS" file.tar.gz.gpg | tar -xzv

set -euo pipefail

. /etc/pve-monitor.env
: "${RESTORE_GPG_PASS:?RESTORE_GPG_PASS not set in /etc/pve-monitor.env}"

DEST_DIR=/mnt/nvme/backups/pve-config
KEEP=8
TS=$(date +%Y%m%d-%H%M%S)
HOST=$(hostname)
OUT="$DEST_DIR/pve-restore-${HOST}-${TS}.tar.gz.gpg"

mkdir -p "$DEST_DIR"
chmod 700 "$DEST_DIR"

# --- file/dir paths to capture (silently skipped if missing) --------------
PATHS=(
    # PVE cluster + guest configs
    /etc/pve

    # Host networking (critical for bare-metal restore)
    /etc/network/interfaces
    /etc/network/interfaces.d
    /etc/hosts
    /etc/hostname
    /etc/resolv.conf

    # Storage / boot
    /etc/fstab
    /etc/exports
    /etc/default/grub
    /etc/kernel
    /etc/modules
    /etc/modules-load.d
    /etc/modprobe.d
    /etc/sysctl.conf
    /etc/sysctl.d

    # Package sources (needed to reinstall right PVE version)
    /etc/apt/sources.list
    /etc/apt/sources.list.d
    /etc/apt/auth.conf.d
    /etc/apt/trusted.gpg.d

    # SSH (host keys + authorized + private)
    /etc/ssh
    /root/.ssh

    # Cron / systemd
    /etc/crontab
    /etc/cron.d
    /etc/cron.daily
    /etc/cron.weekly
    /etc/cron.hourly
    /etc/cron.monthly
    /etc/systemd/system

    # Monitoring / mail
    /etc/smartd.conf
    /etc/default/smartmontools
    /etc/aliases
    /etc/postfix

    # Logrotate
    /etc/logrotate.conf
    /etc/logrotate.d

    # Our scripts and credentials
    /usr/local/sbin
    /usr/local/bin
    /etc/pve-monitor.env
    /root/.config/rclone

    # Documentation/notes left at /root/
    /root/README.md
    /root/notes.md
)

EXIST=()
for p in "${PATHS[@]}"; do
    [[ -e "$p" ]] && EXIST+=("$p")
done

# --- state dumps (placed under state/ inside tarball) ---------------------
TMP=$(mktemp -d -t pve-restore.XXXXXX)
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

state() { "$@" > "$TMP/$1.txt" 2>&1 || true; }

pveversion -v             > "$TMP/pveversion.txt"      2>&1 || true
qm list                   > "$TMP/qm-list.txt"         2>&1 || true
pct list                  > "$TMP/pct-list.txt"        2>&1 || true
pvesm status              > "$TMP/pvesm-status.txt"    2>&1 || true
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,UUID,MODEL > "$TMP/lsblk.txt" 2>&1 || true
blkid                     > "$TMP/blkid.txt"           2>&1 || true
ip -4 addr                > "$TMP/ip-addr.txt"         2>&1 || true
ip route                  > "$TMP/ip-route.txt"        2>&1 || true
brctl show 2>/dev/null    > "$TMP/brctl-show.txt"      || true
pvs 2>/dev/null           > "$TMP/lvm-pvs.txt"         || true
vgs 2>/dev/null           > "$TMP/lvm-vgs.txt"         || true
lvs 2>/dev/null           > "$TMP/lvm-lvs.txt"         || true
dpkg --get-selections     > "$TMP/dpkg-selections.txt" 2>&1 || true
apt-mark showmanual       > "$TMP/apt-manual.txt"      2>&1 || true
cat /proc/cmdline         > "$TMP/kernel-cmdline.txt"  2>&1 || true
uname -a                  > "$TMP/uname.txt"           2>&1 || true
systemctl list-unit-files --state=enabled > "$TMP/systemd-enabled.txt" 2>&1 || true
crontab -l 2>/dev/null    > "$TMP/root-crontab.txt"    || true

# README inside the tarball
cat > "$TMP/RESTORE-INSIDE.txt" <<EOF
pve-restore tarball generated $(date -Is) on $(hostname -f)
PVE: $(pveversion 2>/dev/null | head -1)

Contents:
  etc/pve/...            cluster config (VMs, storage, jobs, users)
  etc/network/...        host network
  etc/{ssh,fstab,hosts,...}  system config
  etc/cron.d/, etc/systemd/system/, etc/logrotate.d/  schedules
  usr/local/sbin/        pve-* operational scripts
  etc/pve-monitor.env    Pushover + MQTT + GPG creds
  root/.config/rclone/   rclone token (OneDrive)
  root/.ssh/             root keys
  state/                 pveversion, qm list, lsblk, ip, dpkg-selections, ...

Restore quickstart:
  1. Install PVE on bare metal (same major version: see state/pveversion.txt)
  2. Decrypt:  gpg -d --batch --passphrase \"\$RESTORE_GPG_PASS\" file.tar.gz.gpg | tar -xzv -C /
  3. systemctl daemon-reload && systemctl restart networking pve-cluster pvedaemon pveproxy
  4. dpkg --set-selections < /state/dpkg-selections.txt ; apt-get -y dselect-upgrade
  5. Restore VMs:  qmrestore <vzdump.vma.zst> <vmid>  (vzdumps from off-site weekly/ or monthly/)
  6. systemctl enable/start any custom units listed in state/systemd-enabled.txt

Full procedure: see docs/RESTORE.md in github.com/vladtsit/pve-ops.
EOF

# --- build + encrypt ------------------------------------------------------
# Stream tar through gpg, never write the plaintext tarball to disk.
# tar strips the leading / from absolute paths, so the transform pattern
# must match the de-rooted form (${TMP#/}) of the temp dir.
umask 077
TMP_NOROOT="${TMP#/}"
tar -czf - \
    --warning=no-file-changed \
    --transform="s,^${TMP_NOROOT}/,state/," \
    "${EXIST[@]}" "$TMP" 2>/dev/null \
  | gpg --batch --yes --quiet \
        --symmetric --cipher-algo AES256 \
        --passphrase "$RESTORE_GPG_PASS" \
        --output "$OUT"

chmod 600 "$OUT"

# --- prune old snapshots --------------------------------------------------
ls -1t "$DEST_DIR"/pve-restore-*.tar.gz.gpg 2>/dev/null \
    | tail -n +$((KEEP + 1)) \
    | xargs -r rm -f

# --- log + heartbeat ------------------------------------------------------
SIZE=$(du -h "$OUT" | cut -f1)
echo "[$(date -Is)] snapshot $OUT ($SIZE)" >> /var/log/pve-config-snapshot.log
tail -200 /var/log/pve-config-snapshot.log > /var/log/pve-config-snapshot.log.tmp \
    && mv /var/log/pve-config-snapshot.log.tmp /var/log/pve-config-snapshot.log

HB_STATUS=ok
[[ -s "$OUT" ]] || HB_STATUS=fail
/usr/local/sbin/pve-cron-heartbeat.sh config_snapshot "$HB_STATUS" "Config Snapshot" >/dev/null 2>&1 || true
