#!/bin/bash
# Publish PVE host system telemetry (temps, load, mem, uptime) to MQTT + HA discovery
. /etc/pve-monitor.env
# Runs every 5 min via /etc/cron.d/pve-system-monitoring
set -eo pipefail

BASE="pve/proxmox/system"
HA_BASE="homeassistant"
DEV_ID="pve_proxmox_system"
DEV_NAME="Proxmox System"

pub() {
    # $1=topic suffix $2=payload (retained)
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
        -r -t "$BASE/$1" -m "$2" 2>/dev/null || true
}

pub_raw() {
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
        -r -t "$1" -m "$2" 2>/dev/null || true
}

DEV_JSON='"device":{"identifiers":["'"$DEV_ID"'"],"name":"'"$DEV_NAME"'","model":"NUC10i3FNH","manufacturer":"Intel"}'

# ---- HA auto-discovery (idempotent, retained) ----
disc_temp() {
    # $1=key $2=friendly name $3=icon
    pub_raw "$HA_BASE/sensor/${DEV_ID}_$1/config" \
'{"name":"'"$2"'","state_topic":"'"$BASE"'/'"$1"'","unique_id":"'"$DEV_ID"'_'"$1"'","device_class":"temperature","unit_of_measurement":"°C","state_class":"measurement","icon":"'"$3"'",'"$DEV_JSON"'}'
}
disc_num() {
    # $1=key $2=name $3=unit $4=icon $5=state_class
    pub_raw "$HA_BASE/sensor/${DEV_ID}_$1/config" \
'{"name":"'"$2"'","state_topic":"'"$BASE"'/'"$1"'","unique_id":"'"$DEV_ID"'_'"$1"'","unit_of_measurement":"'"$3"'","state_class":"'"$5"'","icon":"'"$4"'",'"$DEV_JSON"'}'
}
disc_ts() {
    pub_raw "$HA_BASE/sensor/${DEV_ID}_$1/config" \
'{"name":"'"$2"'","state_topic":"'"$BASE"'/'"$1"'","unique_id":"'"$DEV_ID"'_'"$1"'","device_class":"timestamp","icon":"mdi:clock-start",'"$DEV_JSON"'}'
}

disc_temp cpu_package    "CPU Package Temperature"  "mdi:thermometer"
disc_temp cpu_core0      "CPU Core 0 Temperature"   "mdi:thermometer"
disc_temp cpu_core1      "CPU Core 1 Temperature"   "mdi:thermometer"
disc_temp pch            "Chipset Temperature"      "mdi:chip"
disc_temp acpi           "Motherboard Temperature"  "mdi:expansion-card"
disc_num  load1          "Load Average 1m"          ""     "mdi:gauge"            measurement
disc_num  load5          "Load Average 5m"          ""     "mdi:gauge"            measurement
disc_num  load15         "Load Average 15m"         ""     "mdi:gauge"            measurement
disc_num  cpu_percent    "CPU Usage"                "%"    "mdi:cpu-64-bit"       measurement
disc_num  mem_percent    "Memory Usage"             "%"    "mdi:memory"           measurement
disc_num  mem_used_gb    "Memory Used"              "GB"   "mdi:memory"           measurement
disc_num  swap_percent   "Swap Usage"               "%"    "mdi:harddisk"         measurement
disc_num  root_percent   "Root Disk Usage"          "%"    "mdi:harddisk"         measurement
disc_ts   boot_time      "Last Boot"

# ---- read sensors ----
S=$(sensors -j 2>/dev/null || echo '{}')

# Use jq for parsing
get_temp() { echo "$S" | jq -r "$1 // empty" 2>/dev/null | awk '/^-?[0-9.]+$/ && $1 > -100 {printf "%.1f", $1}'; }

CPU_PKG=$(get_temp '."coretemp-isa-0000"."Package id 0".temp1_input')
CPU_C0=$(get_temp '."coretemp-isa-0000"."Core 0".temp2_input')
CPU_C1=$(get_temp '."coretemp-isa-0000"."Core 1".temp3_input')
PCH=$(get_temp '."pch_cannonlake-virtual-0".temp1.temp1_input')
ACPI=$(get_temp '."acpitz-acpi-0".temp2.temp2_input')

[[ -n "$CPU_PKG" ]] && pub cpu_package "$CPU_PKG"
[[ -n "$CPU_C0"  ]] && pub cpu_core0   "$CPU_C0"
[[ -n "$CPU_C1"  ]] && pub cpu_core1   "$CPU_C1"
[[ -n "$PCH"     ]] && pub pch         "$PCH"
[[ -n "$ACPI"    ]] && pub acpi        "$ACPI"

# ---- load average ----
read -r L1 L5 L15 _ < /proc/loadavg
pub load1  "$L1"
pub load5  "$L5"
pub load15 "$L15"

# ---- CPU % (delta over 1s) ----
read_cpu() { awk '/^cpu / {idle=$5+$6; total=0; for(i=2;i<=NF;i++)total+=$i; print total, idle}' /proc/stat; }
read t1 i1 < <(read_cpu); sleep 1; read t2 i2 < <(read_cpu)
dt=$((t2 - t1)); di=$((i2 - i1))
if (( dt > 0 )); then
    CPU_PCT=$(awk -v dt="$dt" -v di="$di" 'BEGIN{printf "%.1f", (1 - di/dt)*100}')
    pub cpu_percent "$CPU_PCT"
fi

# ---- memory ----
MEM=$(awk '
    /^MemTotal:/ {t=$2}
    /^MemAvailable:/ {a=$2}
    /^SwapTotal:/ {st=$2}
    /^SwapFree:/ {sf=$2}
    END {
        used=t-a
        printf "%.1f %.2f", (used/t)*100, used/1024/1024
        if (st > 0) printf " %.1f", ((st-sf)/st)*100; else printf " 0"
    }' /proc/meminfo)
read MEM_PCT MEM_USED_GB SWAP_PCT <<< "$MEM"
pub mem_percent  "$MEM_PCT"
pub mem_used_gb  "$MEM_USED_GB"
pub swap_percent "$SWAP_PCT"

# ---- root disk usage ----
ROOT_PCT=$(df --output=pcent / | tail -1 | tr -dc '0-9')
pub root_percent "$ROOT_PCT"

# ---- boot time (ISO) ----
BOOT_ISO=$(date -u -d "@$(awk '/^btime/{print $2}' /proc/stat)" +%Y-%m-%dT%H:%M:%S+00:00)
pub boot_time "$BOOT_ISO"
