"""Execute the real Lua generator and generated shell in temporary directories.
No Android path, real BMW account, network call or vehicle command is executed.
"""
import ctypes as C
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import unittest
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parent
VERSION = 'a' * 64

def lua(source, names):
    lib = C.CDLL('liblua5.4.so.0')
    lib.luaL_newstate.restype = C.c_void_p
    lib.luaL_openlibs.argtypes = [C.c_void_p]
    lib.luaL_loadbufferx.argtypes = [C.c_void_p,C.c_char_p,C.c_size_t,C.c_char_p,C.c_char_p]
    lib.lua_pcallk.argtypes = [C.c_void_p,C.c_int,C.c_int,C.c_int,C.c_longlong,C.c_void_p]
    lib.lua_tolstring.argtypes = [C.c_void_p,C.c_int,C.c_void_p]; lib.lua_tolstring.restype = C.c_char_p
    lib.lua_getglobal.argtypes = [C.c_void_p,C.c_char_p]
    lib.lua_close.argtypes = [C.c_void_p]
    state = lib.luaL_newstate(); lib.luaL_openlibs(state)
    try:
        raw = source.encode()
        result = lib.luaL_loadbufferx(state,raw,len(raw),b'@store_bootstrap_test',None)
        if not result: result = lib.lua_pcallk(state,0,0,0,0,None)
        if result: raise AssertionError(lib.lua_tolstring(state,-1,None).decode())
        values = []
        for name in names:
            lib.lua_getglobal(state,name.encode())
            value = lib.lua_tolstring(state,-1,None)
            values.append(value.decode() if value else '')
        return values
    finally: lib.lua_close(state)

def generate(assets=None,reply='QUEUED'):
    with ZipFile(ROOT/'BMW_i3_REAREye_Cloud_v3.5.zip') as z:
        module = z.read('scripts/lib/bootstrap.lua').decode()
        original = {n[8:]:z.read(n).decode() for n in z.namelist() if n.startswith('scripts/') and n.endswith(('.b64','.sh'))}
    if assets is not None: original.update(assets)
    table = '{'+','.join('['+json.dumps(k)+']='+json.dumps(v,ensure_ascii=False) for k,v in original.items())+'}'
    chunk = 'local function loadModule()\n'+module+'\nend\nlocal m=loadModule()\n'
    chunk += 'local assets='+table+'\nlocal calls=0\nlocal ctx={readText=function(self,name) return assert(assets[name],name) end}\n'
    chunk += 'local h={root=function(ctx,cmd,stdin) calls=calls+1; captured=stdin or cmd; return '+json.dumps(reply)+' end}\n'
    chunk += 'job=m.job(ctx,"'+VERSION+'")\nresponse=m.start(ctx,h,"'+VERSION+'")\ncount=tostring(calls)\n'
    chunk += 'diagnostic=m.status(ctx,{root=function() return '+json.dumps(reply)+' end})\n'
    return lua(chunk,['job','captured','response','count','diagnostic'])

MOCK_LAUNCH='''#!/bin/sh
set -eu
BASE=/data/adb/bmw-reareye-async-v3
printf '%s\\n' "$1" >> "$BASE/test_calls"
case "$1" in
runtime) printf PYTHON_OK;;
scheduler) if [ -f "$BASE/scheduler.stop" ]; then printf SCHEDULER_DISABLED; else printf SCHEDULER_STARTED; fi;;
refresh) printf QUEUED;;
*) exit 97;;
esac
'''

class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.base = self.root/'async'; self.native = self.root/'native'; self.dex = self.root/'dex'; self.boot = self.root/'service.d'
        self.base.mkdir(); self.boot.mkdir()

    def mapped(self,script):
        script = script.replace('/data/adb/bmw-reareye-async-v3',str(self.base)).replace('/data/adb/bmw-reareye-native-v2',str(self.native))
        script = re.sub(r'/data/local/tmp/bmw-reareye-reader-[a-f0-9]+',str(self.dex),script)
        script = script.replace('/data/adb/service.d',str(self.boot)).replace('/system/bin/sh','/bin/sh').replace('/system/bin/timeout',shutil.which('timeout'))
        return script

    def resources(self,launch=MOCK_LAUNCH):
        return {'launch.sh':launch,'worker.b64':'Zml4dHVyZQ==','scheduler.b64':'Zml4dHVyZQ==','reader.b64':'Zml4dHVyZQ==',
                'sync.sh':'#!/bin/sh\n# local fixture\n','boot.sh':'#!/bin/sh\n# local fixture\n'}

    def run_start(self,resources=None):
        generated = generate(self.resources() if resources is None else resources)
        script = self.mapped(generated[1])
        subprocess.run(['sh','-n'],input=script,text=True,check=True)
        result = subprocess.run(['sh'],input=script,text=True,capture_output=True,timeout=5)
        self.assertEqual(result.returncode,0,result.stderr)
        return result.stdout

    def wait_phase(self,expected):
        deadline = time.monotonic()+3
        while time.monotonic()<deadline:
            phase = self.base/'store_init.phase'
            if phase.exists() and phase.read_text().strip() in expected: return phase.read_text().strip()
            time.sleep(.02)
        self.fail('expected bootstrap phase '+repr(expected))

    def test_lua_returns_fixed_text_with_one_dispatch(self):
        job,script,reply,count,_ = generate()
        self.assertEqual(count,'1'); self.assertIn('已排队',reply)
        self.assertIn("<<'BMW_STORE_BOOTSTRAP_JOB_EOF'",script)
        self.assertIn('BMW_STORE_FILE_EOF',job)
        subprocess.run(['sh','-n'],input=script,text=True,check=True)
        subprocess.run(['sh','-n'],input=job,text=True,check=True)

    def test_detached_initializer_writes_exact_runtime_and_only_refresh(self):
        self.assertEqual(self.run_start(),'QUEUED')
        self.assertEqual(self.wait_phase({'READY','FAILED'}),'READY')
        self.assertEqual((self.base/'version').read_text(),VERSION)
        self.assertEqual((self.base/'store_init.version').read_text(),VERSION)
        self.assertEqual((self.base/'worker.py').read_text(),'fixture')
        self.assertEqual((self.dex/'reader.dex').read_text(),'fixture')
        self.assertEqual((self.base/'test_calls').read_text().splitlines(),['runtime','scheduler','refresh'])
        self.assertFalse((self.base/'store-init.lock').exists())
        self.assertTrue((self.boot/'bmw_reareye_hourly.sh').exists())

    def test_repeat_install_does_not_resync(self):
        self.run_start(); self.wait_phase({'READY'})
        self.assertEqual(self.run_start(),'READY')
        self.assertEqual((self.base/'test_calls').read_text().splitlines(),['runtime','scheduler','refresh'])

    def test_pause_is_preserved_and_no_boot_hook_added(self):
        (self.base/'scheduler.stop').touch()
        self.run_start(); self.assertEqual(self.wait_phase({'READY_PAUSED','FAILED'}),'READY_PAUSED')
        self.assertTrue((self.base/'scheduler.stop').exists())
        self.assertFalse((self.boot/'bmw_reareye_hourly.sh').exists())

    def test_runtime_failure_has_cooldown_and_releases_lock(self):
        resources=self.resources(MOCK_LAUNCH.replace('printf PYTHON_OK','printf RUNTIME_MISSING'))
        self.run_start(resources); self.wait_phase({'RUNTIME_MISSING'})
        self.assertEqual(self.run_start(resources),'COOLDOWN')
        self.assertFalse((self.base/'store-init.lock').exists())
        self.assertEqual((self.base/'test_calls').read_text().splitlines(),['runtime'])

    def test_concurrent_dispatch_does_not_replace_running_job(self):
        resources=self.resources(MOCK_LAUNCH.replace('printf PYTHON_OK','sleep .25; printf PYTHON_OK'))
        self.assertEqual(self.run_start(resources),'QUEUED')
        self.assertEqual(self.run_start(resources),'BUSY')
        self.wait_phase({'READY'})

    def test_stale_empty_lock_recovered(self):
        lock=self.base/'store-init.lock';lock.mkdir(); old=time.time()-240;os.utime(lock,(old,old))
        self.assertEqual(self.run_start(),'QUEUED');self.wait_phase({'READY'})

    def test_failed_decode_is_not_reported_ready(self):
        resources=self.resources();resources['reader.b64']='A'
        self.run_start(resources);self.wait_phase({'FAILED'})
        self.assertFalse((self.base/'store_init.version').exists())
        self.assertFalse((self.base/'store-init.lock').exists())

    def test_status_whitelist_does_not_return_arbitrary_output(self):
        self.assertIn('暂无初始化记录',generate(reply='PRIVATE_TOKEN_EXAMPLE')[4])
        self.assertNotIn('PRIVATE',generate(reply='PRIVATE_TOKEN_EXAMPLE')[4])
        self.assertIn('暂停',generate(reply='READY_PAUSED')[4])

if __name__ == '__main__': unittest.main(verbosity=2)
