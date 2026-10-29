"""Build the real REARStore ZIP plus upload-ready repository tree; no APK."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
import argparse, base64, hashlib, json, re, shutil, xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT.parent / 'bmw-reareye-cloud-v3_4/BMW_i3_Cloud_AllInOne.zip'
if not SOURCE.exists(): SOURCE = ROOT / 'inputs/BMW_i3_Cloud_AllInOne.zip'
DEFAULT_ID = 'bmw_i3_cloud'

def build(store_id=DEFAULT_ID):
    if not re.fullmatch(r'[a-z0-9_-]+', store_id): raise ValueError('lowercase store id required')
    with ZipFile(SOURCE) as z: old = {n: z.read(n) for n in z.namelist()}
    core = old['lib/core.lua'].decode()
    revision = re.search(r"local REVISION = '([a-f0-9]{64})'", core)[1]
    dex_path = re.search(r"local DEX_PATH = '([^']+)'", core)[1]
    bootstrap = (ROOT / 'bootstrap.lua').read_text().replace('__REVISION__', revision).replace('__DEX_PATH__', dex_path)
    main = old['main.lua'].decode()
    old_version = re.search(r"local VERSION='([a-f0-9]{64})'", main)[1]
    version = hashlib.sha256(old['main.lua'] + bootstrap.encode()).hexdigest()
    main = main.replace(old_version, version)
    main = main.replace("name='BMW i3 v3.4 · 后台授权接续'", "name='BMW i3 v3.5 · 云端组件'")
    marker = "return {id='bmw_i3_async_cloud'"
    assert marker in main
    main = main.replace(marker, "local bootstrap=require('lib.bootstrap')\n"
        "local function store_init(_,_,ctx) return bootstrap.start(ctx,h,VERSION) end\n"
        "local function store_status(_,_,ctx) return bootstrap.status(ctx,h) end\n" + marker)
    main = main.replace('providers={setup=setup,', 'providers={bootstrap=store_init,bootstrap_status=store_status,setup=setup,')
    old_base = 'content://hk.uwu.reareye.script/BMW_i3_Cloud_AllInOne/'
    base = 'content://hk.uwu.reareye.script/component:' + store_id + '/'
    manifest = old['manifest.xml'].decode()
    assert manifest.count(old_base) == 7
    manifest = manifest.replace(old_base, base)
    ET.fromstring(manifest)
    info = {'type': 'widget', 'name': 'BMW i3 车控',
        'business_setup': {'id': store_id, 'renameable': False},
        'card_setup': {'name': 'BMW i3 车控', 'package': 'hk.uwu.reareye',
                       'priority': 500, 'sticky': True, 'renameable': False},
        'requirements': {'packages': ['de.bmw.connected.mobile20.cn']},
        'postinstall': {'uri': 'content://hk.uwu.reareye.script/component:{id}/bootstrap'}}
    # Metadata is also checked into the repository root for store ingestion.
    metadata = (json.dumps(info, ensure_ascii=False, indent=2) + '\n').encode()
    files = {'manifest.xml': manifest.encode(), 'widget_info.json': metadata,
             'scripts/main.lua': main.encode(), 'scripts/lib/bootstrap.lua': bootstrap.encode()}
    for n, data in old.items():
        if n.endswith('.png') or n.startswith('strings/'): files[n] = data
        elif n in ['lib/core.lua','lib/json.lua','sync.sh','launch.sh','boot.sh','worker.b64','scheduler.b64','reader.b64']:
            files['scripts/' + n] = data
    # Correct a stale historical header; no runtime code changes in the helper.
    files['scripts/lib/core.lua'] = files['scripts/lib/core.lua'].replace(
        b'-- REAREye native Root + HTTP only. No Python, Termux runtime or background receiver.',
        b'-- Local authorization helper. The v3.5 bridge uses an existing Termux Python worker.')
    for n in ['README.md','技术交接.md','上架说明.md','store_contract.md','验证记录.json']:
        if (ROOT / n).is_file():
            files[n] = (ROOT / n).read_text().replace(DEFAULT_ID,store_id).encode()
    tree = ROOT / 'repository'
    if tree.exists(): shutil.rmtree(tree)
    tree.mkdir()
    for n, data in files.items():
        p = tree / n; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(data)
    # A source tree needs its real builder/test inputs, not the earlier APK build.
    for n in ['build_store.py','bootstrap.lua','test_store.py','test_bootstrap.py']:
        if (ROOT / n).is_file(): shutil.copy2(ROOT / n, tree / n)
    inputs = tree / 'inputs'; inputs.mkdir()
    shutil.copy2(SOURCE, inputs / 'BMW_i3_Cloud_AllInOne.zip')
    readable = tree / 'source'; readable.mkdir()
    for name in ['worker','scheduler']:
        (readable / (name+'.py')).write_bytes(base64.b64decode(old[name+'.b64'],validate=True))
    (tree / '.gitignore').write_text('__pycache__/\n*.pyc\n.signing/\n/repository/\n/BMW_*.zip\n/SHA256SUMS.txt\n')
    (ROOT / 'widget_info.json').write_bytes(metadata)
    output = ROOT / 'BMW_i3_REAREye_Cloud_v3.5.zip'
    with ZipFile(output, 'w', ZIP_DEFLATED) as z:
        for n, data in files.items(): z.writestr(n, data)
    repo_zip = ROOT / 'BMW_SubSceen_Card_Repository_Update.zip'
    with ZipFile(repo_zip, 'w', ZIP_DEFLATED) as z:
        for p in tree.rglob('*'):
            if p.is_file(): z.write(p, p.relative_to(tree).as_posix())
    return output, repo_zip

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--store-id', default=DEFAULT_ID)
    args = parser.parse_args()
    for p in build(args.store_id): print(p.name, p.stat().st_size, 'bytes')
