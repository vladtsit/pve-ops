# Bare-metal restore — Proxmox VE host

This procedure restores the host from scratch using:
- a fresh PVE install
- one encrypted `pve-restore-*.tar.gz.gpg` (from `OneDrive:proxmox-offsite/restore/`)
- the latest weekly/monthly vzdump archives (from `OneDrive:proxmox-offsite/{weekly,monthly}/`)

Estimated time on identical hardware: **45–90 min** (mostly vzdump restore).

## 0. Prerequisites

You need, **off the dead host**:

| Item | Where it lives |
|---|---|
| `RESTORE_GPG_PASS` (64-char passphrase) | password manager / printed copy |
| OneDrive account access | normal login + 2FA |
| GitHub access to `pve-ops` repo | normal login |
| PVE ISO matching the version in `state/pveversion.txt` | https://proxmox.com/downloads |

**Do NOT lose `RESTORE_GPG_PASS`.** Without it the encrypted snapshot is useless. Store a copy outside this host (password manager + 1 paper copy in a safe).

## 1. Reinstall PVE

1. Boot PVE installer of the matching major version.
2. Target the **same disk layout** as before (see `state/lsblk.txt` once decrypted). Typically: install to the small SSD; `/mnt/nvme` and other data disks left untouched on the NVMe drive (if it survived).
3. On first login set the same `hostname` and IP as before (cross-check `state/ip-addr.txt`).
4. Install minimal tools needed to pull the restore tarball:

   ```bash
   apt-get update && apt-get install -y rclone gnupg curl
   ```

## 2. Fetch the restore tarball + vzdumps from OneDrive

You can rclone-config from scratch, OR (faster) decrypt the small restore tarball first to recover the saved `rclone.conf` and then use the saved config to download vzdumps.

### 2a. Bootstrap rclone with OneDrive (interactive, one-time)

```bash
rclone config
# n) new remote
# name> OneDrive
# Storage> onedrive
# Use auto config? n  (PVE is headless; follow the URL on your laptop)
# ... paste the resulting token
```

### 2b. Pull the restore tarball

```bash
mkdir -p /root/restore && cd /root/restore
rclone copy OneDrive:proxmox-offsite/restore/ . --include "pve-restore-*.tar.gz.gpg"
ls -lh
```

Pick the most recent. (Older ones are kept for "oh no, this snapshot was already broken".)

### 2c. Pull the vzdumps for each VM

```bash
mkdir -p /var/lib/vz/dump
rclone copy OneDrive:proxmox-offsite/weekly/  /var/lib/vz/dump/ --transfers 1
# (or weekly/ + monthly/ — newest wins)
```

## 3. Decrypt and apply the host config

```bash
export RESTORE_GPG_PASS='<paste 64-char passphrase>'

LATEST=$(ls -1t /root/restore/pve-restore-*.tar.gz.gpg | head -1)
echo "Restoring from: $LATEST"

# Sanity-peek inside before extracting:
gpg -d --batch --passphrase "$RESTORE_GPG_PASS" "$LATEST" | tar -tz | head -30

# Extract to /
gpg -d --batch --passphrase "$RESTORE_GPG_PASS" "$LATEST" | tar -xz -C /

# Reload systemd, restart networking + pve services
systemctl daemon-reload
systemctl restart networking
systemctl restart pve-cluster pvedaemon pveproxy pvestatd
```

After this you have:
- `/etc/pve/` cluster config (incl. VM definitions, storage.cfg, vzdump.cron)
- `/etc/network/interfaces` (bridges, vlans)
- `/etc/fstab` (toshiba/nvme mounts)
- `/etc/cron.d/pve-*` + `/etc/systemd/system/*` (your schedules and units)
- `/usr/local/sbin/pve-*` (all monitoring scripts)
- `/etc/pve-monitor.env` (Pushover, MQTT, GPG creds — all still valid)
- `/root/.config/rclone/rclone.conf` (re-use the saved OneDrive token)
- `/root/.ssh/` + `/etc/ssh/` (host keys + your root keys)

## 4. Reinstall the package set

```bash
cd /  # or wherever you extracted
dpkg --set-selections < state/dpkg-selections.txt
apt-get update
apt-get -y dselect-upgrade
# This pulls back: smartmontools, ifupdown2, lm-sensors, qemu-guest-agent, etc
```

If the snapshot is older than the running PVE on the new install, `apt-get -y dist-upgrade` brings everything to current.

## 5. Re-create storage mountpoints (data disks)

If the NVMe data disk survived (the usual case — host SSD died, data NVMe is fine):

```bash
# /etc/fstab is already restored. Just mount:
mount -a
df -h
```

If the data NVMe also died: re-create LVM/filesystems per `state/lvm-{pvs,vgs,lvs}.txt` and `state/blkid.txt`, then `mount -a`.

## 6. Restore VMs

```bash
# For each VM, find the newest vzdump and restore:
for v in 100 101 102; do
    DUMP=$(ls -1t /var/lib/vz/dump/vzdump-qemu-${v}-*.vma.zst 2>/dev/null | head -1)
    [[ -n "$DUMP" ]] && qmrestore "$DUMP" "$v" --force --storage local-lvm
done
qm list
```

Adjust `--storage` to the right target per `/etc/pve/storage.cfg`.

## 7. Restart custom services + cron

```bash
# Re-enable any custom systemd units captured in state/systemd-enabled.txt
# (most are already enabled by the daemon-reload above; just verify)
grep -E "convert-copy|nic-watchdog|cpu-powersave|powertop" state/systemd-enabled.txt
systemctl restart cron

# Sanity check the cron heartbeats start publishing
sleep 360
mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
    -t 'pve/proxmox/cron/+/last_run' -C 10 -v
```

## 8. Re-pair MQTT discovery in HA

Pressure / cron / disk / system entities will republish themselves on the next cron tick. The old retained discovery messages on the broker are still valid, so HA picks them up immediately when the new host publishes to the same topics.

## 9. Power-cycle once, verify

```bash
systemctl reboot
# Wait, then:
ssh root@<host>
pveversion
qm list
df -h
systemctl --failed
tail /var/log/pve-pressure-monitor.log
```

If `systemctl --failed` is empty and pressure-monitor is publishing, you're done.

---

## Anti-pattern: don't store the passphrase in the off-site bucket

`RESTORE_GPG_PASS` is **not** in the encrypted tarball (it's the key to decrypt it — that would be circular). Keep it in:
- Your password manager (primary)
- A printed copy in a safe (offline fallback)
- Optionally a second password manager / family member's vault

If you ever rotate it: edit `/etc/pve-monitor.env`, run `/usr/local/sbin/pve-config-snapshot.sh` once, then `/usr/local/sbin/pve-offsite-onedrive.sh` to push the new encrypted snapshot. Old snapshots remain decryptable with the old passphrase until they age out of the 8-snapshot retention window (~2 months).
