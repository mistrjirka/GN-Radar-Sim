"""Measured baseline for scan latency; no changes to image generation."""
from pathlib import Path
import sys,cProfile,pstats,time,copy,json
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
import mission_worker as worker
out=Path('.radar_runtime/performance');out.mkdir(parents=True,exist_ok=True)
w=worker.SortieRegion(42)
for name,center,extent in [('sortie_2km',[-1500,-4600],2000),('sortie_1km',[-1500,-4600],1000)]:
    pose=[-1800,-7600,1250]
    records=[]
    for i in range(3):
        t=time.perf_counter();r=worker.render_patch(w,pose,center,extent,'detail',out,i)
        r['end_to_end_s']=time.perf_counter()-t;records.append(r)
    prof=cProfile.Profile();prof.enable()
    worker.render_patch(w,pose,center,extent,'detail',out,8)
    prof.disable();prof.dump_stats(str(out/(name+'.prof')))
    with (out/(name+'_profile.txt')).open('w') as f:
        pstats.Stats(prof,stream=f).strip_dirs().sort_stats('cumtime').print_stats(35)
    (out/(name+'_baseline.json')).write_text(json.dumps(records,indent=2))
    print(name,[(round(r['end_to_end_s'],3),round(r['stats']['measurement_s'],3),round(r['stats']['processing_s'],3)) for r in records],flush=True)
    print((out/(name+'_profile.txt')).read_text()[:5000],flush=True)
