"""Continuity, hidden-information and bounded-work tests for the larger sortie.

Real selected-area scans reuse the approved image formation. No screenshot is
accepted as proof of physical realism; these tests cover data/state contracts.
"""
from pathlib import Path
import sys, tempfile, unittest, json, hashlib
import numpy as np
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from mission_worker import render_patch, selected_world, RADAR
from sortie_region import SortieRegion, BOUNDS
from region_noise import land_fields

class SortieRegionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.world=SortieRegion(42)
        cls.tmp=tempfile.TemporaryDirectory();cls.out=Path(cls.tmp.name)
    @classmethod
    def tearDownClass(cls):cls.tmp.cleanup()

    def test_bounds_and_route_length(self):
        p=self.world.public_manifest();b=p['bounds']
        self.assertEqual([b[1]-b[0],b[3]-b[2]],[12000,18000])
        for route in p['suggested_routes'].values():
            chain=np.array([p['start'],*route])
            self.assertGreater(np.linalg.norm(np.diff(chain,axis=0),axis=1).sum(),12000)
            for x,y in route:self.assertTrue(b[0]<x<b[1] and b[2]<y<b[3])

    def test_seed_reproducibility_and_variation(self):
        same=SortieRegion(42);other=SortieRegion(43)
        self.assertEqual(self.world.public_manifest(),same.public_manifest())
        self.assertNotEqual(self.world.target,other.target)
        x=np.linspace(-6000,6000,64);y=np.linspace(-9000,9000,64)
        X,Y=np.meshgrid(x,y)
        self.assertFalse(np.array_equal(self.world.ground(X,Y)['ground'],other.ground(X,Y)['ground']))

    def test_uncertainty_not_precise_positions(self):
        public=self.world.public_manifest()
        self.assertNotIn('emitters',public);self.assertNotIn('sites',public)
        self.assertEqual(len(self.world.sites),7)
        self.assertGreater(len(public['suspected']),len(self.world.sites))
        for site,intel in zip(self.world.sites,public['suspected']):
            delta=np.linalg.norm(np.array(site['position'])-np.array(intel['center']))
            self.assertGreater(delta,1);self.assertLess(delta,intel['radius'])

    def test_coordinate_noise_is_query_order_independent(self):
        X,Y=np.meshgrid(np.arange(-1000,1001,5),np.arange(-2100,-1000,5))
        whole=land_fields(X,Y,42)
        part=land_fields(X[22:95,10:75],Y[22:95,10:75],42)
        for key in whole:self.assertTrue(np.array_equal(whole[key][22:95,10:75],part[key]),key)

    def test_reference_renderer_unchanged(self):
        self.assertEqual(hashlib.sha256((RADAR/'vendor/gemini_v65.py').read_bytes()).hexdigest(),
                         '4b06e1b8dd00d45db3fef2491d27c07b39d6ade3e16bc48d585e108750ca96d1')

    def test_patch_outside_old_map_and_bounds(self):
        patch,c=selected_world(self.world,[-1800,-4500],1000)
        self.assertLess(c[1],-1000)
        self.assertEqual(patch.size_m,1000)
        self.assertTrue(np.isfinite(patch.height).all())
        self.assertGreater(patch._ground_height.std(),5)
        c=self.world.clamp_center([99999,-99999],4000)
        self.assertTrue(np.array_equal(c,[4000,-7000]))
        with self.assertRaises(ValueError):self.world.clamp_center([np.nan,0],1000)
        with self.assertRaises(ValueError):self.world.clamp_center([0,0],300)

    def test_hazard_locations_have_actual_geometry(self):
        site=self.world.sites[0];w,c=self.world.patch(site['position'],600)
        mask=(abs(w._global_x-site['position'][0])<5)&(abs(w._global_y-site['position'][1])<5)
        self.assertGreater(w.trihedral_str[mask].max(),100)
        self.assertGreater((w.mat_id==5).sum(),20)
        self.assertGreater(w.height[mask].max()-w._ground_height[mask].min(),20)

    def test_patch_cache_is_bounded(self):
        for y in [-6000,-5500,-5000,-4500,-4000]:self.world.patch([-3000,y],600)
        self.assertLessEqual(len(self.world._patches),3)

    def test_chart_does_not_depend_on_secret_threat_list(self):
        w=SortieRegion(42)
        a=self.out/'chart_a.png';b=self.out/'chart_b.png'
        w.write_chart(a);w.sites=[];w.write_chart(b)
        self.assertEqual(a.read_bytes(),b.read_bytes())

    def test_scanning_changes_geographic_data(self):
        a=render_patch(self.world,[-2500,-6900,1250],[-2100,-4300],600,'survey',self.out,10)
        b=render_patch(self.world,[2000,1600,1250],[2000,3900],600,'survey',self.out,11)
        A=np.fromfile(a['raw_image'],np.uint8).astype(float)
        B=np.fromfile(b['raw_image'],np.uint8).astype(float)
        self.assertGreater(A.std(),8);self.assertGreater(B.std(),8)
        self.assertGreater(np.mean(abs(A-B)),5)
        self.assertEqual(a['center'],[-2100.,-4300.])
        self.assertEqual(a['stats']['approximation'],'complex-PSF statistical image formation, no raw pulse simulation')

if __name__=='__main__':unittest.main(verbosity=2)
