"""Live heading-up patch geometry; keeps the approved radar kernels unchanged."""
from pathlib import Path
import math,sys,tempfile,unittest
import numpy as np
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from scan_geometry import validate_forward_scan,LIMITS
from endless_world import EndlessWorld,CHART_WIDTH,CHART_HEIGHT,STREAM_STEP,SHEET_FORWARD
from mission_worker import render_patch

class ScanEnvelopeTests(unittest.TestCase):
    def test_entire_oriented_square_forward(self):
        for heading in (0.,math.pi/2,math.pi,-math.pi/2,.73):
            f=np.array([math.sin(heading),math.cos(heading)])
            validate_forward_scan([0,0,1250],heading,(f*3000).tolist(),1600)
            with self.assertRaises(ValueError):validate_forward_scan([0,0,1250],heading,(-f*3000).tolist(),1600)
            with self.assertRaises(ValueError):validate_forward_scan([0,0,1250],heading,(f*2000).tolist(),4000)
    def test_no_self_side_far_or_invalid_scan(self):
        for center in ([0,0],[5000,1000],[0,-2000],[0,11900]):
            with self.assertRaises(ValueError):validate_forward_scan([0,0,1250],0,center,1600)
        for heading in (float('nan'),float('inf')):
            with self.assertRaises(ValueError):validate_forward_scan([0,0,1250],heading,[0,3000],1600)
    def test_rejected_before_any_terrain_generation(self):
        class NoAllocation:
            def patch(self,*args):raise AssertionError('Invalid scan must not allocate terrain')
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(ValueError):render_patch(NoAllocation(),[0,0,1250],[0,0],1600,'survey',Path(folder),1,heading=0)
    def test_rotated_terrain_covers_the_requested_square(self):
        w=EndlessWorld(42)
        a,_=w.patch([14721.,-8229.],600,0.)
        b,_=w.patch([14721.,-8229.],600,math.pi/2)
        np.testing.assert_allclose(b._global_x,np.rot90(a._global_x,-1),atol=1e-6)
        np.testing.assert_allclose(b._global_y,np.rot90(a._global_y,-1),atol=1e-6)
        np.testing.assert_allclose(b._ground_height,np.rot90(a._ground_height,-1),atol=1e-3)
        np.testing.assert_array_equal(b.mat_id,np.rot90(a.mat_id,-1))
    def test_dihedral_orientation_is_rotated_not_brightened(self):
        w=EndlessWorld(42)
        sites=w.features.query([-8000,8000,-12000,0])['sites']
        self.assertTrue(sites)
        a,_=w.patch(sites[0]['position'],600,0.)
        b,_=w.patch(sites[0]['position'],600,math.pi/2)
        np.testing.assert_allclose(b.wall_nx,-np.rot90(a.wall_ny,-1),atol=1e-3)
        np.testing.assert_allclose(b.wall_ny,np.rot90(a.wall_nx,-1),atol=1e-3)
        m=b.dihedral_str>0
        np.testing.assert_allclose(np.sin(b.dihedral_az[m]),np.sin(np.rot90(a.dihedral_az,-1)[m]+math.pi/2),atol=1e-5)
    def test_real_oriented_scan_returns_metadata_and_pixels(self):
        w=EndlessWorld(42)
        with tempfile.TemporaryDirectory() as folder:
            record=render_patch(w,[0,-7600,1250],[2500,-7600],600,'survey',Path(folder),1,heading=math.pi/2)
            self.assertEqual(record['heading'],math.pi/2)
            self.assertEqual(record['center'],[2500.,-7600.])
            raw=np.fromfile(record['raw_image'],np.uint8)
            self.assertEqual(raw.size,record['width']*record['height'])
            self.assertGreater(raw.std(),5)
    def test_rotating_visible_chart_fits_prefetch_sheet_at_every_bearing(self):
        # Same formulas as WorldStream: paper anchor at .81, float-origin stable.
        for heading in np.linspace(0,2*math.pi,49):
            f=np.array([math.sin(heading),math.cos(heading)]);r=np.array([f[1],-f[0]])
            p=np.array([1377.,-5222.]);scale=.065;lead=248/scale+110*8
            request=p+f*lead+np.array([STREAM_STEP/2,STREAM_STEP/2-SHEET_FORWARD])
            b=EndlessWorld.sheet_manifest(request)['bounds']
            for x,y in ((0,0),(640,0),(0,800),(640,800)):
                corner=p+r*(x-320)/scale+f*(648-y)/scale
                self.assertTrue(b[0]<=corner[0]<=b[1] and b[2]<=corner[1]<=b[3],(heading,corner,b))
    def test_distant_receiver_halo_is_bounded(self):
        w=EndlessWorld(42);emitters=w.emitters()
        self.assertGreater(len(emitters),5)
        self.assertLessEqual(len(w.features.cache),256)
        self.assertGreater(LIMITS['receiver_load_radius_m'],LIMITS['receiver_range_m'])

if __name__=='__main__':unittest.main(verbosity=2)
