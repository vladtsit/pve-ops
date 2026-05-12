#!/usr/bin/env bash
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "must run as root"; exit 1; }
cd "$(dirname "$0")"
install -m 0755 sbin/pve-*.sh        /usr/local/sbin/
install -m 0644 cron.d/pve-*         /etc/cron.d/
install -m 0644 logrotate.d/pve-*    /etc/logrotate.d/
echo "Installed. Ensure /etc/pve-monitor.env exists with mode 600:"
echo "  cp etc/pve-monitor.env.example /etc/pve-monitor.env && chmod 600 /etc/pve-monitor.env"
