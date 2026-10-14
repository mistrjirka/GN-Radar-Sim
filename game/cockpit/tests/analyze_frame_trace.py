"""Summarize real frame intervals, with correlation rather than causal guesses.

Usage: python game/cockpit/tests/analyze_frame_trace.py path/to/performance_run
No screenshots are taken; report separates startup, radar, UI and normal flight.
"""
from pathlib import Path
import json,sys
import numpy as np


def stats(frames):
    if not frames:return dict(frames=0)
    values=np.array([x[1] for x in frames])
    return dict(frames=len(values),p50_ms=float(np.percentile(values,50)),
                p95_ms=float(np.percentile(values,95)),p99_ms=float(np.percentile(values,99)),
                max_ms=float(values.max()),over_25_ms=int((values>25).sum()),
                over_33_3_ms=int((values>1000/30).sum()),over_50_ms=int((values>50).sum()),
                over_100_ms=int((values>100).sum()))


def analyze(folder):
    folder=Path(folder);trace=json.loads((folder/'frame_trace.json').read_text())
    frames=trace['frames'];spans=trace['spans']
    byphase={phase:stats([r for r in frames if r[3]==phase]) for phase in sorted(set(r[3] for r in frames))}
    worst=[]
    for row in sorted(frames,key=lambda r:r[1],reverse=True)[:18]:
        # A stall measured at a frame boundary may originate inside the previous frame.
        near=[s for s in spans if s['start_ms']<=row[0]+2 and s['start_ms']+s['duration_ms']>=row[0]-row[1]-2]
        worst.append(dict(time_ms=row[0],wall_ms=row[1],engine_process_ms=row[2],phase=row[3],worker_busy=row[4],scans=row[5],overlapping_spans=near))
    if (folder/'performance_run.json').exists():
        sample=json.loads((folder/'performance_run.json').read_text())
    else:
        source=json.loads((folder/'sortie_test.json').read_text())
        sample={'requests':source.get('scan_count',0),'scans':[source[k] for k in ('first_scan','second_scan') if k in source]}
    loading=[s for s in spans if s['name']=='chart_load_and_prepare']
    cutoff=loading[-1]['start_ms']+loading[-1]['duration_ms'] if loading else 0
    out=dict(all=stats(frames),phases=byphase,after_chart_ready=stats([r for r in frames if r[0]-r[1]>cutoff]),
             worker_busy=stats([r for r in frames if r[4] and r[3]!='loading']),
             worker_idle=stats([r for r in frames if not r[4] and r[3]!='loading']),
             largest_spans=sorted(spans,key=lambda s:s['duration_ms'],reverse=True)[:15],
             worst_frames=worst,requests=sample['requests'],completed_scans=len(sample['scans']),
             scan_calculation_s=[s['stats']['total_s'] for s in sample['scans']],
             caveat='Wall frame timing includes display synchronization and OS scheduling. Overlapping spans are evidence of correlation, not proof of GPU attribution.')
    (folder/'frame_summary.json').write_text(json.dumps(out,indent=2))
    print(json.dumps(out,indent=2))
    return out

if __name__=='__main__':analyze(sys.argv[1])
