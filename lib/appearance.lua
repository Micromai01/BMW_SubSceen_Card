-- Read only the deployed BMW appearance maps. No worker install, credentials,
-- network, vehicle binding, template writes, or vehicle actions in this module.
local json=require('lib.json')
local M={}
local probe=[=[
user=$(/system/bin/cmd activity get-current-user 2>/dev/null)
case "$user" in ''|*[!0-9]*) user=0;; esac
base=/data/system/theme_magic/users/$user/subscreencenter/reareye_card_config
[ -d "$base" ] || exit 0
count=0
total=0
for path in "$base"/*.json; do
    [ -f "$path" ] && [ -r "$path" ] || continue
    key=${path##*/}
    case "$key" in *[!a-zA-Z0-9._-]*) continue;; esac
    count=$((count+1))
    [ "$count" -le 64 ] || break
    metadata=$(stat -c '%s %Y %y' "$path" 2>/dev/null)
    size=${metadata%% *}
    case "$size" in ''|*[!0-9]*) continue;; esac
    [ "$size" -le 8192 ] || continue
    grep -q '"bmwDisplayName"' "$path" || continue
    total=$((total+size))
    [ "$total" -le 49152 ] || break
    digest=$(printf %s "$key" | sha256sum)
    digest=${digest%% *}
    metadata=${metadata#* }
    stamp=${metadata%% *}
    precise=${metadata#* }
    case "$stamp" in ''|*[!0-9]*) continue;; esac
    printf '\nBMW_APPEARANCE %s %s %s\n' "$digest" "$stamp" "$precise"
    head -c 8192 "$path"
    printf '\nBMW_APPEARANCE_END\n'
done
]=]

local function text(value,fallback,limit)
    if type(value)~='string' or #value>limit then return fallback end
    return (value:gsub('[%z\1-\31\127]',' '))
end
local function number(value,fallback,lo,hi)
    if type(value)~='number' or value~=value or value==math.huge or value==-math.huge then return fallback end
    return math.max(lo,math.min(hi,math.floor(value)))
end
local function map(data,name)
    return type(data[name])=='table' and data[name] or {}
end
local function normalized(data)
    if type(data)~='table' then return nil end
    local words=map(data,'textConfig')
    -- Exact BMW field keys, not a filename guess or any other card's text.
    if type(words.bmwDisplayName)~='string' then return nil end
    local images=map(data,'imageConfig')
    local toggles=map(data,'onOffConfig')
    local sliders=map(data,'seekBarSaveConfig')
    local sizes=map(data,'textSizeConfig')
    local image=text(images.bmwCustomImage,'',1024)
    if image~='' and not image:match('^/data/system/theme_magic/users/%d+/subscreencenter/reareye_card_assets/[%w_./%-]+$') then image='' end
    if image:find('/../',1,true) or image:match('/%.%.$') then image='' end
    local enabled=toggles.bmwUseCustomImage
    -- Current OneConfig stores this as a JSON Boolean, older versions may use 0/1.
    enabled=(enabled==nil or enabled==json.null or enabled==true or enabled==1) and 1 or 0
    return {ok=1,name=text(words.bmwDisplayName,'BMW i3',128),model=text(words.bmwDisplayModel,'eDrive35L',160),
        image=image,use_image=enabled,scale=number(sliders.bmwCarScale,100,60,150),
        offset_x=number(sliders.bmwCarOffsetX,0,-100,100),offset_y=number(sliders.bmwCarOffsetY,0,-100,100),
        name_size=number(sizes.bmwNameSize,20,12,24),model_size=number(sizes.bmwModelSize,7,6,10)}
end
local function read(ctx)
    local ok,result=pcall(function() return ctx.root:exec('/system/bin/sh',{stdin=probe,timeoutMillis=1800}) end)
    if not ok or not result or result.timedOut or result.outputLimitExceeded or result.exitCode~=0 then return nil,'READ_FAILED' end
    local raw=result.stdout or ''
    if #raw>65536 then return nil,'OUTPUT_LIMIT' end
    local rows={}
    for digest,seconds,precise,body in raw:gmatch('\nBMW_APPEARANCE (%x+) (%d+) ([^\n]*)\n(.-)\nBMW_APPEARANCE_END\n') do
        if #digest==64 and #body<=8192 then
            local decoded,data=pcall(json.decode,body)
            local values=decoded and normalized(data)
            if values then
                rows[#rows+1]={source=digest:sub(1,12),seconds=tonumber(seconds),
                    fraction=tonumber('0.'..(precise:match('%.(%d+)') or '0')),values=values}
            end
        end
    end
    table.sort(rows,function(a,b)
        if a.seconds~=b.seconds then return a.seconds>b.seconds end
        if a.fraction~=b.fraction then return a.fraction>b.fraction end
        return a.source<b.source
    end)
    return rows
end
local function select(rows,config)
    local selected=config and config.appearance_source or ''
    if type(selected)~='string' then return nil,'INVALID_SOURCE' end
    selected=selected:match('^%s*(.-)%s*$'):lower()
    if selected~='' then
        if #selected~=12 or not selected:match('^%x+$') then return nil,'INVALID_SOURCE' end
        local found=nil
        for _,row in ipairs(rows) do
            if row.source==selected then
                if found then return nil,'SOURCE_COLLISION' end
                found=row
            end
        end
        return found,found and 'FIXED_SOURCE' or 'SOURCE_MISSING'
    end
    if #rows==0 then return nil,'NO_BMW_CONFIG' end
    -- Never silently resolve equal newest mtimes to an arbitrary profile.
    if #rows>1 and rows[1].seconds==rows[2].seconds and rows[1].fraction==rows[2].fraction then
        return nil,'NEWEST_SOURCE_AMBIGUOUS'
    end
    return rows[1],'LATEST_SAVED'
end
function M.payload(_,config,ctx)
    local rows,reason=read(ctx)
    if not rows then return json.encode({ok=0,reason=reason}) end
    local chosen,selection=select(rows,config)
    if not chosen then return json.encode({ok=0,reason=selection,count=#rows}) end
    chosen.values.source=chosen.source
    chosen.values.selection=selection
    return json.encode(chosen.values)
end
function M.status(_,config,ctx)
    local rows,reason=read(ctx)
    if not rows then return '外观读取未完成：'..reason end
    local chosen,selection=select(rows,config)
    if not chosen then return 'BMW外观配置份数='..#rows..'；尚未选定：'..selection end
    return '本地外观读取=OK\n配置编号='..chosen.source..'\n来源='..selection
        ..'\nBMW外观配置份数='..#rows..'\n自定义图片='..(chosen.values.image~='' and '已选择' or '未选择')
        ..'\n仅外观配置；不改变实际控车车辆'
end
function M.sources(_,_,ctx)
    local rows,reason=read(ctx)
    if not rows then return '外观读取未完成：'..reason end
    local lines={'外观编号（仅在本机展示名称；可填入脚本设置的固定外观配置编号）：'}
    for _,row in ipairs(rows) do
        lines[#lines+1]=row.source..'  '..row.values.name..' / '..row.values.model
    end
    if #rows==0 then lines[#lines+1]='没有已部署的BMW外观，请先在普通卡片模板配置中保存。' end
    return table.concat(lines,'\n')
end
M.configs={{id='appearance_source',name='固定外观配置编号（可选）',type='STRING',defaultValue='',
    note='留空使用最近保存的BMW外观，同一脚本项目共用。多份配置时可运行appearance_sources，复制12位编号固定来源；不改变控车车辆。'}}
return M
