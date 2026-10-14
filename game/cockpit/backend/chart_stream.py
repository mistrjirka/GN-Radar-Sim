"""Lower-priority rolling-paper requests, served between radar acquisitions.

One owned Python worker stays sufficient. The game prefetches with several
kilometres of margin and retains the current chart while this job is calculated.
"""
from pathlib import Path
import json, time, traceback
from scene_world import atom_json
from endless_world import EndlessWorld

class ChartStream:
    def __init__(self,folder):
        self.folder=Path(folder);self.last=-1

    def poll(self,world):
        if not isinstance(world,EndlessWorld):return
        request_file=self.folder/'stream_request.json'
        if not request_file.exists():return
        try:
            req=json.loads(request_file.read_text());rid=int(req['id'])
            if rid<=self.last:return
            self.last=rid
            if int(req.get('seed',world.seed))!=world.seed:raise ValueError('Chart seed mismatch')
            started=time.perf_counter()
            atom_json(self.folder/'stream_status.json',{'id':rid,'stage':'generating'})
            path=self.folder/f'paper_{rid}.png'
            data=world.write_chart(path,req['position'])
            data['chart']=str(path)
            data['generation_seconds']=time.perf_counter()-started
            manifest=self.folder/f'paper_{rid}.json';atom_json(manifest,data)
            atom_json(self.folder/'stream_status.json',{'id':rid,'stage':'chart_ready','manifest':str(manifest)})
            for pattern in ('paper_*.png','paper_*.json'):
                files=sorted(self.folder.glob(pattern),key=lambda p:p.stat().st_mtime)
                for old in files[:-3]:old.unlink(missing_ok=True)
        except Exception as exc:
            traceback.print_exc()
            atom_json(self.folder/'stream_status.json',{'id':self.last,'stage':'error','message':str(exc)})
