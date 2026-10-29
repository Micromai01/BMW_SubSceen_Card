-- Local authorization helper. The v3.5 bridge uses an existing Termux Python worker.
local json = require('lib.json')
local BASE = '/data/adb/bmw-reareye-native-v2'
local CAPABILITY = '749e3a09a331bb0c986a32ec059424d6dd97d79799d86811'
local REVISION = 'fcde2de41e8262512c7c7caf9134d725caf965ad7f28bf18f9044e4e190fd742'
local DEX_PATH = '/data/local/tmp/bmw-reareye-reader-749e3a09a331bb0c/reader.dex'
local LABELS = {climate='空调', lights='闪灯', horn='鸣笛'}
local SERVICES = {climate='climate-now?action=START',lights='light-flash',horn='horn-blow'}
local function quote(s) return "'"..tostring(s):gsub("'","'\\''").."'" end
local function execute(ctx, command, stdin)
    local ok, r=pcall(function() return ctx.root:exec(command,{stdin=stdin or '',timeoutMillis=1800}) end)
    if not ok or not r or r.timedOut or r.outputLimitExceeded or r.exitCode~=0 then return nil end
    return r.stdout or ''
end
local access_probe=[=[# ROOT_ACCESS_PROBE: opens paths without reading their contents.
uid=$(id -u 2>/dev/null)
case "$uid" in ''|*[!0-9]*) uid=unknown;; esac
printf 'ROOT_UID=%s\n' "$uid"
if [ "$uid" != 0 ]; then printf 'MODE=NO_ROOT\n'; exit 0; fi
path=/data/user/0/de.bmw.connected.mobile20.cn/shared_prefs/FlutterSecureStorage.xml
alias=/data/data/de.bmw.connected.mobile20.cn/shared_prefs/FlutterSecureStorage.xml
if ( : < "$path" ) 2>/dev/null || ( : < "$alias" ) 2>/dev/null; then
    printf 'DIRECT_OPEN=OK\nMODE=DIRECT\n'
    exit 0
fi
printf 'DIRECT_OPEN=FAILED\n'
probe='( : < /data/user/0/de.bmw.connected.mobile20.cn/shared_prefs/FlutterSecureStorage.xml ) 2>/dev/null || ( : < /data/data/de.bmw.connected.mobile20.cn/shared_prefs/FlutterSecureStorage.xml ) 2>/dev/null'
if [ -x /system/bin/nsenter ]; then
    if /system/bin/nsenter -t 1 -m -- /system/bin/sh -c "$probe" </dev/null >/dev/null 2>&1; then
        printf 'INIT_OPEN=OK\nMODE=INIT_SYSTEM\n'; exit 0
    fi
    printf 'INIT_OPEN=FAILED\n'
elif [ -x /data/adb/magisk/busybox ]; then
    if /data/adb/magisk/busybox nsenter -t 1 -m -- /system/bin/sh -c "$probe" </dev/null >/dev/null 2>&1; then
        printf 'INIT_OPEN=OK\nMODE=INIT_MAGISK\n'; exit 0
    fi
    printf 'INIT_OPEN=FAILED\n'
else printf 'INIT_OPEN=UNAVAILABLE\n'
fi
printf 'MODE=DIRECT\n'
]=]
local selected_mode,probe_result=nil,nil
local function choose_access(ctx)
    if selected_mode then return end
    probe_result=execute(ctx,access_probe) or 'ROOT_UID=unknown\nMODE=NO_ROOT\n'
    selected_mode=probe_result:match('MODE=([A-Z_]+)') or 'NO_ROOT'
end
local function root(ctx,command,stdin)
    choose_access(ctx)
    if selected_mode=='NO_ROOT' then return nil end
    if selected_mode=='INIT_SYSTEM' then
        command='/system/bin/nsenter -t 1 -m -- /system/bin/sh -c '..quote(command)
    elseif selected_mode=='INIT_MAGISK' then
        command='/data/adb/magisk/busybox nsenter -t 1 -m -- /system/bin/sh -c '..quote(command)
    end
    return execute(ctx,command,stdin)
end
local function check(_,_,ctx)
    choose_access(ctx)
    local uid=probe_result:match('ROOT_UID=([%w_]+)') or 'unknown'
    local direct=probe_result:match('DIRECT_OPEN=([A-Z]+)') or 'UNKNOWN'
    local global=probe_result:match('INIT_OPEN=([A-Z]+)') or 'NOT_NEEDED'
    local extra=execute(ctx,[=[
printf 'CTX='; id -Z 2>/dev/null || true
printf '\nUSER='; am get-current-user 2>/dev/null || true
for path in /data/user/0/de.bmw.connected.mobile20.cn /data/data/de.bmw.connected.mobile20.cn; do
    if [ -d "$path" ]; then printf '\nAPP_DIR=EXISTS'; else printf '\nAPP_DIR=HIDDEN_OR_MISSING'; fi
done
printf '\n'
]=]) or ''
    -- Whitelist whole diagnostic fields. Never forward arbitrary command output.
    local context=extra:match('CTX=([a-zA-Z0-9_:,%.%-]+)') or 'unknown'
    local user=extra:match('USER=(%d+)') or 'unknown'
    local dir=extra:match('APP_DIR=([A-Z_]+)') or 'unknown'
    return 'Root UID='..uid..'\n普通空间='..direct..'\n系统空间='..global
        ..'\n所选通道='..selected_mode..'\nSELinux上下文='..context..'\n当前用户='..user..'\n应用目录='..dir
end
local function write(ctx,name,data)
    assert(name:match('^[a-z_]+[.]?[a-z]*$'),'filename')
    return root(ctx,'umask 077; cat > '..BASE..'/'..name..'.new && mv '..BASE..'/'..name..'.new '..BASE..'/'..name,data)~=nil
end
local function decode(s)
    if type(s)~='string' then return nil end
    local ok, obj=pcall(json.decode,s); if ok and type(obj)=='table' then return obj end
end
local function details(_,_,ctx)
    local raw=root(ctx,'if [ -f '..BASE..'/auth_diag.txt ]; then head -c 4096 '..BASE..'/auth_diag.txt; fi')
    if not raw then return '诊断读取失败，请检查Root' end
    local output={}
    local stage_slot=nil
    for line in raw:gmatch('[^\r\n]+') do
        if line:match('^APP_UID=%d+$') or line:match('^HELPER_EXIT=%d+$') or line:match('^BMW_HELPER_UID:%d+$')
            or line:match('^SCRIPT_EXIT=%d+$') or line:match('^APK_COUNT=%d+$')
            or line:match('^CMD_PATH_EXIT=%d+$') or line:match('^PM_PATH_EXIT=%d+$') then
            output[#output+1]=line
        elseif line:match('^AUTH_RESULT=[A-Z_]+$') or line:match('^PACKAGE_SOURCE=[A-Z_]+$') then output[#output+1]=line
        elseif line:match('^SYNC_STAGE=[a-z_]+$') then
            if not stage_slot then stage_slot=#output+1 end
            output[stage_slot]=line
        elseif line:match('^BMW_ACCESS:[A-Z_]+$') then
            output[#output+1]=line
        elseif line:match('^BMW_STAGE:[a-z_]+$') then output[#output+1]=line
        elseif line:match('^NATIVE_ERROR=[A-Z_]+$') or line:match('^NATIVE_ERROR=[A-Za-z]+Exception$') or line:match('^NATIVE_ERROR=[A-Za-z]+Error$') then
            output[#output+1]=line
        elseif line:match('^BMW_ERROR:[A-Z_]+$') then output[#output+1]=line
        elseif (line:match('^BMW_ERROR:[A-Za-z0-9_.$]+Exception$') or line:match('^BMW_ERROR:[A-Za-z0-9_.$]+Error$')
            or line:match('^BMW_CAUSE:[A-Za-z0-9_.$]+Exception$') or line:match('^BMW_CAUSE:[A-Za-z0-9_.$]+Error$')) then
            output[#output+1]=line
        end
    end
    return #output>0 and table.concat(output,'\n') or '暂无读取诊断，请先运行setup一次'
end
local function snapshot(ctx)
    local command=''
    for _,name in ipairs({'auth.raw','pending.json','auth_state','build.txt','version.txt'}) do
        command=command..'printf "\\nBMWS2:'..name..'\\n"; if [ -f '..BASE..'/'..name
            ..' ]; then head -c '..(name=='auth.raw' and '65536' or '8192')..' '..BASE..'/'..name..'; fi; '
    end
    command=command..[=[printf '\nBMWS2:cached\n'; for home in /data/user/0/com.termux/files/home /data/data/com.termux/files/home /data/user/0/com.termux.monet/files/home /data/user/0/com.termux.nightly/files/home; do
  file=$(ls -1 "$home"/.bmw-local/login_token_*.json 2>/dev/null | sort -r | head -n 1)
  if [ -n "$file" ] && [ -r "$file" ]; then head -c 65536 "$file"; break; fi
done; printf '\nBMWS2:end\n']=]
    local raw=root(ctx,command); if not raw then return nil end
    local result={}
    -- Delimiters overlap, so retain each next marker for the next iteration.
    local position=1
    while true do
        local a,b,name=raw:find('\nBMWS2:([^\n]+)\n',position)
        if not a then break end
        local next_pos=raw:find('\nBMWS2:',b+1,true)
        if not next_pos then break end
        result[name]=raw:sub(b+1,next_pos-1); position=next_pos
    end
    return result
end
local function install(ctx)
    local r=root(ctx,'if [ -f '..BASE..'/revision ]; then cat '..BASE..'/revision; fi')
    if r==REVISION then return true end
    local dex=ctx:readText('reader.b64')
    if not dex:match('^[A-Za-z0-9+/=\r\n]+$') then return false end
    local sh=ctx:readText('sync.sh'):gsub('__DEX_PATH__',DEX_PATH)
    local directory=DEX_PATH:match('^(.*)/reader.dex$')
    local cmd='set -eu\numask 077\nmkdir -p '..BASE..'\nchmod 700 '..BASE..'\n'
        ..'mkdir -p '..directory..'\nchmod 755 '..directory..'\n'
        ..'base64 -d > '..DEX_PATH..'.new <<\'BMW_DEX_EOF\'\n'..dex..'\nBMW_DEX_EOF\n'
        ..'chmod 444 '..DEX_PATH..'.new\nmv '..DEX_PATH..'.new '..DEX_PATH..'\n'
        ..'cat > '..BASE..'/sync.sh.new <<\'BMW_SYNC_EOF\'\n'..sh..'\nBMW_SYNC_EOF\n'
        ..'chmod 600 '..BASE..'/sync.sh.new\nmv '..BASE..'/sync.sh.new '..BASE..'/sync.sh\n'
        ..'printf %s '..quote(REVISION)..' > '..BASE..'/revision\n'
    return root(ctx,'/system/bin/sh',cmd)~=nil
end
local function sync(ctx)
    local r=root(ctx,'if ! command -v setsid >/dev/null 2>&1; then printf NO_SETSID; exit 0; fi; '
        ..'if [ -d '..BASE..'/sync.lock ]; then age=$(( $(date +%s) - $(stat -c %Y '..BASE..'/sync.lock) )); '
        ..'if [ "$age" -gt 65 ]; then rmdir '..BASE..'/sync.lock 2>/dev/null || true; fi; fi; '
        ..'if ! mkdir '..BASE..'/sync.lock 2>/dev/null; then printf BUSY; exit 0; fi; '
        ..'printf READING > '..BASE..'/auth_state; '
        ..'setsid /system/bin/sh -c '..quote('/system/bin/timeout 50 /system/bin/sh '..BASE..'/sync.sh; '
            ..'rmdir '..BASE..'/sync.lock 2>/dev/null')..' </dev/null >/dev/null 2>&1 & printf SYNC_QUEUED')
    if not r then return '未能启动本地授权同步，请检查Root' end
    if r:find('NO_SETSID',1,true) then return '系统缺少setsid，未发送指令' end
    return '正在同步本机授权，几秒后运行status'
end
local function b64url(s)
    local alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    s=s:gsub('-','+'):gsub('_','/'):gsub('=+$','')
    local n,bits,out=0,0,{}
    for i=1,#s do
        local p=alphabet:find(s:sub(i,i),1,true); if not p then return nil end
        n=n*64+p-1; bits=bits+6
        if bits>=8 then bits=bits-8; out[#out+1]=string.char(math.floor(n/2^bits)%256); n=n%2^bits end
    end
    return table.concat(out)
end
local function token_value(p,now)
    for _,key in ipairs({'nw_access_token','access_token'}) do
        local t=p[key]
        if type(t)=='string' and #t>=20 and not t:find('[\r\n]') then
            t=t:gsub('^[Bb][Ee][Aa][Rr][Ee][Rr] +','')
            local claim=t:match('^[^.]+[.]([^.]+)[.]')
            local obj=claim and decode(b64url(claim))
            if obj and type(obj.exp)=='number' and obj.exp>now+10 then return t end
        end
    end
end
local function vin_value(p)
    local function valid(v) return type(v)=='string' and #v==17 and v:match('^[A-HJ-NPR-Z0-9]+$') end
    if valid(p.selected_vin) then return p.selected_vin end
    local cache=type(p.vehicle_cache)=='string' and decode(p.vehicle_cache) or p.vehicle_cache
    local found={}
    local function walk(t,d)
        if type(t)~='table' or d>15 then return end
        for k,v in pairs(t) do
            if type(k)=='string' and (k:lower()=='vin' or k:lower()=='vehicleidentificationnumber') and valid(v) then found[v]=true
            elseif type(v)=='table' then walk(v,d+1) end
        end
    end
    walk(cache,0); local only,count=nil,0
    for v in pairs(found) do only=v; count=count+1 end
    if count==1 then return only end
end
local function login(ctx,snap)
    -- All output is captured inside this provider; it is never returned to callers/logs.
    snap=snap or snapshot(ctx); if not snap then return nil end
    local native=snap['auth.raw']
    local candidates={}
    if native then
        local raw=native:match('BMW_TOKEN_JSON:([^\r\n]+)')
        local p=raw and decode(raw); if p then candidates[#candidates+1]=p end
    end
    local cached=snap.cached
    local old=cached and decode(cached)
    if old and type(old.tokens)=='table' then candidates[#candidates+1]=old.tokens end
    local now=ctx:now()/1000
    for _,p in ipairs(candidates) do
        local t=token_value(p,now); local v=vin_value(p)
        if t and v then return p,t,v end
    end
end
local function destination(p)
    local raw=p.omc_api_host or 'myprofile.bmw.com.cn'
    if type(raw)~='string' then return nil end
    raw=raw:gsub('^https://','')
    local host,path=raw:match('^([^/]+)(.*)$')
    if not host or not host:match('^[a-z0-9.-]+%.bmw%.com%.cn$') or not path:match('^[A-Za-z0-9/_-]*$') then return nil end
    return 'https://'..host..path:gsub('/+$','')
end
local function uuid(ctx)
    local ms=ctx:now(); local a=math.floor(ms/65536)%4294967296; local b=ms%65536
    return string.format('%08x-%04x-4%03x-8%03x-%s',a,b,b%4096,(b+17)%4096,CAPABILITY:sub(1,12))
end
local function headers(ctx,p,token,vin,snap)
    snap=snap or snapshot(ctx) or {}
    local meta=(snap['build.txt'] or '')..'\n'..(snap['version.txt'] or '')
    local build,code=meta:match('^([A-Za-z0-9._-]+)%s+([0-9]+)')
    local correlation=uuid(ctx)
    local h={Authorization='Bearer '..token, Accept='application/json', ['Accept-Language']='zh-CN',
        ['User-Agent']='BMW-local-readonly-check/0.2', ['x-identity-provider']='gcdm',
        ['x-widget-request']='widget', ['BMW-request-source']='android_widget', ['BMW-Session-ID']=correlation,
        ['x-user-agent']='android('..(build or 'unknown')..');bmw;6.9.0('..(code or 'unknown')..');cn',
        ['x-correlation-id']=correlation,['BMW-Correlation-Id']=correlation,['x-raw-locale']='zh-CN',
        ['24-hour-format']='true',['bmw-units-preferences']='d=KM;v=L;p=B;ec=KWH100KM;fc=L100KM;em=GKM;'}
    if vin then h['bmw-vin']=vin; h['Content-Type']='application/json' end
    for key,name in pairs({gcid='x-gcid',['Ocp-Apim-Subscription-Key']='Ocp-Apim-Subscription-Key'}) do
        local value=p[key]
        if type(value)=='string' and #value<=4096 and not value:find('[\r\n]') and #value>0 then h[name]=value end
    end
    return h
end
local function request(ctx,url,method,h,body)
    local ok,r=pcall(function() return ctx.http:request({url=url,method=method,headers=h,body=body,
        timeoutMillis=2200,followRedirects=false,followSslRedirects=false}) end)
    if not ok or not r then return nil end
    return r
end
local function pending(ctx,snap)
    local raw=snap and snap['pending.json'] or root(ctx,'if [ -f '..BASE..'/pending.json ]; then head -c 8192 '..BASE..'/pending.json; fi')
    return raw and decode(raw)
end
local function save_pending(ctx,p) return write(ctx,'pending.json',json.encode(p)) end
local function link(_,_,ctx)
    local project=tostring(ctx.projectId or 'unknown')
    if not project:match('^[A-Za-z0-9_:.-]+$') then project='unknown' end
    local p=pending(ctx)
    local lines={'脚本项目='..project,'匹配项目=BMW_i3_Cloud_AllInOne'}
    if not p then lines[#lines+1]='有效控车记录=暂无'; return table.concat(lines,'\n') end
    local known={SENDING=true,UNKNOWN=true,PENDING=true,DELIVERED=true,INITIATED=true,EXECUTED=true,
        ERROR=true,FAILED=true,IGNORED=true,AUTH_ERROR=true,REJECTED=true}
    lines[#lines+1]='最近操作='..(LABELS[p.action] or '未知')
    lines[#lines+1]='提交状态='..(known[p.phase] and p.phase or 'UNKNOWN')
    if type(p.created_at)=='number' then
        lines[#lines+1]='距提交秒数='..string.format('%.0f',math.max(0,ctx:now()/1000-p.created_at))
    end
    if type(p.http_status)=='number' and p.http_status>=100 and p.http_status<=599 then
        lines[#lines+1]='提交HTTP='..tostring(p.http_status)
    end
    return table.concat(lines,'\n')
end
local function normalized_nonce(value)
    if type(value)~='number' and type(value)~='string' then return nil end
    local raw=tostring(value)
    if #raw>32 or not raw:match('^[0-9.eE+-]+$') then return nil end
    local number=tonumber(raw)
    if not number or number~=number or number<1000000000000 or number>9007199254740991 or number%1~=0 then return nil end
    -- MAML numeric-to-string conversion may produce 1.79294E12 or a .0 suffix.
    return string.format('%.0f',number)
end
local TERMINAL={EXECUTED=true,ERROR=true,FAILED=true,IGNORED=true}
local function setup(_,_,ctx)
    if not install(ctx) then return '初始化失败，请允许REAREye Root后重试' end
    return sync(ctx)
end
local function status(_,_,ctx)
    local snap=snapshot(ctx)
    if not snap then return 'Root读取失败，请检查REAREye授权' end
    local state=(snap.auth_state or ''):match('^%s*(.-)%s*$')
    local p=pending(ctx,snap)
    if p and type(p.created_at)=='number' and ctx:now()/1000-p.created_at<90 then
        local label=LABELS[p.action] or '请求'
        if TERMINAL[p.phase] then
            if ctx:now()/1000-(p.updated_at or p.created_at)>12 then return '' end
            return p.phase=='EXECUTED' and label..'：服务器报告已执行' or label..'未执行成功'
        end
        if type(p.event_id)=='string' and #p.event_id<=512 and #p.event_id>0 then
            local auth,token,vin=login(ctx,snap)
            local origin=auth and destination(auth)
            if not origin or vin~=p.vin then return '登录已失效，请重新同步授权' end
            local method=p.query_get and 'GET' or 'POST'
            local event=p.event_id:gsub('[^%w%-._~]',function(c) return string.format('%%%02X',c:byte()) end)
            local r=request(ctx,origin..'/eadrax-vrccs/v3/presentation/remote-commands/eventStatus?eventId='..event,
                method,headers(ctx,auth,token,nil,snap),nil)
            if not r then return label..'已受理，结果待确认' end
            if method=='POST' and (r.statusCode==400 or r.statusCode==404 or r.statusCode==405 or r.statusCode==409 or r.statusCode==422) then
                p.query_get=true; save_pending(ctx,p); return label..'已受理，结果待确认'
            end
            local obj=r.ok and decode(r.body)
            local phase=obj and obj.eventStatus
            if type(phase)=='string' and (TERMINAL[phase] or phase=='PENDING' or phase=='DELIVERED' or phase=='INITIATED') then
                p.phase=phase; p.updated_at=ctx:now()/1000; save_pending(ctx,p)
                if phase=='EXECUTED' then return label..'：服务器报告已执行' end
                if TERMINAL[phase] then return label..'未执行成功' end
            end
            return label..'已受理，结果待确认'
        end
        if p.phase=='AUTH_ERROR' then return '登录失效，请打开My BMW刷新后运行setup' end
        if p.phase=='REJECTED' then return label..'请求未被接受' end
        return label..'结果未确认，请查看My BMW'
    end
    if state=='READING' then return '正在同步本机授权，请稍候' end
    local error_text={VERSION_UNSUPPORTED='本地同步仅适配My BMW 6.9.0',PACKAGE_INFO_UNAVAILABLE='无法获取My BMW安装信息',APP_DATA_UNREADABLE='Root无法读取My BMW数据',
        KEYSET_MISSING='My BMW尚无现有登录存储',UID_UNAVAILABLE='无法确定My BMW应用身份',
        APK_PATH_UNAVAILABLE='无法读取My BMW安装路径',SYNC_TIMEOUT='授权同步超时，请打开My BMW后重试',
        SYNC_FAILED='授权读取未完成；请运行details查看失败阶段'}
    local auth=login(ctx,snap)
    if auth then return state=='SYNC_COMPLETE' and '授权已就绪，可直接控车' or '现有授权可用，可直接控车' end
    if state=='SYNC_COMPLETE' then return '缓存授权不可用，请打开My BMW刷新后重试' end
    return error_text[state] or '请运行setup同步本机授权'
end
local function control(params,_,ctx)
    if params.key~=CAPABILITY then return '调用未授权' end
    local action=params.action
    if not SERVICES[action] then return '' end
    local nonce=normalized_nonce(params.nonce)
    if not nonce then return '请求时间格式无效，请更新匹配卡片' end
    if not install(ctx) then return '初始化失败，请运行setup' end
    local now=ctx:now()/1000
    if math.abs(tonumber(nonce)/1000-now)>30 then return '旧请求已忽略，请重新点击' end
    local snap=snapshot(ctx)
    local auth,token,vin=login(ctx,snap)
    if not auth then return '授权不可用，请在脚本页运行setup' end
    local origin=destination(auth)
    if not origin then return '本地云端地址不符合要求' end
    local h=headers(ctx,auth,token,vin,snap)
    -- This atomic root lock protects against two ContentProvider sessions in parallel.
    local locked=root(ctx,'umask 077; if [ -d '..BASE..'/control.lock ]; then '
        ..'age=$(( $(date +%s) - $(stat -c %Y '..BASE..'/control.lock) )); '
        ..'if [ "$age" -gt 45 ]; then rmdir '..BASE..'/control.lock 2>/dev/null || true; fi; fi; '
        ..'if mkdir '..BASE..'/control.lock 2>/dev/null; then printf LOCKED; fi')
    if locked~='LOCKED' then return '上一请求尚未结束，请稍候' end
    local function submit()
        local old=pending(ctx)
        if old and old.nonce==nonce then return '相同请求已处理，未重复发送' end
        if old and type(old.created_at)=='number' and now-old.created_at<30 then return '请稍后再试，未重复发送' end
        local p={action=action,nonce=nonce,vin=vin,created_at=now,phase='SENDING'}
        if not save_pending(ctx,p) then return '未能保存请求记录，未发送指令' end
        local r=request(ctx,origin..'/eadrax-vrccs/v4/presentation/remote-commands/'..SERVICES[action],'POST',h,'{}')
        p.updated_at=ctx:now()/1000
        if not r then p.phase='UNKNOWN'; save_pending(ctx,p); return '连接超时，结果未知；未自动重发' end
        if type(r.statusCode)=='number' then p.http_status=r.statusCode end
        if r.statusCode==401 or r.statusCode==403 then p.phase='AUTH_ERROR'; save_pending(ctx,p); return '登录失效，请打开My BMW刷新' end
        if not r.ok then
            p.phase=r.statusCode>=500 and 'UNKNOWN' or 'REJECTED'; save_pending(ctx,p)
            return LABELS[action]..(r.statusCode>=500 and '结果未知，未自动重发，HTTP ' or '请求未被接受，HTTP ')..tostring(r.statusCode)
        end
        local obj=decode(r.body)
        if obj and type(obj.eventId)=='string' and #obj.eventId>0 and #obj.eventId<=512 then
            p.event_id=obj.eventId; p.phase='PENDING'
        else p.phase='UNKNOWN' end
        save_pending(ctx,p)
        return LABELS[action]..'已受理，结果待确认'
    end
    local ok,message=pcall(submit)
    root(ctx,'rmdir '..BASE..'/control.lock 2>/dev/null || true')
    if not ok then return '提交过程未完成，结果未知；未自动重发' end
    return message
end
return {id='bmw_i3_cloud', name='BMW i3 云端背屏 v2.4 · 卡片调用适配',
    internal={root=root,install=install,sync=sync,write=write,decode=decode,normalized_nonce=normalized_nonce},
    description='v2.4：兼容背屏时间参数格式。匹配卡片显示云端标记。link只读检查最近提交，不控车。',
    providers={setup=setup,status=status,control=control,check=check,details=details,link=link}}
