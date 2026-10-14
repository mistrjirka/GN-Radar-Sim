"""Verify finite evidence for an endless-flight run; counters are not image review.

Requires genuine scan results, installed chart sheets, gradual turn evidence and
actual screenshot files when capture was enabled. Does not imply every possible
seed/coordinate/hardware combination is validated.
"""
from pathlib import Path
import json,sys
from PIL import Image


def verify(folder):
    folder=Path(folder);r=json.loads((folder/'endless_test.json').read_text())
    errors=[]
    if not r.get('success'):errors.append('Driver did not report success')
    for name,ok in r.get('checks',{}).items():
        if not ok:errors.append(name)
    if r.get('position_teleports')!=0:errors.append('Teleport used in flight test')
    if r.get('sheet_updates',0)<2:errors.append('Insufficient streaming evidence')
    qualities={s['quality'] for s in r['scans']}
    if not {'survey','map','detail'}.issubset(qualities):errors.append('Missing acquired resolution')
    for scan in r['scans']:
        if not scan.get('stats',{}).get('total_s',0)>0:errors.append('Unmeasured scan')
        if scan['width']*scan['height']<=0:errors.append('Empty scan dimensions')
        if 'global_center' not in scan:errors.append('Missing frozen world acquisition center')
    if r.get('test_time_acceleration')==1 and r.get('screenshots_during_test'):
        errors.append('Real-time result includes screenshot work')
    if r.get('screenshots_during_test'):
        for name in ['01_open_flight','02_mechanical_chart','03_turn_in_progress',
                     '04_fast_resolution','05_fine_resolution','06_new_landscape','08_streamed_cockpit']:
            f=folder/(name+'.png')
            if not f.exists():errors.append('Missing actual PNG: '+name);continue
            with Image.open(f) as im:
                if im.width<1000 or im.height<600:errors.append('Unexpected viewport resolution: '+name)
                im.verify()
    log=folder.with_suffix('.log')
    if log.exists():
        errors.extend(line for line in log.read_text().splitlines() if 'SCRIPT ERROR' in line or 'ERROR:' in line)
    result={'ok':not errors,'errors':errors,'distance_m':r['distance_m'],'sheet_updates':r['sheet_updates'],
            'frame_intervals':r['frames'],'screenshot_work':r['screenshots_during_test'],
            'time_multiplier':r['test_time_acceleration'],'scope':'Recorded runtime behavior and output files; visual assessment is separate.'}
    (folder/'verified.json').write_text(json.dumps(result,indent=2))
    print(json.dumps(result,indent=2))
    return not errors

if __name__=='__main__':sys.exit(0 if verify(sys.argv[1]) else 1)
