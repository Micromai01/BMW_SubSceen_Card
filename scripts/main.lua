-- Queue-only bridge: cloud I/O runs in a detached worker, never in this callback.
local core=require('lib.core')
local h=core.internal
local json=require('lib.json')
local BASE='/data/adb/bmw-reareye-async-v3'
local VERSION='dd57d8bfe39c832a1e502417520c351af52fb135877fc7ebd2a457c34448acc1'
local KEY='749e3a09a331bb0c986a32ec059424d6dd97d79799d86811'
local LABELS={check='云端检查',climate='空调',lights='闪灯',horn='鸣笛',refresh='更新授权'}
local AUTH_PHASES={AUTH_EXPIRED=true,AUTH_REJECTED=true,ACCESS_DENIED=true,AUTH_UNAVAILABLE=true,AUTH_SYNC_FAILED=true}
local function quote(v) return "'"..tostring(v):gsub("'","'\\''").."'" end
local function ensure(ctx)
    local version=h.root(ctx,'if [ -f '..BASE..'/version ]; then cat '..BASE..'/version; fi')
    if version==VERSION then return true end
    if not h.install(ctx) then return false end
    local encoded=ctx:readText('worker.b64')
    if not encoded:match('^[A-Za-z0-9+/=\r\n]+$') then return false end
    local launch=ctx:readText('launch.sh')
    local scheduler=ctx:readText('scheduler.b64')
    if not scheduler:match('^[A-Za-z0-9+/=\r\n]+$') then return false end
    local boot=ctx:readText('boot.sh')
    local command='set -eu\numask 077\nmkdir -p '..BASE..'\nchmod 700 '..BASE..'\n'
        ..'base64 -d > '..BASE..'/worker.py.new <<\'BMW_WORKER_EOF\'\n'..encoded..'\nBMW_WORKER_EOF\n'
        ..'chmod 600 '..BASE..'/worker.py.new\nmv '..BASE..'/worker.py.new '..BASE..'/worker.py\n'
        ..'cat > '..BASE..'/launch.sh.new <<\'BMW_LAUNCH_EOF\'\n'..launch..'\nBMW_LAUNCH_EOF\n'
        ..'chmod 600 '..BASE..'/launch.sh.new\nmv '..BASE..'/launch.sh.new '..BASE..'/launch.sh\n'
        ..'base64 -d > '..BASE..'/scheduler.py.new <<\'BMW_SCHEDULER_EOF\'\n'..scheduler..'\nBMW_SCHEDULER_EOF\n'
        ..'chmod 600 '..BASE..'/scheduler.py.new\nmv '..BASE..'/scheduler.py.new '..BASE..'/scheduler.py\n'
        ..'cat > '..BASE..'/boot.sh.new <<\'BMW_BOOT_EOF\'\n'..boot..'\nBMW_BOOT_EOF\n'
        ..'chmod 700 '..BASE..'/boot.sh.new\nmv '..BASE..'/boot.sh.new '..BASE..'/boot.sh\n'
        ..'if [ -d /data/adb/service.d ]; then cp '..BASE..'/boot.sh /data/adb/service.d/bmw_reareye_hourly.sh; chmod 700 /data/adb/service.d/bmw_reareye_hourly.sh; fi\n'
        ..'printf %s '..quote(VERSION)..' > '..BASE..'/version\n'
    return h.root(ctx,'/system/bin/sh',command)~=nil
end
local function runtime(_,_,ctx)
    if not ensure(ctx) then return '后台安装未完成，请检查REAREye Root权限' end
    local result=h.root(ctx,'/system/bin/sh '..BASE..'/launch.sh runtime')
    if result and result:find('PYTHON_OK',1,true) then
        local started=h.root(ctx,'/system/bin/sh '..BASE..'/launch.sh scheduler')
        if started and started:find('SCHEDULER_DISABLED',1,true) then return '后台运行库=OK；整点更新已暂停' end
        if started and started:find('SCHEDULER_STARTED',1,true) then return '后台运行库=OK；整点更新已启动' end
        return '后台运行库=OK；定时器未确认启动，请运行schedule检查'
    end
    if result and result:find('RUNTIME_MISSING',1,true) then return '系统空间未找到已有Python；尚未控车' end
    return '后台运行库未通过检查；尚未控车'
end
local function dispatch(ctx,action,nonce)
    if not ensure(ctx) then return '后台安装未完成，请先运行setup' end
    local result=h.root(ctx,'/system/bin/sh '..BASE..'/launch.sh '..action..' '..nonce)
    if not result then return '任务未能启动，请检查Root' end
    if result:find('RUNTIME_MISSING',1,true) then return '未找到后台运行库，请运行runtime检查' end
    if result:find('SETSID_MISSING',1,true) then return '系统缺少后台分离工具；未控车' end
    if result:find('QUEUED',1,true) then return LABELS[action]..'已进入本机后台任务' end
    return '后台未确认接收，请运行link检查'
end
local function setup(_,_,ctx)
    local result=runtime({}, {},ctx)
    if not result:find('后台运行库=OK',1,true) then return result end
    return result..'；'..dispatch(ctx,'refresh',string.format('%.0f',ctx:now()))
end
local function cloud_check(_,_,ctx)
    return dispatch(ctx,'check',string.format('%.0f',ctx:now()))
end
local function control(params,_,ctx)
    if params.key~=KEY then return '调用未授权' end
    if params.action~='climate' and params.action~='lights' and params.action~='horn' and params.action~='refresh' then return '' end
    if tonumber(params.nonce)==0 then return '' end -- inert initialization/resume query
    local nonce=h.normalized_nonce(params.nonce)
    if not nonce then return '请求时间格式无效' end
    if math.abs(tonumber(nonce)-ctx:now())>30000 then return '旧请求已忽略，请重新点击' end
    return dispatch(ctx,params.action,nonce)
end
local function read_state(ctx)
    local raw=h.root(ctx,'if [ -f '..BASE..'/state.json ]; then head -c 4096 '..BASE..'/state.json; fi; '
        ..'printf "\\nBMW_RECEIPT\\n"; if [ -f '..BASE..'/receipt.json ]; then head -c 4096 '..BASE..'/receipt.json; fi')
    if not raw then return nil,nil,'Root状态读取失败' end
    local a,b=raw:match('^(.-)\nBMW_RECEIPT\n(.*)$')
    return a and h.decode(a), b and h.decode(b)
end
local function describe(state,receipt,ctx)
    if receipt and type(receipt.received_at)=='number' and ctx:now()/1000-receipt.received_at<15 and
        (not state or type(state.updated_at)~='number' or receipt.received_at>=state.updated_at) then
        if receipt.phase=='BUSY' then return '上一任务处理中，当前请求未发送' end
        if receipt.phase=='DUPLICATE' then return '相同请求已处理，未重复发送' end
    end
    if receipt and type(receipt.received_at)=='number' and
        (not state or type(state.updated_at)~='number' or receipt.received_at>state.updated_at) then
        if ctx:now()/1000-receipt.received_at>20 then return '后台尚未开始，请运行runtime检查' end
        return '本机任务已排队，等待后台处理'
    end
    if not state then return '请先运行setup或在更多页更新授权' end
    local label=LABELS[state.action] or '请求'
    local phase=state.phase
    if (phase=='AUTO_SYNCING' or phase=='SYNCING' or phase=='CHECKING' or phase=='CLOUD_CHECKING' or phase=='SENDING' or phase=='ACCEPTED') and
        type(state.updated_at)=='number' and ctx:now()/1000-state.updated_at>120 then
        return '后台任务未完成，结果未知；未自动重发'
    end
    local messages={AUTO_SYNCING='授权到期，正在同步本机授权',SYNCING='正在更新本机授权，请稍候',AUTH_SYNC_FAILED='授权同步未完成，请先在App刷新登录',
        CHECKING='正在检查本机授权',CLOUD_CHECKING='正在读取宝马云端车辆状态',CLOUD_OK='车况查询通过，未发送控车指令',AUTH_READY='本机授权已更新',
        CHECK_FAILED='车况查询未通过',CHECK_REQUIRED='请先更新授权，本次未控车',
        REQUEST_COOLDOWN='请求暂缓，请稍后再试',RATE_LIMITED='云端请求频繁，请稍后再试',
        RATE_STATE_UNAVAILABLE='等待状态不可用，本次未发送',BINDING_REQUIRED='请先运行setup或更新授权绑定车辆',
        BINDING_INVALID='车辆绑定记录不可用，本次未控车',ACCOUNT_CHANGED='账号与模块绑定不一致，未控车',
        ACCOUNT_UNAVAILABLE='无法确认当前账号，未控车',VEHICLE_UNAVAILABLE='无法确认唯一车辆，未控车',HOST_INVALID='官方接口配置不可用，未控车',
        AUTH_EXPIRED='授权已到期，请更新登录',AUTH_REJECTED='登录授权未通过，请更新登录',
        ACCESS_DENIED='云端授权受限，请在App中操作',AUTH_UNAVAILABLE='本机授权不可用，请在App登录',
        CONFIG_ERROR='本地云端配置不可用，请检查模块',VEHICLE_CHANGED='同步时车辆发生变化，请在App确认；未控车',BUSY='请稍后再试，未重复发送',
        SENDING='正在向宝马提交'..label,ACCEPTED=label..'已受理，等待执行结果',
        ACCEPTED_UNCONFIRMED=label..'请求已受理，结果以车辆为准',EXECUTED=label..'：服务器报告已执行',ACCEPTED_UNKNOWN=label..'已受理，结果待确认',
        UNKNOWN=label..'提交结果未知，未自动重发',REJECTED=label..'提交未确认',
        TLS_ERROR='HTTPS证书验证失败，请检查手机证书环境',
        ERROR='后台任务未完成，请检查授权和网络',FAILED=label..'未执行成功',IGNORED=label..'未执行成功'}
    local text=messages[phase] or '后台状态未知，请运行link检查'
    if AUTH_PHASES[phase] and state.app_fallback then
        local reason=phase=='ACCESS_DENIED' and '云端授权受限' or (phase=='AUTH_EXPIRED' and '授权已到期' or '授权需更新')
        local tails={OPENING='，正在请求前屏App',REQUESTED='，已请求打开前屏App',FAILED='，请手动打开前屏App',THROTTLED='，请到前屏App刷新登录'}
        text=reason..(tails[state.app_fallback] or '，请在App刷新登录')
    end
    local code=state.http_status
    if type(code)=='number' and code>=100 and code<=599 and (phase=='CHECK_FAILED' or phase=='REJECTED' or phase=='UNKNOWN') then
        text=text..'，HTTP '..string.format('%.0f',code)
    end
    return text
end
local function status(_,_,ctx)
    local state,receipt,err=read_state(ctx)
    return err or describe(state,receipt,ctx)
end
local function card_status(_,_,ctx)
    local state,receipt,err=read_state(ctx)
    if err then return err end
    if state and AUTH_PHASES[state.phase] then return describe(state,receipt,ctx) end
    local working=state and (state.phase=='AUTO_SYNCING' or state.phase=='SYNCING' or state.phase=='CHECKING' or state.phase=='CLOUD_CHECKING' or state.phase=='SENDING' or state.phase=='ACCEPTED')
    local stamp=math.max(state and tonumber(state.updated_at) or 0,receipt and tonumber(receipt.received_at) or 0)
    if not working and ctx:now()/1000-stamp>15 then return '' end
    return describe(state,receipt,ctx)
end
local function link(_,_,ctx)
    local state,receipt,err=read_state(ctx)
    if err then return err end
    local project=tostring(ctx.projectId or 'unknown')
    if not project:match('^[A-Za-z0-9_:.-]+$') then project='unknown' end
    local lines={'脚本版本=3.4','脚本项目='..project,'本机任务已接收='..(receipt and LABELS[receipt.action] and '是' or '暂无')}
    lines[#lines+1]=describe(state,receipt,ctx)
    if state and type(state.phase)=='string' and state.phase:match('^[A-Z_]+$') then lines[#lines+1]='阶段='..state.phase end
    if state and type(state.http_status)=='number' and state.http_status>=100 and state.http_status<=599 then
        lines[#lines+1]='HTTP='..string.format('%.0f',state.http_status)
    end
    local fallback={REQUESTED='已请求打开前屏App',FAILED='跳转失败，请手动打开',THROTTLED='已提示，暂不重复拉起',OPENING='正在请求跳转'}
    if state and fallback[state.app_fallback] then lines[#lines+1]=fallback[state.app_fallback] end
    return table.concat(lines,'\n')
end
local function auth_status(params,config,ctx)
    return status(params,config,ctx)
end
-- These providers read only local, sanitized cache. Opening/resuming the card never
-- installs a timer, synchronizes credentials, or sends a request to BMW.
local function local_json(ctx,name)
    local raw=h.root(ctx,'if [ -f '..BASE..'/'..name..' ]; then head -c 8192 '..BASE..'/'..name..'; fi')
    return raw and h.decode(raw)
end
local function bounded(value,maximum)
    return type(value)=='number' and value==value and value>=0 and value<=maximum
end
local function vehicle_cache(_,_,ctx)
    local data=local_json(ctx,'telemetry.json')
    local soc=data and bounded(data.soc,100) and string.format('%.0f',data.soc) or '--'
    local km=data and bounded(data.range_km,5000) and string.format('%.0f',data.range_km) or '--'
    return '电量 '..soc..'%  ·  续航 '..km..' km'
end
local function auth_info(_,_,ctx)
    local data=local_json(ctx,'auth_info.json')
    if not data then return '暂无到期记录，请在更多页更新授权；不需要上传Token' end
    local exp=bounded(data.expires_at,253402300799) and data.expires_at or 0
    local function label(value)
        if type(value)=='string' and #value<=40 and value:match('^[%d%s:+%-UTC]+$') then return value end
        return '未知'
    end
    local remaining=math.max(0,math.floor(exp-ctx:now()/1000))
    local lines={'最近检测的令牌='..(exp>ctx:now()/1000+10 and '尚未到期（以实际请求为准）' or exp>0 and '已到期／即将到期' or '无法判断'),
        '签发时间='..label(data.issued_local),'到期时间='..label(data.expires_local),
        '剩余='..math.floor(remaining/3600)..'小时'..math.floor(remaining%3600/60)..'分',
        '上次缓存同步='..label(data.synced_local)}
    if bounded(data.lifetime_seconds,253402300799) then lines[#lines+1]='令牌声明总时长='..string.format('%.2f',data.lifetime_seconds/3600)..'小时' end
    lines[#lines+1]='同步缓存不会重新计算到期时间；时区见时间末尾'
    return table.concat(lines,'\n')
end
local function vehicle_updated(_,_,ctx)
    local data=local_json(ctx,'telemetry.json')
    local stamp=data and data.updated_local
    if type(stamp)=='string' and stamp:match('^%d%d%-%d%d %d%d:%d%d$') then return stamp..' 获取' end
    if data and type(data.updated_at)=='number' then return '获取时间未知' end
    return '尚无缓存'
end
local function schedule(_,_,ctx)
    local timer=local_json(ctx,'scheduler.json')
    local cached=local_json(ctx,'telemetry.json')
    local result=local_json(ctx,'telemetry_status.json')
    local raw=h.root(ctx,'if [ -f '..BASE..'/scheduler.stop ]; then printf PAUSED; fi; if [ -f /data/adb/service.d/bmw_reareye_hourly.sh ]; then printf BOOT_HOOK; fi') or ''
    local lines={'整点更新：08:00～次日01:00；02:00～07:59暂停','打开卡片只读缓存，不发送网络请求'}
    lines[#lines+1]=raw:find('PAUSED',1,true) and '定时更新已手动暂停' or '定时更新已配置；深度休眠时可能延后或跳过'
    lines[#lines+1]=raw:find('BOOT_HOOK',1,true) and '开机启动钩子=已安装' or '开机钩子=不可用；重启后请运行runtime'
    if timer and type(timer.updated_at)=='number' then lines[#lines+1]='定时器最近心跳距今秒数='..string.format('%.0f',math.max(0,ctx:now()/1000-timer.updated_at)) end
    if cached and type(cached.updated_local)=='string' and cached.updated_local:match('^%d%d%-%d%d %d%d:%d%d$') then lines[#lines+1]='上次获取='..cached.updated_local end
    if result and type(result.phase)=='string' and result.phase:match('^[A-Z_]+$') then lines[#lines+1]='最近读取阶段='..result.phase end
    return table.concat(lines,'\n')
end
local function updates_off(_,_,ctx)
    if not h.root(ctx,'umask 077; mkdir -p '..BASE..'; touch '..BASE..'/scheduler.stop; rm -f /data/adb/service.d/bmw_reareye_hourly.sh') then return '暂停未完成，请检查Root' end
    return '整点更新已暂停；已开始的只读请求可能仍会完成，控车按钮不受影响'
end
local function updates_on(_,_,ctx)
    if not ensure(ctx) then return '后台安装未完成' end
    h.root(ctx,'rm -f '..BASE..'/scheduler.stop; if [ -d /data/adb/service.d ]; then cp '..BASE..'/boot.sh /data/adb/service.d/bmw_reareye_hourly.sh; chmod 700 /data/adb/service.d/bmw_reareye_hourly.sh; fi')
    return runtime({}, {},ctx)
end
local bootstrap=require('lib.bootstrap')
local function store_init(_,_,ctx) return bootstrap.start(ctx,h,VERSION) end
local function store_status(_,_,ctx) return bootstrap.status(ctx,h) end
return {id='bmw_i3_async_cloud',name='BMW i3 v3.5 · 云端组件',
    description='按钮读取本机新授权后单次提交；车况独立整点更新，夜间暂停；授权不可用时转前屏App。',
    providers={bootstrap=store_init,bootstrap_status=store_status,setup=setup,runtime=runtime,cloud_check=cloud_check,status=status,card_status=card_status,
        control=control,link=link,auth_status=auth_status,auth_info=auth_info,vehicle_cache=vehicle_cache,vehicle_updated=vehicle_updated,
        schedule=schedule,updates_off=updates_off,updates_on=updates_on,
        details=core.providers.details,check=core.providers.check}}
