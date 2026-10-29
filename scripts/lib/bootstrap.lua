-- Store postinstall only. No provider HTTP, vehicle commands or UI launches.
local M={}
local BASE='/data/adb/bmw-reareye-async-v3'
local NATIVE='/data/adb/bmw-reareye-native-v2'
local REVISION='fcde2de41e8262512c7c7caf9134d725caf965ad7f28bf18f9044e4e190fd742'
local DEX_PATH='/data/local/tmp/bmw-reareye-reader-749e3a09a331bb0c/reader.dex'
local function quote(s) return "'"..tostring(s):gsub("'","'\\''").."'" end
local function encoded(ctx,name)
    local value=ctx:readText(name)
    assert(type(value)=='string' and value:match('^[A-Za-z0-9+/=\r\n]+$'),'invalid local resource')
    return value
end
local function text(ctx,name)
    local value=ctx:readText(name)
    assert(type(value)=='string' and #value<262144 and not value:find('BMW_STORE_FILE_EOF',1,true),'invalid local resource')
    return value
end
local function write(path,data,decode,mode,marker)
    marker=marker or 'BMW_STORE_FILE_EOF'
    assert(not data:find('\n'..marker..'\n',1,true),'invalid local delimiter')
    return (decode and 'base64 -d' or 'cat')..' > '..quote(path..'.new').." <<'"..marker.."'\n"
        ..data..'\n'..marker..'\nchmod '..mode..' '..quote(path..'.new')
        ..'\nmv '..quote(path..'.new')..' '..quote(path)..'\n'
end
function M.job(ctx,version)
    assert(version:match('^[a-f0-9]+$') and #version==64,'version')
    local dexdir=assert(DEX_PATH:match('^(.*)/reader.dex$'))
    local job=[=[#!/system/bin/sh
set -eu
umask 077
BASE=/data/adb/bmw-reareye-async-v3
phase() { printf '%s\n' "$1" > "$BASE/store_init.phase.new"; mv "$BASE/store_init.phase.new" "$BASE/store_init.phase"; }
cleanup() {
  status=$?
  if [ "$status" != 0 ]; then phase FAILED || true; fi
  rmdir "$BASE/store-init.lock" 2>/dev/null || true
}
trap cleanup 0
trap 'exit 1' 1 2 15
phase INSTALLING
]=]
    job=job..'mkdir -p '..NATIVE..' '..quote(dexdir)..'\nchmod 700 '..NATIVE..'\nchmod 755 '..quote(dexdir)..'\n'
        ..write(DEX_PATH,encoded(ctx,'reader.b64'),true,'444')
        ..write(NATIVE..'/sync.sh',text(ctx,'sync.sh'):gsub('/data/local/tmp/bmw-reareye-reader-749e3a09a331bb0c/reader.dex',DEX_PATH),false,'600')
        ..write(NATIVE..'/revision',REVISION,false,'600')
        ..write(BASE..'/worker.py',encoded(ctx,'worker.b64'),true,'600')
        ..write(BASE..'/scheduler.py',encoded(ctx,'scheduler.b64'),true,'600')
        ..write(BASE..'/launch.sh',text(ctx,'launch.sh'),false,'600')
        ..write(BASE..'/boot.sh',text(ctx,'boot.sh'),false,'700')
    -- Exact bytes: ensure() compares these values without whitespace trimming.
    job=job..'printf %s '..quote(REVISION)..' > '..NATIVE..'/revision\n'
        ..'printf %s '..quote(version)..' > '..BASE..'/version\n'
        ..[=[phase RUNTIME_CHECK
runtime=$(/system/bin/sh "$BASE/launch.sh" runtime)
case "$runtime" in *PYTHON_OK*) ;; *) phase RUNTIME_MISSING; trap - 0; rmdir "$BASE/store-init.lock"; exit 1;; esac
timer=$(/system/bin/sh "$BASE/launch.sh" scheduler)
case "$timer" in SCHEDULER_STARTED|SCHEDULER_DISABLED) ;; *) phase SCHEDULER_FAILED; trap - 0; rmdir "$BASE/store-init.lock"; exit 1;; esac
if [ "$timer" = SCHEDULER_STARTED ] && [ -d /data/adb/service.d ]; then
  cp "$BASE/boot.sh" /data/adb/service.d/bmw_reareye_hourly.sh
  chmod 700 /data/adb/service.d/bmw_reareye_hourly.sh
fi
phase SYNC_QUEUING
nonce="$(date +%s)000"
reply=$(/system/bin/sh "$BASE/launch.sh" refresh "$nonce")
case "$reply" in *QUEUED*) ;; *) phase SYNC_NOT_QUEUED; trap - 0; rmdir "$BASE/store-init.lock"; exit 1;; esac
]=]
    job=job..'printf %s '..quote(version)..' > '..BASE..'/store_init.version\n'
        ..[=[if [ "$timer" = SCHEDULER_DISABLED ]; then phase READY_PAUSED; else phase READY; fi
]=]
    return job
end
local replies={READY='本机初始化已完成；授权是否有效请查看状态',BUSY='本机初始化进行中，请稍候',
    COOLDOWN='初始化暂缓，请稍后再试',QUEUED='本机初始化已排队，请等待几秒',NO_SETSID='缺少后台分离工具，初始化未启动',
    NO_TIMEOUT='缺少后台超时工具，初始化未启动'}
function M.start(ctx,h,version)
    local ok,job=pcall(M.job,ctx,version)
    if not ok then return '组件初始化资源不完整，请重新从云端安装' end
    local script='set -eu\numask 077\nBASE='..BASE..'\nVERSION='..quote(version)..'\n'..[=[
mkdir -p "$BASE"
chmod 700 "$BASE"
if [ -f "$BASE/store_init.version" ] && [ "$(cat "$BASE/store_init.version")" = "$VERSION" ] &&
   [ -f "$BASE/version" ] && [ "$(cat "$BASE/version")" = "$VERSION" ] &&
   [ -f "$BASE/worker.py" ] && [ -f "$BASE/scheduler.py" ] && [ -f "$BASE/launch.sh" ]; then
  printf READY; exit 0
fi
if ! command -v setsid >/dev/null 2>&1; then printf NO_SETSID; exit 0; fi
if [ ! -x /system/bin/timeout ]; then printf NO_TIMEOUT; exit 0; fi
if [ -d "$BASE/store-init.lock" ]; then
  age=$(( $(date +%s) - $(stat -c %Y "$BASE/store-init.lock") ))
  if [ "$age" -gt 180 ]; then rmdir "$BASE/store-init.lock" 2>/dev/null || true; fi
fi
if ! mkdir "$BASE/store-init.lock" 2>/dev/null; then printf BUSY; exit 0; fi
trap 'rmdir "$BASE/store-init.lock" 2>/dev/null || true' 0
now=$(date +%s)
if [ -f "$BASE/store_init.attempt_version" ] && [ "$(cat "$BASE/store_init.attempt_version")" = "$VERSION" ] && [ -f "$BASE/store_init.attempt_time" ]; then
  previous=$(cat "$BASE/store_init.attempt_time")
  case "$previous" in ''|*[!0-9]*) previous=0;; esac
  age=$(( now - previous ))
  if [ "$age" -ge 0 ] && [ "$age" -lt 60 ]; then printf COOLDOWN; exit 0; fi
fi
printf %s "$VERSION" > "$BASE/store_init.attempt_version"
printf %s "$now" > "$BASE/store_init.attempt_time"
]=]
    script=script..write(BASE..'/store_bootstrap.sh',job,false,'700','BMW_STORE_BOOTSTRAP_JOB_EOF')
        ..[=[printf QUEUED > "$BASE/store_init.phase"
setsid /system/bin/timeout 150 /system/bin/sh "$BASE/store_bootstrap.sh" </dev/null >/dev/null 2>&1 &
trap - 0
printf QUEUED
]=]
    local result=h.root(ctx,'/system/bin/sh',script)
    return replies[result or ''] or '初始化未确认启动，请检查 REAREye Root 授权'
end
local phases={QUEUED='初始化已排队',INSTALLING='正在部署本机运行文件',RUNTIME_CHECK='正在检查后台运行库',
    RUNTIME_MISSING='未找到可用的 Termux Python，请检查已有运行库',SCHEDULER_FAILED='定时器未确认启动',
    SYNC_QUEUING='正在同步本机官方授权',SYNC_NOT_QUEUED='本机授权同步未排队',FAILED='初始化未完成，请检查 Root 和本机运行库',
    READY='本机初始化完成；授权结果请查看 status',READY_PAUSED='本机初始化完成；整点更新沿用暂停设置'}
function M.status(ctx,h)
    local value=h.root(ctx,'if [ -f '..BASE..'/store_init.phase ]; then head -c 32 '..BASE..'/store_init.phase; fi')
    local phase=type(value)=='string' and value:match('^([A-Z_]+)%s*$')
    return phases[phase] or '暂无初始化记录，请从云端安装或运行 bootstrap'
end
return M
