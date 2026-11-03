#!/system/bin/sh
set -eu
umask 077
BASE=/data/adb/bmw-reareye-async-v3
case "${1:-}" in runtime|scheduler|telemetry|check|refresh|rebind|climate|lights|horn|hidden_setup|hidden_enable|hidden_inspect|hidden_remove) ;; *) exit 2;; esac
if [ "$1" = scheduler ] && [ -f "$BASE/scheduler.stop" ]; then printf SCHEDULER_DISABLED; exit 0; fi
PY=
PREFIX=
for prefix in /data/user/0/com.termux/files/usr /data/data/com.termux/files/usr /data/user/0/com.termux.monet/files/usr /data/user/0/com.termux.nightly/files/usr; do
    for name in python python3; do
        if [ -x "$prefix/bin/$name" ]; then PY=$prefix/bin/$name; PREFIX=$prefix; break; fi
    done
    if [ -n "$PY" ]; then break; fi
done
if [ -z "$PY" ]; then printf RUNTIME_MISSING; exit 0; fi
HOME_DIR=${PREFIX%/usr}/home
unset LD_PRELOAD LD_LIBRARY_PATH
if [ "$1" = runtime ]; then
    if /system/bin/env HOME="$HOME_DIR" PREFIX="$PREFIX" PATH="$PREFIX/bin:/system/bin:/system/xbin" LD_LIBRARY_PATH="$PREFIX/lib" PYTHONDONTWRITEBYTECODE=1 \
        "$PY" -c 'import ssl,json,fcntl,http.client; print("PYTHON_OK")' 2>/dev/null; then :
    else printf RUNTIME_FAILED; fi
    exit 0
fi
case "$1" in
hidden_setup)
    /system/bin/env HOME="$HOME_DIR" PREFIX="$PREFIX" PATH="$PREFIX/bin:/system/bin:/system/xbin" LD_LIBRARY_PATH="$PREFIX/lib" PYTHONDONTWRITEBYTECODE=1 \
        "$PY" "$BASE/hidden_host.py" enable
    exit $?;;
hidden_enable|hidden_inspect|hidden_remove)
    mode=${1#hidden_}
    if ! command -v setsid >/dev/null 2>&1; then printf SETSID_MISSING; exit 0; fi
    setsid /system/bin/timeout 65 /system/bin/env \
        HOME="$HOME_DIR" PREFIX="$PREFIX" PATH="$PREFIX/bin:/system/bin:/system/xbin" LD_LIBRARY_PATH="$PREFIX/lib" PYTHONDONTWRITEBYTECODE=1 \
        "$PY" "$BASE/hidden_host.py" "$mode" </dev/null >/dev/null 2>&1 &
    printf HIDDEN_QUEUED
    exit 0;;
esac
if ! command -v setsid >/dev/null 2>&1; then printf SETSID_MISSING; exit 0; fi
if [ "$1" = scheduler ]; then
    setsid /system/bin/env \
        HOME="$HOME_DIR" PREFIX="$PREFIX" PATH="$PREFIX/bin:/system/bin:/system/xbin" LD_LIBRARY_PATH="$PREFIX/lib" PYTHONDONTWRITEBYTECODE=1 \
        "$PY" "$BASE/scheduler.py" </dev/null >/dev/null 2>&1 &
    printf SCHEDULER_STARTED
    exit 0
fi
if [ "$1" = telemetry ]; then
    setsid /system/bin/timeout 120 /system/bin/env \
        HOME="$HOME_DIR" PREFIX="$PREFIX" PATH="$PREFIX/bin:/system/bin:/system/xbin" LD_LIBRARY_PATH="$PREFIX/lib" PYTHONDONTWRITEBYTECODE=1 \
        "$PY" "$BASE/worker.py" telemetry </dev/null >/dev/null 2>&1 &
    printf TELEMETRY_STARTED
    exit 0
fi
case "${2:-}" in ''|*[!0-9]*) exit 2;; esac
if [ "$#" -gt 3 ]; then exit 2; fi
if [ -n "${3:-}" ]; then
    [ "$1" = rebind ] || exit 2
    case "$3" in *[!A-HJ-NPR-Z0-9]*) exit 2;; esac
    [ "${#3}" = 17 ] || exit 2
fi
printf '{"action":"%s","received_at":%s,"phase":"QUEUED"}' "$1" "$(date +%s)" > "$BASE/receipt.json.new"
mv "$BASE/receipt.json.new" "$BASE/receipt.json"
setsid /system/bin/timeout 160 /system/bin/env \
    HOME="$HOME_DIR" PREFIX="$PREFIX" PATH="$PREFIX/bin:/system/bin:/system/xbin" LD_LIBRARY_PATH="$PREFIX/lib" PYTHONDONTWRITEBYTECODE=1 \
    "$PY" "$BASE/worker.py" "$1" "$2" ${3:+"$3"} </dev/null >/dev/null 2>&1 &
printf QUEUED
