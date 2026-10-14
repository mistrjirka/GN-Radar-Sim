"""Regression tests for the game integration (no running Godot required).

Run: python -m unittest discover -s game/radar/tests -v
The approved valley seed is cached after its first generation (~20 seconds).
"""
from pathlib import Path
import sys, copy, hashlib, tempfile, unittest, json
import numpy as np
from PIL import Image
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'backend'))
from scene_world import load_scene,native_models_world,export_scene,ARRAY_FIELDS
from worker import render,png_diff,request_config,FIXTURE
from model_library import vehicle,radar

class IntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.world=load_scene(ROOT/'backend'/'cache',42,'valley')
        cls.native=native_models_world(cls.world)
        cls.temp=tempfile.TemporaryDirectory(prefix='radar-integration-test-')
        cls.path=Path(cls.temp.name)
    @classmethod
    def tearDownClass(cls):cls.temp.cleanup()

    def test_01_reference_source_unchanged(self):
        digest=hashlib.sha256((ROOT/'backend/vendor/gemini_v65.py').read_bytes()).hexdigest()
        self.assertEqual(digest,'4b06e1b8dd00d45db3fef2491d27c07b39d6ade3e16bc48d585e108750ca96d1')

    def test_02_six_launchers_and_radar(self):
        launchers=[e for e in self.native._entities if e['kind']=='vehicle' and e['y']<0]
        self.assertEqual(len(launchers),6)
        self.assertEqual(len([e for e in self.native._entities if e['kind']=='radar']),1)
        self.assertEqual(len([e for e in self.native._entities if e['kind']=='warehouse']),3)

    def test_03_original_model_design(self):
        parts=vehicle()
        canisters=[p for p in parts if p['material']=='metal_dark' and p.get('size')==[14,1.15,1.45]]
        tires=[p for p in parts if p['material']=='tires']
        self.assertEqual(len(canisters),4)
        self.assertEqual(len(tires),4)
        self.assertEqual(parts[0]['size'],[25,8,3.3])
        self.assertEqual(len([p for p in radar() if p['shape']=='tube']),24)
        self.assertTrue(any(p.get('radar_material')=='antenna_inside_radome' for p in radar()))

    def test_04_scene_data_preserved(self):
        for key in ARRAY_FIELDS:
            arr=getattr(self.world,key)
            self.assertEqual(arr.shape,(1536,1536),key)
            self.assertTrue(np.isfinite(arr).all(),key)

    def test_05_reference_not_mutated(self):
        before=hashlib.sha256(self.world.height.tobytes()+self.world.mat_id.tobytes()).hexdigest()
        native_models_world(self.world)
        after=hashlib.sha256(self.world.height.tobytes()+self.world.mat_id.tobytes()).hexdigest()
        self.assertEqual(before,after)
        self.assertFalse(np.shares_memory(self.native.height,self.world.height))

    def test_06_native_changes_localized(self):
        changed=(self.native.height!=self.world.height)|(self.native.mat_id!=self.world.mat_id)
        self.assertGreater(np.count_nonzero(changed),0)
        self.assertLess(changed.mean(),.01)
        self.assertFalse(np.any(changed&~self.native._changed_mask))

    def test_07_shared_manifest(self):
        d=self.path/'world'
        manifest=export_scene(self.native,d)
        h=np.fromfile(d/'ground.f32',dtype='<f4')
        self.assertEqual(h.size,manifest['mesh_n']**2)
        self.assertEqual(manifest['entities'],self.native._entities)
        with Image.open(d/'albedo.png') as image:self.assertEqual(image.size,(1536,1536))
        self.assertEqual(np.fromfile(d/'trees.f32',dtype='<f4').size,4*manifest['tree_count'])
        self.assertTrue(all(e['scale']==[1,1,1] for e in manifest['entities'] if e['kind']=='radar'))

    def test_08_reference_replay_matches_approved(self):
        path=self.path/'replayed.png'
        render(self.world,np.array([0.,-2400.,1450.]),'detail',path)
        result=png_diff(path,FIXTURE)
        self.assertTrue(result['match'],result)
        self.assertEqual(result['changed_pixels'],0)

    def test_09_scan_configuration(self):
        a,_=request_config({'quality':'survey'})
        b,_=request_config({'quality':'detail'})
        self.assertGreater(a.range_resolution_m,b.range_resolution_m)
        self.assertEqual((b.range_window,b.azimuth_window),('rectangular','rectangular'))
        self.assertTrue(b.normalize_sampling)
        with self.assertRaises(ValueError):request_config({'quality':'unknown'})

    def test_10_static_pose_is_reproducible(self):
        a=self.path/'static_a.png';b=self.path/'static_b.png'
        render(self.native,[0.,-2400.,1450.],'survey',a)
        render(self.native,[0.,-2400.,1450.],'survey',b)
        self.assertTrue(png_diff(a,b)['match'])

    def test_11_changed_view_changes_image(self):
        a=self.path/'view_a.png';b=self.path/'view_b.png'
        render(self.native,[0.,-2400.,1450.],'survey',a)
        render(self.native,[-1850.,-1850.,620.],'survey',b)
        diff=png_diff(a,b)
        self.assertGreater(diff['mean_pixel_error'],2)
        self.assertGreater(diff['changed_pixels'],10000)

if __name__=='__main__':unittest.main(verbosity=2)
