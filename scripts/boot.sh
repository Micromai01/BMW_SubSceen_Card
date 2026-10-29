#!/system/bin/sh
# Read-only hourly updater. Does not refresh login or send any vehicle command.
BASE=/data/adb/bmw-reareye-async-v3
(
    attempt=0
    while [ "$attempt" -lt 120 ]; do
        [ -f "$BASE/scheduler.stop" ] && exit 0
        if [ "$(getprop sys.boot_completed)" = 1 ]; then
            result=$(/system/bin/nsenter -t 1 -m -- /system/bin/sh "$BASE/launch.sh" scheduler 2>/dev/null)
            case "$result" in *SCHEDULER_STARTED*|*SCHEDULER_DISABLED*) exit 0;; esac
        fi
        attempt=$((attempt+1))
        sleep 60
    done
) </dev/null >/dev/null 2>&1 &
