#!/usr/bin/env python3
"""Read-only, bounded BMW appearance delivery check for Termux + Root.

Only emits allowlisted metadata. Does not open BMW account data, make requests,
send vehicle commands, modify templates/preferences, or export raw logs/configs.
"""
from pathlib import Path
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from zipfile import ZipFile, BadZipFile

FIELDS = {
    'textConfig': {'bmwDisplayName': 'BMW i3', 'bmwDisplayModel': 'eDrive35L'},
    'imageConfig': {'bmwCustomImage': ''},
    'onOffConfig': {'bmwUseCustomImage': 1},
    'seekBarSaveConfig': {'bmwCarScale': 100, 'bmwCarOffsetX': 0, 'bmwCarOffsetY': 0},
    'textSizeConfig': {'bmwNameSize': 20, 'bmwModelSize': 7},
}


def run(args, timeout=5):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout[:2_000_000]
    except (OSError, subprocess.SubprocessError):
        return -1, ''


def image_info(raw):
    out = {'selected': bool(raw)}
    if not isinstance(raw, str) or not raw or len(raw) > 4096:
        return out
    out['path_kind'] = ('host_asset' if '/reareye_card_assets/' in raw else
                        'content_uri' if raw.startswith('content:') else
                        'absolute_file' if raw.startswith('/') else 'other')
    if not raw.startswith('/'):
        return out
    p = Path(raw)
    # Only inspect an image path already selected in a BMW appearance field.
    try:
        out.update(exists=p.exists(), readable=os.access(p, os.R_OK), is_file=p.is_file())
        if p.is_file():
            out['bytes'] = p.stat().st_size
            with p.open('rb') as f:
                head = f.read(32)
            out['format'] = ('PNG' if head.startswith(b'\x89PNG\r\n\x1a\n') else
                             'JPEG' if head.startswith(b'\xff\xd8') else
                             'WEBP' if head.startswith(b'RIFF') and head[8:12] == b'WEBP' else
                             'other')
    except OSError:
        out['inspection_error'] = True
    return out


def config_summary(data):
    if not isinstance(data, dict):
        return None
    result = {}
    for map_name, allowed in FIELDS.items():
        values = data.get(map_name)
        if not isinstance(values, dict):
            continue
        for name, default in allowed.items():
            if name not in values:
                continue
            value = values[name]
            item = {'present': True, 'differs_from_default': value != default,
                    'value_type': 'boolean' if isinstance(value, bool) else 'string' if isinstance(value, str) else
                    'number' if isinstance(value, (int, float)) and not isinstance(value, bool) else 'other'}
            if map_name == 'imageConfig':
                item.update(image_info(value))
            elif isinstance(value, str):
                item['characters'] = len(value)
            elif isinstance(value, (int, float)) and not isinstance(value, bool):
                if -1000 <= value <= 1000:
                    item['number'] = value
            result[name] = item
    return result or None


def inspect_config_dir(base):
    out = {'directory_exists': base.is_dir(), 'bmw_configs': []}
    try:
        files = sorted(base.glob('*.json'))[:64]
    except OSError:
        out['readable'] = False
        return out
    out['json_files_checked'] = len(files)
    for path in files:
        try:
            if not path.is_file() or path.stat().st_size > 262144:
                continue
            cfg = config_summary(json.loads(path.read_text()))
            if cfg:
                out['bmw_configs'].append({
                    'slot': hashlib.sha256(path.name.encode()).hexdigest()[:12],
                    'modified_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(path.stat().st_mtime)),
                    'fields': cfg,
                })
        except (OSError, ValueError, TypeError):
            continue
    return out


def inspect_templates(base):
    result = []
    try:
        files = sorted(base.glob('re_*'))[:128]
    except OSError:
        return result
    for path in files:
        try:
            if not path.is_file() or path.stat().st_size > 16_000_000:
                continue
            with ZipFile(path) as archive:
                member = archive.getinfo('manifest.xml')
                if member.file_size > 262144:
                    continue
                xml = archive.read(member)
                if b'bmwVehicleTitle' not in xml:
                    continue
                root = ET.fromstring(xml)
                fields = []
                if 'var_config.xml' in archive.namelist():
                    meta = archive.getinfo('var_config.xml')
                    if meta.file_size <= 65536:
                        fields = [n.get('name') for n in ET.fromstring(archive.read(meta))
                                  if n.get('name') in {k for v in FIELDS.values() for k in v}]
                title = root.find("./Text[@name='bmwVehicleTitle']")
                hero = root.find("./Image[@name='bmwDefaultHero']")
                button = root.find("./Button[@name='main_lock']")
                image = root.find("./Image[@name='bmwCustomCar']")
                result.append({
                    'template_slot': hashlib.sha256(path.name.encode()).hexdigest()[:12],
                    'manifest_sha256': hashlib.sha256(xml).hexdigest(),
                    'schema_fields': fields,
                    'title_uses_expected_variable': title is not None and title.get('textExp') in ('@bmwDisplayName','@bmwRenderName'),
                    'uses_local_appearance_bridge': root.find("./VariableBinders/ContentProviderBinder[@name='BmwAppearance']") is not None,
                    'guarded_inputs': b'ifelse(isnull(@bmwDisplayName)' in xml,
                    'car_shifted_right': hero is not None and hero.get('x') == '0.025*#view_width',
                    'buttons_raised': button is not None and button.get('y') == '(0.720*#view_height)',
                    'image_uses_filesystem': image is not None and image.get('srcType') == 'FileSystem',
                    'contains_clock': bool(root.findall('./DateTime')),
                })
        except (OSError, ValueError, KeyError, BadZipFile, ET.ParseError):
            continue
    return result


def package_version(package):
    code, text = run(['/system/bin/dumpsys', 'package', package])
    out = {'query_ok': code == 0}
    for field in ('versionName', 'versionCode'):
        match = re.search(r'\b' + field + r'=([^\s]+)', text)
        if match:
            value = match[1][:100]
            if re.fullmatch(r'[A-Za-z0-9._+\-]+', value):
                out[field] = value
    return out


def root_probe():
    report = {'check': 'BMW_APPEARANCE_DELIVERY_V1', 'root': os.getuid() == 0,
              'read_only': True, 'timestamp_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
    if not report['root']:
        report['result'] = 'ROOT_NOT_GRANTED'
        return report
    report['reareye'] = package_version('hk.uwu.reareye')
    report['rear_host'] = package_version('com.xiaomi.subscreencenter')
    code, raw = run(['/system/bin/cmd', 'activity', 'get-current-user'])
    user = int(raw.strip()) if code == 0 and raw.strip().isdigit() else 0
    base = Path('/data/system/theme_magic/users') / str(user) / 'subscreencenter'
    report['deployed_configuration'] = inspect_config_dir(base / 'reareye_card_config')
    report['deployed_templates'] = inspect_templates(base / 'smart_assistant')
    # Filter in memory: never write or return original log text.
    code, logs = run(['/system/bin/logcat', '-d', '-t', '1500', '-v', 'brief'])
    relevant = '\n'.join(line for line in logs.splitlines()
                         if any(s in line for s in ('RearWidgetHook', 'mamlWidgetSdk', 'applyCardOneConfig', 'apply card one config')))
    flags = {
        'missing_extras': 'applyCardOneConfig missing extras',
        'oneconfig_apply_failed': 'apply card one config failed',
        'oneconfig_applied': 'applied card one config',
        'native_restore_failed': 'restore fail.',
        'host_oneconfig_failed': 'apply host one config failed',
        'host_oneconfig_succeeded': 'apply host one config success',
    }
    report['log_markers'] = {'query_ok': code == 0, 'raw_logs_exported': False,
                             **{k: s in relevant for k, s in flags.items()}}
    report['log_note'] = 'False does not prove success: debug logging may be disabled or old events evicted.'
    cfgs = report['deployed_configuration']['bmw_configs']
    changed = any(field.get('differs_from_default') for cfg in cfgs for field in cfg['fields'].values())
    report['result'] = ('CUSTOM_CONFIG_DEPLOYED_RENDERING_NEEDS_CHECK' if changed else
                        'ONLY_DEFAULT_CONFIG_DEPLOYED' if cfgs else
                        'NO_BMW_CONFIG_DEPLOYED_IN_CURRENT_USER')
    return report


def main():
    if sys.argv[1:] == ['--root-probe']:
        try:
            report = root_probe()
        except Exception as e:
            report = {'check': 'BMW_APPEARANCE_DELIVERY_V1', 'result': 'CHECK_FAILED',
                      'error_type': type(e).__name__, 'read_only': True}
        print(json.dumps(report, ensure_ascii=False))
        return
    print('只检查 BMW 外观配置是否传到背屏；不修改卡片、不联网、不读取账号授权、不控车。')
    command = shlex.join([sys.executable, str(Path(__file__).resolve()), '--root-probe'])
    code, raw = run(['su', '-c', command], timeout=35)
    try:
        report = json.loads(raw.strip()) if code == 0 else None
    except ValueError:
        report = None
    if not isinstance(report, dict) or report.get('check') != 'BMW_APPEARANCE_DELIVERY_V1':
        report = {'check': 'BMW_APPEARANCE_DELIVERY_V1', 'result': 'ROOT_CHECK_DID_NOT_RETURN',
                  'read_only': True}
    output = Path('/sdcard/Download/bmw_appearance_status.txt')
    try:
        output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    except OSError:
        output = Path.cwd() / 'bmw_appearance_status.txt'
        output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print('结果=' + report.get('result', 'UNKNOWN'))
    print('报告：' + str(output))
    print('只需反馈这份 txt，无需提供原始配置、照片或日志。')


if __name__ == '__main__':
    main()
