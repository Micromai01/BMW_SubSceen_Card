"""Validate installed component layout against the inspected store algorithm."""
from pathlib import Path
from zipfile import ZipFile
import base64
import io
import json
import re
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parent

class StoreTests(unittest.TestCase):
    def setUp(self):
        with ZipFile(ROOT/'BMW_i3_REAREye_Cloud_v3.5.zip') as z:
            self.assertIsNone(z.testzip()); self.files={n:z.read(n) for n in z.namelist()}
        self.info=json.loads(self.files['widget_info.json'])
        self.manifest=ET.fromstring(self.files['manifest.xml'])

    def test_real_cloud_archive_without_apk(self):
        for n in ['manifest.xml','scripts/main.lua','scripts/lib/core.lua','scripts/lib/bootstrap.lua','scripts/worker.b64','scripts/scheduler.b64','README.md']:
            self.assertIn(n,self.files)
        self.assertFalse(any(n.endswith(('.apk','.p12')) or n.startswith('.') for n in self.files))
        self.assertNotIn('main.lua',self.files)

    def test_metadata_automatic_card_and_postinstall(self):
        self.assertEqual(self.info['type'],'widget')
        self.assertEqual(self.info['business_setup']['id'],'bmw_i3_cloud')
        self.assertEqual(self.info['card_setup']['package'],'hk.uwu.reareye')
        self.assertEqual(self.info['postinstall']['uri'],'content://hk.uwu.reareye.script/component:{id}/bootstrap')
        self.assertEqual(self.files['widget_info.json'],(ROOT/'widget_info.json').read_bytes())

    def test_component_scripts_unpack_exactly_as_store(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)/'bmw_i3_cloud';root.mkdir()
            for n,data in self.files.items():
                index=n.replace('\\','/').find('scripts/')
                if index<0:continue
                relative=n[index+len('scripts/'):]
                self.assertNotIn('../',relative)
                p=root/relative;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
            self.assertTrue((root/'main.lua').is_file())
            for name in re.findall(r"require\('([^']+)'\)",(root/'main.lua').read_text()):
                self.assertTrue((root/(name.replace('.','/')+'.lua')).is_file(),name)

    def test_all_script_routes_match_store_component(self):
        routes=[]
        for node in self.manifest.iter():
            for value in node.attrib.values():
                if 'content://hk.uwu.reareye.script/' in value:routes.append(value)
        self.assertEqual(len(routes),7)
        self.assertTrue(all('component:bmw_i3_cloud/' in v for v in routes))
        self.assertNotIn('bootstrap',self.files['manifest.xml'].decode())
        self.assertNotIn('cloud_check',self.files['manifest.xml'].decode())

    def test_original_backend_pair_preserved(self):
        source=ROOT/'repository/inputs/BMW_i3_Cloud_AllInOne.zip'
        with ZipFile(source) as z:
            for n in ['worker.b64','scheduler.b64','reader.b64','launch.sh','sync.sh','boot.sh','lib/json.lua']:
                self.assertEqual(self.files['scripts/'+n],z.read(n),n)
            old_key=re.search(rb"local KEY='([a-f0-9]+)'",z.read('main.lua'))[1]
            self.assertIn(old_key,self.files['scripts/main.lua'])
            self.assertIn(old_key,self.files['manifest.xml'])
        for name in ['worker','scheduler']:
            compile(base64.b64decode(self.files['scripts/'+name+'.b64']),name+'.py','exec')

    def test_controls_only_trigger_explicitly_and_hints_expire(self):
        for name in ['CloudClimate','CloudLights','CloudHorn','CloudRefresh']:
            binder=self.manifest.find(".//ContentProviderBinder[@name='"+name+"']")
            self.assertEqual(binder.get('queryAtStart'),'false')
        for node in self.manifest.findall("./ExternalCommands/Trigger[@action='resume']/BinderCommand"):
            self.assertIn(node.get('name'),['CloudStatus','VehicleCache','VehicleUpdated'])
        expr=self.manifest.find(".//ContentProviderBinder[@name='CloudStatus']//VariableCommand[@name='bmwHintUntil']").get('expression')
        self.assertEqual(expr,'ifelse(eqs(@hint,@cloudStatusText),#bmwHintUntil,#time_sys+4000)')

if __name__=='__main__': unittest.main(verbosity=2)
