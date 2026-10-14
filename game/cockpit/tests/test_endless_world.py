"""Endless-generation contracts: world continuity, bounded storage and real scans.

python -m unittest discover -s game/cockpit/tests -p test_endless_world.py -v
This suite is not a claim of an infinitely long manual playtest.
"""
import copy, json, tempfile, unittest
from pathlib import Path
import sys
import numpy as np
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
import mission_worker as worker
from endless_world import EndlessWorld
from endless_terrain import fields
from endless_features import FeatureCells
from chart_stream import ChartStream

class EndlessWorldTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.world=EndlessWorld(42)
        cls.tmp=tempfile.TemporaryDirectory()
        cls.path=Path(cls.tmp.name)
    @classmethod
    def tearDownClass(cls):cls.tmp.cleanup()

    def test_no_map_clamping_at_large_coordinates(self):
        for center in [(120000.,-84000.),(-543210.,768920.),(1e9+.25,-1e9+.5)]:
            self.assertTrue(np.array_equal(self.world.clamp_center(center,1400),center))
        with self.assertRaises(ValueError):self.world.clamp_center([np.nan,0],1000)
        with self.assertRaises(ValueError):self.world.clamp_center([0,0],float('inf'))

    def test_coordinate_noise_independent_of_query_shape_and_order(self):
        x,y=np.meshgrid(np.arange(150000.,150800.,5),np.arange(-92000.,-91500.,5))
        full=fields(x,y,42)
        sub=fields(x[11:85,29:101],y[11:85,29:101],42)
        for key in full:self.assertTrue(np.array_equal(full[key][11:85,29:101],sub[key]),key)

    def test_nonrepeating_seeded_landscapes(self):
        x,y=np.meshgrid(np.arange(80)*17.,np.arange(65)*17.)
        a=fields(x,y,42)['ground'];b=fields(x+16000,y+20000,42)['ground']
        self.assertGreater(float(abs(a-b).mean()),10)
        self.assertFalse(np.array_equal(a,fields(x,y,43)['ground']))
        self.assertTrue(np.array_equal(a,fields(x,y,42)['ground']))

    def test_sheet_overlap_exact_pixels_including_edges(self):
        # Co-located pixel centers, including contour neighbours at crop edges.
        a=self.world.chart_pixels([15000,17000,-10000,-7000])
        b=self.world.chart_pixels([16000,18000,-11000,-8000])
        self.assertTrue(np.array_equal(a[100:300,100:200],b[0:200,0:100]))

    def test_sheet_is_moving_window_not_boundary(self):
        a=self.world.local_manifest([0,0]);b=self.world.local_manifest([22000,-41000])
        self.assertNotEqual(a['bounds'],b['bounds'])
        self.assertTrue(a['endless'] and b['endless'])
        self.assertEqual(b['sheet_center'],[22000,-38000])
        public=self.world.public_manifest()
        self.assertNotIn('emitters',public)
        self.assertEqual(public['scenario'],'endless')

    def test_chart_prefetch_covers_widest_view_during_update(self):
        # Max visible world at 0.065 chart px/metre, plus 500m of travel while
        # the background sheet job runs. No blank leading edge at a grid crossing.
        for x,y in [(0,0),(1999,1999),(-2001,-2001),(1999,-2001)]:
            b=self.world.sheet_manifest([x,y])['bounds']
            for dx,dy in [(500,500),(-500,-500),(500,-500),(-500,500)]:
                left=x+dx-320/.065;right=x+dx+320/.065
                bottom=y+dy-152/.065;top=y+dy+648/.065
                self.assertLessEqual(b[0],left)
                self.assertGreaterEqual(b[1],right)
                self.assertLessEqual(b[2],bottom)
                self.assertGreaterEqual(b[3],top)

    def test_feature_ids_survive_cache_eviction(self):
        cells=FeatureCells(42);a=copy.deepcopy(cells.cell(-7,25))
        for ix in range(115):cells.cell(ix,0)
        self.assertLessEqual(len(cells.cache),96)
        self.assertEqual(a,cells.cell(-7,25))
        for r in cells.query([-30000,30000,-30000,30000])['sites']:
            self.assertTrue(0<=r['id']<2**52)

    def test_paper_pixels_do_not_depend_on_private_emitters(self):
        a=self.world.chart_pixels([-2000,0,-8500,-6500])
        other=EndlessWorld(42)
        for iy in range(-4,1):
            for ix in range(-2,2):other.features.cell(ix,iy)['sites'].clear()
        b=other.chart_pixels([-2000,0,-8500,-6500])
        self.assertTrue(np.array_equal(a,b))

    def test_arbitrary_area_sizes_generate_geometry(self):
        for extent in [400,800,1400,2200]:
            patch,center=self.world.patch([71000,-42000],extent)
            self.assertEqual(patch.size_m,extent)
            self.assertLessEqual(patch.N,1536)
            self.assertTrue(np.isfinite(patch.height).all())
            self.assertGreater(float(patch.height.std()),1)
        self.assertLessEqual(len(self.world._patches),3)

    def test_all_resolutions_request_real_distinct_returns(self):
        center=[72000.,-64000.];pose=[71700.,-66400.,1250.]
        outputs={}
        fast=worker.ParallelRadar(3)
        try:
            for i,quality in enumerate(['survey','map','detail']):
                result=worker.render_patch(self.world,pose,center,800,quality,self.path,100+i,fast)
                outputs[quality]=Path(result['raw_image']).read_bytes()
                self.assertEqual(result['center'],center)
                self.assertEqual(result['quality'],quality)
                self.assertGreater(np.frombuffer(outputs[quality],np.uint8).std(),8)
        finally:fast.close()
        self.assertNotEqual(outputs['survey'],outputs['detail'])
        self.assertNotEqual(outputs['map'],outputs['detail'])

    def test_stream_channel_writes_a_new_sheet(self):
        # Lightweight surface spy tests protocol/errors without big file fixtures.
        w=EndlessWorld(42)
        def write(path,position):
            from PIL import Image
            Image.new('RGB',(16,16),(100,110,80)).save(path)
            return w.local_manifest(position)
        w.write_chart=write
        stream=ChartStream(self.path)
        (self.path/'stream_request.json').write_text(json.dumps({'id':1,'seed':42,'position':[40000,50000]}))
        for _ in range(100):
            stream.poll(w)
            if (self.path/'stream_status.json').exists():
                status=json.loads((self.path/'stream_status.json').read_text())
                if status['stage']=='chart_ready':break
        self.assertEqual(status['stage'],'chart_ready')
        data=json.loads(Path(status['manifest']).read_text())
        self.assertEqual(data['sheet_center'],[40000,54000])

if __name__=='__main__':unittest.main(verbosity=2)
