"""The cockpit must change acquisition area, not add game graphics to radar.
Run from repository root: python -m unittest discover -s game/cockpit/tests -v
"""
import sys,tempfile,unittest,hashlib
from pathlib import Path
import numpy as np
from PIL import Image
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'backend'))
from mission_worker import mission_world,selected_world,render_patch,chart_image,RADAR

class CockpitBackendTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.world,cls.public,cls.emitters=mission_world(42,RADAR/'cache')
        cls.tmp=tempfile.TemporaryDirectory(prefix='cockpit-test-')
        cls.out=Path(cls.tmp.name)
    @classmethod
    def tearDownClass(cls):cls.tmp.cleanup()

    def test_01_approved_source_is_unchanged(self):
        source=RADAR/'vendor/gemini_v65.py'
        self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(),'4b06e1b8dd00d45db3fef2491d27c07b39d6ade3e16bc48d585e108750ca96d1')

    def test_02_full_area_reuses_source(self):
        patch,c=selected_world(self.world,[0,0],2000)
        self.assertIs(patch,self.world)
        self.assertTrue(np.array_equal(c,[0,0]))

    def test_03_offset_area_is_real_world_data(self):
        patch,c=selected_world(self.world,[-300,180],1000)
        self.assertEqual(patch.size_m,1000)
        self.assertEqual(patch.N,768)
        self.assertTrue(np.allclose(c,[-300,180]))
        self.assertEqual(patch.height.shape,(768,768))
        self.assertTrue(np.isfinite(patch.height).all())
        self.assertGreater(float(patch.height.std()),5)
        self.assertEqual(float(patch.X[0,0]),-500)
        self.assertEqual(float(patch.X[0,-1]),500)

    def test_04_area_clamps_to_surveyed_map(self):
        _,c=selected_world(self.world,[900,-990],600)
        self.assertTrue(np.allclose(c,[700,-700]))
        with self.assertRaises(ValueError):selected_world(self.world,[0,0],123)
        with self.assertRaises(ValueError):selected_world(self.world,[np.nan,0],1000)

    def test_05_intelligence_is_uncertain(self):
        self.assertEqual(len(self.emitters),3)
        self.assertEqual(len(self.public['suspected']),4)
        self.assertNotIn('emitters',self.public)
        for emitter,area in zip(self.emitters,self.public['suspected']):
            distance=np.linalg.norm(np.array(emitter['position'])-np.array(area['center']))
            self.assertGreater(distance,1)
            self.assertLess(distance,area['radius'])

    def test_06_world_has_new_emitter_geometry(self):
        radars=[e for e in self.world._entities if e['kind']=='radar']
        self.assertEqual(len(radars),3)
        for e in self.emitters:
            x,y=e['position']
            ix=int((x+1000)/2000*(self.world.N-1));iy=int((y+1000)/2000*(self.world.N-1))
            self.assertGreater(float(self.world.trihedral_str[iy,ix]),0)

    def test_07_chart_has_no_game_emitter_overlay(self):
        p=self.out/'chart.png';chart_image(self.world,p)
        with Image.open(p) as im:self.assertEqual(im.size,(1536,1536))
        # Chart uses pre-equipment topography, not live threat positions.
        self.assertTrue(hasattr(self.world,'_chart_ground'))
        self.assertFalse(np.shares_memory(self.world._chart_ground,self.world._ground_height))

    def test_08_real_scan_bytes_and_distinct_areas(self):
        a=render_patch(self.world,[0,-1870,1250],[-300,-450],600,'survey',self.out,1)
        b=render_patch(self.world,[0,-1870,1250],[350,250],600,'survey',self.out,2)
        ar=np.fromfile(a['raw_image'],np.uint8).reshape(a['height'],a['width'])
        br=np.fromfile(b['raw_image'],np.uint8).reshape(b['height'],b['width'])
        self.assertGreater(float(ar.std()),10)
        self.assertGreater(float(np.abs(ar.astype(float)-br).mean()),5)
        with Image.open(a['image']) as im:self.assertTrue(np.array_equal(ar,np.asarray(im)))
        self.assertEqual(a['center'],[-300.,-450.])
        self.assertEqual(a['pose'],[0.,-1870.,1250.])
        self.assertEqual(a['stats']['approximation'],'complex-PSF statistical image formation, no raw pulse simulation')

    def test_09_overhead_area_is_explicitly_inhibited(self):
        with self.assertRaisesRegex(ValueError,'INHIBITED'):
            render_patch(self.world,[0,0,1200],[0,0],1000,'map',self.out,9)

if __name__=='__main__':unittest.main(verbosity=2)
