"""Exact-output tests for scheduling-only scan acceleration."""
from pathlib import Path
import sys,unittest,copy,tempfile
import numpy as np
from scipy.ndimage import convolve1d,map_coordinates
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
import mission_worker as worker
from scan_acceleration import ParallelRadar
import approved_renderer as reference

class AccelerationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fast=ParallelRadar(3)
        cls.rng=np.random.default_rng(1357)
    @classmethod
    def tearDownClass(cls):cls.fast.close()

    def test_convolution_both_axes_and_edges(self):
        a=self.rng.normal(size=(513,600)).astype(np.float32)
        k=self.rng.normal(size=137).astype(np.float32)
        for axis in (0,1,-1):
            expected=convolve1d(a,k,axis=axis,mode='constant')
            got=self.fast.convolve(a,k,axis=axis,mode='constant')
            self.assertTrue(np.array_equal(expected,got),axis)

    def test_resampling_nearest_linear_and_borders(self):
        a=self.rng.normal(size=(90,115)).astype(np.float32)
        coords=np.stack([self.rng.uniform(-3,94,(512,513)),self.rng.uniform(-4,119,(512,513))])
        for order in (0,1):
            for mode in ('nearest','constant'):
                expected=map_coordinates(a,coords,order=order,mode=mode)
                got=self.fast.map(a,coords,order=order,mode=mode)
                self.assertTrue(np.array_equal(expected,got))

    def test_fallbacks_preserve_scipy_contract(self):
        a=np.arange(15,dtype=np.float32).reshape(3,5)
        self.assertTrue(np.array_equal(self.fast.convolve(a,[.2,.3,.5],axis=0),convolve1d(a,[.2,.3,.5],axis=0)))
        coords=np.array([[[1.2,1.3]],[[2.1,3.1]]])
        self.assertTrue(np.array_equal(self.fast.map(a,coords,order=3),map_coordinates(a,coords,order=3)))

    def test_full_scan_pixels_are_identical(self):
        w=worker.SortieRegion(44)
        with tempfile.TemporaryDirectory() as directory:
            out=Path(directory)
            args=(w,[-2900,-6100,1250],[-2000,-4000],1000,'map',out)
            a=worker.render_patch(*args,1)
            b=worker.render_patch(*args,2,accelerator=self.fast)
            self.assertEqual(Path(a['raw_image']).read_bytes(),Path(b['raw_image']).read_bytes())
            self.assertEqual(Path(a['image']).read_bytes(),Path(b['image']).read_bytes())

    def test_measurement_and_float_image_match_multiple_views(self):
        w=worker.SortieRegion(42)
        patch,_=w.patch([-1500,-4600],1000)
        cfg=reference.Instrument(range_window='rectangular',azimuth_window='rectangular',normalize_sampling=True)
        for pose in [(0.,-1800.,1250.),(-1500.,-1600.,620.),(2300.,100.,1500.)]:
            patch.rng.bit_generator.state=copy.deepcopy(patch._initial_rng)
            expected=reference.measure(patch,pose,n_az=720,n_rg=800)
            power,image,_=reference.image_measurements(patch,expected,cfg)
            patch.rng.bit_generator.state=copy.deepcopy(patch._initial_rng)
            got=self.fast.measure(patch,pose,n_az=720,n_rg=800)
            accelerated,pixels,_=self.fast.image(patch,got,cfg)
            self.assertTrue(np.array_equal(expected['polar_slant_img'],got['polar_slant_img']))
            self.assertTrue(np.array_equal(power,accelerated))
            self.assertTrue(np.array_equal(image,pixels))

    def test_reference_functions_not_modified(self):
        self.assertIsNot(reference.measure,self.fast._measure)
        self.assertIs(reference.measure.__code__,self.fast._measure.__code__)
        self.assertIs(reference.image_measurements.__code__,self.fast._image.__code__)
        self.assertIs(reference.image_measurements.__globals__['convolve1d'],convolve1d)
        self.assertIs(reference.scene_to_measurements.__globals__['map_coordinates'],map_coordinates)

if __name__=='__main__':unittest.main(verbosity=2)
