#!/bin/bash
# Publish a heartbeat for a named cron/script to MQTT + HA discovery.
# Usage: pve-cron-heartbeat.sh <name> <ok|fail> [friendly-name]
#
# Topics published (retained):
#   pve/proxmox/cron/<name>/last_run   ISO-8601 timestamp
#   pve/proxmox/cron/<name>/status     "ok" | "fail"
# HA discovery:
#   sensor.pve_proxmox_cron_<name>_last_run        (device_class=timestamp)
#   binary_sensor.pve_proxmox_cron_<name>_status   (device_class=problem, on=fail)
#
# Stale-detection is left to HA (template/threshold/alert).

set -eu
[ $# -ge 2 ] || { echo "usage: $0 <name> <ok|fail> [friendly]" >&2; exit 2; }

NAME="$1"
STATUS="$2"
FRIENDLY="${3:-$NAME}"

# Sanitize name to MQTT/HA-safe slug
SLUG=$(printf '%s' "$NAME" | tr -c '[:alnum:]_-' '_' | tr '[:upper:]' '[:lower:]')

. /etc/pve-monitor.env

HOST_ID="proxmox"
BASE="pve/$HOST_ID/cron/$SLUG"
UID_BASE="pve_${HOST_ID}_cron_${SLUG}"
DEVICE_JSON='{"identifiers":["pve_cron_proxmox"],"name":"Proxmox Cron Heartbeats","manufacturer":"Intel NUC10i3FNH","model":"PVE 9.1"}'

pub() {
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        -u "$MQTT_USER" -P "$MQTT_PASS" \
        -r -t "$1" -m "$2" 2>/dev/null || true
}

NOW=$(date -Is)
pub "$BASE/last_run" "$NOW"
pub "$BASE/status"   "$STATUS"

pub "homeassistant/sensor/${UID_BASE}_last_run/config" \
"{\"name\":\"PVE Cron $FRIENDLY Last Run\",\"unique_id\":\"${UID_BASE}_last_run\",\"state_topic\":\"$BASE/last_run\",\"device_class\":\"timestamp\",\"entity_category\":\"diagnostic\",\"device\":$DEVICE_JSON}"

pub "homeassistant/binary_sensor/${UID_BASE}_status/config" \
"{\"name\":\"PVE Cron $FRIENDLY Status\",\"unique_id\":\"${UID_BASE}_status\",\"state_topic\":\"$BASE/status\",\"payload_on\":\"fail\",\"payload_off\":\"ok\",\"device_class\":\"problem\",\"entity_category\":\"diagnostic\",\"device\":$DEVICE_JSON}"
