"""Verify produced files and actual flown state; no aesthetic claims from counters.

python game/cockpit/tests/verify_sortie_run.py .radar_runtime/.../delivery_run
"""
from pathlib import Path
import json,sys
from PIL import Image


def verify(folder):
    folder=Path(folder);report=json.loads((folder/'sortie_test.json').read_text())
    errors=[]
    if not report.get('success'):errors.append('Run did not complete successfully')
    if report.get('position_teleports')!=0:errors.append('Flight used teleportation')
    if report.get('free_stores')!=0:errors.append('Flight used free stores')
    flight=report.get('flown_record',{})
    if not flight.get('survived'):errors.append('Egress not reached')
    if flight.get('distance_m',0)<23000:errors.append('Did not fly the expanded route')
    if not report.get('release_success'):errors.append('Objective was not completed')
    if report.get('scan_count',0)<2:errors.append('Second region scan missing')
    if report.get('world_bounds')!=[-6000.,6000.,-9000.,9000.]:errors.append('Wrong region extent')
    a=report.get('first_scan',{});b=report.get('second_scan',{})
    if a.get('center')==b.get('center'):errors.append('Radar did not change regions')
    if set(report.get('rwr_keys',[]))-{'id','bearing','strength','tracking'}:errors.append('RWR exposes extra position/range information')
    shots={}
    for name in ['01_sortie_station','02_sortie_orders','03_rolling_route','04_inland_scan','05_inland_radar','07_flight_record']:
        path=folder/(name+'.png')
        if not path.exists():errors.append('Missing '+name);continue
        with Image.open(path) as image:
            image.verify();shots[name]=list(image.size)
    log=folder.with_suffix('.log')
    if log.exists():
        for line in log.read_text().splitlines():
            if 'SCRIPT ERROR' in line or 'ERROR:' in line:errors.append(line)
    result={'ok':not errors,'problems':errors,'images':shots,
            'simulated_flight_seconds':flight.get('seconds'),'distance_m':flight.get('distance_m'),
            'scope':'Automated accelerated ordinary-state flight; not a human playtest or realism certification'}
    (folder/'verified.json').write_text(json.dumps(result,indent=2))
    print(json.dumps(result,indent=2))
    return not errors

if __name__=='__main__':sys.exit(0 if verify(sys.argv[1]) else 1)
