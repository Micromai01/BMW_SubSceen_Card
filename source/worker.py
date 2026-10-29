"""BMW v3.4: fresh local credentials, pinned vehicle, one direct command, no replay."""
import base64
import datetime
import email.utils
import fcntl
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import re
import ssl
import subprocess
import sys
import time
import urllib.parse
import uuid

BASE = Path(__file__).resolve().parent
AUTH_BASE = Path('/data/adb/bmw-reareye-native-v2')
SERVICES = {'climate': 'climate-now?action=START', 'lights': 'light-flash', 'horn': 'horn-blow'}
LABELS = {'climate': '空调', 'lights': '闪灯', 'horn': '鸣笛', 'check': '云端检查', 'refresh': '更新授权'}
TERMINAL = {'EXECUTED', 'ERROR', 'FAILED', 'IGNORED'}

LEGACY_RATE_BASE = Path("/data/adb/bmw-widget-cloud-check")
RELEASE = "3.4"

class LocalError(Exception):
    pass

def read_json(path, limit=262144):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > limit:
        return None
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError, UnicodeError):
        return None

def write_json(name, value):
    destination = BASE / name
    temp = BASE / ('.' + name + '.' + uuid.uuid4().hex)
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            json.dump(value, stream, ensure_ascii=False, allow_nan=False)
        os.replace(temp, destination)
    finally:
        temp.unlink(missing_ok=True)

def token_time(token, field):
    try:
        claim = token.split('.')[1]
        value = json.loads(base64.urlsafe_b64decode(claim + '=' * (-len(claim) % 4)))[field]
        return value if type(value) in (int, float) and 0 < value < 253402300800 and math.isfinite(value) else 0
    except (ValueError, KeyError, IndexError, TypeError):
        return 0

def expiry(token):
    return token_time(token, 'exp')

def epoch_label(stamp):
    if not stamp:
        return None
    if Path('/system/bin/date').is_file():
        try:
            env = dict(os.environ)
            env.pop('TZ', None)
            result = subprocess.run(['/system/bin/date', '-d', '@' + str(int(stamp)),
                '+%Y-%m-%d %H:%M:%S %z'], env=env, capture_output=True, text=True, timeout=2, check=False)
            value = result.stdout.strip()
            if result.returncode == 0 and re.fullmatch(r'\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}', value):
                return value
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
    try:
        return datetime.datetime.fromtimestamp(stamp, datetime.timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')
    except (OSError, ValueError, OverflowError):
        return None

def record_auth(token=None, source=None, synced_at=None):
    """Publish only time metadata, never a token, VIN, hash or decoded claims."""
    exp = expiry(token) if token else 0
    issued = token_time(token, 'iat') if token else 0
    if issued > exp:
        issued = 0
    data = {'updated_at': time.time(), 'phase': 'VALID' if exp > time.time() + 10 else 'EXPIRED' if exp else 'UNAVAILABLE',
        'expires_at': exp or None, 'issued_at': issued or None, 'source': source,
        'expires_local': epoch_label(exp), 'issued_local': epoch_label(issued),
        'synced_local': epoch_label(synced_at), 'lifetime_seconds': exp-issued if exp and issued else None}
    try:
        write_json('auth_info.json', data)
    except OSError:
        pass

def vin_from(value):
    found = set()
    def visit(obj, depth=0):
        if depth > 15:
            return
        if isinstance(obj, dict):
            for key, item in obj.items():
                if str(key).lower() in ('vin', 'vehicleidentificationnumber') and isinstance(item, str) and re.fullmatch(r'[A-HJ-NPR-Z0-9]{17}', item):
                    found.add(item)
                elif isinstance(item, (dict, list)):
                    visit(item, depth + 1)
        elif isinstance(obj, list):
            for item in obj[:1000]: visit(item, depth + 1)
    visit(value)
    return found

def open_front_app():
    """Open only the App home on display 0. Never replay a vehicle action."""
    with open(BASE / 'fallback.lock','a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        old = read_json(BASE / 'fallback.json') or {}
        now = time.time()
        if 0 <= now - float(old.get('attempted_at',0)) < 60:
            return 'THROTTLED'
        write_json('fallback.json',{'attempted_at':now,'result':'OPENING'})
        command = ['/system/bin/am','start','--user','0','--display','0',
            '-a','android.intent.action.MAIN','-c','android.intent.category.LAUNCHER',
            '-n','de.bmw.connected.mobile20.cn/com.mobileconnected.MainActivity','-f','0x14000000']
        result = 'FAILED'
        try:
            p = subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=8,check=False)
            output = (p.stdout or b'') + (p.stderr or b'')
            if p.returncode == 0 and b'Error' not in output and b'Exception' not in output:
                result = 'REQUESTED'
        except (OSError,subprocess.SubprocessError): pass
        write_json('fallback.json',{'attempted_at':now,'result':result})
        return result

def sync_local_authorization():
    """Read existing official-App cache; caller separately validates binding and intent."""
    lock = AUTH_BASE / 'sync.lock'
    try:
        lock.mkdir(mode=0o700)
    except FileExistsError:
        if time.time() - lock.stat().st_mtime > 65:
            try: lock.rmdir(); lock.mkdir(mode=0o700)
            except OSError: return False
        else: return False
    try:
        env = dict(os.environ)
        env.pop('LD_PRELOAD',None); env.pop('LD_LIBRARY_PATH',None)
        env['PATH'] = '/system/bin:/system/xbin:/data/adb/ksu/bin:/data/adb/magisk'
        p = subprocess.run(['/system/bin/sh',str(AUTH_BASE/'sync.sh')],env=env,
            stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=55,check=False)
        return p.returncode == 0 and (AUTH_BASE/'auth_state').read_text().strip() == 'SYNC_COMPLETE'
    except (OSError,subprocess.SubprocessError): return False
    finally:
        try: lock.rmdir()
        except OSError: pass

def headers(payload, token, vin=None):
    def metadata(name, pattern, default='unknown'):
        try: value = (AUTH_BASE / name).read_text().strip()
        except OSError: return default
        return value if re.fullmatch(pattern, value) else default
    build = metadata('build.txt', r'[A-Za-z0-9._-]{1,80}')
    code = metadata('version.txt', r'[0-9]{1,20}')
    correlation = str(uuid.uuid4())
    result = {'Authorization': 'Bearer ' + token, 'Accept': 'application/json', 'Accept-Language': 'zh-CN',
        'User-Agent': 'BMW-local-readonly-check/0.2', 'x-identity-provider': 'gcdm',
        'x-widget-request': 'widget', 'BMW-request-source': 'android_widget', 'BMW-Session-ID': str(uuid.uuid4()),
        'x-user-agent': f'android({build});bmw;6.9.0({code});cn', 'x-correlation-id': correlation,
        'BMW-Correlation-Id': correlation, 'x-raw-locale': 'zh-CN', '24-hour-format': 'true',
        'bmw-units-preferences': 'd=KM;v=L;p=B;ec=KWH100KM;fc=L100KM;em=GKM;'}
    if vin: result['bmw-vin'] = vin
    for source, key in [('gcid', 'x-gcid'), ('Ocp-Apim-Subscription-Key', 'Ocp-Apim-Subscription-Key')]:
        value = payload.get(source)
        if isinstance(value, str) and 0 < len(value) <= 4096 and '\r' not in value and '\n' not in value:
            result[key] = value
    return result

def fingerprints(token, vin):
    return hashlib.sha256(token.encode()).hexdigest(), hashlib.sha256(vin.encode()).hexdigest()

def has_state(obj, depth=0):
    if depth > 12: return False
    if isinstance(obj, dict):
        if any(isinstance(obj.get(key), dict) for key in ('state', 'connectedVehicleState', 'doorsState', 'electricChargingState')): return True
        return any(has_state(value, depth + 1) for value in obj.values() if isinstance(value, (dict, list)))
    if isinstance(obj, list): return any(has_state(value, depth + 1) for value in obj[:100])
    return False

def auth_error(code, obj):
    if code in (401,403): return code
    # Some gateways put the authorization error in a successful HTTP envelope.
    # A response with a real eventId remains a submitted task, never a retry cue.
    if 200 <= code < 300 and isinstance(obj,dict) and not obj.get('eventId'):
        business = obj.get('code')
        if type(business) is int and business in (401,403): return business
    return None

def telemetry_local_time():
    """Ask Android for the phone timezone; Python's root runtime may use UTC."""
    if not Path('/system/bin/date').is_file():
        return None
    try:
        env = dict(os.environ)
        env.pop('TZ', None)
        result = subprocess.run(['/system/bin/date', '+%m-%d %H:%M'],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=2, check=False)
        value = result.stdout.decode('ascii').strip()
        if result.returncode == 0 and re.fullmatch(r'[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}', value):
            return value
    except (OSError, UnicodeError, subprocess.SubprocessError):
        pass
    # Never label a guessed UTC time as the phone's local time.
    return None

def telemetry_status(phase, http_status=None):
    result = {'phase': phase, 'updated_at': time.time(), 'updated_local': telemetry_local_time()}
    if type(http_status) is int and 100 <= http_status <= 599:
        result['http_status'] = http_status
    write_json('telemetry_status.json', result)

def bounded_number(value, maximum):
    """Accept JSON numbers only, including zero; do not coerce booleans/text."""
    if type(value) not in (int, float):
        return None
    if not 0 <= value <= maximum or (isinstance(value, float) and not math.isfinite(value)):
        return None
    return value

def telemetry_range(value):
    """MyBMW has used both a scalar km value and an explicit distance model."""
    if isinstance(value, dict):
        km = bounded_number(value.get('valueKm'), 5000)
        if km is not None:
            return km
        miles = bounded_number(value.get('valueMiles'), 5000 / 1.609344)
        return miles * 1.609344 if miles is not None else None
    # bimmer_connected's state endpoint parser documents scalar range in km.
    return bounded_number(value, 5000)

def reported_time(value):
    """Keep the vehicle report timestamp distinct from our retrieval time."""
    if not isinstance(value, str) or not 1 <= len(value) <= 80:
        return None
    try:
        parsed = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
    except ValueError:
        return None
    return value if parsed.tzinfo is not None else None

def extract_telemetry(obj):
    """Use explicit state paths, never search unrelated nested vehicle numbers."""
    if not isinstance(obj, dict):
        return None
    envelopes = [obj]
    if isinstance(obj.get('data'), dict):
        envelopes.append(obj['data'])
    for envelope in envelopes:
        for key in ('state', 'connectedVehicleState'):
            state = envelope.get(key)
            if not isinstance(state, dict):
                continue
            electric = state.get('electricChargingState')
            if not isinstance(electric, dict):
                continue
            soc = bounded_number(electric.get('chargingLevelPercent'), 100)
            range_km = telemetry_range(electric.get('range'))
            if soc is not None or range_km is not None:
                return {'soc': soc, 'range_km': range_km,
                    'vehicle_reported_at': reported_time(state.get('lastFetched'))}
    return None

def select_telemetry_vehicle(vin_hash):
    """Discard a different car's cache even if the new car's GET later fails."""
    old = read_json(BASE / 'telemetry.json')
    if old is not None and (not isinstance(old, dict) or old.get('vin_hash') != vin_hash):
        (BASE / 'telemetry.json').unlink(missing_ok=True)

def cache_telemetry(obj, vin_hash):
    select_telemetry_vehicle(vin_hash)
    values = extract_telemetry(obj)
    if values is None:
        telemetry_status('DATA_UNAVAILABLE')
        return False
    # A partial response stays partial. Never relabel an older field as fresh.
    values.update(vin_hash=vin_hash, updated_at=time.time(), updated_local=telemetry_local_time())
    write_json('telemetry.json', values)
    telemetry_status('OK' if values['soc'] is not None and values['range_km'] is not None else 'PARTIAL')
    return True

def publish(action, phase, message, http_status=None, app_fallback=None, retry_not_before=None):
    state={'action':action,'phase':phase,'message':message,'updated_at':time.time(),'release':RELEASE}
    if type(http_status) is int and 100<=http_status<=599:state['http_status']=http_status
    if app_fallback in ('REQUESTED','FAILED','THROTTLED','OPENING'):state['app_fallback']=app_fallback
    if valid_time(retry_not_before):state['retry_not_before']=retry_not_before
    write_json('state.json',state)


def valid_time(value):
    return type(value) in (int,float) and 0<=value<=253402300799 and math.isfinite(value)


def official_snapshot():
    path=AUTH_BASE/'auth.raw'
    if not path.is_file() or path.is_symlink() or path.stat().st_size>262144:
        raise LocalError('AUTH_UNAVAILABLE')
    for line in path.read_text(encoding='utf-8').splitlines():
        if line.startswith('BMW_TOKEN_JSON:'):
            try:value=json.loads(line[len('BMW_TOKEN_JSON:'):])
            except ValueError:raise LocalError('AUTH_UNAVAILABLE')
            if isinstance(value,dict):return value,path.stat().st_mtime
    raise LocalError('AUTH_UNAVAILABLE')


def identity(payload):
    gcid=payload.get('gcid')
    if not isinstance(gcid,str) or not 0<len(gcid)<=4096 or '\r' in gcid or '\n' in gcid:
        raise LocalError('ACCOUNT_UNAVAILABLE')
    vin=payload.get('selected_vin')
    if not isinstance(vin,str) or not re.fullmatch(r'[A-HJ-NPR-Z0-9]{17}',vin):
        cache=payload.get('vehicle_cache',{})
        if isinstance(cache,str):
            try:cache=json.loads(cache)
            except ValueError:cache={}
        values=vin_from(cache)
        if len(values)!=1:raise LocalError('VEHICLE_UNAVAILABLE')
        vin=next(iter(values))
    return {'account_hash':hashlib.sha256(gcid.encode()).hexdigest(),
            'vin_hash':hashlib.sha256(vin.encode()).hexdigest()},vin


def binding():
    path=BASE/'binding.json'
    value=read_json(path,16384)
    if value is None:
        if path.exists() or path.is_symlink():raise LocalError('BINDING_INVALID')
        return None
    if not isinstance(value,dict) or any(not isinstance(value.get(key),str) or not re.fullmatch(r'[a-f0-9]{64}',value[key])
                                       for key in ('account_hash','vin_hash')):
        raise LocalError('BINDING_INVALID')
    return value


def check_binding(payload, create=False):
    current,vin=identity(payload)
    pinned=binding()
    if pinned is None:
        if not create:raise LocalError('BINDING_REQUIRED')
        write_json('binding.json',dict(current,created_at=time.time()))
    else:
        if pinned['account_hash']!=current['account_hash']:raise LocalError('ACCOUNT_CHANGED')
        if pinned['vin_hash']!=current['vin_hash']:raise LocalError('VEHICLE_CHANGED')
    return vin


def login():
    payload,synced_at=official_snapshot()
    _,vin=identity(payload)
    known_expiry=False
    latest_expired=None
    for key in ('nw_access_token','access_token'):
        token=payload.get(key)
        if not isinstance(token,str) or len(token)>32768 or '\r' in token or '\n' in token:continue
        token=re.sub(r'^Bearer +','',token,flags=re.I).strip()
        exp=expiry(token)
        if exp>time.time()+10:
            record_auth(token,'OFFICIAL_'+key,synced_at)
            return payload,token,vin
        if exp>0:
            known_expiry=True
            if latest_expired is None or exp>expiry(latest_expired[0]):latest_expired=(token,'OFFICIAL_'+key,synced_at)
    record_auth(*(latest_expired or (None,None,None)))
    raise LocalError('AUTH_EXPIRED' if known_expiry else 'AUTH_UNAVAILABLE')


def destination(payload):
    raw=payload.get('omc_api_host')
    if not isinstance(raw,str) or not raw:raise LocalError('HOST_INVALID')
    try:
        parsed=urllib.parse.urlsplit(raw if '://' in raw else 'https://'+raw)
        host=(parsed.hostname or '').lower()
        if (parsed.scheme!='https' or not re.fullmatch(r'[a-z0-9.-]+\.bmw\.com\.cn',host)
            or parsed.username or parsed.password or parsed.port not in (None,443)
            or parsed.query or parsed.fragment or not re.fullmatch(r'[A-Za-z0-9/_-]*',parsed.path)):
            raise ValueError()
    except ValueError:raise LocalError('HOST_INVALID')
    return host,parsed.path.rstrip('/')


def refresh_existing_authorization(action, initialize=False):
    # During explicit setup/refresh, preserve an existing legacy vehicle anchor
    # before the local reader replaces the snapshot. Never rebind automatically.
    if initialize and binding() is None:
        try:previous,_=official_snapshot()
        except LocalError:previous=None
        if previous is not None:
            try:check_binding(previous,create=True)
            except LocalError as error:
                if str(error) not in ('ACCOUNT_UNAVAILABLE','VEHICLE_UNAVAILABLE'):raise
    if action!='telemetry':publish(action,'AUTO_SYNCING','正在读取官方App当前授权')
    if not sync_local_authorization():raise LocalError('AUTH_SYNC_FAILED')
    payload,_=official_snapshot()
    check_binding(payload,create=initialize)
    payload,token,vin=login()
    destination(payload)
    write_json('auto_sync.json',{'attempted_at':time.time(),'phase':'LOCAL_AUTH_FOUND'})
    return payload,token,vin


def login_with_recovery(action):
    # Only telemetry/check may reuse a valid local snapshot. Every user control
    # explicitly reads the live official snapshot in refresh_existing_authorization.
    try:
        payload,token,vin=login()
        check_binding(payload)
        return payload,token,vin,False
    except LocalError as error:
        if str(error) not in ('AUTH_EXPIRED','AUTH_UNAVAILABLE'):raise
        payload,token,vin=refresh_existing_authorization(action)
        return payload,token,vin,True


def fail_auth(action,phase,code=None,token=None):
    if token is not None:
        write_json('blocked.json',{'token_hash':hashlib.sha256(token.encode()).hexdigest(),
                                  'scope':'controls','action':'*' if phase=='AUTH_REJECTED' else action,'phase':phase})
    messages={'AUTH_EXPIRED':'本机授权已到期或即将到期','AUTH_REJECTED':'登录授权未通过',
              'ACCESS_DENIED':'云端授权受限','AUTH_UNAVAILABLE':'本机授权不可用',
              'AUTH_SYNC_FAILED':'未能读取官方App当前授权'}
    publish(action,phase,messages.get(phase,'授权不可用'),code)
    if action in SERVICES:
        publish(action,phase,messages.get(phase,'授权不可用'),code,'OPENING')
        outcome=open_front_app()
        publish(action,phase,messages.get(phase,'授权不可用'),code,outcome)
    return 2


def control_blocked(action,token):
    old=read_json(BASE/'blocked.json')
    return (old if isinstance(old,dict) and old.get('scope')=='controls'
            and old.get('token_hash')==hashlib.sha256(token.encode()).hexdigest()
            and old.get('action') in ('*',action) else None)


def retry_after_seconds(value,date_value=None,now=None):
    now=time.time() if now is None else now
    if not isinstance(value,str) or len(value)>128:return None
    value=value.strip()
    if re.fullmatch(r'[0-9]{1,10}',value):
        delay=int(value)
        return delay if delay<=3153600000 else None
    try:
        target=email.utils.parsedate_to_datetime(value)
        if target.tzinfo is None:return None
        reference=now
        if isinstance(date_value,str) and len(date_value)<=128:
            try:
                server=email.utils.parsedate_to_datetime(date_value)
                if server.tzinfo is not None:reference=server.timestamp()
            except (ValueError,TypeError,OverflowError):pass
        delay=max(0,int(target.timestamp()-reference+0.999))
        return delay if delay<=3153600000 else None
    except (ValueError,TypeError,OverflowError):return None


def request(host,method,path,request_headers,body=None,timeout=15,metadata=None):
    connection=http.client.HTTPSConnection(host,443,timeout=timeout,context=ssl.create_default_context())
    try:
        connection.request(method,path,body=body,headers=request_headers)
        response=connection.getresponse()
        raw=response.read(262145)
        if metadata is not None:
            metadata['retry_after_seconds']=retry_after_seconds(response.getheader('Retry-After'),response.getheader('Date'))
        try:obj=json.loads(raw) if len(raw)<=262144 else None
        except (ValueError,UnicodeError):obj=None
        return response.status,obj
    finally:connection.close()


def rate_state():
    value=read_json(BASE/'rate_limit.json')
    if value is None:
        if (BASE/'rate_limit.json').exists() or (BASE/'rate_limit.json').is_symlink():raise LocalError('RATE_STATE_UNAVAILABLE')
        return {'retry_not_before':0,'strikes':0}
    if (not isinstance(value,dict) or not valid_time(value.get('retry_not_before'))
        or type(value.get('strikes')) is not int or not 0<=value['strikes']<=20):
        raise LocalError('RATE_STATE_UNAVAILABLE')
    return value


def rate_deadline():
    deadline=rate_state()['retry_not_before']
    path=LEGACY_RATE_BASE/'cooldown.json'
    legacy=read_json(path,16384)
    if legacy is None:
        if path.exists() or path.is_symlink():raise LocalError('RATE_STATE_UNAVAILABLE')
    elif not isinstance(legacy,dict) or not valid_time(legacy.get('retry_not_before')):
        raise LocalError('RATE_STATE_UNAVAILABLE')
    else:deadline=max(deadline,legacy['retry_not_before'])
    return deadline


def is_limited(code,obj):
    return code==429 or (code==200 and isinstance(obj,dict) and type(obj.get('code')) is int and obj['code']==429)


def note_response(code,obj,metadata):
    previous=rate_state()
    limited=is_limited(code,obj)
    delay=metadata.get('retry_after_seconds')
    strikes=min(20,max(0,previous['strikes'])+1) if limited else 0
    local=min(1800,30*2**min(strikes-1,6)) if limited else 0
    wait=max(local,delay or 0)
    deadline=max(previous['retry_not_before'],time.time()+wait) if wait else 0
    write_json('rate_limit.json',{'retry_not_before':deadline,'strikes':strikes,
                                'last_http_status':code,'updated_at':time.time()})
    return deadline


def local_failure(action,error):
    phase=str(error)
    if action in SERVICES and phase in ('ACCOUNT_UNAVAILABLE','VEHICLE_UNAVAILABLE'):
        return fail_auth(action,'AUTH_UNAVAILABLE')
    if phase in ('AUTH_EXPIRED','AUTH_REJECTED','ACCESS_DENIED','AUTH_UNAVAILABLE','AUTH_SYNC_FAILED'):
        return fail_auth(action,phase)
    messages={'BINDING_REQUIRED':'请先运行setup或在更多页更新授权，建立车辆绑定',
              'BINDING_INVALID':'车辆绑定记录不可用，本次未控车',
              'ACCOUNT_UNAVAILABLE':'无法确认当前账号，本次未控车',
              'VEHICLE_UNAVAILABLE':'无法确认唯一车辆，本次未控车',
              'ACCOUNT_CHANGED':'账号与模块绑定不一致，本次未控车',
              'VEHICLE_CHANGED':'车辆与模块绑定不一致，本次未控车',
              'RATE_STATE_UNAVAILABLE':'等待状态不可用，本次未发送请求',
              'HOST_INVALID':'官方App的接口配置不可用，本次未控车'}
    publish(action,phase if phase in messages else 'CONFIG_ERROR',messages.get(phase,'本地配置不可用，本次未控车'))
    return 2


def run_telemetry():
    BASE.mkdir(mode=0o700,exist_ok=True)
    try:
        with open(BASE/'job.lock','a') as lock:
            try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError:telemetry_status('BUSY');return 0
            if rate_deadline()>time.time():telemetry_status('REQUEST_COOLDOWN');return 2
            payload,token,vin,_=login_with_recovery('telemetry')
            check_binding(payload)
            _,vin_hash=fingerprints(token,vin)
            select_telemetry_vehicle(vin_hash)
            host,prefix=destination(payload)
            meta={}
            code,obj=request(host,'GET',prefix+'/eadrax-vcs/v4/vehicles/state',headers(payload,token,vin),metadata=meta)
            note_response(code,obj,meta)
            if is_limited(code,obj):telemetry_status('RATE_LIMITED',code);return 2
            rejected=auth_error(code,obj)
            if rejected:
                telemetry_status('AUTH_REJECTED' if rejected==401 else 'ACCESS_DENIED',code)
                return 2  # state endpoint rejection never poisons control authorization
            if (code!=200 or not isinstance(obj,dict) or not has_state(obj)
                or type(obj.get('code')) is int and 400<=obj['code']<=599):
                telemetry_status('HTTP_ERROR' if code!=200 else 'DATA_UNAVAILABLE',code);return 2
            vins=vin_from(obj)
            if vins and vins!={vin}:telemetry_status('VEHICLE_MISMATCH');return 2
            return 0 if cache_telemetry(obj,vin_hash) else 2
    except LocalError as error:telemetry_status(str(error))
    except ssl.SSLCertVerificationError:telemetry_status('TLS_ERROR')
    except (OSError,ValueError,TypeError,http.client.HTTPException):telemetry_status('NETWORK_ERROR')
    except Exception:telemetry_status('ERROR')
    return 2


def run(action,nonce):
    if action not in {*SERVICES,'check','refresh'} or not re.fullmatch(r'[0-9]{13,16}',nonce):return 2
    now=time.time()
    if abs(int(nonce)/1000-now)>35:return 2
    BASE.mkdir(mode=0o700,exist_ok=True)
    with open(BASE/'job.lock','a') as lock:
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:
            write_json('receipt.json',{'action':action,'received_at':now,'phase':'BUSY'});return 2
        seen=read_json(BASE/'seen.json',16384) or []
        if not isinstance(seen,list):raise LocalError('CONFIG_ERROR')
        if nonce in seen:
            write_json('receipt.json',{'action':action,'received_at':now,'phase':'DUPLICATE'});return 0
        write_json('seen.json',(seen+[nonce])[-128:])
        try:
            if action=='refresh':
                refresh_existing_authorization(action,initialize=True)
                publish(action,'AUTH_READY','本机授权已更新；等待实际操作验证')
                return 0
            until=rate_deadline()
            if until>time.time():
                publish(action,'REQUEST_COOLDOWN','请求暂缓，请稍后再试',retry_not_before=until);return 2
            if action in SERVICES:
                payload,token,vin=refresh_existing_authorization(action)
            else:
                payload,token,vin,_=login_with_recovery(action)
                check_binding(payload)
            host,prefix=destination(payload)
            h=headers(payload,token,vin)
            if action=='check':
                publish(action,'CLOUD_CHECKING','正在查询云端车况')
                meta={}
                code,obj=request(host,'GET',prefix+'/eadrax-vcs/v4/vehicles/state',h,metadata=meta)
                until=note_response(code,obj,meta)
                if is_limited(code,obj):publish(action,'RATE_LIMITED','车况查询受限，未判断控车权限',code,retry_not_before=until);return 2
                rejected=auth_error(code,obj)
                if rejected:
                    publish(action,'CHECK_FAILED','车况查询授权未通过，未判断控车权限',code);return 2
                if (code!=200 or not isinstance(obj,dict) or not has_state(obj)
                    or type(obj.get('code')) is int and 400<=obj['code']<=599):
                    publish(action,'CHECK_FAILED','车况查询未通过',code);return 2
                vins=vin_from(obj)
                if vins and vins!={vin}:publish(action,'CHECK_FAILED','返回车辆不一致');return 2
                cache_telemetry(obj,fingerprints(token,vin)[1])
                publish(action,'CLOUD_OK','车况查询通过，未发送控车指令',code);return 0
            blocked=control_blocked(action,token)
            if blocked:
                phase=blocked.get('phase')
                return fail_auth(action,phase if phase in ('AUTH_REJECTED','ACCESS_DENIED') else 'AUTH_REJECTED')
            previous=read_json(BASE/'event.json')
            if isinstance(previous,dict) and valid_time(previous.get('created_at')) and 0<=time.time()-previous['created_at']<30:
                publish(action,'BUSY','上一请求刚提交，本次未重复发送');return 2
            # The live reader may take time. Recheck any shared cooldown before
            # the one control call; no worker waits and sends it later.
            until=rate_deadline()
            if until>time.time():publish(action,'REQUEST_COOLDOWN','请求暂缓，请稍后再试',retry_not_before=until);return 2
            event={'action':action,'created_at':time.time(),'phase':'SENDING','vin':vin}
            write_json('event.json',event)
            publish(action,'SENDING','正在提交'+LABELS[action])
            h['Content-Type']='application/json'
            meta={}
            try:
                code,obj=request(host,'POST',prefix+'/eadrax-vrccs/v4/presentation/remote-commands/'+SERVICES[action],h,b'{}',metadata=meta)
            except (OSError,ValueError,http.client.HTTPException):
                event['phase']='UNKNOWN';write_json('event.json',event)
                publish(action,'UNKNOWN',LABELS[action]+'提交结果未知，未自动重发');return 2
            until=note_response(code,obj,meta)
            if is_limited(code,obj):
                event['phase']='RATE_LIMITED';write_json('event.json',event)
                publish(action,'RATE_LIMITED','云端请求频繁，请稍后再试',code,retry_not_before=until);return 2
            rejected=auth_error(code,obj)
            if rejected:
                phase='AUTH_REJECTED' if rejected==401 else 'ACCESS_DENIED'
                event['phase']=phase;write_json('event.json',event)
                return fail_auth(action,phase,rejected,token)
            if not 200<=code<300:
                event['phase']='UNKNOWN' if code>=500 else 'REJECTED';write_json('event.json',event)
                publish(action,event['phase'],LABELS[action]+'提交未确认',code);return 2
            ref=obj.get('eventId') if isinstance(obj,dict) else None
            if not isinstance(ref,str) or not 0<len(ref)<=512 or '\r' in ref or '\n' in ref:
                event['phase']='UNKNOWN';write_json('event.json',event)
                publish(action,'UNKNOWN',LABELS[action]+'提交结果未确认，未自动重发',code);return 2
            event['phase']='ACCEPTED_UNCONFIRMED'
            event['event_id']=ref
            write_json('event.json',event)
            publish(action,'ACCEPTED_UNCONFIRMED',LABELS[action]+'请求已受理，结果以车辆为准',code)
            # No event-status polling or automatic retry. A new manual click is
            # a new intent, still subject to nonce, lock, cooldown and binding.
            return 0
        except LocalError as error:return local_failure(action,error)


def entry(argv):
    os.umask(0o077)
    if argv==['telemetry']:return run_telemetry()
    if len(argv)!=2 or argv[0] not in {*SERVICES,'check','refresh'}:return 2
    action,nonce=argv
    try:return run(action,nonce)
    except LocalError as error:return local_failure(action,error)
    except ssl.SSLCertVerificationError:publish(action,'TLS_ERROR','HTTPS证书校验失败')
    except (OSError,ValueError,TypeError,http.client.HTTPException):publish(action,'ERROR','后台请求未完成，未自动重发')
    except Exception:publish(action,'ERROR','后台处理异常，未自动重发')
    return 2


if __name__=='__main__':raise SystemExit(entry(sys.argv[1:]))
