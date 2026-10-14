"""Local developer preview; scene inputs vary, approved image formation does not."""
from pathlib import Path
import sys,json,time
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from mission_worker import SortieRegion,render_patch
out=Path('.radar_runtime/sortie_expansion');out.mkdir(parents=True,exist_ok=True)
w=SortieRegion(42)
t=time.perf_counter();w.write_chart(out/'region_chart.png')
print('chart_s',time.perf_counter()-t,flush=True)
c=w.sites[0]['position'];pose=[c[0]-500,c[1]-2400,1250]
record=render_patch(w,pose,c,2000,'detail',out,1)
(out/'first_radar_stats.json').write_text(json.dumps(record,indent=2))
(out/'public_manifest.json').write_text(json.dumps(w.public_manifest(),indent=2))
print(json.dumps(record,indent=2),flush=True)
