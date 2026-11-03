-- Small bounded JSON codec. UTF-8 Lua source, compatible with Lua 5.1/LuaJIT.
local M = {}
local null = {}; M.null = null
local function utf8(cp)
    if cp < 128 then return string.char(cp) end
    if cp < 2048 then return string.char(192+math.floor(cp/64),128+cp%64) end
    if cp < 65536 then return string.char(224+math.floor(cp/4096),128+math.floor(cp/64)%64,128+cp%64) end
    return string.char(240+math.floor(cp/262144),128+math.floor(cp/4096)%64,128+math.floor(cp/64)%64,128+cp%64)
end
function M.decode(s)
    assert(type(s)=='string' and #s <= 262144, 'JSON size')
    local i, count = 1, 0
    local function space()
        while s:sub(i,i):match('[ \n\r\t]') do i=i+1 end
    end
    local function str()
        assert(s:sub(i,i)=='"', 'JSON string'); i=i+1
        local result = {}
        while i<=#s do
            local c=s:sub(i,i); i=i+1
            if c=='"' then return table.concat(result) end
            if c=='\\' then
                local e=s:sub(i,i); i=i+1
                local escapes={['"']='"',['\\']='\\',['/']='/',b='\b',f='\f',n='\n',r='\r',t='\t'}
                if e=='u' then
                    local hex=s:sub(i,i+3); assert(#hex==4 and hex:match('^%x+$'),'JSON unicode')
                    local cp=tonumber(hex,16); i=i+4
                    if cp>=0xD800 and cp<=0xDBFF then
                        assert(s:sub(i,i+1)=='\\u','JSON surrogate'); i=i+2
                        hex=s:sub(i,i+3); assert(#hex==4 and hex:match('^%x+$'),'JSON unicode')
                        local low=tonumber(hex,16); i=i+4
                        assert(low>=0xDC00 and low<=0xDFFF,'JSON surrogate')
                        cp=0x10000+(cp-0xD800)*1024+low-0xDC00
                    else assert(cp<0xDC00 or cp>0xDFFF,'JSON surrogate') end
                    result[#result+1]=utf8(cp)
                else assert(escapes[e],'JSON escape'); result[#result+1]=escapes[e] end
            else assert(c:byte()>=32,'JSON control'); result[#result+1]=c end
        end
        error('JSON unterminated')
    end
    local value
    value=function(depth)
        assert(depth<=24,'JSON depth'); count=count+1; assert(count<=10000,'JSON elements'); space()
        local c=s:sub(i,i)
        if c=='"' then return str() end
        if c=='{' or c=='[' then
            local object=c=='{'; local close=object and '}' or ']'; i=i+1; space()
            local t={}; if s:sub(i,i)==close then i=i+1; return t end
            while true do
                local key
                if object then space(); key=str(); space(); assert(s:sub(i,i)==':','JSON colon'); i=i+1 end
                local v=value(depth+1)
                if object then t[key]=v else t[#t+1]=v end
                space(); c=s:sub(i,i); i=i+1
                if c==close then return t end
                assert(c==',','JSON comma')
            end
        end
        for literal,v in pairs({['true']=true,['false']=false,['null']=null}) do
            if s:sub(i,i+#literal-1)==literal then i=i+#literal; return v end
        end
        local start=i
        if s:sub(i,i)=='-' then i=i+1 end
        if s:sub(i,i)=='0' then i=i+1 else
            assert(s:sub(i,i):match('[1-9]'),'JSON number')
            repeat i=i+1 until not s:sub(i,i):match('%d')
        end
        if s:sub(i,i)=='.' then
            i=i+1; assert(s:sub(i,i):match('%d'),'JSON number')
            repeat i=i+1 until not s:sub(i,i):match('%d')
        end
        if s:sub(i,i):match('[eE]') then
            i=i+1; if s:sub(i,i):match('[+-]') then i=i+1 end
            assert(s:sub(i,i):match('%d'),'JSON exponent')
            repeat i=i+1 until not s:sub(i,i):match('%d')
        end
        local n=tonumber(s:sub(start,i-1)); assert(n and n==n and n~=math.huge and n~=-math.huge,'JSON finite')
        return n
    end
    local result=value(0); space(); assert(i>#s,'JSON trailing'); return result
end
local function quoted(s)
    return '"'..s:gsub('[%z\1-\31\\"]',function(c)
        local map={['"']='\\"',['\\']='\\\\',['\n']='\\n',['\r']='\\r',['\t']='\\t'}
        return map[c] or string.format('\\u%04x',c:byte())
    end)..'"'
end
function M.encode(v, depth)
    depth=depth or 0; assert(depth<=24,'JSON depth')
    if v==null or v==nil then return 'null' end
    if type(v)=='string' then return quoted(v) end
    if type(v)=='boolean' then return tostring(v) end
    if type(v)=='number' then assert(v==v and v~=math.huge and v~=-math.huge,'JSON finite'); return tostring(v) end
    assert(type(v)=='table','JSON type')
    local fields={}
    for k,item in pairs(v) do
        assert(type(k)=='string','JSON object keys')
        fields[#fields+1]=quoted(k)..':'..M.encode(item,depth+1)
    end
    table.sort(fields); return '{'..table.concat(fields,',')..'}'
end
return M
