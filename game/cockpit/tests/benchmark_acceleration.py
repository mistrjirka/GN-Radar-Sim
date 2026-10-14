"""Alternating same-scene comparisons; never trades image quality for timing."""
from pathlib import Path
import sys,copy,json,time,platform,hashlib
import numpy as np
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
import mission_worker as worker
import approved_renderer as reference
from scan_acceleration import ParallelRadar

out=Path('.radar_runtime/performance');out.mkdir(parents=True,exist_ok=True)
world=worker.SortieRegion(42)
results=[]
for name,center,extent in [('sortie_2km',[-1500,-4600],2000),('sortie_1km',[-1500,-4600],1000)]:
    patch,c=world.patch(center,extent)
    pose=(-1800-float(c[0]),-7600-float(c[1]),1250.)
    cfg=reference.Instrument(name='v7_source_preserving',range_window='rectangular',azimuth_window='rectangular',normalize_sampling=True)
    gold=None
    for workers in (1,2,3,4):
        engine=ParallelRadar(workers)
        for repeat in range(2):
            for mode in ('reference','parallel'):
                patch.rng.bit_generator.state=copy.deepcopy(patch._initial_rng)
                st=time.perf_counter()
                m=(reference.measure if mode=='reference' else engine.measure)(patch,pose,n_az=1800,n_rg=2000)
                power,image,r=(reference.image_measurements if mode=='reference' else engine.image)(patch,m,cfg)
                elapsed=time.perf_counter()-st
                if gold is None:gold=(power.copy(),image.copy(),m['polar_slant_img'].copy())
                exact=(np.array_equal(power,gold[0]) and np.array_equal(image,gold[1]) and np.array_equal(m['polar_slant_img'],gold[2]))
                diff=float(np.max(np.abs(image-gold[1])))
                record=dict(case=name,mode=mode,workers=workers,repeat=repeat,elapsed_s=elapsed,
                            measurement_s=r['measurement_s'],processing_s=r['processing_s'],
                            exact_float_array_match=exact,max_image_float_error=diff)
                results.append(record)
                print(json.dumps(record),flush=True)
                assert exact,record
        engine.close()
    reference.save(out/(name+'_verified_image.png'),gold[1])
    del patch,gold
(out/'acceleration_benchmark.json').write_text(json.dumps(dict(cpu=platform.processor(),runs=results),indent=2))
print('ALL reference/parallel image and measurement arrays matched exactly',flush=True)
