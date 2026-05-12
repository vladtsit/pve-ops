# pve-ops

Operational scripts, cron schedules, logrotate config, env template, and
**bare-metal recovery procedure** for the Proxmox VE host
(NUC10i3FNH @ 192.168.3.20).

## Layout

| Path in repo            | Installed to                  |
|-------------------------|-------------------------------|
| `sbin/pve-*.sh`         | `/usr/local/sbin/`            |
| `cron.d/pve-*`          | `/etc/cron.d/`                |
| `logrotate.d/pve-monitor` | `/etc/logrotate.d/`         |
| `etc/pve-monitor.env.example` | copy to `/etc/pve-monitor.env`, fill in, `chmod 600` |
| `docs/RESTORE.md`       | bare-metal restore procedure  |

## Scripts

| Script | Purpose | Schedule |
|---|---|---|
| `pve-pressure-monitor.sh`     | Per-target memory/swap/disk pressure -> Pushover + MQTT | every 5 min |
| `pve-system-mqtt-publish.sh`  | Host CPU/load/mem/uptime -> MQTT discovery              | every 5 min |
| `pve-disk-mqtt-publish.sh`    | smartctl per-disk -> MQTT discovery                     | every 30 min |
| `pve-disk-weekly-summary.sh`  | Weekly SMART digest -> Pushover                         | Mon 08:00 |
| `pve-config-snapshot.sh`      | GPG-encrypted bare-metal recovery tarball               | weekly Sun |
| `pve-offsite-onedrive.sh`     | Off-site rclone of vzdump + restore tarball to OneDrive | weekly Sun 04:00 |
| `pve-vm-fstrim.sh`            | `fstrim -av` inside VMs via qm guest exec               | weekly Sun 03:30 |
| `pve-cron-heartbeat.sh`       | Helper: publish retained heartbeat + HA discovery       | (called by other scripts) |

## Disaster recovery

The combination of:

1. **vzdump archives** in `OneDrive:proxmox-offsite/{weekly,monthly}/` — VM data
2. **GPG-encrypted host config tarball** in `OneDrive:proxmox-offsite/restore/` — everything else needed to rebuild the host: `/etc/pve`, network, ssh keys, cron, scripts, `dpkg --get-selections`, LVM layout, kernel cmdline, ...
3. **`RESTORE_GPG_PASS`** stored separately (password manager + paper backup)

...lets you fully rebuild the host on any matching hardware. See **[docs/RESTORE.md](docs/RESTORE.md)** for the step-by-step procedure.

## Install / re-sync

```bash
sudo ./install.sh         # copies files to canonical locations + sets perms
```

## Re-sync from live host into repo (after editing live files)

```bash
sudo ./setup-pve-ops-repo.sh   # the bootstrap script (preserves README + docs/)
git -C /root/pve-ops diff       # review
git -C /root/pve-ops commit -am "live sync $(date -I)"
git -C /root/pve-ops push
```
