#!/bin/bash
# Called by smartd on any monitored event. Env: SMARTD_DEVICE, SMARTD_MESSAGE, SMARTD_FAILTYPE, etc.
. /etc/pve-monitor.env
TOKEN="$PUSHOVER_TOKEN"
USER="$PUSHOVER_USER"
TITLE="[smartd] ${SMARTD_FAILTYPE:-alert} on ${SMARTD_DEVICESTRING:-unknown}"
MSG="${SMARTD_FULLMESSAGE:-$SMARTD_MESSAGE}"
PRIORITY=1
case "${SMARTD_FAILTYPE:-}" in
    EmailTest|TemperatureInfo) PRIORITY=-1 ;;
    FailedHealthCheck|FailedReadSmartData|OfflineUncorrectableSector|CurrentPendingSector|FailedOpenDevice|SelfTestErrorCount) PRIORITY=1 ;;
esac
curl -s --max-time 15 https://api.pushover.net/1/messages.json \
    --form-string token="$TOKEN" \
    --form-string user="$USER" \
    --form-string title="$TITLE" \
    --form-string message="$MSG" \
    --form-string priority="$PRIORITY" \
